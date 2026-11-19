import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show ValueListenable, TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import 'core/analytics/analytics.dart';
import 'core/app_config.dart';
import 'core/app_mode.dart';
import 'core/backup/auto_backup_runner.dart';
import 'core/boot_network.dart';
import 'core/desktop/desktop_context_menu.dart';
import 'core/desktop/desktop_storage.dart';
import 'core/desktop/desktop_window.dart';
import 'core/di/injector.dart';
import 'core/ui/splash_style.dart';
import 'core/hive/safe_box.dart';
import 'core/discord/discord_rpc.dart';
import 'core/environment.dart';
import 'core/supabase/auth_route.dart';
import 'features/auth/auth_connection_screen.dart';
import 'core/stremio/stremio_sync.dart';
import 'core/logging/app_logger.dart';
import 'core/logging/crash_reports.dart';
import 'core/platform/apple_tv.dart';
import 'core/platform/android_mpv.dart';
import 'core/platform/trusted_certificates.dart';
import 'core/notify/cs_notify.dart';
import 'core/notify/new_episode_inbox.dart';
import 'core/notify/notification_service.dart';
import 'core/notify/push_service.dart';
import 'core/ui/home_rows_prefs.dart';
import 'core/ui/route_observer.dart';
import 'core/ui/poster_card.dart';
import 'core/notify/subscription_checker.dart';
import 'core/notify/subscription_store.dart';
import 'core/playback/category_store.dart';
import 'core/playback/my_list.dart';
import 'core/playback/history_merge.dart';
import 'core/playback/list_idle_runner.dart';
import 'core/playback/resume_store.dart';
import 'core/playback/watch_history.dart';
import 'core/profiles/account_local_data.dart';
import 'core/profiles/viewer_profile.dart';
import 'core/sync/sync_status.dart';
import 'core/reading/read_history.dart';
import 'core/state/active_source_cubit.dart';
import 'core/locale/locale_controller.dart';
import 'core/zmode/match_store.dart';
import 'core/zmode/metadata_provider_prefs.dart';
import 'core/zmode/zmode_prefs.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/app_font_prefs.dart';
import 'core/theme/theme_controller.dart';
import 'core/tv/tv_route_pop_guard.dart';
import 'core/tv/tv_viewport.dart';
import 'core/ui/global_messenger.dart';
import 'core/theme/theme_repaint_observer.dart';
import 'features/auth/auth_cubit.dart';
import 'features/home/cubit/home_cubit.dart';
import 'features/onboarding/boot_error_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/profiles/profile_launch_gate.dart';
import 'features/shell/root_shell.dart';
import 'features/watch_together/ui/party_bar.dart';
import 'features/watch_together/watch_together_controller.dart';
import 'l10n/l10n.dart';

final _authConnectionPhase = ValueNotifier(AuthConnectionPhase.idle);
bool _authConnectionVerified = false;
bool _hadStoredAuthSession = false;
String? _expectedAuthUserId;

/// Windows shows the splash first and runs the network probe and account
/// start-up behind it (shell-4), so clicking the icon offline never looks
/// like nothing happened. Phone and TV keep the probe-before-runApp order.
bool get _splashFirst => defaultTargetPlatform == TargetPlatform.windows;

/// Splash-first only: the pending "Try again" of an unreadable auth-route
/// cache. The app is already running, so instead of replacing it with a
/// second runApp the retry screen is drawn over it while this is non-null.
final _authRouteRetry = ValueNotifier<Completer<void>?>(null);

Future<AuthRouteDecision> _selectLaunchAuthRoute() async {
  // Explicit build overrides are for staging and remain authoritative.
  if (const bool.hasEnvironment('SUPABASE_URL')) {
    return const AuthRouteDecision(AuthRoute.cloud, changed: false);
  }
  while (true) {
    final client = http.Client();
    try {
      return await AuthRouteResolver(
        preferences: await SharedPreferences.getInstance(),
        client: client,
      ).resolve();
    } catch (_) {
      // An unreadable routing cache must never silently select the old authority.
      final retry = Completer<void>();
      if (_splashFirst) {
        // The splash is already up: show the retry screen over it (see
        // _AuthRouteRetryOverlay) and wait for the button.
        _authRouteRetry.value = retry;
        await retry.future;
        _authRouteRetry.value = null;
        continue;
      }
      runApp(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Connection settings unavailable'),
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Connect to the internet and try again.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                  FilledButton(
                    onPressed: () {
                      if (!retry.isCompleted) retry.complete();
                    },
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await retry.future;
    } finally {
      client.close();
    }
  }
}

Future<bool> _verifyLaunchAuthConnection() async {
  try {
    final client = Supabase.instance.client;
    if (_hadStoredAuthSession || client.auth.currentSession != null) {
      if (client.auth.currentSession == null) return false;
      final result = await client.auth.getUser().timeout(
        const Duration(seconds: 5),
      );
      return result.user != null &&
          (!_hadStoredAuthSession || result.user!.id == _expectedAuthUserId);
    }
    final httpClient = http.Client();
    try {
      final response = await httpClient
          .send(
            http.Request(
                'GET',
                Uri.parse('${AuthRoute.active.url}/auth/v1/health'),
              )
              ..followRedirects = false
              ..headers['apikey'] = AuthRoute.active.anonKey,
          )
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } finally {
      httpClient.close();
    }
  } catch (_) {
    return false;
  }
}

Future<void> main() async {
  // Run inside a guarded zone so uncaught async errors land in the shareable
  // in-app log (binding + runApp must share this zone — hence both inside).
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await DesktopStorage.initialize();
      unawaited(LiquidGlassWidgets.initialize(enablePerformanceMonitor: false));
      await AppLogger.instance.init();
      // Mirror debugPrint into the log (still prints to the console too).
      final origDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) AppLogger.instance.log(message);
        origDebugPrint(message, wrapWidth: wrapWidth);
      };
      // Flutter framework errors → log + crash report + normal presentation.
      final origOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        AppLogger.instance.logError(details.exception, details.stack);
        CrashReports.record(details.exception, details.stack);
        origOnError?.call(details);
      };
      // Errors from the engine that never reach a Dart zone — a failed
      // platform-channel reply, for one. Without this they are invisible.
      PlatformDispatcher.instance.onError = (error, stack) {
        AppLogger.instance.logError(error, stack);
        CrashReports.record(error, stack, fatal: true);
        return true;
      };
      // Install public roots before Firebase, Supabase, images, or providers
      // create HTTPS clients. A broken asset falls back to platform validation.
      if (Platform.isAndroid) {
        try {
          await installSupplementalTrustRoots();
          AppLogger.instance.log('[tls] Supplemental public CA roots loaded');
        } catch (e, st) {
          AppLogger.instance.logError(e, st);
        }
      }
      final authRouteFuture = _selectLaunchAuthRoute();
      // Cap the in-memory image cache so a heavy source's posters + heroes can't
      // pile up and OOM-crash (default is 100 MB; libmpv adds a big native
      // baseline). On-screen images stay full quality; far-off-screen ones reload
      // from the disk cache.
      PaintingBinding.instance.imageCache.maximumSizeBytes = 80 << 20; // 80 MB
      // Cap the count too — the byte ceiling alone lets lots of small images
      // (cast photos, credits) pile up. 300 is plenty for the visible screens.
      PaintingBinding.instance.imageCache.maximumSize = 300;
      // Fire the list-reveal animations promptly as items scroll in — the
      // detector defaults to a 500ms batch interval, which would blank-flash each
      // card before it reveals.
      VisibilityDetectorController.instance.updateInterval = const Duration(
        milliseconds: 80,
      );
      // Firebase Analytics. Guarded so a build without google-services.json (or a
      // device without Play Services) still boots — analytics just stays off.
      // This Windows port has no desktop Firebase project configuration.
      if (!Platform.isWindows) {
        try {
          await Firebase.initializeApp().timeout(const Duration(seconds: 8));
          Analytics.enabled = true;
          // After initializeApp, and only if it worked — a build with no
          // google-services.json has no Firebase to report to.
          await CrashReports.enable();
        } catch (e, st) {
          AppLogger.instance.logError(e, st);
        }
      }
      // Resolve Apple TV before Supabase / media_kit — Dart reports tvOS as iOS,
      // and the version string often has no "tvos" token, so we ask the native
      // runner. Must run before Supabase: its default auth deep-link observer uses
      // app_links, which has no tvOS plugin (MissingPluginException).
      final appleTv = await resolveAppleTv();
      // shell-4: Windows puts the splash up first and runs the network half
      // of boot behind it (WatchApp awaits [bootNetwork] before opening the
      // local stores). Phone and TV still finish it before runApp.
      Future<bool>? bootNetwork;
      var bootOffline = false;
      if (_splashFirst) {
        bootNetwork = _bootNetwork(
          appleTv: appleTv,
          authRouteFuture: authRouteFuture,
        );
      } else {
        bootOffline = await _bootNetwork(
          appleTv: appleTv,
          authRouteFuture: authRouteFuture,
        );
      }
      // media_kit (libmpv) has no tvOS libs — Apple TV plays via AVPlayer instead.
      // Calling ensureInitialized here prints + throws and used to derail boot.
      // On old Android 8 / Fire TV the native libs can also fail to load; guard
      // those so the UI still comes up (playback may be unavailable there).
      if (!appleTv) {
        try {
          final library = Platform.isAndroid
              ? await resolveAndroidMpvLibrary()
              : null;
          MediaKit.ensureInitialized(libmpv: library);
          AppLogger.instance.log('[media] Native playback library initialized');
        } catch (e, st) {
          AppLogger.instance.logError(e, st);
        }
      }
      // The splash is drawn while initDependencies() is still opening boxes,
      // so the one box it reads (which animation to play) has to be open
      // before that. Tiny local file; bounded and swallowed like everything
      // else out here, because a splash preference is never worth delaying or
      // failing boot over — SplashStyle falls back to the default if this
      // didn't land. initDependencies re-opens it, which Hive serves from
      // cache.
      try {
        await initHiveForApp();
        await openBoxSafely(
          SplashStyle.boxName,
        ).timeout(const Duration(seconds: 2));
      } catch (e, st) {
        AppLogger.instance.logError(e, st);
      }
      // Windows desktop extras: remember click positions so context menus
      // open at the cursor, and load the new-episode inbox (needs Hive,
      // which is ready above). Bounded and guarded like the splash box.
      if (Platform.isWindows) {
        DesktopPointer.install();
        try {
          await NewEpisodeInbox.init().timeout(const Duration(seconds: 2));
        } catch (e, st) {
          AppLogger.instance.logError(e, st);
        }
      }
      // Dependency init happens inside the boot gate so the splash shows
      // immediately instead of a blank screen.
      runApp(WatchApp(bootOffline: bootOffline, bootNetwork: bootNetwork));
    },
    (error, stack) {
      AppLogger.instance.logError(error, stack);
      CrashReports.record(error, stack, fatal: true);
    },
  );
}

/// The network half of boot: one connectivity probe, the auth-route choice,
/// Supabase init and (after an auth host move) the connection check.
/// Returns whether the probe found the network down. Phone and TV await this
/// before runApp; Windows runs it behind the splash (shell-4).
Future<bool> _bootNetwork({
  required bool appleTv,
  required Future<AuthRouteDecision> authRouteFuture,
}) async {
  // Bounded + guarded like Firebase/MediaKit: on a dead/slow network the
  // session-restore inside initialize can HANG (a hang never throws, so a
  // try/catch alone wouldn't save us), and this runs BEFORE runApp — an
  // unbounded hang here traps the app on the splash forever. Time it out so
  // boot always proceeds; cloud features degrade to local-only until the next
  // launch on a live network (SupabaseService.currentUserId tolerates an
  // uninitialized client).
  // One short connectivity probe before any cloud work. On a dead network
  // (Wi-Fi with no internet) each cloud stage used to wait out its own
  // timeout one after another, so the splash stalled and then failed. When
  // the probe says offline, boot stays local-only and BootConnectivity
  // re-checks in the background, then runs the skipped sync on reconnect.
  // The app's own backends: the network counts as down only when none of
  // them can be reached, so one service outage never flips the app offline.
  final probeHosts = [
    Uri.tryParse(Environment.vpsSyncUrl)?.host ?? '',
    Uri.tryParse(Environment.supabaseUrl)?.host ?? '',
    'graphql.anilist.co',
  ];
  final bootOffline = await probeAllUnreachable(probeHosts);
  if (bootOffline) {
    AppLogger.instance.log('[boot] offline — starting local-only');
  }
  // Keep watching for the rest of the session, in both directions: a Wi-Fi
  // drop or an ISP outage later switches the app to offline mode by itself,
  // and the network returning switches it back.
  BootConnectivity.instance.start(
    () => probeAllUnreachable(probeHosts),
    offline: bootOffline,
    // Wi-Fi off / on is noticed within ~2 s instead of the next probe.
    linkDown: localLinkDown,
  );
  // Upstream auth-route selection (auth host migration) runs after the
  // connectivity probe so its connection screen sees the probe result.
  final authDecision = await authRouteFuture;
  AuthRoute.active = authDecision.route;
  if (authDecision.changed) {
    final storedSession = (await SharedPreferences.getInstance()).getString(
      Environment.supabaseSessionStorageKey,
    );
    _hadStoredAuthSession = storedSession?.isNotEmpty ?? false;
    if (_hadStoredAuthSession) {
      try {
        final stored = jsonDecode(storedSession!);
        _expectedAuthUserId = stored['user']['id'] as String?;
      } catch (_) {
        /* A malformed saved session must not produce a success message. */
      }
    }
    _authConnectionPhase.value = AuthConnectionPhase.preparing;
    // Splash-first (Windows): WatchApp is already running and its
    // AuthConnectionOverlay draws this phase, so no second runApp.
    if (!_splashFirst) {
      runApp(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: const AuthConnectionScreen(
            phase: AuthConnectionPhase.preparing,
          ),
        ),
      );
    }
  }
  var supabaseOk = false;
  try {
    // initialize() sets the singleton's client synchronously and only
    // then awaits session restore — a timeout still leaves a usable
    // client behind (registrations below dereference it), so even a
    // probed-offline boot runs it with a short fuse instead of skipping.
    await Supabase.initialize(
      url: AuthRoute.active.url,
      anonKey: AuthRoute.active.anonKey,
      // TV auth uses QR pairing, not OAuth redirect deep links.
      // Keep the same saved session across auth hosts and startup retries.
      authOptions: FlutterAuthClientOptions(
        detectSessionInUri: !appleTv,
        localStorage: SharedPreferencesLocalStorage(
          persistSessionKey: Environment.supabaseSessionStorageKey,
        ),
      ),
    ).timeout(Duration(seconds: bootOffline ? 2 : 8));
    supabaseOk = true;
  } catch (e, st) {
    AppLogger.instance.logError(e, st);
  }
  if (authDecision.changed) {
    _authConnectionVerified =
        supabaseOk && await _verifyLaunchAuthConnection();
  }
  // Boot init failed (dead/slow network) → keep retrying in the background so
  // login + cloud sync self-heal when the network returns, no restart needed.
  if (!supabaseOk) unawaited(_retrySupabaseInit());
  return bootOffline;
}

/// True once Supabase.initialize has set up its singleton. Accessing
/// Supabase.instance asserts when init never ran, so probe it via try/catch.
bool _supabaseReady() {
  try {
    Supabase.instance;
    return true;
  } catch (_) {
    return false;
  }
}

/// After a boot-time Supabase init failure (dead/slow network), keep retrying in
/// the background. Once it comes up, re-run the auth restore so a logged-in
/// user's login + cloud sync reappear WITHOUT an app restart (AuthCubit only
/// restores once, at boot). Fire-and-forget and bounded — gives up quietly if
/// the network stays down (next launch will try again).
Future<void> _retrySupabaseInit() async {
  for (var attempt = 0; attempt < 15; attempt++) {
    await Future.delayed(const Duration(seconds: 15));
    if (_supabaseReady()) break; // a prior attempt already set the client
    try {
      await Supabase.initialize(
        url: AuthRoute.active.url,
        anonKey: AuthRoute.active.anonKey,
        // Same pinned persisted-session key as the boot init above.
        authOptions: FlutterAuthClientOptions(
          detectSessionInUri: !isAppleTv,
          localStorage: SharedPreferencesLocalStorage(
            persistSessionKey: Environment.supabaseSessionStorageKey,
          ),
        ),
      ).timeout(const Duration(seconds: 8));
      break; // initialized
    } catch (_) {
      // still down — try again next loop
    }
  }
  // Client is up now → refresh auth so the UI reflects the restored session.
  // A boot that probed offline also skipped the profile cloud merge — run it
  // now that the network is back.
  if (_supabaseReady() && sl.isRegistered<AuthCubit>()) {
    try {
      await sl<AuthCubit>().restore();
    } catch (_) {}
    try {
      if (sl.isRegistered<ViewerProfileStore>()) {
        await sl<ViewerProfileStore>().loadForUser(
          displayName: sl<AuthCubit>().state.displayName,
        );
      }
    } catch (_) {}
  }
}

/// Boots the app: runs [initDependencies] behind a splash, then builds the
/// real app with the global cubits provided ABOVE the [MaterialApp]'s Navigator
/// so pushed routes (login, profile, …) can read them. Providing them below the
/// Navigator would scope them out of any `Navigator.push`ed route.
class WatchApp extends StatefulWidget {
  const WatchApp({super.key, this.bootOffline = false, this.bootNetwork});

  /// True when the pre-runApp probe found no connectivity: boot stays
  /// local-only instead of waiting out serial network timeouts on the splash.
  final bool bootOffline;

  /// Splash-first boot (Windows): the still-running network half of boot.
  /// Its result replaces [bootOffline]. Null when it finished before runApp.
  final Future<bool>? bootNetwork;

  @override
  State<WatchApp> createState() => _WatchAppState();
}

class _WatchAppState extends State<WatchApp> with WidgetsBindingObserver {
  /// Startup, with a watchdog. NOT `late final` — Try again reassigns it.
  late Future<void> _boot = _startBoot();
  bool _bootReady = false;

  /// True once [initDependencies] finishes — cubits exist for the shell route.
  bool _depsReady = false;

  /// True once [Navigator.pushReplacement] has swapped splash → shell (non-tvOS).
  bool _shellRoutePushed = false;

  /// Drives the already-mounted tvOS initial route directly. Rebuilding
  /// MaterialApp does not update that route on physical Apple TV.
  /// Rebuilds live routes when the theme's mutable colours change.
  final ThemeRepaintObserver _themeRepaint = ThemeRepaintObserver();

  final ValueNotifier<bool> _tvShellGate = ValueNotifier<bool>(false);
  bool _bootFailed = false;
  bool _reconnectRegistered = false;
  Object? _bootError;
  StackTrace? _bootStack;
  String _bootStage = 'initializing local services';

  /// Whether boot found the network down. Starts from the widget value and,
  /// on a splash-first boot, is replaced by the result of the network half.
  late bool _bootOffline = widget.bootOffline;

  Future<void> _startBoot() async {
    // The splash is already on screen; when started this way, finish the
    // network half of boot first. It is outside the 45 s watchdog because it
    // can wait on the user (the auth-route "Try again" screen) and every
    // network step inside it is bounded already.
    final start = DateTime.now();
    await _awaitBootNetwork();
    await _run(start: start).timeout(const Duration(seconds: 45));
  }

  /// Waits for [WatchApp.bootNetwork] (splash-first boot only). A failure
  /// counts as offline so boot still goes ahead local-only; the connectivity
  /// watcher corrects it once a real check runs.
  Future<void> _awaitBootNetwork() async {
    final network = widget.bootNetwork;
    if (network == null) return;
    _bootStage = 'checking the network';
    try {
      _bootOffline = await network;
    } catch (e, st) {
      AppLogger.instance.logError(e, st);
      _bootOffline = true;
    }
  }

  void _watchBoot(Future<void> boot) {
    boot
        .then((_) {
          if (!mounted) return;
          setState(() => _bootReady = true);
          if (_authConnectionPhase.value == AuthConnectionPhase.preparing) {
            _authConnectionPhase.value = _authConnectionVerified
                ? AuthConnectionPhase.ready
                : AuthConnectionPhase.failed;
          }
          if (isAppleTv) {
            // Never mount RootShell during pushReplacement on tvOS — building the
            // full shell synchronously wedged the isolate for seconds while the
            // splash frame stayed composited. Load provider JS first, then reveal
            // the already-mounted [_TvBootGate].
            WidgetsBinding.instance.addPostFrameCallback((_) {
              unawaited(_finishTvProviderBoot());
            });
          } else {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _pushShellRouteIfNeeded();
              if (sl.isRegistered<AppMode>() && sl<AppMode>().isTv) {
                unawaited(_finishTvProviderBoot());
              }
            });
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_syncBootCloud());
          });
          // acct-10: run a scheduled backup once boot is done (Windows only).
          // Platform.isWindows because it writes real files; the target
          // check keeps widget tests (pretending to be Android) timer-free.
          // A few seconds after the first frame so startup is not slowed.
          // runIfDue never throws and is a no-op when backups are off/not due.
          if (Platform.isWindows &&
              defaultTargetPlatform == TargetPlatform.windows) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              unawaited(
                Future<void>.delayed(const Duration(seconds: 5)).then(
                  (_) => AutoBackupRunner.runIfDue(),
                ),
              );
            });
          }
          if (!_handledLaunchTaps) {
            _handledLaunchTaps = true;
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => NotificationService.instance.handleLaunch(),
            );
          }
        })
        .catchError((Object e, StackTrace st) {
          AppLogger.instance.log(
            'Startup failed during $_bootStage',
            level: 'E',
          );
          AppLogger.instance.logError(e, st);
          if (!mounted) return;
          if (_authConnectionPhase.value == AuthConnectionPhase.preparing) {
            _authConnectionPhase.value = AuthConnectionPhase.failed;
          }
          setState(() {
            _bootFailed = true;
            _bootError = e;
            _bootStack = st;
          });
        });
  }

  /// tvOS-only second boot phase: provider eval, then reveal the shell.
  Future<void> _finishTvProviderBoot() async {
    await runDeferredAppleTvBootTasks();
    if (!mounted || !_bootReady || _bootFailed || !_depsReady) {
      debugPrint(
        '[boot] TV provider boot skipped · mounted=$mounted '
        'boot=$_bootReady deps=$_depsReady failed=$_bootFailed',
      );
      return;
    }
    if (isAppleTv) {
      _tvShellGate.value = true;
      setState(() {});
    }
  }

  /// Re-runs startup after a failure. GetIt must be cleared first — every
  /// registerSingleton in initDependencies throws if the type is already
  /// registered, so a bare retry over a partly-built container would fail for
  /// a second, misleading reason.
  Future<void> _retryBoot() async {
    try {
      await sl.reset();
    } catch (_) {
      /* nothing registered yet — fine */
    }
    if (!mounted) return;
    if (!isAppleTv) {
      rootNavigatorKey.currentState?.pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const SplashScreen()),
      );
    }
    setState(() {
      _bootReady = false;
      _depsReady = false;
      _shellRoutePushed = false;
      _bootFailed = false;
      _bootError = null;
      _bootStack = null;
      _handledLaunchTaps = false;
      _boot = _startBoot();
    });
    _tvShellGate.value = false;
    _watchBoot(_boot);
  }

  bool? _onboardedOverride; // set true once onboarding finishes this session
  bool _handledLaunchTaps = false; // route a notification-tap launch once
  DateTime? _lastSubscriptionCheck;

  /// Maximum age of the local cloud snapshot before a launch/resume pull.
  /// This balances cross-device freshness against repeated database reads.
  static const Duration _syncFreshness = Duration(minutes: 10);
  static const Duration _subscriptionCheckCooldown = Duration(minutes: 15);

  /// Windows runs the new-episode checker while the app is open (track-1):
  /// on a timer, on window focus and from Check now. Results go to the
  /// in-app inbox and, when enabled, to a Windows notification.
  static bool get _desktopEpisodeChecks =>
      defaultTargetPlatform == TargetPlatform.windows;

  /// How often Windows re-checks subscriptions while the app stays open.
  static const Duration _desktopSubscriptionInterval = Duration(minutes: 30);

  /// The Windows periodic subscription check (null elsewhere).
  Timer? _subscriptionTimer;

  Future<void> _checkSubscriptions({bool syncCloudStream = false}) async {
    if (!(Platform.isAndroid || _desktopEpisodeChecks) ||
        !sl.isRegistered<SubscriptionChecker>() ||
        !sl.isRegistered<SubscriptionStore>()) {
      return;
    }
    // Windows: a window focus during the splash must not sweep before the
    // sources are loaded; it would fail every show and then start the
    // cooldown, holding back the real boot check.
    if (_desktopEpisodeChecks && !_bootReady) return;
    final now = DateTime.now();
    if (_lastSubscriptionCheck != null &&
        now.difference(_lastSubscriptionCheck!) < _subscriptionCheckCooldown) {
      return;
    }
    _lastSubscriptionCheck = now;
    try {
      if (syncCloudStream) {
        await CsNotify.sync(sl<SubscriptionStore>().all());
      }
      await sl<SubscriptionChecker>().checkAll();
      await CsNotify.checkNow();
    } catch (e) {
      AppLogger.instance.log('[notify] foreground check failed · $e');
    }
  }

  void _onThemeChanged() {
    if (mounted) {
      setState(() {}); // accent changed → rebuild so the app recolours
    }
  }

  void _onLocaleChanged() {
    if (mounted)
      setState(() {}); // language changed → rebuild MaterialApp.locale
  }

  /// The streaming kind changed: swap Home rows without blanking the screen.
  /// Cached rows for the target kind appear immediately; a fresh fetch runs in
  /// the background.
  void _onStreamKindChanged() {
    // TV shell + HomeCubit listen to [ZModePrefs.revision] / bloc state — a
    // full [MaterialApp] rebuild here (phone path) stalls the isolate on TV.
    final tv = sl.isRegistered<AppMode>() && sl<AppMode>().isTv;
    if (!tv && mounted) setState(() {});
    if (!sl.isRegistered<HomeCubit>()) return;
    final cubit = sl<HomeCubit>();
    final cached = cubit.sectionsFor(ZModePrefs.streamKind);
    // TV keeps both catalogues mounted — skip cubit work when rows are cached.
    if (tv && cached != null) return;
    sl<HomeCubit>().loadForStreamKindChange();
  }

  /// Metadata provider changed: rows differ between AniList/MAL/TMDB/Simkl, so
  /// drop any cached streaming-kind rows and hard-reset Home.
  void _onMetadataProviderChanged() {
    if (sl.isRegistered<HomeCubit>()) {
      sl<HomeCubit>().clearStreamKindCache();
      sl<HomeCubit>().load(reset: true);
    }
    if (mounted) setState(() {});
  }

  /// A home-rows arrangement was saved or reset: re-merge the layout Home
  /// already fetched (no refetch, no scroll reset — provider data is
  /// unchanged, only its arrangement is).
  void _onHomeRowsChanged() {
    if (sl.isRegistered<HomeCubit>()) sl<HomeCubit>().relayout();
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ThemeController.revision.addListener(_onThemeChanged);
    // The UI font is baked into every AppText getter and into ThemeData, so a
    // change has to rebuild MaterialApp — same as an accent change.
    AppFontPrefs.revision.addListener(_onThemeChanged);
    LocaleController.revision.addListener(_onLocaleChanged);
    ZModePrefs.revision.addListener(_onStreamKindChanged);
    MetadataProviderPrefs.revision.addListener(_onMetadataProviderChanged);
    HomeRowsPrefs.revision.addListener(_onHomeRowsChanged);
    // acct-3: the title-bar sync icon (click / F5) asks for a sync through
    // SyncStatus; this app owns the library sync, so it answers. Going
    // offline is reported there too so the icon reflects it at once.
    SyncStatus.onSyncRequested = _syncNow;
    BootConnectivity.instance.offline.addListener(_onConnectivityChanged);
    _watchBoot(_boot);
  }

  /// Manual "Sync now" (acct-3): re-test a session we only assumed was dead,
  /// then pull and push the whole library regardless of how fresh it is.
  Future<void> _syncNow() async {
    if (sl.isRegistered<AuthCubit>()) {
      try {
        await sl<AuthCubit>().revalidateIfFlagged(force: true);
      } catch (_) {
        /* the sync below reports the outcome */
      }
    }
    // Offline: ask the connectivity watcher to look again now, so a network
    // that just came back is noticed without waiting for its timer.
    if (BootConnectivity.instance.offline.value) {
      await BootConnectivity.instance.checkNow();
    }
    if (sl.isRegistered<StremioSync>()) {
      unawaited(sl<StremioSync>().refresh(maxAge: Duration.zero));
    }
    await _runLibrarySync(maxAge: Duration.zero);
  }

  /// Mirrors the connectivity watcher into the sync status: offline shows
  /// at once; coming back is reported by the reconnect sync itself.
  void _onConnectivityChanged() {
    if (BootConnectivity.instance.offline.value && _signedIn) {
      SyncStatus.report(SyncState.offline);
    }
  }

  /// True when an account is signed in (and the cubit exists yet).
  bool get _signedIn =>
      sl.isRegistered<AuthCubit>() && sl<AuthCubit>().state.isLoggedIn;

  /// Reports the resting state after a sync attempt: needs sign-in when the
  /// session looked dead or nobody is signed in, offline when the network is
  /// down, otherwise synced.
  void _reportSyncDone() {
    if (!_signedIn) {
      SyncStatus.report(SyncState.needsSignIn);
    } else if (sl<AuthCubit>().state.needsReconnect) {
      SyncStatus.report(SyncState.needsSignIn);
    } else if (BootConnectivity.instance.offline.value) {
      SyncStatus.report(SyncState.offline);
    } else {
      SyncStatus.report(SyncState.synced);
    }
  }

  @override
  void dispose() {
    ThemeController.revision.removeListener(_onThemeChanged);
    AppFontPrefs.revision.removeListener(_onThemeChanged);
    LocaleController.revision.removeListener(_onLocaleChanged);
    ZModePrefs.revision.removeListener(_onStreamKindChanged);
    MetadataProviderPrefs.revision.removeListener(_onMetadataProviderChanged);
    HomeRowsPrefs.revision.removeListener(_onHomeRowsChanged);
    WidgetsBinding.instance.removeObserver(this);
    _subscriptionTimer?.cancel();
    BootConnectivity.instance.offline.removeListener(_onConnectivityChanged);
    SyncStatus.onSyncRequested = null;
    _tvShellGate.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final discord = sl.isRegistered<DiscordRpc>() ? sl<DiscordRpc>() : null;
    if (state == AppLifecycleState.resumed) {
      discord?.onForeground();
      // A blink of no network makes the startup session check fail, which
      // raises the "Reconnect to sync" banner — and nothing re-tested it,
      // because restore() only runs at launch. No-op unless that banner is up.
      if (sl.isRegistered<AuthCubit>()) {
        unawaited(sl<AuthCubit>().revalidateIfFlagged());
      }
      _syncOnResume();
      unawaited(_checkSubscriptions());
      // The wallpaper may have changed while we were away. No-op unless
      // Material You is on, and only rebuilds if the colours actually moved.
      ThemeController.refresh();
    } else if (state == AppLifecycleState.paused) {
      // Opening the in-app player (native surface / immersive) fires paused
      // even though the user is still watching. Do not drop Rich Presence.
      discord?.onPaused();
    } else if (state == AppLifecycleState.detached) {
      discord?.onDetached();
    }
  }

  /// Cross-device freshness: when the app returns to the foreground, re-pull the
  /// library if it's older than [_syncFreshness] (debounced inside
  /// [MyListStore.pullFromCloudIfStale], so rapid app-switching doesn't hammer
  /// the DB). Also retries locally queued cloud writes.
  void _syncOnResume() => _syncLibrary(maxAge: _syncFreshness);

  /// True while a focus-triggered library sync is running, so refocusing the
  /// window repeatedly (especially offline, where each sync hangs) never stacks
  /// overlapping syncs.
  bool get _librarySyncing => _librarySync != null;

  /// The library sync in flight, so a manual "Sync now" can wait for the one
  /// a window focus already started instead of being dropped.
  Future<void>? _librarySync;

  void _syncLibrary({required Duration maxAge}) {
    if (sl.isRegistered<StremioSync>()) {
      unawaited(sl<StremioSync>().refresh(maxAge: maxAge));
    }
    unawaited(_runLibrarySync(maxAge: maxAge));
  }

  /// Pulls the library if older than [maxAge] and retries queued writes,
  /// reporting each step to [SyncStatus] (acct-3) instead of only the debug
  /// log. Never throws.
  Future<void> _runLibrarySync({required Duration maxAge}) {
    if (!_signedIn) {
      SyncStatus.report(SyncState.needsSignIn);
      return Future.value();
    }
    // Nothing to sync with while the connection is down; the reconnect task does
    // it the moment the network returns.
    if (BootConnectivity.instance.offline.value) {
      SyncStatus.report(SyncState.offline);
      return Future.value();
    }
    final running = _librarySync;
    if (_librarySyncing && running != null) return running;
    SyncStatus.report(SyncState.syncing);
    Future<void> run() async {
      try {
        await Future.wait([
          sl<MyListStore>().pullFromCloudIfStale(maxAge: maxAge),
          sl<WatchHistory>().pullFromCloudIfStale(maxAge: maxAge),
          sl<ReadHistory>().pullFromCloudIfStale(maxAge: maxAge),
          // My List categories ride the same trigger — two small SELECTs, and
          // they have to arrive with the list they label.
          sl<CategoryStore>().pullFromCloudIfStale(maxAge: maxAge),
        ]);
        await Future.wait([
          sl<MyListStore>().retryPending(),
          sl<WatchHistory>().retryPending(),
          sl<ReadHistory>().retryPending(),
        ]);
        _reportSyncDone();
      } catch (e) {
        debugPrint('[sync] library sync failed: $e');
        // A request that failed because the network vanished is "offline",
        // not an error the user has to act on.
        if (isNetworkFailure(e)) {
          BootConnectivity.instance.suspectOffline();
          SyncStatus.report(SyncState.offline, error: '$e');
        } else {
          SyncStatus.report(SyncState.error, error: '$e');
        }
      } finally {
        _librarySync = null;
      }
    }

    // Started on the next event, so _librarySync is set before run() can
    // finish (and clear it) even if the stores throw synchronously.
    return _librarySync = Future<void>(run);
  }

  /// Init deps, then (for returning users) kick off the Home fetch so its rows
  /// stream in WHILE the splash plays — Home appears already populated. Holds
  /// the splash for a minimum so the intro animation reads even on fast boots.
  Future<void> _run({DateTime? start}) async {
    // [start] is when the splash went up (splash-first boot passes it so the
    // network wait counts towards the minimum splash time).
    start ??= DateTime.now();
    // Boot-gate offline hint expires after a couple of minutes: the launch
    // lock check happens seconds after boot, while later checks (profile
    // switches) are user-initiated and should see remote lock changes.
    final offlineUntil = start.add(const Duration(minutes: 2));
    await initDependencies(
      onProgress: (stage) {
        _bootStage = stage;
        AppLogger.instance.log('[boot] $stage');
      },
      // Glue: the live connectivity watcher also counts as offline, so a
      // connection lost mid-session uses the lock cache instead of hanging.
      isOffline: () =>
          BootConnectivity.instance.offline.value ||
          (_bootOffline && DateTime.now().isBefore(offlineUntil)),
    );
    _bootStage = 'reading app version';
    // Registered once even when "Try again" re-runs boot. It runs every time the
    // network returns after being down (at boot or later in the session); the
    // task restores sign-in itself, so it does not matter whether a session was
    // found while offline.
    if (!_reconnectRegistered) {
      _reconnectRegistered = true;
      BootConnectivity.instance.addReconnectTask(_resyncAfterReconnect);
    }
    if (mounted) {
      setState(() => _depsReady = true);
      if (_bootReady) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _pushShellRouteIfNeeded();
        });
      }
    }
    // Show the real build version in Settings/About instead of a stale literal.
    try {
      final info = await PackageInfo.fromPlatform();
      kAppVersion = info.version;
      kAppBuild = info.buildNumber;
      AppLogger.instance.log(
        '===== session started · v${info.version} (build ${info.buildNumber}) =====',
      );
    } catch (_) {}
    // Restore cached identity and profiles before mounting the profile/PIN gate.
    // Remote profile and library requests run after the splash is dismissed.
    try {
      _bootStage = 'restoring sign-in';
      await sl<AuthCubit>().restore().timeout(const Duration(seconds: 5));
    } catch (_) {}
    // acct-1: record which account the live library belongs to (or bring
    // back its snapshot) even if the auth listener was not mounted yet.
    if (sl<AuthCubit>().state.isLoggedIn) {
      await _adoptAccountLocalData(sl<AuthCubit>().state.user?.id);
    }
    // Local profiles only: the cloud merge and library sync run after the
    // splash in [_syncBootCloud] (online boot) or [_resyncAfterReconnect]
    // (when the network returns after an offline boot).
    await sl<ViewerProfileStore>().loadForUser(
      displayName: sl<AuthCubit>().state.displayName,
      attemptRemote: false,
    );
    // Rows saved under a source before the browse screen started resolving
    // titles to the catalogue: move them onto the show they belong to.
    // Online startup does this after cloud sync so imported rows are covered.
    _bootStage = 'opening home';
    if ((_bootOffline || !sl<AuthCubit>().state.isLoggedIn) &&
        sl.isRegistered<MatchStore>()) {
      unawaited(
        HistoryCanonicalMerge.runOnce(
          history: sl<WatchHistory>(),
          resume: sl<ResumeStore>(),
          matches: sl<MatchStore>(),
        ),
      );
    }
    if (isOnboarded()) {
      // tvOS: Home fetch waits until provider JS is loaded (deferred boot task).
      if (!isAppleTv) sl<HomeCubit>().load();
      // CloudStream-style "new episode" check: once the app is up, re-fetch
      // each subscribed show's episodes (JS or CS) and notify on any increase.
      // Fire-and-forget + delayed so it doesn't compete with the splash/home.
      Future.delayed(const Duration(seconds: 6), () async {
        try {
          await NotificationService.instance.init();
          // Mirror CS subs to native + (re)schedule the background worker, then
          // run the launch/resume sweep: JS sources here, CS via native worker.
          await _checkSubscriptions(syncCloudStream: true);
        } catch (_) {}
      });
      // Windows keeps checking while the app stays open (track-1). The
      // cooldown inside _checkSubscriptions stops this and window focus
      // from doubling up. Re-running boot ("Try again") replaces the timer.
      if (_desktopEpisodeChecks) {
        _subscriptionTimer?.cancel();
        _subscriptionTimer = Timer.periodic(
          _desktopSubscriptionInterval,
          (_) => unawaited(_checkSubscriptions()),
        );
      }
      // R5: auto Paused/Dropped for idle My List titles. First sweep ~20 s
      // after boot (never blocks startup), then a cheap hourly tick that
      // sweeps at most every 6 h. No-op while the setting is off (the
      // default outside Windows). A boot retry replaces the timers.
      ListIdleRunner.instance.start();
    }
    // FCM broadcasts: subscribe every device to the `all` topic so we can push
    // a custom notification to all users from the Firebase Console. Independent
    // of onboarding + fire-and-forget so it never delays launch.
    unawaited(PushService.instance.init());
    final elapsed = DateTime.now().difference(start);
    // The intro animation is 1600ms, so anything past that is just dead
    // waiting. Give it a hair over (1700) so the logo lands, then go — used
    // to be 2000ms, which sat there doing nothing for ~400ms.
    // shell-4 C: on Windows a returning user whose Home is already cached
    // (HomeCubit.load painted the remembered rows above) skips the hold:
    // the window should open straight into their library.
    final minSplash = _skipSplashHold()
        ? Duration.zero
        : const Duration(milliseconds: 1700);
    if (elapsed < minSplash) await Future.delayed(minSplash - elapsed);
  }

  /// True on Windows when the user is onboarded and Home already has cached
  /// rows to show, so holding the intro animation would only delay them.
  bool _skipSplashHold() {
    if (defaultTargetPlatform != TargetPlatform.windows) return false;
    if (!isOnboarded() || !sl.isRegistered<HomeCubit>()) return false;
    return sl<HomeCubit>().state.sections?.isNotEmpty ?? false;
  }

  /// Pushes unsynced rows up and pulls the cloud library into the local cache.
  /// Shared by normal boot and by the reconnect path after an offline boot.
  Future<void> _syncCloudLibrary() async {
    await Future.wait([
      sl<MyListStore>().seedCloudIfNeeded(),
      sl<WatchHistory>().seedCloudIfNeeded(),
      sl<ReadHistory>().seedCloudIfNeeded(),
    ]).timeout(const Duration(seconds: 8));
    await Future.wait([
      sl<MyListStore>().pullFromCloudIfStale(maxAge: _syncFreshness),
      sl<WatchHistory>().pullFromCloudIfStale(maxAge: _syncFreshness),
      sl<ReadHistory>().pullFromCloudIfStale(maxAge: _syncFreshness),
      sl<CategoryStore>().pullFromCloudIfStale(maxAge: _syncFreshness),
    ]).timeout(const Duration(seconds: 6));
    unawaited(
      Future.wait([
        sl<MyListStore>().retryPending(),
        sl<WatchHistory>().retryPending(),
        sl<ReadHistory>().retryPending(),
      ]),
    );
  }

  /// Guards [_resyncAfterReconnect] so two network returns in quick succession
  /// (a flaky connection) never run two syncs at once.
  bool _resyncing = false;

  /// Runs every time the network returns after being down, whether the app
  /// started offline or lost the connection later: reloads Home, restores the
  /// session, merges cloud profiles, then syncs the library.
  Future<void> _resyncAfterReconnect() async {
    if (_resyncing) return;
    _resyncing = true;
    try {
      AppLogger.instance.log('[net] back online — syncing');
      // Home first, for everyone: it should recover even when signed out.
      if (sl.isRegistered<HomeCubit>()) unawaited(sl<HomeCubit>().load());
      if (_supabaseReady() && sl.isRegistered<AuthCubit>()) {
        await sl<AuthCubit>().restore().timeout(const Duration(seconds: 8));
      }
      if (!sl.isRegistered<AuthCubit>() ||
          !sl<AuthCubit>().state.isLoggedIn) {
        return;
      }
      await sl<ViewerProfileStore>()
          .loadForUser(displayName: sl<AuthCubit>().state.displayName)
          .timeout(const Duration(seconds: 15));
      // acct-3: the title-bar icon shows this catch-up sync.
      SyncStatus.report(SyncState.syncing);
      try {
        await _syncCloudLibrary();
        _reportSyncDone();
      } catch (e) {
        SyncStatus.report(SyncState.error, error: '$e');
        rethrow;
      }
    } finally {
      _resyncing = false;
    }
  }

  /// Refresh cloud data after local startup has released the splash.
  Future<void> _syncBootCloud() async {
    if (_bootOffline || !mounted) return;
    final auth = sl<AuthCubit>();
    final userId = auth.state.user?.id;
    if (!auth.state.isLoggedIn || userId == null) return;
    bool isCurrentUser() => mounted && auth.state.user?.id == userId;
    try {
      await sl<ViewerProfileStore>()
          .loadForUser(displayName: auth.state.displayName)
          .timeout(const Duration(seconds: 15));
      if (!isCurrentUser()) return;
      // acct-3: report the boot sync to the title-bar sync icon.
      SyncStatus.report(SyncState.syncing);
      final profileId = sl<ViewerProfileStore>().activeId;
      await Future.wait([
        sl<MyListStore>().seedCloudIfNeeded(),
        sl<WatchHistory>().seedCloudIfNeeded(),
        sl<ReadHistory>().seedCloudIfNeeded(),
      ]).timeout(const Duration(seconds: 8));
      if (!isCurrentUser() || sl<ViewerProfileStore>().activeId != profileId) {
        return;
      }
      await Future.wait([
        sl<MyListStore>().pullFromCloudIfStale(maxAge: _syncFreshness),
        sl<WatchHistory>().pullFromCloudIfStale(maxAge: _syncFreshness),
        sl<ReadHistory>().pullFromCloudIfStale(maxAge: _syncFreshness),
        sl<CategoryStore>().pullFromCloudIfStale(maxAge: _syncFreshness),
      ]).timeout(const Duration(seconds: 6));
      if (!isCurrentUser() || sl<ViewerProfileStore>().activeId != profileId) {
        return;
      }
      await Future.wait([
        sl<MyListStore>().retryPending(),
        sl<WatchHistory>().retryPending(),
        sl<ReadHistory>().retryPending(),
      ]);
      _reportSyncDone();
    } catch (error, stack) {
      AppLogger.instance.logError(error, stack);
      SyncStatus.report(
        isNetworkFailure(error) ? SyncState.offline : SyncState.error,
        error: '$error',
      );
    } finally {
      // An early return (account or profile switched mid-sync) must not
      // leave the icon spinning.
      if (SyncStatus.state.value == SyncState.syncing) _reportSyncDone();
      if (isCurrentUser() && sl.isRegistered<MatchStore>()) {
        unawaited(
          HistoryCanonicalMerge.runOnce(
            history: sl<WatchHistory>(),
            resume: sl<ResumeStore>(),
            matches: sl<MatchStore>(),
          ),
        );
      }
    }
  }

  /// Cloud-sync the library on in-session auth changes: pull on login, wipe the
  /// local cache on logout. Boot-time restore uses [_run] and [_syncBootCloud].
  Future<void> _onAuthChange(BuildContext context, AuthState state) async {
    if (state.status == AuthStatus.authenticated) {
      // acct-1: on Windows, bring back this account's local library from
      // its sign-out snapshot before the cloud sync, so it shows instantly.
      await _adoptAccountLocalData(state.user?.id);
      await sl<ViewerProfileStore>().loadForUser(
        displayName: state.displayName,
      );
      Future<void> sync() async {
        await sl<MyListStore>().seedCloudIfNeeded();
        await sl<WatchHistory>().seedCloudIfNeeded();
        await sl<ReadHistory>().seedCloudIfNeeded();
        await sl<MyListStore>().pullFromCloud();
        await sl<WatchHistory>().pullFromCloud();
        await sl<ReadHistory>().pullFromCloud();
        await sl<CategoryStore>().pullFromCloud();
        unawaited(
          Future.wait([
            sl<MyListStore>().retryPending(),
            sl<WatchHistory>().retryPending(),
            sl<ReadHistory>().retryPending(),
          ]),
        );
        if (!sl.isRegistered<AppMode>() ||
            !sl<AppMode>().isTv ||
            tvosProvidersReady) {
          sl<HomeCubit>().load();
        }
      }

      if (isAppleTv) {
        unawaited(
          sync().timeout(const Duration(seconds: 20)).catchError((_) {}),
        );
      } else {
        // acct-3: the sign-in sync shows on the title-bar sync icon.
        SyncStatus.report(SyncState.syncing);
        try {
          await sync();
          _reportSyncDone();
        } catch (e) {
          SyncStatus.report(SyncState.error, error: '$e');
          rethrow;
        }
      }
    } else if (state.status == AuthStatus.unauthenticated) {
      // acct-1: on Windows, keep the signed-out account's library on disk
      // (a per-account snapshot) before the live copy is cleared below.
      if (_keepAccountData) {
        try {
          await AccountLocalData.onSignedOut();
        } catch (e, st) {
          AppLogger.instance.logError(e, st);
        }
      }
      await sl<ViewerProfileStore>().loadForUser();
      await _clearLocalLibrary();
      SyncStatus.report(SyncState.needsSignIn);
    }
  }

  /// acct-1 is Windows only: phone keeps wiping the library on sign-out.
  static bool get _keepAccountData =>
      defaultTargetPlatform == TargetPlatform.windows;

  /// Drops the live local library (My List, Continue Watching, reading
  /// history). The cloud copy is untouched.
  Future<void> _clearLocalLibrary() async {
    await sl<MyListStore>().clearLocal();
    await sl<WatchHistory>().clearLocal();
    await sl<ReadHistory>().clearLocal();
  }

  /// Windows: makes the live library belong to [userId]. Same account as
  /// before: nothing to do. A sign-out snapshot for it: restored at once.
  /// A different account still holding the live copy: that copy is saved
  /// to its own snapshot and cleared first, so the new account starts clean.
  Future<void> _adoptAccountLocalData(String? userId) async {
    if (!_keepAccountData || userId == null || userId.isEmpty) return;
    try {
      final restored = await AccountLocalData.onSignedIn(
        userId,
        clearLive: _clearLocalLibrary,
      );
      // My List caches a revision counter its screens listen to; the
      // history boxes are watched directly, so only this one needs a nudge.
      if (restored) sl<MyListStore>().revision.value++;
    } catch (e, st) {
      AppLogger.instance.logError(e, st);
    }
  }

  Widget _buildShellHome() {
    final onboarded = _onboardedOverride ?? isOnboarded();
    return onboarded
        ? ProfileLaunchGate(child: RootShell())
        : OnboardingScreen(
            onDone: () {
              setState(() => _onboardedOverride = true);
              if (isAppleTv) {
                // The Navigator retains its initial _TvBootGate route. Its
                // boolean is already true, so parent setState alone cannot
                // replace the Onboarding child; notify the mounted gate again.
                _tvShellGate
                  ..value = false
                  ..value = true;
              } else {
                rootNavigatorKey.currentState?.pushReplacement(
                  MaterialPageRoute<void>(
                    builder: (_) => ProfileLaunchGate(child: RootShell()),
                  ),
                );
              }
            },
          );
  }

  /// Swaps the splash route for the real shell (phone / Android TV only).
  void _pushShellRouteIfNeeded() {
    if (isAppleTv) return;
    if (_shellRoutePushed || !_bootReady || _bootFailed || !_depsReady) return;
    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    nav.pushReplacement(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => _buildShellHome(),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
    _shellRoutePushed = true;
    // The shell is up, so a link held since boot can finally navigate without
    // the pushReplacement above throwing its route away.
    markAppShellReady();
    if (mounted) setState(() {});
  }

  Widget _buildHome() {
    if (_bootFailed) {
      AppLogger.instance.logError(_bootError ?? 'startup failed', _bootStack);
      return BootErrorScreen(
        details: 'Startup step: $_bootStage\n$_bootError\n\n${_bootStack ?? ''}'
            .trim(),
        onRetry: _retryBoot,
      );
    }
    if (isAppleTv) {
      // Keep ONE widget as [MaterialApp.home] for the app lifetime — changing
      // `home` from SplashScreen to RootShell does not replace the Navigator's
      // initial route on tvOS (logs show "shell visible" while splash stays up).
      return _TvBootGate(
        showShell: _tvShellGate,
        shellBuilder: _buildShellHome,
      );
    }
    return const SplashScreen();
  }

  Widget _buildMaterialApp({required bool shellFeatures}) {
    return LiquidGlassWidgets.wrap(
      child: MaterialApp(
        title: kAppName,
        theme: buildAppTheme(),
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: LocaleController.locale,
        localeResolutionCallback: (locale, supported) =>
            resolveAppLocale(locale, supported),
        scaffoldMessengerKey: shellFeatures ? rootMessengerKey : null,
        navigatorKey: rootNavigatorKey,
        navigatorObservers: [
          _themeRepaint,
          if (shellFeatures) ...[
            Analytics.observer,
            appRouteObserver,
            TvRoutePopGuardObserver(),
          ],
        ],
        home: _buildHome(),
        builder: (_, child) {
          final content = shellFeatures
              ? Stack(
                  children: [
                    ?child,
                    if (WatchTogetherController.isEnabled)
                      const Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: SafeArea(
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: PartyBar(),
                          ),
                        ),
                      ),
                  ],
                )
              : (child ?? const SizedBox.shrink());
          final isTv = sl.isRegistered<AppMode>() && sl<AppMode>().isTv;
          // Windows title bar / window chrome wraps upstream's auth overlay.
          return DesktopWindow(
            // Windows keeps its own titlebar from the splash onward, so the
            // plain OS caption never shows first (the runner starts without it).
            enableChrome: !isTv,
            child: PosterCardScope(
              // Splash-first boot draws the auth-route retry screen here
              // instead of replacing the app (never set elsewhere).
              child: _AuthRouteRetryOverlay(
                child: AuthConnectionOverlay(
                  phase: _authConnectionPhase,
                  child: isTv ? TvViewport(child: content) : content,
                ),
              ),
            ),
          );
        },
      ),
      brightnessResolver: Theme.maybeBrightnessOf,
    );
  }

  @override
  Widget build(BuildContext context) {
    final shellFeatures = isAppleTv
        ? (_tvShellGate.value && _depsReady && !_bootFailed)
        : (_shellRoutePushed && !_bootFailed);
    final app = _buildMaterialApp(shellFeatures: shellFeatures);

    if (!_depsReady) return app;

    return MultiBlocProvider(
      providers: [
        BlocProvider<ActiveSourceCubit>.value(value: sl<ActiveSourceCubit>()),
        BlocProvider<AuthCubit>.value(value: sl<AuthCubit>()),
      ],
      child: BlocListener<AuthCubit, AuthState>(
        listenWhen: (p, c) => p.status != c.status,
        listener: _onAuthChange,
        child: app,
      ),
    );
  }
}

/// Splash-first boot (Windows): the "Connection settings unavailable" screen
/// that [_selectLaunchAuthRoute] used to show with its own runApp, drawn over
/// the running app while [_authRouteRetry] holds a pending retry.
class _AuthRouteRetryOverlay extends StatelessWidget {
  const _AuthRouteRetryOverlay({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Completer<void>?>(
      valueListenable: _authRouteRetry,
      builder: (context, retry, child) {
        if (retry == null) return child!;
        return Stack(
          children: [
            // Keep the app mounted (and its boot running) underneath.
            ExcludeSemantics(child: child!),
            Positioned.fill(
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(context.l10n.connectionSettingsUnavailable),
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          context.l10n.connectToInternetTryAgain,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      FilledButton(
                        onPressed: () {
                          if (!retry.isCompleted) retry.complete();
                        },
                        child: Text(context.l10n.tryAgain),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
      child: child,
    );
  }
}

/// tvOS boot gate: always the [MaterialApp.home] route so toggling [showShell]
/// swaps children in-place instead of changing `home` (which does not replace
/// the Navigator's initial route after first paint on physical Apple TV).
class _TvBootGate extends StatelessWidget {
  const _TvBootGate({required this.showShell, required this.shellBuilder});

  final ValueListenable<bool> showShell;
  final Widget Function() shellBuilder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: showShell,
      builder: (_, visible, _) {
        if (visible) return RepaintBoundary(child: shellBuilder());
        return const SplashScreen();
      },
    );
  }
}

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:hive/hive.dart';

import '../boot_network.dart';
import '../platform/apple_tv.dart';
import '../desktop/desktop_oauth.dart';
import '../desktop/desktop_prefs.dart';
import '../privacy/incognito_mode.dart';
import 'discord_activity_watch.dart';
import 'discord_auth.dart';
import 'discord_config.dart';
import 'discord_gateway.dart';
import 'discord_sdk_gateway.dart';
import 'discord_presence.dart';
import 'discord_token_store.dart';

/// Orchestrates Discord Rich Presence: holds the Gateway connection, the opt-in
/// toggle, and builds the "watching" / "browsing" presence. Stays connected
/// through Android `paused` (the video player routinely fires that). Clears on
/// player exit, disable, incognito, or process detach.
///
/// Login is OAuth2 + PKCE in the external browser (same pattern as the MAL
/// tracker): no client secret, short-lived access token with a stored refresh
/// token, profile from /users/@me. The old WebView token scraper is gone —
/// scraping a user token breaks whenever Discord renames a webpack chunk, and
/// user tokens are one ToS complaint away from a banned account.
class DiscordRpc {
  DiscordRpc(this._dio);
  final Dio _dio;

  static const String boxName = 'discord';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  Box get _box => Hive.box(boxName);

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;
  Completer<bool>? _pendingAuth;
  bool _handlingRedirect = false;

  /// Last OAuth failure, human-readable for the settings screen to show.
  /// Null means "no error info" (e.g. the browser never came back).
  String? lastAuthError;

  DiscordGateway? _gateway;
  String? _accessToken;
  bool _enabled = false;
  bool _foreground = true;
  DiscordActivity? _current;
  int _presenceRevision = 0;
  final Map<String, String> _assetCache = {}; // posterUrl -> "mp:..." key
  Timer? _clearTimer;
  Timer? _presenceSendTimer;

  /// Android pauses (and sometimes disposes) the player when the native
  /// surface attaches. Immediate clear would wipe Watching; a short delay
  /// lets the next [setWatching] cancel it.
  static const Duration playerExitClearDelay = Duration(seconds: 2);

  // ── Windows connection upkeep ─────────────────────────────────────────────

  /// Whether the Windows-only connection rules apply (SDK transport with the
  /// raw gateway as fallback, shared refresh, retries). Phone and TV keep
  /// their own behaviour.
  static bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// Set when the SDK loaded but could not start after all; the raw gateway
  /// is used for the rest of this run of the app.
  bool _sdkUnavailable = false;

  /// The login the current gateway was last given.
  String? _gatewayToken;

  /// The refresh in flight, shared by everyone who needs one. Discord swaps
  /// the refresh token on every use, so a second one at the same time would
  /// use up a token that is already spent.
  Future<String?>? _refreshing;

  /// When the last refresh worked, and how long after it a rejected login may
  /// be refreshed again. Grows while Discord keeps rejecting fresh logins.
  DateTime? _refreshedAt;
  static const Duration _firstRefreshGap = Duration(minutes: 5);
  Duration _refreshGap = _firstRefreshGap;

  /// When the last refresh failed without ending the login (no network, a
  /// server fault). The next one waits at least [_refreshRetryGap], so window
  /// focus or a status change cannot hammer Discord.
  DateTime? _refreshFailedAt;
  static const Duration _refreshRetryGap = Duration(seconds: 10);

  /// Goes up whenever the login ends or is replaced, so the answer to an older
  /// refresh cannot bring the old login back.
  int _loginEpoch = 0;

  /// Whether [at] is less than [gap] ago. A clock that was set back counts as
  /// long ago.
  bool _within(DateTime? at, Duration gap) {
    if (at == null) return false;
    final passed = debugNow().difference(at);
    return !passed.isNegative && passed < gap;
  }

  /// The rejected-login handling in flight; a second report joins it.
  Future<void>? _authFailure;

  /// Retries connecting while there is no gateway because the login could not
  /// be refreshed (for example no network at launch).
  Timer? _connectRetry;
  static const Duration _firstConnectRetry = Duration(seconds: 30);
  Duration _connectRetryWait = _firstConnectRetry;

  /// Builds the raw gateway; tests replace it so no real socket opens.
  @visibleForTesting
  DiscordGateway Function(String token, Future<void> Function() onAuthFailure)?
  debugRawGateway;

  /// Clock, replaceable so tests can fake time.
  @visibleForTesting
  DateTime Function() debugNow = DateTime.now;

  bool get enabled => _enabled;
  bool get loggedIn => _accessToken != null && _accessToken!.isNotEmpty;

  /// Account profile from /users/@me (username, display name, avatar).
  String get username => _box.get('username', defaultValue: '') as String;
  String get displayName => _box.get('displayName', defaultValue: '') as String;
  String get avatarUrl => _box.get('avatarUrl', defaultValue: '') as String;

  /// Opt-in + credentials. Sending is not gated on Android `paused` — the
  /// player leaves Flutter paused for the whole episode.
  bool get _allowed =>
      _enabled && loggedIn && DiscordConfig.configured && !IncognitoMode.on;

  bool get _canRun => _allowed;

  String get _skipReason {
    if (!DiscordConfig.configured) return 'app id not configured';
    if (!loggedIn) return 'not logged in';
    if (!_enabled) return 'rich presence toggle off';
    if (IncognitoMode.on) return 'incognito';
    return 'ok';
  }

  /// Load persisted state + connect if everything's ready. Call at startup.
  /// Also retires any WebView-scraped user token left in secure storage: the
  /// OAuth session (Hive box) is the only credential now, and a leftover raw
  /// token must never silently keep self-botting.
  Future<void> start() async {
    _enabled = _box.get('enabled', defaultValue: false) as bool;
    _accessToken = _box.get('accessToken') as String?;
    await DiscordTokenStore.clear();
    // Incognito pauses presence: flipping it on drops the connection, off resumes.
    IncognitoMode.notifier.addListener(_onIncognitoChanged);
    debugPrint(
      '[discord] start enabled=$_enabled loggedIn=$loggedIn '
      'configured=${DiscordConfig.configured} incognito=${IncognitoMode.on} '
      'foreground=$_foreground → $_skipReason',
    );
    // Windows: start watching input and the window state so an idle or
    // minimised app stops advertising itself (track-12). Skipped under
    // `flutter test`, whose fake binding would keep its timer pending; tests
    // attach their own watch through [debugAttachActivityWatch].
    if (_showsIdlePresence &&
        !Platform.environment.containsKey('FLUTTER_TEST')) {
      debugAttachActivityWatch(
        DiscordActivityWatch(onChanged: refreshVisibility)..install(),
      );
    }
    if (_isWindows) {
      BootConnectivity.instance.offline.addListener(_onOfflineChanged);
    }
    if (_canRun) {
      unawaited(_connect());
      // Windows: show "Browsing" from launch rather than an empty profile.
      if (_current == null && _showsIdlePresence) unawaited(setBrowsing());
    }
  }

  // ── Away / "only while watching" (track-12, Windows) ──────────────────────

  /// Idle / minimised watcher; null off Windows and in tests.
  DiscordActivityWatch? _watch;

  /// The presence hidden state last pushed, so a flip sends exactly once.
  bool _sentHidden = false;

  /// Installs [watch] as the away detector (the app uses a real one; tests
  /// pass one they drive by hand). Replaces and disposes any previous one.
  @visibleForTesting
  void debugAttachActivityWatch(DiscordActivityWatch? watch) {
    if (identical(_watch, watch)) return;
    _watch?.dispose();
    _watch = watch;
  }

  /// "Only while watching" (Windows): no Browsing / Looking at status at all.
  bool get _onlyWhileWatching =>
      _showsIdlePresence && DesktopPrefs.discordOnlyWhileWatching;

  /// Whether the current presence should be hidden from Discord right now.
  /// A playing video is never hidden; a paused one counts as watching for
  /// "only while watching" but is hidden when the person is away.
  bool get presenceHidden {
    if (!_showsIdlePresence) return false;
    final kind = _lastPresenceKind;
    if (kind == _PresenceKind.playing) return false;
    if (_onlyWhileWatching && kind != _PresenceKind.paused) return true;
    final w = _watch;
    return w != null && (w.idle || w.minimised);
  }

  /// What Discord should show: the current activity, or nothing while hidden.
  DiscordActivity? get _visible => presenceHidden ? null : _current;

  /// Re-sends presence after the away state or the "only while watching"
  /// setting changed: clears it when it should be hidden, restores the kept
  /// activity when it may show again. Cheap no-op when nothing flipped.
  void refreshVisibility() {
    final hidden = presenceHidden;
    if (hidden == _sentHidden) return;
    debugPrint('[discord] presence ${hidden ? 'hidden (away)' : 'restored'}');
    if (_canRun && _gateway != null) _queuePresenceSend();
  }

  /// Windows: the network came back, so try at once instead of waiting out a
  /// retry that may be minutes away.
  void _onOfflineChanged() {
    if (!_isWindows || BootConnectivity.instance.offline.value || !_canRun) {
      return;
    }
    final g = _gateway;
    if (g != null) {
      g.retryNow();
      return;
    }
    _cancelConnectRetry();
    _refreshFailedAt = null;
    unawaited(_connect());
  }

  void _onIncognitoChanged() {
    debugPrint('[discord] incognito=${IncognitoMode.on}');
    if (_canRun) {
      unawaited(_connect());
      // Windows: nothing kept to show (incognito was already on at launch, or
      // the video was closed meanwhile), so show Browsing again. Not over a
      // paused video that "show when paused" keeps off the profile.
      if (_showsIdlePresence &&
          _current == null &&
          _lastPresenceKind != _PresenceKind.paused) {
        unawaited(setBrowsing());
      }
    } else {
      unawaited(_disconnect());
    }
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await _box.put('enabled', value);
    debugPrint('[discord] setEnabled $value');
    if (_canRun) {
      _refreshFailedAt = null; // the person asked: try at once
      unawaited(_connect(restartStopped: true));
      // Windows: turning presence on from Settings should show something on
      // the profile straight away, not only after the next title page.
      if (value && _current == null && _showsIdlePresence) {
        unawaited(setBrowsing());
      }
    } else {
      if (!value) _current = null;
      unawaited(_disconnect());
    }
  }

  /// Desktop shows a plain "Browsing" activity whenever nothing more specific
  /// is set; phone/TV keep their original event-driven behaviour.
  bool get _showsIdlePresence =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  // ── OAuth login ─────────────────────────────────────────────────────────
  // Browser flow (external application, never a WebView): the
  // discord-<appId>:/authorize/callback redirect comes back through the
  // manifest intent-filter into [_onLink], like the tracker OAuth logins.

  void _ensureLinkListener() {
    if (_linkSub != null || isAppleTv) return;
    _linkSub = _appLinks.uriLinkStream.listen(_onLink, onError: (_) {});
    _appLinks
        .getInitialLink()
        .then((u) {
          if (u != null) _onLink(u);
        })
        .catchError((_) {});
  }

  String _random(int len) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(len, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// Launch that never throws: some resolvers raise instead of returning
  /// false when nothing handles the URL.
  Future<bool> _tryLaunch(Uri url, LaunchMode mode) async {
    try {
      return await launchUrl(url, mode: mode);
    } catch (e) {
      debugPrint('[discord] launch ($mode) threw: $e');
      return false;
    }
  }

  /// Browser OAuth login. True when the session (tokens + profile) is stored.
  /// On false, [lastAuthError] says why (redirect mismatch, denied, timeout).
  Future<bool> connect() async {
    final active = _pendingAuth;
    if (active != null) return active.future;
    final pending = Completer<bool>();
    _pendingAuth = pending;
    lastAuthError = null;
    try {
      _ensureLinkListener();
      final verifier = _random(64);
      final state = _random(32);
      await _box.put('codeVerifier', verifier);
      await _box.put('oauthState', state);
      final url = DiscordAuth.authorizeUri(
        applicationId: DiscordConfig.applicationId,
        state: state,
        challenge: DiscordAuth.codeChallenge(verifier),
      );
      // Windows: the browser can only hand discord-<appId>:/authorize/callback
      // back to us once that scheme points at this exe (Android/iOS declare
      // it in the manifest/plist instead).
      final callbackError = await DesktopOAuth.ensureBrowserCallback(
        scheme: DiscordAuth.redirectScheme(DiscordConfig.applicationId),
      );
      if (callbackError != null) {
        lastAuthError = callbackError;
        return false;
      }
      // Discord's Android app handles its action URI, not the web OAuth path.
      var opened = false;
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        opened = await _tryLaunch(
          DiscordAuth.nativeAuthorizeUri(url),
          LaunchMode.externalApplication,
        ).timeout(const Duration(seconds: 10), onTimeout: () => false);
      }
      opened =
          opened ||
          await _tryLaunch(
            url,
            LaunchMode.externalApplication,
          ).timeout(const Duration(seconds: 10), onTimeout: () => false);
      if (!opened) {
        lastAuthError = 'Could not open Discord or the browser.';
        return false;
      }
      // The redirect can arrive before launchUrl finishes; retain this future.
      return await pending.future.timeout(const Duration(minutes: 3));
    } on TimeoutException {
      lastAuthError = DesktopOAuth.usesRegisteredCallback
          ? DesktopOAuth.noCallbackMessage('Discord')
          : 'Discord login timed out. Please try connecting again.';
      return false;
    } catch (_) {
      lastAuthError ??= 'Could not start Discord login. Please try again.';
      return false;
    } finally {
      if (identical(_pendingAuth, pending)) {
        await _box.delete('codeVerifier');
        await _box.delete('oauthState');
        _pendingAuth = null;
      }
      if (!pending.isCompleted) pending.complete(false);
    }
  }

  /// Abandons a browser login still waiting for its redirect; [connect] then
  /// returns false and clears the stored verifier/state so a late callback
  /// is ignored.
  void cancelConnect() {
    final pending = _pendingAuth;
    if (pending == null || pending.isCompleted || _handlingRedirect) return;
    lastAuthError = 'Discord login cancelled.';
    pending.complete(false);
  }

  void _onLink(Uri uri) {
    if (!DiscordAuth.isCallback(uri, DiscordConfig.applicationId)) return;
    unawaited(_handleRedirect(uri));
  }

  Future<void> _handleRedirect(Uri uri) async {
    // Ignore unrelated/stale links without cancelling the current login.
    final state = uri.queryParameters['state'];
    final saved = _box.get('oauthState') as String?;
    if (_handlingRedirect || state == null || saved == null || state != saved) {
      return;
    }
    _handlingRedirect = true;
    final pending = _pendingAuth;
    var ok = false;
    try {
      final error = uri.queryParameters['error'];
      if (error != null) {
        throw StateError(uri.queryParameters['error_description'] ?? error);
      }
      final code = uri.queryParameters['code'];
      if (code == null || code.isEmpty) {
        throw StateError('No authorization code received.');
      }
      final verifier = _box.get('codeVerifier') as String?;
      if (verifier == null || verifier.isEmpty) {
        throw StateError('Login expired. Please try again.');
      }
      ok = await _exchangeCode(code, verifier);
      if (!ok) {
        lastAuthError ??= 'Discord could not complete login. Please try again.';
      }
    } catch (e) {
      lastAuthError = '$e'.replaceFirst('Bad state: ', '');
    } finally {
      _handlingRedirect = false;
      if (pending != null && !pending.isCompleted) pending.complete(ok);
    }
  }

  Future<bool> _exchangeCode(String code, String verifier) async {
    try {
      final res = await _dio.post<dynamic>(
        DiscordAuth.tokenEndpoint,
        data: {
          'client_id': DiscordConfig.applicationId,
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': DiscordAuth.redirectUri(DiscordConfig.applicationId),
          'code_verifier': verifier,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final d = res.data;
      if (d is! Map || d['access_token'] == null) {
        final error = d is Map ? d['error'] : null;
        lastAuthError = error == 'invalid_client'
            ? 'Discord app setup is incomplete. Enable Public Client in its OAuth2 settings.'
            : 'Discord could not complete login (HTTP ${res.statusCode}${error == null ? '' : ': $error'}).';
        return false;
      }
      _loginEpoch++; // a refresh of the previous login no longer counts
      await _storeSession(d);
      await _fetchAccount();
      _accessToken = _box.get('accessToken') as String?;
      debugPrint('[discord] oauth login stored');
      if (_canRun) unawaited(_connect(restartStopped: true));
      return true;
    } catch (e) {
      debugPrint('[discord] code exchange failed: $e');
      return false;
    }
  }

  Future<void> _storeSession(Map<dynamic, dynamic> d) async {
    if (_isWindows) {
      await _storeSessionAtOnce(d);
      return;
    }
    await _box.put('accessToken', '${d['access_token']}');
    final refresh = d['refresh_token'];
    if (refresh != null && '$refresh'.isNotEmpty) {
      await _box.put('refreshToken', '$refresh');
    }
    final expiresIn = (d['expires_in'] as num?)?.toInt() ?? 0;
    await _box.put(
      'expiresAt',
      expiresIn > 0
          ? DateTime.now().millisecondsSinceEpoch + expiresIn * 1000
          : 0,
    );
  }

  /// Windows: the same values in a single write, which takes effect before this
  /// returns its future. A sign-out or a new login can come before or after it,
  /// but never in the middle.
  Future<void> _storeSessionAtOnce(Map<dynamic, dynamic> d) {
    final refresh = d['refresh_token'];
    final expiresIn = (d['expires_in'] as num?)?.toInt() ?? 0;
    _refreshFailedAt = null;
    return _box.putAll({
      'accessToken': '${d['access_token']}',
      if (refresh != null && '$refresh'.isNotEmpty) 'refreshToken': '$refresh',
      'expiresAt': expiresIn > 0
          ? DateTime.now().millisecondsSinceEpoch + expiresIn * 1000
          : 0,
    });
  }

  /// A valid access token, refreshing first when it expires within 60s. This
  /// is what makes login survive: Discord access tokens live ~7 days, and the
  /// user never sees a re-login unless the refresh token itself dies.
  Future<String?> getValidAccessToken() async {
    var token = _accessToken ?? _box.get('accessToken') as String?;
    if (token == null || token.isEmpty) return null;
    final exp = (_box.get('expiresAt') as int?) ?? 0;
    if (exp == 0 || DateTime.now().millisecondsSinceEpoch < exp - 60000) {
      _accessToken = token;
      return token;
    }
    return _refreshNow();
  }

  /// Force a refresh (gateway invalid-session, or expiry). Null when the
  /// session is dead — the caller logs out and the settings show login again.
  Future<String?> _refreshNow() {
    if (!_isWindows) return _refreshOnce();
    // Windows: one refresh at a time, shared by expiry and a rejected login.
    final running = _refreshing;
    if (running != null) return running;
    if (_within(_refreshFailedAt, _refreshRetryGap)) {
      return Future<String?>.value();
    }
    return _refreshing = _refreshOnce().whenComplete(() {
      _refreshing = null;
    });
  }

  Future<String?> _refreshOnce() async {
    final refresh = _box.get('refreshToken') as String?;
    if (refresh == null || refresh.isEmpty) {
      if (_isWindows) await _loginDead('no refresh possible');
      return null;
    }
    final epoch = _loginEpoch;
    try {
      final res = await _dio.post<dynamic>(
        DiscordAuth.tokenEndpoint,
        data: {
          'client_id': DiscordConfig.applicationId,
          'grant_type': 'refresh_token',
          'refresh_token': refresh,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final d = res.data;
      if (_isWindows &&
          (epoch != _loginEpoch || _box.get('refreshToken') != refresh)) {
        // Signed out (or in again) while waiting: this answer belongs to a
        // login that is gone and must not bring it back.
        debugPrint('[discord] login changed during refresh — ignored');
        return _accessToken;
      }
      if (d is! Map || d['access_token'] == null) {
        if (_isWindows) {
          final error = d is Map ? d['error'] : null;
          if (error == 'invalid_grant') {
            await _loginDead('invalid_grant');
          } else {
            debugPrint(
              '[discord] login refresh refused (HTTP ${res.statusCode}) — '
              'kept, trying again later',
            );
            _refreshFailedAt = debugNow();
          }
        }
        return null;
      }
      await _storeSession(d);
      // Signed out while this was being saved: the box is empty again, and so
      // is the login.
      _accessToken = _box.get('accessToken') as String?;
      if (_isWindows && epoch != _loginEpoch) return _accessToken;
      _refreshedAt = debugNow();
      debugPrint('[discord] login refreshed');
      return _accessToken;
    } catch (e) {
      debugPrint('[discord] refresh failed: $e');
      if (_isWindows && epoch == _loginEpoch) _refreshFailedAt = debugNow();
      return null;
    }
  }

  /// Windows: Discord will never accept this login again, so sign out and let
  /// the settings offer a new one. Nothing else (no network, a server fault,
  /// a rate limit) may end a login.
  Future<void> _loginDead(String why) async {
    debugPrint('[discord] login is no longer valid ($why) — signing out');
    await logout();
  }

  Future<void> _fetchAccount() async {
    final token = _box.get('accessToken') as String?;
    if (token == null || token.isEmpty) return;
    try {
      final res = await _dio.get<dynamic>(
        DiscordAuth.meEndpoint,
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final d = res.data;
      if (d is! Map) return;
      final id = '${d['id'] ?? ''}';
      final username = '${d['username'] ?? ''}';
      final display = '${d['global_name'] ?? d['username'] ?? ''}';
      await _box.put('username', username);
      await _box.put('displayName', display);
      await _box.put(
        'avatarUrl',
        DiscordAuth.avatarUrl(id, d['avatar'] as String?) ?? '',
      );
    } catch (e) {
      debugPrint('[discord] profile fetch failed: $e');
    }
  }

  /// Log out: drop the session + tokens and disconnect. The account is
  /// untouched — reconnecting is one browser tap.
  Future<void> logout() async {
    const keys = [
      'accessToken',
      'refreshToken',
      'expiresAt',
      'username',
      'displayName',
      'avatarUrl',
    ];
    Future<void>? gone;
    if (_isWindows) {
      // All of it at once, before anything else: a refresh answer that arrives
      // during the waits below finds the login gone and is ignored.
      _loginEpoch++;
      _accessToken = null;
      gone = _box.deleteAll(keys);
    }
    await setEnabled(false);
    if (gone != null) {
      await gone;
    } else {
      for (final k in keys) {
        await _box.delete(k);
      }
    }
    _accessToken = null;
    _current = null;
    _gatewayToken = null;
    _refreshedAt = null;
    _refreshGap = _firstRefreshGap;
    _refreshFailedAt = null;
    _cancelConnectRetry();
    debugPrint('[discord] logged out');
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  void onForeground() {
    _foreground = true;
    debugPrint('[discord] foreground');
    if (_canRun) unawaited(_connect());
    // Windows: the person is back, so do not sit out a long retry wait.
    if (_canRun && _isWindows) _gateway?.retryNow();
  }

  /// Flutter `paused` — keep the gateway. Native video surfaces trigger this
  /// for the entire playback session; clearing here made Watching vanish.
  void onPaused() {
    debugPrint('[discord] lifecycle paused — keeping gateway + presence');
  }

  /// Process is going away — flush an empty activity so the profile drops.
  void onDetached() {
    _foreground = false;
    debugPrint('[discord] detached — clearing presence + disconnect');
    unawaited(_disconnect());
  }

  // ── Presence ──────────────────────────────────────────────────────────────
  // Defaults keep the existing watching and browsing text.

  String get nameSrc => _box.get('nameSrc', defaultValue: 'title') as String;
  String get detailsSrc =>
      _box.get('detailsSrc', defaultValue: 'episode') as String;
  String get stateSrc => _box.get('stateSrc', defaultValue: 'app') as String;
  static const presenceStatuses = {'online', 'idle', 'dnd', 'invisible'};

  String get presenceStatus {
    final value = _box.get('presenceStatus', defaultValue: 'online');
    return presenceStatuses.contains(value) ? value as String : 'online';
  }

  String get largeImageSrc =>
      _box.get('largeImage', defaultValue: 'poster') as String;
  String get smallImageSrc =>
      _box.get('smallImage', defaultValue: 'logo') as String;
  bool get showPresenceButton =>
      _box.get('showButton', defaultValue: true) as bool;
  String get presenceButtonLabel =>
      _box.get('buttonLabel', defaultValue: '') as String;
  bool get showWhenPaused => _box.get('showPaused', defaultValue: true) as bool;
  bool get browsingShowsTitle =>
      _box.get('browsingTitle', defaultValue: true) as bool;

  Future<void> setPresencePref(String key, Object value) async {
    if (key == 'presenceStatus' && !presenceStatuses.contains(value)) {
      throw ArgumentError.value(value, key, 'Unknown Discord status');
    }
    await _box.put(key, value);
    if (key == 'presenceStatus' && _canRun) _queuePresenceSend();
    // Windows: make the visible presence follow the toggle at once instead of
    // waiting for the next title page or player event. Phone and TV keep
    // their event-driven behaviour.
    final replay = _lastPresence;
    if (_isWindows &&
        replay != null &&
        ((key == 'showPaused' && _lastPresenceKind == _PresenceKind.paused) ||
            (key == 'browsingTitle' &&
                _lastPresenceKind == _PresenceKind.browsing))) {
      await replay();
    }
  }

  /// Last presence request, replayed when a preference that shapes it changes.
  /// Only browsing and paused watching are replayed: their content is static,
  /// whereas a playing call carries a position that is already stale.
  Future<void> Function()? _lastPresence;
  _PresenceKind? _lastPresenceKind;

  void _rememberPresence(Future<void> Function() replay, _PresenceKind kind) {
    _lastPresence = replay;
    _lastPresenceKind = kind;
  }

  Future<void> setWatching({
    required String title,
    String? episodeLabel,
    String? posterUrl,
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
    bool playing = true,
    // https open link for the "Open in Zangetsu" button (ShareLink.watchUrl).
    // Null omits the button — same payload as before.
    String? openUrl,
  }) async {
    // Remember this call so a settings toggle can re-render it (see above).
    // A playing one is only replayed when Windows swaps the transport; the
    // video has moved on since, so its position does too.
    final asked = debugNow();
    Future<void> replay() => setWatching(
      title: title,
      episodeLabel: episodeLabel,
      posterUrl: posterUrl,
      position: playing ? position + debugNow().difference(asked) : position,
      duration: duration,
      playing: playing,
      openUrl: openUrl,
    );
    if (!_allowed) {
      return;
    }
    if (!playing && !showWhenPaused) {
      clear();
      _rememberPresence(replay, _PresenceKind.paused);
      return;
    }
    _rememberPresence(
      replay,
      playing ? _PresenceKind.playing : _PresenceKind.paused,
    );
    _cancelScheduledClear();
    final revision = ++_presenceRevision;
    final ts = discordPlaybackTimestamps(
      position: position,
      duration: duration,
      playing: playing,
    );
    final large = await _resolveLarge(posterUrl);
    final logo = await _appLogoKey();
    if (revision != _presenceRevision || !_allowed) return;
    final details = (episodeLabel == null && detailsSrc == 'episode')
        ? null
        : discordSourceLine(
            detailsSrc,
            title: title,
            episode: episodeLabel,
            appText: DiscordConfig.appName,
          );
    var buttonLabel = presenceButtonLabel;
    if (buttonLabel.isEmpty) buttonLabel = 'Open in Zangetsu';
    _current = DiscordActivity(
      name: discordSourceLine(
        nameSrc,
        title: title,
        episode: episodeLabel,
        appText: DiscordConfig.appName,
      ),
      type: 3, // Watching
      details: details,
      state: discordSourceLine(
        stateSrc,
        title: title,
        episode: episodeLabel,
        appText: 'on ${DiscordConfig.appName}',
      ),
      largeImage: large,
      largeText: title,
      smallImage: smallImageSrc == 'logo' && large != null ? logo : null,
      smallText: 'Watching on ${DiscordConfig.appName}',
      startMs: ts.startMs,
      endMs: ts.endMs,
      buttons: showPresenceButton && openUrl != null
          ? [(label: buttonLabel, url: openUrl)]
          : const [],
    );
    debugPrint(
      '[discord] setWatching "$title" ${episodeLabel ?? ''} '
      'playing=$playing pos=${position.inSeconds}s dur=${duration.inSeconds}s '
      'bar=${ts.startMs != null && ts.endMs != null}'
      '${duration <= Duration.zero ? " (end=null until duration known)" : ""} '
      'openUrl=${openUrl != null} '
      'gateway=${_gateway != null} readySend=$_canRun',
    );
    if (_canRun) {
      _queuePresenceSend();
    } else {
      debugPrint('[discord] setWatching held, not sent ($_skipReason)');
    }
  }

  Future<void> setBrowsing({String? title, String? posterUrl}) async {
    if (!_allowed) {
      debugPrint('[discord] setBrowsing skipped ($_skipReason)');
      return;
    }
    _rememberPresence(
      () => setBrowsing(title: title, posterUrl: posterUrl),
      _PresenceKind.browsing,
    );
    _cancelScheduledClear();
    final revision = ++_presenceRevision;
    final large = await _resolveLarge(posterUrl);
    final logo = await _appLogoKey();
    if (revision != _presenceRevision || !_allowed) return;
    _current = DiscordActivity(
      name: DiscordConfig.appName,
      type: 0, // Playing → "Playing Zangetsu"
      details: (browsingShowsTitle && title != null)
          ? 'Looking at $title'
          : 'Browsing',
      largeImage: large,
      largeText: title ?? DiscordConfig.appName,
      smallImage: smallImageSrc == 'logo' && large != null ? logo : null,
    );
    debugPrint(
      '[discord] setBrowsing ${title ?? "(app)"} image=${_current!.largeImage} '
      'gateway=${_gateway != null} send=$_canRun',
    );
    if (_canRun) {
      _queuePresenceSend();
    } else {
      debugPrint('[discord] setBrowsing held, not sent ($_skipReason)');
    }
  }

  /// Discord drops status updates that arrive too close together. A Watching
  /// line with no duration (end=null) followed ~1s later by the real bar would
  /// leave the profile stuck without a progress bar.
  void _queuePresenceSend() {
    _presenceSendTimer?.cancel();
    _presenceSendTimer = Timer(const Duration(milliseconds: 400), () {
      if (_canRun) _pushVisible();
    });
  }

  /// Sends [_visible] (nothing while away / not watching on Windows) and
  /// remembers which state was sent for [refreshVisibility].
  void _pushVisible() {
    final g = _gateway;
    if (g == null) return;
    _sentHidden = presenceHidden;
    g.setPresence(_visible, status: presenceStatus);
  }

  /// Drop the current activity. [delay] is for player teardown: Android
  /// disposes the player on `paused`, then immediately rebuilds it — a new
  /// [setWatching] cancels the timer so Watching survives. A real exit
  /// (no follow-up presence) still clears after the delay.
  void clear({Duration delay = Duration.zero}) {
    _presenceRevision++;
    _lastPresence = null;
    _lastPresenceKind = null;
    _clearTimer?.cancel();
    if (delay <= Duration.zero) {
      _applyClear();
      return;
    }
    debugPrint('[discord] clear scheduled in ${delay.inMilliseconds}ms');
    _clearTimer = Timer(delay, () {
      _applyClear();
      // Windows: after leaving the player, fall back to Browsing instead of
      // an empty profile. The usual rules (incognito, away, only while
      // watching) still decide whether it shows.
      if (_isWindows && _allowed) unawaited(setBrowsing());
    });
  }

  void _cancelScheduledClear() {
    if (_clearTimer == null) return;
    debugPrint('[discord] clear cancelled (new presence)');
    _clearTimer!.cancel();
    _clearTimer = null;
  }

  void _applyClear() {
    _clearTimer = null;
    _presenceSendTimer?.cancel();
    _presenceSendTimer = null;
    debugPrint('[discord] clear presence gateway=${_gateway != null}');
    _current = null;
    _gateway?.setPresence(null, status: presenceStatus);
  }

  // ── Internals ───────────────────────────────────────────────────────────
  /// [restartStopped]: a settings change (toggle, fresh login) replaces a
  /// Windows gateway that stopped retrying after repeated failures, so the
  /// person gets a new attempt; other callers leave it stopped.
  Future<void> _connect({bool restartStopped = false}) async {
    final stopped = _gateway;
    if (restartStopped && stopped != null && stopped.gaveUp) {
      debugPrint('[discord] settings changed — retrying stopped gateway');
      _gateway = null;
      await stopped.close();
      if (_isWindows && !_canRun) return;
    }
    if (_gateway != null) {
      debugPrint(
        '[discord] already connected — re-push current=${_current?.name}',
      );
      _presenceSendTimer?.cancel();
      _pushVisible();
      return;
    }
    final token = await getValidAccessToken();
    if (token == null || token.isEmpty) {
      debugPrint('[discord] connect skipped (no valid token)');
      _scheduleConnectRetry();
      return;
    }
    if (_isWindows) {
      await _connectWindows(token);
      return;
    }
    debugPrint('[discord] connecting gateway');
    _gateway =
        (supportsNativeDiscordPresence
              ? DiscordSdkGateway(token, onAuthFailure: _onAuthFailure)
              : DiscordGateway('Bearer $token', onAuthFailure: _onAuthFailure))
          ..connect();
    _pushVisible();
  }

  /// Windows: the Social SDK when this build and PC can use it, else the raw
  /// gateway. Everything may have changed during the waits before this (a
  /// second connect finished first, incognito, sign-out, a new login), so it
  /// is checked again with no wait between the check and the new gateway.
  Future<void> _connectWindows(String token) async {
    if (!_canRun) return;
    final sdk = await _usesSdk();
    if (_gateway != null || !_canRun) return;
    if (token != _accessToken) {
      // Another login took over while waiting; connect with that one soon.
      _scheduleConnectRetry();
      return;
    }
    _cancelConnectRetry();
    debugPrint('[discord] connecting gateway (${sdk ? 'SDK' : 'raw'})');
    // Log which scopes this saved login really has, once per connect, so a
    // login without the presence scope shows up in the log instead of only as
    // gateway close codes. Never blocks or logs out.
    unawaited(_logGrantedScopes(token));
    _gatewayToken = token;
    final DiscordGateway gateway;
    if (sdk) {
      late final DiscordSdkGateway native;
      native = DiscordSdkGateway(
        token,
        onAuthFailure: _onAuthFailure,
        onUnavailable: () => _onSdkUnavailable(native),
      );
      gateway = native;
    } else {
      final bearer = 'Bearer $token';
      gateway =
          debugRawGateway?.call(bearer, _onAuthFailure) ??
          DiscordGateway(bearer, onAuthFailure: _onAuthFailure);
    }
    _gateway = gateway..connect();
    _pushVisible();
  }

  /// Which transport the presence goes through. On Windows the running
  /// gateway decides; without one the native side is asked (once).
  Future<bool> _usesSdk() async {
    if (!_isWindows) return supportsNativeDiscordPresence;
    final g = _gateway;
    if (g != null) return g is DiscordSdkGateway;
    if (_sdkUnavailable) return false;
    return DiscordSdkGateway.isAvailable();
  }

  /// Windows: the SDK could not start. Use the raw gateway from here on, and
  /// build the presence again because the raw one needs other image keys.
  void _onSdkUnavailable(DiscordSdkGateway gateway) {
    _sdkUnavailable = true;
    if (!identical(_gateway, gateway)) return;
    debugPrint('[discord] SDK could not start — using the raw gateway');
    _gateway = null;
    unawaited(gateway.close());
    unawaited(_connectAfterSdk());
  }

  Future<void> _connectAfterSdk() async {
    if (_canRun) await _connect();
    if (_canRun) await _lastPresence?.call();
  }

  /// Windows: no gateway because there is no usable login right now. Tries
  /// again after 30s, doubling to 5 minutes.
  void _scheduleConnectRetry() {
    if (!_isWindows || !_canRun || _gateway != null) return;
    // An attempt in between (the window was focused) neither restarts nor
    // lengthens the wait that is already running.
    if (_connectRetry != null) return;
    final wait = _connectRetryWait;
    final next = wait * 2;
    const longest = Duration(minutes: 5);
    _connectRetryWait = next > longest ? longest : next;
    debugPrint('[discord] connect again in ${wait.inSeconds}s');
    _connectRetry = Timer(wait, () {
      _connectRetry = null;
      if (_canRun && _gateway == null) unawaited(_connect());
    });
  }

  void _cancelConnectRetry() {
    _connectRetry?.cancel();
    _connectRetry = null;
    _connectRetryWait = _firstConnectRetry;
  }

  /// Windows diagnostics: asks Discord which scopes [token] carries
  /// (`GET /oauth2/@me`) and logs them. The token itself is never logged.
  /// A missing `sdk.social_layer_presence` is only reported; the user is
  /// not signed out, so existing logins keep working as before.
  Future<void> _logGrantedScopes(String token) async {
    try {
      final res = await _dio.get<dynamic>(
        'https://discord.com/api/oauth2/@me',
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final d = res.data;
      final scopes = d is Map && d['scopes'] is List
          ? (d['scopes'] as List).map((e) => '$e').toList()
          : const <String>[];
      debugPrint(
        '[discord] login scopes (HTTP ${res.statusCode}): ${scopes.join(' ')}',
      );
      if (res.statusCode == 200 &&
          !scopes.contains('sdk.social_layer_presence')) {
        debugPrint(
          '[discord] login lacks sdk.social_layer_presence — presence needs '
          'a new Discord login',
        );
      }
    } catch (e) {
      debugPrint('[discord] scope check failed: $e');
    }
  }

  /// Gateway rejected the session (op 9): refresh once and resume on the same
  /// socket; a dead refresh token means logout and the settings show login.
  Future<void> _onAuthFailure() {
    if (!_isWindows) return _refreshAfterReject();
    // Windows: the SDK can report one bad login several times in a row.
    return _authFailure ??= _onWindowsAuthFailure().whenComplete(() {
      _authFailure = null;
    });
  }

  /// Windows: refresh at most once per 5 minutes, and less often (down to once
  /// an hour) while Discord keeps rejecting what it just issued. Such a login
  /// is not fixed by another one, and it is never a reason to sign out; the
  /// gateway keeps its own growing waits.
  Future<void> _onWindowsAuthFailure() async {
    if (_gateway == null) return; // a gateway on its way out
    if (_within(_refreshedAt, _refreshGap)) {
      final current = _accessToken;
      if (current != null && current.isNotEmpty && current != _gatewayToken) {
        // Refreshed elsewhere, but this gateway still uses the old login.
        _gatewayToken = current;
        _gateway?.updateToken('Bearer $current');
        return;
      }
      debugPrint(
        '[discord] login rejected again right after a refresh — waiting',
      );
      return;
    }
    debugPrint('[discord] login rejected — refreshing');
    // A dead login signs out inside the refresh; anything else keeps it.
    // Rejected again within two hours of a refresh: the same trouble goes on.
    final again = _within(_refreshedAt, const Duration(hours: 2));
    final token = await _refreshNow();
    if (token == null || token.isEmpty) return;
    const longest = Duration(hours: 1);
    final longer = _refreshGap * 2;
    _refreshGap = !again
        ? _firstRefreshGap
        : (longer > longest ? longest : longer);
    _gatewayToken = token;
    _gateway?.updateToken('Bearer $token');
  }

  Future<void> _refreshAfterReject() async {
    debugPrint('[discord] login rejected — refreshing');
    final token = await _refreshNow();
    if (token == null || token.isEmpty) {
      debugPrint('[discord] refresh dead — logging out');
      await logout();
      return;
    }
    _gateway?.updateToken('Bearer $token');
  }

  Future<void> _disconnect() async {
    _presenceRevision++;
    _cancelConnectRetry();
    // Windows: a clear still waiting after leaving the player takes effect now.
    // Only cancelling it would bring the closed video back on the profile when
    // presence resumes (incognito off again).
    if (_isWindows && _clearTimer != null) _current = null;
    final g = _gateway;
    _gateway = null;
    if (g == null) return;
    _cancelScheduledClear();
    _presenceSendTimer?.cancel();
    _presenceSendTimer = null;
    debugPrint('[discord] disconnect (flush clear first)');
    await g.clearThenClose();
  }

  /// Large image per the user's choice: the poster via external-assets, the
  /// app logo, or nothing. Unconfigured values fall back to the old behavior
  /// (poster, else logo) so an update never blanks existing presence.
  Future<String?> _resolveLarge(String? posterUrl) async {
    final src = largeImageSrc;
    if (src == 'off') return null;
    if (src == 'logo' || posterUrl == null) return _appLogoKey();
    return await _externalAsset(posterUrl) ?? await _appLogoKey();
  }

  /// App logo as a Discord-displayable image key (proxied URL, not the
  /// named `logo` portal asset — that one isn't uploaded, so Discord shows ?).
  Future<String> _appLogoKey() async {
    final key = await _externalAsset(DiscordConfig.appLogoUrl);
    return key ?? DiscordConfig.appLogoUrl;
  }

  /// Convert a poster URL into a Discord-displayable `mp:external/...` key via
  /// the external-assets API (so the real cover shows). Cached per URL.
  Future<String?> _externalAsset(String url) async {
    // The native SDK resolves artwork URLs itself.
    if (supportsNativeDiscordPresence) return url;
    if (_isWindows) {
      // Nothing is loaded or asked once the presence may not run. A cover
      // saved on this PC (downloaded shows) means nothing to Discord either
      // way; null brings the app logo.
      if (!_allowed || !discordIsWebUrl(url)) return null;
      if (await _usesSdk()) return discordSdkImageOk(url) ? url : null;
      if (!_allowed) return null;
    }
    final cached = _assetCache[url];
    if (cached != null) return cached;
    final token = await getValidAccessToken();
    if (token == null || token.isEmpty || !DiscordConfig.configured) {
      return null;
    }
    try {
      final r = await _dio.post<dynamic>(
        '${DiscordConfig.api}/applications/${DiscordConfig.applicationId}/external-assets',
        data: {
          'urls': [url],
        },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final list = r.data as List<dynamic>;
      final path = (list.first as Map)['external_asset_path'] as String;
      final key = 'mp:$path';
      _assetCache[url] = key;
      return key;
    } catch (e) {
      debugPrint('[discord] external asset failed: $e');
      return null; // fall back to the app logo
    }
  }
}

/// What the last presence request showed; decides whether a preference
/// change can safely replay it (see [DiscordRpc.setPresencePref]).
enum _PresenceKind { browsing, playing, paused }

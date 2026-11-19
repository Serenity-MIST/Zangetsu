import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../logging/app_logger.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../ui/desktop_docked_panel.dart';
import '../ui/global_messenger.dart';
import '../../l10n/l10n.dart';

/// One extension, plugin or engine that could not be loaded on Windows.
@immutable
class ExtensionLoadFailure {
  const ExtensionLoadFailure({
    required this.ecosystem,
    required this.name,
    required this.message,
  });

  /// Which system it belongs to, e.g. 'CloudStream', 'Aniyomi', 'Mihon' or
  /// 'Extension engine'. Retry handlers are registered per ecosystem.
  final String ecosystem;

  /// What failed: a plugin id, an extension folder or the engine itself.
  final String name;

  /// Short reason shown under the name.
  final String message;

  /// Same ecosystem + name means the same failure (a newer report replaces).
  String get key => '$ecosystem|$name';
}

/// Collects Windows extension/plugin load failures and shows a one-time
/// notice after startup that lists them, with Retry. Before this, failures
/// only reached debugPrint or a log file, so sources silently vanished.
abstract final class ExtensionLoadFailures {
  /// Current failures, newest last. Listen to rebuild a list.
  static final ValueNotifier<List<ExtensionLoadFailure>> failures =
      ValueNotifier(const []);

  /// Retry handlers by ecosystem; each reloads what failed for that system.
  static final Map<String, Future<void> Function()> _retries = {};

  /// The startup notice is shown at most once per app session.
  static bool _noticeShown = false;

  /// Pending timer that gathers failures before the notice shows, so a burst
  /// of plugin failures becomes one notice instead of several.
  static Timer? _noticeTimer;

  /// Test hook: replaces the real notice so tests need no app shell.
  @visibleForTesting
  static void Function(List<ExtensionLoadFailure> failures)? debugShowNotice;

  /// Records [failure] (replacing an older one with the same key), logs it
  /// and schedules the startup notice.
  static void report(ExtensionLoadFailure failure) {
    AppLogger.instance.log(
      '[extensions] ${failure.ecosystem} failed to load ${failure.name}: '
      '${failure.message}',
      level: 'W',
    );
    failures.value = [
      for (final f in failures.value)
        if (f.key != failure.key) f,
      failure,
    ];
    _scheduleNotice();
  }

  /// Drops failures of [ecosystem] (optionally only [name]), e.g. after a
  /// successful retry or reload.
  static void clear(String ecosystem, {String? name}) {
    final next = [
      for (final f in failures.value)
        if (f.ecosystem != ecosystem || (name != null && f.name != name)) f,
    ];
    if (next.length != failures.value.length) failures.value = next;
  }

  /// Registers how to retry [ecosystem]'s failed loads.
  static void registerRetry(String ecosystem, Future<void> Function() retry) =>
      _retries[ecosystem] = retry;

  /// Runs every retry handler whose ecosystem currently has failures. A
  /// handler clears what it fixed and re-reports what still fails.
  static Future<void> retryAll() async {
    final ecosystems = {for (final f in failures.value) f.ecosystem};
    for (final ecosystem in ecosystems) {
      final retry = _retries[ecosystem];
      if (retry == null) continue;
      try {
        await retry();
      } catch (error) {
        AppLogger.instance.log(
          '[extensions] retry for $ecosystem failed: $error',
          level: 'W',
        );
      }
    }
  }

  /// Clears all state between tests.
  @visibleForTesting
  static void debugReset() {
    _noticeTimer?.cancel();
    _noticeTimer = null;
    _noticeShown = false;
    _retries.clear();
    failures.value = const [];
    debugShowNotice = null;
  }

  /// How long failures are gathered before the notice appears.
  @visibleForTesting
  static Duration noticeDelay = const Duration(seconds: 4);

  /// Shows the notice once, a moment after the shell is up. Windows only:
  /// other platforms keep their existing (silent) behaviour.
  static void _scheduleNotice() {
    if (_noticeShown || _noticeTimer != null) return;
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    _noticeTimer = Timer(noticeDelay, () async {
      _noticeTimer = null;
      final hook = debugShowNotice;
      if (hook == null) {
        // Wait for the real shell so the notice is not lost behind splash.
        await appShellReady;
      }
      final current = failures.value;
      if (_noticeShown || current.isEmpty) return;
      _noticeShown = true;
      if (hook != null) {
        hook(current);
      } else {
        _showSnack(current.length);
      }
    });
  }

  /// Bottom toast with a Details action that opens the full list.
  static void _showSnack(int count) {
    final messenger = rootMessengerKey.currentState;
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 10),
        content: Text(
          appL10n.extensionsFailedToLoad(count),
        ),
        action: SnackBarAction(
          label: appL10n.details,
          onPressed: () {
            final context = rootNavigatorKey.currentContext;
            if (context != null) unawaited(showExtensionLoadFailures(context));
          },
        ),
      ),
    );
  }
}

/// Centred graphite list of every current load failure with Retry. Also
/// usable from a screen (e.g. the providers hub) to show the details again.
Future<void> showExtensionLoadFailures(BuildContext context) =>
    showDesktopDockedPanel<void>(
      context,
      centred: true,
      width: 520,
      dialogKey: const ValueKey('extension-load-failures'),
      builder: (_) => const _FailureList(),
    );

/// Body of [showExtensionLoadFailures]; rebuilds as failures change.
class _FailureList extends StatefulWidget {
  const _FailureList();

  @override
  State<_FailureList> createState() => _FailureListState();
}

class _FailureListState extends State<_FailureList> {
  /// True while Retry runs (disables the button, shows a spinner).
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    await ExtensionLoadFailures.retryAll();
    if (!mounted) return;
    setState(() => _retrying = false);
    // Everything loaded: nothing left to show.
    if (ExtensionLoadFailures.failures.value.isEmpty) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<List<ExtensionLoadFailure>>(
        valueListenable: ExtensionLoadFailures.failures,
        builder: (context, items, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DesktopPanelTitleBar(
              title: context.l10n.someExtensionsDidNotLoad,
              subtitle: context.l10n.extensionSourcesMissingUntilLoad,
            ),
            Flexible(
              child: items.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        context.l10n.everythingLoaded,
                        style: AppText.body.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        for (final f in items)
                          ListTile(
                            dense: true,
                            leading: Icon(
                              Icons.error_outline_rounded,
                              color: AppColors.accent,
                            ),
                            title: Text(
                              '${extensionFailureText(context.l10n, f.ecosystem)}: '
                              '${extensionFailureText(context.l10n, f.name)}',
                              style: AppText.body.copyWith(
                                color: AppColors.textPrimary,
                              ),
                            ),
                            subtitle: Text(
                              extensionFailureText(context.l10n, f.message),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.caption.copyWith(
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(context.l10n.close),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    key: const ValueKey('extension-load-failures-retry'),
                    onPressed: _retrying || items.isEmpty ? null : _retry,
                    icon: _retrying
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                    label: Text(context.l10n.retry),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

/// Translates the fixed engine/notice names and messages kept as English ids
/// (they are cleared by name, so they cannot change with the language).
/// Extension and plugin names and their error text are shown as they are.
String extensionFailureText(AppLocalizations l10n, String raw) =>
    switch (raw) {
      'Extension engine' => l10n.extensionEngine,
      'Installed extensions' => l10n.installedExtensions,
      'Startup' => l10n.startupEntry,
      'CloudStream engine' => l10n.cloudStreamEngine,
      'Aniyomi / Mihon engine' => l10n.aniyomiMihonEngine,
      'Extension engine not found. Re-extract the app folder.' =>
        l10n.extensionEngineNotFound,
      _ => raw,
    };

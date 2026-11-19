import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/anilist/anilist_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/mal_service.dart';
import '../../core/tracker/mangabaka_service.dart';
import '../../core/tracker/simkl_service.dart';
import '../../core/tracker/tracker_hub.dart' show trackerNeedsSignIn;
import '../../core/tracker/tracker_sync_queue.dart';
import '../../core/ui/app_dialog.dart';
import '../../core/ui/desktop_settings_surface.dart';
import '../../core/ui/settings_widgets.dart';

/// Connect / disconnect any [Tracker], including MangaBaka, and toggle
/// its auto-sync. Connecting opens the provider's OAuth consent in the browser;
/// the token returns via the `zangetsu://…` deep link captured by the service.
class TrackerSettingsScreen extends StatefulWidget {
  const TrackerSettingsScreen({super.key, required this.tracker});

  final Tracker tracker;

  @override
  State<TrackerSettingsScreen> createState() => _TrackerSettingsScreenState();
}

class _TrackerSettingsScreenState extends State<TrackerSettingsScreen> {
  Tracker get _t => widget.tracker;
  bool _busy = false;

  /// True inside the Windows settings workspace.
  bool get _desktop => DesktopSettingsScope.contains(context);

  /// Specific failure reason from the service. MangaBaka always had one; the
  /// other trackers report theirs only on desktop so phone text is unchanged.
  String? _connectionError() {
    final t = _t;
    if (t is MangaBakaService) return t.lastConnectionError;
    if (!_desktop) return null;
    return switch (t) {
      AniListService() => t.lastConnectionError,
      MalService() => t.lastConnectionError,
      SimklService() => t.lastConnectionError,
      _ => null,
    };
  }

  /// Desktop: abandon a browser sign-in that is still waiting.
  void _cancelConnect() {
    switch (_t) {
      case final AniListService t:
        t.cancelConnect();
      case final MalService t:
        t.cancelConnect();
      case final SimklService t:
        t.cancelConnect();
      case final MangaBakaService t:
        t.cancelConnect();
    }
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() => _busy = true);
    var ok = false;
    try {
      ok = await _t.connect();
    } catch (_) {
      // A launcher or plugin error must not leave the row stuck on
      // "Connecting…"; the generic cancelled message below covers it.
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? context.l10n.connectedAs(_t.viewerName ?? '')
              : _connectionError() ??
                    context.l10n.trackerConnectionCanceled(_t.displayName),
        ),
      ),
    );
  }

  Future<void> _disconnect() async {
    final ok = await AppDialog.confirm(
      context,
      title: context.l10n.disconnectTrackerQuestion(_t.displayName),
      message: context.l10n.trackerDisconnectBody(_t.displayName),
      confirmLabel: context.l10n.disconnect,
      destructive: true,
    );
    if (ok == true) await _t.disconnect();
  }

  // ── Sync health (track-2, Windows only) ────────────────────────────────────

  /// The shared outbox the Windows app's TrackerHub reports into.
  TrackerSyncQueue get _queue => TrackerSyncQueue.instance;

  /// Whether the login is dead: refused by the tracker (MAL refresh, 401) or
  /// expired (AniList can't refresh at all).
  bool get _needsSignIn =>
      _queue.healthOf(_t.displayName).needsSignIn || trackerNeedsSignIn(_t);

  /// Reconnect after a dead login, then send everything that waited for it.
  Future<void> _reconnect() async {
    if (_busy) return;
    setState(() => _busy = true);
    var ok = false;
    try {
      ok = await _t.connect();
    } catch (_) {
      // Same as _connect: never leave the row stuck on the spinner.
    }
    if (ok) await _queue.signedInAgain(_t.displayName);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? context.l10n.connectedAs(_t.viewerName ?? '')
              : _connectionError() ??
                    context.l10n.trackerConnectionCanceled(_t.displayName),
        ),
      ),
    );
  }

  /// Retry this tracker's waiting updates now.
  Future<void> _retry() async {
    if (_busy) return;
    setState(() => _busy = true);
    await _queue.flush(only: _t.displayName);
    if (!mounted) return;
    setState(() => _busy = false);
    final left = _queue.pendingFor(_t.displayName);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          left == 0
              ? context.l10n.trackerUpToDate(_t.displayName)
              : context.l10n.trackerStillUnreachable(_t.displayName),
        ),
      ),
    );
  }

  /// "Last sync failed / needs sign-in" card, shown only while something is
  /// wrong or waiting. Null when all is well.
  Widget? _syncHealthCard() {
    final name = _t.displayName;
    final health = _queue.healthOf(name);
    final pending = _queue.pendingFor(name);
    final needsSignIn = _needsSignIn;
    if (!needsSignIn && !health.failed && pending == 0) return null;
    final l10n = context.l10n;
    final waiting = pending == 0
        ? ''
        : l10n.trackerUpdatesSavedSuffix(pending);
    final when = health.lastFailureAt == null
        ? ''
        : l10n.trackerLastTrySuffix(_ago(health.lastFailureAt!));
    return SettingsCard(
      children: [
        SettingsTile(
          icon: needsSignIn ? Icons.lock_reset_rounded : Icons.sync_problem_rounded,
          title: needsSignIn
              ? l10n.trackerNeedsSignIn(name)
              : (health.failed
                    ? l10n.lastSyncFailed
                    : l10n.updatesWaitingToSync),
          subtitle: needsSignIn
              ? l10n.loginExpiredOrRevoked + waiting
              : '${health.lastError ?? l10n.noConnectionDot}$when$waiting',
          subtitleMaxLines: null,
          onTap: _busy ? null : (needsSignIn ? _reconnect : _retry),
          trailing: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  needsSignIn ? l10n.reconnect : l10n.retry,
                  style: AppText.body.copyWith(color: AppColors.accent),
                ),
        ),
      ],
    );
  }

  /// "just now" / "5 min ago" / "3 h ago" / a date, for the failure time.
  static String _ago(DateTime at) {
    final d = DateTime.now().difference(at);
    // Static helper without context; appL10n follows the app language.
    if (d.inMinutes < 1) return appL10n.justNow;
    if (d.inHours < 1) return appL10n.minutesAgoShort(d.inMinutes);
    if (d.inDays < 1) return appL10n.hoursAgoShort(d.inHours);
    return '${at.day}/${at.month}/${at.year}';
  }

  @override
  Widget build(BuildContext context) {
    final desktop = _desktop;
    final list = AnimatedBuilder(
      // Desktop also rebuilds when the sync outbox changes (track-2).
      animation: desktop ? Listenable.merge([_t, _queue]) : _t,
      builder: (context, _) {
        final connected = _t.isConnected;
        final error = connected ? null : _connectionError();
        final health = desktop ? _syncHealthCard() : null;
        return ListView(
          padding: EdgeInsets.only(top: desktop ? 16 : 8, bottom: 24),
          children: [
            if (desktop) _desktopHeader(connected) else _header(connected),
            // Windows: failed sync / needs sign-in, with Retry or Reconnect.
            if (health != null) ...[health, const SizedBox(height: 12)],
            if (!connected)
              SettingsCard(
                children: [
                  SettingsTile(
                    icon: Icons.link_rounded,
                    title: _busy
                        ? context.l10n.connectingEllipsis
                        : context.l10n.connectTracker(_t.displayName),
                    // Desktop: explain the browser hand-off and let a click
                    // cancel the wait instead of a dead row for 3 minutes.
                    subtitle: _busy
                        ? (desktop
                              ? 'Approve in your browser, then choose '
                                    '"Open Zangetsu". Click here to cancel.'
                              : null)
                        : context.l10n.signInToLinkYourAccount,
                    subtitleMaxLines: null,
                    onTap: _busy ? (desktop ? _cancelConnect : null) : _connect,
                    trailing: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                  ),
                ],
              )
            else ...[
              SettingsCard(
                children: [
                  SettingsTile(
                    icon: Icons.sync_rounded,
                    title: context.l10n.autoSync,
                    subtitle: context.l10n.updateTrackerAsYouWatch(
                      _t.displayName,
                    ),
                    subtitleMaxLines: desktop ? null : 1,
                    // Desktop rows are whole click targets, like the switch.
                    onTap: desktop
                        ? () => setState(() => _t.autoSync = !_t.autoSync)
                        : null,
                    trailing: Switch.adaptive(
                      value: _t.autoSync,
                      activeThumbColor: AppColors.accent,
                      onChanged: (v) => setState(() => _t.autoSync = v),
                    ),
                  ),
                ],
              ),
              if (desktop) const SizedBox(height: 12),
              SettingsCard(
                children: [
                  SettingsTile(
                    icon: Icons.logout_rounded,
                    title: context.l10n.disconnect,
                    destructive: true,
                    onTap: _disconnect,
                  ),
                ],
              ),
            ],
            Padding(
              padding: EdgeInsets.fromLTRB(
                desktop ? 26 : 24,
                desktop ? 12 : 8,
                24,
                0,
              ),
              child: Text(
                _t is MangaBakaService
                    ? 'Sync your manga and novel library, reading progress and status with MangaBaka.'
                    : 'When you start an anime it’s marked Watching, each '
                          'episode you finish updates the count, and a status you set on '
                          'a title is pushed to ${_t.displayName}. '
                          // Desktop states what this tracker really covers
                          // (Simkl also syncs films/series, AniList and MAL
                          // also sync reading); phone keeps its text.
                          '${desktop ? (_t.supportsReading ? 'Manga and novel reading syncs here too.' : 'Movies and series sync here too.') : 'Anime only.'}',
                style: AppText.caption,
              ),
            ),
            // Keep failures readable after the temporary snackbar disappears
            // or the user returns from the browser to this settings screen.
            if (error != null)
              Padding(
                padding: EdgeInsets.fromLTRB(desktop ? 26 : 24, 16, 24, 0),
                child: Text(
                  error,
                  style: AppText.body.copyWith(color: AppColors.accent),
                ),
              ),
          ],
        );
      },
    );
    return Scaffold(
      backgroundColor: settingsPageBackground(context),
      appBar: settingsAppBar(_t.displayName),
      // Desktop: keep rows readable on wide panes, like Discord settings.
      body: desktop
          ? Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: list,
              ),
            )
          : list,
    );
  }

  /// Desktop account summary drawn as a graphite panel row.
  Widget _desktopHeader(bool connected) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GraphiteSettingsPanel(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
            child: Row(
              children: [
                _avatar(connected, 48),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        connected
                            ? (_t.viewerName ?? _t.displayName)
                            : _t.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.headline.copyWith(
                          fontSize: 19,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _needsSignIn
                            ? context.l10n.signInExpired
                            : connected
                            ? context.l10n.connectedToName(_t.displayName)
                            : context.l10n.notConnected,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(
                          color: _needsSignIn
                              ? trackerWarningColor
                              : connected
                              ? AppColors.accent
                              : AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(bool connected) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _avatar(connected, 52),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  connected
                      ? (_t.viewerName ?? _t.displayName)
                      : _t.displayName,
                  style: AppText.headline.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  connected ? 'Connected' : 'Not connected',
                  style: AppText.caption.copyWith(
                    color: connected
                        ? AppColors.accent
                        : AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Account avatar when connected, otherwise a neutral placeholder.
  Widget _avatar(bool connected, double size) {
    if (connected && (_t.viewerAvatar?.isNotEmpty ?? false)) {
      return ClipOval(
        child: CachedNetworkImage(
          imageUrl: _t.viewerAvatar!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorWidget: (_, _, _) => _fallbackAvatar(size),
        ),
      );
    }
    return _fallbackAvatar(size);
  }

  Widget _fallbackAvatar(double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: AppColors.surface2,
      shape: BoxShape.circle,
    ),
    child: const Icon(Icons.person_rounded, color: AppColors.textTertiary),
  );
}

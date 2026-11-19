import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../core/ui/settings_widgets.dart';

import '../../core/announce/announcement.dart';
import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/mode/content_mode.dart';
import '../../core/notify/cs_notify.dart';
import '../../core/notify/new_episode_inbox.dart';
import '../../core/notify/notification_router.dart';
import '../../core/notify/subscription_checker.dart';
import '../../core/notify/subscription_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/states.dart';
import '../announce/announcement_sheet.dart';
import '../detail/detail_screen.dart';
import 'subscriptions_screen_tv.dart';
import '../../l10n/l10n.dart';

/// The Notifications screen: developer announcements (history) on top, then the
/// "new episode" subscriptions (the shows the bell on Detail subscribed to).
/// Opening it clears the announcement badge.
class SubscriptionsScreen extends StatefulWidget {
  const SubscriptionsScreen({super.key});

  @override
  State<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends State<SubscriptionsScreen> {
  SubscriptionStore get _store => sl<SubscriptionStore>();
  AnnouncementStore get _announcements => sl<AnnouncementStore>();

  /// Windows shows the in-app "New episodes" inbox on this page (track-1);
  /// phone keeps today's page.
  bool get _showInbox => defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    // Viewing the list clears the "new announcement" badge.
    _announcements.markAllSeen();
    // The checker can add entries while this page is open (timer, focus).
    if (_showInbox) NewEpisodeInbox.changes.addListener(_onInboxChanged);
  }

  /// shell-9: whether this page was on screen at the last dependency check.
  /// The Windows shell keeps it alive in an IndexedStack and turns its
  /// TickerMode off while another page shows, so that is how "left the
  /// page" is noticed without a dispose.
  bool _wasVisible = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // TickerMode.valuesOf registers a dependency, so this runs again
    // whenever the shell shows or hides the page.
    final visible = TickerMode.valuesOf(context).enabled;
    // A route pushed on top (e.g. a show opened from an inbox entry) also
    // turns tickers off, but the user has not left Notifications: they come
    // back to it with Back, so the other entries keep their unread dots.
    // isCurrentOf registers a dependency too, so returning re-runs this.
    final covered = ModalRoute.isCurrentOf(context) == false;
    if (_wasVisible && !visible && !covered) _markViewedInboxRead();
    _wasVisible = visible;
  }

  /// shell-9: entries the user has looked at count as read once they leave
  /// the page, which clears the bell badge. Marking on leave (not on open)
  /// keeps the unread dots visible while the list is being read.
  void _markViewedInboxRead() {
    if (_showInbox) unawaited(NewEpisodeInbox.markAllRead());
  }

  @override
  void dispose() {
    NewEpisodeInbox.changes.removeListener(_onInboxChanged);
    // Leaving a pushed Notifications route also counts as viewing it.
    if (_wasVisible) _markViewedInboxRead();
    super.dispose();
  }

  void _onInboxChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openDetail(Subscription s) async {
    // Opening the show means its new episodes were seen.
    if (_showInbox) await markInboxShowRead(s.sourceId, s.url);
    if (!mounted) return;
    await Navigator.of(context).push(
      // Typed by the subscription's real mode: a manga opens as a manga
      // (track-6; this used to be hardcoded to anime).
      DetailScreen.route(subscriptionMediaItem(s)),
    );
    if (mounted) setState(() {}); // reflect an unsubscribe done from the detail
  }

  /// Opens the title an inbox entry announces and marks it read.
  Future<void> _openInboxEntry(NewEpisodeEntry e) async {
    await NewEpisodeInbox.markRead(e.id);
    await openShowFromNotification(
      '${e.sourceId}|${e.showId}',
      mode: contentModeNamed(e.mode),
    );
    if (mounted) setState(() {});
  }

  Future<void> _remove(Subscription s) async {
    await _store.remove(s.sourceId, s.url);
    await CsNotify.sync(_store.all()); // drop it from the native worker too
    if (mounted) setState(() {});
  }

  Future<void> _checkNow() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text(context.l10n.checkingForNewEpisodes)),
    );
    final found = await sl<SubscriptionChecker>().checkAll(); // JS sources
    await CsNotify.checkNow(); // CS sources (native worker)
    if (!mounted) return;
    setState(() {});
    // Windows has no CS worker, so the sweep above is the whole answer:
    // say so when nothing new turned up instead of going quiet.
    if (_showInbox && found == 0) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text(context.l10n.noNewEpisodes)),
      );
    }
  }

  String _sourceLabel(String sourceId) =>
      sourceId.startsWith('cs:') ? sourceId.substring(3) : sourceId;

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const SubscriptionsScreenTv();
    final subs = _store.all();
    final announcements = _announcements.all();
    // Windows inbox of new episodes/chapters, newest first (empty elsewhere).
    final inbox = _showInbox
        ? NewEpisodeInbox.entries
        : const <NewEpisodeEntry>[];
    final hasUnread = inbox.any((e) => !e.read);
    final empty = subs.isEmpty && announcements.isEmpty && inbox.isEmpty;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(
        context.l10n.notifications,
        actions: [
          if (hasUnread)
            IconButton(
              icon: const Icon(Icons.done_all_rounded),
              tooltip: context.l10n.markAllRead,
              onPressed: () => NewEpisodeInbox.markAllRead(),
            ),
          if (subs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: context.l10n.checkNow,
              onPressed: _checkNow,
            ),
        ],
      ),
      body: empty
          ? EmptyState(
              icon: Icons.notifications_none_rounded,
              message: context.l10n.noNotificationsYet,
            )
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                // Newest alerts first: this is what the Windows bell badge
                // counts.
                if (inbox.isNotEmpty) ...[
                  _header(context.l10n.newEpisodesHeader),
                  for (final e in inbox) _inboxTile(e),
                  const SizedBox(height: 8),
                ],
                if (announcements.isNotEmpty) ...[
                  _header(context.l10n.announcements),
                  for (final a in announcements) _announcementTile(a),
                ],
                if (subs.isNotEmpty) ...[
                  if (announcements.isNotEmpty) const SizedBox(height: 8),
                  _header(context.l10n.subscribedShows),
                  for (final s in subs) _subscriptionTile(s),
                ],
              ],
            ),
    );
  }

  Widget _header(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
    child: Text(
      label.toUpperCase(),
      style: AppText.caption.copyWith(
        color: AppColors.textSecondary,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    ),
  );

  Widget _announcementTile(Announcement a) {
    final (icon, tint) = switch (a.type) {
      'warning' => (Icons.warning_amber_rounded, const Color(0xFFF2B01E)),
      'update' => (Icons.system_update_rounded, AppColors.accent),
      _ => (Icons.campaign_rounded, AppColors.accent),
    };
    final iconAvatar = CircleAvatar(
      radius: 20,
      backgroundColor: tint.withValues(alpha: 0.14),
      child: Icon(icon, color: tint, size: 20),
    );
    final hasImage = a.imageUrl != null && a.imageUrl!.isNotEmpty;
    return ListTile(
      // Re-open the full message (with its action button) in the sheet.
      onTap: () => showAnnouncementSheet(context, a),
      leading: hasImage
          ? ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 44,
                height: 44,
                child: CachedNetworkImage(
                  imageUrl: a.imageUrl!,
                  fit: BoxFit.cover,
                  // 44x44 icon: decode small.
                  memCacheWidth: 132,
                  errorWidget: (_, _, _) => iconAvatar,
                ),
              ),
            )
          : iconAvatar,
      title: Text(
        a.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppText.body.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: a.body.isEmpty
          ? null
          : Text(
              a.body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption,
            ),
    );
  }

  /// "3 new episodes" / "1 new chapter" for an inbox entry.
  String _inboxCountLabel(NewEpisodeEntry e) {
    final reading = contentModeNamed(e.mode) != null &&
        contentModeNamed(e.mode) != ContentMode.anime;
    if (reading) {
      return context.l10n.newChaptersCount(e.count);
    }
    return context.l10n.newEpisodesCount(e.count);
  }

  /// One inbox entry: unread ones get an accent dot and a bold title.
  /// Clicking opens the title; the trailing buttons mark read or remove.
  Widget _inboxTile(NewEpisodeEntry e) {
    final unread = !e.read;
    return ListTile(
      onTap: () => _openInboxEntry(e),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 44,
              height: 62,
              child: (e.cover != null && e.cover!.isNotEmpty)
                  ? CachedNetworkImage(
                      imageUrl: e.cover!,
                      fit: BoxFit.cover,
                      // 44x62 thumb: decode small, not full poster.
                      memCacheWidth: 132,
                      errorWidget: (_, _, _) =>
                          ColoredBox(color: AppColors.surface2),
                    )
                  : ColoredBox(color: AppColors.surface2),
            ),
          ),
          // Unread marker.
          if (unread)
            Positioned(
              top: -3,
              right: -3,
              child: Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.bg, width: 2),
                ),
              ),
            ),
        ],
      ),
      title: Text(
        e.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AppText.body.copyWith(
          color: unread ? AppColors.textPrimary : AppColors.textSecondary,
          fontWeight: unread ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
      subtitle: Text(
        '${_inboxCountLabel(e)} · ${_sourceLabel(e.sourceId)}',
        style: AppText.caption.copyWith(
          color: unread ? AppColors.accent : AppColors.textSecondary,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (unread)
            IconButton(
              icon: const Icon(
                Icons.mark_email_read_outlined,
                color: AppColors.textSecondary,
              ),
              tooltip: context.l10n.markAsRead,
              onPressed: () => NewEpisodeInbox.markRead(e.id),
            ),
          IconButton(
            icon: const Icon(
              Icons.close_rounded,
              color: AppColors.textSecondary,
            ),
            tooltip: context.l10n.remove,
            onPressed: () => NewEpisodeInbox.remove(e.id),
          ),
        ],
      ),
    );
  }

  Widget _subscriptionTile(Subscription s) => ListTile(
    onTap: () => _openDetail(s),
    leading: ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 44,
        height: 62,
        child: (s.cover != null && s.cover!.isNotEmpty)
            ? CachedNetworkImage(
                imageUrl: s.cover!,
                httpHeaders: s.coverHeaders,
                fit: BoxFit.cover,
                // 44x62 thumb: decode small, not full poster.
                memCacheWidth: 132,
                errorWidget: (_, _, _) => ColoredBox(color: AppColors.surface2),
              )
            : ColoredBox(color: AppColors.surface2),
      ),
    ),
    title: Text(
      s.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: AppText.body.copyWith(color: AppColors.textPrimary),
    ),
    subtitle: Text(_sourceLabel(s.sourceId), style: AppText.caption),
    trailing: IconButton(
      icon: const Icon(
        Icons.notifications_off_outlined,
        color: AppColors.textSecondary,
      ),
      tooltip: context.l10n.turnOff,
      onPressed: () => _remove(s),
    ),
  );
}

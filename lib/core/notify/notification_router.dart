import '../../features/detail/detail_screen.dart';
import '../di/injector.dart';
import '../models/media_item.dart';
import '../mode/content_mode.dart';
import '../models/provider_info.dart';
import '../ui/global_messenger.dart';
import 'new_episode_inbox.dart';
import 'subscription_store.dart';

/// The Detail item type for a subscription's [mode]. Manga and novels must
/// open as reading titles; anything else (or an unknown mode) is video.
ProviderType providerTypeForMode(ContentMode? mode) => switch (mode) {
  ContentMode.manga => ProviderType.manga,
  ContentMode.novel => ProviderType.novel,
  _ => ProviderType.anime,
};

/// [ContentMode] from its stored name (as the inbox keeps it); null when
/// unknown.
ContentMode? contentModeNamed(String? name) {
  for (final mode in ContentMode.values) {
    if (mode.name == name) return mode;
  }
  return null;
}

/// The Detail item for a subscribed show, typed by its real mode (track-6:
/// the Notifications page used to open every subscription as an anime).
MediaItem subscriptionMediaItem(Subscription s) => MediaItem(
  id: s.url,
  title: s.title,
  url: s.url,
  type: providerTypeForMode(s.mode),
  sourceId: s.sourceId,
  cover: s.cover,
  coverHeaders: s.coverHeaders,
);

/// Payload of the Windows download batch notifications (dl-11).
const String downloadsNotificationPayload = 'downloads';

/// Set by the Windows shell while it is mounted: brings the Downloads page
/// to the front. Null elsewhere (phone, TV, tests), so the click is ignored.
void Function()? openDownloadsFromNotification;

/// Open the Detail screen for the show a new-episode/chapter alert points to.
/// [payload] is "sourceId|url" (split on the FIRST '|' — a url may contain one).
/// The full cover / headers / title come from the stored subscription so Detail
/// renders immediately; it then re-fetches by sourceId+url anyway.
/// [mode] is used when the subscription is gone (e.g. an inbox entry for a
/// show that was unsubscribed since).
Future<void> openShowFromNotification(
  String? payload, {
  ContentMode? mode,
}) async {
  if (payload == null) return;
  // Windows download batch notifications (DesktopDownloadSignals) carry
  // 'downloads': open the Downloads page instead of a show (dl-11).
  if (payload == downloadsNotificationPayload) {
    openDownloadsFromNotification?.call();
    return;
  }
  final i = payload.indexOf('|');
  if (i < 0) return;
  final sourceId = payload.substring(0, i);
  final url = payload.substring(i + 1);
  if (sourceId.isEmpty || url.isEmpty) return;

  Subscription? sub;
  if (sl.isRegistered<SubscriptionStore>()) {
    for (final s in sl<SubscriptionStore>().all()) {
      if (s.sourceId == sourceId && s.url == url) {
        sub = s;
        break;
      }
    }
  }

  // Opening the title counts as reading its inbox entry (Windows bell).
  await markInboxShowRead(sourceId, url);

  final nav = rootNavigatorKey.currentState;
  if (nav == null) return;
  await nav.push(
    DetailScreen.route(
      MediaItem(
        id: url,
        title: sub?.title ?? '',
        url: url,
        // Was hardcoded to anime, which opened a subscribed manga as a video
        // show. The subscription knows what it is.
        type: providerTypeForMode(sub?.mode ?? mode),
        sourceId: sourceId,
        cover: sub?.cover,
        coverHeaders: sub?.coverHeaders,
      ),
    ),
  );
}

/// Marks every unread inbox entry of one show as read. A no-op when the
/// inbox is empty (phone, tests).
Future<void> markInboxShowRead(String sourceId, String url) async {
  for (final e in NewEpisodeInbox.entries) {
    if (!e.read && e.sourceId == sourceId && e.showId == url) {
      await NewEpisodeInbox.markRead(e.id);
    }
  }
}

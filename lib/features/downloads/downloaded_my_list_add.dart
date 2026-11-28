import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;

import '../../core/di/injector.dart';
import '../../core/download/download_record.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart' show ProviderType;
import '../../core/models/watch_status.dart';
import '../../core/playback/list_status_store.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/tv_playback_helpers.dart'
    show mediaItemForPlayback;
import '../../core/privacy/incognito_mode.dart';
import '../../core/zmode/zmode_ids.dart';
import '../auth/auth_cubit.dart';

/// Auto-add to My List for episodes played from saved files (Windows).
///
/// Pressing Play on an online show page adds the show to My List as Watching.
/// Playing a downloaded file skipped that step, so a show watched only from
/// Downloads never showed up in My List even though AniList was updated.
/// This gives the saved-file path the same add, with extra care so it never
/// lists a made-up show or a second copy of one already there.

/// The My List entry a downloaded episode belongs to, or null when the
/// download has no real show behind it.
///
/// Files found by a folder scan or recovered from disk carry invented
/// identities ('local-files', 'local:…', a file address). Adding those would
/// put a show in My List that opens nowhere, so they are left out.
MediaItem? downloadedListItem(DownloadRecord record) {
  final url = record.showUrl.trim();
  final z = url.isEmpty ? null : ZmodeIds.parseShow(url);
  if (z != null) {
    // A catalogue show: the same identity the online show page uses, so the
    // entry matches the one online Play would make.
    return mediaItemForPlayback(
      sourceId: record.sourceId,
      showUrl: url,
      showTitle: record.showTitle,
      cover: record.cover,
      coverHeaders: record.coverHeaders,
      malId: record.malId,
      tmdbId: record.tmdbId,
      tmdbIsTv: record.tmdbIsTv,
      imdbId: record.imdbId,
    )?.copyWith(anilistId: record.anilistId);
  }
  if (record.recoveredFromDisk ||
      !_realShow(record.sourceId, record.showId, url)) {
    return null;
  }
  // A show saved from a source page: the source's own id and link, which is
  // what that source's show page lists under.
  final title = record.showTitle.trim();
  return MediaItem(
    id: record.showId,
    title: title.isNotEmpty ? title : url,
    url: url,
    sourceId: record.sourceId,
    type: record.tmdbId != null && record.malId == null
        ? ProviderType.movie
        : ProviderType.anime,
    cover: record.cover,
    coverHeaders: record.coverHeaders,
    malId: record.malId,
    anilistId: record.anilistId,
    tmdbId: record.tmdbId,
    tmdbIsTv: record.tmdbIsTv,
    imdbId: record.imdbId,
  );
}

/// False for the stand-in identities given to files found on disk.
bool _realShow(String sourceId, String showId, String url) {
  final link = url.trim();
  return sourceId.isNotEmpty &&
      sourceId != 'local-files' &&
      showId.isNotEmpty &&
      !showId.startsWith('local:') &&
      link.isNotEmpty &&
      !link.startsWith('file:');
}

/// True when My List already has this show under any source, matched by its
/// MAL id, or by its TMDB id and kind. A show saved from one source and listed
/// from another would otherwise be listed twice.
///
/// MAL numbers anime and manga separately, so a listed manga or light novel
/// with the same number is a different title and does not count.
bool listedByCatalogueIds(MediaItem item, Iterable<MediaItem> listed) {
  bool isReading(ProviderType t) =>
      t == ProviderType.manga || t == ProviderType.novel;
  for (final m in listed) {
    if (item.malId != null &&
        m.malId == item.malId &&
        isReading(m.type) == isReading(item.type)) {
      return true;
    }
    if (item.tmdbId != null &&
        m.tmdbId == item.tmdbId &&
        m.tmdbIsTv == item.tmdbIsTv) {
      return true;
    }
  }
  return false;
}

/// Which show to add to My List for this downloaded episode, or null to add
/// nothing.
///
/// [listItem] is the online show page's own item when Play started there; it
/// is then treated exactly like online Play (skipped only when that same entry
/// is listed). Otherwise the item is built from the download, and a show
/// already listed under its MAL or TMDB id counts as listed too. Either way an
/// entry already in My List is never touched, so a Completed show stays
/// Completed.
MediaItem? downloadedShowToAutoAdd({
  required DownloadRecord record,
  MediaItem? listItem,
  required bool signedIn,
  required bool autoAddEnabled,
  required bool incognito,
  required bool Function(MediaItem) contains,
  required Iterable<MediaItem> Function() listed,
}) {
  if (!signedIn || !autoAddEnabled || incognito) return null;
  if (listItem != null) {
    // A page opened for files found on disk has the same made-up identity.
    if (!_realShow(listItem.sourceId, listItem.id, listItem.url)) return null;
    return contains(listItem) ? null : listItem;
  }
  final item = downloadedListItem(record);
  if (item == null || contains(item)) return null;
  if (listedByCatalogueIds(item, listed())) return null;
  return item;
}

/// Adds the show behind a downloaded episode to My List as Watching, on
/// Windows, when the viewer is signed in, "Auto-add to My List" is on and
/// incognito is off. Fire-and-forget so it never delays playback.
///
/// Once listed, the later list moves (2 minutes in, the finale) find the show
/// through My List itself, so they work for downloads too.
void maybeAddDownloadedShowToMyList(
  DownloadRecord record, {
  MediaItem? listItem,
}) {
  if (defaultTargetPlatform != TargetPlatform.windows) return;
  if (!sl.isRegistered<AuthCubit>() ||
      !sl.isRegistered<PlaybackPrefs>() ||
      !sl.isRegistered<MyListStore>() ||
      !sl.isRegistered<ListStatusStore>()) {
    return;
  }
  final list = sl<MyListStore>();
  final MediaItem? item;
  try {
    item = downloadedShowToAutoAdd(
      record: record,
      listItem: listItem,
      signedIn: sl<AuthCubit>().state.isLoggedIn,
      autoAddEnabled: sl<PlaybackPrefs>().autoAddToMyList,
      incognito: IncognitoMode.on,
      contains: list.contains,
      listed: list.all,
    );
  } catch (_) {
    return; // a list that can't be read must never stop playback
  }
  if (item == null) return;
  final MediaItem show = item;
  final status = sl<ListStatusStore>();
  unawaited(() async {
    try {
      // Add first, like online Play, then set Watching. If the add did
      // nothing (no account behind the sign-in), no stray status is left
      // behind; if a cloud pull gave the show a status while the add was
      // saving, that status is kept.
      if (list.contains(show)) return;
      final before = status.statusOf(show);
      await list.add(show);
      if (!list.contains(show)) return;
      if (status.statusOf(show) != before) return;
      await status.setStatus(show, WatchStatus.watching);
      // The add's cloud copy went up before the status was set, so send the
      // status after it.
      await list.pushStatus(show);
    } catch (_) {}
  }());
}

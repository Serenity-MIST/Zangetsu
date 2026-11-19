import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/list_auto_status.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/home/cubit/tracker_home_rows.dart';

void main() {
  group('autoListStatus: starting an episode', () {
    WatchStatus? start(WatchStatus? s) =>
        autoListStatus(current: s, event: ListAutoEvent.started);

    test('not on the list is added as Watching', () {
      expect(start(null), WatchStatus.watching);
    });
    test('Plan to watch, Paused and Dropped move to Watching', () {
      expect(start(WatchStatus.planning), WatchStatus.watching);
      expect(start(WatchStatus.paused), WatchStatus.watching);
      expect(start(WatchStatus.dropped), WatchStatus.watching);
    });
    test('Watching and Completed are left alone', () {
      expect(start(WatchStatus.watching), isNull);
      expect(start(WatchStatus.completed), isNull); // rewatch stays Completed
    });
  });

  group('autoListStatus: finishing an episode', () {
    WatchStatus? finish(WatchStatus? s, {required bool finale}) =>
        autoListStatus(current: s, event: ListAutoEvent.finished, finale: finale);

    test('the finale completes every status', () {
      for (final s in [
        null,
        WatchStatus.planning,
        WatchStatus.watching,
        WatchStatus.paused,
        WatchStatus.dropped,
      ]) {
        expect(finish(s, finale: true), WatchStatus.completed, reason: '$s');
      }
      expect(finish(WatchStatus.completed, finale: true), isNull);
    });
    test('a non-final episode behaves like starting', () {
      expect(finish(WatchStatus.planning, finale: false), WatchStatus.watching);
      expect(finish(WatchStatus.watching, finale: false), isNull);
    });
  });

  group('showFinished', () {
    MediaDetail d(MediaStatus st, {int? next}) => MediaDetail(
          id: 'x', title: 'x', url: 'x', type: ProviderType.anime,
          sourceId: 'x', episodes: const [], status: st,
          nextEpisode: next);
    test('finished and cancelled shows are done', () {
      expect(showFinished(d(MediaStatus.completed)), isTrue);
      expect(showFinished(d(MediaStatus.cancelled)), isTrue);
    });
    test('airing, unknown, or with a next episode scheduled are not', () {
      expect(showFinished(d(MediaStatus.ongoing)), isFalse);
      expect(showFinished(d(MediaStatus.unknown)), isFalse);
      expect(showFinished(d(MediaStatus.completed, next: 5)), isFalse);
    });
  });

  group('isFinale', () {
    test('needs a finished show and its last episode', () {
      expect(isFinale(finishedAiring: true, episode: 12, lastEpisode: 12), isTrue);
      expect(isFinale(finishedAiring: true, episode: 11, lastEpisode: 12), isFalse);
      // Still airing: the newest episode is not the end.
      expect(isFinale(finishedAiring: false, episode: 8, lastEpisode: 8), isFalse);
      expect(isFinale(finishedAiring: true, episode: null, lastEpisode: 12), isFalse);
    });
  });

  group('aniListLatestReleaseAt', () {
    test('airing: about a week before the next episode', () {
      final at = DateTime.utc(2026, 11, 20);
      final got = aniListLatestReleaseAt({
        'nextAiringEpisode': {
          'episode': 8,
          'airingAt': at.millisecondsSinceEpoch ~/ 1000,
        },
      });
      expect(got!.toUtc(), at.subtract(const Duration(days: 7)));
    });
    test('airing episode 1 next: nothing released yet', () {
      expect(
        aniListLatestReleaseAt({
          'nextAiringEpisode': {'episode': 1, 'airingAt': 1800000000},
        }),
        isNull,
      );
    });
    test('finished: its end date', () {
      expect(
        aniListLatestReleaseAt({
          'status': 'FINISHED',
          'endDate': {'year': 2024, 'month': 3, 'day': 23},
        }),
        DateTime(2024, 3, 23),
      );
    });
  });

  group('freshReleases (desktop New from your list)', () {
    final now = DateTime(2026, 11, 16);
    TrackerListItem entry(String t, DateTime? released, {int progress = 2}) =>
        TrackerListItem(
          item: MediaItem(
            id: t,
            title: t,
            url: '',
            type: ProviderType.anime,
            sourceId: '',
          ),
          status: WatchStatus.watching,
          progress: progress,
          totalEpisodes: 12,
          latestReleaseAt: released,
        );

    test('drops long-finished shows and sorts newest release first', () {
      final got = freshReleases([
        entry('Strongest Sage (finished 2022)', DateTime(2022, 3, 21)),
        entry('Three days ago', now.subtract(const Duration(days: 3))),
        entry('Yesterday', now.subtract(const Duration(days: 1))),
        entry('No date', null),
        entry('Caught up', now, progress: 12),
      ], ZKind.anime, now: now);
      expect(got.map((e) => e.item.title), ['Yesterday', 'Three days ago']);
    });
  });
}

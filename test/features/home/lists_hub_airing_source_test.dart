import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/schedule/airing_service.dart';
import 'package:watch_app/core/schedule/schedule_models.dart';
import 'package:watch_app/features/home/lists_hub_airing_source.dart';

/// AiringService whose week the test controls.
class _FakeAiring extends AiringService {
  _FakeAiring(this.week) : super(Dio());

  List<AiringEntry> week;

  @override
  Future<List<AiringEntry>> weekAiring({DateTime? now}) async => week;
}

AiringEntry _e(String title, DateTime at, {int? mal, String? alt}) =>
    AiringEntry(
      malId: mal,
      title: title,
      altTitle: alt,
      coverUrl: 'c-$title',
      episode: 4,
      airsAtLocal: at,
      format: 'TV',
    );

void main() {
  final now = DateTime(2026, 11, 17, 9, 30);

  test('keeps only the local day, sorted, with show items', () async {
    final airing = _FakeAiring([
      _e('Tomorrow', DateTime(2026, 11, 18, 0, 0)),
      _e('Evening', DateTime(2026, 11, 17, 23, 59), mal: 5, alt: 'Yoru'),
      _e('Midnight', DateTime(2026, 11, 17)),
      _e('Yesterday', DateTime(2026, 11, 16, 23, 59)),
    ]);
    final calls = <(MediaItem, String)>[];
    final rows = await HubAiringSource(airing: airing, clock: () => now).today(
      isOnYourList: (item, title) {
        calls.add((item, title));
        return title == 'Evening';
      },
    );
    expect(rows.map((r) => r.title), ['Midnight', 'Evening']);
    expect(rows.map((r) => r.onYourList), [false, true]);
    // Midnight has no MAL id: not clickable, still matched by title.
    expect(rows.first.item, isNull);
    final show = rows.last.item!;
    expect(show.malId, 5, reason: 'id matching needs the MAL id');
    expect(show.englishTitle, 'Yoru', reason: 'romaji alt for title match');
    expect(show.url, 'zm://anime/mal:5');
    expect(calls.map((c) => c.$1.englishTitle), contains('Yoru'));
  });

  test('an empty week is a failure, not "nothing today"', () async {
    final airing = _FakeAiring(const [])..lastFailureOffline = false;
    expect(
      HubAiringSource(
        airing: airing,
        clock: () => now,
      ).today(isOnYourList: (_, _) => false),
      throwsA(isA<HubAiringUnavailable>()),
    );
  });

  test('a week with nothing today returns []', () async {
    final airing = _FakeAiring([_e('Later', DateTime(2026, 11, 19, 12))]);
    final rows = await HubAiringSource(
      airing: airing,
      clock: () => now,
    ).today(isOnYourList: (_, _) => true);
    expect(rows, isEmpty);
  });
}

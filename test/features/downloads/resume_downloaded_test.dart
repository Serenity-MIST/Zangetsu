import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/playback/watch_history.dart';
import 'package:watch_app/features/downloads/resume_downloaded.dart';

HistoryEntry _entry({
  String id = 'e6',
  String url = 'u6',
  double? number = 6,
}) => HistoryEntry(
  sourceId: 's',
  showId: 'show',
  showTitle: 'Show',
  showUrl: 'show-url',
  category: 'sub',
  episodeId: id,
  episodeNumber: number,
  episodeUrl: url,
  position: const Duration(minutes: 12),
  duration: const Duration(minutes: 24),
  updatedAt: 0,
);

void main() {
  final list = [
    for (var i = 1; i <= 8; i++)
      Episode(id: 'e$i', title: 'Episode $i', url: 'u$i', number: i.toDouble()),
  ];

  test('finds the resumed episode by id first', () {
    expect(resumeIndexIn(list, _entry()), 5);
  });

  test('falls back to the URL when the id was regenerated', () {
    expect(resumeIndexIn(list, _entry(id: 'new-id', url: 'u3')), 2);
  });

  test('falls back to the episode number last', () {
    expect(resumeIndexIn(list, _entry(id: 'x', url: 'y', number: 8)), 7);
  });

  test('missing episode gives -1 so the downloaded queue is used', () {
    expect(resumeIndexIn(list, _entry(id: 'x', url: 'y', number: 99)), -1);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/folder_manifest.dart';
import 'package:watch_app/core/playback/skip_service.dart';

void main() {
  test('skip times survive the metadata file round trip', () {
    const episode = ManifestEpisode(
      key: 'k1',
      file: 'Episode 6.mp4',
      title: 'Episode 6',
      number: 6,
      skips: [
        SkipInterval(
          start: Duration(seconds: 90),
          end: Duration(seconds: 179),
          type: 'op',
        ),
        SkipInterval(
          start: Duration(minutes: 22),
          end: Duration(minutes: 23, seconds: 30),
          type: 'ed',
        ),
      ],
    );
    final back = ManifestEpisode.fromJson(episode.toJson())!;
    expect(back.skips, hasLength(2));
    expect(back.skips.first.start, const Duration(seconds: 90));
    expect(back.skips.first.end, const Duration(seconds: 179));
    expect(back.skips.last.type, 'ed');
  });

  test('malformed skip entries from other files are dropped', () {
    final back = ManifestEpisode.fromJson({
      'key': 'k',
      'file': 'a.mp4',
      'skips': [
        {'start_ms': 10, 'end_ms': 5, 'type': 'op'}, // ends before it starts
        {'start_ms': 'x', 'end_ms': 20, 'type': 'op'},
        'junk',
        {'start_ms': 1000, 'end_ms': 2000, 'type': 'recap'},
      ],
    })!;
    expect(back.skips.single.type, 'recap');
  });

  test('older files without skip times still load', () {
    final back = ManifestEpisode.fromJson({'key': 'k', 'file': 'a.mp4'})!;
    expect(back.skips, isEmpty);
  });
}

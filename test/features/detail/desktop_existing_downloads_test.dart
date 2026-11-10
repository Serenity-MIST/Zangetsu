import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/features/detail/desktop_existing_downloads.dart';

/// Disposable index snapshots; no user files or running queue are accessed.
DownloadRecord recovered(int n, {String? id, int? season = 1}) =>
    DownloadRecord.fromMap({'id': id ?? 'disk$n', 'sourceId': 'local-files',
      'recoveredFromDisk': true, 'showTitle': 'The_Four_of_Us',
      'episodeNumber': n, 'season': season, 'status': 'done', 'category': 'unknown'});
Episode episode(int n, {int? season = 1}) => Episode(id: 'e$n',
    title: 'Episode $n', url: '/$n', number: n.toDouble(), season: season);

void main() {
  test('requested49 minus ten approved existing files leaves39 in original order', () async {
    final episodes = [for (var n = 8; n <= 56; n++) episode(n)];
    final records = [for (final n in [8,9,10,11,13,18,21,24,29,37]) recovered(n)];
    final matches = recoveredDownloadSuggestions(title: 'The Four of Us',
        episodes: episodes, records: records);
    expect(matches, hasLength(10));
    final pending = await omitReusableDownloads(episodes, matches, (_) async => true);
    expect(pending, hasLength(39));
    expect(pending.first.number, 12); expect(pending.last.number, 56);
    expect(records.every((r) => r.category == 'unknown'), isTrue);
  });
  test('ambiguity, missing season and different titles never suggest reuse', () {
    final matches = recoveredDownloadSuggestions(title: 'The Four of Us',
      episodes: [episode(12),episode(13, season:null),episode(14, season:2)],
      records: [recovered(12), recovered(12,id:'duplicate'),recovered(13),recovered(14)]);
    expect(matches,isEmpty);
    expect(recoveredDownloadSuggestions(title:'Another show', episodes:[episode(12)],
      records:[recovered(12)]),isEmpty);
  });
  test('file removed while confirmation open stays queued for download', () async {
    final episodes=[episode(12),episode(13)];
    final matches=recoveredDownloadSuggestions(title:'The Four of Us',episodes:episodes,
      records:[recovered(12),recovered(13)]);
    final pending=await omitReusableDownloads(episodes,matches,
      (r) async => r.episodeNumber == 13);
    expect(pending.single.number,12);
  });
}

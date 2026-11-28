import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/features/downloads/desktop_download_episode_groups.dart';

/// Isolated record snapshots model the user's failed/recovered duplicate rows.
DownloadRecord row(String id, {bool recovered = false, int? season = 1,
    double? number = 27, String category = 'sub', String title = 'The Four of Us'}) =>
  DownloadRecord.fromMap({'id': id, 'showTitle':title, 'season':season,
    'episodeNumber':number, 'category':category, 'sourceId':recovered?'local-files':'old-source',
    'recoveredFromDisk':recovered, 'status':recovered?'done':'failed'});
void main() {
  test('saved file leads one episode group without rewriting failed Dub state', () {
    final failed=row('failed',category:'dub');
    final saved=row('saved',recovered:true,category:'unknown');
    final groups=desktopDownloadEpisodeGroups([failed,saved]);
    expect(groups,hasLength(1)); expect(groups.single.first.id,'saved');
    expect(groups.single.last, same(failed));
    expect(failed.status,DownloadStatus.failed); expect(failed.category,'dub');
    expect(saved.category,'unknown');
  });
  test('different seasons,titles and unknown positions are not merged', () {
    final groups=desktopDownloadEpisodeGroups([row('saved',recovered:true),
      row('s2',season:2),row('other',title:'Other'),row('unknown',season:null),
      row('unnumbered',number:null)]);
    expect(groups,hasLength(5));
  });
  test('provider-only Sub and Dub attempts remain individually visible', () {
    expect(desktopDownloadEpisodeGroups([row('sub'),row('dub',category:'dub')]),hasLength(2));
  });
}

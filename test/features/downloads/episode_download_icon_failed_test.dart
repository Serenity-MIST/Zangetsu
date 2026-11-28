// Windows: an episode whose download failed or turned out unsupported shows
// as not downloaded (the plain download icon), and a click downloads it.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/features/downloads/episode_download_icon.dart';

class _FakeManager extends ChangeNotifier implements DownloadManager {
  _FakeManager(this.status);
  final DownloadStatus status;

  @override
  DownloadRecord? recordFor(
    String sourceId,
    String showId,
    String episodeId, {
    String? category,
  }) => DownloadRecord(
    id: 'r',
    sourceId: sourceId,
    showId: showId,
    showTitle: 'Show',
    showUrl: '/show',
    episodeId: episodeId,
    episodeUrl: '/e',
    episodeTitle: 'Episode 8',
    category: 'dub',
    quality: 'best',
    status: status,
    createdAt: 1,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<int> _tap(WidgetTester tester, DownloadStatus status) async {
  sl.registerSingleton<DownloadManager>(_FakeManager(status));
  addTearDown(sl.reset);
  var taps = 0;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: EpisodeDownloadIcon(
          sourceId: 'zm',
          showId: 'frieren',
          episodeId: 'e8',
          onTap: () => taps++,
        ),
      ),
    ),
  );
  await tester.tap(find.byType(IconButton));
  return taps;
}

void main() {
  for (final status in [DownloadStatus.failed, DownloadStatus.unsupported]) {
    testWidgets('Windows: $status offers the download again', (tester) async {
      expect(await _tap(tester, status), 1);
      expect(find.byIcon(Icons.file_download_outlined), findsOneWidget);
      expect(find.byTooltip('Download episode'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  testWidgets('phone keeps its retry icon', (tester) async {
    expect(await _tap(tester, DownloadStatus.failed), 1);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  test('every other status is shown as it is', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    for (final s in DownloadStatus.values) {
      if (s == DownloadStatus.failed || s == DownloadStatus.unsupported) {
        continue;
      }
      expect(shownDownloadStatus(s), s);
    }
    expect(shownDownloadStatus(null), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}

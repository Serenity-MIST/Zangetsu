import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_size_estimate.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/features/downloads/download_size_preview.dart';

/// Holds preview responses so source changes and disposal can be deterministic.
class _Estimator extends DownloadSizeEstimator {
  _Estimator() : super(cooldownUntil: (_) => null, onRateLimited: (_, _) async {});
  final response = Completer<DownloadSizeEstimate?>();
  int calls = 0;
  bool disposed = false;
  @override Future<DownloadSizeEstimate?> estimate(VideoSource source, {
    int? runtimeMinutes, String? quality}) { calls++; return response.future; }
  @override void dispose() { disposed = true; super.dispose(); }
}

void main() {
  testWidgets('batchcount only recalculates hint; changed source retires old response', (tester) async {
    var source = const VideoSource(url: 'https://fixture/first.mp4');
    var count = 1;
    final estimators = <_Estimator>[];
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(builder: (context, set) {
      update = set;
      return DownloadSizePreview(source: source, count: count, createEstimator: () {
        final estimator = _Estimator(); estimators.add(estimator); return estimator;
      });
    }))));
    expect(estimators, hasLength(1));
    update(() => count = 49); await tester.pump();
    expect(estimators, hasLength(1));
    update(() => source = const VideoSource(url: 'https://fixture/second.mp4')); await tester.pump();
    expect(estimators.first.disposed, isTrue);
    estimators.first.response.complete((bytes: 1, solid: true)); await tester.pump();
    expect(find.textContaining('~1 B'), findsNothing);
    estimators.last.response.complete((bytes: 1048576, solid: true)); await tester.pumpAndSettle();
    expect(find.textContaining('~49 MB total - based on one episode'), findsOneWidget,
      reason: tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join(' | '));
    expect(estimators.every((e) => e.calls == 1), isTrue);
  });
  testWidgets('low storage is visible only for solid estimate and known capacity', (tester) async {
    final estimator = _Estimator();
    await tester.pumpWidget(MaterialApp(home: DownloadSizePreview(
      source: const VideoSource(url: 'https://fixture/file'), count: 2,
      createEstimator: () => estimator, readFreeBytes: () async => 1048576)));
    estimator.response.complete((bytes: 1048576, solid: true)); await tester.pumpAndSettle();
    expect(find.textContaining('Low storage:'), findsOneWidget);
    expect(find.textContaining('1 MB available'), findsOneWidget);
    final assumed = _Estimator();
    await tester.pumpWidget(MaterialApp(home: DownloadSizePreview(key: const ValueKey('assumed'),
      source: const VideoSource(url: 'https://fixture/file'), createEstimator: () => assumed,
      readFreeBytes: () async => 1)));
    assumed.response.complete((bytes: 1048576, solid: false)); await tester.pumpAndSettle();
    expect(find.textContaining('Low storage:'), findsNothing);
  });
  testWidgets('unknown stays unavailable and removed preview ignores late result', (tester) async {
    final estimator = _Estimator();
    await tester.pumpWidget(MaterialApp(home: DownloadSizePreview(
      source: const VideoSource(url: 'https://fixture/file'), createEstimator: () => estimator)));
    estimator.response.complete(null); await tester.pump();
    expect(find.text('Download size unavailable'), findsOneWidget);
    final late = _Estimator();
    await tester.pumpWidget(MaterialApp(home: DownloadSizePreview(key: const ValueKey('new'),
      source: const VideoSource(url: 'https://fixture/another'), createEstimator: () => late)));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(late.disposed, isTrue);
    late.response.complete((bytes: 2048, solid: true)); await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

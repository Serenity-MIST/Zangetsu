import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/features/downloads/desktop_download_selection.dart';

/// No real files or manager: exercise the actual desktop confirmation dispatch.
DownloadRecord rec(String id, {String generation = 'one'}) => DownloadRecord(
  id: id, sourceId: 'source', showId: 'show', showTitle: 'Show', showUrl: '/show',
  episodeId: id, episodeUrl: '/$id', episodeTitle: 'Episode $id', category: 'dub',
  quality: 'best', storageKey: generation, createdAt: 0);

void main() {
  testWidgets('recovered episode leads,attempt expands,and selection exposes both exact records', (tester) async {
    final saved=DownloadRecord.fromMap({...rec('saved').toMap(),
      'episodeNumber':27,'season':1,'status':'done','recoveredFromDisk':true,
      'category':'unknown','sourceId':'local-files'});
    final failed=DownloadRecord.fromMap({...rec('failed').toMap(),
      'episodeNumber':27,'season':1,'status':'failed'});
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DesktopDownloadSelection(
      records:[failed,saved],rowBuilder:(r)=>Text('record:${r.id}'),onDelete:(_) async {}))));
    expect(find.text('record:saved'),findsOneWidget);
    expect(find.text('record:failed'),findsNothing);
    await tester.tap(find.text('Other files and previous attempts (1)'));
    await tester.pumpAndSettle();
    expect(find.text('record:failed'),findsOneWidget);
    expect(find.text('source - dub'),findsOneWidget);
    await tester.tap(find.text('Select episodes'));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox),findsNWidgets(2));
    expect(find.text('record:saved'),findsOneWidget);
    expect(find.text('record:failed'),findsOneWidget);
    expect(tester.takeException(),isNull);
  });

  testWidgets('selection, cancel and dismissed confirmation never delete', (tester) async {
    final calls = <List<DownloadRecord>>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DesktopDownloadSelection(
      records: [rec('1'), rec('2')], rowBuilder: (r) => ListTile(title: Text(r.episodeTitle)),
      onDelete: (records) async => calls.add(records)))));
    await tester.tap(find.text('Select episodes'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    await tester.tap(find.text('Delete (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
  });
  testWidgets('confirmed deletion contains only checked records', (tester) async {
    final calls = <List<DownloadRecord>>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DesktopDownloadSelection(
      records: [rec('1'), rec('2'), rec('3')], rowBuilder: (r) => Text(r.episodeTitle),
      onDelete: (records) async => calls.add(records)))));
    await tester.tap(find.text('Select episodes')); await tester.pumpAndSettle();
    await tester.tap(find.text('Select all')); await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).at(1)); await tester.pumpAndSettle();
    await tester.tap(find.text('Delete (2)')); await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete')); await tester.pumpAndSettle();
    expect(calls.single.map((r) => r.id), ['1', '3']);
    expect(find.byType(Checkbox), findsNothing);
  });
  testWidgets('deletion failure retains selection and reports the failure', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DesktopDownloadSelection(
      records: [rec('1')], rowBuilder: (r) => Text(r.episodeTitle),
      onDelete: (_) async => throw StateError('fixture failure')))));
    await tester.tap(find.text('Select episodes')); await tester.pumpAndSettle();
    await tester.tap(find.text('Select all')); await tester.pumpAndSettle();
    await tester.tap(find.text('Delete (1)')); await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete')); await tester.pumpAndSettle();
    expect(find.textContaining('could not be removed'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
  });
  testWidgets('replacement while confirmation open is not approved for deletion', (tester) async {
    final calls = <List<DownloadRecord>>[];
    var records = [rec('1'), rec('2')];
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(builder: (context, set) {
      update = set;
      return DesktopDownloadSelection(records: records,
        rowBuilder: (r) => Text(r.episodeTitle), onDelete: (value) async => calls.add(value));
    }))));
    await tester.tap(find.text('Select episodes')); await tester.pumpAndSettle();
    await tester.tap(find.text('Select all')); await tester.pumpAndSettle();
    await tester.tap(find.text('Delete (2)')); await tester.pumpAndSettle();
    update(() => records = [rec('1', generation: 'new'), rec('2')]);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete')); await tester.pumpAndSettle();
    expect(calls.single.map((r) => r.id), ['2']);
  });
}

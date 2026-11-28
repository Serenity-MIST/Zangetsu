// Windows "Show download progress on the taskbar button" (dl-11): the
// Download settings switch is saved in DesktopPrefs, turning it off clears
// the bar at once and on brings it back, the bar turns red on a failure,
// clears when the batch ends, combines several downloads, and reaches the
// native runner as the ITaskbarList3 state index + fraction.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/desktop/desktop_native.dart';
import 'package:watch_app/core/desktop/desktop_prefs.dart';
import 'package:watch_app/core/desktop/desktop_shortcuts.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/download/chapter_download_store.dart';
import 'package:watch_app/core/download/chapter_downloader.dart';
import 'package:watch_app/core/download/desktop_download_signals.dart';
import 'package:watch_app/core/mode/content_mode.dart';

/// Chapter queue the test moves by hand (only what the signals read).
class _Chapters extends ChangeNotifier implements ChapterDownloader {
  final live = <String, ChapterDownload>{};
  @override
  Map<String, ChapterDownload> get inFlight => Map.unmodifiable(live);
  void changed() => notifyListeners();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Saved chapter rows, so a chapter that left the queue reads done / failed.
class _Store implements ChapterDownloadStore {
  final rows = <String, ChapterDownload>{};
  @override
  ChapterDownload? get(String id) => rows[id];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ChapterDownload _chapter(
  String id, {
  ChapterDownloadStatus status = ChapterDownloadStatus.downloading,
  int pages = 10,
  int done = 0,
}) => ChapterDownload(
  id: id,
  sourceId: 'src',
  showId: 'show',
  showTitle: 'Show',
  chapterId: id,
  chapterUrl: '/$id',
  chapterTitle: 'Chapter $id',
  mode: ContentMode.manga,
  status: status,
  pageCount: pages,
  pagesDone: done,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late DesktopDownloadSignals signals;
  late _Chapters chapters;
  late _Store store;
  final bar = <(DesktopTaskbarState, double)>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('taskbar_setting_test');
    Hive.init(dir.path);
    DesktopShortcuts.debugReset();
    await DesktopPrefs.init();
    bar.clear();
    signals = DesktopDownloadSignals.forTesting();
    signals.setTaskbar = (state, fraction) async => bar.add((state, fraction));
    signals.notify = (_, _) async {};
    // taskbarEnabled stays the real DesktopPrefs read.
    chapters = _Chapters();
    store = _Store();
    signals.attachChapters(chapters, store);
  });

  tearDown(() async {
    signals.debugReset();
    await Hive.deleteFromDisk();
    await Hive.close();
    DesktopShortcuts.debugReset();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  // Lets the Hive box listener fire after a pref write.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test('the switch is saved, defaults on, and survives a reopen', () async {
    expect(DesktopPrefs.taskbarProgress, isTrue);
    await DesktopPrefs.setTaskbarProgress(false);
    await Hive.close();
    await DesktopPrefs.init();
    expect(DesktopPrefs.taskbarProgress, isFalse);
  });

  test('several downloads combine into one bar, cleared when done', () {
    chapters.live['a'] = _chapter('a', done: 5); // 50%
    chapters.live['b'] = _chapter('b', done: 0); // 0%
    chapters.changed();
    expect(bar.last, (DesktopTaskbarState.normal, .25));

    // 'a' finishes: it still counts as 100% of its share.
    chapters.live.remove('a');
    store.rows['a'] = _chapter('a', status: ChapterDownloadStatus.done);
    chapters.changed();
    expect(bar.last, (DesktopTaskbarState.normal, .5));

    chapters.live.remove('b');
    store.rows['b'] = _chapter('b', status: ChapterDownloadStatus.done);
    chapters.changed();
    expect(bar.last, (DesktopTaskbarState.none, 0.0));
  });

  test('a failure retried inside the same batch is counted once', () {
    chapters.live['a'] = _chapter('a', done: 0);
    chapters.live['b'] = _chapter('b', done: 0);
    chapters.changed();
    chapters.live.remove('a');
    store.rows['a'] = _chapter('a', status: ChapterDownloadStatus.failed);
    chapters.changed();
    // Failed counts as a full share: (1 + 0) / 2.
    expect(bar.last, (DesktopTaskbarState.error, .5));

    // Retried while 'b' still runs: two items, both at 0%, not three with
    // the old failure still counted as done (which read 33%).
    chapters.live['a'] = _chapter('a', done: 0);
    store.rows['a'] = _chapter('a');
    chapters.changed();
    expect(bar.last, (DesktopTaskbarState.indeterminate, 0.0));

    chapters.live['a'] = _chapter('a', done: 5); // 50%
    chapters.changed();
    expect(bar.last, (DesktopTaskbarState.normal, .25));
  });

  test('a failure turns the bar red until it is retried', () {
    chapters.live['a'] = _chapter('a', done: 5);
    chapters.live['b'] = _chapter('b', done: 5);
    chapters.changed();
    chapters.live.remove('a');
    store.rows['a'] = _chapter('a', status: ChapterDownloadStatus.failed);
    chapters.changed();
    expect(bar.last.$1, DesktopTaskbarState.error);

    // Batch ends with the failure still there: stays red at full.
    chapters.live.remove('b');
    store.rows['b'] = _chapter('b', status: ChapterDownloadStatus.done);
    chapters.changed();
    expect(bar.last, (DesktopTaskbarState.error, 1.0));

    // Retried: back in the queue, no longer red.
    chapters.live['a'] = _chapter('a', done: 2);
    store.rows['a'] = _chapter('a');
    chapters.changed();
    expect(bar.last.$1, DesktopTaskbarState.normal);
  });

  test(
    'turning the switch off clears the bar at once, on brings it back',
    () async {
      chapters.live['a'] = _chapter('a', done: 4);
      chapters.changed();
      expect(bar.last, (DesktopTaskbarState.normal, .4));

      // No download event in between: only the pref write.
      await DesktopPrefs.setTaskbarProgress(false);
      await settle();
      expect(bar.last, (DesktopTaskbarState.none, 0.0));

      // Progress moves while off: nothing reaches the taskbar.
      final sent = bar.length;
      chapters.live['a'] = _chapter('a', done: 6);
      chapters.changed();
      expect(bar.length, sent);

      await DesktopPrefs.setTaskbarProgress(true);
      await settle();
      expect(bar.last, (DesktopTaskbarState.normal, .6));
    },
  );

  test(
    'DesktopNative sends the ITaskbarList3 state index and fraction',
    () async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('com.spyou.zangetsu/window');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await DesktopNative.setTaskbarProgress(DesktopTaskbarState.error, 1.5);
      await DesktopNative.setTaskbarProgress(DesktopTaskbarState.none);
      // Runner switch: 0 none, 1 normal, 2 paused, 3 error, 4 indeterminate.
      expect(calls.map((c) => c.method), [
        'setTaskbarProgress',
        'setTaskbarProgress',
      ]);
      expect(Map<String, Object?>.from(calls[0].arguments as Map), {
        'state': 3,
        'fraction': 1.0,
      });
      expect(Map<String, Object?>.from(calls[1].arguments as Map), {
        'state': 0,
        'fraction': 0.0,
      });
    },
    skip: !Platform.isWindows,
  );
}

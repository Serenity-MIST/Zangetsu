import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/desktop/desktop_native.dart';
import 'package:watch_app/core/desktop/desktop_prefs.dart';
import 'package:watch_app/core/desktop/desktop_shortcuts.dart';
import 'package:watch_app/core/download/chapter_download.dart';
import 'package:watch_app/core/download/chapter_download_store.dart';
import 'package:watch_app/core/download/chapter_downloader.dart';
import 'package:watch_app/core/download/desktop_download_signals.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/mode/content_mode.dart';

// Checks the "Notify when downloads finish or fail" switch in Download
// settings end to end: the value is saved in DesktopPrefs, the batch
// notifier reads that saved value (no test override) at the moment a batch
// ends, and which download outcomes produce a Windows notification.

/// Stand-in for the video download manager: only the record list and the
/// change notifications are used by DesktopDownloadSignals.
class _FakeVideos extends ChangeNotifier implements DownloadManager {
  final Map<String, DownloadRecord> records = {};

  @override
  List<DownloadRecord> get all => records.values.toList();

  void set(String id, DownloadStatus status) {
    records[id] = _record(id, status);
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Stand-in for the chapter downloader: only the live queue is read.
class _FakeChapters extends ChangeNotifier implements ChapterDownloader {
  final Map<String, ChapterDownload> live = {};

  @override
  Map<String, ChapterDownload> get inFlight => Map.unmodifiable(live);

  void changed() => notifyListeners();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Stand-in for the chapter store: says how a chapter ended.
class _FakeStore implements ChapterDownloadStore {
  final Map<String, ChapterDownload> saved = {};

  @override
  ChapterDownload? get(String id) => saved[id];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DownloadRecord _record(String id, DownloadStatus status) => DownloadRecord(
  id: id,
  sourceId: 'src',
  showId: 'show',
  showTitle: 'Show',
  showUrl: 'https://example.invalid/show',
  episodeId: id,
  episodeUrl: 'https://example.invalid/$id',
  episodeNumber: double.tryParse(id.replaceAll(RegExp(r'\D'), '')),
  episodeTitle: '',
  category: 'sub',
  quality: 'best',
  status: status,
  createdAt: 0,
);

ChapterDownload _chapter(String id, ChapterDownloadStatus status) =>
    ChapterDownload(
      id: id,
      sourceId: 'src',
      showId: 'manga',
      showTitle: 'Manga',
      chapterId: id,
      chapterUrl: 'https://example.invalid/$id',
      chapterTitle: 'Chapter $id',
      mode: ContentMode.manga,
      status: status,
      pageCount: 10,
    );

void main() {
  late Directory dir;
  late DesktopDownloadSignals signals;
  late _FakeVideos videos;
  late List<(String, String)> notes;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dl_notify_toggle_test');
    Hive.init(dir.path);
    DesktopShortcuts.debugReset();
    await DesktopPrefs.init();
    notes = [];
    signals = DesktopDownloadSignals.forTesting()
      ..setTaskbar = ((DesktopTaskbarState _, double _) async {})
      ..notify = (title, body) async => notes.add((title, body));
    // notificationsEnabled is left as shipped: it reads DesktopPrefs.
    videos = _FakeVideos();
    signals.attachVideos(videos);
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

  /// One episode goes queued -> downloading -> [end].
  void runEpisode(String id, DownloadStatus end) {
    videos.set(id, DownloadStatus.queued);
    videos.set(id, DownloadStatus.downloading);
    videos.set(id, end);
  }

  test('switch is on by default and is saved across a restart', () async {
    expect(DesktopPrefs.downloadNotifications, isTrue);
    await DesktopPrefs.setDownloadNotifications(false);
    expect(DesktopPrefs.downloadNotifications, isFalse);
    // Reopen the box from disk, like the next app start.
    await Hive.close();
    Hive.init(dir.path);
    await DesktopPrefs.init();
    expect(DesktopPrefs.downloadNotifications, isFalse);
    expect(
      Hive.box<dynamic>(DesktopPrefs.boxName).get('download_notifications'),
      isFalse,
    );
  });

  test('on: a finished episode notifies once when the batch ends', () {
    runEpisode('e1', DownloadStatus.done);
    expect(notes, [('Download finished', 'Show · Episode 1 is ready')]);
  });

  test('on: a failed episode notifies', () {
    runEpisode('e2', DownloadStatus.failed);
    expect(notes, hasLength(1));
    expect(notes.single.$1, 'Download failed');
    expect(notes.single.$2, contains('Show · Episode 2'));
  });

  test('off: neither finish nor failure notifies', () async {
    await DesktopPrefs.setDownloadNotifications(false);
    runEpisode('e1', DownloadStatus.done);
    runEpisode('e2', DownloadStatus.failed);
    expect(notes, isEmpty);
  });

  test('flipping it mid-batch: the value at the batch end decides', () async {
    videos.set('e1', DownloadStatus.queued);
    videos.set('e1', DownloadStatus.downloading);
    await DesktopPrefs.setDownloadNotifications(false);
    videos.set('e1', DownloadStatus.done);
    expect(notes, isEmpty);
    // Back on: the next batch notifies again.
    await DesktopPrefs.setDownloadNotifications(true);
    runEpisode('e3', DownloadStatus.done);
    expect(notes, hasLength(1));
  });

  test('several episodes in one batch give one summary notification', () {
    videos.set('e1', DownloadStatus.downloading);
    videos.set('e2', DownloadStatus.downloading);
    videos.set('e3', DownloadStatus.downloading);
    videos.set('e1', DownloadStatus.done);
    videos.set('e2', DownloadStatus.failed);
    expect(notes, isEmpty, reason: 'e3 still running, batch not over');
    videos.set('e3', DownloadStatus.done);
    expect(notes, [('Download failed', 'Show · Episode 2 failed, 2 finished')]);
  });

  test('unsupported (no downloadable source) notifies as a failure', () {
    // "Something goes wrong" includes an episode that could not be
    // downloaded at all; it used to end the batch silently.
    runEpisode('e4', DownloadStatus.unsupported);
    expect(notes, [('Download failed', 'Show · Episode 4 failed')]);
  });

  test('unsupported is counted in a mixed batch summary', () {
    videos.set('e1', DownloadStatus.downloading);
    videos.set('e4', DownloadStatus.resolving);
    videos.set('e4', DownloadStatus.unsupported);
    videos.set('e1', DownloadStatus.done);
    expect(notes, [('Download failed', 'Show · Episode 4 failed, 1 finished')]);
  });

  test('unsupported turns the taskbar red only for its own batch', () {
    // An unsupported entry can never be retried, so it must not keep the
    // bar red after its batch, nor draw a later healthy batch in red.
    final bar = <DesktopTaskbarState>[];
    signals.setTaskbar = (state, _) async => bar.add(state);
    videos.set('e1', DownloadStatus.downloading);
    videos.set('e4', DownloadStatus.resolving);
    videos.set('e4', DownloadStatus.unsupported);
    expect(bar.last, DesktopTaskbarState.error, reason: 'red in its batch');
    videos.set('e1', DownloadStatus.done);
    expect(bar.last, DesktopTaskbarState.none, reason: 'cleared at the end');
    // Next batch, the unsupported record is still in the list.
    videos.set('e5', DownloadStatus.queued);
    videos.set('e5', DownloadStatus.downloading);
    expect(bar.last, isNot(DesktopTaskbarState.error));
    videos.set('e5', DownloadStatus.done);
    expect(bar.last, DesktopTaskbarState.none);
  });

  test('a failed episode still keeps the bar red until it is retried', () {
    final bar = <DesktopTaskbarState>[];
    signals.setTaskbar = (state, _) async => bar.add(state);
    runEpisode('e2', DownloadStatus.failed);
    expect(bar.last, DesktopTaskbarState.error);
    runEpisode('e2', DownloadStatus.done);
    expect(bar.last, DesktopTaskbarState.none);
  });

  test('a failure retried and finished inside the batch is not reported '
      'as failed', () {
    videos.set('e1', DownloadStatus.downloading);
    videos.set('e2', DownloadStatus.downloading);
    videos.set('e2', DownloadStatus.failed);
    // Retry while e1 still runs, then both finish.
    videos.set('e2', DownloadStatus.queued);
    videos.set('e2', DownloadStatus.downloading);
    videos.set('e2', DownloadStatus.done);
    videos.set('e1', DownloadStatus.done);
    expect(notes, [('Downloads finished', '2 downloads are ready')]);
  });

  test('cancel and pause do not notify', () {
    runEpisode('e5', DownloadStatus.canceled);
    videos.set('e6', DownloadStatus.downloading);
    videos.set('e6', DownloadStatus.paused);
    expect(notes, isEmpty);
  });

  test('chapters: done and failed notify, off silences them', () async {
    final chapters = _FakeChapters();
    final store = _FakeStore();
    signals.attachChapters(chapters, store);

    chapters.live['c1'] = _chapter('c1', ChapterDownloadStatus.downloading);
    chapters.changed();
    chapters.live.remove('c1');
    store.saved['c1'] = _chapter('c1', ChapterDownloadStatus.failed);
    chapters.changed();
    expect(notes, hasLength(1));
    expect(notes.single.$2, contains('Manga · Chapter c1'));

    await DesktopPrefs.setDownloadNotifications(false);
    chapters.live['c2'] = _chapter('c2', ChapterDownloadStatus.downloading);
    chapters.changed();
    chapters.live.remove('c2');
    store.saved['c2'] = _chapter('c2', ChapterDownloadStatus.done);
    chapters.changed();
    expect(notes, hasLength(1));
  });
}

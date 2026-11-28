// Playing a downloaded episode on Windows adds the show to My List as
// Watching, the same way pressing Play online does, without adding made-up
// shows for files found on disk or a second copy of a show already listed.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/library_repair.dart';
import 'package:watch_app/core/playback/list_status_store.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/privacy/incognito_mode.dart';
import 'package:watch_app/core/supabase/auth_user.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/downloads/downloaded_my_list_add.dart';

DownloadRecord _record({
  String sourceId = 'zm',
  String showId = 'mal:61316',
  String showUrl = 'zm://anime/mal:61316',
  int? malId = 61316,
  int? tmdbId,
  bool recovered = false,
}) => DownloadRecord(
  id: 'r1',
  sourceId: sourceId,
  showId: showId,
  showTitle: 'Re:ZERO Season 4',
  showUrl: showUrl,
  episodeId: 'e12',
  episodeUrl: 'zm://anime/mal:61316/ep/12',
  episodeNumber: 12,
  episodeTitle: 'Episode 12',
  category: 'dub',
  quality: 'best',
  status: DownloadStatus.done,
  filePath: 'C:/Downloads/e12.ts',
  malId: malId,
  tmdbId: tmdbId,
  recoveredFromDisk: recovered,
  createdAt: 0,
);

const _online = MediaItem(
  id: 'mal:61316',
  title: 'Re:ZERO Season 4',
  url: 'zm://anime/mal:61316',
  sourceId: 'zm',
  type: ProviderType.anime,
  malId: 61316,
);

MediaItem? _decide(
  DownloadRecord record, {
  MediaItem? listItem,
  bool signedIn = true,
  bool autoAdd = true,
  bool incognito = false,
  List<MediaItem> listed = const [],
}) {
  final keys = {for (final m in listed) libraryStorageKey(m)};
  return downloadedShowToAutoAdd(
    record: record,
    listItem: listItem,
    signedIn: signedIn,
    autoAddEnabled: autoAdd,
    incognito: incognito,
    contains: (m) => keys.contains(libraryStorageKey(m)),
    listed: () => listed,
  );
}

class _FakeMyList implements MyListStore {
  _FakeMyList(this.items);
  final List<MediaItem> items;
  int adds = 0;
  int statusPushes = 0;

  /// Stands in for a sign-in with no account behind it: add does nothing.
  bool noAccount = false;

  /// Runs while an add is saving, like a cloud pull arriving.
  void Function()? duringAdd;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  bool contains(MediaItem m) =>
      items.any((x) => libraryStorageKey(x) == libraryStorageKey(m));

  @override
  List<MediaItem> all() => List.of(items);

  @override
  Future<void> add(MediaItem m) async {
    if (noAccount || contains(m)) return;
    adds++;
    items.add(m);
    duringAdd?.call();
  }

  @override
  Future<void> pushStatus(MediaItem m) async => statusPushes++;
}

class _FakeStatus implements ListStatusStore {
  final Map<String, WatchStatus> byKey = {};

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  WatchStatus? statusOf(MediaItem m) => byKey[libraryStorageKey(m)];

  @override
  Future<void> setStatus(MediaItem m, WatchStatus status) async =>
      byKey[libraryStorageKey(m)] = status;
}

class _FakePrefs implements PlaybackPrefs {
  bool autoAdd = true;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  bool get autoAddToMyList => autoAdd;
}

class _TestAuthCubit extends Cubit<AuthState> implements AuthCubit {
  _TestAuthCubit({required bool signedIn})
    : super(
        signedIn
            ? const AuthState(
                status: AuthStatus.authenticated,
                user: AuthUser(
                  id: 'test-user',
                  name: 'Test user',
                  email: 'test@example.com',
                ),
              )
            : const AuthState(status: AuthStatus.unauthenticated),
      );

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('which show a downloaded episode adds', () {
    test('a catalogue download adds the same entry online Play makes', () {
      final item = _decide(_record());
      expect(item, isNotNull);
      expect(libraryStorageKey(item!), libraryStorageKey(_online));
      expect(item.malId, 61316);
    });

    test('nothing when that show is already listed', () {
      expect(_decide(_record(), listed: [_online]), isNull);
    });

    test('nothing when the same MAL id is listed under another source', () {
      final fromSource = _online.copyWith(
        id: '/watch/rezero-4',
        url: '/watch/rezero-4',
        sourceId: 'ani:4697',
      );
      expect(_decide(_record(), listed: [fromSource]), isNull);
      // And the other way round: a source download of a show listed as zm.
      final sourceRecord = _record(
        sourceId: 'ani:4697',
        showId: '/watch/rezero-4',
        showUrl: '/watch/rezero-4',
      );
      expect(_decide(sourceRecord, listed: [_online]), isNull);
    });

    test('a manga with the same MAL number does not count as listed', () {
      final manga = _online.copyWith(
        id: 'mal:61316',
        url: 'zm://manga/mal:61316',
        type: ProviderType.manga,
      );
      expect(_decide(_record(), listed: [manga]), isNotNull);
      expect(
        _decide(_record(), listed: [manga.copyWith(type: ProviderType.novel)]),
        isNotNull,
      );
    });

    test('nothing when the same TMDB show is listed', () {
      MediaItem listedAs({required bool tv}) => MediaItem(
        id: tv ? 'tmdb:tv:1' : 'tmdb:movie:1',
        title: 'Show',
        url: tv ? 'zm://tv/tmdb:1' : 'zm://movie/tmdb:1',
        sourceId: 'zm',
        type: ProviderType.movie,
        tmdbId: 1,
        tmdbIsTv: tv,
      );
      final record = _record(
        sourceId: 'stremio',
        showId: 'tt1',
        showUrl: 'https://example.invalid/tt1',
        malId: null,
        tmdbId: 1,
      );
      // The record's TMDB kind defaults to a movie, so it is a different show.
      expect(_decide(record, listed: [listedAs(tv: true)]), isNotNull);
      expect(_decide(record, listed: [listedAs(tv: false)]), isNull);
    });

    test('a source download keeps its own source identity', () {
      final record = _record(
        sourceId: 'ani:4697',
        showId: '/watch/rezero-4',
        showUrl: '/watch/rezero-4',
        malId: null,
      );
      final item = _decide(record)!;
      expect(item.sourceId, 'ani:4697');
      expect(item.id, '/watch/rezero-4');
      expect(item.url, '/watch/rezero-4');
    });

    test('files found on disk never add a made-up show', () {
      expect(
        _decide(
          _record(
            sourceId: 'local-files',
            showId: 'local:abc',
            showUrl: 'file:///C:/Downloads/ReZero',
            malId: null,
          ),
        ),
        isNull,
      );
      expect(
        _decide(_record(sourceId: 'ani:1', showId: 'local:abc', showUrl: '/x')),
        isNull,
      );
      expect(
        _decide(
          _record(
            sourceId: 'ani:1',
            showId: '/x',
            showUrl: 'file:///C:/Downloads/x',
          ),
        ),
        isNull,
      );
      expect(
        _decide(
          _record(
            sourceId: 'ani:1',
            showId: '/x',
            showUrl: '/x',
            recovered: true,
          ),
        ),
        isNull,
      );
    });

    test('setting off, incognito or signed out add nothing', () {
      expect(_decide(_record(), autoAdd: false), isNull);
      expect(_decide(_record(), incognito: true), isNull);
      expect(_decide(_record(), signedIn: false), isNull);
      expect(_decide(_record(), listItem: _online, incognito: true), isNull);
    });

    test('the online page adds its own item', () {
      final page = _online.copyWith(id: 'mal:61316');
      final sourceRecord = _record(
        sourceId: 'ani:4697',
        showId: '/watch/rezero-4',
        showUrl: '/watch/rezero-4',
      );
      expect(_decide(sourceRecord, listItem: page), same(page));
      expect(_decide(sourceRecord, listItem: page, listed: [_online]), isNull);
    });

    test('a page for files found on disk adds nothing', () {
      const local = MediaItem(
        id: 'local:abc',
        title: 'ReZero',
        url: 'file:///C:/Downloads/ReZero',
        sourceId: 'local-files',
        type: ProviderType.anime,
      );
      expect(_decide(_record(), listItem: local), isNull);
    });
  });

  group('adding to My List', () {
    late _FakeMyList list;
    late _FakeStatus status;
    late _FakePrefs prefs;

    void wire({bool signedIn = true, List<MediaItem> items = const []}) {
      list = _FakeMyList(List.of(items));
      status = _FakeStatus();
      prefs = _FakePrefs();
      sl
        ..registerSingleton<MyListStore>(list)
        ..registerSingleton<ListStatusStore>(status)
        ..registerSingleton<PlaybackPrefs>(prefs)
        ..registerSingleton<AuthCubit>(_TestAuthCubit(signedIn: signedIn));
    }

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    });

    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      IncognitoMode.notifier.value = false;
      await sl.reset();
    });

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('adds the show once, as Watching', () async {
      wire();
      maybeAddDownloadedShowToMyList(_record());
      await settle();
      maybeAddDownloadedShowToMyList(_record());
      await settle();
      expect(list.adds, 1);
      expect(status.statusOf(_online), WatchStatus.watching);
      expect(list.statusPushes, 1);
    });

    test('no stray status when the add does nothing', () async {
      wire();
      list.noAccount = true;
      maybeAddDownloadedShowToMyList(_record());
      await settle();
      expect(list.adds, 0);
      expect(status.byKey, isEmpty);
      expect(list.statusPushes, 0);
    });

    test('a status a cloud pull brings in during the add is kept', () async {
      wire();
      list.duringAdd = () =>
          status.byKey[libraryStorageKey(_online)] = WatchStatus.completed;
      maybeAddDownloadedShowToMyList(_record());
      await settle();
      expect(list.adds, 1);
      expect(status.statusOf(_online), WatchStatus.completed);
    });

    test('a Completed show stays Completed', () async {
      wire(items: [_online]);
      await status.setStatus(_online, WatchStatus.completed);
      maybeAddDownloadedShowToMyList(_record());
      await settle();
      expect(list.adds, 0);
      expect(status.statusOf(_online), WatchStatus.completed);
    });

    test('incognito, signed out or setting off add nothing', () async {
      wire();
      IncognitoMode.notifier.value = true;
      maybeAddDownloadedShowToMyList(_record());
      await settle();
      expect(list.adds, 0);
      IncognitoMode.notifier.value = false;
      prefs.autoAdd = false;
      maybeAddDownloadedShowToMyList(_record());
      await settle();
      expect(list.adds, 0);
      await sl.reset();
      wire(signedIn: false);
      maybeAddDownloadedShowToMyList(_record());
      await settle();
      expect(list.adds, 0);
      expect(status.byKey, isEmpty);
    });

    test('off Windows nothing changes', () async {
      wire();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      maybeAddDownloadedShowToMyList(_record());
      await settle();
      expect(list.adds, 0);
    });
  });

  test('both play paths hand the show over', () {
    final screen = File(
      'lib/features/downloads/downloads_screen.dart',
    ).readAsStringSync();
    expect(
      screen,
      contains('maybeAddDownloadedShowToMyList(record, listItem: listItem)'),
    );
    final detail = File(
      'lib/features/detail/detail_screen.dart',
    ).readAsStringSync();
    expect(detail, contains('listItem: widget.item,'));
  });
}

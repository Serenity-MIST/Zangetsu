import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/anilist/anilist_api.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/mangabaka_service.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_sync_queue.dart';

// track-2: AniList and MangaBaka report each write's outcome to the sync
// outbox (TrackerWriteScope), so failed writes are queued and a dead login
// shows "needs sign-in".

/// A Dio whose every request answers [status] (or [byMethod] per method).
Dio _dioAnswering(
  int status, {
  Map<String, int> byMethod = const {},
  List<RequestOptions>? seen,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        seen?.add(request);
        handler.resolve(
          Response(
            requestOptions: request,
            statusCode: byMethod[request.method] ?? status,
            data: <String, dynamic>{},
          ),
        );
      },
    ),
  );
  return dio;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AniList _gql', () {
    test('a 401 with a token reports needs sign-in', () async {
      final api = AniListApi(_dioAnswering(401), () => 'token');
      final report = await TrackerWriteScope.run(() async {
        expect(await api.saveStatus(mediaId: 1, status: 'CURRENT'), isFalse);
      });
      expect(report.problem, TrackerWriteProblem.auth);
    });

    test('an anonymous 403 is not reported as a lost login', () async {
      final seen = <RequestOptions>[];
      final api = AniListApi(_dioAnswering(403, seen: seen), () => null);
      final report = await TrackerWriteScope.run(() async {
        // A public lookup with no token goes out anonymously.
        expect(await api.mediaByMalId(1), isNull);
      });
      expect(seen, hasLength(1));
      expect(seen.single.headers.containsKey('Authorization'), isFalse);
      expect(report.problem, isNull);
    });

    test('outside a watched write nothing throws', () async {
      final api = AniListApi(_dioAnswering(401), () => 'token');
      expect(await api.saveStatus(mediaId: 1, status: 'CURRENT'), isFalse);
    });
  });

  group('MangaBaka writes', () {
    late Directory dir;

    setUpAll(() {
      // MangaBakaService listens on the app_links channel.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/events'),
            (_) async => null,
          );
    });

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('mb_report_test');
      Hive.init(dir.path);
      await MangaBakaService.init();
    });

    tearDown(() async {
      await Hive.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    /// A connected service whose requests answer as given.
    Future<MangaBakaService> connected(
      int status, {
      Map<String, int> byMethod = const {},
      List<RequestOptions>? seen,
    }) async {
      final svc = MangaBakaService(
        _dioAnswering(status, byMethod: byMethod, seen: seen),
      );
      addTearDown(svc.dispose);
      await svc.importSession({'accessToken': 'access'});
      return svc;
    }

    Future<TrackerWriteReport> edit(MangaBakaService svc) =>
        TrackerWriteScope.run(
          () => svc.updateEntry(
            pinnedId: '42',
            status: WatchStatus.watching,
            kind: MediaKind.manga,
          ),
        );

    test('a 2xx edit counts as sent', () async {
      final report = await edit(await connected(200));
      expect(report.sent, isTrue);
      expect(report.ok, isTrue);
    });

    test('a 404 edit falls back to the add, which is the write', () async {
      final seen = <RequestOptions>[];
      final svc = await connected(
        200,
        byMethod: const {'PATCH': 404},
        seen: seen,
      );
      final report = await edit(svc);
      expect(seen.map((r) => r.method), containsAllInOrder(['PATCH', 'POST']));
      expect(report.sent, isTrue);
      expect(report.ok, isTrue);
    });

    test('a refused add is reported as rejected', () async {
      final svc = await connected(
        200,
        byMethod: const {'PATCH': 404, 'POST': 400},
      );
      final report = await edit(svc);
      expect(report.sent, isFalse);
      expect(report.problem, TrackerWriteProblem.rejected);
    });

    test('a 401 without a refresh token reports needs sign-in', () async {
      final report = await edit(await connected(401));
      expect(report.problem, TrackerWriteProblem.auth);
    });

    test('removing an entry that is already gone counts as sent', () async {
      final svc = await connected(404);
      final report = await TrackerWriteScope.run(
        () => svc.removeFromList(pinnedId: '42', kind: MediaKind.manga),
      );
      expect(report.sent, isTrue);
      expect(report.ok, isTrue);
    });
  });
}

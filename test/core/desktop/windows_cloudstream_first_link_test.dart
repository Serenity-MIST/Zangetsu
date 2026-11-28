// Windows CloudStream: playback starts on the first link while the engine
// keeps collecting the rest (plan item C1). No Java is needed: the session
// logic is tested with a fake engine call, and the whole Windows wiring
// (DesktopCloudStream + the cs3_engine transport) with a fake engine process
// (fake_cs3_engine.dart, run by the Dart that ships with Flutter).
import 'dart:async';
import 'dart:io';

import 'package:cs3_engine/cs3_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:watch_app/core/desktop/cloudstream_link_sessions.dart';
import 'package:watch_app/core/desktop/cloudstream_runtime.dart';

/// A fake engine links call the test finishes by hand.
class _FakeCall {
  final tags = <String>[];
  final cancelled = <String>[];
  final answer = Completer<Map<String, dynamic>>();

  Future<Map<String, dynamic>> call(String tag) {
    tags.add(tag);
    return answer.future;
  }

  Future<void> cancel(String tag) async => cancelled.add(tag);
}

Map<String, dynamic> _link(int n) => {
  'name': 'Mirror $n',
  'url': 'https://video.example/$n.m3u8',
  'type': 'M3U8',
};

List<String> _urls(Map<String, dynamic> result) => [
  for (final source in result['sources'] as List) '${source['url']}',
];

/// The Dart that ships with the Flutter running this test, or null.
String? _flutterDart() {
  var dir = File(Platform.resolvedExecutable).parent;
  while (p.basename(dir.path) != 'cache' && dir.parent.path != dir.path) {
    dir = dir.parent;
  }
  final dart = File(
    p.join(dir.path, 'dart-sdk', 'bin', Platform.isWindows ? 'dart.exe' : 'dart'),
  );
  return dart.existsSync() ? dart.path : null;
}

void main() {
  group('CloudStreamLinkSessions', () {
    CloudStreamLinkSessions sessions() => CloudStreamLinkSessions(
      grace: const Duration(milliseconds: 40),
      fastCap: const Duration(seconds: 2),
    );

    test('a fast request returns on the first link with done false', () async {
      final links = sessions();
      final fake = _FakeCall();
      final watch = Stopwatch()..start();
      final pending = links.load(
        'p|ep',
        fast: true,
        call: fake.call,
        cancel: fake.cancel,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      links.handleEvent({'event': 'link', 'tag': fake.tags.single, 'link': _link(1)});
      final result = await pending;
      expect(_urls(result), ['https://video.example/1.m3u8']);
      expect(result['done'], isFalse);
      expect(result['sources'][0]['isM3u8'], isTrue);
      // It did not wait for the engine's full answer (which never came).
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(fake.answer.isCompleted, isFalse);
    });

    test('poll returns later links, then done after linksDone and the answer', () async {
      final links = sessions();
      final fake = _FakeCall();
      final pending = links.load('p|ep', fast: true, call: fake.call);
      final tag = fake.tags.single;
      links.handleEvent({'event': 'link', 'tag': tag, 'link': _link(1)});
      await pending;

      links.handleEvent({'event': 'link', 'tag': tag, 'link': _link(2)});
      final subtitle = {'lang': 'English', 'url': 'https://video.example/en.vtt'};
      links.handleEvent({'event': 'subtitle', 'tag': tag, 'subtitle': subtitle});
      // A repeated subtitle address is dropped, as the engine's answer does.
      links.handleEvent({'event': 'subtitle', 'tag': tag, 'subtitle': subtitle});
      var polled = links.poll('p|ep')!;
      expect(_urls(polled), [
        'https://video.example/1.m3u8',
        'https://video.example/2.m3u8',
      ]);
      expect(polled['subtitles'], hasLength(1));
      expect(polled['done'], isFalse);

      links.handleEvent({'event': 'linksDone', 'tag': tag, 'completed': true});
      expect(links.poll('p|ep')!['done'], isTrue);

      fake.answer.complete({
        'links': [_link(1), _link(2)],
        'subtitles': [subtitle],
        'completed': true,
      });
      await Future<void>.delayed(Duration.zero);
      polled = links.poll('p|ep')!;
      expect(polled['done'], isTrue);
      expect(_urls(polled), hasLength(2));
      // A late event after the end changes nothing.
      links.handleEvent({'event': 'link', 'tag': tag, 'link': _link(3)});
      expect(_urls(links.poll('p|ep')!), hasLength(2));
    });

    test('a full request joins the running call and returns the full answer', () async {
      final links = sessions();
      final fake = _FakeCall();
      final fast = links.load('p|ep', fast: true, call: fake.call);
      links.handleEvent({'event': 'link', 'tag': fake.tags.single, 'link': _link(1)});
      await fast;
      final full = links.load('p|ep', fast: false, call: fake.call);
      // No second scrape of the site for the same episode.
      expect(fake.tags, hasLength(1));
      fake.answer.complete({'links': [_link(1), _link(2)], 'subtitles': []});
      final result = await full;
      expect(_urls(result), hasLength(2));
      expect(result['done'], isTrue);
    });

    test('with no link yet a fast request waits for the answer, errors as before', () async {
      final links = sessions();
      final fake = _FakeCall();
      final pending = links.load('p|ep', fast: true, call: fake.call);
      // Past the cap: still waiting, a slow source is not cut short.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      fake.answer.complete({'links': [], 'error': 'site down'});
      await expectLater(pending, throwsA(isA<StateError>()));
      expect(links.poll('p|ep')!['done'], isTrue);
    });

    test('the answer arriving inside the grace wait is returned in full', () async {
      final links = CloudStreamLinkSessions(
        grace: const Duration(seconds: 5),
        fastCap: const Duration(seconds: 10),
      );
      final fake = _FakeCall();
      final pending = links.load('p|ep', fast: true, call: fake.call);
      links.handleEvent({'event': 'link', 'tag': fake.tags.single, 'link': _link(1)});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      fake.answer.complete({'links': [_link(1), _link(2)], 'subtitles': []});
      final result = await pending.timeout(const Duration(seconds: 1));
      expect(_urls(result), hasLength(2));
      expect(result['done'], isTrue);
    });

    test('cancel drops the session and stops the engine call', () async {
      final links = sessions();
      final fake = _FakeCall();
      final pending = links.load(
        'p|ep',
        fast: true,
        call: fake.call,
        cancel: fake.cancel,
      );
      final tag = fake.tags.single;
      links.handleEvent({'event': 'link', 'tag': tag, 'link': _link(1)});
      await pending;
      links.cancel('p|ep');
      expect(fake.cancelled, [tag]);
      expect(links.poll('p|ep'), isNull);
      // Its later events are ignored, and a new request starts a new call.
      links.handleEvent({'event': 'link', 'tag': tag, 'link': _link(2)});
      unawaited(links.load('p|ep', fast: false, call: fake.call));
      expect(fake.tags, hasLength(2));
    });

    test('a cancel does not stop a call a full request waits on', () async {
      final links = sessions();
      final fake = _FakeCall();
      final fast = links.load(
        'p|ep',
        fast: true,
        call: fake.call,
        cancel: fake.cancel,
      );
      links.handleEvent({'event': 'link', 'tag': fake.tags.single, 'link': _link(1)});
      await fast;
      // A download joins the running call, then the player is closed.
      final full = links.load('p|ep', fast: false, call: fake.call);
      links.cancel('p|ep');
      expect(fake.cancelled, isEmpty);
      // The session is kept, so the poll still reads the links coming in.
      expect(links.poll('p|ep')!['done'], isFalse);
      fake.answer.complete({'links': [_link(1), _link(2)], 'subtitles': []});
      expect(_urls(await full), hasLength(2));
      // Once nobody waits for the full answer, a cancel works as before.
      links.cancel('p|ep');
      expect(links.poll('p|ep'), isNull);
    });

    test('a download alone is not stopped by a cancel either', () async {
      final links = sessions();
      final fake = _FakeCall();
      final full = links.load(
        'p|ep',
        fast: false,
        call: fake.call,
        cancel: fake.cancel,
      );
      links.cancel('p|ep');
      expect(fake.cancelled, isEmpty);
      fake.answer.complete({'links': [_link(1)], 'subtitles': []});
      expect(_urls(await full), hasLength(1));
    });

    test('past maxSessions the oldest call is stopped, unless a download waits on it', () async {
      final links = CloudStreamLinkSessions(maxSessions: 2);
      final calls = [for (var i = 0; i < 4; i++) _FakeCall()];
      unawaited(links.load('a', fast: false, call: calls[0].call, cancel: calls[0].cancel));
      unawaited(links.load('b', fast: true, call: calls[1].call, cancel: calls[1].cancel));
      // 'a' is the oldest, but a full request waits on it: only forgotten.
      unawaited(links.load('c', fast: true, call: calls[2].call, cancel: calls[2].cancel));
      expect(calls[0].cancelled, isEmpty);
      expect(links.poll('a'), isNull);
      // 'b' is now the oldest and only playback waited on it: stopped.
      unawaited(links.load('d', fast: true, call: calls[3].call, cancel: calls[3].cancel));
      expect(calls[1].cancelled, calls[1].tags);
      expect(links.poll('b'), isNull);
      expect(links.poll('c'), isNotNull);
      expect(links.poll('d'), isNotNull);
    });

    test('other engine events are left to the caller', () {
      expect(sessions().handleEvent({'event': 'webRequest', 'rid': 1}), isFalse);
    });
  });

  group('DesktopCloudStream with a fake engine process', () {
    final dart = _flutterDart();
    final script = p.join(
      Directory.current.path,
      'test',
      'core',
      'desktop',
      'fake_cs3_engine.dart',
    );

    late Directory temp;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('cs3-first-link-');
      Hive.init(temp.path);
      final box = await Hive.openBox<dynamic>('desktop_cs_plugins');
      final plugin = File(p.join(temp.path, 'Fake.cs3'))..writeAsStringSync('');
      await box.put('Fake@1@x', {
        'id': 'Fake@1@x',
        'path': plugin.path,
        'url': 'https://repo.example/Fake.cs3',
        'providers': [
          {'name': 'Fake', 'mainUrl': 'https://fake.example'},
        ],
      });
    });
    tearDown(() async {
      await Hive.close();
      await temp.delete(recursive: true);
    });

    // Where the fake engine writes each cancelLinks tag it receives.
    File cancelLog() => File(p.join(temp.path, 'cancels.txt'));

    DesktopCloudStream host(String generation) => DesktopCloudStream(
      dataDirectory: temp,
      relocatePluginPath: (path) => path,
      engineFactory: (path) => Cs3Engine.start(
        dataDir: path,
        java: dart!,
        // The script goes where JVM options would, so the fake engine runs.
        jvmArgs: [script, generation, cancelLog().path],
        assetsDirectory: temp.path,
      ),
    );

    const args = {'name': 'Fake@1@x\u0001Fake', 'data': 'ep1', 'fast': true};
    const key = {'name': 'Fake@1@x\u0001Fake', 'data': 'ep1'};

    test('a new engine: first link early, later links through the poll', () async {
      final cs = host('events');
      addTearDown(cs.dispose);
      // Start the engine first so the timing below is only the links call.
      await cs.call('liveMainUrl', {'name': 'Fake@1@x\u0001Fake'}).catchError((_) {});
      final watch = Stopwatch()..start();
      final first = await cs.call('loadLinks', args) as Map<String, dynamic>;
      expect(watch.elapsedMilliseconds, lessThan(1400));
      expect(_urls(first), ['https://video.example/ep1/1.m3u8']);
      expect(first['done'], isFalse);

      var polled = await cs.call('pollLinks', key) as Map<String, dynamic>;
      expect(polled['done'], isFalse);
      // The engine keeps collecting: the slow mirror and the end arrive later.
      await Future<void>.delayed(const Duration(milliseconds: 2600));
      polled = await cs.call('pollLinks', key) as Map<String, dynamic>;
      expect(_urls(polled), [
        'https://video.example/ep1/1.m3u8',
        'https://video.example/ep1/2.m3u8',
      ]);
      expect(polled['subtitles'], hasLength(1));
      expect(polled['done'], isTrue);
    }, skip: dart == null ? 'Flutter Dart not found' : false);

    test('an old engine (no link events): waits for every link, as before', () async {
      final cs = host('old');
      addTearDown(cs.dispose);
      await cs.call('liveMainUrl', {'name': 'Fake@1@x\u0001Fake'}).catchError((_) {});
      final watch = Stopwatch()..start();
      final result = await cs.call('loadLinks', args) as Map<String, dynamic>;
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(2400));
      expect(_urls(result), hasLength(2));
      expect(result['done'], isTrue);
      final polled = await cs.call('pollLinks', key) as Map<String, dynamic>;
      expect(polled, result);
    }, skip: dart == null ? 'Flutter Dart not found' : false);

    test('cancelLinks stops the engine call and the poll reads done', () async {
      final cs = host('events');
      addTearDown(cs.dispose);
      await cs.call('liveMainUrl', {'name': 'Fake@1@x\u0001Fake'}).catchError((_) {});
      final first = await cs.call('loadLinks', args) as Map<String, dynamic>;
      expect(first['done'], isFalse);
      await cs.call('cancelLinks', key);
      final polled = await cs.call('pollLinks', key) as Map<String, dynamic>;
      expect(polled['sources'], isEmpty);
      expect(polled['done'], isTrue);
      // The cancel reached the engine (it is sent without waiting).
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (!(cancelLog().existsSync() &&
              cancelLog().readAsStringSync().trim().isNotEmpty) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(cancelLog().readAsLinesSync(), hasLength(1));
      // The engine stopped the call: a full request now starts a fresh one
      // that still answers normally.
      final again = await cs.call('loadLinks', {...args, 'fast': false})
          as Map<String, dynamic>;
      expect(_urls(again), hasLength(2));
    }, skip: dart == null ? 'Flutter Dart not found' : false);

    test('closing the player does not stop a download of the same episode', () async {
      final cs = host('events');
      addTearDown(cs.dispose);
      await cs.call('liveMainUrl', {'name': 'Fake@1@x\u0001Fake'}).catchError((_) {});
      final first = await cs.call('loadLinks', args) as Map<String, dynamic>;
      expect(first['done'], isFalse);
      // A download of the same episode joins the running call...
      final download = cs.call('loadLinks', {...args, 'fast': false});
      // (It first passes the runtime's own setup steps; let it get there.)
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // ...and then the player is closed, which cancels every running hunt.
      await cs.call('cancelLinks', key);
      final result = await download as Map<String, dynamic>;
      // Every link, not the one found before the cancel.
      expect(_urls(result), hasLength(2));
      expect(cancelLog().existsSync(), isFalse);
    }, skip: dart == null ? 'Flutter Dart not found' : false);
  });
}

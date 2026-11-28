// Plan item R5: on Windows the mpv player keeps collecting late mirrors for
// about 60 s after playback starts (desktop_late_mirrors.dart). These tests
// drive the poll with a fake poller and no real waiting.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/features/player/desktop_late_mirrors.dart';

typedef _Read = ({List<VideoSource> sources, bool done});

VideoSource _src(String url) => VideoSource(url: url);

/// A fake poller: hands out [reads] one by one (the last one again once
/// they run out) and counts how often it was asked.
class _FakePoll {
  _FakePoll(this.reads);

  final List<_Read> reads;
  int calls = 0;

  Future<_Read> call() async {
    final read = reads[calls < reads.length ? calls : reads.length - 1];
    calls++;
    return read;
  }
}

/// The player's Sources list, as the poll sees and changes it.
class _List {
  _List(this.sources);

  List<VideoSource> sources;
  int adds = 0;

  void add(List<VideoSource> extra) {
    adds++;
    sources = [...sources, ...extra];
  }
}

/// No real waiting: ten steps, like the real ~60 s schedule.
final _instant = List<Duration>.filled(10, Duration.zero);

void main() {
  group('desktopLateMirrorsEnabled', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('on for Windows', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(desktopLateMirrorsEnabled, isTrue);
    });

    test('off for Android, so the phone keeps the shared poll', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(desktopLateMirrorsEnabled, isFalse);
    });
  });

  test('the schedule covers about 60 s, like the phone', () {
    final total = kDesktopLateMirrorDelays.fold<Duration>(
      Duration.zero,
      (a, b) => a + b,
    );
    expect(total.inSeconds, inInclusiveRange(55, 65));
  });

  group('desktopLateMirrorPoller', () {
    test("the launcher's poller always wins", () {
      expect(
        desktopLateMirrorPoller(isWindows: true, given: 'show', fallback: 'x'),
        'show',
      );
      expect(
        desktopLateMirrorPoller(isWindows: false, given: 'show', fallback: 'x'),
        'show',
      );
    });

    test('Windows falls back when the launcher passed none', () {
      expect(
        desktopLateMirrorPoller<String>(
          isWindows: true,
          given: null,
          fallback: 'fallback',
        ),
        'fallback',
      );
    });

    test('the phone gets no poller when none was passed (unchanged)', () {
      expect(
        desktopLateMirrorPoller<String>(
          isWindows: false,
          given: null,
          fallback: 'fallback',
        ),
        isNull,
      );
    });
  });

  group('pollDesktopLateMirrors', () {
    test(
      'adds late mirrors after the playing one, without duplicates',
      () async {
        final playing = _src('https://a/1');
        final list = _List([playing]);
        final poll = _FakePoll([
          (sources: [playing], done: false),
          (sources: [playing, _src('https://a/2')], done: false),
          (
            sources: [playing, _src('https://a/2'), _src('https://a/3')],
            done: true,
          ),
        ]);
        await pollDesktopLateMirrors(
          poll: poll.call,
          isCurrent: () => true,
          currentSources: () => list.sources,
          add: list.add,
          delays: _instant,
        );
        expect(list.sources.map((s) => s.url), [
          'https://a/1',
          'https://a/2',
          'https://a/3',
        ]);
        // The playing link keeps its place and is the same object.
        expect(identical(list.sources.first, playing), isTrue);
        // Stopped at "done": three reads, not ten.
        expect(poll.calls, 3);
        // Nothing emitted for the read that brought nothing new.
        expect(list.adds, 2);
      },
    );

    test('keeps reading for the whole schedule while more may come', () async {
      final list = _List([_src('https://a/1')]);
      final poll = _FakePoll([(sources: <VideoSource>[], done: false)]);
      await pollDesktopLateMirrors(
        poll: poll.call,
        isCurrent: () => true,
        currentSources: () => list.sources,
        add: list.add,
        delays: _instant,
      );
      expect(poll.calls, 10);
      expect(list.adds, 0);
    });

    test('stops when the episode changes or the player closes', () async {
      final list = _List([_src('https://a/1')]);
      var current = true;
      var calls = 0;
      await pollDesktopLateMirrors(
        poll: () async {
          calls++;
          // The viewer moved on while this read was running.
          current = false;
          return (sources: [_src('https://a/2')], done: false);
        },
        isCurrent: () => current,
        currentSources: () => list.sources,
        add: list.add,
        delays: _instant,
      );
      expect(calls, 1);
      // The read that came back after the change adds nothing.
      expect(list.sources.map((s) => s.url), ['https://a/1']);
    });

    test('a replaced poll (newer run) ends at its next step', () async {
      final list = _List([_src('https://a/1')]);
      var run = 1;
      const mine = 1;
      final poll = _FakePoll([(sources: <VideoSource>[], done: false)]);
      final running = pollDesktopLateMirrors(
        poll: () {
          // A second poll starts (or fresh links replaced the list).
          if (poll.calls == 1) run = 2;
          return poll.call();
        },
        isCurrent: () => run == mine,
        currentSources: () => list.sources,
        add: list.add,
        delays: _instant,
      );
      await running;
      expect(poll.calls, 2);
    });

    test('stops when the playing source is no longer known', () async {
      final list = _List([_src('https://a/1')]);
      final poll = _FakePoll([(sources: <VideoSource>[], done: false)]);
      var known = true;
      await pollDesktopLateMirrors(
        poll: () {
          known = false; // the player is moving to another source
          return poll.call();
        },
        isCurrent: () => true,
        currentSources: () => list.sources,
        add: list.add,
        canPoll: () => known,
        delays: _instant,
      );
      // One read, then the next step saw the source was gone and stopped
      // instead of asking (which could start a whole new search).
      expect(poll.calls, 1);
    });

    test('an empty list (a new open under way) stops it', () async {
      final list = _List(const []);
      final poll = _FakePoll([
        (sources: [_src('https://a/2')], done: false),
      ]);
      await pollDesktopLateMirrors(
        poll: poll.call,
        isCurrent: () => true,
        currentSources: () => list.sources,
        add: list.add,
        delays: _instant,
      );
      expect(poll.calls, 0);
      expect(list.sources, isEmpty);
    });

    test('a failed read ends it quietly', () async {
      final list = _List([_src('https://a/1')]);
      var calls = 0;
      await pollDesktopLateMirrors(
        poll: () async {
          calls++;
          throw StateError('engine gone');
        },
        isCurrent: () => true,
        currentSources: () => list.sources,
        add: list.add,
        delays: _instant,
      );
      expect(calls, 1);
      expect(list.sources.map((s) => s.url), ['https://a/1']);
    });

    test('compares with the list as it is after the read', () async {
      final list = _List([_src('https://a/1')]);
      await pollDesktopLateMirrors(
        poll: () async {
          // Something else (a fresh-links swap, say) changed the list while
          // the read ran; its link must not be added a second time.
          list.sources = [...list.sources, _src('https://a/2')];
          return (
            sources: [_src('https://a/2'), _src('https://a/3')],
            done: true,
          );
        },
        isCurrent: () => true,
        currentSources: () => list.sources,
        add: list.add,
        delays: _instant,
      );
      expect(list.sources.map((s) => s.url), [
        'https://a/1',
        'https://a/2',
        'https://a/3',
      ]);
    });
  });
}

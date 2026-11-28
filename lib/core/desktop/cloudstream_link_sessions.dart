import 'dart:async';

import 'package:flutter/foundation.dart';

import 'cloudstream_runtime.dart' show adaptCloudStreamLinks;

/// Starts one engine links call with [tag] and completes with the engine's
/// full answer (the same map `Cs3Engine.loadLinks` returns).
typedef CloudStreamLinkCall = Future<Map<String, dynamic>> Function(String tag);

/// Asks the engine to stop the links call with [tag]. Best effort.
typedef CloudStreamLinkCancel = Future<void> Function(String tag);

/// Windows only: the links found so far for each CloudStream episode, filled
/// live from the engine's `link`, `subtitle` and `linksDone` events.
///
/// This is how the phone works: a playback ("fast") request returns as soon
/// as the first link arrives (plus a short wait for a couple of others),
/// while the engine keeps collecting the rest. Later links are read with
/// [poll], which the player already calls after playback starts.
///
/// One engine call runs per episode key at a time. A second request for the
/// same episode while it runs joins it instead of scraping the site again
/// (some sites hand out one-use tokens).
class CloudStreamLinkSessions {
  CloudStreamLinkSessions({
    this.grace = const Duration(milliseconds: 700),
    this.fastCap = const Duration(seconds: 15),
    this.maxSessions = 24,
  });

  /// How long a fast request waits after the first link for a few more, as
  /// the phone does (`LOADLINKS_FAST_GRACE_MS`).
  final Duration grace;

  /// The latest a fast request waits once it has at least one link. With no
  /// link yet it keeps waiting for the first one or the engine's answer, so a
  /// slow source is not cut short (see [load]).
  final Duration fastCap;

  /// How many episodes are kept; the oldest is dropped (and stopped) first.
  final int maxSessions;

  // A map literal keeps insertion order, so the first key is the oldest.
  final _byKey = <String, _LinkSession>{};
  final _byTag = <String, _LinkSession>{};
  int _nextTag = 0;

  /// Resolves the links for [key] (`name|data`).
  ///
  /// [fast] false waits for the engine's full answer and returns it exactly
  /// as the old code did (it throws the same error when nothing was found).
  ///
  /// [fast] true returns the links found so far, with `done: false`, once the
  /// first link has arrived and [grace] has passed (never later than
  /// [fastCap] after the request when a link is in). If the engine answers
  /// first, that full answer is returned instead. With no link at all it
  /// waits for the engine's answer, as today, so a source that needs 20 s to
  /// find its first link still plays. The resolver's playback limit for
  /// `cs:` sources is 30 s (plan item C2). A source still silent then is not
  /// cut off: the resolver keeps listening to this same request for its slow
  /// grace, so the wait here stays open on purpose. An empty return at
  /// [fastCap] would instead turn a source whose first link takes 20 s into
  /// "nothing found". Full asks keep the 75 s limit, above the engine's 60 s.
  Future<Map<String, dynamic>> load(
    String key, {
    required bool fast,
    required CloudStreamLinkCall call,
    CloudStreamLinkCancel? cancel,
  }) async {
    final started = DateTime.now();
    final session = _sessionFor(key, call, cancel);
    if (!fast) {
      // Someone (a download, say) needs every link: while they wait, a cancel
      // from the player must not stop the call (see [cancel]).
      session.fullWaiters++;
      return session.full.whenComplete(() => session.fullWaiters--);
    }

    // Wait for the first link, or for the engine to end the call.
    await Future.any([session.finished.future, session.firstLink.future]);
    if (!session.done) {
      // A short wait so a couple of other mirrors can arrive too, capped so
      // the whole request stays within [fastCap].
      var wait = fastCap - DateTime.now().difference(started);
      if (wait > grace) wait = grace;
      if (wait > Duration.zero) {
        await Future.any([
          session.finished.future,
          Future<void>.delayed(wait),
        ]);
      }
    }
    // The call ended meanwhile: give its full answer (or its error), the same
    // result a non-fast request gets.
    if (session.done) return session.full;
    final early = session.snapshot();
    // Shows in the app log that playback got its first links early.
    debugPrint(
      '[cloudstream] first links after '
      '${DateTime.now().difference(started).inMilliseconds}ms '
      '(${(early['sources'] as List).length} links, still collecting)',
    );
    return early;
  }

  /// The links found so far for [key] and whether more may come, or null when
  /// no session is kept for it (the caller then answers as before).
  Map<String, dynamic>? poll(String key) => _byKey[key]?.snapshot();

  /// Stops [key]'s session: it is dropped (so a poll reads "done, nothing"),
  /// and the engine is asked to stop its call.
  ///
  /// The app cancels every links request still running when the player is
  /// closed, downloads included. So a session that a full (non-fast) request
  /// still waits on is left running: stopping it would hand that download only
  /// the links found so far, often none. It ends by itself, as before.
  void cancel(String key) {
    final session = _byKey[key];
    if (session == null) return;
    if (session.fullWaiters > 0 && !session.done) return;
    _byKey.remove(key);
    _stop(session);
  }

  /// Drops every session (plugins were removed or the engine restarted).
  void clear() {
    for (final session in _byKey.values.toList()) {
      _stop(session);
    }
    _byKey.clear();
  }

  /// Feeds one engine event in. Returns true when it was a links event (so
  /// the caller need not look at it further).
  bool handleEvent(Map<String, dynamic> event) {
    final type = event['event'];
    if (type != 'link' && type != 'subtitle' && type != 'linksDone') {
      return false;
    }
    final session = _byTag['${event['tag']}'];
    // A late event for a finished or dropped session changes nothing: the
    // engine's full answer is what counts then.
    if (session == null || session.done) return true;
    switch (type) {
      case 'link':
        final link = event['link'];
        if (link is Map) {
          session.links.add(Map<String, dynamic>.from(link));
          if (!session.firstLink.isCompleted) session.firstLink.complete();
        }
      case 'subtitle':
        final subtitle = event['subtitle'];
        // Same rule as the engine's answer: the first subtitle per address.
        if (subtitle is Map && session.subtitleUrls.add('${subtitle['url']}')) {
          session.subtitles.add(Map<String, dynamic>.from(subtitle));
        }
      case 'linksDone':
        // No more links come; the full answer follows right after.
        session.eventsDone = true;
    }
    return true;
  }

  /// Joins [key]'s running session, or starts a new engine call for it.
  _LinkSession _sessionFor(
    String key,
    CloudStreamLinkCall call,
    CloudStreamLinkCancel? cancel,
  ) {
    final running = _byKey[key];
    if (running != null && !running.done) return running;

    // A finished session is replaced by a fresh call, as a new request always
    // started a fresh scrape before.
    _byKey.remove(key);
    while (_byKey.length >= maxSessions) {
      final oldest = _byKey.remove(_byKey.keys.first)!;
      // A call a full request still waits on is only forgotten here, not
      // stopped, for the same reason as in [cancel]; it ends by itself.
      if (oldest.fullWaiters == 0 || oldest.done) _stop(oldest);
    }
    final tag = 'links-${++_nextTag}';
    final session = _LinkSession(tag, cancel);
    _byKey[key] = session;
    _byTag[tag] = session;
    session.full = Future.sync(() => call(tag)).then(
      (result) {
        final mapped = adaptCloudStreamLinks(result);
        session.answer = mapped;
        // Same rule as before: no links and an error means the call failed.
        if ((mapped['sources'] as List).isEmpty && result['error'] != null) {
          throw StateError('${result['error']}');
        }
        return mapped;
      },
    );
    session.full.then<void>(
      (_) {},
      onError: (Object _) {},
    ).whenComplete(() {
      session.ended = true;
      _byTag.remove(tag);
      if (!session.finished.isCompleted) session.finished.complete();
    });
    return session;
  }

  /// Marks [session] stopped and asks the engine to stop its call.
  void _stop(_LinkSession session) {
    session.cancelled = true;
    _byTag.remove(session.tag);
    final cancel = session.cancel;
    if (cancel != null && !session.ended) {
      unawaited(Future.sync(() => cancel(session.tag)).catchError((Object _) {}));
    }
  }
}

/// One episode's links call: what its events brought so far, and its end.
class _LinkSession {
  _LinkSession(this.tag, this.cancel);

  final String tag;
  final CloudStreamLinkCancel? cancel;

  /// Raw engine link maps in the order they arrived (the answer's order).
  final links = <Map<String, dynamic>>[];
  final subtitles = <Map<String, dynamic>>[];
  final subtitleUrls = <String>{};

  /// Completes when the first link event arrives.
  final firstLink = Completer<void>();

  /// Completes when the engine call has answered (or failed).
  final finished = Completer<void>();

  /// The engine call, mapped to the host payload (throws as before on error).
  late final Future<Map<String, dynamic>> full;

  /// The engine's full answer once it came, mapped. It replaces what the
  /// events collected, so polls then read exactly what the old code cached.
  Map<String, dynamic>? answer;

  /// How many full (non-fast) requests are waiting on this call right now.
  int fullWaiters = 0;

  bool eventsDone = false;
  bool ended = false;
  bool cancelled = false;

  /// True once no more links can come for this session.
  bool get done => ended || eventsDone || cancelled;

  /// What a poll or an early fast return gives: the full answer when it came,
  /// else the links so far mapped the same way, with whether more may come.
  Map<String, dynamic> snapshot() {
    final full = answer;
    if (full != null) return {...full, 'done': true};
    return {
      ...adaptCloudStreamLinks({'links': links, 'subtitles': subtitles}),
      'done': done,
    };
  }
}

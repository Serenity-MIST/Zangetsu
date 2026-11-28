import 'dart:async';

import '../models/video_source.dart';

/// Where one source stands while a download search asks it for links.
enum DownloadSourcePhase {
  waiting,
  trying,
  found,
  empty,
  timedOut,
  failed,
  skipped,
}

/// What one source handed back for a download: its links, plus the source's
/// own show/episode urls so the caller can say where the file came from.
class DownloadSourceHit {
  const DownloadSourceHit({
    required this.streams,
    this.episodeUrl,
    this.showUrl,
  });
  final List<VideoSource> streams;
  final String? episodeUrl;
  final String? showUrl;
}

/// One source the search will ask, in priority order.
class DownloadSourceCandidate {
  const DownloadSourceCandidate({
    required this.id,
    required this.name,
    required this.budget,
    this.serial = false,
    this.skipReason,
    this.freeWorkerAfter,
    this.extendIf,
  });
  final String id;
  final String name;

  /// How long this source may take before it counts as timed out.
  final Duration budget;

  /// Runs on a shared in-process engine (bundled JS), so it is asked one at a
  /// time instead of alongside the native sources.
  final bool serial;

  /// Non-null when the source is not asked at all (e.g. Cloudflare check
  /// pending); reported so "not asked" never reads as "has nothing".
  final String? skipReason;

  /// When set (shorter than [budget]), the search stops holding a worker for
  /// this source after this long and moves on to the next one, while still
  /// listening for this source's answer until [budget]. A source that waits
  /// a long time in a queue then does not keep every other source waiting.
  final Duration? freeWorkerAfter;

  /// Asked once when [budget] runs out, with the time this source was asked.
  /// True gives the source one more [budget] (still within the whole
  /// search's limit), for time it spent waiting rather than working.
  final bool Function(DateTime askedAt)? extendIf;
}

/// One row of a download search snapshot.
class DownloadSourceStatus {
  const DownloadSourceStatus({
    required this.sourceId,
    required this.name,
    required this.phase,
    this.streams = const [],
    this.episodeUrl,
    this.showUrl,
    this.detail,
  });
  final String sourceId;
  final String name;
  final DownloadSourcePhase phase;
  final List<VideoSource> streams;
  final String? episodeUrl;
  final String? showUrl;

  /// Skip reason or error text, for the status line.
  final String? detail;

  bool get settled =>
      phase != DownloadSourcePhase.waiting &&
      phase != DownloadSourcePhase.trying;

  DownloadSourceStatus _as(
    DownloadSourcePhase p, {
    DownloadSourceHit? hit,
    String? detail,
  }) => DownloadSourceStatus(
    sourceId: sourceId,
    name: name,
    phase: p,
    streams: hit?.streams ?? const [],
    episodeUrl: hit?.episodeUrl,
    showUrl: hit?.showUrl,
    detail: detail,
  );
}

/// Asks every candidate for download links and emits a full snapshot (in
/// candidate order) each time any source changes state, so a dialog can show
/// "Trying X..." per source and offer links as soon as the first one answers.
///
/// Every attempt is bounded by its candidate's budget and the whole search by
/// [wallClock]; the stream always ends, with every row settled. Native sources
/// run [parallel] at a time; [DownloadSourceCandidate.serial] ones run one at
/// a time in their own lane. A candidate with
/// [DownloadSourceCandidate.freeWorkerAfter] gives its worker back early and
/// keeps listening in the background. Cancelling the subscription stops new attempts
/// and cancels every timer (in-flight provider calls cannot be recalled; their
/// late answers are dropped).
///
/// [onSettled], when given, hears each asked source once as it settles, with
/// how long it took from being asked (for the log). A source still open when
/// the whole search ends is reported as timed out at that point.
Stream<List<DownloadSourceStatus>> searchDownloadSources({
  required List<DownloadSourceCandidate> candidates,
  required Future<DownloadSourceHit?> Function(String sourceId) attempt,
  int parallel = 3,
  Duration wallClock = const Duration(seconds: 90),
  void Function(DownloadSourceStatus row, Duration elapsed)? onSettled,
}) {
  final rows = [
    for (final c in candidates)
      c.skipReason != null
          ? DownloadSourceStatus(
              sourceId: c.id,
              name: c.name,
              phase: DownloadSourcePhase.skipped,
              detail: c.skipReason,
            )
          : DownloadSourceStatus(
              sourceId: c.id,
              name: c.name,
              phase: DownloadSourcePhase.waiting,
            ),
  ];
  final timers = <Timer>{};
  // When each asked source was asked, for [onSettled].
  final askedAt = <int, Stopwatch>{};
  var stopped = false;
  late final StreamController<List<DownloadSourceStatus>> out;

  void emit() {
    if (!out.isClosed) out.add(List.unmodifiable(rows));
  }

  void settled(int index) {
    final clock = askedAt.remove(index);
    if (clock == null || onSettled == null) return;
    onSettled(rows[index], clock.elapsed);
  }

  void finish() {
    if (stopped) return;
    stopped = true;
    for (final t in timers) {
      t.cancel();
    }
    timers.clear();
    // Anything still unanswered when the search ends is reported as timed out.
    for (var i = 0; i < rows.length; i++) {
      if (!rows[i].settled) {
        rows[i] = rows[i]._as(DownloadSourcePhase.timedOut);
        settled(i);
      }
    }
    emit();
    if (!out.isClosed) out.close();
  }

  // Sources still being listened to after their worker moved on.
  final listening = <Future<void>>[];

  /// One source, bounded by its own budget via a cancellable timer.
  Future<void> ask(int index) async {
    if (stopped) return;
    final c = candidates[index];
    rows[index] = rows[index]._as(DownloadSourcePhase.trying);
    askedAt[index] = Stopwatch()..start();
    final askedWhen = DateTime.now();
    emit();
    final done = Completer<void>();
    var extended = false;
    late Timer timer;
    void onBudget() {
      timers.remove(timer);
      if (done.isCompleted || stopped) return;
      final extend = c.extendIf;
      if (!extended && extend != null && extend(askedWhen)) {
        // Its time went on waiting, not working: one more budget.
        extended = true;
        timer = Timer(c.budget, onBudget);
        timers.add(timer);
        return;
      }
      rows[index] = rows[index]._as(DownloadSourcePhase.timedOut);
      settled(index);
      emit();
      done.complete();
    }

    timer = Timer(c.budget, onBudget);
    timers.add(timer);
    unawaited(
      Future<DownloadSourceHit?>.sync(() => attempt(c.id)).then(
        (hit) {
          if (done.isCompleted || stopped) return;
          final streams = hit?.streams ?? const <VideoSource>[];
          rows[index] = streams.isEmpty
              ? rows[index]._as(DownloadSourcePhase.empty)
              : rows[index]._as(DownloadSourcePhase.found, hit: hit);
          settled(index);
          emit();
          done.complete();
        },
        onError: (Object e) {
          if (done.isCompleted || stopped) return;
          rows[index] = rows[index]._as(
            DownloadSourcePhase.failed,
            detail: '$e',
          );
          settled(index);
          emit();
          done.complete();
        },
      ),
    );
    Future<void> cleanUp() async {
      await done.future;
      timer.cancel();
      timers.remove(timer);
    }

    final free = c.freeWorkerAfter;
    if (free == null || free >= c.budget) {
      await cleanUp();
      return;
    }
    // Hand the worker back after [free], or sooner if the source settles;
    // the answer is still taken until its budget runs out.
    listening.add(cleanUp());
    final released = Completer<void>();
    final freeTimer = Timer(free, () {
      if (!released.isCompleted) released.complete();
    });
    timers.add(freeTimer);
    unawaited(
      done.future.then((_) {
        if (!released.isCompleted) released.complete();
      }),
    );
    await released.future;
    freeTimer.cancel();
    timers.remove(freeTimer);
  }

  Future<void> run() async {
    final native = <int>[];
    final serial = <int>[];
    for (var i = 0; i < candidates.length; i++) {
      if (candidates[i].skipReason != null) continue;
      (candidates[i].serial ? serial : native).add(i);
    }
    var next = 0;
    // Workers pull from one queue so a slow source never holds up the others.
    Future<void> worker() async {
      while (!stopped && next < native.length) {
        await ask(native[next++]);
      }
    }

    Future<void> serialLane() async {
      for (final i in serial) {
        if (stopped) return;
        await ask(i);
      }
    }

    await Future.wait([
      for (var i = 0; i < parallel; i++) worker(),
      serialLane(),
    ]);
    // Workers that moved on early: wait for those sources to settle too.
    while (listening.isNotEmpty && !stopped) {
      final pending = List.of(listening);
      listening.clear();
      await Future.wait(pending);
    }
  }

  out = StreamController<List<DownloadSourceStatus>>(
    onListen: () {
      emit();
      final wall = Timer(wallClock, finish);
      timers.add(wall);
      unawaited(run().whenComplete(finish));
    },
    onCancel: () {
      stopped = true;
      for (final t in timers) {
        t.cancel();
      }
      timers.clear();
    },
  );
  return out.stream;
}

/// A single-source search for callers that only have one resolver (ordinary,
/// non-catalogue sources); still bounded and still reports progress.
Stream<List<DownloadSourceStatus>> searchSingleDownloadSource({
  required String sourceId,
  required String name,
  required Future<List<VideoSource>> Function() resolve,
  Duration budget = const Duration(seconds: 75),
}) => searchDownloadSources(
  candidates: [
    DownloadSourceCandidate(id: sourceId, name: name, budget: budget),
  ],
  attempt: (_) async => DownloadSourceHit(streams: await resolve()),
  wallClock: budget + const Duration(seconds: 1),
);

import 'download_failure.dart';
import 'hls_audio_selection.dart';
import 'subtitle_selection.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

import '../playback/hls.dart';
import 'webvtt_merge.dart';

/// Platform merge capability for already-downloaded files, never remote URLs.
typedef HlsAudioMux =
    Future<String?> Function(
      String video,
      String audio,
      String output,
      String? language,
      bool Function() canceled,
    );

/// Downloads an HLS (m3u8) stream to a single local file by fetching every
/// segment, decrypting AES-128 if needed, and concatenating into one .mp4.
/// Handles both flavors: plain TS segments (concatenated directly) and fMP4
/// (`#EXT-X-MAP` init segment written first, then the `.m4s` fragments) — libmpv
/// plays either a concatenated TS or a concatenated fragmented-MP4 fine.
///
/// Runs in the Dart isolate (foreground while the app is open) — there's no
/// background_downloader equivalent for segmented HLS. Progress is reported via
/// [onProgress]; [canceled] is polled between segments to abort.
class HlsDownloader {
  HlsDownloader(
    this._dio, {
    this.muxAudio,
    this.isHostCoolingDown,
    this.onRateLimited,
    this.resilient = false,
    this.waitForNetwork,
    this.networkPatience = const Duration(minutes: 3),
    List<Duration>? retryDelays,
  }) : retryDelays = retryDelays ?? _patientRetryDelays;
  final HlsAudioMux? muxAudio;

  /// Windows only (the Windows download manager passes true). A resilient
  /// download rides out a weak or dropping connection instead of failing:
  /// it writes to `<output>.part` with a small progress file beside it, keeps
  /// both when it stops, and carries on from the last saved segment the next
  /// time it runs. Off (the default) keeps the original behaviour exactly.
  final bool resilient;

  /// Resilient mode: completes when the network is back (at once when it is
  /// already up). Time spent waiting here does not count against
  /// [networkPatience], so a long outage never fails the download.
  final Future<void> Function()? waitForNetwork;

  /// Resilient mode: how long one request may keep failing while the network
  /// looks up before the download stops with [networkResult].
  final Duration networkPatience;

  /// Resilient mode: the waits between tries of one failed request. The last
  /// one repeats until [networkPatience] runs out.
  final List<Duration> retryDelays;

  static const List<Duration> _patientRetryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
  ];

  /// Results of a resilient [download] that are not plain failures. The
  /// partial file is kept for every one of these except [canceledResult].
  static const String canceledResult = 'canceled';

  /// Stopped by a pause (or the app closing); the partial file is kept.
  static const String pausedResult = 'paused';

  /// The connection kept failing for [networkPatience]; try again later.
  static const String networkResult = 'network';

  /// The host refused a segment (403/410), usually an expired signed link.
  /// Fetching the stream link again carries on from the saved segment.
  static const String expiredResult = 'playlist-expired';

  /// Another download is already writing this same partial file.
  static const String busyResult = 'busy';

  /// Every segment is saved, but the finished file could not take its real
  /// name yet (an older copy is open in a player, or antivirus holds the
  /// file). Everything is kept; trying again later only renames it.
  static const String finishLaterResult = 'finish-later';

  /// Partial files being written right now in this app, so two jobs can never
  /// write into one file at the same time.
  static final Set<String> _openParts = {};

  /// Resilient mode: the checkpoint file format. Bump it when the fields change.
  /// 2: the chosen quality, the playlist's link path and the source are part
  /// of the match, so another quality or language is never joined on.
  static const int _checkpointVersion = 2;

  /// Resilient mode: segments written and segment total of the last run, for
  /// the manager's log line (no links in it).
  int segmentsWritten = 0;
  int segmentsTotal = 0;

  /// Resilient mode: the segment the last run started from (0 = fresh start).
  int resumedFrom = 0;

  /// Resilient mode: why the last playlist or key request failed.
  _Miss _lastMiss = _Miss.none;

  /// Resilient mode: true when the current job should stop (pause or cancel).
  bool Function() _stopNow = _never;
  static bool _never() => false;

  /// Resilient mode: set when one segment has failed the run, so the other
  /// connections stop at once instead of carrying on with nothing to write to.
  bool _abortRun = false;

  /// Optional device-local policy; absent for existing background/mobile callers.
  final bool Function(Uri url)? isHostCoolingDown;

  /// Persist a server hint before this job returns its transfer capacity.
  final Future<void> Function(Uri url, String? retryAfter)? onRateLimited;
  bool _rateLimited = false;
  Uri? _rateLimitedUri;
  bool _receivedRateLimitResponse = false;

  /// A cached cooldown is not another server rejection and must not extend it.
  bool get receivedRateLimitResponse => _receivedRateLimitResponse;

  /// Ephemeral final host for the manager's host-only persisted retry metadata.
  Uri? get rateLimitedUri => _rateLimitedUri;

  /// Separates host throttling from a missing playlist, segment or audio track.
  bool get rateLimited => _rateLimited;

  /// Keep response bodies and signed URLs out of user-visible error messages.
  String? get _rateLimitMessage =>
      _rateLimited ? downloadFailureMessage(null, statusCode: 429) : null;

  /// Stop new requests after throttling; already in-flight segments may settle.
  bool _mayRequest(Uri url) {
    if (_rateLimited) return false;
    if (isHostCoolingDown?.call(url) == true) {
      _rateLimited = true;
      _rateLimitedUri = url;
      return false;
    }
    return true;
  }

  /// Observe the final redirect host, retaining no response body or credentials.
  Future<void> _observeRateLimit(Response<dynamic> response) async {
    if (response.statusCode != 429 || onRateLimited == null) return;
    _rateLimited = true;
    _receivedRateLimitResponse = true;
    _rateLimitedUri = response.realUri;
    await onRateLimited!(
      response.realUri,
      response.headers.value('retry-after'),
    );
  }

  final Dio _dio;

  static const int _concurrency = 4; // parallel segment fetches
  static const int _maxAhead = 32; // cap out-of-order buffer (memory bound)

  /// Tries per segment. Three, not more: a segment that fails three times with
  /// a growing gap between attempts is not a blip, and a thousand-segment
  /// download shouldn't spend minutes discovering the host is down.
  static const int _segmentAttempts = 3;

  /// Multiplied by the attempt number, so the waits are 400ms then 800ms — a
  /// dropped connection wants a moment, and a rate limiter wants a bit more.
  static const Duration _segmentRetryDelay = Duration(milliseconds: 400);

  /// Returns null on success (file written to [outputPath]). On failure or
  /// cancellation the partial file is removed and a short reason string is
  /// returned — surfaced on the download tile and logged by the manager, so a
  /// failed HLS download is no longer a silent black box.
  Future<String?> download({
    required String url,
    required Map<String, String> headers,
    required String outputPath,
    required String preferredQuality,
    required void Function(double progress) onProgress,
    required bool Function() canceled,
    int? connections,
    String? preferredAudioLanguage,
    bool Function()? paused,
    String? resumeKey,
    String? sourceTag,
    bool discardStaleOutput = false,
  }) async {
    // Segment-fetch parallelism for THIS download (clamped); defaults to 4.
    final concurrency = (connections ?? _concurrency).clamp(
      1,
      _concurrency * 4,
    );
    if (resilient) {
      // [sourceTag] names the server and quality the run came from. It is
      // saved with the progress (so the manager can go back to that same
      // server) and must match for a resume. [discardStaleOutput]: a file
      // already at [outputPath] is a half download from the older app
      // version, removed once this run has its first bytes.
      return _downloadResilient(
        url: url,
        headers: headers,
        outputPath: outputPath,
        preferredQuality: preferredQuality,
        onProgress: onProgress,
        canceled: canceled,
        paused: paused ?? _never,
        concurrency: concurrency,
        connections: connections,
        preferredAudioLanguage: preferredAudioLanguage,
        resumeKey: resumeKey ?? '',
        sourceTag: sourceTag ?? '',
        discardStaleOutput: discardStaleOutput,
      );
    }
    // 1. Resolve a master playlist down to a media (segment) playlist.
    HlsAudioRendition? selectedAudio;
    (String, String)? media;
    try {
      media = await _resolveMediaPlaylist(
        url,
        headers,
        preferredQuality,
        preferredAudioLanguage: preferredAudioLanguage,
        onAudio:
            Platform.isWindows ||
                muxAudio != null ||
                preferredAudioLanguage != null
            ? (audio) => selectedAudio = audio
            : null,
      );
    } on HlsAudioSelectionException catch (error) {
      return error.toString();
    }
    if (media == null) return _rateLimitMessage ?? 'playlist unreachable';
    if (selectedAudio != null && muxAudio == null) {
      return 'This stream requires the bundled audio merge engine';
    }
    final mediaUrl = media.$1;
    final playlist = media.$2;

    // 2. Parse segments + (optional) AES-128 key reference.
    final pl = _parseMedia(playlist, mediaUrl);
    if (pl.segments.isEmpty) return 'empty playlist (no segments)';

    // 3. Fetch the decryption key if the stream is encrypted.
    Uint8List? key;
    if (pl.keyUrl != null) {
      key = await _fetchBytes(pl.keyUrl!, headers);
      if (key == null || key.length != 16)
        return _rateLimitMessage ?? 'AES key fetch failed';
    }

    // 4. Download segments with bounded parallelism, writing strictly in order.
    final file = File(outputPath);
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    final pending = <int, Uint8List>{};
    final total = pl.segments.length;
    var nextIndex = 0;
    var nextWrite = 0;
    var done = 0;
    var failed = false;
    String? failReason;

    Future<void> worker() async {
      while (true) {
        if (failed || canceled()) return;
        // Throttle so a slow early segment can't blow up the pending buffer.
        while (nextIndex - nextWrite > _maxAhead && !failed && !canceled()) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        if (failed || canceled()) return;
        final i = nextIndex++;
        if (i >= total) return;

        Uint8List? bytes = await _fetchBytes(pl.segments[i], headers);
        if (bytes == null) {
          failed = true;
          failReason ??= 'segment ${i + 1}/$total unreachable';
          return;
        }
        if (key != null) {
          final iv = pl.explicitIv ?? hlsSeqIv(pl.mediaSequence + i);
          // Off the main isolate. AES-128-CBC here is pure Dart (PointyCastle),
          // so a few MB per segment is real CPU work on the thread that draws
          // frames — with up to 16 of these in flight, downloading an encrypted
          // stream visibly stutters the UI. Decrypting is the only part heavy
          // enough to be worth moving; fetching and writing are I/O and already
          // yield.
          //
          // One isolate per segment is the right trade here: spawning costs a
          // few ms against tens of ms of decryption, and only encrypted streams
          // pay it at all — an unencrypted download never reaches this branch.
          bytes = await compute(_decryptSegment, (
            data: bytes,
            key: key,
            iv: iv,
          ));
        }
        // TS segments only (fMP4 has an init header and no 0x47 sync): drop any
        // decoy prefix so the saved file is clean TS external players can demux.
        if (pl.initUrl == null) bytes = hlsStripToTsSync(bytes);
        pending[i] = bytes;
        // Flush every now-contiguous segment (sync, no await → no interleave).
        while (pending.containsKey(nextWrite)) {
          sink.add(pending.remove(nextWrite)!);
          nextWrite++;
          done++;
          onProgress((done / total) * (selectedAudio == null ? 1 : .8));
        }
      }
    }

    // fMP4: write the init segment FIRST so the file has its ftyp+moov header
    // before the moof+mdat fragments — otherwise the result is unplayable. TS
    // playlists have no `#EXT-X-MAP`, so initUrl is null and this is skipped
    // (TS downloads are unchanged). The init segment is never encrypted.
    if (pl.initUrl != null) {
      final init = await _fetchBytes(pl.initUrl!, headers);
      if (init == null) {
        await sink.close();
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
        return _rateLimitMessage ?? 'init segment fetch failed';
      }
      sink.add(init);
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    await sink.flush();
    await sink.close();

    if (failed || canceled() || nextWrite < total) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      if (canceled()) return 'canceled';
      return _rateLimitMessage ??
          failReason ??
          'incomplete ($nextWrite/$total segments)';
    }
    if (selectedAudio != null) {
      final audio = selectedAudio!;
      final scratch = await file.parent.createTemp('.zangetsu-audio-');
      try {
        final audioPath = '${scratch.path}/audio.media';
        final mergedPath = '${scratch.path}/merged.ts';
        final audioDownloader = HlsDownloader(
          _dio,
          isHostCoolingDown: isHostCoolingDown,
          onRateLimited: onRateLimited,
        );
        final error = await audioDownloader.download(
          url: audio.uri,
          headers: headers,
          outputPath: audioPath,
          preferredQuality: 'best',
          connections: connections,
          onProgress: (value) => onProgress(.8 + value * .19),
          canceled: canceled,
        );
        if (audioDownloader.rateLimited) {
          _rateLimited = true;
          _rateLimitedUri = audioDownloader.rateLimitedUri;
          _receivedRateLimitResponse =
              audioDownloader.receivedRateLimitResponse;
        }
        if (error != null) {
          await file.delete();
          return _rateLimitMessage ?? 'Selected audio download failed: $error';
        }
        final mergeError = await muxAudio!(
          outputPath,
          audioPath,
          mergedPath,
          preferredAudioLanguage ?? audio.lang,
          canceled,
        );
        if (mergeError != null || canceled()) {
          await file.delete();
          return canceled() ? 'canceled' : mergeError;
        }
        await file.delete();
        await File(mergedPath).rename(outputPath);
        onProgress(1);
      } catch (_) {
        if (await file.exists()) await file.delete();
        return 'The selected audio could not be saved';
      } finally {
        if (await scratch.exists()) await scratch.delete(recursive: true);
      }
    }
    return null;
  }

  // ── Playlist resolution ───────────────────────────────────────────────────

  /// Follow a master playlist to a media playlist, choosing the variant closest
  /// to [preferredQuality] (or the highest for 'best'/unknown). Returns
  /// (mediaUrl, playlistText).
  /// The subtitle renditions [masterUrl] offers, each merged into one WebVTT
  /// document ready to save beside the video.
  ///
  /// Subtitles inside an HLS stream had nowhere to survive a download: the
  /// master's `#EXT-X-MEDIA:TYPE=SUBTITLES` entries were never read, and
  /// [TsRemuxer] cannot put a subtitle track in an MP4 — MediaMuxer refuses
  /// the format, so it logs "unsupported" and drops it. Pulling the rendition
  /// out as a sidecar is what keeps it.
  ///
  /// Best-effort from end to end: a master that is really a media playlist, an
  /// unreachable rendition, or a segment that fails all return what was
  /// gathered so far rather than failing the download. Subtitles are a bonus
  /// on top of a video that already downloaded fine.
  Future<List<({String lang, String label, bool isDefault, String vtt})>>
  fetchSubtitleTracks(
    String masterUrl,
    Map<String, String> headers, {
    bool Function()? canceled,
    String? preferredLanguage,
  }) async {
    final out = <({String lang, String label, bool isDefault, String vtt})>[];
    try {
      final master = await _fetchText(masterUrl, headers);
      if (master == null) return out;
      final tracks = parseHlsSubtitles(master, masterUrl);
      final selected = preferredLanguage == null
          ? tracks
          : downloadSubtitleSelection(
              tracks,
              preferredLanguage,
              language: (track) => track.lang,
              label: (track) => track.label,
            );
      for (final track in selected) {
        if (canceled?.call() ?? false) return out;
        final vtt = await _mergeRendition(track.url, headers, canceled);
        if (vtt == null) continue;
        out.add((
          lang: track.lang,
          label: track.label,
          isDefault: track.isDefault,
          vtt: vtt,
        ));
      }
    } catch (_) {
      // Never surfaced: the video is already downloaded.
    }
    return out;
  }

  /// Download every `.vtt` segment of one rendition and join them.
  ///
  /// Sequential on purpose: a subtitle rendition is a handful of small text
  /// files, and this runs after the video is already on disk, so there is
  /// nothing to be gained by competing with anything for bandwidth.
  Future<String?> _mergeRendition(
    String playlistUrl,
    Map<String, String> headers,
    bool Function()? canceled,
  ) async {
    final text = await _fetchText(playlistUrl, headers);
    if (text == null) return null;
    final segs = <VttSegment>[];
    var start = 0.0;
    for (final entry in _timedSegments(text, playlistUrl)) {
      if (canceled?.call() ?? false) break;
      final body = await _fetchText(entry.url, headers);
      // A missing segment is a gap, not a failure — keep the rest of the
      // track rather than throwing away subtitles that did arrive.
      if (body != null && body.isNotEmpty) {
        segs.add(VttSegment(text: body, startSeconds: start));
      }
      start += entry.seconds;
    }
    if (segs.isEmpty) return null;
    return mergeWebVtt(segs);
  }

  /// Segment urls of a media playlist paired with their `#EXTINF` duration.
  ///
  /// Read here rather than from [_parseMedia] because only this path needs the
  /// durations — they are what place a segment on the media timeline when its
  /// cues turn out to be segment-relative.
  List<({String url, double seconds})> _timedSegments(
    String text,
    String playlistUrl,
  ) {
    final out = <({String url, double seconds})>[];
    var pending = 0.0;
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTINF:')) {
        pending =
            double.tryParse(line.substring(8).split(',').first.trim()) ?? 0.0;
        continue;
      }
      if (line.startsWith('#')) continue;
      out.add((url: _resolveRef(line, playlistUrl), seconds: pending));
      pending = 0.0;
    }
    return out;
  }

  Future<(String, String)?> _resolveMediaPlaylist(
    String url,
    Map<String, String> headers,
    String preferredQuality, {
    String? preferredAudioLanguage,
    void Function(HlsAudioRendition audio)? onAudio,
    void Function(HlsVariant variant)? onVariant,
  }) async {
    var current = url;
    for (var depth = 0; depth < 3; depth++) {
      final text = await _fetchText(current, headers);
      if (text == null) return null;
      final variants = parseHlsMaster(text, current);
      if (variants.isEmpty) return (current, text); // it's a media playlist
      final variant = _pickVariant(variants, preferredQuality);
      onVariant?.call(variant);
      final audio = selectDownloadAudio(
        text,
        current,
        variant,
        preferredLanguage: preferredAudioLanguage,
      );
      if (audio != null) onAudio?.call(audio);
      current = variant.url;
    }
    return null;
  }

  HlsVariant _pickVariant(List<HlsVariant> variants, String quality) {
    // variants are already sorted highest-first.
    final want = int.tryParse(
      RegExp(r'(\d{3,4})').firstMatch(quality)?.group(1) ?? '',
    );
    if (quality == 'best' || want == null) return variants.first;
    HlsVariant best = variants.first;
    var bestDelta = 1 << 30;
    for (final v in variants) {
      final h =
          int.tryParse(
            RegExp(r'(\d{3,4})').firstMatch(v.quality)?.group(1) ?? '',
          ) ??
          0;
      final d = (h - want).abs();
      if (d < bestDelta) {
        bestDelta = d;
        best = v;
      }
    }
    return best;
  }

  _MediaPlaylist _parseMedia(String text, String mediaUrl) {
    final pl = _MediaPlaylist();
    final lines = text.split(RegExp(r'\r?\n'));
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        pl.mediaSequence = int.tryParse(line.split(':').last.trim()) ?? 0;
      } else if (line.startsWith('#EXT-X-KEY:')) {
        final method =
            RegExp(r'METHOD=([^,]+)').firstMatch(line)?.group(1) ?? 'NONE';
        if (method.toUpperCase().contains('AES')) {
          final uri = RegExp(r'URI="([^"]+)"').firstMatch(line)?.group(1);
          if (uri != null) pl.keyUrl = _resolveRef(uri, mediaUrl);
          final iv = RegExp(r'IV=([0-9A-Fa-fxX]+)').firstMatch(line)?.group(1);
          if (iv != null) pl.explicitIv = hlsParseHexIv(iv);
        }
      } else if (line.startsWith('#EXT-X-MAP:')) {
        // fMP4 init segment — must be written before any fragment. (We don't
        // handle BYTERANGE inits, rare; the common case is a full init file.)
        final uri = RegExp(r'URI="([^"]+)"').firstMatch(line)?.group(1);
        if (uri != null) pl.initUrl = _resolveRef(uri, mediaUrl);
      } else if (line.startsWith('#EXTINF:')) {
        // Kept only so a resumed download can tell it is the same playlist.
        pl.durations.add(line.substring(8).split(',').first.trim());
        for (var j = i + 1; j < lines.length; j++) {
          final c = lines[j].trim();
          if (c.isEmpty || c.startsWith('#')) continue;
          pl.segments.add(_resolveRef(c, mediaUrl));
          break;
        }
      }
    }
    return pl;
  }

  // ── HTTP ──────────────────────────────────────────────────────────────────

  Future<String?> _fetchText(String url, Map<String, String> headers) async {
    if (resilient) {
      // Playlist requests wait out a drop too; the reason is kept so a dead
      // network is not mistaken for a missing stream.
      final (text, miss) = await _patientGet<String>(
        url,
        headers,
        ResponseType.plain,
      );
      _lastMiss = miss;
      return text;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !_mayRequest(uri)) return null;
    try {
      final r = await _dio.getUri<String>(
        Uri.parse(url),
        options: Options(
          responseType: ResponseType.plain,
          headers: headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      await _observeRateLimit(r);
      return r.statusCode == 200 ? r.data : null;
    } on DioException catch (error) {
      if (error.response != null) await _observeRateLimit(error.response!);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Fetches one segment, trying [_segmentAttempts] times before giving up.
  ///
  /// A single failure here used to end the whole download AND delete the
  /// partial file, so segment 900 of 1000 failing threw away all 900. An
  /// episode is hundreds to thousands of segments; on mobile data one of them
  /// failing once is the normal case, not an edge case. The MP4 path has asked
  /// background_downloader for 5 retries all along — this only brings HLS in
  /// line with it.
  ///
  /// A 4xx is not retried: the segment is gone or forbidden, and asking three
  /// times only makes the failure slower.
  Future<Uint8List?> _fetchBytes(
    String url,
    Map<String, String> headers,
  ) async {
    for (var attempt = 1; attempt <= _segmentAttempts; attempt++) {
      final uri = Uri.tryParse(url);
      if (uri == null || !_mayRequest(uri)) return null;
      try {
        final r = await _dio.getUri<List<int>>(
          Uri.parse(url),
          options: Options(
            responseType: ResponseType.bytes,
            headers: headers,
            validateStatus: (s) => s != null && s < 500,
          ),
        );
        await _observeRateLimit(r);
        if (r.statusCode == 200 && r.data != null) {
          return Uint8List.fromList(r.data!);
        }
        // Answered, but not with the segment. 4xx won't change on a retry.
        if (r.statusCode != null && r.statusCode! >= 400) return null;
      } on DioException catch (error) {
        if (error.response != null) await _observeRateLimit(error.response!);
        if (_rateLimited) return null;
        // Transient transport failures retain the bounded segment retry policy.
      } catch (_) {
        // Timeout, reset connection, DNS — exactly what a retry is for.
      }
      if (attempt < _segmentAttempts) {
        await Future<void>.delayed(_segmentRetryDelay * attempt);
      }
    }
    return null;
  }

  // ── Resilient download (Windows) ──────────────────────────────────────────

  /// True when [outputPath] has a partial file and a progress file beside it,
  /// meaning a resilient download can carry on instead of starting over.
  static Future<bool> hasResumableProgress(String outputPath) async {
    try {
      return await File('$outputPath.part').exists() &&
          await File('$outputPath.part.json').exists();
    } catch (_) {
      return false;
    }
  }

  /// Removes every leftover of a resilient download of [outputPath]: the
  /// partial video, its progress file, a separate audio track and a merge in
  /// progress. The finished file itself is never touched.
  static Future<void> discardPartial(String outputPath) async {
    for (final suffix in const [
      '.part',
      '.part.json',
      '.part.json.tmp',
      '.audio',
      '.audio.id',
      '.audio.part',
      '.audio.part.json',
      '.audio.part.json.tmp',
      '.merging',
    ]) {
      await _deleteQuietly('$outputPath$suffix');
    }
  }

  /// The server and quality ([download]'s `sourceTag`) the saved progress of
  /// [outputPath] came from, or null when there is none. The manager uses it
  /// to go back to that same server instead of the first one on the list.
  static Future<String?> readSourceTag(String outputPath) async {
    try {
      final file = File('$outputPath.part.json');
      if (!await file.exists()) return null;
      final data = jsonDecode(await file.readAsString());
      final tag = data is Map ? data['source'] : null;
      return tag is String && tag.isNotEmpty ? tag : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// The path of [url] with anything that looks like a one-time token
  /// replaced by `*`, so two links to the same playlist match while links to
  /// another quality or language (a different path) do not. No host, no query.
  static String _stablePath(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '';
    final hasDigit = RegExp(r'\d');
    final hasLetter = RegExp(r'[A-Za-z]');
    return uri.pathSegments
        .map(
          (part) =>
              part.length >= 32 ||
                  (part.length >= 16 &&
                      !part.contains('.') &&
                      hasDigit.hasMatch(part) &&
                      hasLetter.hasMatch(part))
              ? '*'
              : part,
        )
        .join('/');
  }

  /// True when a 200 answer is a web page (a Wi-Fi sign-in page, an error
  /// page) rather than the playlist or media that was asked for. Saving it
  /// would spoil the episode for good, so it is treated like a failed request.
  static bool _looksLikeWebPage(Object? data, Headers headers) {
    final type = headers.value('content-type')?.toLowerCase() ?? '';
    if (type.contains('text/html')) return true;
    String head;
    if (data is String) {
      head = data.length > 64 ? data.substring(0, 64) : data;
    } else if (data is List<int>) {
      final n = data.length < 64 ? data.length : 64;
      head = String.fromCharCodes(data.sublist(0, n));
    } else {
      return false;
    }
    head = head.trimLeft().toLowerCase();
    return head.startsWith('<!doctype') ||
        head.startsWith('<html') ||
        head.startsWith('<head') ||
        head.startsWith('<body');
  }

  /// One spelling per file, so the same path written two ways is one claim.
  static String _claimName(String path) {
    final full = File(path).absolute.path;
    return Platform.isWindows
        ? full.replaceAll('/', r'\').toLowerCase()
        : full;
  }

  /// A short, stable fingerprint of [text] (FNV-1a), to tell two playlists
  /// apart without storing their links.
  static String _fingerprint(String text) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(text)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return '${text.length}:${hash.toRadixString(16)}';
  }

  /// The saved position, when the progress file belongs to this same job and
  /// this same playlist. Anything else (missing, damaged, another playlist)
  /// means a fresh start.
  static Future<({int next, int bytes})?> _readCheckpoint(
    String path,
    Map<String, Object?> identity,
  ) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return null;
      for (final entry in identity.entries) {
        if (data[entry.key] != entry.value) return null;
      }
      final next = data['next'];
      final bytes = data['bytes'];
      if (next is! int || bytes is! int || next < 0 || bytes < 0) return null;
      return (next: next, bytes: bytes);
    } catch (_) {
      return null;
    }
  }

  /// Wraps [_resilientBody]: one writer per partial file, and a real cancel
  /// removes what was saved so far. A pause keeps it.
  Future<String?> _downloadResilient({
    required String url,
    required Map<String, String> headers,
    required String outputPath,
    required String preferredQuality,
    required void Function(double progress) onProgress,
    required bool Function() canceled,
    required bool Function() paused,
    required int concurrency,
    required int? connections,
    required String? preferredAudioLanguage,
    required String resumeKey,
    required String sourceTag,
    required bool discardStaleOutput,
  }) async {
    final claim = _claimName('$outputPath.part');
    if (!_openParts.add(claim)) return busyResult;
    _abortRun = false;
    _stopNow = () => _abortRun || canceled() || paused();
    String? result;
    try {
      try {
        result = await _resilientBody(
          url: url,
          headers: headers,
          outputPath: outputPath,
          preferredQuality: preferredQuality,
          onProgress: onProgress,
          canceled: canceled,
          paused: paused,
          concurrency: concurrency,
          connections: connections,
          preferredAudioLanguage: preferredAudioLanguage,
          resumeKey: resumeKey,
          sourceTag: sourceTag,
          discardStaleOutput: discardStaleOutput,
        );
      } on FileSystemException {
        result = 'The download could not be written to disk';
      } catch (error) {
        // Only the kind of error: its text may hold a signed link.
        result = 'The download stopped unexpectedly (${error.runtimeType})';
      }
      _stopNow = _never;
      if (result == null) return null;
      // Removed while this job still holds the file, so a new attempt
      // cannot open it in between.
      if (canceled()) {
        await discardPartial(outputPath);
        return canceledResult;
      }
      if (paused()) return pausedResult;
      return result;
    } finally {
      _stopNow = _never;
      _abortRun = false;
      _openParts.remove(claim);
    }
  }

  Future<String?> _resilientBody({
    required String url,
    required Map<String, String> headers,
    required String outputPath,
    required String preferredQuality,
    required void Function(double progress) onProgress,
    required bool Function() canceled,
    required bool Function() paused,
    required int concurrency,
    required int? connections,
    required String? preferredAudioLanguage,
    required String resumeKey,
    required String sourceTag,
    required bool discardStaleOutput,
  }) async {
    bool stop() => canceled() || paused();
    String stopped() => canceled() ? canceledResult : pausedResult;
    String missResult(_Miss miss, String otherwise) => switch (miss) {
      _Miss.stopped => stop() ? stopped() : otherwise,
      _Miss.network => networkResult,
      _Miss.expired => expiredResult,
      _ => _rateLimitMessage ?? otherwise,
    };

    // 1. Playlist, fetched fresh every run (so links and tokens are new).
    HlsAudioRendition? selectedAudio;
    HlsVariant? pickedVariant;
    (String, String)? media;
    try {
      media = await _resolveMediaPlaylist(
        url,
        headers,
        preferredQuality,
        preferredAudioLanguage: preferredAudioLanguage,
        onAudio:
            Platform.isWindows ||
                muxAudio != null ||
                preferredAudioLanguage != null
            ? (audio) => selectedAudio = audio
            : null,
        onVariant: (variant) => pickedVariant = variant,
      );
    } on HlsAudioSelectionException catch (error) {
      return error.toString();
    }
    if (media == null) return missResult(_lastMiss, 'playlist unreachable');
    if (selectedAudio != null && muxAudio == null) {
      return 'This stream requires the bundled audio merge engine';
    }
    final pl = _parseMedia(media.$2, media.$1);
    if (pl.segments.isEmpty) return 'empty playlist (no segments)';

    // 2. Decryption key.
    Uint8List? key;
    if (pl.keyUrl != null) {
      final (bytes, miss) = await _patientGet<List<int>>(
        pl.keyUrl!,
        headers,
        ResponseType.bytes,
      );
      if (bytes == null) return missResult(miss, 'AES key fetch failed');
      key = Uint8List.fromList(bytes);
      if (key.length != 16) return 'AES key fetch failed';
    }

    // 3. Carry on from the saved position when it is the same playlist: same
    // job, same server and quality, same picked variant, same playlist path
    // and the same segment list. Anything else starts fresh.
    final total = pl.segments.length;
    segmentsTotal = total;
    final variant = pickedVariant;
    final identity = <String, Object?>{
      'version': _checkpointVersion,
      'job': resumeKey,
      'source': sourceTag,
      'variant': variant == null
          ? null
          : '${variant.quality}|${variant.bandwidth}',
      'media': _stablePath(media.$1),
      'segments': total,
      'sequence': pl.mediaSequence,
      'durations': _fingerprint(pl.durations.join(',')),
      'init': pl.initUrl == null ? null : _stablePath(pl.initUrl!),
      'encrypted': pl.keyUrl != null,
    };
    final partPath = '$outputPath.part';
    final checkpointPath = '$partPath.json';
    final part = File(partPath);
    await part.parent.create(recursive: true);
    final saved = await _readCheckpoint(checkpointPath, identity);
    var resuming =
        saved != null &&
        saved.next <= total &&
        await part.exists() &&
        await part.length() >= saved.bytes;
    RandomAccessFile? raf;
    var openedFresh = false;
    var failed = false;
    var failMiss = _Miss.none;
    String? failReason;
    Object? writeError;
    var nextWrite = 0;
    var bytesWritten = 0;
    try {
      final s = saved;
      if (resuming && s != null) {
        final opened = await part.open(mode: FileMode.append);
        // Checked again now that it is open: the file may have been removed
        // or cut short since the first look. Never fill the gap with zeros.
        if (await opened.length() < s.bytes) {
          resuming = false;
          await opened.close();
        } else {
          raf = opened;
          // The file can be longer than the saved position (data written
          // after the last save), never shorter; cut it back to that point.
          await opened.truncate(s.bytes);
          await opened.setPosition(s.bytes);
          nextWrite = s.next;
          bytesWritten = s.bytes;
        }
      }
      resumedFrom = nextWrite;
      segmentsWritten = nextWrite;
      final audioShare = selectedAudio == null ? 1.0 : .8;
      double share(int written) => (written / total) * audioShare;
      // The real starting point at once (0 on a fresh start).
      onProgress(share(nextWrite));

      // A fresh start leaves the old partial alone until this playlist has
      // delivered its first bytes: if this server fails too, the progress
      // saved from the other one is still there to go back to.
      Future<RandomAccessFile> writer() async {
        final open = raf;
        if (open != null) return open;
        await discardPartial(outputPath);
        if (discardStaleOutput) await _deleteQuietly(outputPath);
        final fresh = await part.open(mode: FileMode.write);
        raf = fresh;
        openedFresh = true;
        return fresh;
      }

      var lastSavedAt = DateTime.now();
      var lastSavedIndex = nextWrite;
      // Data first, then the position that points at it, so the progress file
      // never claims bytes that are not on disk yet.
      Future<void> saveCheckpoint() async {
        final open = raf;
        if (open == null) return;
        await open.flush(); // a real disk failure still stops the run
        lastSavedAt = DateTime.now();
        lastSavedIndex = nextWrite;
        try {
          final tmp = File('$checkpointPath.tmp');
          await tmp.writeAsString(
            jsonEncode({...identity, 'next': nextWrite, 'bytes': bytesWritten}),
            flush: true,
          );
          await tmp.rename(checkpointPath);
        } catch (_) {
          // The progress file is busy for a moment (antivirus, search
          // indexer). Skip this save; the next one tries again, and an
          // older save only means a few segments are fetched again.
        }
      }

      // fMP4 header first. On a resume it is already in the saved bytes.
      if (!resuming && pl.initUrl != null) {
        final (init, miss) = await _patientGet<List<int>>(
          pl.initUrl!,
          headers,
          ResponseType.bytes,
        );
        if (init == null) return missResult(miss, 'init segment fetch failed');
        await (await writer()).writeFrom(init);
        bytesWritten += init.length;
        await saveCheckpoint();
      }

      final pending = <int, Uint8List>{};
      var nextIndex = nextWrite;
      var flushing = false;
      // Connections that ran too far ahead wait here until the writer moves.
      final aheadWaiters = <Completer<void>>[];
      void wakeAhead() {
        for (final waiter in aheadWaiters) {
          if (!waiter.isCompleted) waiter.complete();
        }
        aheadWaiters.clear();
      }

      void fail(_Miss miss, String reason) {
        if (failed) return;
        failed = true;
        failMiss = miss;
        failReason = reason;
        _abortRun = true; // the other connections stop at once
        wakeAhead();
      }

      // Only one writer at a time; whoever is writing picks up every segment
      // that became next in line while it waited for the disk.
      Future<void> drain() async {
        if (flushing) return;
        flushing = true;
        try {
          while (pending.containsKey(nextWrite)) {
            final chunk = pending.remove(nextWrite)!;
            await (await writer()).writeFrom(chunk);
            bytesWritten += chunk.length;
            nextWrite++;
            segmentsWritten = nextWrite;
            wakeAhead();
            onProgress(share(nextWrite));
            if (nextWrite - lastSavedIndex >= 8 ||
                DateTime.now().difference(lastSavedAt) >=
                    const Duration(seconds: 2)) {
              await saveCheckpoint();
            }
          }
        } finally {
          flushing = false;
        }
      }

      // One segment, decrypted and checked. A body that will not decrypt
      // (a web page instead of the segment) is fetched again a few times.
      Future<Uint8List?> fetchSegment(int i) async {
        for (var tries = 1; ; tries++) {
          final (data, miss) = await _patientGet<List<int>>(
            pl.segments[i],
            headers,
            ResponseType.bytes,
          );
          if (data == null) {
            if (miss != _Miss.stopped) {
              fail(miss, 'segment ${i + 1}/$total unreachable');
            }
            return null;
          }
          var bytes = data is Uint8List ? data : Uint8List.fromList(data);
          if (key == null) return bytes;
          try {
            final iv = pl.explicitIv ?? hlsSeqIv(pl.mediaSequence + i);
            bytes = await compute(_decryptSegment, (
              data: bytes,
              key: key,
              iv: iv,
            ));
            return bytes;
          } catch (_) {
            if (tries >= 3) {
              fail(_Miss.gone, 'segment ${i + 1}/$total could not be decrypted');
              return null;
            }
          }
          if (_stopNow()) return null;
        }
      }

      Future<void> worker() async {
        try {
          while (true) {
            if (failed || stop()) return;
            while (nextIndex - nextWrite > _maxAhead && !failed && !stop()) {
              final waiter = Completer<void>();
              aheadWaiters.add(waiter);
              // Woken by the writer; the timer only notices a pause or cancel.
              final timer = Timer(const Duration(milliseconds: 500), () {
                if (!waiter.isCompleted) waiter.complete();
              });
              await waiter.future;
              timer.cancel();
            }
            if (failed || stop()) return;
            final i = nextIndex++;
            if (i >= total) return;
            var bytes = await fetchSegment(i);
            if (bytes == null) return;
            if (pl.initUrl == null) bytes = hlsStripToTsSync(bytes);
            pending[i] = bytes;
            try {
              await drain();
            } catch (error) {
              writeError ??= error;
              fail(_Miss.none, 'The download could not be written to disk');
              return;
            }
          }
        } catch (error) {
          // Anything unexpected stops this run cleanly: every connection
          // ends before the file is closed.
          writeError ??= error;
          fail(_Miss.none, 'The download stopped unexpectedly');
        }
      }

      if (nextWrite < total) {
        await Future.wait(List.generate(concurrency, (_) => worker()));
      }
      // Keep whatever finished in order, then save the final position.
      try {
        if (writeError == null) await drain();
        if (bytesWritten > 0) await saveCheckpoint();
      } catch (error) {
        writeError ??= error;
      }
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
    // A fresh start that saved nothing at all leaves no empty partial
    // behind, so a Retry simply starts over.
    if (openedFresh && bytesWritten == 0) await discardPartial(outputPath);
    if (stop()) return stopped();
    if (writeError != null) {
      return writeError is FileSystemException
          ? 'The download could not be written to disk'
          : 'The download stopped unexpectedly';
    }
    if (failed) {
      return missResult(failMiss, failReason ?? 'incomplete');
    }
    if (nextWrite < total) return 'incomplete ($nextWrite/$total segments)';

    // 4. Separate audio track: its own resumable partial in the same folder,
    // then one merge. An interrupted merge is simply run again next time.
    if (selectedAudio != null) {
      final audio = selectedAudio!;
      final audioPath = '$outputPath.audio';
      final audioIdPath = '$audioPath.id';
      // Which track the finished audio file is: a track saved for another
      // language or group is never merged in.
      final audioTag =
          '${audio.lang}|${audio.groupId}|${audio.name}|'
          '${_stablePath(audio.uri)}';
      var haveAudio = false;
      try {
        haveAudio =
            await File(audioPath).exists() &&
            await File(audioIdPath).exists() &&
            await File(audioIdPath).readAsString() == audioTag;
      } catch (_) {}
      if (!haveAudio) {
        await _deleteQuietly(audioPath);
        await _deleteQuietly(audioIdPath);
        final audioDownloader = HlsDownloader(
          _dio,
          isHostCoolingDown: isHostCoolingDown,
          onRateLimited: onRateLimited,
          resilient: true,
          waitForNetwork: waitForNetwork,
          networkPatience: networkPatience,
          retryDelays: retryDelays,
        );
        final error = await audioDownloader.download(
          url: audio.uri,
          headers: headers,
          outputPath: audioPath,
          preferredQuality: 'best',
          connections: connections,
          onProgress: (value) => onProgress(.8 + value * .19),
          canceled: canceled,
          paused: paused,
          resumeKey: '$resumeKey|audio',
          sourceTag: 'audio|$audioTag',
        );
        if (audioDownloader.rateLimited) {
          _rateLimited = true;
          _rateLimitedUri = audioDownloader.rateLimitedUri;
          _receivedRateLimitResponse =
              audioDownloader.receivedRateLimitResponse;
        }
        if (error != null) {
          if (stop()) return stopped();
          if (const {
            networkResult,
            expiredResult,
            busyResult,
            finishLaterResult,
          }.contains(error)) {
            return error;
          }
          return _rateLimitMessage ?? 'Selected audio download failed: $error';
        }
        try {
          await File(audioIdPath).writeAsString(audioTag, flush: true);
        } catch (_) {
          // Not marked: the next run only fetches the audio again.
        }
      }
      final merged = '$outputPath.merging';
      try {
        await _deleteQuietly(merged);
        final mergeError = await muxAudio!(
          partPath,
          audioPath,
          merged,
          preferredAudioLanguage ?? audio.lang,
          stop,
        );
        if (stop() || mergeError != null) {
          await _deleteQuietly(merged);
          return stop() ? stopped() : mergeError;
        }
      } catch (_) {
        await _deleteQuietly(merged);
        return 'The selected audio could not be saved';
      }
      // Rename replaces an older file of the same name in one step.
      try {
        await File(merged).rename(outputPath);
      } catch (_) {
        await _deleteQuietly(merged);
        return finishLaterResult;
      }
      await discardPartial(outputPath);
      onProgress(1);
      return null;
    }

    // 5. Every segment is on disk: only now does it get its real name. Rename
    // replaces an older file of the same name in one step; when it cannot
    // (the old file is open somewhere), everything is kept for later.
    try {
      await part.rename(outputPath);
    } catch (_) {
      return finishLaterResult;
    }
    await discardPartial(outputPath);
    return null;
  }

  /// One request that waits out a weak or dropping connection: it tries
  /// again with growing waits (1, 2, 4, 8, then every 15 s), parks while the
  /// app knows the network is down, and gives up only after
  /// [networkPatience] of failing while the network looked up. That time
  /// counts the failed requests themselves and the waits between them, for
  /// this one request; a request that succeeds starts the next one afresh.
  ///
  /// A 429 keeps the existing cooldown path. A 403 or 410 is reported as
  /// expired (a fresh playlist link fixes it); any other 4xx is final. A web
  /// page where media was expected (a Wi-Fi sign-in page) counts as a
  /// failed try, never as data.
  Future<(T?, _Miss)> _patientGet<T>(
    String url,
    Map<String, String> headers,
    ResponseType type,
  ) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return (null, _Miss.gone);
    final online = Stopwatch();
    var attempt = 0;
    while (true) {
      if (_stopNow()) return (null, _Miss.stopped);
      if (!_mayRequest(uri)) return (null, _Miss.limited);
      online.start();
      // A pause or cancel ends a request that is stuck on a dead link at
      // once, instead of after the connect or receive timeout.
      final cancel = CancelToken();
      final watch = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (_stopNow() && !cancel.isCancelled) cancel.cancel();
      });
      try {
        final r = await _dio.getUri<T>(
          uri,
          cancelToken: cancel,
          options: Options(
            responseType: type,
            headers: headers,
            validateStatus: (s) => s != null && s < 500,
          ),
        );
        await _observeRateLimit(r);
        if (_rateLimited) return (null, _Miss.limited);
        final code = r.statusCode ?? 0;
        if (code == 403 || code == 410) return (null, _Miss.expired);
        if (code >= 400) return (null, _Miss.gone);
        if (code == 200 && r.data != null) {
          if (!_looksLikeWebPage(r.data, r.headers)) {
            return (r.data, _Miss.none);
          }
          // A web page in place of the media: try again like a drop.
        } else {
          // Answered without the content (another 2xx, an empty body): a
          // retry will not change that.
          return (null, _Miss.gone);
        }
      } on DioException catch (error) {
        if (error.response != null) await _observeRateLimit(error.response!);
        if (_rateLimited) return (null, _Miss.limited);
        // A 5xx answer or no answer at all: both usually pass, so try again.
      } catch (_) {
        // Reset connection, DNS failure, timeout: exactly what waiting is for.
      } finally {
        watch.cancel();
      }
      online.stop();
      if (_stopNow()) return (null, _Miss.stopped);
      // Park while the network is down. That time is not counted, and the
      // waits start small again once it is back.
      final parked = Stopwatch()..start();
      await _untilOnline();
      if (parked.elapsed > const Duration(milliseconds: 500)) attempt = 0;
      if (_stopNow()) return (null, _Miss.stopped);
      if (online.elapsed >= networkPatience) return (null, _Miss.network);
      final delay = retryDelays.isEmpty
          ? Duration.zero
          : retryDelays[attempt < retryDelays.length
                ? attempt
                : retryDelays.length - 1];
      attempt++;
      online.start();
      await _sleepUnlessStopped(delay);
      online.stop();
    }
  }

  /// Waits for [waitForNetwork], but wakes for a pause or cancel too. One
  /// listener and one timer per wait, however long the outage lasts.
  Future<void> _untilOnline() async {
    final wait = waitForNetwork;
    if (wait == null || _stopNow()) return;
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    unawaited(wait().catchError((Object _) {}).whenComplete(finish));
    final watch = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_stopNow()) finish();
    });
    try {
      await done.future;
    } finally {
      watch.cancel();
    }
  }

  /// Sleeps for [delay] in short steps so a pause or cancel is not kept waiting.
  Future<void> _sleepUnlessStopped(Duration delay) async {
    final end = DateTime.now().add(delay);
    while (!_stopNow()) {
      final left = end.difference(DateTime.now());
      if (left <= Duration.zero) return;
      await Future<void>.delayed(
        left < const Duration(milliseconds: 250)
            ? left
            : const Duration(milliseconds: 250),
      );
    }
  }

  static String _resolveRef(String ref, String base) {
    if (ref.startsWith('http://') || ref.startsWith('https://')) return ref;
    return Uri.parse(base).resolve(ref).toString();
  }
}

class _MediaPlaylist {
  final List<String> segments = [];

  /// Each segment's `#EXTINF` length as written in the playlist.
  final List<String> durations = [];
  String? keyUrl;
  Uint8List? explicitIv;
  int mediaSequence = 0;

  /// fMP4 initialization segment (`#EXT-X-MAP:URI="…"`) — the ftyp+moov header
  /// the `.m4s` fragments lack. Null for plain TS playlists.
  String? initUrl;
}

/// [hlsAesCbcDecrypt] shaped for [compute] — one argument, top-level, so it can
/// cross an isolate boundary.
Uint8List _decryptSegment(({Uint8List data, Uint8List key, Uint8List iv}) m) =>
    hlsAesCbcDecrypt(m.data, m.key, m.iv);

// ── Crypto helpers (top-level so they're unit-testable) ──────────────────────

/// AES-128-CBC decrypt with PKCS7 unpadding (HLS segment encryption). Returns
/// the input unchanged when it isn't block-aligned.
Uint8List hlsAesCbcDecrypt(Uint8List data, Uint8List key, Uint8List iv) {
  if (data.isEmpty || data.length % 16 != 0) return data;
  final cipher = CBCBlockCipher(AESEngine())
    ..init(false, ParametersWithIV<KeyParameter>(KeyParameter(key), iv));
  final out = Uint8List(data.length);
  for (var off = 0; off < data.length; off += 16) {
    cipher.processBlock(data, off, out, off);
  }
  // Strip PKCS7 padding when it's valid (HLS pads each segment).
  final pad = out[out.length - 1];
  if (pad >= 1 && pad <= 16 && pad <= out.length) {
    var valid = true;
    for (var k = out.length - pad; k < out.length; k++) {
      if (out[k] != pad) {
        valid = false;
        break;
      }
    }
    if (valid) return Uint8List.sublistView(out, 0, out.length - pad);
  }
  return out;
}

/// 16-byte big-endian IV from a segment's media-sequence number (the HLS
/// default when no explicit `IV=` is given in the playlist).
Uint8List hlsSeqIv(int seq) {
  final iv = Uint8List(16);
  var v = seq;
  for (var i = 15; i >= 0 && v != 0; i--) {
    iv[i] = v & 0xff;
    v >>= 8;
  }
  return iv;
}

/// Strip a decoy/junk prefix that some anti-scrape CDNs prepend to each TS
/// segment (e.g. a 1×1 PNG + "Service01" marker sitting before the real
/// stream). MPEG-TS is 188-byte packets each starting with sync byte 0x47;
/// find the first offset that is 0x47 AND is 0x47 again one and two packets
/// later — a real packet boundary, not a stray match — and return the bytes
/// from there. A clean segment already starts at a valid boundary, so this
/// returns it UNCHANGED (offset 0); when no aligned sync is found within a
/// small window (non-TS data, or an unusually large prefix) it also returns the
/// input untouched, so it can never corrupt a normal download.
Uint8List hlsStripToTsSync(Uint8List seg) {
  const ts = 188;
  if (seg.length < ts * 3) return seg; // too short to validate — leave alone
  // A real decoy prefix is tiny (tens/hundreds of bytes). Bound the scan so we
  // find it near the start and never match a coincidental 0x47 deep in payload.
  final maxStart = seg.length - ts * 2;
  final scanEnd = maxStart < 4096 ? maxStart : 4096;
  for (var i = 0; i < scanEnd; i++) {
    if (seg[i] == 0x47 && seg[i + ts] == 0x47 && seg[i + ts * 2] == 0x47) {
      return i == 0 ? seg : Uint8List.sublistView(seg, i);
    }
  }
  return seg; // no aligned TS sync near the start — don't touch it
}

/// Parse an `IV=0x...` hex string into 16 bytes; null if malformed.
Uint8List? hlsParseHexIv(String s) {
  var h = s.trim();
  if (h.startsWith('0x') || h.startsWith('0X')) h = h.substring(2);
  if (h.length != 32) return null;
  final out = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    final b = int.tryParse(h.substring(i * 2, i * 2 + 2), radix: 16);
    if (b == null) return null;
    out[i] = b;
  }
  return out;
}

/// First non-comment URI line in an HLS playlist (variant or segment).
String? hlsFirstUriLine(String playlist) {
  var expectUri = false;
  for (final raw in playlist.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final upper = line.toUpperCase();
    if (upper.startsWith('#EXT-X-I-FRAME-STREAM-INF')) continue;
    if (upper.startsWith('#EXT-X-STREAM-INF') || upper.startsWith('#EXTINF')) {
      expectUri = true;
      continue;
    }
    if (line.startsWith('#')) continue;
    if (expectUri) return line;
  }
  // Media playlists sometimes omit a recognizable tag before the first URI.
  for (final raw in playlist.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    return line;
  }
  return null;
}

bool hlsPlaylistIsMaster(String playlist) =>
    playlist.contains('#EXT-X-STREAM-INF');

bool hlsPlaylistIsEncrypted(String playlist) {
  final u = playlist.toUpperCase();
  return u.contains('#EXT-X-KEY:METHOD=AES-128') ||
      u.contains('#EXT-X-KEY:METHOD=SAMPLE-AES');
}

/// Peel a decoy image/junk prefix off a disguised HLS segment (`.jpg` / PNG
/// wrappers used by some CDNs). Scans the fetched prefix for MPEG-TS sync or
/// an ISO-BMFF `ftyp`/`moof` box. Returns null if neither is found.
Uint8List? hlsUnwrapSegment(Uint8List seg, {int scanLimit = 128 * 1024}) {
  if (seg.length < 12) return seg;
  if (seg[0] == 0x47 && _hasTsSync(seg, 188, 0)) return seg;
  if (isoLooksLikeFmp4(seg)) return seg;
  final limit = seg.length < scanLimit ? seg.length : scanLimit;
  const ts = 188;
  final tsEnd = limit - ts * 3;
  for (var i = 1; i <= tsEnd; i++) {
    if (seg[i] == 0x47 &&
        seg[i + ts] == 0x47 &&
        seg[i + ts * 2] == 0x47 &&
        (i + ts * 3 >= seg.length || seg[i + ts * 3] == 0x47)) {
      return Uint8List.sublistView(seg, i);
    }
  }
  for (var i = 4; i + 8 <= limit; i++) {
    final a = seg[i], b = seg[i + 1], c = seg[i + 2], d = seg[i + 3];
    final ftyp = a == 0x66 && b == 0x74 && c == 0x79 && d == 0x70; // ftyp
    final styp = a == 0x73 && b == 0x74 && c == 0x79 && d == 0x70; // styp
    final moof = a == 0x6d && b == 0x6f && c == 0x6f && d == 0x66; // moof
    if (ftyp || styp || moof) {
      return Uint8List.sublistView(seg, i - 4);
    }
  }
  return null;
}

String hlsSegmentMagic(Uint8List data) {
  final n = data.length < 8 ? data.length : 8;
  final hex = data
      .sublist(0, n)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join(' ');
  if (n >= 2 && data[0] == 0xFF && data[1] == 0xD8) return 'jpeg $hex';
  if (n >= 4 && data[0] == 0x89 && data[1] == 0x50) return 'png $hex';
  if (n >= 4 && data[0] == 0x47) return 'ts $hex';
  if (isoLooksLikeFmp4(data)) return 'fmp4 $hex';
  return hex;
}

double? mpegTsFirstPtsSeconds(Uint8List data) {
  final inspect = mpegTsInspect(data);
  return inspect.videoPts ?? inspect.audioPts;
}

class MpegTsInspect {
  const MpegTsInspect({
    this.pcr,
    this.videoPts,
    this.audioPts,
    this.videoPid,
    this.audioPid,
    this.ptsSamples = const [],
  });
  final double? pcr;
  final double? videoPts;
  final double? audioPts;
  final int? videoPid;
  final int? audioPid;
  final List<double> ptsSamples;

  /// Sidecar VTT origin: audio-behind-video skew, then Apple-style PTS/PCR padding.
  double? get epoch {
    if (audioPts != null && videoPts != null) {
      final skew = audioPts! - videoPts!;
      if (skew >= 0.5 && skew <= 60) return audioPts;
    }
    return _inPaddingRange(videoPts) ??
        _inPaddingRange(audioPts) ??
        _inPaddingRange(pcr);
  }

  String get summary {
    String f(double? v) => v == null ? '-' : v.toStringAsFixed(3);
    final skew = (audioPts != null && videoPts != null)
        ? (audioPts! - videoPts!).toStringAsFixed(3)
        : '-';
    return 'pcr=${f(pcr)}s videoPts=${f(videoPts)}s audioPts=${f(audioPts)}s '
        'avSkew=${skew}s vpid=${videoPid ?? '-'} apid=${audioPid ?? '-'}';
  }
}

/// Apple HLS padding is typically 10s (MPEGTS 900000). Tiny PCR/PTS (~0.1–0.5s)
/// is just the first frame, not a caption origin.
double? _inPaddingRange(double? t) {
  if (t == null || t < 8 || t > 30) return null;
  return t;
}

MpegTsInspect mpegTsInspect(Uint8List data) {
  final bytes = data.length >= 188 * 3 ? hlsStripToTsSync(data) : data;
  final packetSize = _tsPacketSize(bytes);
  if (packetSize == null) return const MpegTsInspect();
  final hdr = packetSize == 192 ? 4 : 0;
  var i = 0;
  double? pcr;
  double? paddingPcr;
  double? videoPts;
  double? audioPts;
  int? pmtPid;
  int? videoPid;
  int? audioPid;
  final audioPids = <int>{};
  final videoPids = <int>{};
  final pmtSeen = <int>{};
  final ptsSamples = <double>[];
  while (i + packetSize <= bytes.length) {
    final sync = i + hdr;
    if (bytes[sync] != 0x47) {
      i += 1;
      continue;
    }
    final pusi = (bytes[sync + 1] & 0x40) != 0;
    final pid = ((bytes[sync + 1] & 0x1f) << 8) | bytes[sync + 2];
    final adapt = (bytes[sync + 3] >> 4) & 0x3;
    var payload = sync + 4;
    if (adapt == 2 || adapt == 3) {
      final adaptLen = bytes[sync + 4];
      if (adaptLen > 0 && payload + 1 + adaptLen <= sync + 188) {
        final flags = bytes[sync + 5];
        if ((flags & 0x10) != 0 && sync + 12 <= bytes.length) {
          final parsed = _mpegTsPcr(bytes, sync + 6);
          pcr ??= parsed;
          paddingPcr ??= _inPaddingRange(parsed);
        }
      }
      payload = sync + 5 + adaptLen;
    }
    i += packetSize;
    if (pid == 0x1fff || !pusi || payload >= sync + 188) continue;
    if (pid == 0) {
      pmtPid ??= _patProgramMapPid(bytes, payload, sync + 188);
      continue;
    }
    if (pmtPid != null && pid == pmtPid && !pmtSeen.contains(pid)) {
      pmtSeen.add(pid);
      final pmt = _pmtAvPids(bytes, payload, sync + 188);
      videoPid ??= pmt.video;
      audioPid ??= pmt.audio;
      if (pmt.video != null) videoPids.add(pmt.video!);
      audioPids.addAll(pmt.audios);
      continue;
    }
    if (payload + 14 > sync + 188) continue;
    if (bytes[payload] != 0 ||
        bytes[payload + 1] != 0 ||
        bytes[payload + 2] != 1) {
      continue;
    }
    if ((bytes[payload + 6] & 0xC0) != 0x80) continue;
    final ptsDts = (bytes[payload + 7] >> 6) & 0x3;
    if (ptsDts < 2) continue;
    if (!_mpegTsPtsMarkersOk(bytes, payload + 9)) continue;
    final pts = _mpegTsPts(bytes, payload + 9) / 90000.0;
    if (ptsSamples.length < 8) ptsSamples.add(pts);
    final streamId = bytes[payload + 3];
    final isVideo =
        (streamId >= 0xE0 && streamId <= 0xEF) || videoPids.contains(pid);
    final isAudio =
        (streamId >= 0xC0 && streamId <= 0xDF) ||
        streamId == 0xBD ||
        audioPids.contains(pid);
    if (isVideo) videoPts ??= pts;
    if (isAudio) audioPts ??= pts;
  }
  return MpegTsInspect(
    pcr: paddingPcr ?? pcr,
    videoPts: videoPts,
    audioPts: audioPts,
    videoPid: videoPid,
    audioPid: audioPid,
    ptsSamples: ptsSamples,
  );
}

double? _mpegTsPcr(Uint8List b, int i) {
  if (i + 6 > b.length) return null;
  final base =
      (b[i] << 25) |
      (b[i + 1] << 17) |
      (b[i + 2] << 9) |
      (b[i + 3] << 1) |
      ((b[i + 4] >> 7) & 1);
  return base / 90000.0;
}

bool _mpegTsPtsMarkersOk(Uint8List b, int i) {
  if (i + 5 > b.length) return false;
  final prefix = b[i] & 0xF1;
  if (prefix != 0x21 && prefix != 0x31) return false;
  return (b[i + 2] & 1) == 1 && (b[i + 4] & 1) == 1;
}

int? _patProgramMapPid(Uint8List b, int payload, int end) {
  var o = payload;
  if (o >= end) return null;
  o += 1 + b[o]; // pointer_field
  if (o + 8 > end || b[o] != 0) return null;
  final sectionLen = ((b[o + 1] & 0x0f) << 8) | b[o + 2];
  final sectionEnd = o + 3 + sectionLen - 4; // minus CRC
  o += 8;
  while (o + 4 <= sectionEnd && o + 4 <= end) {
    final prog = (b[o] << 8) | b[o + 1];
    final pid = ((b[o + 2] & 0x1f) << 8) | b[o + 3];
    o += 4;
    if (prog != 0) return pid;
  }
  return null;
}

class _PmtAvPids {
  const _PmtAvPids({this.video, this.audio, this.audios = const {}});
  final int? video;
  final int? audio;
  final Set<int> audios;
}

_PmtAvPids _pmtAvPids(Uint8List b, int payload, int end) {
  var o = payload;
  if (o >= end) return const _PmtAvPids();
  o += 1 + b[o];
  if (o + 12 > end || b[o] != 0x02) return const _PmtAvPids();
  final sectionLen = ((b[o + 1] & 0x0f) << 8) | b[o + 2];
  final sectionEnd = o + 3 + sectionLen - 4;
  final progInfo = ((b[o + 10] & 0x0f) << 8) | b[o + 11];
  o += 12 + progInfo;
  int? video;
  int? audio;
  final audios = <int>{};
  const videoTypes = {0x01, 0x02, 0x10, 0x1B, 0x24, 0x20, 0x27, 0xDB, 0xEA};
  const audioTypes = {0x03, 0x04, 0x0F, 0x11, 0x81, 0x87, 0x06, 0x83, 0x84};
  while (o + 5 <= sectionEnd && o + 5 <= end) {
    final streamType = b[o];
    final epid = ((b[o + 1] & 0x1f) << 8) | b[o + 2];
    final esInfo = ((b[o + 3] & 0x0f) << 8) | b[o + 4];
    o += 5 + esInfo;
    if (video == null && videoTypes.contains(streamType)) video = epid;
    if (audioTypes.contains(streamType)) {
      audio ??= epid;
      audios.add(epid);
    }
  }
  return _PmtAvPids(video: video, audio: audio, audios: audios);
}

int? _tsPacketSize(Uint8List bytes) {
  if (_hasTsSync(bytes, 188, 0)) return 188;
  if (_hasTsSync(bytes, 192, 4)) return 192;
  if (bytes.length >= 188 && bytes[0] == 0x47) return 188;
  final limit = bytes.length < 4096 ? bytes.length : 4096;
  for (var i = 0; i + 564 < limit; i++) {
    if (bytes[i] == 0x47 && bytes[i + 188] == 0x47 && bytes[i + 376] == 0x47) {
      return 188;
    }
  }
  return null;
}

bool _hasTsSync(Uint8List bytes, int packetSize, int header) {
  if (bytes.length < packetSize * 3) return false;
  return bytes[header] == 0x47 &&
      bytes[header + packetSize] == 0x47 &&
      bytes[header + packetSize * 2] == 0x47;
}

int _mpegTsPts(Uint8List bytes, int i) {
  final b0 = bytes[i];
  final b1 = bytes[i + 1];
  final b2 = bytes[i + 2];
  final b3 = bytes[i + 3];
  final b4 = bytes[i + 4];
  return ((b0 & 0x0E) << 29) |
      (b1 << 22) |
      ((b2 & 0xFE) << 14) |
      (b3 << 7) |
      ((b4 & 0xFE) >> 1);
}

bool isoLooksLikeFmp4(Uint8List data) {
  if (data.length < 8) return false;
  final type = String.fromCharCodes(data.sublist(4, 8));
  return type == 'ftyp' ||
      type == 'styp' ||
      type == 'moof' ||
      type == 'moov' ||
      type == 'sidx';
}

String? hlsExtXMapUri(String playlist) {
  for (final raw in playlist.split('\n')) {
    final line = raw.trim();
    if (!line.toUpperCase().startsWith('#EXT-X-MAP:')) continue;
    return hlsAttr(line, 'URI');
  }
  return null;
}

double? hlsExtXStartOffset(String playlist) {
  final m = RegExp(
    r'#EXT-X-START:[^\n]*TIME-OFFSET=(-?[\d.]+)',
    caseSensitive: false,
  ).firstMatch(playlist);
  if (m == null) return null;
  return double.tryParse(m.group(1)!);
}

class HlsMediaSegment {
  const HlsMediaSegment({
    required this.duration,
    required this.uri,
    required this.discontinuity,
  });
  final double duration;
  final String uri;
  final bool discontinuity;
}

/// Media playlist segments in file order (relative URIs left unresolved).
List<HlsMediaSegment> hlsMediaSegments(String playlist, {int max = 32}) {
  final out = <HlsMediaSegment>[];
  var pendingDuration = 0.0;
  var pendingDisc = false;
  var haveDuration = false;
  for (final raw in playlist.split('\n')) {
    if (out.length >= max) break;
    final line = raw.trim();
    if (line.isEmpty) continue;
    final upper = line.toUpperCase();
    if (upper.startsWith('#EXT-X-DISCONTINUITY') &&
        !upper.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE')) {
      pendingDisc = true;
      continue;
    }
    if (upper.startsWith('#EXTINF:')) {
      final comma = line.indexOf(',');
      final spec = comma < 0 ? line.substring(8) : line.substring(8, comma);
      pendingDuration = double.tryParse(spec.trim()) ?? 0;
      haveDuration = true;
      continue;
    }
    if (line.startsWith('#')) continue;
    if (!haveDuration) continue;
    out.add(
      HlsMediaSegment(
        duration: pendingDuration,
        uri: line,
        discontinuity: pendingDisc,
      ),
    );
    pendingDisc = false;
    haveDuration = false;
    pendingDuration = 0;
  }
  return out;
}

/// Leading content before the first discontinuity, when that looks like a bumper.
double? hlsLeadingDiscontinuitySeconds(List<HlsMediaSegment> segments) {
  if (segments.length < 2) return null;
  final idx = segments.indexWhere((s) => s.discontinuity);
  if (idx <= 0) return null;
  var sum = 0.0;
  for (var i = 0; i < idx; i++) {
    sum += segments[i].duration;
  }
  return _inPaddingRange(sum);
}

double? hlsDateRangeDuration(String playlist) {
  final m = RegExp(
    r'#EXT-X-DATERANGE:[^\n]*DURATION=([\d.]+)',
    caseSensitive: false,
  ).firstMatch(playlist);
  if (m == null) return null;
  return _inPaddingRange(double.tryParse(m.group(1)!));
}

String hlsPlaylistPreview(String playlist, {int maxLines = 24}) {
  final lines = playlist
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .take(maxLines);
  final text = lines.join(' | ');
  return text.length <= 700 ? text : '${text.substring(0, 700)}…';
}

/// `#EXT…` tags only (no segment URIs), for compact timing logs.
String hlsPlaylistTagSummary(String playlist, {int max = 40}) {
  final tags = playlist
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.startsWith('#') && !l.toUpperCase().startsWith('#EXTINF'))
      .take(max);
  return tags.join(' | ');
}

final _hlsHexId = RegExp(r'^[a-fA-F0-9]{32}$');

/// Last 32-hex path folder (Kryntal-style encode id), or null.
String? hlsCdnEncodeId(String url) {
  final segs = Uri.tryParse(url)?.pathSegments ?? const <String>[];
  String? last;
  for (final s in segs) {
    if (_hlsHexId.hasMatch(s)) last = s;
  }
  return last;
}

/// Rewrite the encode folder in [url] (last 32-hex segment) to [newEncodeId].
String? hlsCdnSwapEncode(String url, String newEncodeId) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final segs = List<String>.from(uri.pathSegments);
  var idx = -1;
  for (var i = 0; i < segs.length; i++) {
    if (_hlsHexId.hasMatch(segs[i])) idx = i;
  }
  if (idx < 0) return null;
  segs[idx] = newEncodeId;
  return uri.replace(pathSegments: segs).toString();
}

double hlsSumExtinf(String playlist) {
  final segs = hlsMediaSegments(playlist, max: 8192);
  return segs.fold<double>(0, (a, s) => a + s.duration);
}

/// Seconds of [playing] that occur before [other]'s EXTINF pattern.
/// 0 means they start together (any duration gap is at the tail).
double? hlsLeadingExtinfSkew(
  List<double> playing,
  List<double> other, {
  double eps = 0.15,
  int needleLen = 12,
}) {
  if (playing.length < 8 || other.length < 8) return null;

  bool matchAt(List<double> hay, int start, List<double> needle) {
    if (start < 0 || start + needle.length > hay.length) return false;
    for (var i = 0; i < needle.length; i++) {
      if ((hay[start + i] - needle[i]).abs() > eps) return false;
    }
    return true;
  }

  double sumBefore(List<double> list, int start) {
    var s = 0.0;
    for (var i = 0; i < start; i++) {
      s += list[i];
    }
    return s;
  }

  double? uniqueLead({
    required List<double> hay,
    required List<double> needle,
  }) {
    final n = needle.length;
    if (n < 8 || hay.length < n) return null;
    double? found;
    for (var start = 0; start <= hay.length - n; start++) {
      if (!matchAt(hay, start, needle)) continue;
      final lead = sumBefore(hay, start);
      if (found != null && (found - lead).abs() > eps) return null;
      found = lead;
    }
    return found;
  }

  for (final nTry in [needleLen, 8]) {
    final n = nTry < other.length ? nTry : other.length;
    if (n < 8) continue;
    final lead = uniqueLead(hay: playing, needle: other.take(n).toList());
    if (lead != null) return lead;
    final reverse = uniqueLead(hay: other, needle: playing.take(n).toList());
    if (reverse != null && reverse > 0) return -reverse;
  }
  return null;
}

/// Compact playlist timing dump for `[zangetsu-sub-timing]` logs.
String hlsExtinfFingerprint(List<HlsMediaSegment> segs) {
  if (segs.isEmpty) return 'empty';
  final durs = [for (final s in segs) s.duration];
  final total = durs.fold<double>(0, (a, b) => a + b);
  String fmt(Iterable<double> xs) =>
      xs.map((x) => x.toStringAsFixed(3)).join(',');
  final discs = <String>[];
  var t = 0.0;
  var runLen = 1;
  var runAt = 0.0;
  var bestLen = 1;
  var bestDur = durs.first;
  var bestAt = 0.0;
  for (var i = 0; i < segs.length; i++) {
    if (segs[i].discontinuity) {
      discs.add('${t.toStringAsFixed(1)}s#${i}');
    }
    if (i > 0) {
      if ((durs[i] - durs[i - 1]).abs() <= 0.05) {
        runLen++;
        if (runLen > bestLen) {
          bestLen = runLen;
          bestDur = durs[i];
          bestAt = runAt;
        }
      } else {
        runLen = 1;
        runAt = t;
      }
    }
    t += durs[i];
  }
  final head = fmt(durs.take(16));
  final tail = fmt(durs.skip(durs.length > 16 ? durs.length - 16 : 0));
  final repeat = bestLen >= 4
      ? ' repeat=${bestLen}x${bestDur.toStringAsFixed(3)}@${bestAt.toStringAsFixed(1)}s'
      : '';
  return 'n=${segs.length} dur=${total.toStringAsFixed(3)} '
      'head=[$head] tail=[$tail] '
      'disc=${discs.isEmpty ? "none" : discs.join(",")}'
      '$repeat';
}

/// Highest-resolution variant, preferring [preferBasename] when present.
String? hlsPreferredVariantUri(
  String master,
  String masterUrl, {
  String? preferBasename,
}) {
  final uris = hlsVariantUrisOrdered(
    master,
    masterUrl,
    preferBasename: preferBasename,
  );
  return uris.isEmpty ? null : uris.first;
}

/// Variant URLs from a master: matching basename first, then high→low res.
List<String> hlsVariantUrisOrdered(
  String master,
  String masterUrl, {
  String? preferBasename,
}) {
  final variants = parseHlsMaster(master, masterUrl);
  final out = <String>[];
  if (preferBasename != null && preferBasename.isNotEmpty) {
    for (final v in variants) {
      if (Uri.parse(v.url).pathSegments.last == preferBasename) {
        out.add(v.url);
        break;
      }
    }
  }
  for (final v in variants) {
    if (!out.contains(v.url)) out.add(v.url);
  }
  if (out.isEmpty) {
    final first = hlsFirstUriLine(master);
    if (first != null) out.add(Uri.parse(masterUrl).resolve(first).toString());
  }
  return out;
}

/// Presentation start of an fMP4 init+fragment, in seconds (`tfdt / mdhd`).
double? fmp4BaseMediaTimeSeconds(Uint8List init, [Uint8List? fragment]) {
  var timescale = isoMdhdTimescale(init);
  var tfdt = isoTfdt(init);
  if (fragment != null) {
    timescale ??= isoMdhdTimescale(fragment);
    tfdt ??= isoTfdt(fragment);
  }
  if (timescale == null || timescale <= 0 || tfdt == null) return null;
  return tfdt / timescale;
}

int? isoMdhdTimescale(Uint8List data) {
  int? scale;
  _isoWalk(data, 0, data.length, (type, start, end) {
    if (type != 'mdhd' || scale != null || start + 16 > end) return;
    final version = data[start];
    if (version == 1) {
      if (start + 32 > end) return;
      scale = _isoU32(data, start + 20);
    } else {
      scale = _isoU32(data, start + 12);
    }
  });
  return scale;
}

int? isoTfdt(Uint8List data) {
  int? value;
  _isoWalk(data, 0, data.length, (type, start, end) {
    if (type != 'tfdt' || value != null || start + 8 > end) return;
    final version = data[start];
    if (version == 1) {
      if (start + 12 > end) return;
      value = _isoU64(data, start + 4);
    } else {
      value = _isoU32(data, start + 4);
    }
  });
  return value;
}

void _isoWalk(
  Uint8List data,
  int start,
  int end,
  void Function(String type, int payloadStart, int payloadEnd) visit,
) {
  var i = start;
  while (i + 8 <= end) {
    var size = _isoU32(data, i);
    final type = String.fromCharCodes(data.sublist(i + 4, i + 8));
    var header = 8;
    if (size == 1) {
      if (i + 16 > end) return;
      size = _isoU64(data, i + 8);
      header = 16;
    } else if (size == 0) {
      size = end - i;
    }
    if (size < header || i + size > end) return;
    final payloadStart = i + header;
    final payloadEnd = i + size;
    visit(type, payloadStart, payloadEnd);
    const containers = {
      'moov',
      'trak',
      'mdia',
      'minf',
      'stbl',
      'moof',
      'traf',
      'mvex',
      'edts',
    };
    if (containers.contains(type)) {
      _isoWalk(data, payloadStart, payloadEnd, visit);
    }
    i += size;
  }
}

int _isoU32(Uint8List b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

int _isoU64(Uint8List b, int i) {
  final hi = _isoU32(b, i);
  final lo = _isoU32(b, i + 4);
  return (hi << 32) | lo;
}

/// Why a resilient request came back empty.
enum _Miss {
  /// It did not fail.
  none,

  /// A pause or cancel stopped it.
  stopped,

  /// The connection kept failing for the whole patience window.
  network,

  /// 403 or 410: the signed link most likely expired.
  expired,

  /// The host is rate limiting (429 or a saved cooldown).
  limited,

  /// The host answered with another error; asking again will not help.
  gone,
}

import 'package:dio/dio.dart';

/// One rendition listed in a DASH (`.mpd`) manifest.
///
/// Only what the Windows downloader needs: which kind of track it is, how
/// tall the picture is, how many bits per second it costs, and its language.
class DashRepresentation {
  const DashRepresentation({
    required this.id,
    required this.isVideo,
    this.height,
    this.bandwidth,
    this.language,
  });

  /// The manifest's own `Representation@id` (may be empty).
  final String id;

  /// True for a picture rendition, false for a sound rendition.
  final bool isVideo;

  /// Picture height in pixels (video only); null when the manifest omits it.
  final int? height;

  /// Bits per second the manifest declares; null when it omits it.
  final int? bandwidth;

  /// Audio language from the adaptation set (`lang`), lower case.
  final String? language;
}

/// The parts of a DASH manifest the Windows batch download needs.
///
/// The player learns DASH qualities from mpv's track list after the stream
/// opens. A download has no player, so it reads the same manifest itself:
/// the video renditions here are the same 1080p / 720p / 480p the player's
/// Quality sheet shows for that stream.
class DashManifest {
  const DashManifest({
    required this.videos,
    required this.audios,
    this.duration,
  });

  /// Video renditions in manifest order. The order matters: ffmpeg's DASH
  /// reader numbers its video streams in this same order, so the index of a
  /// rendition here is the `0:v:<index>` the downloader maps.
  final List<DashRepresentation> videos;

  /// Audio renditions in manifest order (ffmpeg's `0:a:<index>`).
  final List<DashRepresentation> audios;

  /// Whole-programme length (`mediaPresentationDuration`); null when absent.
  final Duration? duration;

  /// Distinct picture heights, tallest first, e.g. [1080, 720, 480].
  List<int> get heights {
    final out = <int>{
      for (final v in videos)
        if ((v.height ?? 0) > 0) v.height!,
    }.toList()..sort((a, b) => b.compareTo(a));
    return out;
  }

  /// Index into [videos] for a wanted [height]: the best rendition at that
  /// height, else the tallest one BELOW it (an episode that lacks 720p gets
  /// 480p, never a bigger file than asked for), else the shortest one above.
  /// A null [height] means "best": the tallest, highest-bitrate rendition.
  /// Returns null when the manifest lists no video at all.
  int? videoIndexFor(int? height) {
    if (videos.isEmpty) return null;
    int h(int i) => videos[i].height ?? 0;
    int bw(int i) => videos[i].bandwidth ?? 0;
    final all = List<int>.generate(videos.length, (i) => i);
    // Best first: taller, then more bits per second.
    all.sort((a, b) {
      final byHeight = h(b).compareTo(h(a));
      return byHeight != 0 ? byHeight : bw(b).compareTo(bw(a));
    });
    if (height == null) return all.first;
    for (final i in all) {
      if (h(i) <= height) return i; // first at-or-below = nearest lower
    }
    return all.last; // everything is taller: take the smallest of them
  }

  /// Index into [audios] for the preferred [language] (ISO code or name,
  /// compared loosely), else the highest-bitrate audio. Null when the
  /// manifest has no separate audio (the video then carries its own sound).
  /// The downloader checks [audioLanguageMissing] first, so the bitrate
  /// fallback is only used when the manifest names no languages (the size
  /// estimate also uses it loosely).
  int? audioIndexFor(String? language) {
    if (audios.isEmpty) return null;
    final match = _audioLanguageMatch(language);
    if (match != null) return match;
    var best = 0;
    for (var i = 1; i < audios.length; i++) {
      if ((audios[i].bandwidth ?? 0) > (audios[best].bandwidth ?? 0)) best = i;
    }
    return best;
  }

  /// Index of the first audio whose `lang` loosely matches [language]
  /// ("hi" matches "hin" and "hi-IN"); null when nothing was asked for or
  /// nothing matches.
  int? _audioLanguageMatch(String? language) {
    final want = language?.trim().toLowerCase() ?? '';
    if (want.isEmpty) return null;
    for (var i = 0; i < audios.length; i++) {
      final lang = audios[i].language ?? '';
      if (lang.isNotEmpty && (lang.startsWith(want) || want.startsWith(lang))) {
        return i;
      }
    }
    return null;
  }

  /// True when the download must refuse this stream for its sound: a
  /// [language] was asked for, the manifest names its audio languages, and
  /// none of them is that language. The batch treats audio language as a
  /// hard rule (like the Windows HLS path), so the downloader then fails
  /// this mirror instead of quietly saving another language. A manifest
  /// with no `lang` at all cannot be checked, so it is not refused.
  bool audioLanguageMissing(String? language) {
    if ((language?.trim() ?? '').isEmpty || audios.isEmpty) return false;
    if (!audios.any((a) => (a.language ?? '').isNotEmpty)) return false;
    return _audioLanguageMatch(language) == null;
  }

  /// Rough bytes for one episode at the chosen renditions: declared bits per
  /// second times the programme length. Null when either is unknown.
  int? estimateBytes(int? videoIndex, int? audioIndex) {
    final d = duration;
    if (d == null || videoIndex == null) return null;
    final v = videos[videoIndex].bandwidth;
    if (v == null || v <= 0) return null;
    final a = audioIndex == null ? 0 : (audios[audioIndex].bandwidth ?? 0);
    return ((v + a) * d.inMilliseconds / 8000).round();
  }

  /// Reads a manifest's XML. Returns null for text that is not an MPD.
  ///
  /// A small tag scanner rather than a full XML parser (the app ships no XML
  /// package): an MPD's AdaptationSet / Representation tags are flat and
  /// attribute-only, which is all this needs.
  static DashManifest? tryParse(String text) {
    final mpd = RegExp(r'<(?:\w+:)?MPD\b([^>]*)>').firstMatch(text);
    if (mpd == null) return null;
    // ffmpeg numbers renditions in document order; only the first period is
    // used, like the player's single-programme streams.
    final periodStart = RegExp(r'<(?:\w+:)?Period\b').firstMatch(text);
    if (periodStart == null) return null;
    var body = text.substring(periodStart.start);
    final periodEnd = RegExp(r'</(?:\w+:)?Period\s*>').firstMatch(body);
    if (periodEnd != null) body = body.substring(0, periodEnd.end);
    final videos = <DashRepresentation>[];
    final audios = <DashRepresentation>[];
    // An empty self-closed set ("<AdaptationSet .../>") has no renditions;
    // the other branch takes everything up to the set's closing tag.
    final sets = RegExp(
      r'<(?:\w+:)?AdaptationSet\b([^>]*?)(?:/>|>(.*?)(?:</(?:\w+:)?AdaptationSet\s*>|$))',
      dotAll: true,
    );
    for (final set in sets.allMatches(body)) {
      final setAttrs = set.group(1) ?? '';
      final inner = set.group(2) ?? '';
      final setType = _kindOf(setAttrs);
      final setHeight = int.tryParse(_attr(setAttrs, 'height') ?? '');
      final lang = _attr(setAttrs, 'lang')?.trim().toLowerCase();
      for (final rep in RegExp(
        r'<(?:\w+:)?Representation\b([^>]*)>',
      ).allMatches(inner)) {
        final attrs = rep.group(1) ?? '';
        // A rendition may name its own type; else it inherits the set's.
        final type = _kindOf(attrs) ?? setType;
        if (type == null) continue;
        final r = DashRepresentation(
          id: _attr(attrs, 'id') ?? '',
          isVideo: type == 'video',
          height: int.tryParse(_attr(attrs, 'height') ?? '') ?? setHeight,
          bandwidth: int.tryParse(_attr(attrs, 'bandwidth') ?? ''),
          language: (lang == null || lang.isEmpty) ? null : lang,
        );
        (r.isVideo ? videos : audios).add(r);
      }
    }
    return DashManifest(
      videos: videos,
      audios: audios,
      duration: parseIsoDuration(
        _attr(mpd.group(1) ?? '', 'mediaPresentationDuration'),
      ),
    );
  }

  /// One attribute's value out of a tag's attribute text ('' quotes too).
  static String? _attr(String attrs, String name) {
    final m = RegExp(
      // Whitespace (or the start) before the name, so "id" never matches
      // inside "codecId"; value in double or single quotes.
      '(?:^|\\s)$name\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')',
    ).firstMatch(attrs);
    return m == null ? null : (m.group(1) ?? m.group(2));
  }

  /// 'video' / 'audio' from contentType or mimeType; null for anything else
  /// (subtitles, images) or when the tag does not say.
  static String? _kindOf(String attrs) {
    final content = (_attr(attrs, 'contentType') ?? '').toLowerCase();
    if (content == 'video' || content == 'audio') return content;
    final mime = (_attr(attrs, 'mimeType') ?? '').toLowerCase();
    if (mime.startsWith('video/')) return 'video';
    if (mime.startsWith('audio/')) return 'audio';
    return null;
  }

  /// ISO-8601 duration like `PT1H2M3.5S` (days allowed); null when invalid.
  static Duration? parseIsoDuration(String? raw) {
    final m = RegExp(
      r'^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$',
    ).firstMatch(raw?.trim() ?? '');
    if (m == null) return null;
    double part(int g) => double.tryParse(m.group(g) ?? '') ?? 0;
    final seconds = part(1) * 86400 + part(2) * 3600 + part(3) * 60 + part(4);
    if (seconds <= 0) return null;
    return Duration(milliseconds: (seconds * 1000).round());
  }
}

/// Downloads and reads the manifest at [url] with the stream's [headers].
/// Returns null on any network or parse failure; never throws.
Future<DashManifest?> fetchDashManifest(
  String url,
  Map<String, String>? headers, {
  Dio? dio,
}) async {
  final client =
      dio ??
      Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
  try {
    final res = await client
        .get<String>(
          url,
          options: Options(headers: headers, responseType: ResponseType.plain),
        )
        .timeout(const Duration(seconds: 30));
    final body = res.data;
    return body == null ? null : DashManifest.tryParse(body);
  } catch (_) {
    return null;
  } finally {
    // A client made here is ours to close; a passed-in one is the caller's.
    if (dio == null) client.close();
  }
}

/// Picture height a quality label asks for ("720p" -> 720); null for "best"
/// or a label that names no height.
int? dashWantedHeight(String quality) {
  if (quality == 'best') return null;
  final m = RegExp(r'(\d{3,4})').firstMatch(quality);
  return m == null ? null : int.tryParse(m.group(1)!);
}

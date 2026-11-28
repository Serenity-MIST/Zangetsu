import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/video_source.dart';
import '../playback/hls.dart' as hls;

/// Display-only approximation. Assumed bitrate estimates must not gate writes.
typedef DownloadSizeEstimate = ({int bytes, bool solid});

/// The downloader chooses the nearest available height, highest first on ties.
hls.HlsVariant? downloadEstimateVariant(
  List<hls.HlsVariant> variants,
  String quality,
) {
  if (variants.isEmpty) return null;
  final wanted = int.tryParse(
    RegExp(r'(\d{3,4})').firstMatch(quality)?.group(1) ?? '',
  );
  if (quality == 'best' || wanted == null) return variants.first;
  var pick = variants.first;
  var delta = 1 << 30;
  for (final v in variants) {
    final height =
        int.tryParse(
          RegExp(r'(\d{3,4})').firstMatch(v.quality)?.group(1) ?? '',
        ) ??
        0;
    final distance = (height - wanted).abs();
    if (distance < delta) {
      pick = v;
      delta = distance;
    }
  }
  return pick;
}

/// Playlist arithmetic never fetches media segments or fabricates an exact size.
DownloadSizeEstimate? estimateDownloadPlaylist(
  String body,
  String url, {
  required String quality,
  int? runtimeMinutes,
}) {
  if (!body.trimLeft().startsWith('#EXTM3U')) return null;
  hls.HlsVariant? variant;
  try {
    variant = downloadEstimateVariant(hls.parseHlsMaster(body, url), quality);
  } catch (_) {
    return null;
  }
  if (variant != null) {
    if (variant.bandwidth <= 0 || runtimeMinutes == null || runtimeMinutes <= 0)
      return null;
    final bytes = variant.bandwidth.toDouble() * runtimeMinutes * 60 / 8;
    if (!bytes.isFinite || bytes <= 0 || bytes > 9007199254740991) return null;
    return (bytes: bytes.round(), solid: true);
  }
  // A live sliding window cannot predict a completed offline video's size.
  if (!body.contains('#EXT-X-ENDLIST')) return null;
  var seconds = 0.0;
  for (final line in body.split('\n')) {
    if (!line.trim().startsWith('#EXTINF:')) continue;
    final n = double.tryParse(line.trim().substring(8).split(',').first);
    if (n == null || !n.isFinite || n <= 0) return null;
    seconds += n;
  }
  final height = int.tryParse(
    RegExp(r'(\d{3,4})p', caseSensitive: false).firstMatch(quality)?.group(1) ??
        '',
  );
  if (height == null || seconds <= 0 || !seconds.isFinite) return null;
  final bitrate = height >= 1080
      ? 8000000
      : height >= 720
      ? 4000000
      : height >= 480
      ? 2000000
      : 1000000;
  final bytes = bitrate * seconds / 8;
  if (!bytes.isFinite || bytes <= 0 || bytes > 9007199254740991) return null;
  return (bytes: bytes.round(), solid: false);
}

// ─────────────────────────────────────────────────────────────────────────────
// Download size estimates. Shown with a "~" and used only for display + the
// low-storage warning — never for decisions that must be exact. Anything
// unknowable returns null, and callers treat null as "no estimate", not zero.
//
// Direct files: HEAD content-length. HLS master playlists: variant bitrate ×
// episode runtime. DASH, media playlists and missing runtimes: null.
// ─────────────────────────────────────────────────────────────────────────────

/// One variant from an HLS master playlist. The playback `HlsVariant` class
/// is imported with the `hls` prefix above, so both names coexist here.
typedef HlsVariant = ({int bandwidth, int? height});

/// Variants listed in an HLS master playlist, fastest first. Media playlists
/// (no `#EXT-X-STREAM-INF`) yield nothing — their bitrate isn't stated.
List<HlsVariant> parseHlsVariants(String manifest) {
  final out = <HlsVariant>[];
  final lines = manifest.split('\n');
  for (final raw in lines) {
    final line = raw.trim();
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    final bw = RegExp(r'(?:^|[:,])BANDWIDTH=(\d+)').firstMatch(line);
    if (bw == null) continue;
    final res = RegExp(r'RESOLUTION=\d+x(\d+)').firstMatch(line);
    out.add((
      bandwidth: int.parse(bw.group(1)!),
      height: res == null ? null : int.tryParse(res.group(1)!),
    ));
  }
  out.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
  return out;
}

/// Height parsed from a quality label like "1080p" or "720p60", else null
/// (covers 'best'/'auto' and label-less sources).
int? qualityHeight(String? quality) {
  if (quality == null) return null;
  final m = RegExp(r'(\d{3,4})').firstMatch(quality);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// Total seconds stated by an HLS *media* playlist (EXTINF segments), or
/// null when the body isn't a media playlist at all. Guards the assumed-
/// bitrate fallback so an error page can never fabricate a size.
int? parseHlsMediaDurationSec(String manifest) {
  if (!manifest.contains('#EXTM3U') || !manifest.contains('#EXTINF')) {
    return null;
  }
  var total = 0.0;
  var found = false;
  for (final raw in manifest.split('\n')) {
    final m = RegExp(r'#EXTINF:([\d.]+)').firstMatch(raw.trim());
    if (m != null) {
      total += double.tryParse(m.group(1)!) ?? 0;
      found = true;
    }
  }
  return found && total > 0 ? total.round() : null;
}

/// Assumed bits-per-second per height, used ONLY for media playlists that
/// state no bitrate. Deliberately coarse — callers mark these low-confidence
/// (shown, but never trigger the storage warning).
int? assumedBitrateForHeight(int? height) => switch (height) {
  null => null,
  >= 1080 => 8000000,
  >= 720 => 4000000,
  >= 480 => 2000000,
  _ => 1000000,
};

/// Estimate + whether it's solid enough to warn on. Direct sizes and master-
/// playlist math are high confidence; assumed bitrates are not.
/// Upstream name for [DownloadSizeEstimate]; the record shapes are identical.
typedef SizeEstimate = DownloadSizeEstimate;

/// Bytes for one episode at the wanted variant, or null when unknowable.
/// Prefers the variant matching [wantedHeight]; otherwise the fastest.
int? hlsVariantBytes(
  List<HlsVariant> variants, {
  int? wantedHeight,
  required int runtimeSec,
}) {
  if (variants.isEmpty || runtimeSec <= 0) return null;
  var pick = variants.first;
  if (wantedHeight != null) {
    for (final v in variants) {
      if (v.height == wantedHeight) {
        pick = v;
        break;
      }
    }
  }
  return pick.bandwidth ~/ 8 * runtimeSec;
}

/// Upstream spelling of [formatDownloadEstimate]; both callers share one
/// formatter so the "~" display stays identical across platforms.
String formatApproxBytes(int bytes) => formatDownloadEstimate(bytes);

/// Human-readable approximation; unknown is represented by null, never zero.
String formatDownloadEstimate(int bytes) {
  if (bytes >= 1 << 30) return '~${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '~${(bytes / (1 << 20)).toStringAsFixed(0)} MB';
  if (bytes >= 1 << 10) return '~${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
  return '~$bytes B';
}

/// One selected-source probe with bounded redirects/body/time and shared host
/// cooldown admission. Disposing the preview aborts requests and hides results.
class DownloadSizeEstimator {
  DownloadSizeEstimator({
    required this.cooldownUntil,
    required this.onRateLimited,
    this.timeout = const Duration(seconds: 8),
    this.maxPlaylistBytes = 256 * 1024,
  });
  final DateTime? Function(Uri) cooldownUntil;
  final Future<void> Function(Uri, String?) onRateLimited;
  final Duration timeout;
  final int maxPlaylistBytes;
  bool _disposed = false;
  final Set<HttpClient> _clients = {};

  /// Only HTTP metadata/playlists: no HEAD-to-GET fallback for direct files.
  Future<DownloadSizeEstimate?> estimate(
    VideoSource source, {
    int? runtimeMinutes,
    String? quality,
  }) async {
    final uri = Uri.tryParse(source.url.trim());
    if (_disposed ||
        uri == null ||
        !_http(uri) ||
        source.container == SourceContainer.torrent ||
        uri.path.toLowerCase().endsWith('.mpd'))
      return null;
    final client = HttpClient()..connectionTimeout = timeout;
    _clients.add(client);
    try {
      return await _probe(
        client,
        source,
        uri,
        runtimeMinutes,
        quality ?? source.quality ?? 'best',
      ).timeout(timeout);
    } catch (_) {
      return null;
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  /// Explicit redirects check every destination before opening a connection.
  Future<DownloadSizeEstimate?> _probe(
    HttpClient client,
    VideoSource source,
    Uri initial,
    int? runtimeMinutes,
    String quality,
  ) async {
    var uri = initial;
    final headers = Map<String, String>.from(source.headers ?? const {});
    headers.removeWhere(
      (key, _) =>
          const ['range', 'host', 'content-length'].contains(key.toLowerCase()),
    );
    final hls =
        source.container == SourceContainer.hls ||
        uri.path.toLowerCase().endsWith('.m3u8');
    for (var redirects = 0; redirects <= 3; redirects++) {
      if (_disposed || !_http(uri) || cooldownUntil(uri) != null) return null;
      final request = await client.openUrl(hls ? 'GET' : 'HEAD', uri);
      if (_disposed) {
        request.abort();
        return null;
      }
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();
      if (response.statusCode == 429) {
        final retryAfter = response.headers.value('retry-after');
        await response.listen((_) {}).cancel();
        await onRateLimited(uri, retryAfter);
        return null;
      }
      if (const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.listen((_) {}).cancel();
        if (location == null || redirects == 3) return null;
        final next = uri.resolve(location);
        if (!_http(next) || (uri.scheme == 'https' && next.scheme != 'https'))
          return null;
        if (next.host != uri.host ||
            next.port != uri.port ||
            next.scheme != uri.scheme) {
          headers.removeWhere(
            (key, _) => const [
              'authorization',
              'cookie',
              'proxy-authorization',
            ].contains(key.toLowerCase()),
          );
        }
        uri = next;
        continue;
      }
      if (response.statusCode != 200 || _disposed) {
        await response.listen((_) {}).cancel();
        return null;
      }
      if (!hls) {
        final length = response.contentLength;
        final type = response.headers.contentType?.mimeType.toLowerCase();
        await response.listen((_) {}).cancel();
        if (type == 'text/html' || type == 'application/json') return null;
        return length > 0 && !_disposed ? (bytes: length, solid: true) : null;
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        if (_disposed || bytes.length + chunk.length > maxPlaylistBytes)
          return null;
        bytes.addAll(chunk);
      }
      if (_disposed) return null;
      return estimateDownloadPlaylist(
        utf8.decode(bytes),
        uri.toString(),
        quality: quality,
        runtimeMinutes: runtimeMinutes,
      );
    }
    return null;
  }

  /// A preview may be abandoned while its server is still sending headers.
  void dispose() {
    _disposed = true;
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
  }

  static bool _http(Uri uri) =>
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

/// Estimated bytes of ONE episode from [source], plus whether the number is
/// solid enough to warn on. Null when unknowable — callers hide the estimate
/// and skip the storage warning rather than guess.
Future<SizeEstimate?> estimateEpisodeBytes(
  VideoSource source, {
  int? runtimeMinutes,
  HttpClient? client,
}) async {
  final url = source.url.trim();
  if (url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return null;
  if (url.contains('.mpd')) {
    return null; // DASH sizes aren't cheap to derive
  }
  final isHls =
      source.container == SourceContainer.hls || url.contains('.m3u8');
  final owned = client == null;
  final http = client ?? HttpClient();
  http.connectionTimeout = const Duration(seconds: 8);
  try {
    final headers = source.headers ?? const <String, String>{};
    if (!isHls) {
      final req = await http.openUrl('HEAD', uri);
      headers.forEach(req.headers.set);
      final res = await req.close().timeout(const Duration(seconds: 8));
      await res.drain<void>().timeout(const Duration(seconds: 8));
      if (res.statusCode != HttpStatus.ok) return null;
      final len = res.contentLength;
      return len > 0 ? (bytes: len, solid: true) : null;
    }
    final req = await http.getUrl(uri);
    headers.forEach(req.headers.set);
    final res = await req.close().timeout(const Duration(seconds: 10));
    if (res.statusCode < 200 || res.statusCode >= 400) return null;
    final bytes = await res
        .fold<List<int>>(<int>[], (buffer, chunk) {
          if (buffer.length + chunk.length > 1024 * 1024) {
            throw const FormatException(
              'Playlist too large for a size estimate',
            );
          }
          return buffer..addAll(chunk);
        })
        .timeout(const Duration(seconds: 10));
    final body = utf8.decode(bytes);
    final runtimeSec = (runtimeMinutes ?? 0) * 60;
    final fromVariants = hlsVariantBytes(
      parseHlsVariants(body),
      wantedHeight: qualityHeight(source.quality),
      runtimeSec: runtimeSec,
    );
    if (fromVariants != null) return (bytes: fromVariants, solid: true);
    // Media playlist: durations are stated, bitrate isn't — assume one for
    // the quality and mark it low-confidence (shown, never warns).
    final mediaSec = parseHlsMediaDurationSec(body);
    final assumed = assumedBitrateForHeight(qualityHeight(source.quality));
    if (mediaSec == null || assumed == null) return null;
    return (bytes: assumed ~/ 8 * mediaSec, solid: false);
  } catch (_) {
    return null;
  } finally {
    if (owned) http.close(force: true);
  }
}

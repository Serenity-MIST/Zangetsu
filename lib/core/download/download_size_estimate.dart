import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/video_source.dart';
import '../playback/hls.dart';

/// Display-only approximation. Assumed bitrate estimates must not gate writes.
typedef DownloadSizeEstimate = ({int bytes, bool solid});

/// The downloader chooses the nearest available height, highest first on ties.
HlsVariant? downloadEstimateVariant(List<HlsVariant> variants, String quality) {
  if (variants.isEmpty) return null;
  final wanted = int.tryParse(RegExp(r'(\d{3,4})').firstMatch(quality)?.group(1) ?? '');
  if (quality == 'best' || wanted == null) return variants.first;
  var pick = variants.first;
  var delta = 1 << 30;
  for (final v in variants) {
    final height = int.tryParse(RegExp(r'(\d{3,4})').firstMatch(v.quality)?.group(1) ?? '') ?? 0;
    final distance = (height - wanted).abs();
    if (distance < delta) { pick = v; delta = distance; }
  }
  return pick;
}

/// Playlist arithmetic never fetches media segments or fabricates an exact size.
DownloadSizeEstimate? estimateDownloadPlaylist(String body, String url, {
  required String quality, int? runtimeMinutes,
}) {
  if (!body.trimLeft().startsWith('#EXTM3U')) return null;
  HlsVariant? variant;
  try { variant = downloadEstimateVariant(parseHlsMaster(body, url), quality); }
  catch (_) { return null; }
  if (variant != null) {
    if (variant.bandwidth <= 0 || runtimeMinutes == null || runtimeMinutes <= 0) return null;
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
  final height = int.tryParse(RegExp(r'(\d{3,4})p', caseSensitive: false)
      .firstMatch(quality)?.group(1) ?? '');
  if (height == null || seconds <= 0 || !seconds.isFinite) return null;
  final bitrate = height >= 1080 ? 8000000 : height >= 720 ? 4000000 : height >= 480 ? 2000000 : 1000000;
  final bytes = bitrate * seconds / 8;
  if (!bytes.isFinite || bytes <= 0 || bytes > 9007199254740991) return null;
  return (bytes: bytes.round(), solid: false);
}

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
  DownloadSizeEstimator({required this.cooldownUntil, required this.onRateLimited,
    this.timeout = const Duration(seconds: 8), this.maxPlaylistBytes = 256 * 1024});
  final DateTime? Function(Uri) cooldownUntil;
  final Future<void> Function(Uri, String?) onRateLimited;
  final Duration timeout;
  final int maxPlaylistBytes;
  bool _disposed = false;
  final Set<HttpClient> _clients = {};

  /// Only HTTP metadata/playlists: no HEAD-to-GET fallback for direct files.
  Future<DownloadSizeEstimate?> estimate(VideoSource source, {
    int? runtimeMinutes, String? quality,
  }) async {
    final uri = Uri.tryParse(source.url.trim());
    if (_disposed || uri == null || !_http(uri) || source.container == SourceContainer.torrent ||
        uri.path.toLowerCase().endsWith('.mpd')) return null;
    final client = HttpClient()..connectionTimeout = timeout;
    _clients.add(client);
    try {
      return await _probe(client, source, uri, runtimeMinutes, quality ?? source.quality ?? 'best')
          .timeout(timeout);
    } catch (_) {
      return null;
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  /// Explicit redirects check every destination before opening a connection.
  Future<DownloadSizeEstimate?> _probe(HttpClient client, VideoSource source,
      Uri initial, int? runtimeMinutes, String quality) async {
    var uri = initial;
    final headers = Map<String, String>.from(source.headers ?? const {});
    headers.removeWhere((key, _) => const ['range', 'host', 'content-length']
        .contains(key.toLowerCase()));
    final hls = source.container == SourceContainer.hls || uri.path.toLowerCase().endsWith('.m3u8');
    for (var redirects = 0; redirects <= 3; redirects++) {
      if (_disposed || !_http(uri) || cooldownUntil(uri) != null) return null;
      final request = await client.openUrl(hls ? 'GET' : 'HEAD', uri);
      if (_disposed) { request.abort(); return null; }
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
        if (!_http(next) || (uri.scheme == 'https' && next.scheme != 'https')) return null;
        if (next.host != uri.host || next.port != uri.port || next.scheme != uri.scheme) {
          headers.removeWhere((key, _) => const ['authorization', 'cookie', 'proxy-authorization']
              .contains(key.toLowerCase()));
        }
        uri = next;
        continue;
      }
      if (response.statusCode != 200 || _disposed) {
        await response.listen((_) {}).cancel(); return null;
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
        if (_disposed || bytes.length + chunk.length > maxPlaylistBytes) return null;
        bytes.addAll(chunk);
      }
      if (_disposed) return null;
      return estimateDownloadPlaylist(utf8.decode(bytes), uri.toString(),
          quality: quality, runtimeMinutes: runtimeMinutes);
    }
    return null;
  }

  /// A preview may be abandoned while its server is still sending headers.
  void dispose() {
    _disposed = true;
    for (final client in _clients) { client.close(force: true); }
    _clients.clear();
  }

  static bool _http(Uri uri) => (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty && uri.userInfo.isEmpty;
}

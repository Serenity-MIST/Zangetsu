import 'package:flutter/services.dart';

enum TorrentState { finding, buffering, ready, error }

String torrentFailureMessage(String? reason) {
  if (reason == 'wifi_only') {
    return 'Torrents are set to Wi-Fi only. Turn on mobile data for torrents '
        'in Settings › Torrents.';
  }
  if (reason == 'no_metadata') {
    return 'No peers responded to this torrent. Try another source.';
  }
  if (reason == 'no_handle') {
    return 'Couldn’t connect to this torrent. Try another source.';
  }
  if (reason == 'no_video_in_torrent') {
    return 'This torrent has no supported video file. Try another source.';
  }
  return 'Couldn’t stream this torrent. It may have no active peers or may '
      'have timed out. Try another source.';
}

class TorrentProgress {
  const TorrentProgress({
    required this.id,
    required this.state,
    required this.bufferPct,
    required this.peers,
    required this.downSpeedBps,
    this.error,
  });
  final String id;
  final TorrentState state;
  final double bufferPct;
  final int peers;
  final int downSpeedBps;
  final String? error;

  static TorrentProgress fromMap(Map<dynamic, dynamic> m) => TorrentProgress(
        id: (m['id'] ?? '') as String,
        state: _stateFrom(m['state'] as String?),
        bufferPct: ((m['bufferPct'] ?? 0) as num).toDouble(),
        peers: ((m['peers'] ?? 0) as num).toInt(),
        downSpeedBps: ((m['downSpeedBps'] ?? 0) as num).toInt(),
        error: m['error'] as String?,
      );

  static TorrentState _stateFrom(String? s) => switch (s) {
        'finding' => TorrentState.finding,
        'buffering' => TorrentState.buffering,
        'ready' => TorrentState.ready,
        'error' => TorrentState.error,
        _ => TorrentState.finding,
      };
}

class TorrentService {
  static const MethodChannel _method =
      MethodChannel('com.spyou.watch_app/torrent');
  static const EventChannel _events =
      EventChannel('com.spyou.watch_app/torrent/events');

  /// Starts streaming a magnet/.torrent; returns the torrent id + a local URL
  /// the player can open. Throws on Wi-Fi block (a `wifi_only` PlatformException
  /// when metered + [allowMobileData] is false), no-metadata, or engine error.
  Future<({String id, String localUrl})> startStream(
    String uri, {
    bool allowMobileData = false,
  }) async {
    final res = await _method.invokeMapMethod<String, dynamic>(
      'startStream',
      {'uri': uri, 'allowMobileData': allowMobileData},
    );
    return (
      id: (res?['id'] ?? '') as String,
      localUrl: (res?['localUrl'] ?? '') as String,
    );
  }

  Stream<TorrentProgress> events() => _events
      .receiveBroadcastStream()
      .map((e) => TorrentProgress.fromMap(e as Map));

  Future<void> stop(String id) =>
      _method.invokeMethod('stopStream', {'id': id});
}

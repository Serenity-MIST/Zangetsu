import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/source_selection.dart';

/// A desktop catalogue may return torrent mirrors alongside playable HTTP.
void main() {
  final torrent = VideoSource(url: 'magnet:?xt=urn:btih:fixture', quality: '2160p');
  final direct = VideoSource(url: 'https://source.example/video.mp4', quality: '1080p');
  test('desktop prefers direct video over an unsupported higher-quality magnet', () {
    expect(pickDefault([torrent, direct], torrentsSupported: false), direct);
  });
  test('Android retains torrent quality selection', () {
    expect(pickDefault([torrent, direct], torrentsSupported: true), torrent);
  });
  test('torrent-only results remain selectable for a clear capability error', () {
    expect(pickDefault([torrent], torrentsSupported: false), torrent);
  });
}

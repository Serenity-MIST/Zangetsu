import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/hls_downloader.dart';
import 'package:watch_app/core/download/subtitle_selection.dart';
import 'package:watch_app/core/models/video_source.dart';

class _HlsResponses implements HttpClientAdapter {
  final requested = <String>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream, Future<void>? cancel) async {
    requested.add(options.uri.path);
    final text = switch (options.uri.path) {
      '/master.m3u8' => '#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,NAME="Spanish",LANGUAGE="es",URI="es.m3u8"\n#EXT-X-MEDIA:TYPE=SUBTITLES,NAME="English",LANGUAGE="eng",URI="en.m3u8"\n#EXT-X-MEDIA:TYPE=SUBTITLES,NAME="English SDH",LANGUAGE="en",URI="sdh.m3u8"',
      '/en.m3u8' => '#EXTM3U\n#EXTINF:5,\nen.vtt\n#EXT-X-ENDLIST',
      '/en.vtt' => 'WEBVTT\n\n00:00:00.000 --> 00:00:04.000\nHello\n',
      _ => throw StateError('Unexpected subtitle request: ${options.uri.path}'),
    };
    return ResponseBody.fromString(text, 200);
  }
  @override
  void close({bool force = false}) {}
}

void main() {
  List<Subtitle> select(List<Subtitle> tracks, String pref) => downloadSubtitleSelection(tracks, pref,
    language: (track) => track.lang, label: (track) => track.label ?? '');
  const tracks = [
    Subtitle(url: 'forced', lang: 'eng', label: 'English forced'),
    Subtitle(url: 'full', lang: 'en-US', label: 'English'),
    Subtitle(url: 'spanish', lang: 'Spanish'),
    Subtitle(url: 'duplicate', lang: 'English SDH'),
  ];
  test('one complete track, matching ISO aliases and region tags', () {
    expect(select(tracks, 'en').single.url, 'full');
    expect(select(tracks, 'es').single.url, 'spanish');
  });
  test('off and unavailable language never download another language', () {
    expect(select(tracks, 'off'), isEmpty);
    expect(select(tracks, 'ja'), isEmpty);
  });
  test('HLS selection happens before rendition and segment requests', () async {
    final adapter = _HlsResponses();
    final downloader = HlsDownloader(Dio()..httpClientAdapter = adapter);
    final subs = await downloader.fetchSubtitleTracks('https://test.example/master.m3u8', {}, preferredLanguage: 'en');
    expect(subs, hasLength(1));
    expect(subs.single.vtt, contains('Hello'));
    expect(adapter.requested, ['/master.m3u8', '/en.m3u8', '/en.vtt']);
  });
}

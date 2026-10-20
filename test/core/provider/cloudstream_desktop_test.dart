import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/cloudstream_catalog.dart';
import 'package:watch_app/core/desktop/cloudstream_runtime.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';

class _Responses implements HttpClientAdapter {
  _Responses(this.responses);
  final Map<String, Object> responses;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async => ResponseBody.fromString(
    jsonEncode(responses[options.uri.toString()]),
    200,
  );
  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'arbitrary repositories resolve relative lists and plugin files, keeping newest version',
    () async {
      final dio = Dio()
        ..httpClientAdapter = _Responses({
          'https://repo.example/builds/repo.json': {
            'name': 'Custom',
            'pluginLists': ['one.json', 'nested/two.json'],
          },
          'https://repo.example/builds/one.json': [
            {'internalName': 'Example', 'version': 2, 'url': 'Example.cs3'},
          ],
          'https://repo.example/builds/nested/two.json': [
            {'internalName': 'Example', 'version': 3, 'url': '../New.cs3'},
          ],
        });
      final repo = await CloudStreamCatalog(
        client: dio,
      ).fetch('cloudstreamrepo://repo.example/builds/repo.json');
      expect(repo['name'], 'Custom');
      expect(repo['plugins'], [
        containsPair('url', 'https://repo.example/builds/New.cs3'),
      ]);
      expect(repo['plugins'][0]['version'], 3);
    },
  );
  test('rejects pages without a repository manifest', () async {
    final dio = Dio()
      ..httpClientAdapter = _Responses({
        'https://repo.example/': {'name': 'Not a repo'},
      });
    await expectLater(
      CloudStreamCatalog(client: dio).fetch('https://repo.example/'),
      throwsFormatException,
    );
  });
  test('rejects local file URLs supplied by repository lists', () async {
    final dio = Dio()
      ..httpClientAdapter = _Responses({
        'https://repo.example/': {
          'pluginLists': ['file:///C:/private'],
        },
      });
    await expectLater(
      CloudStreamCatalog(client: dio).fetch('https://repo.example/'),
      throwsFormatException,
    );
  });
  test('sub and dub episode payloads stay separate', () {
    final result = {
      'episodes': [
        {'data': 'sub', 'dub': 'Subbed'},
        {'data': 'dub', 'dub': 'Dubbed'},
      ],
      'syncIds': {'mal': '42'},
    };
    final detail = adaptCloudStreamDetail(result, 'dub');
    expect(detail['episodes'], [
      {'data': 'dub', 'dub': 'Dubbed'},
    ]);
    expect(detail['subCount'], 1);
    expect(detail['dubCount'], 1);
    expect(detail['syncData'], {'mal': '42'});
  });
  test('movies expose their opaque data payload as a playable episode', () {
    expect(
      adaptCloudStreamDetail({
        'name': 'Movie',
        'dataUrl': '{"id":1}',
      }, 'sub')['episodes'],
      [
        {'name': 'Movie', 'episode': 1, 'data': '{"id":1}'},
      ],
    );
  });
  test('streams retain subtitles, headers, quality and HLS identity', () {
    final mapped = adaptCloudStreamLinks({
      'links': [
        {
          'name': 'Server',
          'url': 'https://video.example/a.m3u8',
          'type': 'M3U8',
          'quality': 1080,
          'headers': {'Authorization': 'example'},
          'referer': 'https://site.example/',
        },
      ],
      'subtitles': [
        {'lang': 'English', 'url': 'https://video.example/sub.vtt'},
      ],
    });
    final sources = CloudStreamProvider(
      name: 'Example',
      lang: 'en',
      types: ['Movie'],
    ).sourcesFromResult(mapped);
    expect(sources.single.url, 'https://video.example/a.m3u8');
    expect(mapped['sources'][0]['isM3u8'], true);
    expect(mapped['sources'][0]['headers']['Authorization'], 'example');
    expect(mapped['subtitles'], hasLength(1));
  });
  test(
    'same extension from different repositories has a different namespace',
    () {
      expect(
        DesktopCloudStream.repoTag('https://one.example/repo.json'),
        isNot(DesktopCloudStream.repoTag('https://two.example/repo.json')),
      );
    },
  );
}

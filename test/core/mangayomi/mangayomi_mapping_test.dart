import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mangayomi/mangayomi_provider.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:zangetsu_source_bridge/zangetsu_source_bridge.dart';

void main() {
  final source = MangayomiSource(
    repository: Uri.parse('https://repo.example.com/index.json'),
    key: 'mg:repo:1:1:1066185420',
    id: 1066185420,
    name: 'Torrentio',
    baseUrl: Uri.parse('https://torrentio.strem.fun'),
    codeUrl: Uri.parse('https://repo.example.com/torrentio.js'),
    version: '0.0.26',
    contentType: MangayomiContentType.video,
    codeLanguage: MangayomiCodeLanguage.javascript,
    language: 'all',
  );

  test('keeps extension-owned ids and paths opaque', () {
    final item = MangayomiMapping.item(
      source,
      MManga(name: 'Example', link: 'tt123,series', imageUrl: '/poster.jpg'),
      ProviderType.anime,
    );
    expect(item.id, 'tt123,series');
    expect(item.url, 'tt123,series');
    expect(item.cover, 'https://torrentio.strem.fun/poster.jpg');

    final episodes = MangayomiMapping.episodes(source, [
      MChapter(
        name: 'Episode 1',
        url: '/stream/series/tt123:1:1.json',
        thumbnailUrl: '/thumb.jpg',
      ),
    ]);
    expect(episodes.single.id, '/stream/series/tt123:1:1.json');
    expect(episodes.single.url, '/stream/series/tt123:1:1.json');
    expect(episodes.single.thumbnail, 'https://torrentio.strem.fun/thumb.jpg');

    final video = MangayomiMapping.video(
      source,
      MVideo(
        'magnet:?xt=urn:btih:abc',
        '1080p',
        'magnet:?xt=urn:btih:abc',
        subtitles: [Track(file: '/subs/en.vtt', label: 'English')],
      ),
    );
    expect(video.url, 'magnet:?xt=urn:btih:abc');
    expect(video.container, SourceContainer.torrent);
    expect(
      video.subtitles.single.url,
      'https://torrentio.strem.fun/subs/en.vtt',
    );
  });

  test('still resolves reader page images against the source base URL', () {
    final page = MangayomiMapping.page(source, MPage('/pages/1.jpg'));
    expect(page.url, 'https://torrentio.strem.fun/pages/1.jpg');
  });
}

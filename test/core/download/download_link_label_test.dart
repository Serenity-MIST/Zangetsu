import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_link_label.dart';
import 'package:watch_app/core/download/download_server_preference.dart';
import 'package:watch_app/core/models/video_source.dart';

// Anikoto-shaped links: no label, the server name lives in `quality`, all on
// one CDN host, SUB and DUB for the same episode.
const subHd = VideoSource(
  url: 'https://cdn.test/s-hd1.m3u8',
  quality: 'HD - 1 - 1080p',
  kind: AudioKind.sub,
);
const subVs2 = VideoSource(
  url: 'https://cdn.test/s-vs2.m3u8',
  quality: 'Vidstream - 2 - 1080p',
  kind: AudioKind.sub,
);
const subVs1 = VideoSource(
  url: 'https://cdn.test/s-vs1.m3u8',
  quality: 'Vidstream - 1 - 1080p',
  kind: AudioKind.sub,
);
const dubHd = VideoSource(
  url: 'https://cdn.test/d-hd1.m3u8',
  quality: 'HD - 1 - 1080p',
  kind: AudioKind.dub,
);
const dubVs2 = VideoSource(
  url: 'https://cdn.test/d-vs2.m3u8',
  quality: 'Vidstream - 2 - 1080p',
  kind: AudioKind.dub,
);

void main() {
  group('downloadLinkLabel (player labelling)', () {
    test('quality-only links get the SUB/DUB prefix', () {
      expect(downloadLinkLabel(subHd), 'SUB • HD - 1 - 1080p');
      expect(downloadLinkLabel(dubVs2), 'DUB • Vidstream - 2 - 1080p');
    });
    test('unknown kind has no prefix; container fills a missing quality', () {
      expect(
        downloadLinkLabel(
          const VideoSource(url: 'https://x.test/a', quality: '720p'),
        ),
        '720p',
      );
      expect(
        downloadLinkLabel(
          const VideoSource(
            url: 'https://x.test/a',
            container: SourceContainer.hls,
          ),
        ),
        'hls',
      );
    });
    test(
      'labelled links append quality unless already in the label or auto',
      () {
        expect(
          downloadLinkLabel(
            const VideoSource(
              url: 'https://x.test/a',
              label: 'FSL Server',
              quality: '1080p',
              kind: AudioKind.dub,
            ),
          ),
          'DUB • FSL Server · 1080p',
        );
        expect(
          downloadLinkLabel(
            const VideoSource(
              url: 'https://x.test/a',
              label: 'Mirror 1080p',
              quality: '1080p',
            ),
          ),
          'Mirror 1080p',
        );
        expect(
          downloadLinkLabel(
            const VideoSource(
              url: 'https://x.test/a',
              label: 'Mirror',
              quality: 'auto',
            ),
          ),
          'Mirror',
        );
      },
    );
  });

  group('downloadServerName / key', () {
    test('strips the resolution from a quality-carried server name', () {
      expect(downloadServerName(subHd), 'HD - 1');
      expect(downloadServerName(subVs2), 'Vidstream - 2');
      expect(
        downloadServerName(
          const VideoSource(url: 'https://x.test/a', quality: '1080p'),
        ),
        '',
      );
      expect(
        downloadServerName(
          const VideoSource(
            url: 'https://x.test/a',
            label: ' Mirror B ',
            quality: '720p',
          ),
        ),
        'Mirror B',
      );
    });
    test('SUB and DUB of one server, and servers on one host, stay apart', () {
      final keys = {
        for (final s in [subHd, subVs2, subVs1, dubHd, dubVs2])
          downloadServerKey(s),
      };
      expect(keys, hasLength(5));
      expect(downloadServerLabel(dubHd), 'DUB • HD - 1');
      expect(
        downloadServerLabel(const VideoSource(url: 'https://www.cdn.test/a')),
        'cdn.test',
      );
    });
    test('category follows the link kind', () {
      expect(downloadCategoryForKind(AudioKind.sub), 'sub');
      expect(downloadCategoryForKind(AudioKind.dub), 'dub');
      expect(downloadCategoryForKind(AudioKind.unknown), isNull);
    });
    test('orders like the player with the preferred kind first', () {
      const sub720 = VideoSource(
        url: 'https://cdn.test/s720',
        quality: '720p',
        kind: AudioKind.sub,
      );
      const sub1080 = VideoSource(
        url: 'https://cdn.test/s1080',
        quality: '1080p',
        kind: AudioKind.sub,
      );
      const dub1080 = VideoSource(
        url: 'https://cdn.test/d1080',
        quality: '1080p',
        kind: AudioKind.dub,
      );
      expect(orderDownloadLinks([sub720, dub1080, sub1080], 'sub'), [
        sub1080,
        sub720,
        dub1080,
      ]);
      expect(orderDownloadLinks([sub720, dub1080, sub1080], 'dub'), [
        dub1080,
        sub1080,
        sub720,
      ]);
    });
    test('drops links no download category can take (RAW beside SUB/DUB)', () {
      const sub1080 = VideoSource(
        url: 'https://cdn.test/s1080',
        quality: '1080p',
        kind: AudioKind.sub,
      );
      const raw1080 = VideoSource(
        url: 'https://cdn.test/r1080',
        quality: '1080p',
        kind: AudioKind.raw,
      );
      const bare = VideoSource(url: 'https://cdn.test/u1080', quality: '1080p');
      expect(orderDownloadLinks([raw1080, sub1080, bare], 'sub'), [sub1080]);
      // A source that labels nothing keeps every link.
      expect(orderDownloadLinks([bare], 'sub'), [bare]);
    });
  });

  group('DownloadServerPreference.prioritize (server + SUB/DUB mapping)', () {
    final mixed = [subHd, subVs2, subVs1, dubHd, dubVs2];

    test('a DUB HD-1 pick ranks DUB HD-1 first and never offers SUB', () {
      final pref = DownloadServerPreference.fromSource(dubHd);
      expect(pref.audioKind, 'dub');
      expect(pref.label, 'HD - 1');
      expect(pref.prioritize(mixed), [dubHd, dubVs2]);
    });
    test('a SUB Vidstream-1 pick beats HD-1 on the same host', () {
      final pref = DownloadServerPreference.fromSource(subVs1);
      expect(pref.prioritize(mixed).first, subVs1);
      expect(
        pref.prioritize(mixed).every((s) => s.kind == AudioKind.sub),
        isTrue,
      );
    });
    test('missing server falls back to the same kind, other servers', () {
      final pref = DownloadServerPreference.fromSource(dubHd);
      expect(pref.prioritize([subHd, dubVs2]), [dubVs2]);
    });
    test(
      'an exact (hand-picked) server keeps only its own links while they exist',
      () {
        final pref = DownloadServerPreference.fromSource(subVs1, exact: true);
        const vs1Low = VideoSource(
          url: 'https://cdn.test/s-vs1-720.m3u8',
          quality: 'Vidstream - 1 - 720p',
          kind: AudioKind.sub,
        );
        expect(pref.prioritize([subHd, vs1Low, subVs1]), [vs1Low, subVs1]);
        // Server gone on a later re-resolve: same kind only, never DUB.
        expect(pref.prioritize([dubHd, subHd]), [subHd]);
      },
    );
    test('fresh episode links keep the pick by name even on a new host', () {
      final pref = DownloadServerPreference.fromSource(dubVs2);
      const moved = VideoSource(
        url: 'https://other.test/d-vs2.m3u8',
        quality: 'Vidstream - 2 - 1080p',
        kind: AudioKind.dub,
      );
      expect(pref.prioritize([dubHd, moved]).first, moved);
    });
    test('audioKind and exact survive persistence; legacy maps still load', () {
      final saved = DownloadServerPreference.fromMap(
        DownloadServerPreference.fromSource(dubHd, exact: true).toMap(),
      );
      expect(saved.audioKind, 'dub');
      expect(saved.exact, isTrue);
      expect(saved.label, 'HD - 1');
      final legacy = DownloadServerPreference.fromMap(const {
        'label': '',
        'host': 'cdn.test',
        'audioLanguage': null,
      });
      expect(legacy.audioKind, isNull);
      expect(legacy.exact, isFalse);
      // No kind recorded: both kinds stay eligible, as before.
      expect(legacy.prioritize(mixed), mixed);
      expect(
        DownloadServerPreference.fromSource(
          const VideoSource(url: 'https://x.test/a'),
        ).toMap().containsKey('audioKind'),
        isFalse,
      );
    });
  });
}

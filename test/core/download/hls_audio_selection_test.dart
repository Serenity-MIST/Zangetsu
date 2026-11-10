import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/hls_audio_selection.dart';
import 'package:watch_app/core/playback/hls.dart';

const master = '''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="main",NAME="Japanese",LANGUAGE="ja",DEFAULT=YES,URI="jp/index.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="main",NAME="English",LANGUAGE="eng",DEFAULT=NO,URI="en/index.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="other",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="wrong/index.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720,AUDIO="main"
video/index.m3u8
''';
void main() {
  const url = 'https://fixture.test/show/master.m3u8';
  test('English overrides Japanese default and keeps selected video group', () {
    final variant = parseHlsMaster(master, url).single;
    expect(variant.audioGroup, 'main');
    final audio = selectDownloadAudio(
      master,
      url,
      variant,
      preferredLanguage: 'en',
    )!;
    expect(audio.uri, 'https://fixture.test/show/en/index.m3u8');
    expect(audio.groupId, 'main');
    expect(audio.lang, 'eng');
  });
  test('unset language retains source default; unavailable language fails', () {
    final variant = parseHlsMaster(master, url).single;
    expect(selectDownloadAudio(master, url, variant)!.lang, 'ja');
    expect(
      () => selectDownloadAudio(master, url, variant, preferredLanguage: 'hi'),
      throwsA(isA<HlsAudioSelectionException>()),
    );
  });
  test(
    'English in unrelated group cannot replace missing selected-group English',
    () {
      final japaneseOnly = master
          .split(String.fromCharCode(10))
          .where(
            (line) =>
                !(line.contains('GROUP-ID="main"') &&
                    line.contains('LANGUAGE="eng"')),
          )
          .join(String.fromCharCode(10));
      final variant = parseHlsMaster(japaneseOnly, url).single;
      expect(
        () => selectDownloadAudio(
          japaneseOnly,
          url,
          variant,
          preferredLanguage: 'en',
        ),
        throwsA(isA<HlsAudioSelectionException>()),
      );
    },
  );
  test('video with no audio group does not attach unrelated renditions', () {
    final variant = HlsVariant(
      quality: '720p',
      url: 'https://fixture.test/video',
    );
    expect(
      selectDownloadAudio(master, url, variant, preferredLanguage: 'en'),
      isNull,
    );
  });
}

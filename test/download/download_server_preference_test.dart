import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/download/download_server_preference.dart';
import 'package:watch_app/core/models/video_source.dart';

void main() {
  test(
    'explicit English audio survives persistence and rejects Japanese/unknown mirrors',
    () {
      final preference = DownloadServerPreference.fromSource(
        const VideoSource(
          url: 'https://b.test/preview',
          label: 'B',
          audioLang: 'English',
        ),
      );
      final saved = DownloadServerPreference.fromMap(preference.toMap());
      expect(saved.audioLanguage, 'en');
      final candidates = const [
        VideoSource(url: 'https://b.test/jp', label: 'B', audioLang: 'jpn'),
        VideoSource(url: 'https://b.test/unknown', label: 'B'),
        VideoSource(url: 'https://c.test/en', label: 'C', audioLang: 'eng'),
      ];
      expect(saved.prioritize(candidates), [candidates.last]);
    },
  );
  test(
    'multi-audio metadata is not mistaken for one explicitly selected language',
    () {
      for (final value in ['multi', 'und', 'English Japanese']) {
        final preference = DownloadServerPreference.fromSource(
          VideoSource(url: 'https://fixture.test/file', audioLang: value),
        );
        expect(preference.audioLanguage, isNull);
      }
    },
  );

  test(
    'fresh episode links prefer selected label even when order/host changes',
    () {
      final preference = DownloadServerPreference.fromSource(
        const VideoSource(
          url: 'https://old.test/episode1?token=private',
          label: 'Mirror B',
        ),
      );
      final sources = [
        const VideoSource(url: 'https://a.test/episode2', label: 'Mirror A'),
        const VideoSource(
          url: 'https://new.test/episode2?token=fresh',
          label: 'Mirror B',
        ),
      ];
      expect(preference.prioritize(sources).first, sources.last);
      expect(preference.toMap().toString(), isNot(contains('token')));
      expect(preference.toMap().toString(), isNot(contains('episode1')));
    },
  );
  test('host fallback preserves quality order and alternate mirrors', () {
    const preference = DownloadServerPreference(label: '', host: 'b.test');
    final sources = [
      const VideoSource(url: 'https://a.test/2', quality: '1080p'),
      const VideoSource(url: 'https://b.test/2-hi', quality: '1080p'),
      const VideoSource(url: 'https://b.test/2-low', quality: '720p'),
    ];
    expect(preference.prioritize(sources), [
      sources[1],
      sources[2],
      sources[0],
    ]);
    expect(
      const DownloadServerPreference(
        label: 'missing',
        host: '',
      ).prioritize(sources),
      sources,
    );
  });
  test(
    'saved preference survives copy/restart and old jobs remain readable',
    () {
      const record = DownloadRecord(
        id: 'job',
        sourceId: 'source',
        showId: 'show',
        showTitle: 'Show',
        showUrl: 'show',
        episodeId: 'ep',
        episodeUrl: 'ep',
        episodeTitle: 'Episode',
        category: 'sub',
        quality: 'best',
        createdAt: 1,
        serverPreference: DownloadServerPreference(label: 'B', host: 'b.test'),
      );
      final restored = DownloadRecord.fromMap(
        record.copyWith(status: DownloadStatus.paused).toMap(),
      );
      expect(restored.serverPreference!.label, 'B');
      expect(restored.serverPreference!.host, 'b.test');
      final legacy = record.toMap()..remove('serverPreference');
      expect(DownloadRecord.fromMap(legacy).serverPreference, isNull);
    },
  );
}

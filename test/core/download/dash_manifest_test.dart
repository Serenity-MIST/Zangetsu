import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/dash_manifest.dart';
import 'package:watch_app/core/download/desktop_dash_downloader.dart';

/// A MovieBox-style manifest: one video set with three heights (listed out
/// of order, as some servers do) and one audio set.
const _mpd = '''<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static"
     mediaPresentationDuration="PT23M40.5S">
  <Period id="0">
    <AdaptationSet contentType="video" mimeType="video/mp4">
      <Representation id="v720" bandwidth="1500000" width="1280" height="720">
        <BaseURL>v720.mp4</BaseURL>
      </Representation>
      <Representation id="v1080" bandwidth="3000000" width="1920" height="1080"/>
      <Representation id="v480" bandwidth="800000" width="854" height="480"/>
    </AdaptationSet>
    <AdaptationSet mimeType="audio/mp4" lang="en">
      <Representation id="a1" bandwidth="128000"/>
    </AdaptationSet>
  </Period>
</MPD>''';

void main() {
  test('lists every video height the stream has, tallest first', () {
    final m = DashManifest.tryParse(_mpd)!;
    // The same 1080p / 720p / 480p the player's Quality sheet shows.
    expect(m.heights, [1080, 720, 480]);
    expect(m.videos.map((v) => v.id), ['v720', 'v1080', 'v480']);
    expect(m.audios.single.language, 'en');
    expect(
      m.duration,
      const Duration(minutes: 23, seconds: 40, milliseconds: 500),
    );
  });

  test('picks the manifest index of the asked height, nearest lower', () {
    final m = DashManifest.tryParse(_mpd)!;
    // Indexes follow manifest order (ffmpeg's 0:v:N).
    expect(m.videoIndexFor(720), 0);
    expect(m.videoIndexFor(1080), 1);
    expect(m.videoIndexFor(null), 1, reason: 'best = tallest');
    // An episode without 900p gets 720p, never the bigger 1080p.
    expect(m.videoIndexFor(900), 0);
    // Nothing that small: the smallest available.
    expect(m.videoIndexFor(240), 2);
    expect(m.audioIndexFor('en'), 0);
    expect(m.audioIndexFor(null), 0);
  });

  test('size estimate is bitrate times length', () {
    final m = DashManifest.tryParse(_mpd)!;
    final bytes = m.estimateBytes(0, 0)!;
    // (1.5 Mb/s + 128 kb/s) * 1420.5 s / 8
    expect(bytes, closeTo((1500000 + 128000) * 1420.5 / 8, 1));
  });

  test('an asked audio language the manifest lacks is refused', () {
    final m = DashManifest.tryParse(_mpd)!;
    // The manifest names English only: Hindi must fail, not save English.
    expect(m.audioLanguageMissing('hi'), isTrue);
    expect(m.audioLanguageMissing('en'), isFalse);
    expect(m.audioLanguageMissing('eng'), isFalse, reason: 'loose match');
    expect(m.audioLanguageMissing(null), isFalse, reason: 'nothing asked');
    // No lang attributes at all: cannot be checked, so never refused.
    final unnamed = DashManifest.tryParse(_mpd.replaceFirst(' lang="en"', ''))!;
    expect(unnamed.audioLanguageMissing('hi'), isFalse);
    expect(unnamed.audioIndexFor('hi'), 0);
  });

  test('a save shorter than the episode is not whole', () {
    const total = Duration(minutes: 20);
    final us = total.inMicroseconds;
    expect(DesktopDashDownloader.savedWhole(us, total), isTrue);
    expect(
      DesktopDashDownloader.savedWhole((us * 0.98).round(), total),
      isTrue,
    );
    // ffmpeg skipped fragments and stopped at 80%: a failure, not "done".
    expect(
      DesktopDashDownloader.savedWhole((us * 0.8).round(), total),
      isFalse,
    );
    expect(DesktopDashDownloader.savedWhole(-1, total), isFalse);
    // Unknown length cannot be checked.
    expect(DesktopDashDownloader.savedWhole(-1, null), isTrue);
  });

  test('labels map to heights and non-MPD text is rejected', () {
    expect(dashWantedHeight('720p'), 720);
    expect(dashWantedHeight('best'), isNull);
    expect(DashManifest.tryParse('#EXTM3U'), isNull);
    expect(
      DashManifest.parseIsoDuration('PT1H2M3S'),
      const Duration(hours: 1, minutes: 2, seconds: 3),
    );
  });
}

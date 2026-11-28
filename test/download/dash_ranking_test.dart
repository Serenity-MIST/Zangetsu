import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/download/download_server_preference.dart';
import 'package:watch_app/core/models/video_source.dart';

// MovieBox-style links for one episode: a DASH server and an MP4 server.
const _dash = VideoSource(
  url: 'https://cdn.fixture/ep1/master.mpd',
  label: 'MovieBox (Original) DASH',
  quality: '1080p',
);
const _mp4Hd = VideoSource(
  url: 'https://cdn.fixture/ep1/1080.mp4',
  label: 'MovieBox (Original) MP4',
  quality: '1080p',
);
const _mp4Sd = VideoSource(
  url: 'https://cdn.fixture/ep1/480.mp4',
  label: 'MovieBox (Original) MP4',
  quality: '480p',
);
// Same DASH server, but encrypted (ClearKey): never downloadable.
const _drmDash = VideoSource(
  url: 'https://cdn.fixture/ep1/locked.mpd',
  label: 'MovieBox (Original) DASH',
  quality: '1080p',
  drmKid: 'kid',
  drmKey: 'key',
);

/// A batch record for one episode, pinned to [pin] when given.
DownloadRecord _record({VideoSource? pin, String quality = '720p'}) =>
    DownloadRecord(
      id: 'r1',
      sourceId: 'moviebox',
      showId: 'show',
      showTitle: 'Fixture Show',
      showUrl: '/show',
      episodeId: 'e1',
      episodeUrl: '/e1',
      episodeTitle: 'Episode 1',
      category: 'sub',
      quality: quality,
      serverPreference: pin == null
          ? null
          : DownloadServerPreference.fromSource(pin),
      createdAt: 0,
    );

void main() {
  const all = [_dash, _mp4Hd, _mp4Sd];

  test('a DASH pin ranks its .mpd first, MP4 links stay as fallbacks', () {
    final ranked = DownloadManager.rankForRecord(
      _record(pin: _dash),
      all,
      desktopDash: true,
    );
    expect(ranked.first, _dash);
    expect(ranked.skip(1), containsAll([_mp4Hd, _mp4Sd]));
    expect(ranked.length, 3);
  });

  test('without the Windows DASH engine a DASH pin keeps the old order', () {
    final ranked = DownloadManager.rankForRecord(
      _record(pin: _dash),
      all,
      desktopDash: false,
    );
    expect(ranked, isNot(contains(_dash)));
  });

  test('an MP4 pin and Auto never rank DASH links', () {
    final mp4 = DownloadManager.rankForRecord(
      _record(pin: _mp4Hd, quality: '480p'),
      all,
      desktopDash: true,
    );
    // Closest height first, like before.
    expect(mp4, [_mp4Sd, _mp4Hd]);
    final auto = DownloadManager.rankForRecord(
      _record(quality: 'best'),
      all,
      desktopDash: true,
    );
    expect(auto, [_mp4Hd, _mp4Sd]);
  });

  test('encrypted DASH is never ranked as downloadable', () {
    final ranked = DownloadManager.rankForRecord(_record(pin: _drmDash), const [
      _drmDash,
      _mp4Hd,
    ], desktopDash: true);
    expect(ranked, [_mp4Hd]);
  });
}

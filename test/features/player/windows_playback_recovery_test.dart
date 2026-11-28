// Plan items R2 (safe second try), R3 (fresh links once) and P5 (resume mark
// at the end): the Windows-only rules in desktop_playback_recovery.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/desktop_playback_recovery.dart';

void main() {
  group('shouldDesktopSafeRetry (R2)', () {
    // A fatal error before the first frame on a plain online link.
    bool retry({
      bool isWindows = true,
      bool alreadyRetried = false,
      bool startedThisSource = false,
      bool isLocalFile = false,
      bool isTorrent = false,
      bool isDrm = false,
      bool offline = false,
      bool proxied = false,
      bool proxySwapPending = false,
      bool timedOut = false,
      bool otherMirrorLeft = true,
    }) => shouldDesktopSafeRetry(
      isWindows: isWindows,
      alreadyRetried: alreadyRetried,
      startedThisSource: startedThisSource,
      isLocalFile: isLocalFile,
      isTorrent: isTorrent,
      isDrm: isDrm,
      offline: offline,
      proxied: proxied,
      proxySwapPending: proxySwapPending,
      timedOut: timedOut,
      otherMirrorLeft: otherMirrorLeft,
    );

    test('an error on an online link gets one try, mirrors left or not', () {
      expect(retry(), isTrue);
      expect(retry(otherMirrorLeft: false), isTrue);
    });

    test('never twice for the same link (no loop)', () {
      expect(retry(alreadyRetried: true), isFalse);
      expect(retry(alreadyRetried: true, timedOut: true), isFalse);
    });

    test('never on phones', () {
      expect(retry(isWindows: false), isFalse);
    });

    test('torrent, DRM, local file and offline are excluded', () {
      expect(retry(isTorrent: true), isFalse);
      expect(retry(isDrm: true), isFalse);
      expect(retry(isLocalFile: true), isFalse);
      expect(retry(offline: true), isFalse);
    });

    test('a link that already played, or has its own proxy recovery, is left', () {
      expect(retry(startedThisSource: true), isFalse);
      expect(retry(proxied: true), isFalse);
      expect(retry(proxySwapPending: true), isFalse);
    });

    test('a silent link is retried only when no other mirror is left', () {
      expect(retry(timedOut: true, otherMirrorLeft: true), isFalse);
      expect(retry(timedOut: true, otherMirrorLeft: false), isTrue);
    });

    test('the retry has a 15 s watchdog and plain demuxer options', () {
      expect(kDesktopSafeRetryWatchdog, const Duration(seconds: 15));
      expect(kDesktopSafeRetryDemuxerOptions, isNot(contains('http_persistent')));
      expect(kDesktopSafeRetryDemuxerOptions, isNot(contains('analyzeduration')));
      expect(kDesktopSafeRetryDemuxerOptions, contains('extension_picky=0'));
    });
  });

  group('looksLikeExpiredLink (R3)', () {
    test('403 / 410 / expired / forbidden read as expired', () {
      for (final e in [
        'HTTP error 403 Forbidden',
        'http: HTTP error 410 Gone',
        'Failed to open: token expired',
        'Access Denied',
        'Server returned 403',
      ]) {
        expect(looksLikeExpiredLink(error: e), isTrue, reason: e);
      }
    });

    test('a real 403 next to a link still counts', () {
      expect(
        looksLikeExpiredLink(
          error: 'Failed to open https://cdn.example/a.m3u8: HTTP error 403',
        ),
        isTrue,
      );
    });

    test('an error log line can carry the 403', () {
      expect(
        looksLikeExpiredLink(
          error: 'Failed to open https://cdn.example/a.m3u8.',
          logLines: const ['ffmpeg: http: HTTP error 403 Forbidden'],
        ),
        isTrue,
      );
    });

    test('other failures do not', () {
      for (final e in [
        'Failed to open https://cdn.example/a.m3u8.',
        'tcp: Connection refused',
        'HTTP error 404 Not Found',
        'vd: Could not open codec',
        'Error 4030 in segment', // a number that only contains 403
        // 403 / 410 / "gone" / "expired" only inside the link itself.
        'Failed to open https://cdn.example/seg/410/x.ts',
        'Failed to open https://cdn.example/play?ep=12-403',
        'Failed to open https://gone.example/a.m3u8?expired=0',
      ]) {
        expect(looksLikeExpiredLink(error: e), isFalse, reason: e);
      }
      expect(
        looksLikeExpiredLink(
          error: 'x',
          logLines: const ['ffmpeg: Opening https://cdn.example/403/a.ts'],
        ),
        isFalse,
      );
    });
  });

  group('shouldTryFreshLinks (R3)', () {
    bool fresh({
      bool isWindows = true,
      bool alreadyTried = false,
      bool mirrorsLeft = false,
      bool isLocalFile = false,
      bool isTorrent = false,
      bool offline = false,
      bool looksExpired = true,
    }) => shouldTryFreshLinks(
      isWindows: isWindows,
      alreadyTried: alreadyTried,
      mirrorsLeft: mirrorsLeft,
      isLocalFile: isLocalFile,
      isTorrent: isTorrent,
      offline: offline,
      looksExpired: looksExpired,
    );

    test('expired link with no mirror left: once', () {
      expect(fresh(), isTrue);
      expect(fresh(alreadyTried: true), isFalse, reason: 'once per episode');
    });

    test('not while mirrors are left, not for other errors, not on phones', () {
      expect(fresh(mirrorsLeft: true), isFalse);
      expect(fresh(looksExpired: false), isFalse);
      expect(fresh(isWindows: false), isFalse);
    });

    test('never for local files, torrents or offline', () {
      expect(fresh(isLocalFile: true), isFalse);
      expect(fresh(isTorrent: true), isFalse);
      expect(fresh(offline: true), isFalse);
    });

    test('cap is 15 s', () {
      expect(kDesktopFreshLinksCap, const Duration(seconds: 15));
    });
  });

  group('firstUntriedLink (R3)', () {
    test('plays the first link not already tried', () {
      expect(
        firstUntriedLink<String>(['a', 'b', 'c'], {'a'}, (s) => s),
        'b',
      );
    });

    test('null when every fresh link already failed', () {
      expect(firstUntriedLink<String>(['a', 'b'], {'a', 'b'}, (s) => s), isNull);
      expect(firstUntriedLink<String>(const [], {}, (s) => s), isNull);
    });
  });

  group('resumeMarkAtOrPastEnd (P5)', () {
    const min = Duration(minutes: 1);

    test('at, past, or within 5 s of a known end', () {
      expect(
        resumeMarkAtOrPastEnd(target: min * 24, duration: min * 24),
        isTrue,
      );
      expect(
        resumeMarkAtOrPastEnd(target: min * 30, duration: min * 24),
        isTrue,
      );
      expect(
        resumeMarkAtOrPastEnd(
          target: min * 24 - const Duration(seconds: 5),
          duration: min * 24,
        ),
        isTrue,
      );
    });

    test('a valid mark before the end is kept', () {
      expect(
        resumeMarkAtOrPastEnd(
          target: min * 24 - const Duration(seconds: 6),
          duration: min * 24,
        ),
        isFalse,
      );
      expect(
        resumeMarkAtOrPastEnd(target: min * 10, duration: min * 24),
        isFalse,
      );
    });

    test('an unknown or untrusted duration is never proof', () {
      expect(
        resumeMarkAtOrPastEnd(target: min * 10, duration: Duration.zero),
        isFalse,
      );
      expect(
        resumeMarkAtOrPastEnd(
          target: min * 30,
          duration: min * 24,
          durationTrusted: false,
        ),
        isFalse,
      );
      expect(
        resumeMarkAtOrPastEnd(target: Duration.zero, duration: min * 24),
        isFalse,
      );
    });
  });

  group('isSavedResumeTarget (P5)', () {
    const end = Duration(minutes: 24);
    const nearEnd = Duration(minutes: 23, seconds: 57);

    test('a saved mark the player still aims for counts', () {
      expect(
        isSavedResumeTarget(target: end, savedMark: end, pending: end),
        isTrue,
      );
    });

    test('a switch or quality reopen near the end is not a saved mark', () {
      // Switch at the live position: the open read no mark (savedMark zero)
      // and the player aims for nothing (pending zero).
      expect(
        isSavedResumeTarget(
          target: nearEnd,
          savedMark: Duration.zero,
          pending: Duration.zero,
        ),
        isFalse,
      );
      // An older mark that is not this open's start.
      expect(
        isSavedResumeTarget(
          target: nearEnd,
          savedMark: const Duration(minutes: 5),
          pending: const Duration(minutes: 5),
        ),
        isFalse,
      );
    });

    test('a mark the player already dropped, or zero, never counts', () {
      expect(
        isSavedResumeTarget(
          target: end,
          savedMark: end,
          pending: Duration.zero,
        ),
        isFalse,
      );
      expect(
        isSavedResumeTarget(
          target: Duration.zero,
          savedMark: Duration.zero,
          pending: Duration.zero,
        ),
        isFalse,
      );
    });
  });
}

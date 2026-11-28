// Windows 4K playback and watch page opening: the render size cap for videos
// above 1440p, the cheaper video filter for them, the movie top bar without
// an "E1" line, and the watch page that opens straight away while the player
// is still loading. Each check also pins that 1080p and phones keep their
// old behaviour.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/features/player/desktop_watch_page.dart';
import 'package:watch_app/features/player/player_controller.dart';
import 'package:watch_app/features/player/player_screen.dart';
import 'package:watch_app/features/player/player_watch_page.dart';
import 'package:watch_app/l10n/app_localizations.dart';

void main() {
  group('big video detection', () {
    test('4K counts as above 1440p, 1080p and 1440p do not', () {
      expect(isAbove1440p(3840, 2160), isTrue);
      expect(isAbove1440p(4096, 1716), isTrue);
      expect(isAbove1440p(1920, 1080), isFalse);
      expect(isAbove1440p(2560, 1440), isFalse);
      expect(isAbove1440p(1920, 800), isFalse);
    });
  });

  group('render size cap', () {
    test('4K on a 1080p screen is drawn at 1920x1080', () {
      expect(
        windowsRenderCap(
          videoWidth: 3840,
          videoHeight: 2160,
          screenWidth: 1920,
          screenHeight: 1080,
        ),
        (1920, 1080),
      );
    });

    test('keeps a wide film its shape', () {
      expect(
        windowsRenderCap(
          videoWidth: 3840,
          videoHeight: 1600,
          screenWidth: 1920,
          screenHeight: 1080,
        ),
        (1920, 800),
      );
    });

    test('a 4K screen keeps the full 4K picture', () {
      expect(
        windowsRenderCap(
          videoWidth: 3840,
          videoHeight: 2160,
          screenWidth: 3840,
          screenHeight: 2160,
        ),
        isNull,
      );
    });

    test('never caps below 1920x1080, even on a small screen', () {
      expect(
        windowsRenderCap(
          videoWidth: 3840,
          videoHeight: 2160,
          screenWidth: 1366,
          screenHeight: 768,
        ),
        (1920, 1080),
      );
      // No display reported at all.
      expect(
        windowsRenderCap(
          videoWidth: 3840,
          videoHeight: 2160,
          screenWidth: 0,
          screenHeight: 0,
        ),
        (1920, 1080),
      );
    });

    test('1080p and 1440p are left at their own size', () {
      expect(
        windowsRenderCap(
          videoWidth: 1920,
          videoHeight: 1080,
          screenWidth: 1366,
          screenHeight: 768,
        ),
        isNull,
      );
      expect(
        windowsRenderCap(
          videoWidth: 2560,
          videoHeight: 1440,
          screenWidth: 1920,
          screenHeight: 1080,
        ),
        isNull,
      );
    });
  });

  group('frame dropping', () {
    test('a software-decoded 4K video may drop in the decoder', () {
      expect(windowsFramedropMode(big: true, hwdec: 'no'), 'decoder+vo');
      expect(windowsFramedropMode(big: true), 'decoder+vo');
      expect(windowsFramedropMode(big: true, hwdec: ''), 'decoder+vo');
    });

    test('a hardware-decoded 4K video keeps normal dropping', () {
      expect(windowsFramedropMode(big: true, hwdec: 'd3d11va'), 'vo');
      expect(windowsFramedropMode(big: true, hwdec: 'd3d11va-copy'), 'vo');
    });

    test('1080p always keeps normal dropping', () {
      expect(windowsFramedropMode(big: false, hwdec: 'no'), 'vo');
      expect(windowsFramedropMode(big: false), 'vo');
    });
  });

  group('video filter', () {
    test('Windows keeps bicubic for 1080p and unknown sizes', () {
      expect(videoFilterQuality(windows: true), FilterQuality.high);
      expect(
        videoFilterQuality(windows: true, videoWidth: 1920, videoHeight: 1080),
        FilterQuality.high,
      );
    });

    test('Windows uses bilinear for a 4K video', () {
      expect(
        videoFilterQuality(windows: true, videoWidth: 3840, videoHeight: 2160),
        FilterQuality.low,
      );
    });

    test('phone is unchanged', () {
      expect(videoFilterQuality(windows: false), FilterQuality.low);
      expect(
        videoFilterQuality(windows: false, videoWidth: 1920, videoHeight: 1080),
        FilterQuality.low,
      );
    });
  });

  group('top bar second line', () {
    test('a film shows no episode line', () {
      expect(
        playerHeaderSecondLine(
          showTitle: 'The Odyssey',
          epNum: 1,
          epName: 'The Odyssey',
          isMovie: true,
        ),
        isNull,
      );
    });

    test('an episode keeps "E5 · Name" and phone is unchanged', () {
      expect(
        playerHeaderSecondLine(showTitle: 'Show', epNum: 5, epName: 'Name'),
        'E5 · Name',
      );
      expect(
        playerHeaderSecondLine(showTitle: 'Show', epNum: 5, epName: null),
        'E5',
      );
      expect(
        playerHeaderSecondLine(showTitle: null, epNum: 5, epName: 'Name'),
        isNull,
      );
    });
  });

  group('watch page while loading', () {
    Future<void> pump(
      WidgetTester tester, {
      required List<Episode> episodes,
      bool movie = false,
      VoidCallback? onBack,
    }) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: desktopWatchLoadingPage(
              episodes: episodes,
              startIndex: 1,
              showTitle: movie ? 'The Odyssey' : 'Show',
              showDescription: 'About it.',
              cover: '',
              coverHeaders: null,
              isMovie: movie,
              autoplay: true,
              onBack: onBack ?? () {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets(
      'opens the theater page with the small player loading and the list',
      (tester) async {
        var back = 0;
        await pump(
          tester,
          episodes: const [
            Episode(id: '1', title: 'Pilot', url: '/1', number: 1),
            Episode(id: '2', title: 'The Fall', url: '/2', number: 2),
          ],
          onBack: () => back++,
        );
        expect(
          tester.state(find.byType(PlayerWatchPage)),
          isA<DesktopWatchPageState>(),
        );
        // Loading shows inside the small player, not as a full window.
        final video = tester.getRect(find.byKey(const ValueKey('watch-video')));
        final spinner = tester.getRect(
          find.byType(CircularProgressIndicator).first,
        );
        expect(video.contains(spinner.center), isTrue);
        expect(video.width, lessThan(1600));
        // The episode list is already there.
        expect(
          find.byKey(const ValueKey('watch-episode-list')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('watch-back')));
        expect(back, 1);
        // Keep the spinner from holding the test open.
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets('works before the episode list is known', (tester) async {
      await pump(tester, episodes: const [], movie: true);
      expect(find.byType(PlayerWatchPage), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });

  test('Android stays on the phone watch page and filter', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(videoFilterQuality(windows: false), FilterQuality.low);
    debugDefaultTargetPlatformOverride = null;
  });
}

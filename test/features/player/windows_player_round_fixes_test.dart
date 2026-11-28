// Windows player fixes: on-screen seek buttons, the episode name in the top
// bar, full-quality software decoding and the sharper video scaling. Each
// check also pins that phones keep their old behaviour.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/features/player/player_controller.dart';
import 'package:watch_app/features/player/player_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

Episode _ep({String title = 'Episode 1', String? metaTitle, double n = 1}) =>
    Episode(
      id: 'e$n',
      title: title,
      url: 'https://x/e$n',
      number: n,
      metaTitle: metaTitle,
    );

void main() {
  group('seek step buttons', () {
    Future<List<String>> pump(WidgetTester tester, int seconds) async {
      final log = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  debugPlayerSeekStepButton(
                    seconds: -seconds,
                    onTap: () => log.add('-$seconds'),
                  ),
                  debugPlayerSeekStepButton(
                    seconds: seconds,
                    onTap: () => log.add('+$seconds'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      return log;
    }

    testWidgets('show numbered arrows with tooltips and seek on click', (
      tester,
    ) async {
      final log = await pump(tester, 10);
      expect(find.byIcon(Icons.replay_10_rounded), findsOneWidget);
      expect(find.byIcon(Icons.forward_10_rounded), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == 'Seek back 10s',
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == 'Seek forward 10s',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byIcon(Icons.replay_10_rounded));
      await tester.tap(find.byIcon(Icons.forward_10_rounded));
      expect(log, ['-10', '+10']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('can be reached with Tab and pressed with Enter', (
      tester,
    ) async {
      final log = await pump(tester, 10);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(log, ['-10', '+10']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('an unusual step writes the number under a plain arrow', (
      tester,
    ) async {
      await pump(tester, 15);
      expect(find.byIcon(Icons.replay_rounded), findsOneWidget);
      expect(find.byIcon(Icons.forward_rounded), findsOneWidget);
      expect(find.text('15'), findsNWidgets(2));
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });

  group('top bar episode name', () {
    test('Windows falls back to the looked-up name', () {
      final ep = _ep(metaTitle: 'The Boy in the Iceberg');
      expect(
        playerHeaderEpisodeName(ep, 1, windows: true),
        'The Boy in the Iceberg',
      );
    });

    test('Windows still prefers a real source title', () {
      final ep = _ep(title: 'Source Name', metaTitle: 'Meta Name');
      expect(playerHeaderEpisodeName(ep, 1, windows: true), 'Source Name');
    });

    test('no name at all stays null so the bar shows only E1', () {
      expect(playerHeaderEpisodeName(_ep(), 1, windows: true), isNull);
      expect(
        playerHeaderEpisodeName(_ep(title: '1'), 1, windows: true),
        isNull,
      );
    });

    test('phone is unchanged: source title only, meta ignored', () {
      final ep = _ep(metaTitle: 'The Boy in the Iceberg');
      expect(playerHeaderEpisodeName(ep, 1, windows: false), isNull);
      expect(
        playerHeaderEpisodeName(_ep(title: 'Real'), 1, windows: false),
        'Real',
      );
    });

    test('a lookup is only needed when some episode has no name', () {
      expect(episodesMissingNames([_ep(title: 'Named')]), isFalse);
      expect(
        episodesMissingNames([
          _ep(title: 'Named'),
          _ep(n: 2, title: 'Episode 2'),
        ]),
        isTrue,
      );
      expect(episodesMissingNames([_ep(metaTitle: 'From AniZip')]), isFalse);
    });
  });

  group('video quality', () {
    test('Windows decodes in software at full quality', () {
      expect(lavcDecodeOptions(true), {
        'vd-lavc-threads': '0',
        'vd-lavc-skiploopfilter': 'default',
        'vd-lavc-fast': 'no',
      });
    });

    test('phone keeps the light software-decode settings', () {
      expect(lavcDecodeOptions(false), {
        'vd-lavc-threads': '4',
        'vd-lavc-skiploopfilter': 'nonkey',
        'vd-lavc-fast': 'yes',
      });
    });

    test('Windows scales the video with the bicubic filter', () {
      expect(videoFilterQuality(windows: true), FilterQuality.high);
      expect(videoFilterQuality(windows: false), FilterQuality.low);
    });
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/ui/episode_unavailable_dialog.dart';
import 'package:watch_app/core/ui/jump_prompt.dart';
import 'package:watch_app/core/zmode/playback_resolver.dart';
import 'package:watch_app/features/detail/episode_sources_sheet.dart';

/// Hosts a button that runs [open] with a context inside a Material app.
Widget _host(Future<void> Function(BuildContext context) open) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => open(context),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

/// Resolver stand-in: two candidates, one of which has the episode. The
/// stream is held open so the dialog stays in its "checking" state.
class _FakeResolver implements PlaybackResolver {
  final controller = StreamController<SourceProbe>();

  @override
  List<({String id, String name})> candidatesForEpisode(String url) => const [
    (id: 'a', name: 'Alpha'),
    (id: 'b', name: 'Bravo'),
  ];

  @override
  Stream<SourceProbe> probeEach(
    String zmEpisodeUrl, {
    Duration wallClock = const Duration(seconds: 20),
    Set<String> skip = const {},
  }) => controller.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _ep = Episode(
  id: '1',
  title: 'Ep 3',
  number: 3,
  url: 'zm://ep/3',
  unavailable: 'Not on HiAnime',
);

void main() {
  // Every test here is the Windows branch. The variant sets and resets the
  // platform override inside each test, so flutter_test's debug-variable
  // check passes and other files stay phone.
  final windows = TargetPlatformVariant.only(TargetPlatform.windows);

  testWidgets('episode unavailable: desktop confirm, Enter checks others', (
    tester,
  ) async {
    bool? result;
    await tester.pumpWidget(
      _host((c) async => result = await showEpisodeUnavailable(c, _ep)),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Not on HiAnime'), findsOneWidget);
    expect(find.text('Check other sources'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    // The phone card's big circle icon is gone on Windows.
    expect(find.byIcon(Icons.hourglass_empty_rounded), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(result, isTrue);
  }, variant: windows);

  testWidgets('playback dead end: Esc goes back, Try again returns true', (
    tester,
  ) async {
    bool? result;
    await tester.pumpWidget(
      _host(
        (c) async => result = await showPlaybackDeadEnd(
          c,
          'Nothing played\nEvery source failed.',
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing played'), findsOneWidget);
    expect(find.text('Every source failed.'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(result, isFalse);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  }, variant: windows);

  testWidgets('jump prompt: choice rows, Esc returns null', (tester) async {
    JumpChoice? result = JumpChoice.move;
    await tester.pumpWidget(
      _host((c) async => result = await showJumpPrompt(c, reading: false)),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Jump to this episode?'), findsOneWidget);
    expect(find.text('Just look'), findsOneWidget);
    expect(find.text('Move progress here'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(result, isNull);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move progress here'));
    await tester.pumpAndSettle();
    expect(result, JumpChoice.move);
  }, variant: windows);

  testWidgets('episode sources: graphite dialog, Stop row, Esc closes', (
    tester,
  ) async {
    final fake = _FakeResolver();
    sl.registerSingleton<PlaybackResolver>(fake);
    addTearDown(() async {
      await sl.unregister<PlaybackResolver>();
      await fake.controller.close();
    });

    var closed = false;
    await tester.pumpWidget(
      _host((c) async {
        await showEpisodeSourcesSheet(c, episode: _ep);
        closed = true;
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Where to watch episode 3'), findsOneWidget);
    // Close button is a real IconButton with a tooltip on Windows.
    expect(find.byTooltip('Close (Esc)'), findsOneWidget);
    // Footer "Stop" is an inline TextButton, not a full-width pill.
    expect(find.widgetWithText(TextButton, 'Stop'), findsOneWidget);
    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    final shape = dialog.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(14));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(closed, isTrue);
  }, variant: windows);
}

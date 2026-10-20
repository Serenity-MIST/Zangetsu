import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/features/settings/player_controls_screen.dart';

/// Desktop placement settings must describe the action the player performs.
void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('player-control-labels-');
    Hive.init(directory.path);
    await PlaybackPrefs.init();
    sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
  });
  tearDown(() async {
    await sl.reset();
    await Hive.close();
    await directory.delete(recursive: true);
  });
  testWidgets('Windows names the rotate slot Fullscreen', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PlayerControlsScreen()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Fullscreen'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Fullscreen'), findsOneWidget);
    expect(find.text('Portrait'), findsNothing);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);
}

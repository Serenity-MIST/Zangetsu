import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/features/reader/reader_comfort.dart';

/// A minimal reader exercises the real comfort lifecycle without network data.
class _Reader extends StatefulWidget {
  const _Reader();
  @override
  State<_Reader> createState() => _ReaderState();
}

/// Applies the same init/dispose behavior used by the manga and novel readers.
class _ReaderState extends State<_Reader> with ReaderComfortMixin<_Reader> {
  @override
  void initState() {
    super.initState();
    applyReaderComfort();
  }

  @override
  void dispose() {
    restoreReaderComfort();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

/// Verifies native state restoration with private settings and a fake channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final initialFullscreen in [false, true]) {
    testWidgets('reader restores incoming fullscreen=$initialFullscreen', (
      tester,
    ) async {
      late Directory directory;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('reader-window-');
        Hive.init(directory.path);
        await ReaderPrefs.init();
        await sl.reset();
        final prefs = ReaderPrefs();
        sl.registerSingleton<ReaderPrefs>(prefs);
        await prefs.setFullscreen(!initialFullscreen);
      });
      var nativeState = initialFullscreen;
      final setters = <bool>[];
      const channel = MethodChannel('com.spyou.zangetsu/window');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'isFullscreen') return nativeState;
        if (call.method == 'setFullscreen') {
          nativeState = call.arguments as bool;
          setters.add(nativeState);
        }
        return null;
      });
      addTearDown(() async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        await sl.reset();
        await Hive.close();
        await directory.delete(recursive: true);
      });
      await tester.pumpWidget(const MaterialApp(home: _Reader()));
      await tester.pumpAndSettle();
      // reader-4 C: "Reader fullscreen" on makes the reader full screen and
      // closing restores the window; off leaves the window as the user had
      // it (no native calls at all).
      final readerTurnsItOn = !initialFullscreen;
      expect(nativeState, readerTurnsItOn ? true : initialFullscreen);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(nativeState, initialFullscreen);
      expect(setters, readerTurnsItOn ? [true, false] : isEmpty);
    }, skip: !Platform.isWindows);
  }

  // Re-applying comfort (e.g. toggling Keep screen on in the panel) must not
  // undo a full screen the user entered with F; closing still restores.
  testWidgets('F full screen survives an unrelated comfort re-apply', (
    tester,
  ) async {
    late Directory directory;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('reader-window-');
      Hive.init(directory.path);
      await ReaderPrefs.init();
      await sl.reset();
      final prefs = ReaderPrefs();
      sl.registerSingleton<ReaderPrefs>(prefs);
      await prefs.setFullscreen(false);
    });
    var nativeState = false;
    const channel = MethodChannel('com.spyou.zangetsu/window');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'isFullscreen') return nativeState;
      if (call.method == 'setFullscreen') nativeState = call.arguments as bool;
      return null;
    });
    addTearDown(() async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
      await sl.reset();
      await Hive.close();
      await directory.delete(recursive: true);
    });
    await tester.pumpWidget(const MaterialApp(home: _Reader()));
    await tester.pumpAndSettle();
    final state = tester.state<_ReaderState>(find.byType(_Reader));
    state.toggleReaderFullscreen();
    await tester.pumpAndSettle();
    expect(nativeState, isTrue);
    state.applyReaderComfort();
    await tester.pumpAndSettle();
    expect(nativeState, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(nativeState, isFalse);
  }, skip: !Platform.isWindows);
}

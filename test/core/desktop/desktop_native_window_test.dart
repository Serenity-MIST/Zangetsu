import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:watch_app/core/desktop/desktop_native.dart';
import 'package:watch_app/core/desktop/desktop_title_bar.dart';
import 'package:watch_app/core/desktop/desktop_window.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/l10n/app_localizations.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Mode fixture so the title bar's media selector needs no app startup.
class _Mode extends Cubit<ContentMode> implements ContentModeCubit {
  _Mode() : super(ContentMode.anime);
  @override
  Future<void> setMode(ContentMode value) async => emit(value);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Covers the runner -> Dart window events (shell-10 Snap Layouts rect,
// shell-12 fullscreen reporting) through the real title bar.
void main() {
  const channel = MethodChannel('com.spyou.zangetsu/window');

  testWidgets('title bar follows native window events', (tester) async {
    final mode = _Mode();
    GetIt.instance.registerSingleton<ContentModeCubit>(mode);
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return switch (call.method) {
        'setTitlebarHidden' => true,
        'isMaximizedWindow' => DesktopWindow.maximized.value,
        _ => null,
      };
    });
    // A 2x display: the runner wants the rect in physical pixels.
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(2732, 1536);
    addTearDown(() async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
      tester.view.reset();
      DesktopWindow.fullscreen.value = false;
      DesktopWindow.maximized.value = false;
      DesktopWindow.maximizeHover.value = false;
      DesktopNative.debugReset();
      await GetIt.instance.reset();
      await mode.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (_, child) => DesktopWindow(enableChrome: true, child: child!),
        home: const Scaffold(body: Text('Content')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DesktopTitleBar), findsOneWidget);

    // Snap Layouts: the maximise button rect is reported in physical px.
    final rectCall = calls.lastWhere(
      (c) => c.method == 'setMaximizeButtonRect',
    );
    final args = rectCall.arguments as Map;
    final button = tester.getRect(
      find.byKey(const ValueKey('caption-Maximize')),
    );
    expect(args['x'], button.left * 2);
    expect(args['y'], button.top * 2);
    expect(args['w'], button.width * 2);
    expect(args['h'], button.height * 2);

    // The runner reports a maximise made by Snap / Win+Up.
    await DesktopNative.debugHandleNativeCall(
      const MethodCall('maximizedChanged', true),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('caption-Restore')), findsOneWidget);

    // The window left/entered fullscreen without Dart asking (shell-12):
    // the caption follows, and the Snap rect is cleared while hidden.
    calls.clear();
    await DesktopNative.debugHandleNativeCall(
      const MethodCall('fullscreenChanged', true),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DesktopTitleBar), findsNothing);
    final cleared = calls.lastWhere((c) => c.method == 'setMaximizeButtonRect');
    expect((cleared.arguments as Map)['w'], 0);

    await DesktopNative.debugHandleNativeCall(
      const MethodCall('fullscreenChanged', false),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DesktopTitleBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

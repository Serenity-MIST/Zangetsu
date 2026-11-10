import 'package:watch_app/core/desktop/desktop_media_selector.dart';
import 'dart:async';
import 'package:watch_app/features/home/cubit/home_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:watch_app/core/desktop/desktop_window.dart';
import 'package:watch_app/core/desktop/desktop_title_bar.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// Mode state fixture isolates caption actions from network/source startup.
class _Mode extends Cubit<ContentMode> implements ContentModeCubit {
  _Mode() : super(ContentMode.anime);
  @override
  Future<void> setMode(ContentMode value) async {
    emit(value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Deliberately unfinished catalogue loads reproduce switching on a slow source.
class _PendingHome extends Cubit<HomeState> implements HomeCubit {
  _PendingHome() : super(const HomeState());
  final completion = Completer<void>();
  int loads = 0;
  @override
  Future<void> load({bool reset = false}) {
    loads++;
    return completion.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const channel = MethodChannel('com.spyou.zangetsu/window');
  testWidgets('media tabs remain usable while catalogue requests are pending', (
    tester,
  ) async {
    final mode = _Mode();
    final home = _PendingHome();
    GetIt.instance.registerSingleton<ContentModeCubit>(mode);
    GetIt.instance.registerSingleton<HomeCubit>(home);
    addTearDown(() async {
      home.completion.complete();
      await GetIt.instance.reset();
      await mode.close();
      await home.close();
    });
    await tester.binding.setSurfaceSize(const Size(1366, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: DesktopMediaSelector()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manga'));
    await tester.pumpAndSettle();
    expect(mode.state, ContentMode.manga);
    expect(home.completion.isCompleted, isFalse);
    await tester.tap(find.text('Novel'));
    await tester.pumpAndSettle();
    expect(mode.state, ContentMode.novel);
    expect(home.loads, 2);
    expect(tester.takeException(), isNull);
  });
  for (final width in [420.0, 1366.0]) {
    testWidgets('caption handshake/actions/fullscreen at $width', (
      tester,
    ) async {
      final mode = _Mode();
      GetIt.instance.registerSingleton<ContentModeCubit>(mode);
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return switch (call.method) {
          'setTitlebarHidden' => true,
          'isMaximizedWindow' => false,
          'toggleMaximizeWindow' => true,
          _ => null,
        };
      });
      addTearDown(() async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        DesktopWindow.fullscreen.value = false;
        await GetIt.instance.reset();
        await mode.close();
      });
      await tester.binding.setSurfaceSize(Size(width, 768));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // Match production: the caption is above the Navigator's own Overlay.
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (_, child) =>
              DesktopWindow(enableChrome: true, child: child!),
          home: const Scaffold(body: Text('Content')),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls.first.method, 'setTitlebarHidden');
      expect(calls.first.arguments, true);
      expect(find.byType(DesktopTitleBar), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('caption-Minimize')));
      await tester.tap(find.byKey(const ValueKey('caption-Maximize')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('caption-Close')));
      expect(
        calls.map((c) => c.method),
        containsAll(['minimizeWindow', 'toggleMaximizeWindow', 'closeWindow']),
      );
      await DesktopWindow.setFullscreen(true);
      await tester.pump();
      expect(find.byType(DesktopTitleBar), findsNothing);
      await DesktopWindow.setFullscreen(false);
      await tester.pumpAndSettle();
      expect(find.byType(DesktopTitleBar), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

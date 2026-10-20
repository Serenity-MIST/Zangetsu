import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/shell/mode_bar.dart';

void main() {
  testWidgets('Windows mode picker stays compact and centered', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    t.view.physicalSize = const Size(1366, 768);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModeBar(
            open: true,
            current: (ContentMode.anime, StreamKind.anime),
            onPicked: (_, _) {},
          ),
        ),
      ),
    );
    final rect = t.getRect(find.byType(BackdropFilter));
    expect(rect.width, 440);
    expect(rect.center.dx, 683);
    debugDefaultTargetPlatformOverride = null;
    expect(t.takeException(), isNull);
  });

  testWidgets('shows exactly four content modes and reports the pick', (
    t,
  ) async {
    ContentMode? mode;
    StreamKind? kind;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModeBar(
            open: true,
            current: (ContentMode.anime, StreamKind.anime),
            onPicked: (m, k) {
              mode = m;
              kind = k;
            },
          ),
        ),
      ),
    );
    expect(find.text('Anime'), findsOneWidget);
    expect(find.text('Movie/TV'), findsOneWidget);
    expect(find.text('Manga'), findsOneWidget);
    expect(find.text('Novel'), findsOneWidget);
    expect(find.text('Sources'), findsNothing);
    expect(find.text('Streaming'), findsNothing);
    await t.tap(find.text('Movie/TV'));
    expect(mode, ContentMode.anime);
    expect(kind, StreamKind.movie);
    await t.tap(find.text('Manga'));
    expect(mode, ContentMode.manga);
  });

  testWidgets('closed bar ignores taps', (t) async {
    var picked = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModeBar(
            open: false,
            current: (ContentMode.anime, StreamKind.anime),
            onPicked: (_, _) => picked++,
          ),
        ),
      ),
    );
    await t.tap(find.text('Manga'), warnIfMissed: false);
    expect(picked, 0);
  });
}

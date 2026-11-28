import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/desktop/desktop_prefs.dart';
import 'package:watch_app/core/theme/app_text.dart';
import 'package:watch_app/features/downloads/desktop_download_settings_dialog.dart';

// Layout of the Windows "Download settings" dialog: the two sliders and the
// two switches are the same kind of settings row (same left edge, icon
// column, title column and right edge), a slider used with the mouse does
// not stay behind as a highlighted card, and "Default: N" stays on the
// value line next to the number.

const _rowKeys = [
  ValueKey('desktop-parallel-downloads'),
  ValueKey('desktop-connections-per-download'),
  ValueKey('desktop-download-notifications'),
  ValueKey('desktop-taskbar-progress'),
];

const _icons = [
  Icons.download_rounded,
  Icons.lan_outlined,
  Icons.notifications_none_rounded,
  Icons.web_asset_rounded,
];

void main() {
  late Directory dir;
  var realFont = false;
  final shippedFont = AppText.fontFamily;

  setUpAll(() async {
    // The real Windows UI font when it is there: the test font is about
    // twice as wide, so it cannot tell whether a line fits.
    const faces = ['segoeui.ttf', 'seguisb.ttf', 'segoeuib.ttf'];
    final files = [for (final f in faces) File('C:/Windows/Fonts/$f')];
    if (!files.every((f) => f.existsSync())) return;
    final loader = FontLoader('Segoe UI');
    for (final f in files) {
      loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
    await loader.load();
    realFont = true;
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dl_dialog_layout');
    Hive.init(dir.path);
    await DesktopPrefs.init();
    if (realFont) AppText.fontFamily = 'Segoe UI';
  });

  tearDown(() async {
    AppText.fontFamily = shippedFont;
    await Hive.close();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpDialog(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => DesktopDownloadSettingsDialog(
              parallel: 3,
              connections: 8,
              onParallelChanged: (_) {},
              onParallelCommit: (_) {},
              onConnectionsChanged: (_) {},
              onConnectionsCommit: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The tint of a slider row's card (transparent when it is not a card).
  Color? cardColor(WidgetTester tester, Key row) {
    final box = tester.widget<AnimatedContainer>(
      find
          .descendant(
            of: find.byKey(row),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    return (box.decoration as BoxDecoration?)?.color;
  }

  testWidgets('sliders and switches share one row layout', (tester) async {
    await pumpDialog(tester);
    final rows = [for (final k in _rowKeys) tester.getRect(find.byKey(k))];
    final icons = [
      for (var i = 0; i < _icons.length; i++)
        tester.getRect(
          find.descendant(
            of: find.byKey(_rowKeys[i]),
            matching: find.byIcon(_icons[i]),
          ),
        ),
    ];
    for (var i = 1; i < rows.length; i++) {
      expect(rows[i].left, closeTo(rows[0].left, 0.5), reason: 'left edge $i');
      expect(rows[i].right, closeTo(rows[0].right, 0.5), reason: 'right $i');
      expect(icons[i].left, closeTo(icons[0].left, 0.5), reason: 'icon $i');
    }
    // The title column starts at the same x in every row.
    final titles = [
      'Parallel downloads',
      'Connections per download',
      'Notify when downloads finish or fail',
      'Show download progress on the taskbar button',
    ];
    final titleLefts = [
      for (final t in titles) tester.getTopLeft(find.text(t)).dx,
    ];
    for (final x in titleLefts) {
      expect(x, closeTo(titleLefts.first, 0.5));
    }
    // The switch and the slider end at the same right edge inside the row.
    final sliderRight = tester
        .getRect(
          find.descendant(
            of: find.byKey(_rowKeys[0]),
            matching: find.byType(Slider),
          ),
        )
        .right;
    final switchBox = tester.getRect(
      find.descendant(
        of: find.byKey(_rowKeys[2]),
        matching: find.byType(Switch),
      ),
    );
    expect(switchBox.right, closeTo(sliderRight, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('hover tints a slider row like any settings row; focus only '
      'tints it in keyboard mode', (tester) async {
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    await pumpDialog(tester);
    const parallel = ValueKey('desktop-parallel-downloads');
    const connections = ValueKey('desktop-connections-per-download');
    expect(cardColor(tester, parallel), Colors.transparent);

    final slider = find.descendant(
      of: find.byKey(parallel),
      matching: find.byType(Slider),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(slider));
    await tester.pumpAndSettle();
    // Hovered: the same tint the switch rows get under the mouse.
    expect(cardColor(tester, parallel), isNot(Colors.transparent));
    await mouse.moveTo(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(cardColor(tester, parallel), Colors.transparent);

    // Touch mode (a touch screen): the slider takes focus (Windows hands it
    // focus when its accessibility node is focused) but shows no focus ring,
    // so it must not stay a tinted card beside a plain one either.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
    // The Slider's own focus node (the first Focus with one inside it).
    final node = tester
        .widgetList<Focus>(
          find.descendant(of: slider, matching: find.byType(Focus)),
        )
        .map((f) => f.focusNode)
        .whereType<FocusNode>()
        .first;
    node.requestFocus();
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue);
    expect(cardColor(tester, parallel), Colors.transparent);
    expect(cardColor(tester, connections), Colors.transparent);

    // Keyboard mode while it keeps focus: tint and ring come back at once.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    await tester.pumpAndSettle();
    expect(cardColor(tester, parallel), isNot(Colors.transparent));
    expect(cardColor(tester, connections), Colors.transparent);
  });

  testWidgets('"Default: N" stays on the value line', (tester) async {
    if (!realFont) {
      markTestSkipped('Segoe UI not installed');
      return;
    }
    await pumpDialog(tester);
    for (final (key, number, defaultText) in const [
      (_rowKeys0, '3', '  ·  Default: 3 at once'),
      (_rowKeys1, '8', '  ·  Default: 4 connections'),
    ]) {
      final value = tester.getRect(
        find.descendant(of: find.byKey(key), matching: find.text(number)),
      );
      final def = tester.getRect(
        find.descendant(of: find.byKey(key), matching: find.text(defaultText)),
      );
      expect(def.center.dy, closeTo(value.center.dy, 2), reason: defaultText);
      expect(def.left, greaterThan(value.right), reason: defaultText);
    }
    expect(tester.takeException(), isNull);
  });
}

const _rowKeys0 = ValueKey('desktop-parallel-downloads');
const _rowKeys1 = ValueKey('desktop-connections-per-download');

// search-4: the Aniyomi and Mihon extension filter sheets open as a centred
// dialog on Windows (no drag handle) and stay bottom sheets on phone.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_filters.dart';
import 'package:watch_app/core/mihon/mihon_filters.dart';
import 'package:watch_app/features/aniyomi/aniyomi_filter_sheet.dart';
import 'package:watch_app/features/mihon/mihon_filter_sheet.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// Key that showAdaptiveSheet puts on its Windows dialog.
const _dialogKey = ValueKey('desktop-adaptive-sheet');

/// Pumps a button that opens a sheet through [open].
Future<void> _open(WidgetTester t, void Function(BuildContext) open) async {
  await t.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => open(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

/// The 36x4 phone drag handle, if any.
Finder _dragHandle() => find.byWidgetPredicate(
  (w) =>
      w is Container &&
      w.constraints?.maxWidth == 36 &&
      w.constraints?.maxHeight == 4,
);

void main() {
  final cases = <String, void Function(BuildContext)>{
    'Aniyomi': (ctx) => showAniyomiFilterSheet(ctx, [
      AniyomiCheckBox(name: 'Completed', state: false),
    ]),
    'Mihon': (ctx) => showMihonFilterSheet(ctx, [
      MihonCheckBox(name: 'Completed', state: false),
    ]),
  };

  for (final MapEntry(key: name, value: open) in cases.entries) {
    testWidgets(
      '$name filters: centred dialog without a drag handle on Windows',
      (t) async {
        t.view.physicalSize = const Size(1600, 1000);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await _open(t, open);
        expect(find.byKey(_dialogKey), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
        expect(_dragHandle(), findsNothing);
        expect(find.text('Completed'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets('$name filters: phone keeps the bottom sheet', (t) async {
      await _open(t, open);
      expect(find.byKey(_dialogKey), findsNothing);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(_dragHandle(), findsOneWidget);
    });
  }
}

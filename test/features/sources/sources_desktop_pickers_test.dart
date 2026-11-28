// Windows pickers of the provider screens (sources-screens group, src-7 A):
// the language picker opens as a searchable desktop dialog that writes each
// tick straight through, while phone keeps its bottom sheet.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/i18n/source_languages.dart';
import 'package:watch_app/core/prefs/source_lang_prefs.dart';
import 'package:watch_app/features/sources/source_language_sheet.dart';

/// In-memory prefs so no Hive box is needed.
class _FakePrefs extends LangPrefs {
  _FakePrefs(this._langs) : super('test_lang_prefs');
  Set<String>? _langs;

  @override
  Set<String>? get enabled => _langs;

  @override
  Future<void> setEnabled(Set<String> langs) async {
    _langs = langs;
    notifyListeners();
  }
}

/// A button that opens the language picker for [prefs].
Widget _app(LangPrefs prefs) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => showSourceLanguageSheet(context, prefs),
        child: const Text('open'),
      ),
    ),
  ),
);

void main() {
  testWidgets('Windows: searchable dialog, ticks write through', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final prefs = _FakePrefs({'en'});
      await t.pumpWidget(_app(prefs));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();

      // A dialog, not a bottom sheet.
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(Dialog), findsOneWidget);

      // The search narrows the list to the matching language.
      final spanish = sourceLangLabel('es');
      await t.enterText(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(TextField),
        ),
        spanish,
      );
      await t.pump();
      expect(find.byKey(const ValueKey('desktop-lang-es')), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-lang-en')), findsNothing);

      // Ticking writes the new set at once (no Save step), keeping 'en'.
      await t.tap(find.byKey(const ValueKey('desktop-lang-es')));
      await t.pump();
      expect(prefs.enabled, {'en', 'es'});

      // Ticking again removes it.
      await t.tap(find.byKey(const ValueKey('desktop-lang-es')));
      await t.pump();
      expect(prefs.enabled, {'en'});
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('phone keeps the bottom sheet', (t) async {
    final prefs = _FakePrefs({'en'});
    await t.pumpWidget(_app(prefs));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-lang-en')), findsNothing);
  });
}

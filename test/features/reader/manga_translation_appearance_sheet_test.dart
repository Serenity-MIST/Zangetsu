import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/features/reader/manga_translation_appearance_sheet.dart';

class _AppearancePrefs extends ReaderPrefs {
  double translationFontSize = 20;
  double backgroundOpacity = 0.4;
  Color textColor = ReaderPrefs.defaultMangaTranslationTextColor;
  Color backgroundColor = ReaderPrefs.defaultMangaTranslationBackgroundColor;

  @override
  double get mangaTranslationFontSize => translationFontSize;

  @override
  Future<void> setMangaTranslationFontSize(double value) async {
    translationFontSize = value;
  }

  @override
  double get mangaTranslationBackgroundOpacity => backgroundOpacity;

  @override
  Future<void> setMangaTranslationBackgroundOpacity(double value) async {
    backgroundOpacity = value;
  }

  @override
  Color get mangaTranslationTextColor => textColor;

  @override
  Future<void> setMangaTranslationTextColor(Color value) async {
    textColor = value;
  }

  @override
  Color get mangaTranslationBackgroundColor => backgroundColor;

  @override
  Future<void> setMangaTranslationBackgroundColor(Color value) async {
    backgroundColor = value;
  }
}

void main() {
  testWidgets('desktop appearance preview edits, cancels color and resets', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(720, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final prefs = _AppearancePrefs();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopSettingsScope(
            child: MangaTranslationAppearanceSheet(prefs: prefs),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(GraphiteSettingsPanel), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    final size = find.byKey(
      const ValueKey('manga-translation-appearance-size'),
    );
    tester.widget<Slider>(size).onChanged!(26);
    await tester.pump();
    expect(prefs.translationFontSize, 20); // writes only on release
    tester.widget<Slider>(size).onChangeEnd!(26);
    await tester.pump();
    expect(prefs.translationFontSize, 26);
    expect(
      tester.widget<Text>(find.text('Translation preview')).style?.fontSize,
      26,
    );
    await tester.tap(
      find.byKey(const ValueKey('manga-translation-appearance-text-color')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(prefs.textColor, ReaderPrefs.defaultMangaTranslationTextColor);
    await tester.tap(
      find.byKey(
        const ValueKey('manga-translation-appearance-background-color'),
      ),
    );
    await tester.pumpAndSettle();
    tester
        .widget<ColorPicker>(find.byType(ColorPicker))
        .onColorChanged(Colors.red);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(prefs.backgroundColor, Colors.red);
    await tester.ensureVisible(find.text('Reset to defaults'));
    await tester.tap(find.text('Reset to defaults'));
    await tester.pumpAndSettle();
    expect(
      prefs.translationFontSize,
      ReaderPrefs.defaultMangaTranslationFontSize,
    );
    expect(
      prefs.backgroundOpacity,
      ReaderPrefs.defaultMangaTranslationBackgroundOpacity,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop appearance controls remain reachable at large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: DesktopSettingsScope(
              child: MangaTranslationAppearanceSheet(prefs: _AppearancePrefs()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Reset to defaults'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Reset to defaults').hitTestable(), findsOneWidget);
    final color = find.byKey(
      const ValueKey('manga-translation-appearance-text-color'),
    );
    await tester.ensureVisible(color);
    await tester.pumpAndSettle();
    await tester.tap(color);
    await tester.pumpAndSettle();
    expect(find.byType(ColorPicker), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('shows saved appearance and updates size and opacity', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final prefs = _AppearancePrefs();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MangaTranslationAppearanceSheet(prefs: prefs)),
      ),
    );

    expect(find.text('Translation preview'), findsNWidgets(2));
    expect(
      tester
          .widget<Slider>(
            find.byKey(const ValueKey('manga-translation-appearance-size')),
          )
          .value,
      20,
    );
    expect(
      tester
          .widget<Slider>(
            find.byKey(const ValueKey('manga-translation-appearance-opacity')),
          )
          .value,
      0.4,
    );

    await tester.drag(
      find.byKey(const ValueKey('manga-translation-appearance-size')),
      const Offset(80, 0),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final opacitySlider = find.byKey(
      const ValueKey('manga-translation-appearance-opacity'),
    );
    tester.widget<Slider>(opacitySlider).onChanged!(0.7);
    await tester.pump();
    tester.widget<Slider>(opacitySlider).onChangeEnd!(0.7);

    expect(prefs.mangaTranslationFontSize, isNot(20));
    expect(prefs.mangaTranslationBackgroundOpacity, isNot(0.4));
  });

  testWidgets('opens custom color pickers for translated text and background', (
    tester,
  ) async {
    final prefs = _AppearancePrefs();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MangaTranslationAppearanceSheet(prefs: prefs)),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('manga-translation-appearance-text-color')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Custom colour'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(
        const ValueKey('manga-translation-appearance-background-color'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Custom colour'), findsOneWidget);
  });
}

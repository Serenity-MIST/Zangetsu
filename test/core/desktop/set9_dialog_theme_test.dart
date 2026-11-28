import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/theme/theme_controller.dart';
import 'package:watch_app/core/ui/app_dialog.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// Swaps the background the way ThemeController does (Pure black etc.).
void _setBg(Color bg) {
  AppColors.bg = bg;
  ThemeController.revision.value++;
}

/// Opens a Windows settings AppDialog and returns its AlertDialog.
Future<AlertDialog> _openDialog(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: DesktopSettingsScope(
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                AppDialog.alert(context, title: 'Title', message: 'Body'),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return tester.widget<AlertDialog>(find.byType(AlertDialog));
}

void main() {
  tearDown(() => _setBg(AppColors.defaultBg));

  // set-9: the stock background keeps the original graphite greys.
  testWidgets('settings dialog keeps the stock greys by default', (
    tester,
  ) async {
    final dialog = await _openDialog(tester);
    expect(dialog.backgroundColor, const Color(0xFF1A1B20));
    final shape = dialog.shape! as RoundedRectangleBorder;
    expect(shape.side.color, const Color(0xFF36373E));
  });

  // set-9: with Pure black the dialog follows the frame, not fixed greys.
  testWidgets('settings dialog follows Pure black', (tester) async {
    _setBg(const Color(0xFF000000));
    final dialog = await _openDialog(tester);
    expect(dialog.backgroundColor, isNot(const Color(0xFF1A1B20)));
    expect(dialog.backgroundColor, GraphiteSettingsColors.dialog);
    final shape = dialog.shape! as RoundedRectangleBorder;
    expect(shape.side.color, GraphiteSettingsColors.dialogEdge);
  });
}

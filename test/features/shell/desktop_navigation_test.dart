import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/nav_prefs.dart';
import 'package:watch_app/features/shell/desktop_navigation.dart';
import 'package:watch_app/l10n/app_localizations.dart';

void main() {
  for (final expanded in [true, false]) {
    testWidgets(
      'desktop navigation selects configured destinations, expanded=$expanded',
      (tester) async {
        DockTab? picked;
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Row(
                children: [
                  DesktopNavigation(
                    tabs: const [
                      DockTab.home,
                      DockTab.sources,
                      DockTab.profile,
                    ],
                    active: DockTab.home,
                    expanded: expanded,
                    onSelected: (tab) => picked = tab,
                  ),
                  const Expanded(child: Text('Content')),
                ],
              ),
            ),
          ),
        );
        await tester.tap(find.byIcon(Icons.extension_rounded));
        expect(picked, DockTab.sources);
        expect(find.byIcon(Icons.download_rounded), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

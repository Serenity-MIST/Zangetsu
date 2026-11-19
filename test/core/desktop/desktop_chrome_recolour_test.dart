import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:watch_app/core/desktop/desktop_chrome_colors.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/theme/theme_controller.dart';
import 'package:watch_app/core/ui/nav_prefs.dart';
import 'package:watch_app/core/ui/settings_widgets.dart';
import 'package:watch_app/features/settings/desktop_settings_workspace.dart';
import 'package:watch_app/features/shell/desktop_shell_workspace.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// Local mode fixture so the shell's media pill builds without disk/network.
class _Mode extends Cubit<ContentMode> implements ContentModeCubit {
  _Mode() : super(ContentMode.anime);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A settings sub-page as the real ones are written: it reads its background
/// during build and is const, so only a forced rebuild can recolour it.
class _SubPage extends StatelessWidget {
  const _SubPage();
  @override
  Widget build(BuildContext context) => Scaffold(
    key: const ValueKey('sub-page'),
    backgroundColor: settingsPageBackground(context),
    appBar: settingsAppBar('Theme & colour'),
    body: const SizedBox.expand(),
  );
}

/// Pure black as ThemeController applies it: swap the static colour, then
/// bump the revision every listener rebuilds on.
void _setBg(Color bg) {
  AppColors.bg = bg;
  ThemeController.revision.value++;
}

Color _materialColor(WidgetTester tester, String key) =>
    tester.widget<Material>(find.byKey(ValueKey(key))).color!;

Color _railEdge(WidgetTester tester) {
  final box = tester.widget<Container>(
    find.byKey(const ValueKey('desktop-shell-rail')),
  );
  return ((box.decoration! as BoxDecoration).border! as Border).right.color;
}

void main() {
  tearDown(() => _setBg(AppColors.defaultBg));

  testWidgets('Pure black recolours the shell rail and top bar live', (
    tester,
  ) async {
    final mode = _Mode();
    GetIt.instance.registerSingleton<ContentModeCubit>(mode);
    addTearDown(() async {
      await GetIt.instance.reset();
      await mode.close();
    });
    await tester.binding.setSurfaceSize(const Size(1366, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DesktopShellWorkspace(
          active: DockTab.home,
          onSelected: (_) {},
          onSearch: (_) {},
          profile: const Icon(Icons.person),
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Untouched install: the original greys.
    expect(_materialColor(tester, 'desktop-shell-frame'), DesktopChrome.stockFrame);
    expect(_railEdge(tester), DesktopChrome.stockHairline);

    _setBg(const Color(0xFF000000));
    await tester.pump();

    expect(_materialColor(tester, 'desktop-shell-frame'), const Color(0xFF000000));
    final rail = tester.widget<Container>(
      find.byKey(const ValueKey('desktop-shell-rail')),
    );
    expect((rail.decoration! as BoxDecoration).color, const Color(0xFF000000));
    expect(_railEdge(tester), isNot(DesktopChrome.stockHairline));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pure black and Background colour recolour the settings frame, '
      'header and an open sub-page live', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopSettingsWorkspace(
          title: 'Settings',
          selectedId: 'interface',
          destinations: const [],
          onExit: () {},
          child: const _SubPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Color header() => tester
        .widget<AppBar>(
          find.descendant(
            of: find.byKey(const ValueKey('sub-page')),
            matching: find.byType(AppBar),
          ),
        )
        .backgroundColor!;
    Color page() =>
        tester.widget<Scaffold>(find.byKey(const ValueKey('sub-page'))).backgroundColor!;
    List<Color> sidebar() =>
        ((tester
                        .widget<Container>(
                          find.byKey(const ValueKey('desktop-settings-sidebar')),
                        )
                        .decoration!
                    as BoxDecoration)
                .gradient!
            as LinearGradient)
            .colors;

    expect(_materialColor(tester, 'desktop-settings-frame'), DesktopChrome.stockFrame);
    expect(header(), DesktopChrome.stockFrame);
    // Page body and header are one surface: no seam under the header.
    expect(page(), DesktopChrome.stockFrame);
    expect(sidebar().first, DesktopChrome.stockSidebarTop);

    _setBg(const Color(0xFF000000));
    await tester.pump();

    const black = Color(0xFF000000);
    expect(_materialColor(tester, 'desktop-settings-frame'), black);
    expect(header(), black);
    expect(page(), black);
    expect(sidebar().last, black);
    final theme = Theme.of(tester.element(find.byKey(const ValueKey('sub-page'))));
    expect(theme.scaffoldBackgroundColor, black);

    // A custom Background colour reaches the same surfaces.
    const navy = Color(0xFF101830);
    _setBg(navy);
    await tester.pump();
    // Page and header stay one surface (frame), now derived from the navy.
    expect(page(), DesktopChrome.frame);
    expect(page(), isNot(DesktopChrome.stockFrame));
    expect(header(), DesktopChrome.frame);
    expect(header(), isNot(DesktopChrome.stockFrame));
    expect(_materialColor(tester, 'desktop-settings-frame'), DesktopChrome.frame);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Outside the Windows settings workspace pages keep AppColors.bg', (
    tester,
  ) async {
    late Color bg;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            bg = settingsPageBackground(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(bg, AppColors.bg);
  });
}

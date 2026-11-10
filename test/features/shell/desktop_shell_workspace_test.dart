import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/desktop/desktop_media_selector.dart';
import 'package:watch_app/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/nav_prefs.dart';
import 'package:watch_app/features/shell/desktop_shell_workspace.dart';

/// Local mode fixture keeps shell geometry tests independent of disk/network.
class _Mode extends Cubit<ContentMode> implements ContentModeCubit {
  _Mode() : super(ContentMode.anime);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('extra sidebar page and Home share exclusive selected affordances', (tester) async {
    final mode=_Mode(); GetIt.instance.registerSingleton<ContentModeCubit>(mode);
    addTearDown(() async { await GetIt.instance.reset(); await mode.close(); });
    String? extra;
    await tester.pumpWidget(MaterialApp(home:StatefulBuilder(builder:(context,set) =>
      DesktopShellWorkspace(active:DockTab.home,activeShortcut:extra,
        onSelected:(_)=>set(()=>extra=null),onSearch:(_){},profile:const Icon(Icons.person),
        shortcuts:[(id:'genres',label:'Genres',icon:'tags',onTap:()=>set(()=>extra='genres'))],
        child:const Text('Page')))));
    await tester.pumpAndSettle();
    bool selected(String id) => tester.widget<Semantics>(
      find.byKey(ValueKey('desktop-selected-$id'))).properties.selected == true;
    expect(selected('home'),isTrue); expect(selected('genres'),isFalse);
    await tester.tap(find.byKey(const ValueKey('desktop-shortcut-genres'))); await tester.pump();
    expect(selected('home'),isFalse); expect(selected('genres'),isTrue);
    await tester.tap(find.byKey(const ValueKey('desktop-rail-home'))); await tester.pump();
    expect(selected('home'),isTrue); expect(selected('genres'),isFalse);
  });

  for (final size in [const Size(420,360),const Size(420,768),
      const Size(1366,360),const Size(1366,768)]) {
    final width=size.width;
    testWidgets('desktop rail and search dispatch once at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final mode = _Mode();
      GetIt.instance.registerSingleton<ContentModeCubit>(mode);
      addTearDown(() async {
        await GetIt.instance.reset();
        await mode.close();
      });
      final selected = <DockTab>[];
      final searches = <String>[];
      final shortcuts = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DesktopShellWorkspace(
            active: DockTab.home,
            onSelected: selected.add,
            onSearch: searches.add,
            onNotifications: () => shortcuts.add('notifications'),
            shortcuts: [for (final id in ['streaming','schedule','genres','downloads'])
              (id:id,label:id,icon:'download',onTap:() => shortcuts.add(id))],
            profile: const Icon(Icons.person_outline),
            child: const Text('Real page'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final pill = find.byType(DesktopMediaSelector);
      expect(pill, findsOneWidget);
      expect(tester.getSize(pill).width, lessThanOrEqualTo(430));
      if (width == 1366) {
        expect(tester.getRect(pill).right,
          lessThan(tester.getRect(find.byType(TextField)).left));
        expect(
          tester.getCenter(pill).dy,
          closeTo(tester.getCenter(find.byType(TextField)).dy, 3),
        );
      }
      await tester.tap(find.byKey(const ValueKey('desktop-rail-myList')));
      expect(selected, [DockTab.myList]);
      await tester.tap(find.byKey(const ValueKey('desktop-shell-profile')));
      expect(selected.last, DockTab.profile);
      await tester.enterText(find.byType(TextField), 'Frieren');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      expect(searches, ['Frieren']);
      for (final id in ['streaming','schedule','genres','downloads']) {
        await tester.ensureVisible(find.byKey(ValueKey('desktop-shortcut-$id')));
        await tester.tap(find.byKey(ValueKey('desktop-shortcut-$id')));
      }
      await tester.tap(find.byKey(const ValueKey('desktop-shell-notifications')));
      expect(shortcuts,['streaming','schedule','genres','downloads','notifications']);
      expect(find.descendant(of:pill,matching:find.byKey(
        const ValueKey('desktop-shell-notifications'))),findsNothing);
      expect(find.byKey(const ValueKey('desktop-rail-profile')), findsNothing);
      expect(find.byKey(const ValueKey('desktop-rail-search')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}

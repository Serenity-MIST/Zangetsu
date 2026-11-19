import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:watch_app/core/desktop/desktop_back_navigation.dart';
import 'package:watch_app/core/desktop/desktop_catalogue_switch.dart';
import 'package:watch_app/core/desktop/desktop_media_selector.dart';
import 'package:watch_app/core/desktop/desktop_shortcut_catalog.dart';
import 'package:watch_app/core/desktop/desktop_title_bar.dart';
import 'package:watch_app/core/desktop/desktop_window.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/sync/sync_status.dart';
import 'package:watch_app/core/ui/global_messenger.dart';
import 'package:watch_app/core/ui/nav_prefs.dart';
import 'package:watch_app/features/shell/desktop_shell_workspace.dart';
import 'package:watch_app/features/shell/desktop_sidebar_pages.dart';
import 'package:watch_app/features/shell/root_shell.dart';
import 'package:watch_app/features/shell/desktop_sync_indicator.dart';
import 'package:watch_app/l10n/app_localizations.dart';

/// Local mode fixture so the shell renders without disk or network.
class _Mode extends Cubit<ContentMode> implements ContentModeCubit {
  _Mode() : super(ContentMode.anime);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Registers the mode cubit the media pill reads, removed after the test.
void _registerMode() {
  final mode = _Mode();
  GetIt.instance.registerSingleton<ContentModeCubit>(mode);
  addTearDown(() async {
    await GetIt.instance.reset();
    await mode.close();
  });
}

Widget _app(Widget home) => MaterialApp(
  navigatorKey: rootNavigatorKey,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

/// Stands in for HomeScreen's catalogue publishing: publishes one choice
/// after its first frame and clears the switch when disposed, as Home does.
class _HomePublisher extends StatefulWidget {
  const _HomePublisher();
  @override
  State<_HomePublisher> createState() => _HomePublisherState();
}

class _HomePublisherState extends State<_HomePublisher> {
  @override
  void initState() {
    super.initState();
    // After the frame, like Home, because the switch's listeners rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      DesktopCatalogueSwitch.publish([
        DesktopCatalogueOption(
          id: 'anilist',
          label: 'AniList',
          group: 'Trackers',
          onSelect: () {},
        ),
      ], currentId: 'anilist');
    });
  }

  @override
  void dispose() {
    // Cleared after the frame: the switch's listeners rebuild widgets, which
    // the framework forbids while it is unmounting this one.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => DesktopCatalogueSwitch.clear(),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Text('Home page');
}

/// Runs a test with the Windows UI on (tests run as Android by default).
final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

void main() {
  setUp(() {
    registerDefaultDesktopShortcuts();
    SyncStatus.debugReset();
    DesktopCatalogueSwitch.clear();
    DesktopWindow.setAppActions(null);
  });

  group('compact rail', () {
    // The user removed History, the Settings gear and the expand chevron
    // from the Windows rail; it stays the compact icon rail.
    testWidgets('no History, Settings or toggle; fixed compact width', (
      tester,
    ) async {
      _registerMode();
      await tester.binding.setSurfaceSize(const Size(1366, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final selected = <DockTab>[];
      await tester.pumpWidget(
        _app(
          DesktopShellWorkspace(
            active: DockTab.home,
            onSelected: selected.add,
            onSearch: (_) {},
            profile: const Icon(Icons.person),
            child: const Text('Page'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(desktopRailTabs.map((e) => e.$1), [
        DockTab.home,
        DockTab.myList,
        DockTab.sources,
      ]);
      expect(find.byKey(const ValueKey('desktop-rail-history')), findsNothing);
      expect(find.byKey(const ValueKey('desktop-rail-settings')), findsNothing);
      expect(find.byKey(const ValueKey('desktop-rail-toggle')), findsNothing);
      // Icon-only rail: labels only as tooltips.
      expect(find.text('Home'), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('desktop-shell-rail'))).width,
        kDesktopRailCollapsed,
      );
      // Remaining rail items still select their tab.
      await tester.tap(find.byKey(const ValueKey('desktop-rail-myList')));
      expect(selected, [DockTab.myList]);
      expect(tester.takeException(), isNull);
    });
  });

  group('shell-9 bell badge', () {
    testWidgets('shows the unread count and hides at zero', (tester) async {
      _registerMode();
      final unread = ValueNotifier<int>(3);
      await tester.pumpWidget(
        _app(
          DesktopShellWorkspace(
            active: DockTab.home,
            onSelected: (_) {},
            onSearch: (_) {},
            onNotifications: () {},
            unreadNotifications: unread,
            profile: const Icon(Icons.person),
            child: const Text('Page'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Badge badge() => tester.widget<Badge>(
        find.byKey(const ValueKey('desktop-shell-notifications-badge')),
      );
      expect(badge().isLabelVisible, isTrue);
      expect(find.text('3'), findsOneWidget);
      unread.value = 0;
      await tester.pump();
      expect(badge().isLabelVisible, isFalse);
    });
  });

  group('shell-13 / home-6 media pill', () {
    testWidgets('no blur, catalogue button hidden until published', (
      tester,
    ) async {
      _registerMode();
      await tester.pumpWidget(
        _app(const Scaffold(body: Center(child: DesktopMediaSelector()))),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      expect(
        find.byKey(const ValueKey('desktop-catalogue-switch')),
        findsNothing,
      );
    });

    testWidgets('lists catalogues by group with a tick and switches', (
      tester,
    ) async {
      _registerMode();
      final picked = <String>[];
      DesktopCatalogueSwitch.publish([
        DesktopCatalogueOption(
          id: 'anilist',
          label: 'AniList',
          group: 'Trackers',
          icon: Icons.list,
          onSelect: () => picked.add('anilist'),
        ),
        DesktopCatalogueOption(
          id: 'stremio',
          label: 'Stremio',
          group: 'Extensions',
          onSelect: () => picked.add('stremio'),
        ),
      ], currentId: 'anilist');
      await tester.pumpWidget(
        _app(const Scaffold(body: Center(child: DesktopMediaSelector()))),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('desktop-catalogue-switch'));
      expect(button, findsOneWidget);
      expect(find.text('AniList'), findsOneWidget);
      await tester.tap(button);
      await tester.pumpAndSettle();
      // Group headings appear as rows in the menu.
      expect(find.text('Trackers'), findsOneWidget);
      expect(find.text('Extensions'), findsOneWidget);
      await tester.tap(find.text('Stremio'));
      await tester.pumpAndSettle();
      expect(picked, ['stremio']);
    });

    // pill: the pill names only the catalogue ('AniList'); the menu keeps the
    // full 'AniList catalogue' label.
    testWidgets('pill shows the short name, menu the full label', (
      tester,
    ) async {
      _registerMode();
      DesktopCatalogueSwitch.publish([
        DesktopCatalogueOption(
          id: 'meta:anime:anilist',
          label: 'AniList catalogue',
          shortLabel: 'AniList',
          group: 'Catalogues',
          icon: Icons.list,
          onSelect: () {},
        ),
        // No short label: the pill falls back to the full source name.
        DesktopCatalogueOption(
          id: 'source:long',
          label: 'AnimePahe Plus',
          group: 'Extensions',
          onSelect: () {},
        ),
      ], currentId: 'meta:anime:anilist');
      await tester.pumpWidget(
        _app(const Scaffold(body: Center(child: DesktopMediaSelector()))),
      );
      await tester.pumpAndSettle();
      expect(find.text('AniList'), findsOneWidget);
      expect(find.text('AniList catalogue'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('desktop-catalogue-switch')));
      await tester.pumpAndSettle();
      expect(find.text('AniList catalogue'), findsOneWidget);
      // Close the menu, switch to the long source and check it is not cut.
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      DesktopCatalogueSwitch.currentId.value = 'source:long';
      await tester.pumpAndSettle();
      final text = find.text('AnimePahe Plus');
      expect(text, findsOneWidget);
      final painter = TextPainter(
        text: const TextSpan(
          text: 'AnimePahe Plus',
          style: TextStyle(fontSize: 13),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      // The label box is at least as wide as the unclipped text.
      expect(
        tester.getSize(text).width,
        greaterThanOrEqualTo(painter.width - 0.5),
      );
      painter.dispose();
    });

    // historybugs: the picker vanished on History / Settings because Home,
    // its only publisher, was unmounted there (lazy tabs) and cleared it on
    // dispose. The shell now keeps Home mounted on Windows; with the
    // publisher mounted under the in-frame pages, the picker stays on every
    // page that shows the pill.
    testWidgets('picker stays while an in-frame page is shown', variant: _windows, (
      tester,
    ) async {
      _registerMode();
      await tester.binding.setSurfaceSize(const Size(1366, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? page;
      var homeMounted = true;
      late StateSetter update;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, set) {
              update = set;
              return DesktopShellWorkspace(
                active: DockTab.profile,
                onSelected: (_) {},
                onSearch: (_) {},
                profile: const Icon(Icons.person),
                child: DesktopSidebarPages(
                  selected: page,
                  builders: {
                    'history': (_) => const Text('History page'),
                    'settings': (_) => const Text('Settings page'),
                  },
                  fallback: homeMounted
                      ? const _HomePublisher()
                      : const Text('Profile page'),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final picker = find.byKey(const ValueKey('desktop-catalogue-switch'));
      expect(picker, findsOneWidget);
      for (final next in ['history', 'settings', null]) {
        update(() => page = next);
        await tester.pumpAndSettle();
        expect(picker, findsOneWidget, reason: 'page $next');
      }
      // The old behaviour, for contrast: once Home is unmounted the picker
      // goes, which is why the shell must keep Home mounted.
      update(() {
        homeMounted = false;
        page = 'history';
      });
      await tester.pumpAndSettle();
      expect(picker, findsNothing);
      expect(tester.takeException(), isNull);
    });

    test('Windows keeps Home mounted; phones keep it lazy', () {
      const tabs = [DockTab.home, DockTab.myList, DockTab.profile];
      expect(desktopKeepsHomeMounted(windowsUi: true, tabs: tabs), isTrue);
      expect(desktopKeepsHomeMounted(windowsUi: false, tabs: tabs), isFalse);
      // No Home tab, nothing to keep.
      expect(
        desktopKeepsHomeMounted(
          windowsUi: true,
          tabs: const [DockTab.myList, DockTab.profile],
        ),
        isFalse,
      );
    });

    // pill: in the shell's width-capped pill a long source name ellipsizes
    // inside the room the tabs leave, so the chip (and its chevron) is never
    // hard-clipped by the pill's scroll view.
    testWidgets('long source name fits the capped pill', (tester) async {
      _registerMode();
      await tester.binding.setSurfaceSize(const Size(1000, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      DesktopCatalogueSwitch.publish([
        DesktopCatalogueOption(
          id: 'source:huge',
          label: 'A Very Long Extension Source Name',
          group: 'Extensions',
          onSelect: () {},
        ),
      ], currentId: 'source:huge');
      await tester.pumpWidget(
        _app(
          const Scaffold(
            body: Center(
              child: SizedBox(width: 700, child: DesktopMediaSelector()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(DesktopMediaSelector),
          matching: find.byType(Scrollable),
        ),
      );
      // Nothing spills past the pill: no horizontal scrolling needed.
      expect(scroll.position.maxScrollExtent, 0);
      // The name itself was shortened (ellipsis), not left at full width.
      final name = find.text('A Very Long Extension Source Name');
      expect(tester.getSize(name).width, lessThanOrEqualTo(200));
    });
  });

  group('shell-7 / shell-6 / acct-3 window keys', () {
    // Sends one key-down through DesktopWindow's handler while Ctrl / Alt
    // are held as given.
    Future<KeyEventResult> press(
      WidgetTester tester,
      LogicalKeyboardKey key, {
      bool control = false,
      bool alt = false,
      String? character,
    }) async {
      if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      final result = DesktopWindow.handleAppKey(
        KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: key,
          character: character,
          timeStamp: Duration.zero,
        ),
      );
      if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      return result;
    }

    testWidgets('app actions run, typing keys stay in text fields', variant: _windows, (
      tester,
    ) async {
      final calls = <String>[];
      DesktopWindow.setAppActions({
        'app.search': () => calls.add('search'),
        'app.section2': () => calls.add('section2'),
        'app.mode3': () => calls.add('mode3'),
        'app.settings': () => calls.add('settings'),
        'app.history': () => calls.add('history'),
      });
      final field = FocusNode();
      addTearDown(field.dispose);
      await tester.pumpWidget(
        _app(Scaffold(body: TextField(focusNode: field))),
      );
      expect(
        await press(tester, LogicalKeyboardKey.keyF, control: true),
        KeyEventResult.handled,
      );
      await press(tester, LogicalKeyboardKey.digit2, control: true);
      await press(tester, LogicalKeyboardKey.digit3, alt: true);
      await press(tester, LogicalKeyboardKey.comma, control: true);
      // Ctrl+H opens History (it left the sidebar).
      await press(tester, LogicalKeyboardKey.keyH, control: true);
      expect(calls, ['search', 'section2', 'mode3', 'settings', 'history']);
      // '/' outside a field focuses search; inside a field it is typing.
      await press(tester, LogicalKeyboardKey.slash, character: '/');
      expect(calls.last, 'search');
      calls.clear();
      field.requestFocus();
      await tester.pump();
      expect(
        await press(tester, LogicalKeyboardKey.slash, character: '/'),
        KeyEventResult.ignored,
      );
      expect(calls, isEmpty);
    });

    testWidgets('F5 falls back to a sync only when a sync owner exists', variant: _windows, (
      tester,
    ) async {
      await tester.pumpWidget(_app(const SizedBox()));
      expect(
        await press(tester, LogicalKeyboardKey.f5),
        KeyEventResult.ignored,
      );
      var syncs = 0;
      SyncStatus.onSyncRequested = () async => syncs++;
      expect(await press(tester, LogicalKeyboardKey.f5), KeyEventResult.handled);
      await tester.pump();
      expect(syncs, 1);
      expect(SyncStatus.state.value, SyncState.synced);
    });

    testWidgets('phone keeps none of it', (tester) async {
      DesktopWindow.setAppActions({'app.search': () => fail('ran on phone')});
      await tester.pumpWidget(_app(const SizedBox()));
      expect(
        await press(tester, LogicalKeyboardKey.keyF, control: true),
        KeyEventResult.ignored,
      );
    });

    testWidgets('Alt+Left and mouse Back pop the top page, never the root', variant: _windows, (
      tester,
    ) async {
      await tester.pumpWidget(_app(const Text('Root')));
      rootNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('Detail')),
      );
      await tester.pumpAndSettle();
      expect(
        await press(tester, LogicalKeyboardKey.arrowLeft, alt: true),
        KeyEventResult.handled,
      );
      await tester.pumpAndSettle();
      expect(find.text('Root'), findsOneWidget);
      expect(find.text('Detail'), findsNothing);

      // Mouse Back on a second page pops it too.
      rootNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('Detail 2')),
      );
      await tester.pumpAndSettle();
      DesktopMouseBack.snapshot();
      DesktopWindow.handlePointerDown(
        const PointerDownEvent(
          kind: PointerDeviceKind.mouse,
          buttons: kBackMouseButton,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Detail 2'), findsNothing);
      // At the root nothing can pop: the app stays.
      await press(tester, LogicalKeyboardKey.arrowLeft, alt: true);
      await tester.pumpAndSettle();
      expect(find.text('Root'), findsOneWidget);
    });

    testWidgets('mouse Back leaves screens that own the button alone', variant: _windows, (
      tester,
    ) async {
      await tester.pumpWidget(_app(const Text('Root')));
      rootNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              const DesktopMouseBackOwner(child: Text('Reader')),
        ),
      );
      await tester.pumpAndSettle();
      DesktopMouseBack.snapshot();
      DesktopWindow.handlePointerDown(
        const PointerDownEvent(
          kind: PointerDeviceKind.mouse,
          buttons: kBackMouseButton,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Reader'), findsOneWidget);
      // A screen that already popped its route for the press is not
      // popped a second time.
      final page = rootNavigatorKey.currentState!;
      page.push(MaterialPageRoute<void>(builder: (_) => const Text('Player')));
      await tester.pumpAndSettle();
      DesktopMouseBack.snapshot();
      page.pop();
      DesktopWindow.handlePointerDown(
        const PointerDownEvent(
          kind: PointerDeviceKind.mouse,
          buttons: kBackMouseButton,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Reader'), findsOneWidget);
    });
  });

  group('acct-3 sync feedback (no title-bar icon)', () {
    // Answers the window channel the title bar reads on start-up.
    void mockWindowChannel(WidgetTester tester) {
      const channel = MethodChannel('com.spyou.zangetsu/window');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => false,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
    }

    testWidgets('title bar has no sync icon and sync never shows a toast', variant: _windows, (
      tester,
    ) async {
      mockWindowChannel(tester);
      await tester.pumpWidget(_app(const Scaffold(body: DesktopTitleBar())));
      expect(find.byKey(const ValueKey('desktop-shell-sync')), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      // Sync is background-only: the title bar mounts no sync listener.
      expect(find.byType(DesktopSyncIndicator), findsNothing);
      // Every sync state stays silent, failures and sign-in included.
      SyncStatus.report(SyncState.syncing);
      SyncStatus.report(SyncState.error);
      SyncStatus.report(SyncState.needsSignIn);
      SyncStatus.report(SyncState.synced);
      await tester.pump();
      expect(find.byKey(const ValueKey('desktop-sync-toast')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed sync toasts once with Retry', variant: _windows, (
      tester,
    ) async {
      var syncs = 0;
      SyncStatus.onSyncRequested = () async => syncs++;
      await tester.pumpWidget(
        _app(const Scaffold(body: Center(child: DesktopSyncIndicator()))),
      );
      SyncStatus.report(SyncState.syncing);
      SyncStatus.report(SyncState.error, error: 'boom');
      await tester.pump();
      final toast = find.byKey(const ValueKey('desktop-sync-toast'));
      expect(toast, findsOneWidget);
      expect(find.textContaining('boom'), findsOneWidget);
      // Retry runs a sync and closes the toast.
      await tester.tap(find.byKey(const ValueKey('desktop-sync-toast-action')));
      await tester.pump();
      expect(syncs, 1);
      expect(toast, findsNothing);
      // That retry succeeded, which resets the quiet period; fail again.
      SyncStatus.report(SyncState.syncing);
      SyncStatus.report(SyncState.error, error: 'boom');
      await tester.pump();
      expect(toast, findsOneWidget);
      // It goes away by itself.
      await tester.pump(DesktopSyncIndicator.toastDuration);
      expect(toast, findsNothing);
      // The same error straight after stays quiet.
      SyncStatus.report(SyncState.syncing);
      SyncStatus.report(SyncState.error, error: 'boom');
      await tester.pump();
      expect(toast, findsNothing);
      // A different error does show.
      SyncStatus.report(SyncState.syncing);
      SyncStatus.report(SyncState.error, error: 'other');
      await tester.pump();
      expect(toast, findsOneWidget);
      await tester.pump(DesktopSyncIndicator.toastDuration);
      expect(toast, findsNothing);
    });

    testWidgets('needs sign-in after a sync offers Sign in; startup is silent', variant: _windows, (
      tester,
    ) async {
      var signIns = 0;
      DesktopSyncIndicator.signInHandler = () => signIns++;
      addTearDown(() => DesktopSyncIndicator.signInHandler = null);
      await tester.pumpWidget(
        _app(const Scaffold(body: Center(child: DesktopSyncIndicator()))),
      );
      final toast = find.byKey(const ValueKey('desktop-sync-toast'));
      // Signed out at startup (idle -> needs sign-in): no nagging.
      SyncStatus.report(SyncState.needsSignIn);
      await tester.pump();
      expect(toast, findsNothing);
      // A sync that ends needing sign-in (expired session) does toast.
      SyncStatus.report(SyncState.syncing);
      SyncStatus.report(SyncState.needsSignIn);
      await tester.pump();
      expect(toast, findsOneWidget);
      expect(find.text('Sign in to sync your list and progress'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('desktop-sync-toast-action')));
      await tester.pump();
      expect(signIns, 1);
      expect(toast, findsNothing);
      expect(
        DesktopSyncIndicator.tooltipFor(SyncState.offline, null, null),
        contains('Offline'),
      );
    });
  });
}

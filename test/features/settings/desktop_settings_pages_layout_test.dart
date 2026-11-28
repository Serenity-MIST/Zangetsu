// Windows settings: every page must sit where the Reader page does. The real
// Settings screen is pumped at 1366x768 and the laid-out rects and text styles
// of the section pages, Window & system and Keyboard shortcuts are compared
// with the Reader page's, so none can drift back into its own column, width
// or spacing.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/desktop/desktop_chrome_colors.dart';
import 'package:watch_app/core/desktop/desktop_prefs.dart';
import 'package:watch_app/core/desktop/desktop_shortcut_catalog.dart';
import 'package:watch_app/core/desktop/desktop_shortcuts.dart';
import 'package:watch_app/core/discord/discord_rpc.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/core/locale/locale_controller.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/theme/app_theme.dart';
import 'package:watch_app/core/theme/theme_controller.dart';
import 'package:watch_app/core/torrent/torrent_prefs.dart';
import 'package:watch_app/core/tracker/mal_service.dart';
import 'package:watch_app/core/tracker/mangabaka_service.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';
import 'package:watch_app/core/ui/desktop_settings_row_target.dart';
import 'package:watch_app/core/ui/desktop_settings_surface.dart';
import 'package:watch_app/core/ui/nav_prefs.dart';
import 'package:watch_app/core/ui/settings_widgets.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/profiles/viewer_profiles_screen.dart';
import 'package:watch_app/features/settings/connected_services_screen.dart';
import 'package:watch_app/features/settings/contributors_screen.dart';
import 'package:watch_app/features/settings/discord_settings_screen.dart';
import 'package:watch_app/features/settings/download_location_screen.dart';
import 'package:watch_app/features/settings/manual_matches_screen.dart';
import 'package:watch_app/features/settings/tracker_settings_screen.dart';
import 'package:watch_app/features/settings/desktop_settings_profile.dart';
import 'package:watch_app/features/settings/keyboard_shortcuts_screen.dart';
import 'package:watch_app/features/settings/reader_settings_screen.dart';
import 'package:watch_app/features/settings/settings_screen.dart';
import 'package:watch_app/features/settings/window_system_settings_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';
import 'package:watch_app/l10n/ui_strings.dart';

/// Font size, weight, line height and colour of a text as it is drawn.
typedef TextLook = ({
  double? size,
  FontWeight? weight,
  double? height,
  Color? color,
});

/// A section title and the card under it.
typedef SectionLook = ({
  double left,
  TextLook look,
  double gapToCard,
  double cardLeft,
  double cardWidth,
});

/// Where the parts of one row are. Everything but [left] is relative to the
/// row's corner, because the pages scroll independently.
typedef RowLook = ({
  double left,
  double width,
  double height,
  Rect icon,
  Offset title,
  TextLook titleLook,
  Offset? subtitle,
  TextLook? subtitleLook,
});

class _StubSearchPrefs extends SearchPrefs {
  @override
  SearchLayout get layout => SearchLayout.vertical;
}

class _StubProviderRegistry implements ProviderRegistry {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<ProviderRegistryEntry> getAll() => const [];

  @override
  ProviderRegistryEntry? entryFor(String sourceId) => null;

  @override
  Set<String> nsfwSourceIds() => const {};
}

/// What the Connections and tracker pages read of a tracker that is not
/// signed in. Nothing here talks to a service.
mixin _SignedOutTracker on ChangeNotifier {
  bool get isConnected => false;
  String? get viewerName => null;
  String? get viewerAvatar => null;
  String? get lastConnectionError => null;
  bool get autoSync => true;
  set autoSync(bool value) {}
}

class _StubAniList extends ChangeNotifier
    with _SignedOutTracker
    implements AniListService {
  @override
  String get displayName => 'AniList';
  @override
  bool get supportsReading => true;
  @override
  bool get signInExpired => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubMal extends ChangeNotifier
    with _SignedOutTracker
    implements MalService {
  @override
  String get displayName => 'MyAnimeList';
  @override
  bool get supportsReading => true;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubSimkl extends ChangeNotifier
    with _SignedOutTracker
    implements SimklService {
  @override
  String get displayName => 'Simkl';
  @override
  bool get supportsReading => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubMangaBaka extends ChangeNotifier
    with _SignedOutTracker
    implements MangaBakaService {
  @override
  String get displayName => 'MangaBaka';
  @override
  bool get supportsReading => true;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// The sections that open a list of rows (the others open one page directly).
const landings = ['account', 'sources', 'downloads', 'interface', 'advanced'];

void main() {
  late Directory dir;
  late ActiveSourceCubit activeCubit;

  setUpAll(() async {
    // The real Windows UI font when it is there, so one-line texts fit on
    // one line as they do in the app (the test font is twice as wide).
    const faces = ['segoeui.ttf', 'seguisb.ttf', 'segoeuib.ttf'];
    final files = [for (final f in faces) File('C:/Windows/Fonts/$f')];
    if (!files.every((f) => f.existsSync())) return;
    for (final family in ['System', 'Segoe UI']) {
      final loader = FontLoader(family);
      for (final f in files) {
        loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
      }
      await loader.load();
    }
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('settings_layout');
    Hive.init(dir.path);
    // In-memory boxes: a write started inside the tester's fake clock never
    // finishes on disk, which would hang the tear-down.
    for (final name in [
      DownloadPrefs.boxName,
      TorrentPrefs.boxName,
      ThemeController.boxName,
      LocaleController.boxName,
      PlaybackPrefs.boxName,
      NavPrefs.boxName,
    ]) {
      await Hive.openBox(name, bytes: Uint8List(0));
    }
    await Hive.openBox<dynamic>(DesktopPrefs.boxName, bytes: Uint8List(0));
    await Hive.openBox<dynamic>(DiscordRpc.boxName, bytes: Uint8List(0));
    await Hive.openBox<Map>(MatchStore.boxName, bytes: Uint8List(0));
    DesktopShortcuts.debugReset();
    await DesktopPrefs.init();
    await LocaleController.init();
    await ReaderPrefs.init();
    await NavPrefs.init();
    await ViewerProfileStore.init();
    GetIt.instance
      ..registerSingleton<NavPrefs>(NavPrefs())
      ..registerSingleton<ViewerProfileStore>(ViewerProfileStore())
      ..registerSingleton<AppMode>(AppMode(isTv: false))
      ..registerSingleton<SearchPrefs>(_StubSearchPrefs())
      ..registerSingleton<ProviderRegistry>(_StubProviderRegistry())
      ..registerSingleton<AniListService>(_StubAniList())
      ..registerSingleton<MalService>(_StubMal())
      ..registerSingleton<SimklService>(_StubSimkl())
      ..registerSingleton<MangaBakaService>(_StubMangaBaka())
      ..registerSingleton<PlaybackPrefs>(PlaybackPrefs())
      ..registerSingleton<DownloadPrefs>(DownloadPrefs())
      ..registerSingleton<TorrentPrefs>(TorrentPrefs())
      ..registerSingleton<ReaderPrefs>(ReaderPrefs())
      ..registerSingleton<DiscordRpc>(DiscordRpc(Dio()))
      ..registerSingleton<MatchStore>(await MatchStore.open());
    activeCubit = ActiveSourceCubit();
    SettingsScreen.debugDesktopWorkspaceOverride = true;
  });

  tearDown(() async {
    SettingsScreen.debugDesktopWorkspaceOverride = null;
    debugDefaultTargetPlatformOverride = null;
    DesktopSettingsRowTargets.debugReset();
    await activeCubit.close();
    await GetIt.instance.reset();
    DesktopShortcuts.debugReset();
    await Hive.close();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  /// The real Settings screen under a 46px title bar, as in the app.
  Future<void> pumpSettings(
    WidgetTester tester, {
    Size window = const Size(1366, 768),
    double textScale = 1,
  }) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final auth = AuthCubit(SupabaseService());
    addTearDown(auth.close);
    GetIt.instance.registerSingleton<AuthCubit>(auth);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthCubit>.value(value: auth),
          BlocProvider<ActiveSourceCubit>.value(value: activeCubit),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const RepaintBoundary(
            key: ValueKey('layout-shot'),
            child: Column(
              children: [
                SizedBox(height: 46),
                Expanded(child: SettingsScreen()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Opens a section from the sidebar.
  Future<void> openSection(WidgetTester tester, String id) async {
    final item = find.byKey(ValueKey('desktop-nav-$id'));
    await tester.ensureVisible(item);
    await tester.pumpAndSettle();
    await tester.tap(item);
    await tester.pumpAndSettle();
  }

  /// The settings row titled [title].
  Finder rowOf(String title) => find.ancestor(
    of: find.text(title),
    matching: find.byType(GraphiteSettingsControl),
  );

  /// The scroll view of the page that is showing.
  Finder pageScroll() => find
      .byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      )
      .last;

  /// Scrolls the row titled [title] into view, from the top of the page.
  Future<void> reveal(WidgetTester tester, String title) async {
    tester.state<ScrollableState>(pageScroll()).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      rowOf(title).hitTestable(),
      120,
      scrollable: pageScroll(),
    );
    await tester.pumpAndSettle();
  }

  /// Reveals the row titled [title] and taps it. Taps the row's own title,
  /// since a section row can share its name with the sidebar item and the
  /// page heading (upstream's "Connected services").
  Future<void> openRow(WidgetTester tester, String title) async {
    await reveal(tester, title);
    await tester.tap(
      find.descendant(of: rowOf(title), matching: find.text(title)).first,
    );
    await tester.pumpAndSettle();
  }

  Future<void> openWindowSystem(WidgetTester tester) async {
    await openSection(tester, 'advanced');
    await openRow(tester, 'Window & system');
    expect(find.byType(WindowSystemSettingsScreen), findsOneWidget);
  }

  Future<void> openShortcuts(WidgetTester tester) async {
    await openSection(tester, 'advanced');
    await openRow(tester, 'Keyboard shortcuts');
    expect(find.byType(KeyboardShortcutsScreen), findsOneWidget);
  }

  Future<void> openReader(WidgetTester tester) async {
    await openSection(tester, 'reading');
    expect(find.byType(ReaderSettingsScreen), findsOneWidget);
  }

  TextLook lookOf(WidgetTester tester, Finder text) {
    final style = tester
        .renderObject<RenderParagraph>(
          find.descendant(of: text, matching: find.byType(RichText)),
        )
        .text
        .style!;
    return (
      size: style.fontSize,
      weight: style.fontWeight,
      height: style.height,
      color: style.color,
    );
  }

  /// The drawn card (border included, margin not) of a settings panel.
  Rect cardRect(WidgetTester tester, Finder panel) => tester.getRect(
    find.descendant(of: panel, matching: find.byType(DecoratedBox)).first,
  );

  /// The [index]th section title and the card under it.
  SectionLook measureSection(WidgetTester tester, int index) {
    final text = find.descendant(
      of: find.byType(SettingsSectionLabel).at(index),
      matching: find.byType(Text),
    );
    final title = tester.getRect(text);
    final cards = [
      for (final e in find.byType(GraphiteSettingsPanel).evaluate())
        cardRect(tester, find.byWidget(e.widget)),
    ];
    final card = cards.firstWhere((c) => c.top >= title.bottom);
    return (
      left: title.left,
      look: lookOf(tester, text),
      gapToCard: card.top - title.bottom,
      cardLeft: card.left,
      cardWidth: card.width,
    );
  }

  /// Reveals the row titled [title] and measures it.
  Future<RowLook> measureRow(WidgetTester tester, String title) async {
    await reveal(tester, title);
    final row = rowOf(title);
    final titleText = find.descendant(of: row, matching: find.text(title));
    final rowRect = tester.getRect(row);
    final origin = rowRect.topLeft;
    final icon = find.descendant(of: row, matching: find.byType(Icon)).first;
    final subtitleData = tester.widget<GraphiteSettingsControl>(row).subtitle;
    final subtitle = subtitleData == null
        ? null
        : find.descendant(of: row, matching: find.text(subtitleData));
    return (
      left: rowRect.left,
      width: rowRect.width,
      height: rowRect.height,
      icon: tester.getRect(icon).shift(-origin),
      title: tester.getTopLeft(titleText) - origin,
      titleLook: lookOf(tester, titleText),
      subtitle: subtitle == null ? null : tester.getTopLeft(subtitle) - origin,
      subtitleLook: subtitle == null ? null : lookOf(tester, subtitle),
    );
  }

  /// The value text (its right edge and look) and chevron of a choice row.
  Future<
    ({double right, TextLook look, double chevronLeft, double chevronRight})
  >
  measureValue(WidgetTester tester, String title, String value) async {
    await reveal(tester, title);
    final row = rowOf(title);
    final text = find.descendant(of: row, matching: find.text(value)).last;
    final chevron = tester.getRect(
      find.descendant(
        of: row,
        matching: find.byIcon(Icons.chevron_right_rounded),
      ),
    );
    return (
      right: tester.getRect(text).right,
      look: lookOf(tester, text),
      chevronLeft: chevron.left,
      chevronRight: chevron.right,
    );
  }

  Future<Rect> switchRect(WidgetTester tester, String title) async {
    await reveal(tester, title);
    return tester.getRect(
      find.descendant(of: rowOf(title), matching: find.byType(Switch)),
    );
  }

  windowsTest('section titles and cards sit where Reader has them', (
    tester,
  ) async {
    await pumpSettings(tester);
    await openReader(tester);
    final reader = measureSection(tester, 0);
    final readerTop = tester
        .getTopLeft(find.byType(SettingsSectionLabel).first)
        .dy;
    _report('section Reader', reader);
    await _shot(tester, 'reader');
    expect(reader.cardLeft, 258);
    expect(reader.cardWidth, kDesktopSettingsContentMaxWidth);
    expect(reader.left, 260);

    await openSection(tester, 'interface');
    await _shot(tester, 'interface');
    final labels = find.byType(SettingsSectionLabel);
    expect(labels, findsNWidgets(3));
    for (var i = 0; i < 3; i++) {
      final s = measureSection(tester, i);
      _report('section $i Interface', s);
      expect(s, reader, reason: 'Interface section $i');
    }

    await openWindowSystem(tester);
    await _shot(tester, 'window_system');
    for (var i = 0; i < 2; i++) {
      final s = measureSection(tester, i);
      _report('section $i Window & system', s);
      expect(s, reader, reason: 'Window & system section $i');
    }
    expect(
      tester.getTopLeft(find.byType(SettingsSectionLabel).first).dy,
      readerTop,
    );

    await openShortcuts(tester);
    await _shot(tester, 'shortcuts');
    final shortcuts = measureSection(tester, 0);
    _report('section Keyboard shortcuts', shortcuts);
    expect(shortcuts, reader);
    final search = tester.getRect(
      find.descendant(
        of: find.byType(KeyboardShortcutsScreen),
        matching: find.byType(TextField),
      ),
    );
    _report('search box Keyboard shortcuts', search);
    expect(search.left, reader.cardLeft);
    expect(search.width, reader.cardWidth);
  });

  windowsTest('every landing page lines its heading up with its cards', (
    tester,
  ) async {
    await pumpSettings(tester);
    for (final section in landings) {
      await openSection(tester, section);
      await _shot(tester, 'landing_$section');
      final body = find.byKey(ValueKey('desktop-section-$section'));
      final heading = find.descendant(of: body, matching: find.byType(Text));
      expect(tester.getTopLeft(heading.at(0)).dx, 258, reason: section);
      expect(tester.getTopLeft(heading.at(1)).dx, 258, reason: section);
      final panels = find.byType(GraphiteSettingsPanel);
      expect(panels, findsWidgets, reason: section);
      for (var i = 0; i < panels.evaluate().length; i++) {
        final card = cardRect(tester, panels.at(i));
        _report('card $i $section', card);
        expect(card.left, 258, reason: section);
        expect(card.width, kDesktopSettingsContentMaxWidth, reason: section);
      }
    }
    await openSection(tester, 'account');
    // Starts at the card's left padding, not in the middle of it.
    expect(tester.getTopLeft(find.text('Switch profile')).dx, 258 + 1 + 22);
    final profile = tester.getRect(
      find
          .descendant(
            of: find.byType(DesktopSettingsProfile),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    expect(profile.left, 258);
    expect(profile.width, kDesktopSettingsContentMaxWidth);
  });

  windowsTest('rows match the Reader rows', (tester) async {
    await pumpSettings(tester);
    await openReader(tester);
    // One line and a value; two lines and a switch; two lines alone.
    final oneLine = await measureRow(tester, 'Reading mode');
    final toggle = await measureRow(tester, 'Double-page (landscape)');
    final twoLines = await measureRow(tester, 'Click zones');
    _report('row Reader: Reading mode', oneLine);
    _report('row Reader: Double-page', toggle);
    _report('row Reader: Click zones', twoLines);

    Future<void> same(String page, String title, RowLook reader) async {
      final row = await measureRow(tester, title);
      _report('row $page: $title', row);
      expect(row, reader, reason: '$page: $title');
    }

    await openSection(tester, 'interface');
    for (final title in const [
      'Theme & colour',
      'Splash screen',
      'Poster cards',
      'Start page',
      'My List style',
      'Search layout',
    ]) {
      await same('Interface', title, twoLines);
    }
    for (final (section, title) in const [
      // Upstream renamed the Account row to its section title.
      ('account', 'Connected services'),
      ('sources', 'Providers'),
      ('downloads', 'Downloads'),
      ('downloads', 'Storage'),
      ('advanced', 'Window & system'),
      ('advanced', 'Privacy'),
    ]) {
      await openSection(tester, section);
      await same(section, title, twoLines);
    }
    await openSection(tester, 'sources');
    await same('sources', 'Auto-update extensions', toggle);

    await openWindowSystem(tester);
    await same('Window & system', 'Launch at sign-in', toggle);
    await same('Window & system', 'Close button', twoLines);
    await same('Window & system', 'Start page', twoLines);
    await same('Window & system', 'New-episode alerts', toggle);
    await same('Window & system', 'Keyboard shortcuts', twoLines);

    // Key caps are 3px taller than the Reader's one-line rows; every column
    // and text style is the same.
    await openShortcuts(tester);
    for (final title in const ['Search', 'Go to sidebar item 1']) {
      final row = await measureRow(tester, title);
      _report('row Keyboard shortcuts: $title', row);
      expect(row.left, oneLine.left);
      expect(row.width, oneLine.width);
      expect(row.icon.left, oneLine.icon.left);
      expect(row.icon.size, oneLine.icon.size);
      expect(row.title.dx, oneLine.title.dx);
      expect(row.titleLook, oneLine.titleLook);
      expect(row.height - oneLine.height, inInclusiveRange(0, 4));
    }
  });

  windowsTest('values, chevrons, switches and keys end at one right edge', (
    tester,
  ) async {
    await pumpSettings(tester);
    await openReader(tester);
    final reader = await measureValue(tester, 'Fit', 'Contain');
    _report('value Reader', reader);
    final readerSwitch = await switchRect(tester, 'Double-page (landscape)');
    _report('switch Reader', readerSwitch);
    expect(reader.chevronRight, 1154);
    expect(readerSwitch.right, 1154);

    Future<void> same(String title, String value) async {
      final v = await measureValue(tester, title, value);
      _report('value $title', v);
      expect(v, reader, reason: title);
    }

    await openSection(tester, 'interface');
    await same('Theme & colour', 'Default');
    // The colour dot stands right before the value, in the right-hand group.
    final dot = tester.getRect(
      find.descendant(
        of: rowOf('Theme & colour'),
        matching: find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).shape == BoxShape.circle &&
              (w.decoration as BoxDecoration).color == AppColors.accent,
        ),
      ),
    );
    final name = tester.getRect(
      find.descendant(
        of: rowOf('Theme & colour'),
        matching: find.text('Default'),
      ),
    );
    _report('dot Theme & colour', dot);
    expect(name.left - dot.right, 10);
    await same('Start page', 'Home');
    for (final title in const ['My List style', 'Title language', 'Metadata']) {
      await reveal(tester, title);
      final chevron = tester.getRect(
        find.descendant(
          of: rowOf(title),
          matching: find.byIcon(Icons.chevron_right_rounded),
        ),
      );
      expect(chevron.right, reader.chevronRight, reason: title);
    }

    await openSection(tester, 'sources');
    final auto = await switchRect(tester, 'Auto-update extensions');
    expect(auto.right, readerSwitch.right);
    expect(auto.size, readerSwitch.size);

    await openWindowSystem(tester);
    await same('Start page', 'Home');
    await same('Close button', 'Ask when downloads are running');
    for (final title in const [
      'Launch at sign-in',
      'Remember window size and position',
      'New-episode alerts',
    ]) {
      final s = await switchRect(tester, title);
      _report('switch $title', s);
      expect(s.right, readerSwitch.right, reason: title);
      expect(s.size, readerSwitch.size, reason: title);
    }

    await openShortcuts(tester);
    for (final title in const ['Search', 'Go to sidebar item 1']) {
      await reveal(tester, title);
      final caps = find.descendant(
        of: rowOf(title),
        matching: find.byType(KeyCap),
      );
      final right = [
        for (final e in caps.evaluate())
          tester.getRect(find.byWidget(e.widget)).right,
      ].reduce((a, b) => a > b ? a : b);
      _report('keys $title', right);
      expect(right, reader.chevronRight, reason: title);
    }
    // A row whose keys can be changed ends in its Change button.
    final change = find.widgetWithText(TextButton, 'Change');
    await tester.scrollUntilVisible(
      change.hitTestable(),
      240,
      scrollable: pageScroll(),
    );
    await tester.pumpAndSettle();
    await _shot(tester, 'shortcuts_player');
    expect(tester.getRect(change.first).right, reader.chevronRight);
  });

  windowsTest('gaps between a card and the next title are the same', (
    tester,
  ) async {
    // Tall enough to hold the pages, so every section is laid out.
    await pumpSettings(tester, window: const Size(1366, 2400));
    double gap() {
      final card = cardRect(tester, find.byType(GraphiteSettingsPanel).first);
      return tester.getTopLeft(find.byType(SettingsSectionLabel).at(1)).dy -
          card.bottom;
    }

    await openReader(tester);
    final reader = gap();
    await openSection(tester, 'interface');
    expect(gap(), reader);
    await openWindowSystem(tester);
    expect(gap(), reader);
    await openShortcuts(tester);
    expect(gap(), reader);
  });

  windowsTest('keyboard: rows take focus and Enter opens them', (tester) async {
    await pumpSettings(tester);
    await openSection(tester, 'advanced');
    var opened = false;
    for (var i = 0; i < 30 && !opened; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final row = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<GraphiteSettingsControl>();
      if (row?.title != 'Window & system') continue;
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      opened = true;
    }
    expect(opened, isTrue);
    expect(find.byType(WindowSystemSettingsScreen), findsOneWidget);
  });

  windowsTest('a search result still opens its page at the named row', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tester.enterText(find.byType(TextField).first, 'lock when windows');
    await tester.pumpAndSettle();
    // The results are the same rows, in the same column.
    final card = cardRect(tester, find.byType(GraphiteSettingsPanel).first);
    expect(card.left, 258);
    expect(card.width, kDesktopSettingsContentMaxWidth);
    const title = 'Lock when Windows locks';
    await tester.tap(rowOf(title));
    await tester.pumpAndSettle();
    expect(find.byType(WindowSystemSettingsScreen), findsOneWidget);
    final row = tester.getRect(
      find.descendant(
        of: find.byType(WindowSystemSettingsScreen),
        matching: rowOf(title),
      ),
    );
    expect(row.top, greaterThan(46));
    expect(row.bottom, lessThanOrEqualTo(768));
    expect(DesktopSettingsRowTargets.hasPending, isFalse);
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<GraphiteSettingsControl>()
          ?.title,
      title,
    );
  });

  /// Scrolls the showing page to its end a screen at a time, so every row of
  /// it is laid out.
  Future<void> scrollThrough(WidgetTester tester, String what) async {
    for (var i = 0; i < 60; i++) {
      expect(tester.takeException(), isNull, reason: '$what, step $i');
      final position = tester.state<ScrollableState>(pageScroll()).position;
      if (position.pixels >= position.maxScrollExtent) return;
      position.jumpTo(
        (position.pixels + position.viewportDimension * .8).clamp(
          0,
          position.maxScrollExtent,
        ),
      );
      await tester.pumpAndSettle();
    }
    fail('$what: the end was not reached');
  }

  // 800x560 is the smallest window Windows lets the app have.
  for (final (window, scale) in const [
    (Size(800, 560), 1.0),
    (Size(800, 560), 2.0),
    (Size(1000, 700), 2.0),
    (Size(1366, 768), 2.0),
  ]) {
    final tag = '${window.width.round()}x${window.height.round()}_$scale';
    windowsTest('nothing overflows at $tag', (tester) async {
      await pumpSettings(tester, window: window, textScale: scale);
      for (final section in landings) {
        await openSection(tester, section);
        await _shot(tester, '${section}_$tag');
        await scrollThrough(tester, section);
      }
      await openWindowSystem(tester);
      await _shot(tester, 'window_system_$tag');
      await scrollThrough(tester, 'Window & system');
      // The card still keeps its margin on the narrow page.
      final card = cardRect(tester, find.byType(GraphiteSettingsPanel).last);
      expect(card.right, lessThanOrEqualTo(window.width - 22));
      await openShortcuts(tester);
      await _shot(tester, 'shortcuts_$tag');
      await scrollThrough(tester, 'Keyboard shortcuts');
    });
  }

  // Changed keys are the widest rows: long key names plus Change and Reset.
  for (final (window, scale) in const [
    (Size(800, 560), 2.0),
    (Size(1366, 768), 1.0),
    (Size(1366, 768), 2.0),
  ]) {
    final tag = '${window.width.round()}x${window.height.round()}_$scale';
    windowsTest('changed shortcuts fit their rows at $tag', (tester) async {
      await pumpSettings(tester, window: window, textScale: scale);
      final ids = [
        for (final s in DesktopShortcuts.all)
          if (s.remappable) s.id,
      ];
      expect(ids, isNotEmpty);
      for (final id in ids) {
        await DesktopShortcuts.setOverride(id, const [
          SingleActivator(
            LogicalKeyboardKey.arrowRight,
            control: true,
            shift: true,
            alt: true,
          ),
          SingleActivator(LogicalKeyboardKey.pageDown, control: true),
        ]);
      }
      await openShortcuts(tester);
      final reset = find.widgetWithText(TextButton, 'Reset');
      await tester.scrollUntilVisible(
        reset.hitTestable(),
        120,
        scrollable: pageScroll(),
      );
      await tester.pumpAndSettle();
      await _shot(tester, 'shortcuts_changed_$tag');
      // The last button of the row ends where every other value does, and
      // the keys stay inside the row.
      final row = find.ancestor(
        of: reset.first,
        matching: find.byType(GraphiteSettingsControl),
      );
      final rowRect = tester.getRect(row);
      final edge = rowRect.right - 4 - 1 - 18;
      _report('changed row $tag', (rowRect, tester.getRect(reset.first)));
      expect(tester.getRect(reset.first).right, closeTo(edge, 1));
      final caps = find.descendant(of: row, matching: find.byType(KeyCap));
      expect(caps, findsNWidgets(2));
      for (final e in caps.evaluate()) {
        final cap = tester.getRect(find.byWidget(e.widget));
        expect(cap.right, lessThanOrEqualTo(edge + 1));
        expect(cap.left, greaterThan(rowRect.left + 64));
      }
      tester.state<ScrollableState>(pageScroll()).position.jumpTo(0);
      await tester.pumpAndSettle();
      await scrollThrough(tester, 'Changed shortcuts');
    });
  }

  // The "?" help opens this page over the whole window, without the sidebar:
  // same width as the settings pages, centred in the window (a window with
  // no room to spare keeps the 22px margin).
  for (final (window, scale) in const [
    (Size(1366, 768), 1.0),
    (Size(800, 560), 2.0),
  ]) {
    final tag = '${window.width.round()}x${window.height.round()}_$scale';
    windowsTest('Keyboard shortcuts outside Settings at $tag', (tester) async {
      tester.view.physicalSize = window;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      registerDefaultDesktopShortcuts();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const RepaintBoundary(
            key: ValueKey('layout-shot'),
            child: KeyboardShortcutsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _shot(tester, 'shortcuts_outside_$tag');
      final card = cardRect(tester, find.byType(GraphiteSettingsPanel).first);
      final search = tester.getRect(find.byType(TextField));
      _report('outside $tag', (card, search));
      final width = (window.width - 44).clamp(
        0,
        kDesktopSettingsContentMaxWidth,
      );
      expect(card.left, (window.width - width) / 2);
      expect(card.width, width);
      expect(search.left, card.left);
      expect(search.width, card.width);
      await scrollThrough(tester, 'Keyboard shortcuts outside Settings');
    });
  }
  // The other settings pages. Connections, the tracker pages, Discord,
  // Manual matches, Download location, Profiles & account and Contributors
  // used to sit in their own centred columns (640 to 960 wide) or with their
  // own insets. They now stand where the Reader page does.

  final l10n = lookupAppLocalizations(const Locale('en'));

  /// Pins one title, so Manual matches has a row to lay out.
  Future<void> pinOneMatch(WidgetTester tester) => tester.runAsync(() async {
    const title = ZCanonical(ZKind.anime, 'mal:5114');
    final store = GetIt.instance<MatchStore>();
    await store.pin(
      title,
      const SourceMatch(
        sourceId: 'ani:1',
        showUrl: '/fma',
        showId: 'fma',
        showTitle: 'FMA on AllAnime',
        pinned: true,
      ),
    );
    await store.rememberTitle(title, 'Fullmetal Alchemist');
  });

  /// Opens [page] in the Settings content area, beside the sidebar, the way
  /// its own row does.
  Future<void> pushPage(WidgetTester tester, Widget page) async {
    final navigator = tester.state<NavigatorState>(
      find
          .ancestor(
            of: find.byType(ReaderSettingsScreen),
            matching: find.byType(Navigator),
          )
          .first,
    );
    unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => page)));
    await tester.pumpAndSettle();
  }

  /// Opens Profiles & account from the card at the top of Account.
  Future<void> openProfiles(WidgetTester tester) async {
    await openSection(tester, 'account');
    final card = find.byType(DesktopSettingsProfile);
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: card, matching: find.byType(InkWell)).first,
    );
    await tester.pumpAndSettle();
  }

  /// Opens the connected services page (trackers and Discord) from the
  /// Account section, tapping its row when the section shows a row list.
  Future<void> openConnections(WidgetTester tester) async {
    await openSection(tester, 'account');
    if (find.byType(ConnectedServicesScreen).evaluate().isEmpty) {
      await openRow(
        tester,
        settingsSectionTitle(l10n, SettingsSection.account),
      );
    }
  }

  /// The pages, each with the page widget it shows and how it is opened.
  final otherPages = <(String, Type, Future<void> Function(WidgetTester))>[
    ('Connections', ConnectedServicesScreen, openConnections),
    for (final tracker in const [
      'AniList',
      'MyAnimeList',
      'Simkl',
      'MangaBaka',
    ])
      (
        tracker,
        TrackerSettingsScreen,
        (tester) async {
          await openConnections(tester);
          await openRow(tester, tracker);
        },
      ),
    (
      'Discord',
      DiscordSettingsScreen,
      (tester) async {
        await openConnections(tester);
        await openRow(tester, l10n.discord);
      },
    ),
    ('Profiles & account', ViewerProfilesScreen, openProfiles),
    (
      'Manual matches',
      ManualMatchesScreen,
      (tester) async {
        await pinOneMatch(tester);
        await openReader(tester);
        await pushPage(tester, const ManualMatchesScreen());
      },
    ),
    (
      'Download location',
      DownloadLocationScreen,
      (tester) async {
        await openReader(tester);
        await pushPage(tester, const DownloadLocationScreen());
      },
    ),
    (
      'Contributors',
      ContributorsScreen,
      (tester) async {
        await openReader(tester);
        await pushPage(tester, const ContributorsScreen());
      },
    ),
  ];

  /// The laid-out rect of a text that is not in a card.
  Rect textRect(WidgetTester tester, String text) =>
      tester.getRect(find.text(text).hitTestable().first);

  windowsTest('the other settings pages stand in the Reader column', (
    tester,
  ) async {
    await pumpSettings(tester);
    await openReader(tester);
    final reader = measureSection(tester, 0);
    final readerRow = await measureRow(tester, 'Reading mode');

    for (final (name, type, open) in otherPages) {
      await open(tester);
      final page = find.byType(type);
      expect(page, findsOneWidget, reason: name);
      await _shot(tester, 'page_$name');
      // Every card: the Reader card's left edge and width.
      final panels = find.descendant(
        of: page,
        matching: find.byType(GraphiteSettingsPanel),
      );
      if (type != ManualMatchesScreen) {
        expect(panels, findsWidgets, reason: name);
      }
      for (var i = 0; i < panels.evaluate().length; i++) {
        final card = cardRect(tester, panels.at(i));
        _report('card $i $name', card);
        expect(card.left, reader.cardLeft, reason: '$name card $i');
        expect(card.width, reader.cardWidth, reason: '$name card $i');
      }
      // Every section title: where and how the Reader titles are drawn.
      final labels = find.descendant(
        of: page,
        matching: find.byType(SettingsSectionLabel),
      );
      for (var i = 0; i < labels.evaluate().length; i++) {
        final text = find.descendant(
          of: labels.at(i),
          matching: find.byType(Text),
        );
        _report('title $i $name', tester.getRect(text));
        expect(tester.getRect(text).left, reader.left, reason: '$name $i');
        expect(lookOf(tester, text), reader.look, reason: '$name $i');
      }
      // The page itself has the Settings background.
      final scaffold = tester.widget<Scaffold>(
        find.descendant(of: page, matching: find.byType(Scaffold)).first,
      );
      expect(scaffold.backgroundColor, DesktopChrome.frame, reason: name);
      // Rows: the Reader row's left edge and width.
      final rows = find.descendant(
        of: page,
        matching: find.byType(GraphiteSettingsControl),
      );
      for (var i = 0; i < rows.evaluate().length; i++) {
        final rect = tester.getRect(rows.at(i));
        expect(rect.left, readerRow.left, reason: '$name row $i');
        expect(rect.width, readerRow.width, reason: '$name row $i');
      }
    }
  });

  windowsTest('notes, rows and the search box line up with Reader', (
    tester,
  ) async {
    await pumpSettings(tester);
    await openReader(tester);
    final reader = await measureRow(tester, 'Click zones');

    await openConnections(tester);
    expect(textRect(tester, 'Watch tracking').left, 260);
    // The tracker page: the account summary right under the header, the
    // rows in the Reader columns, the note where the titles start.
    await openRow(tester, 'Simkl');
    final header = cardRect(tester, find.byType(GraphiteSettingsPanel).first);
    final bar = tester.getRect(
      find.descendant(
        of: find.byType(TrackerSettingsScreen),
        matching: find.byType(AppBar),
      ),
    );
    _report('tracker header', (header, bar));
    expect(header.left, 258);
    expect(header.top, bar.bottom + 16);
    final note = find.textContaining('Movies and series sync here too.');
    expect(tester.getRect(note.hitTestable()).left, 260);
    final connect = await measureRow(tester, 'Connect Simkl');
    _report('row Connect Simkl', connect);
    expect(connect.icon, reader.icon);
    expect(connect.title, reader.title);
    expect(connect.titleLook, reader.titleLook);
    expect(connect.subtitle, reader.subtitle);
    expect(connect.subtitleLook, reader.subtitleLook);

    await openConnections(tester);
    await openRow(tester, l10n.discord);
    final blurb = find.text(l10n.discordPresenceBlurb);
    await tester.scrollUntilVisible(
      blurb.hitTestable(),
      120,
      scrollable: pageScroll(),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(blurb).left, 260);

    await openReader(tester);
    await pushPage(tester, const DownloadLocationScreen());
    expect(textRect(tester, l10n.newDownloadsSaveHere).left, 260);

    await pinOneMatch(tester);
    await openReader(tester);
    await pushPage(tester, const ManualMatchesScreen());
    expect(textRect(tester, l10n.manualMatchesIntro).left, 260);
    final search = tester.getRect(
      find.byKey(const ValueKey('manual-matches-search')),
    );
    expect(search.left, 258);
    expect(search.width, kDesktopSettingsContentMaxWidth);
    final row = tester.getRect(
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('manual-match-'),
      ),
    );
    _report('manual match row', row);
    expect(row.left, 258);
    expect(row.width, kDesktopSettingsContentMaxWidth);

    // Profiles & account: a settings section title instead of its own small
    // heading, and the note in the cards' column. Upstream moved the account
    // rows to the Account section, so this page only has the Profiles title.
    await openProfiles(tester);
    expect(
      find.ancestor(
        of: find.text('Profiles'),
        matching: find.byType(SettingsSectionLabel),
      ),
      findsOneWidget,
    );
    final icon = tester.getRect(
      find.byIcon(Icons.switch_account_rounded).hitTestable(),
    );
    expect(icon.left, 260 + (34 - 19) / 2);

    // Contributors: one card per section, each row's link mark at the
    // right edge the Reader values end at.
    await openReader(tester);
    await pushPage(tester, const ContributorsScreen());
    expect(
      find.descendant(
        of: find.byType(ContributorsScreen),
        matching: find.byType(GraphiteSettingsPanel),
      ),
      findsWidgets,
    );
    final marks = find.byIcon(Icons.arrow_outward_rounded).hitTestable();
    expect(marks, findsWidgets);
    for (var i = 0; i < marks.evaluate().length; i++) {
      expect(tester.getRect(marks.at(i)).right, 1154, reason: 'mark $i');
    }
  });

  // Small windows and 200% text: every row of these pages still fits.
  for (final (window, scale) in const [
    (Size(800, 560), 1.0),
    (Size(800, 560), 2.0),
    (Size(1366, 768), 2.0),
  ]) {
    final tag = '${window.width.round()}x${window.height.round()}_$scale';
    windowsTest('the other settings pages fit at $tag', (tester) async {
      await pumpSettings(tester, window: window, textScale: scale);
      for (final (name, type, open) in otherPages) {
        await open(tester);
        expect(find.byType(type), findsOneWidget, reason: name);
        await _shot(tester, 'page_${name}_$tag');
        await scrollThrough(tester, name);
        // The cards keep their margin on the narrow page.
        final panels = find.descendant(
          of: find.byType(type),
          matching: find.byType(GraphiteSettingsPanel),
        );
        for (var i = 0; i < panels.evaluate().length; i++) {
          final card = cardRect(tester, panels.at(i));
          expect(
            card.right,
            lessThanOrEqualTo(window.width - 22),
            reason: name,
          );
        }
      }
    });
  }

  // Opened from outside Settings (Downloads, Lists, the reader export, or
  // the settings list outside the Windows workspace) these pages fill the
  // window: the same column, centred.
  for (final (window, scale) in const [
    (Size(1366, 768), 1.0),
    (Size(800, 560), 2.0),
  ]) {
    final tag = '${window.width.round()}x${window.height.round()}_$scale';
    windowsTest('the other settings pages outside Settings at $tag', (
      tester,
    ) async {
      tester.view.physicalSize = window;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pinOneMatch(tester);
      final width = (window.width - 44).clamp(
        0,
        kDesktopSettingsContentMaxWidth,
      );
      final left = (window.width - width) / 2;
      for (final (name, page) in <(String, Widget)>[
        ('Download location', const DownloadLocationScreen()),
        ('Manual matches', const ManualMatchesScreen()),
        ('Window & system', const WindowSystemSettingsScreen()),
        (
          'Tracker',
          DesktopSettingsScope(
            standalone: true,
            child: TrackerSettingsScreen(
              tracker: GetIt.instance<AniListService>(),
            ),
          ),
        ),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey(name),
            theme: buildAppTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: RepaintBoundary(
              key: const ValueKey('layout-shot'),
              child: page,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _shot(tester, 'outside_${name}_$tag');
        final cards = find.byType(GraphiteSettingsPanel);
        for (var i = 0; i < cards.evaluate().length; i++) {
          final card = cardRect(tester, cards.at(i));
          _report('outside $name $tag card $i', card);
          expect(card.left, left, reason: '$name card $i');
          expect(card.width, width, reason: '$name card $i');
        }
        if (name == 'Manual matches') {
          final search = tester.getRect(
            find.byKey(const ValueKey('manual-matches-search')),
          );
          expect(search.left, left);
          expect(search.width, width);
        }
        await scrollThrough(tester, '$name outside Settings');
      }
    });
  }
}

/// Prints one measured line when run with --dart-define=LAYOUT_REPORT=true.
void _report(String what, Object? value) {
  if (const bool.fromEnvironment('LAYOUT_REPORT')) {
    debugPrint('LAYOUT $what: $value', wrapWidth: 4000);
  }
}

/// Saves what is on screen to the folder in --dart-define=LAYOUT_SHOTS, to
/// look at; does nothing in a normal run.
Future<void> _shot(WidgetTester tester, String name) async {
  const out = String.fromEnvironment('LAYOUT_SHOTS');
  if (out.isEmpty) return;
  await tester.runAsync(() async {
    // The icon font, so the picture shows the icons and not boxes.
    const icons = String.fromEnvironment('LAYOUT_ICONS');
    if (icons.isNotEmpty) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(ByteData.sublistView(File(icons).readAsBytesSync())),
        );
      await loader.load();
    }
  });
  await tester.pump();
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('layout-shot')),
    );
    final image = await boundary.toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
}

/// A widget test run as the Windows build. The override is cleared at the
/// end of the body, as the test framework requires.
void windowsTest(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

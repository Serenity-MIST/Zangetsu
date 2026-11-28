// search-10 Option A: on Windows, Ctrl/Shift-click puts genres into a
// selection bar ("Browse N genres") that opens Search on all of them at once.
// A plain click still opens a single genre, and phone is unchanged.

import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/zmode/genre_catalog.dart';
import 'package:watch_app/core/zmode/metadata_filters.dart';
import 'package:watch_app/core/zmode/metadata_repository.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/home/genres_screen.dart';
import 'package:watch_app/features/home/search_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

class _FakeContentModeCubit extends Cubit<ContentMode>
    implements ContentModeCubit {
  _FakeContentModeCubit(super.initial);
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeMetaRepo implements MetadataRepository {
  @override
  bool get supportsFilters => true;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Keeps pushed routes so their SearchScreen can be inspected without
/// building it (that would need the whole Search dependency graph).
class _Pushes extends NavigatorObserver {
  final routes = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previous) {
    if (previous != null) routes.add(route);
  }
}

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('genres-multi-');
    Hive.init(directory.path);
    await ZModePrefs.init();
    final v = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    v.physicalSize = const Size(1200 * 2, 1800 * 2);
    v.devicePixelRatio = 2;
    sl.registerSingleton<ContentModeCubit>(
      _FakeContentModeCubit(ContentMode.anime),
    );
    sl.registerSingleton<MetadataRepository>(_FakeMetaRepo());
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first
        .resetPhysicalSize();
    await sl.reset();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Widget harness(NavigatorObserver o) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    navigatorObservers: [o],
    home: const GenresScreen(),
  );

  /// The SearchScreen a pushed route would build.
  SearchScreen pushedSearch(WidgetTester t, Route<dynamic> route) =>
      (route as MaterialPageRoute<void>).builder(
            t.element(find.byType(GenresScreen)),
          )
          as SearchScreen;

  testWidgets('Ctrl-click builds a selection and browses all of it', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final pushes = _Pushes();
    await t.pumpWidget(harness(pushes));
    await t.pumpAndSettle();
    final genres = GenreCatalog.genresFor(ZKind.anime, adult: false);
    final a = genres[0], b = genres[2];

    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.tap(find.byKey(ValueKey('genre_$a')));
    await t.tap(find.byKey(ValueKey('genre_$b')));
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pumpAndSettle();

    // Modifier clicks select instead of opening.
    expect(pushes.routes, isEmpty);
    expect(find.byKey(ValueKey('genre_selected_$a')), findsOneWidget);
    expect(find.text('Browse 2 genres'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('genre-selection-browse')));
    expect(pushes.routes, hasLength(1));
    expect(pushedSearch(t, pushes.routes.single).initialFilters!.genres, [
      a,
      b,
    ]);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Shift-click selects a range; Esc clears it', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await t.pumpWidget(harness(_Pushes()));
    await t.pumpAndSettle();
    final genres = GenreCatalog.genresFor(ZKind.anime, adult: false);

    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.tap(find.byKey(ValueKey('genre_${genres[0]}')));
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.tap(find.byKey(ValueKey('genre_${genres[3]}')));
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pumpAndSettle();
    expect(find.text('Browse 4 genres'), findsOneWidget);

    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('genre-selection-bar')), findsNothing);
    expect(find.byType(GenresScreen), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a plain click still opens one genre', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final pushes = _Pushes();
    await t.pumpWidget(harness(pushes));
    await t.pumpAndSettle();
    final g = GenreCatalog.genresFor(ZKind.anime, adult: false).first;
    await t.tap(find.byKey(ValueKey('genre_$g')));
    expect(pushes.routes, hasLength(1));
    expect(pushedSearch(t, pushes.routes.single).initialFilters!.genres, [g]);
    expect(find.byKey(const ValueKey('genre-selection-bar')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  test('multiGenreFilters keeps order and the adult rule', () {
    expect(multiGenreFilters(['A', 'B']).genres, ['A', 'B']);
    expect(multiGenreFilters(['A']).adult, isFalse);
    expect(multiGenreFilters(['A', kAdultGenre]).adult, isTrue);
  });
}

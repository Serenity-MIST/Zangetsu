// Windows My List: a Refresh button and F5 instead of pull-to-refresh
// (home-4), and right-click menus at the cursor on posters and category tabs
// instead of phone bottom sheets (home-3). Phone keeps none of these.
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/category_store.dart';
import 'package:watch_app/core/playback/list_status_store.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/series_groups.dart';
import 'package:watch_app/core/supabase/auth_user.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/home/my_list_screen.dart';

class _ModeCubit extends Cubit<ContentMode> implements ContentModeCubit {
  _ModeCubit() : super(ContentMode.anime);
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// My List with one title; counts cloud pulls (the Refresh action).
class _MyList implements MyListStore {
  @override
  final revision = ValueNotifier<int>(0);
  int pulls = 0;
  static const item = MediaItem(
    id: 'a',
    title: 'Frieren',
    url: '/a',
    sourceId: 's',
    type: ProviderType.anime,
  );

  @override
  List<MediaItem> all() => const [item];
  @override
  bool contains(MediaItem m) => m.id == item.id;
  @override
  Future<void> pullFromCloud({String? forProfileId}) async => pulls++;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Statuses implements ListStatusStore {
  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  @override
  WatchStatus? statusOf(MediaItem m) => null;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// One category ("Gym") that holds the title.
class _Cats implements CategoryStore {
  @override
  final revision = ValueNotifier<int>(0);
  @override
  String get profileId => 'p';
  @override
  List<ListCategory> all() => const [
    ListCategory(id: 'gym', name: 'Gym', position: 0, kind: 'anime'),
  ];
  @override
  Set<String> categoriesOf(MediaItem item) => {'gym'};
  @override
  bool isIn(MediaItem item, String id) => id == 'gym';
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// No series groups, so My List shows every title on its own.
class _Series implements SeriesGroupStore {
  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  @override
  List<SeriesGroup> all() => const [];
  @override
  SeriesGroup? groupOf(String key) => null;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Auth extends Cubit<AuthState> implements AuthCubit {
  _Auth()
    : super(
        const AuthState(
          status: AuthStatus.authenticated,
          user: AuthUser(id: 'u', name: 'T', email: 't@example.com'),
        ),
      );
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late _MyList myList;

  setUp(() async {
    await sl.reset();
    myList = _MyList();
    sl
      ..registerSingleton<AppMode>(const AppMode(isTv: false))
      ..registerSingleton<TrackerHub>(TrackerHub(const []))
      ..registerSingleton<ListStatusStore>(_Statuses())
      ..registerSingleton<CategoryStore>(_Cats())
      ..registerSingleton<MyListStore>(myList)
      ..registerSingleton<SeriesGroupStore>(_Series())
      ..registerSingleton<ContentModeCubit>(_ModeCubit());
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await sl.reset();
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider<AuthCubit>.value(
          value: _Auth(),
          child: const MyListScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Windows: Refresh button and F5 pull the list', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pump(tester);
    await tester.tap(find.byTooltip('Refresh (F5)'));
    await tester.pumpAndSettle();
    expect(myList.pulls, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pumpAndSettle();
    expect(myList.pulls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Windows: right-click on a poster opens a menu, not a sheet', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pump(tester);
    await tester.tap(find.text('Frieren').first, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Change status…'), findsOneWidget);
    expect(find.text('Remove from My List'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Windows: right-click on a category tab offers rename/delete', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pump(tester);
    await tester.tap(find.text('Gym'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Delete category'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phone: no Refresh button', (tester) async {
    await pump(tester);
    expect(find.byTooltip('Refresh (F5)'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

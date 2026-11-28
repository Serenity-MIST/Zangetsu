import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/watch_history.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/core/supabase/auth_user.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/auth/auth_screens.dart';
import 'package:watch_app/features/auth/reconnect.dart';

/// Windows sign-in form (acct-2), logout confirmation (acct-5) and the
/// account avatar menu (acct-6). Each Windows test switches the target
/// platform; the phone checks prove the old behaviour is untouched.
void main() {
  late _FakeAuth auth;

  setUp(() async {
    await GetIt.instance.reset();
    auth = _FakeAuth();
    GetIt.instance
      ..registerSingleton<AppMode>(const AppMode(isTv: false))
      ..registerSingleton<AuthCubit>(auth)
      ..registerSingleton<WatchHistory>(_History())
      ..registerSingleton<MyListStore>(_MyList());
  });

  tearDown(() async {
    await auth.close();
    await GetIt.instance.reset();
  });

  Future<void> pumpLogin(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider<AuthCubit>.value(value: auth, child: screen),
      ),
    );
    await tester.pumpAndSettle();
  }

  EditableText editable(WidgetTester tester, String key) =>
      tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(EditableText),
        ),
      );

  group('sign-in form on Windows', () {
    windowsTest('email focused, Enter moves on, Enter on password submits', (
      tester,
    ) async {
      await pumpLogin(tester, const LoginScreen());

      expect(editable(tester, 'auth-login-email').focusNode.hasFocus, isTrue);
      expect(editable(tester, 'auth-login-email').autofillHints, [
        AutofillHints.email,
        AutofillHints.username,
      ]);
      expect(editable(tester, 'auth-login-password').autofillHints, [
        AutofillHints.password,
      ]);

      await tester.enterText(
        find.byKey(const ValueKey('auth-login-email')),
        'a@b.c',
      );
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();
      expect(
        editable(tester, 'auth-login-password').focusNode.hasFocus,
        isTrue,
      );

      await tester.enterText(
        find.byKey(const ValueKey('auth-login-password')),
        'secret123',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(auth.loginCalls, [('a@b.c', 'secret123')]);
    });

    windowsTest('password can be revealed and hidden', (tester) async {
      await pumpLogin(tester, const LoginScreen());

      expect(editable(tester, 'auth-login-password').obscureText, isTrue);
      await tester.tap(find.byKey(const ValueKey('auth-password-reveal')));
      await tester.pump();
      expect(editable(tester, 'auth-login-password').obscureText, isFalse);
      await tester.tap(find.byKey(const ValueKey('auth-password-reveal')));
      await tester.pump();
      expect(editable(tester, 'auth-login-password').obscureText, isTrue);
    });

    windowsTest('form sits in a centred card no wider than 440px', (
      tester,
    ) async {
      await pumpLogin(tester, const LoginScreen());

      final card = find.byKey(const ValueKey('auth-desktop-card'));
      expect(card, findsOneWidget);
      final rect = tester.getRect(card);
      expect(rect.width, lessThanOrEqualTo(440));
      expect(rect.center.dx, closeTo(800, 1));
    });

    windowsTest('sign-up walks name -> email -> password -> submit', (
      tester,
    ) async {
      await pumpLogin(tester, const SignupScreen());

      expect(editable(tester, 'auth-signup-name').focusNode.hasFocus, isTrue);
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();
      expect(editable(tester, 'auth-signup-email').focusNode.hasFocus, isTrue);
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();
      expect(
        editable(tester, 'auth-signup-password').focusNode.hasFocus,
        isTrue,
      );
      expect(editable(tester, 'auth-signup-password').autofillHints, [
        AutofillHints.newPassword,
      ]);
    });
  });

  testWidgets('phone sign-in form is unchanged', (tester) async {
    await pumpLogin(tester, const LoginScreen());

    expect(find.byKey(const ValueKey('auth-desktop-card')), findsNothing);
    expect(find.byKey(const ValueKey('auth-password-reveal')), findsNothing);
    expect(editable(tester, 'auth-login-email').focusNode.hasFocus, isFalse);
    expect(editable(tester, 'auth-login-email').autofillHints, isNull);
  });

  group('logout on Windows', () {
    Future<BuildContext> pumpHost(WidgetTester tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                captured = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      return captured;
    }

    windowsTest('asks first and names the account; Cancel keeps you in', (
      tester,
    ) async {
      final context = await pumpHost(tester);
      final result = safeLogout(context);
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Log out of a@example.com? Your library stays in your account.',
        ),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(await result, isFalse);
      expect(auth.logoutCalls, 0);
    });

    windowsTest('confirming logs out', (tester) async {
      final context = await pumpHost(tester);
      final result = safeLogout(context);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(auth.logoutCalls, 1);
    });

    testWidgets('phone still logs out in one click', (tester) async {
      final context = await pumpHost(tester);
      final result = safeLogout(context);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(await result, isTrue);
      expect(auth.logoutCalls, 1);
    });
  });

  windowsTest('Windows account avatar opens a menu with three uploads', (
    tester,
  ) async {
    GetIt.instance.registerSingleton<ViewerProfileStore>(_Profiles());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider<AuthCubit>.value(
            value: auth,
            child: const ProfileAccountSection(),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('account-avatar-button')));
    await tester.pumpAndSettle();

    expect(find.text('Photo from gallery'), findsNothing);
    expect(find.text('Upload image…'), findsOneWidget);
    expect(find.text('Upload GIF…'), findsOneWidget);
    expect(find.text('Search GIFs…'), findsOneWidget);

    // The menu drops down from the avatar, not from the window bottom.
    final avatar = tester.getRect(
      find.byKey(const ValueKey('account-avatar-button')),
    );
    expect(
      tester.getTopLeft(find.text('Upload image…')).dy,
      greaterThan(avatar.bottom - 1),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });
}

class _FakeAuth extends Cubit<AuthState> implements AuthCubit {
  _FakeAuth()
    : super(
        const AuthState(
          status: AuthStatus.authenticated,
          user: AuthUser(id: 'user-1', name: 'Account', email: 'a@example.com'),
        ),
      );

  final loginCalls = <(String, String)>[];
  int logoutCalls = 0;

  @override
  bool get hasLiveSession => true;

  @override
  Future<bool> login(String email, String password) async {
    loginCalls.add((email, password));
    return false;
  }

  @override
  Future<void> logout() async => logoutCalls++;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _History implements WatchHistory {
  @override
  List<HistoryEntry> all() => const [];

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MyList implements MyListStore {
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  List<MediaItem> all() => const [];
}

/// A widget test run with Windows as the target platform (the variant
/// restores the platform afterwards, as flutter_test requires).
void windowsTest(String description, WidgetTesterCallback body) => testWidgets(
  description,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.windows),
);

/// Profile store with just the default profile, no Hive needed.
class _Profiles extends ViewerProfileStore {
  @override
  List<ViewerProfile> get profiles => const [
    ViewerProfile(id: kDefaultProfileId, name: 'Account'),
  ];
}

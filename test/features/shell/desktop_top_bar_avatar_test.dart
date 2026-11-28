import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/core/profiles/viewer_profile_avatar.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/shell/desktop_top_bar_avatar.dart';

/// Profile store stand-in: only the listenables the avatar reads.
class _Profiles implements ViewerProfileStore {
  @override
  final ValueNotifier<ViewerProfile?> active = ValueNotifier(null);
  @override
  final ValueNotifier<int> revision = ValueNotifier(0);
  @override
  ViewerProfile get activeProfile =>
      active.value ?? const ViewerProfile(id: kDefaultProfileId, name: 'Home');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Sign-in stand-in whose state the test sets directly.
class _Auth extends Cubit<AuthState> implements AuthCubit {
  _Auth(super.initial);
  void setAvatar(String? url) => emit(AuthState(avatarUrl: url));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String? _shownPhoto(WidgetTester tester) =>
    tester.widget<ProfileAvatarFace>(find.byType(ProfileAvatarFace)).photoUrl;

void main() {
  testWidgets(
    'Windows top bar shows the account picture for the main profile',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final profiles = _Profiles();
      final auth = _Auth(const AuthState(avatarUrl: 'https://a.test/me.png'));
      addTearDown(auth.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: DesktopTopBarAvatar(profiles: profiles, auth: auth),
          ),
        ),
      );
      // Same rule as the Profile page: the main profile without its own
      // photo uses the signed-in account's picture, not a person icon.
      expect(_shownPhoto(tester), 'https://a.test/me.png');

      // A new account picture shows up without rebuilding the shell.
      auth.setAvatar('https://a.test/new.png');
      await tester.pump();
      expect(_shownPhoto(tester), 'https://a.test/new.png');

      // Switching to a profile with its own photo shows that photo.
      profiles.active.value = const ViewerProfile(
        id: 'kid',
        name: 'Kid',
        photoUrl: 'https://a.test/kid.png',
      );
      await tester.pump();
      expect(_shownPhoto(tester), 'https://a.test/kid.png');

      // A second profile without a photo shows its own icon, not the
      // account picture (also the Profile page rule).
      profiles.active.value = const ViewerProfile(id: 'other', name: 'Other');
      await tester.pump();
      expect(_shownPhoto(tester), isNull);
      expect(tester.takeException(), isNull);
    },
  );
}

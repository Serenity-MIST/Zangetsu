import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/di/injector.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/profiles/viewer_profile_avatar.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/desktop_svg.dart';
import '../auth/auth_cubit.dart';

/// The round picture at the top right of the Windows window.
///
/// It shows the same picture as the Profile page: the active viewer
/// profile's own photo, or, for the main profile without its own photo, the
/// signed-in account's picture. It listens to the profile store and the
/// sign-in state itself, so a new photo or a profile switch shows up at once
/// without waiting for the whole shell to rebuild.
class DesktopTopBarAvatar extends StatelessWidget {
  const DesktopTopBarAvatar({super.key, this.profiles, this.auth});

  /// Test hooks; the app uses the shared services from the injector.
  final ViewerProfileStore? profiles;
  final AuthCubit? auth;

  static const double _diameter = 36;

  @override
  Widget build(BuildContext context) {
    final store =
        profiles ??
        (sl.isRegistered<ViewerProfileStore>()
            ? sl<ViewerProfileStore>()
            : null);
    final cubit =
        auth ?? (sl.isRegistered<AuthCubit>() ? sl<AuthCubit>() : null);
    // Without a profile store (early start-up, some tests) fall back to the
    // account picture alone.
    if (store == null) return _withAuth(cubit, (photo) => _face(null, photo));
    return ListenableBuilder(
      // `active` changes on a profile switch, `revision` when a profile is
      // edited (for example a new photo).
      listenable: Listenable.merge([store.active, store.revision]),
      builder: (context, _) {
        final profile = store.activeProfile;
        return _withAuth(
          cubit,
          (accountPhoto) => _face(
            profile,
            profilePhotoForFace(
              profile: profile,
              accountPhotoUrl: accountPhoto,
            ),
          ),
        );
      },
    );
  }

  /// Rebuilds [child] whenever the signed-in account's picture changes.
  Widget _withAuth(AuthCubit? cubit, Widget Function(String?) child) {
    if (cubit == null) return child(null);
    return BlocBuilder<AuthCubit, AuthState>(
      bloc: cubit,
      buildWhen: (a, b) => a.avatarUrl != b.avatarUrl,
      builder: (context, state) => child(state.avatarUrl),
    );
  }

  Widget _face(ViewerProfile? profile, String? photoUrl) {
    if (profile == null) {
      if (photoUrl == null || photoUrl.isEmpty) return _genericIcon();
      // No profile but a signed-in picture: show the picture on its own.
      return ClipOval(
        child: ColoredBox(
          color: AppColors.surface2,
          child: ProfileAvatarFace(
            profile: const ViewerProfile(id: kDefaultProfileId, name: ''),
            photoUrl: photoUrl,
            iconSize: 22,
            photoDiameter: _diameter,
          ),
        ),
      );
    }
    return ClipOval(
      child: ColoredBox(
        // The profile's own colour behind its icon, like the Profile page.
        color: viewerProfileAvatarColor(profile.avatar),
        child: SizedBox.square(
          dimension: _diameter,
          child: Center(
            child: ProfileAvatarFace(
              key: ValueKey('desktop-top-avatar:${profile.id}:$photoUrl'),
              profile: profile,
              photoUrl: photoUrl,
              iconSize: 22,
              photoDiameter: _diameter,
            ),
          ),
        ),
      ),
    );
  }

  Widget _genericIcon() => SvgPicture.asset(
    'assets/icons/lucide/user-round.svg',
    width: 24,
    height: 24,
    renderingStrategy: desktopSvgStrategy,
    colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
  );
}

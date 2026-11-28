import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../core/cache/app_image_cache.dart';
import '../../core/desktop/desktop_history_opener.dart';
import '../../core/desktop/desktop_settings_opener.dart';
import '../../core/desktop/desktop_shortcuts.dart';
import '../../core/di/injector.dart';
import '../../core/models/watch_status.dart';
import '../../core/playback/list_status_store.dart';
import '../../core/playback/my_list.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/profiles/viewer_profile_avatar.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../auth/auth_cubit.dart';
import '../auth/auth_screens.dart' show ProfileAccountSection;
import '../history/history_screen.dart';
import '../settings/settings_screen.dart';
import '../settings/donate_screen.dart';
import 'desktop_profile_relock.dart';
import 'viewer_profile_editor_screen.dart';
import 'viewer_profiles_screen.dart';
import '../../l10n/l10n.dart';

class ViewerProfileHomeScreen extends StatelessWidget {
  const ViewerProfileHomeScreen({
    super.key,
    this.onProfileSelected,
    this.onPickerClosed,
  });

  final VoidCallback? onProfileSelected;
  final VoidCallback? onPickerClosed;

  static const _zoroGifUrl =
      'https://custom-doodle.com/wp-content/uploads/doodle/auto-draft/one-piece-dancing-roronoa-zoro-doodle.gif';

  ViewerProfileStore get _profiles => sl<ViewerProfileStore>();

  String? _accountPhoto() =>
      sl.isRegistered<AuthCubit>() ? sl<AuthCubit>().state.avatarUrl : null;

  void _openSettings(BuildContext context) {
    // shell-1: on Windows, let the shell open Settings (a full page over the
    // rail, one copy at a time, same as Ctrl+,). Falls back to pushing the
    // route here when the shell has not installed its handler (and always
    // on phones).
    if (defaultTargetPlatform == TargetPlatform.windows &&
        DesktopSettingsOpener.open()) {
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const SettingsScreen(showBackButton: true),
      ),
    );
  }

  /// Windows: History left the sidebar, so the Profile page opens it. Uses
  /// the shell's in-frame History page; falls back to the pushed screen when
  /// the shell has not installed its handler.
  void _openHistory(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.windows &&
        DesktopHistoryOpener.open()) {
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const HistoryScreen()),
    );
  }

  Future<void> _openChooser(BuildContext context) async {
    final route = ProfilePickerRoute(
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      builder: (pickerContext) => ViewerProfilesScreen(
        selectionOnly: true,
        onProfilePrepared: onProfileSelected,
        onSelected: onProfileSelected == null
            ? null
            : () async {
                await WidgetsBinding.instance.endOfFrame;
                if (pickerContext.mounted) Navigator.of(pickerContext).pop();
              },
      ),
    );
    await Navigator.of(context).push<void>(route);
    await route.completed;
    onPickerClosed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.select<AuthCubit, AuthState>((cubit) => cubit.state);
    if (auth.status == AuthStatus.unknown) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: Center(child: CircularProgressIndicator(color: AppColors.accent)),
      );
    }
    if (!auth.isLoggedIn) {
      return Scaffold(backgroundColor: AppColors.bg, body: _signedOut(context));
    }

    final myList = sl.isRegistered<MyListStore>() ? sl<MyListStore>() : null;
    final statuses = sl.isRegistered<ListStatusStore>()
        ? sl<ListStatusStore>()
        : null;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: AnimatedBuilder(
        animation: Listenable.merge([
          _profiles.revision,
          if (myList != null) myList.revision,
          if (statuses != null) statuses.revision,
        ]),
        builder: (context, _) {
          final profile = _profiles.activeProfile;
          final saved = myList?.all() ?? [];
          final inProgress = statuses == null
              ? 0
              : saved
                    .where(
                      (item) => statuses.statusOf(item) == WatchStatus.watching,
                    )
                    .length;
          final completed = statuses == null
              ? 0
              : saved
                    .where(
                      (item) =>
                          statuses.statusOf(item) == WatchStatus.completed,
                    )
                    .length;
          // Windows gets a layout that fills the window and never scrolls; the
          // narrow scrolling column below is the phone layout.
          if (defaultTargetPlatform == TargetPlatform.windows) {
            return _desktopLayout(
              context,
              profile,
              saved.length,
              inProgress,
              completed,
            );
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _cover(context, profile),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 124),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 260),
                          switchInCurve: Curves.easeOutCubic,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(0, 0.08),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                          child: Column(
                            key: ValueKey(profile.id),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      profile.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppText.title,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    tooltip: 'Edit profile',
                                    onPressed: () => openViewerProfileEditor(
                                      context,
                                      _profiles,
                                      profile: profile,
                                    ),
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 20,
                                    ),
                                  ),
                                ],
                              ),
                              if (profile.isKids)
                                Text('Kids profile', style: AppText.caption),
                              GestureDetector(
                                onTap: () => openViewerProfileEditor(
                                  context,
                                  _profiles,
                                  profile: profile,
                                ),
                                child: Text(
                                  profile.bio.isEmpty
                                      ? 'Add a bio'
                                      : profile.bio,
                                  style: AppText.body.copyWith(
                                    fontSize: 14,
                                    color: profile.bio.isEmpty
                                        ? AppColors.textTertiary
                                        : AppColors.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 26),
                        _stats(saved.length, inProgress, completed),
                        const SizedBox(height: 30),
                        Divider(height: 1, color: AppColors.hairline),
                        const SizedBox(height: 22),
                        _comingSoonCard(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _signedOut(BuildContext context) => SafeArea(
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
          child: Row(
            children: [
              Text('Profile', style: AppText.title),
              const Spacer(),
              IconButton(
                tooltip: 'Settings',
                onPressed: () => _openSettings(context),
                style: IconButton.styleFrom(
                  foregroundColor: AppColors.textPrimary,
                  backgroundColor: AppColors.surface,
                  shape: const CircleBorder(),
                ),
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: const ProfileAccountSection(),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  /// Gutter between the window edge and the page content on desktop.
  static const double _desktopGutter = 40;

  /// Desktop avatar diameter, and how far it hangs below the banner (half).
  static const double _desktopAvatarSize = 112;
  static const double _desktopAvatarOverhang = _desktopAvatarSize / 2;

  /// Windows layout: the page fills the whole window and never scrolls, and
  /// stays compact.
  ///
  /// A short banner spans edge to edge. Under it, one row holds the name and
  /// bio (beside the avatar that hangs from the banner) with the three stats
  /// right-aligned on the same row, so the identity takes one band instead of
  /// three. The mascot fills the space below at its natural size. On a narrow
  /// window the stats drop under the name, and everything shrinks to fit rather
  /// than overflowing or scrolling. The phone-only gap reserved for the floating
  /// dock is gone.
  Widget _desktopLayout(
    BuildContext context,
    ViewerProfile profile,
    int saved,
    int inProgress,
    int completed,
  ) => LayoutBuilder(
    builder: (context, box) {
      final coverHeight = (box.maxHeight * 0.24).clamp(140.0, 220.0);
      final contentWidth = (box.maxWidth - _desktopGutter * 2).clamp(
        240.0,
        double.infinity,
      );
      // Wide windows put the stats on the name's row; narrow ones stack them.
      final wide = contentWidth >= 760;
      final below = (box.maxHeight - coverHeight).clamp(0.0, double.infinity);
      return Column(
        key: const ValueKey('profile-home-desktop'),
        children: [
          _cover(context, profile, height: coverHeight, desktop: true),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              _desktopGutter,
              8,
              _desktopGutter,
              0,
            ),
            child: SizedBox(
              height: math.min(wide ? 72.0 : 132.0, below * 0.45),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: contentWidth,
                  child: _desktopHeader(
                    context,
                    profile,
                    saved,
                    inProgress,
                    completed,
                    wide: wide,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: _desktopGutter),
            child: Divider(height: 1, color: AppColors.hairline),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                _desktopGutter,
                8,
                _desktopGutter,
                12,
              ),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: _comingSoonCard(size: 170),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );

  /// The row under the banner: name and bio next to the avatar, stats on the
  /// right ([wide]) or underneath (narrow).
  Widget _desktopHeader(
    BuildContext context,
    ViewerProfile profile,
    int saved,
    int inProgress,
    int completed, {
    required bool wide,
  }) {
    // Leaves room for the avatar that hangs down from the banner.
    final name = Padding(
      padding: const EdgeInsets.only(left: _desktopAvatarSize + 20),
      child: _nameBlock(context, profile),
    );
    final stats = _compactStats(saved, inProgress, completed);
    if (wide) {
      // The stats follow the name closely instead of sitting at the far edge.
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(child: name),
          const SizedBox(width: 28),
          stats,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [name, const SizedBox(height: 10), stats],
    );
  }

  /// Name, edit button, optional Kids label and bio, with the same switch
  /// animation the phone page uses when the active profile changes.
  Widget _nameBlock(BuildContext context, ViewerProfile profile) =>
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOutCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.08),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: Column(
          key: ValueKey(profile.id),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    profile.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.title.copyWith(fontSize: 26),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Edit profile',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => openViewerProfileEditor(
                    context,
                    _profiles,
                    profile: profile,
                  ),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                ),
              ],
            ),
            if (profile.isKids) Text('Kids profile', style: AppText.caption),
            GestureDetector(
              onTap: () =>
                  openViewerProfileEditor(context, _profiles, profile: profile),
              child: Text(
                profile.bio.isEmpty ? 'Add a bio' : profile.bio,
                style: AppText.body.copyWith(
                  fontSize: 15,
                  color: profile.bio.isEmpty
                      ? AppColors.textTertiary
                      : AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );

  /// The three stats in a compact row, with thin dividers between them.
  Widget _compactStats(int saved, int inProgress, int completed) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _compactStat('$saved', 'My List'),
      _statDivider(),
      _compactStat('$inProgress', 'In progress'),
      _statDivider(),
      _compactStat('$completed', 'Completed'),
    ],
  );

  Widget _compactStat(String value, String label) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: AppText.title.copyWith(fontSize: 24)),
        Text(label, style: AppText.caption.copyWith(fontSize: 12)),
      ],
    ),
  );

  Widget _statDivider() => SizedBox(
    height: 30,
    child: VerticalDivider(width: 1, color: AppColors.hairline),
  );

  void _openDonate(BuildContext context) => Navigator.of(
    context,
  ).push<void>(MaterialPageRoute<void>(builder: (_) => const DonateScreen()));

  Widget _cover(
    BuildContext context,
    ViewerProfile profile, {
    double? height,
    bool desktop = false,
  }) {
    final photo = profilePhotoForFace(
      profile: profile,
      accountPhotoUrl: _accountPhoto(),
    );
    final topInset = MediaQuery.paddingOf(context).top;
    final imageWidth =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round()
            .clamp(1, desktop ? 2560 : 1600);
    final gutter = desktop ? _desktopGutter : 20.0;
    return SizedBox(
      height: height ?? topInset + 190,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [AppColors.surface, AppColors.bg],
                    ),
                  ),
                ),
                if (profile.coverUrl != null)
                  CachedNetworkImage(
                    imageUrl: profile.coverUrl!,
                    cacheManager: AppImageCache.cacheManagerOrDefault,
                    fit: BoxFit.cover,
                    // A wide, short desktop banner crops the picture; aim it a
                    // little above centre so faces stay in view.
                    alignment: desktop
                        ? const Alignment(0, -0.3)
                        : Alignment.center,
                    memCacheWidth: imageWidth,
                    fadeInDuration: const Duration(milliseconds: 240),
                    errorWidget: (_, _, _) => const SizedBox.shrink(),
                  ),
                if (profile.coverUrl != null)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          AppColors.bg.withValues(alpha: 0.04),
                          AppColors.bg.withValues(alpha: 0.22),
                          AppColors.bg,
                        ],
                        stops: const [0, 0.52, 0.82, 1],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Positioned(
            top: topInset + 10,
            left: gutter,
            right: gutter,
            child: Row(
              children: [
                Material(
                  color: AppColors.bg.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(24),
                  child: InkWell(
                    key: const ValueKey('profile-home-switch'),
                    borderRadius: BorderRadius.circular(24),
                    onTap: () => _openChooser(context),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 180),
                            child: Text(
                              profile.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.button,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                if (desktop) ...[
                  // Windows "Lock profile now" (acct-11): same as Ctrl+L;
                  // the launch gate asks the PIN again (or says to set one).
                  _coverAction(
                    key: const ValueKey('profile-home-lock'),
                    tooltip: context.l10n.lockProfileWithKeys(DesktopShortcuts.describeAll('app.lockProfile')),
                    icon: Icons.lock_outline_rounded,
                    onPressed: () => DesktopProfileRelock.lockNow(),
                  ),
                  const SizedBox(width: 8),
                  // History lives here on Windows (it left the sidebar);
                  // Ctrl+H opens the same page.
                  _coverAction(
                    key: const ValueKey('profile-home-history'),
                    tooltip: context.l10n.history,
                    icon: Icons.history_rounded,
                    onPressed: () => _openHistory(context),
                  ),
                  const SizedBox(width: 8),
                  // A desktop has room, so Settings and Donate are their own
                  // buttons instead of living behind a three-dots menu.
                  _coverAction(
                    key: const ValueKey('profile-home-settings'),
                    tooltip: 'Settings',
                    icon: Icons.settings_outlined,
                    onPressed: () => _openSettings(context),
                  ),
                  const SizedBox(width: 8),
                  _coverAction(
                    key: const ValueKey('profile-home-donate'),
                    tooltip: 'Donate',
                    icon: Icons.favorite_outline_rounded,
                    onPressed: () => _openDonate(context),
                  ),
                ] else
                  IconButton(
                    tooltip: 'Settings',
                    onPressed: () => _openSettings(context),
                    style: IconButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                      backgroundColor: Colors.black.withValues(alpha: 0.5),
                      shape: const CircleBorder(),
                    ),
                    icon: const Icon(Icons.settings_outlined),
                  ),
              ],
            ),
          ),
          Positioned(
            bottom: desktop ? -_desktopAvatarOverhang : -18,
            left: gutter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              switchInCurve: Curves.easeOutCubic,
              child: Semantics(
                key: ValueKey(profile.id),
                label: '${profile.name} avatar',
                child: Container(
                  width: desktop ? _desktopAvatarSize : 90,
                  height: desktop ? _desktopAvatarSize : 90,
                  padding: EdgeInsets.all(desktop ? 4 : 3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.bg,
                  ),
                  child: CircleAvatar(
                    backgroundColor: viewerProfileAvatarColor(profile.avatar),
                    child: ProfileAvatarFace(
                      profile: profile,
                      photoUrl: photo,
                      iconSize: desktop ? 48 : 38,
                      photoDiameter: desktop ? _desktopAvatarSize - 8 : 84,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Round translucent button used on the banner (settings, donate).
  Widget _coverAction({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) => IconButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      foregroundColor: AppColors.textPrimary,
      backgroundColor: Colors.black.withValues(alpha: 0.5),
      shape: const CircleBorder(),
    ),
    icon: Icon(icon),
  );

  Widget _stats(int saved, int inProgress, int completed) => Row(
    children: [
      _stat('$saved', 'My List'),
      _stat('$inProgress', 'In progress'),
      _stat('$completed', 'Completed'),
    ],
  );

  /// The mascot block shown while the page has no further sections. [size] is
  /// the picture's width and height (148 on phones, larger on desktop).
  Widget _comingSoonCard({double size = 148}) => Center(
    key: const ValueKey('zoro-coming-soon-section'),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        CachedNetworkImage(
          key: const ValueKey('zoro-coming-soon-gif'),
          imageUrl: _zoroGifUrl,
          cacheManager: AppImageCache.cacheManagerOrDefault,
          width: size,
          height: size,
          fit: BoxFit.contain,
          fadeInDuration: const Duration(milliseconds: 240),
          placeholder: (_, _) => SizedBox(width: size, height: size),
          errorWidget: (_, _, _) => const SizedBox.shrink(),
        ),
        const SizedBox(height: 4),
        Text(
          'More features are on their way with Zoro… he just got lost again.',
          textAlign: TextAlign.center,
          style: AppText.body.copyWith(color: AppColors.textSecondary),
        ),
      ],
    ),
  );

  Widget _stat(String value, String label) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: AppText.title),
        const SizedBox(height: 3),
        Text(label, style: AppText.caption),
      ],
    ),
  );
}

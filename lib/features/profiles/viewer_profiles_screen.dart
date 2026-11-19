import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../core/app_mode.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/desktop/desktop_context_menu.dart';
import '../../core/desktop/desktop_dialogs.dart' show showDesktopConfirm;
import '../../core/desktop/desktop_window.dart';
import '../../core/di/injector.dart';
import '../../core/profiles/profile_pin_store.dart';
import '../../core/models/media_item.dart';
import '../../core/ui/desktop_docked_panel.dart' show desktopPanelsEnabled;
import '../../core/profiles/viewer_profile.dart';
import '../../core/profiles/viewer_profile_avatar.dart';
import '../../core/profiles/profile_lock_store.dart';
import '../../core/profiles/synced_profile_lock_store.dart';
import '../../core/profiles/profile_picker_artwork.dart';
import '../../core/app_config.dart';
import '../auth/auth_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/image_fade.dart';
import '../../core/ui/native_cover_provider.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../l10n/l10n.dart';
import '../home/cubit/home_cubit.dart';
import '../auth/auth_screens.dart' show ProfileAccountSection;
import 'profile_unlock.dart';
import 'viewer_profile_editor_screen.dart';

const Object kViewerProfileHeroTag = 'viewer-profile-selector';


String _pickerBackdropUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host != 'image.tmdb.org') return url;
  final segments = uri.pathSegments;
  if (segments.length < 4 ||
      segments[0] != 't' ||
      segments[1] != 'p' ||
      !const {'w500', 'w780'}.contains(segments[2])) {
    return url;
  }
  return uri
      .replace(
        pathSegments: [...segments.take(2), 'w1280', ...segments.skip(3)],
      )
      .toString();
}

class ViewerProfilesScreen extends StatefulWidget {
  const ViewerProfilesScreen({
    super.key,
    this.selectionOnly = false,
    this.onSelected,
  });

  final bool selectionOnly;
  final VoidCallback? onSelected;

  @override
  State<ViewerProfilesScreen> createState() => _ViewerProfilesScreenState();
}

class _ViewerProfilesScreenState extends State<ViewerProfilesScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pickerEntrance;
  late final Animation<double> _screenOpacity;
  late final Animation<Offset> _screenSlide;
  late final Animation<double> _titleOpacity;
  late final Animation<double> _footerOpacity;
  final _enableSelectionHero = ValueNotifier(false);
  bool _selecting = false;
  bool _managingProfiles = false;
  bool _recoveryPromptShown = false;
  String? _pickerArtworkUrl;
  ProfilePickerArtwork? _pickerArtwork;
  Timer? _artworkRotation;

  // Windows picker (acct-7): one avatar key per profile so the number keys
  // can play the same press animation as a click, and whether the number
  // key handler was added (removed again in dispose).
  final Map<String, GlobalKey<_ProfileAvatarTapTargetState>> _desktopAvatarKeys =
      {};
  bool _desktopKeysAdded = false;

  /// Windows "Who's watching" layout and keys; phone and TV keep theirs.
  bool get _desktopPicker => widget.selectionOnly && desktopPanelsEnabled;

  ViewerProfileStore get _profiles => sl<ViewerProfileStore>();

  /// The signed-in account's photo, for the default profile's face. Absent
  /// in widget tests and when signed out — callers fall back to icons.
  String? _accountPhoto() =>
      sl.isRegistered<AuthCubit>() ? sl<AuthCubit>().state.avatarUrl : null;

  MediaItem? _pickerBackdropItem() {
    if (!sl.isRegistered<HomeCubit>()) return null;
    for (final item in sl<HomeCubit>().state.heroItems) {
      if (item.isAdult) continue;
      final art = item.banner ?? item.cover;
      if (art != null && art.isNotEmpty) return item;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_promptForRecovery());
    });
    _pickerEntrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _screenOpacity = CurvedAnimation(
      parent: _pickerEntrance,
      curve: Curves.easeOutCubic,
    );
    _screenSlide = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(_pickerEntrance);
    _titleOpacity = CurvedAnimation(
      parent: _pickerEntrance,
      curve: const Interval(0, 0.3, curve: Curves.easeOutCubic),
    );
    _footerOpacity = CurvedAnimation(
      parent: _pickerEntrance,
      curve: const Interval(0.7, 1, curve: Curves.easeOutCubic),
    );
    if (_desktopPicker) {
      _desktopKeysAdded = true;
      HardwareKeyboard.instance.addHandler(_onDesktopPickerKey);
    }
    if (widget.selectionOnly) {
      if (Hive.isBoxOpen(ViewerProfileStore.boxName)) {
        final artwork = _pickerArtwork = ProfilePickerArtwork(
          box: Hive.box(ViewerProfileStore.boxName),
          fetchManifest: () async => (await sl<Dio>().get<Object>(
            kProfilePickerArtworkManifestUrl,
            options: Options(receiveTimeout: const Duration(seconds: 4)),
          )).data,
        );
        _pickerArtworkUrl = artwork.cachedUrl;
        if (sl.isRegistered<Dio>()) unawaited(_loadNextArtwork());
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (MediaQuery.disableAnimationsOf(context)) {
          _pickerEntrance.value = 1.0;
        } else {
          _pickerEntrance.forward();
        }
      });
    }
  }

  Future<void> _loadNextArtwork() async {
    final artwork = _pickerArtwork;
    if (artwork == null) return;
    final url = await artwork.next();
    if (!mounted || url == null) return;
    if (url != _pickerArtworkUrl) setState(() => _pickerArtworkUrl = url);
    if (artwork.canRotate) {
      _artworkRotation ??= Timer.periodic(const Duration(seconds: 3), (_) {
        unawaited(_loadNextArtwork());
      });
    }
  }

  double _avatarStart(int i, int count, double gapScale) =>
      0.25 + (0.45 * gapScale * i / count);
  double _avatarEnd(int i, int count, double gapScale) =>
      (_avatarStart(i, count, gapScale) + 0.45 * gapScale / count + 0.15).clamp(
        0.0,
        1.0,
      );

  Animation<double> _avatarScale(int i, int count, double gapScale) =>
      Tween<double>(begin: 0.8, end: 1.0)
          .chain(CurveTween(curve: Curves.easeOutBack))
          .animate(
            CurvedAnimation(
              parent: _pickerEntrance,
              curve: Interval(
                _avatarStart(i, count, gapScale),
                _avatarEnd(i, count, gapScale),
              ),
            ),
          );

  /// Windows picker: keys 1-9 (top row or numpad) choose the profile in that
  /// position, like clicking it. Ignored while typing, with Ctrl/Alt held,
  /// in the profile manager, or when another route covers the picker.
  bool _onDesktopPickerKey(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted || _managingProfiles) return false;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return false;
    }
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (DesktopWindow.focusInTextField()) return false;
    final index = desktopPickerDigitIndex(event.logicalKey);
    final profiles = _profiles.profiles;
    if (index == null || index >= profiles.length) return false;
    _activateDesktopProfile(profiles[index]);
    return true;
  }

  /// Chooses [profile] with the same press animation as a click.
  void _activateDesktopProfile(ViewerProfile profile) {
    final avatar = _desktopAvatarKeys[profile.id]?.currentState;
    if (avatar == null) {
      unawaited(_switchTo(profile));
    } else {
      unawaited(avatar.runSelection());
    }
  }

  /// Right-click / Menu-key menu on a picker profile (acct-7 Option B).
  /// The PIN row says Set or Change depending on the saved lock status.
  Future<void> _openDesktopProfileMenu(
    ViewerProfile profile, {
    Offset? position,
    BuildContext? anchor,
  }) async {
    final locks = sl.isRegistered<ProfileLockStore>()
        ? sl<ProfileLockStore>()
        : null;
    final hasPin = await profileHasPin(profile.id, locks);
    if (!mounted) return;
    await showDesktopContextMenu<void>(
      context,
      position: position,
      anchor: position == null ? anchor : null,
      items: [
        DesktopMenuItem(
          label: context.l10n.editProfile,
          icon: Icons.edit_outlined,
          onTap: () => unawaited(_edit(profile)),
        ),
        if (locks != null)
          DesktopMenuItem(
            label: hasPin
                ? context.l10n.changePinEllipsis
                : context.l10n.setPinEllipsis,
            icon: hasPin ? Icons.lock_reset_rounded : Icons.lock_outline_rounded,
            onTap: () => unawaited(manageProfileLock(context, profile)),
          ),
        if (!profile.isDefault) ...[
          const DesktopMenuItem.divider(),
          DesktopMenuItem(
            label: context.l10n.deleteProfile,
            icon: Icons.delete_outline_rounded,
            destructive: true,
            onTap: () => unawaited(_delete(profile)),
          ),
        ],
      ],
    );
  }

  @override
  void dispose() {
    if (_desktopKeysAdded) {
      HardwareKeyboard.instance.removeHandler(_onDesktopPickerKey);
    }
    _artworkRotation?.cancel();
    _enableSelectionHero.dispose();
    _pickerEntrance.dispose();
    super.dispose();
  }

  Future<void> _switchTo(ViewerProfile profile) async {
    // Both the avatar and the name label land here. Sticky: every real flow
    // closes the picker after a selection, so a second tap is always a
    // double-tap, never a new choice.
    if (_selecting) return;
    final owner = _profiles.ownerKey;
    // A locked profile asks for its PIN first, including when it is the one
    // already active (launch picker). Cancel or a wrong PIN stays on the picker.
    if (!await ensureProfileAccess(context, profile)) return;
    if (!mounted ||
        _selecting ||
        _profiles.ownerKey != owner ||
        !_profiles.profiles.any((p) => p.id == profile.id)) {
      return;
    }
    final locks = sl.isRegistered<ProfileLockStore>()
        ? sl<ProfileLockStore>()
        : null;
    if (_profiles.activeId != profile.id) locks?.approveSwitch(profile.id);
    _selecting = true;
    try {
      await _profiles.switchTo(profile.id);
      if (_profiles.ownerKey != owner || _profiles.activeId != profile.id) {
        _selecting = false;
        return;
      }
      final onSelected = widget.onSelected;
      if (mounted && onSelected != null) {
        _enableSelectionHero.value = true;
        onSelected();
      }
      if (mounted && onSelected == null) Navigator.of(context).pop();
    } catch (_) {
      _selecting = false;
      rethrow;
    } finally {
      locks?.consumeSwitchApproval(profile.id);
    }
  }

  Future<void> _edit([ViewerProfile? profile, int initialAvatar = 0]) async {
    if (profile != null && !await ensureProfileAccess(context, profile)) {
      return;
    }
    if (!mounted) return;
    await openViewerProfileEditor(
      context,
      _profiles,
      profile: profile,
      initialAvatar: initialAvatar,
    );
  }

  /// Turning the launch picker off opens straight into the active profile —
  /// even a locked one. The locks stay set for switching inside the app, so
  /// confirm the trade-off explicitly instead of silently dropping launch
  /// protection the user may have set up for kids.
  Future<void> _toggleAskOnLaunch() async {
    if (!_profiles.askOnLaunch) {
      await _profiles.setAskOnLaunch(true);
      return;
    }
    // Windows uses the same synced lock as the phone, which is not asked at
    // launch with the picker off, so it confirms exactly like the phone.
    const title = "Turn off Who's watching?";
    const message =
        'The app will open straight into the active profile — no PIN at launch. '
        'Profile PINs stay on for switching profiles inside the app.';
    // Windows: graphite confirm (Enter turns off, Esc cancels); the phone
    // keeps its plain AlertDialog below unchanged.
    final confirmed = desktopPanelsEnabled
        ? await showDesktopConfirm(
            context,
            title: title,
            message: message,
            confirmLabel: 'Turn off',
            cancelLabel: 'Cancel',
          )
        : await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text(title),
              content: const Text(message),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Turn off'),
                ),
              ],
            ),
          );
    if (!mounted || confirmed != true) return;
    await _profiles.setAskOnLaunch(false);
  }

  Future<void> _delete(ViewerProfile profile) async {
    // A lock that doesn't cover deletion is decoration: removing the profile
    // wipes the PIN with it.
    if (!await ensureProfileAccess(context, profile)) return;
    if (!mounted) return;
    final message =
        'Delete ${profile.name} and its saved lists and progress from this account?';
    // Windows: graphite confirm with a red Delete button (Enter deletes, Esc
    // cancels); the phone keeps its plain AlertDialog below unchanged.
    final confirmed = desktopPanelsEnabled
        ? await showDesktopConfirm(
            context,
            title: 'Delete profile?',
            message: message,
            confirmLabel: 'Delete',
            cancelLabel: 'Cancel',
            destructive: true,
          )
        : await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Delete profile?'),
              content: Text(message),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          );
    // The PIN was already checked above (before the dialog), so a second
    // prompt here would only ask twice.
    if (confirmed != true || !mounted) return;
    final deleted = await _profiles.delete(profile.id);
    if (deleted && sl.isRegistered<ProfilePinStore>()) {
      await sl<ProfilePinStore>().forget(profile.id);
    }
    if (!deleted && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.offlineBody)));
    }
  }

  Future<void> _promptForRecovery() async {
    if (_recoveryPromptShown || _profiles.recoverableProfiles.isEmpty) return;
    _recoveryPromptShown = true;
    final profile = _profiles.recoverableProfiles.first;
    final title = '${profile.name} is on this device only';
    const message =
        'This profile is missing from cloud sync. It may have been created offline or deleted on another device. Restore it only if you want it on all your devices. Its local data is safe either way.';
    // Windows: graphite confirm (Enter restores, Esc means Later); the phone
    // keeps its plain AlertDialog below unchanged.
    final restore = desktopPanelsEnabled
        ? await showDesktopConfirm(
            context,
            title: title,
            message: message,
            confirmLabel: 'Restore to cloud',
            cancelLabel: 'Later',
          )
        : await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(title),
              content: const Text(message),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Later'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Restore to cloud'),
                ),
              ],
            ),
          );
    if (!mounted || restore != true) return;
    if (!await _profiles.restoreRecoverable(profile.id) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not restore profile. Try again later.'),
        ),
      );
    }
  }

  void _openProfileManager() {
    setState(() => _managingProfiles = true);
  }

  void _closeProfileManager() {
    setState(() => _managingProfiles = false);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.selectionOnly && !_managingProfiles) {
      return ValueListenableBuilder<bool>(
        valueListenable: _enableSelectionHero,
        builder: (context, enabled, child) =>
            HeroMode(enabled: enabled, child: child!),
        child: FadeTransition(
          key: const ValueKey('profile-picker-entry-screen-fade'),
          opacity: _screenOpacity,
          child: SlideTransition(
            key: const ValueKey('profile-picker-entry-screen-slide'),
            position: _screenSlide,
            child: _buildProfilePicker(),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(
        'Profiles',
        onBack: widget.selectionOnly ? _closeProfileManager : null,
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: _profiles.revision,
        builder: (context, _, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 36),
          children: [
            if (sl.isRegistered<AuthCubit>()) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                child: Text('Account', style: AppText.headline),
              ),
              BlocProvider.value(
                value: sl<AuthCubit>(),
                child: const ProfileAccountSection(),
              ),
              const Divider(height: 1),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
              child: Row(
                children: [
                  Hero(tag: kViewerProfileHeroTag, child: _profileHeaderIcon()),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Choose who is watching. Each profile keeps its own list and progress.',
                      style: AppText.caption,
                    ),
                  ),
                ],
              ),
            ),
            SettingsCard(
              children: [
                for (var i = 0; i < _profiles.profiles.length; i++) ...[
                  _profileTile(_profiles.profiles[i]),
                  if (i < _profiles.profiles.length - 1)
                    const Divider(height: 1, indent: 60),
                ],
              ],
            ),
            const SizedBox(height: 14),
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.login_rounded,
                  title: 'Ask who is watching on launch',
                  subtitle:
                      'Off opens straight into the active profile, even if it has a PIN.',
                  trailing: Switch.adaptive(
                    value: _profiles.askOnLaunch,
                    onChanged: (_) => _toggleAskOnLaunch(),
                  ),
                  onTap: _toggleAskOnLaunch,
                ),
              ],
            ),
            const SizedBox(height: 14),
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.person_add_alt_1_rounded,
                  title: 'Add profile',
                  subtitle:
                      _profiles.profiles.length >=
                          ViewerProfileStore.maxProfiles
                      ? 'Maximum ${ViewerProfileStore.maxProfiles} profiles reached'
                      : 'Create another profile on this account',
                  onTap:
                      _profiles.profiles.length >=
                          ViewerProfileStore.maxProfiles
                      ? null
                      : () => _edit(
                          null,
                          defaultAvatarForNewProfile(_profiles.profiles.length),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Kids profiles hide adult-rated catalogue titles. Third-party source catalogs may not have age ratings, so this is not a parental lock.',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfilePicker() {
    final isTv = sl.isRegistered<AppMode>() && sl<AppMode>().isTv;
    final backdrop = _pickerBackdropItem();
    final screenSize = MediaQuery.sizeOf(context);
    final useWideArt = isTv || screenSize.width >= screenSize.height;
    final sourceBackdropUrl = useWideArt
        ? backdrop?.banner ?? backdrop?.cover
        : backdrop?.cover ?? backdrop?.banner;
    final backdropUrl =
        _pickerArtworkUrl ??
        (sourceBackdropUrl == null
            ? null
            : _pickerBackdropUrl(sourceBackdropUrl));
    final backdropProvider = backdropUrl == null || backdropUrl.isEmpty
        ? null
        : nativeCoverProvider(
            backdropUrl,
            _pickerArtworkUrl == null ? backdrop?.coverHeaders : null,
          );
    final backdropWidth = math
        .min(
          (MediaQuery.sizeOf(context).width *
                  MediaQuery.devicePixelRatioOf(context))
              .round(),
          2560,
        )
        .toInt();
    if (isTv && screenSize.width > screenSize.height) {
      return _buildTvProfilePicker(
        backdropProvider: backdropProvider,
        backdropUrl: backdropUrl,
        backdropWidth: backdropWidth,
      );
    }
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            key: const ValueKey('profile-picker-background'),
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.7),
                radius: 1.35,
                colors: [
                  AppColors.accent.withValues(alpha: 0.28),
                  AppColors.bg,
                ],
              ),
            ),
          ),
          if (backdropProvider != null)
            Positioned.fill(
              bottom: useWideArt ? 0 : screenSize.height * 0.4,
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: AnimatedSwitcher(
                    key: const ValueKey('profile-picker-backdrop-switcher'),
                    duration: const Duration(milliseconds: 900),
                    reverseDuration: const Duration(milliseconds: 700),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) {
                      final curved = CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                        reverseCurve: Curves.easeInCubic,
                      );
                      return FadeTransition(
                        opacity: curved,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0.025, 0),
                            end: Offset.zero,
                          ).animate(curved),
                          child: ScaleTransition(
                            scale: Tween<double>(
                              begin: 1.04,
                              end: 1,
                            ).animate(curved),
                            child: child,
                          ),
                        ),
                      );
                    },
                    child: SizedBox.expand(
                      key: ValueKey(backdropUrl),
                      child: Image(
                        key: const ValueKey('profile-picker-backdrop-image'),
                        image: ResizeImage(
                          backdropProvider,
                          width: backdropWidth,
                        ),
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                        frameBuilder: imageFadeIn,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: isTv
                        ? const [0, 0.18, 0.42, 0.72, 1]
                        : const [0, 0.2, 0.36, 0.56, 1],
                    colors: isTv
                        ? [
                            AppColors.bg.withValues(alpha: 0.52),
                            AppColors.bg.withValues(alpha: 0.12),
                            AppColors.bg.withValues(alpha: 0.34),
                            AppColors.bg.withValues(alpha: 0.96),
                            AppColors.bg,
                          ]
                        : [
                            AppColors.bg.withValues(alpha: 0.24),
                            AppColors.bg.withValues(alpha: 0.04),
                            AppColors.bg.withValues(alpha: 0.78),
                            AppColors.bg,
                            AppColors.bg,
                          ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            bottom: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 900;
                final diameter = isTv
                    ? (wide ? 160.0 : 120.0)
                    : (constraints.maxWidth >= 600 ? 112.0 : 100.0);
                final columns = isTv || wide ? 4 : 2;
                final gridWidth = math.min(
                  isTv || wide
                      ? (diameter + 32) * columns + 16 * (columns - 1)
                      : constraints.maxWidth - 32,
                  math.max(0.0, constraints.maxWidth - (wide ? 96 : 32)),
                );
                const topPadding = 24.0;
                final bottomPadding = math.max(
                  24.0,
                  MediaQuery.paddingOf(context).bottom + 16,
                );
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: math.max(
                        0.0,
                        constraints.maxHeight -
                            topPadding -
                            (isTv ? bottomPadding : 0),
                      ),
                    ),
                    child: Container(
                      key: const ValueKey('profile-picker-bottom-content'),
                      width: math.min(
                        constraints.maxWidth,
                        isTv ? 1400.0 : 820.0,
                      ),
                      padding: EdgeInsets.fromLTRB(
                        16,
                        topPadding,
                        16,
                        bottomPadding,
                      ),
                      child: ValueListenableBuilder<int>(
                        valueListenable: _profiles.revision,
                        builder: (context, _, _) {
                          final lastName = _profiles.active.value?.name;
                          final title = FadeTransition(
                            key: const ValueKey('profile-picker-title-fade'),
                            opacity: _titleOpacity,
                            child: Column(
                              children: [
                                Text(
                                  "Who's watching?",
                                  textAlign: TextAlign.center,
                                  style: AppText.title.copyWith(
                                    fontSize: wide ? 34 : 28,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 7),
                                Text(
                                  lastName == null
                                      ? 'Pick up where you left off.'
                                      : 'Ready for the next watch, $lastName?',
                                  textAlign: TextAlign.center,
                                  style: AppText.caption.copyWith(
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          );
                          final grid = _pickerGrid(
                            diameter: diameter,
                            gridWidth: gridWidth,
                            columns: columns,
                            isTv: isTv,
                            gapScale: isTv ? 0.5 : 1.0,
                          );
                          final manage = FadeTransition(
                            key: const ValueKey('profile-picker-footer-fade'),
                            opacity: _footerOpacity,
                            child: _manageProfilesButton(isTv),
                          );
                          if (isTv) {
                            return Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                title,
                                SizedBox(height: wide ? 28 : 16),
                                grid,
                                SizedBox(height: wide ? 16 : 8),
                                manage,
                              ],
                            );
                          }
                          return Column(
                            // Windows centres the picker in the window; the
                            // phone keeps it low in the thumb zone.
                            mainAxisAlignment: _desktopPicker
                                ? MainAxisAlignment.center
                                : MainAxisAlignment.end,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              title,
                              const SizedBox(height: 20),
                              grid,
                              const SizedBox(height: 16),
                              manage,
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTvProfilePicker({
    required ImageProvider<Object>? backdropProvider,
    required String? backdropUrl,
    required int backdropWidth,
  }) => Scaffold(
    backgroundColor: AppColors.bg,
    body: Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.7, -0.8),
              radius: 1.4,
              colors: [AppColors.surface2, AppColors.bg],
            ),
          ),
        ),
        Positioned.fill(
          key: const ValueKey('tv-profile-picker-art-panel'),
          child: backdropProvider == null
              ? const SizedBox.shrink()
              : ExcludeSemantics(
                  child: IgnorePointer(
                    child: AnimatedSwitcher(
                      key: const ValueKey('profile-picker-backdrop-switcher'),
                      duration: const Duration(milliseconds: 900),
                      reverseDuration: const Duration(milliseconds: 700),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOutCubic,
                          reverseCurve: Curves.easeInCubic,
                        ),
                        child: child,
                      ),
                      child: SizedBox.expand(
                        key: ValueKey(backdropUrl),
                        child: Image(
                          key: const ValueKey('profile-picker-backdrop-image'),
                          image: ResizeImage(
                            backdropProvider,
                            width: backdropWidth,
                          ),
                          fit: BoxFit.cover,
                          alignment: Alignment.centerRight,
                          frameBuilder: imageFadeIn,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  stops: const [0, 0.3, 0.52, 0.76, 1],
                  colors: [
                    AppColors.bg.withValues(alpha: 0.98),
                    AppColors.bg.withValues(alpha: 0.92),
                    AppColors.bg.withValues(alpha: 0.62),
                    AppColors.bg.withValues(alpha: 0.16),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0, 0.24, 0.72, 1],
                  colors: [
                    AppColors.bg.withValues(alpha: 0.12),
                    Colors.transparent,
                    Colors.transparent,
                    AppColors.bg.withValues(alpha: 0.2),
                  ],
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(44, 28, 28, 28),
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: ValueListenableBuilder<int>(
                        valueListenable: _profiles.revision,
                        builder: (context, _, _) {
                          final lastName = _profiles.active.value?.name;
                          final profiles = _profiles.profiles;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "Who's watching?",
                                style: AppText.title.copyWith(
                                  fontSize: 34,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                lastName == null
                                    ? 'Pick up where you left off.'
                                    : 'Ready for the next watch, $lastName?',
                                style: AppText.body.copyWith(
                                  color: AppColors.textSecondary,
                                  fontSize: 17,
                                ),
                              ),
                              const SizedBox(height: 22),
                              Expanded(
                                child: SingleChildScrollView(
                                  child: Column(
                                    children: [
                                      for (var i = 0; i < profiles.length; i++)
                                        _tvProfileChoice(
                                          profiles[i],
                                          autofocus: i == 0,
                                        ),
                                      if (profiles.length <
                                          ViewerProfileStore.maxProfiles)
                                        _tvAddProfileChoice(),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: _manageProfilesButton(true),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
                const Expanded(flex: 6, child: SizedBox.expand()),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _tvProfileChoice(ViewerProfile profile, {required bool autofocus}) {
    final selected = _profiles.activeId == profile.id;
    final photo = profilePhotoForFace(
      profile: profile,
      accountPhotoUrl: _accountPhoto(),
    );
    final avatarKey = GlobalKey<_ProfileAvatarTapTargetState>();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TvListFocusable(
        autofocus: autofocus,
        semanticLabel: 'Select profile ${profile.name}',
        variant: TvFocusVariant.none,
        onTap: () {
          final avatar = avatarKey.currentState;
          if (avatar == null) {
            _switchTo(profile);
          } else {
            avatar.runSelection();
          }
        },
        builder: (focused) => Align(
          alignment: AlignmentDirectional.centerStart,
          child: AnimatedContainer(
            key: ValueKey('tv-profile-choice-${profile.id}'),
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            width: 360,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: focused
                  ? Colors.white
                  : selected
                  ? AppColors.surface.withValues(alpha: 0.82)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(36),
            ),
            child: Row(
              children: [
                _ProfileAvatarTapTarget(
                  key: avatarKey,
                  profileId: profile.id,
                  diameter: 64,
                  fill: viewerProfileAvatarColor(profile.avatar),
                  shape: const CircleBorder(),
                  onTap: () => _switchTo(profile),
                  child: ProfileAvatarFace(
                    profile: profile,
                    photoUrl: photo,
                    iconSize: 28,
                    photoDiameter: 64,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.headline.copyWith(
                          color: focused
                              ? AppColors.bg
                              : selected
                              ? AppColors.textPrimary
                              : AppColors.textSecondary,
                          fontSize: 19,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                        ),
                      ),
                      if (profile.isKids)
                        Text(
                          'KIDS',
                          style: AppText.overline.copyWith(
                            color: focused ? AppColors.bg : AppColors.accent,
                          ),
                        ),
                    ],
                  ),
                ),
                if (selected)
                  Icon(
                    Icons.check_circle_rounded,
                    color: AppColors.accent,
                    size: 22,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tvAddProfileChoice() => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TvListFocusable(
      semanticLabel: 'Add profile',
      variant: TvFocusVariant.none,
      onTap: () =>
          _edit(null, defaultAvatarForNewProfile(_profiles.profiles.length)),
      builder: (focused) => Align(
        alignment: AlignmentDirectional.centerStart,
        child: AnimatedContainer(
          key: const ValueKey('tv-profile-choice-add'),
          duration: const Duration(milliseconds: 150),
          width: 360,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: focused ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(36),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 64,
                height: 64,
                child: Icon(
                  Icons.add_rounded,
                  size: 38,
                  color: focused ? AppColors.bg : AppColors.textSecondary,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Add profile',
                style: AppText.headline.copyWith(
                  color: focused ? AppColors.bg : AppColors.textSecondary,
                  fontSize: 19,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _manageProfilesButton(bool isTv) {
    if (isTv) {
      return TvListFocusable(
        waitForKeyUp: true,
        semanticLabel: 'Manage profiles',
        onTap: _openProfileManager,
        builder: (focused) => AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: focused
                ? Colors.white
                : Colors.white.withValues(alpha: 0.12),
          ),
          child: Icon(
            Icons.manage_accounts_rounded,
            size: 24,
            color: focused ? AppColors.bg : AppColors.textPrimary,
          ),
        ),
      );
    }

    return TextButton.icon(
      onPressed: _openProfileManager,
      icon: const Icon(Icons.edit_rounded, size: 18),
      label: const Text('Manage profiles'),
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: AppColors.hairline),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    );
  }

  Widget _pickerGrid({
    required double diameter,
    required double gridWidth,
    required int columns,
    required bool isTv,
    required double gapScale,
  }) {
    final profiles = _profiles.profiles;
    final hasAddTile = profiles.length < ViewerProfileStore.maxProfiles;
    final count = profiles.length + (hasAddTile ? 1 : 0);
    // Windows starts keyboard focus on the profile used last time, so Enter
    // reopens it straight away; elsewhere the first tile (TV) as before.
    final activeIndex = profiles.indexWhere((p) => p.id == _profiles.activeId);
    final desktopFocusIndex = activeIndex < 0 ? 0 : activeIndex;
    return SizedBox(
      width: gridWidth.toDouble(),
      child: GridView.count(
        key: const ValueKey('profile-picker-grid'),
        crossAxisCount: columns,
        crossAxisSpacing: 4,
        mainAxisSpacing: 16,
        // Windows tiles add a focus ring around the avatar and name.
        mainAxisExtent: diameter + (_desktopPicker ? 60 : 48),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (var i = 0; i < profiles.length; i++)
            ScaleTransition(
              key: ValueKey('profile-entrance-${profiles[i].id}'),
              scale: _avatarScale(i, count, gapScale),
              child: _profilePickerChoice(
                profile: profiles[i],
                diameter: diameter,
                isTv: isTv,
                autofocus: _desktopPicker ? i == desktopFocusIndex : i == 0,
                position: i,
              ),
            ),
          if (hasAddTile)
            ScaleTransition(
              key: const ValueKey('profile-entrance-add'),
              scale: _avatarScale(profiles.length, count, gapScale),
              child: _profilePickerAction(
                title: 'Add',
                semanticLabel: 'Add profile',
                icon: Icons.add_rounded,
                diameter: diameter,
                isTv: isTv,
                autofocus: profiles.isEmpty,
                onTap: () => _edit(
                  null,
                  defaultAvatarForNewProfile(_profiles.profiles.length),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _profilePickerChoice({
    required ViewerProfile profile,
    required double diameter,
    required bool isTv,
    required bool autofocus,
    int position = 0,
  }) {
    final selected = _profiles.activeId == profile.id;
    final fill = viewerProfileAvatarColor(profile.avatar);
    final desktop = _desktopPicker && !isTv;
    // Windows keeps one key per profile so number keys reach the avatar.
    final avatarKey = desktop
        ? _desktopAvatarKeys.putIfAbsent(
            profile.id,
            GlobalKey<_ProfileAvatarTapTargetState>.new,
          )
        : GlobalKey<_ProfileAvatarTapTargetState>();
    final photo = profilePhotoForFace(
      profile: profile,
      accountPhotoUrl: _accountPhoto(),
    );

    Widget content(bool focused) => SizedBox(
      width: diameter + 8,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ProfileAvatarTapTarget(
            key: avatarKey,
            profileId: profile.id,
            diameter: diameter,
            fill: fill,
            shape: CircleBorder(
              side: BorderSide(
                color: AppColors.textPrimary.withValues(alpha: 0.25),
              ),
            ),
            onTap: () => _switchTo(profile),
            // On Windows the whole tile takes focus (with its own ring), so
            // the avatar's ink is not a second Tab stop.
            focusable: !desktop,
            child: ProfileAvatarFace(
              profile: profile,
              photoUrl: photo,
              iconSize: diameter * 0.42,
              photoDiameter: diameter,
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _switchTo(profile),
            child: Column(
              children: [
                const SizedBox(height: 6),
                Text(
                  profile.name,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.headline.copyWith(
                    color: focused || selected
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                    fontSize: isTv ? 18 : 15,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
                if (profile.isKids) ...[
                  const SizedBox(height: 3),
                  Text(
                    'KIDS',
                    style: AppText.overline.copyWith(
                      color: AppColors.accent,
                      fontSize: 10,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    if (isTv) {
      return TvListFocusable(
        autofocus: autofocus,
        semanticLabel: 'Select profile ${profile.name}',
        onTap: () {
          final avatar = avatarKey.currentState;
          if (avatar == null) {
            _switchTo(profile);
          } else {
            avatar.runSelection();
          }
        },
        builder: content,
      );
    }
    if (desktop) {
      // Windows (acct-7): focusable tile with a ring, Enter/Space opens,
      // arrows move, right-click / Menu key opens Edit / PIN / Delete, and a
      // tooltip names the profile, its kind, its lock and its number key.
      return _ProfileLockStatus(
        profileId: profile.id,
        builder: (locked) => _DesktopPickerTile(
          key: ValueKey('desktop-picker-tile-${profile.id}'),
          autofocus: autofocus,
          semanticLabel: context.l10n.selectProfileNamed(profile.name),
          tooltip: [
            profile.name,
            if (profile.isKids) context.l10n.kidsProfile,
            if (locked) context.l10n.pinProtected,
            if (position < 9) context.l10n.pressNToChoose(position + 1),
          ].join('\n'),
          onActivate: () => _activateDesktopProfile(profile),
          onMenu: (position, anchor) => unawaited(
            _openDesktopProfileMenu(
              profile,
              position: position,
              anchor: anchor,
            ),
          ),
          builder: content,
        ),
      );
    }
    return content(false);
  }

  Widget _profilePickerAction({
    required String title,
    required String semanticLabel,
    required IconData icon,
    required double diameter,
    required bool isTv,
    required bool autofocus,
    required VoidCallback onTap,
  }) {
    Widget content(bool focused) => SizedBox(
      width: diameter + 8,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            key: ValueKey('profile-picker-action-$title'),
            duration: const Duration(milliseconds: 180),
            width: diameter,
            height: diameter,
            decoration: BoxDecoration(
              color: AppColors.surface2,
              shape: BoxShape.circle,
              border: focused
                  ? Border.all(color: AppColors.accent, width: 2)
                  : Border.all(color: AppColors.hairline),
            ),
            child: Icon(
              icon,
              size: diameter * 0.38,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.headline.copyWith(
              color: AppColors.textSecondary,
              fontSize: isTv ? 18 : 15,
            ),
          ),
        ],
      ),
    );

    if (isTv) {
      return TvListFocusable(
        autofocus: autofocus,
        semanticLabel: semanticLabel,
        onTap: onTap,
        builder: content,
      );
    }
    if (_desktopPicker) {
      // Windows: the Add tile joins the arrow-key grid with the same ring.
      return _DesktopPickerTile(
        key: ValueKey('desktop-picker-tile-action-$title'),
        autofocus: autofocus,
        semanticLabel: semanticLabel,
        tooltip: semanticLabel,
        onActivate: onTap,
        builder: (focused) => InkWell(
          customBorder: const CircleBorder(),
          canRequestFocus: false,
          onTap: onTap,
          child: content(focused),
        ),
      );
    }
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: content(false),
    );
  }

  Widget _profileHeaderIcon() => Container(
    width: 34,
    height: 34,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: AppColors.accent.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Icon(
      Icons.switch_account_rounded,
      color: AppColors.accent,
      size: 19,
    ),
  );

  Widget _profileTile(ViewerProfile profile) {
    final selected = _profiles.activeId == profile.id;
    return SettingsTile(
      icon: viewerProfileAvatarIcon(profile.avatar),
      leading: Container(
        key: ValueKey('profile-tile-avatar-${profile.id}'),
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: viewerProfileAvatarColor(profile.avatar),
        ),
        child: ProfileAvatarFace(
          profile: profile,
          photoUrl: profilePhotoForFace(
            profile: profile,
            accountPhotoUrl: _accountPhoto(),
          ),
          iconSize: 19,
          photoDiameter: 34,
        ),
      ),
      title: profile.name,
      subtitle: profile.isKids
          ? 'Kids profile'
          : (profile.isDefault ? 'Default profile' : 'Profile'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected)
            Icon(Icons.check_circle_rounded, color: AppColors.accent),
          IconButton(
            tooltip: 'Edit ${profile.name}',
            onPressed: () => _edit(profile),
            icon: const Icon(Icons.edit_outlined, size: 19),
          ),
          if (!profile.isDefault)
            IconButton(
              tooltip: 'Delete ${profile.name}',
              onPressed: () => _delete(profile),
              icon: const Icon(Icons.delete_outline_rounded, size: 19),
            ),
        ],
      ),
      onTap: () => _switchTo(profile),
    );
  }
}

class _ProfileAvatarTapTarget extends StatefulWidget {
  const _ProfileAvatarTapTarget({
    super.key,
    required this.profileId,
    required this.diameter,
    required this.fill,
    required this.shape,
    required this.onTap,
    required this.child,
    this.focusable = true,
  });

  final String profileId;
  final double diameter;
  final Color fill;
  final ShapeBorder shape;
  final Future<void> Function() onTap;
  final Widget child;

  /// False on the Windows picker, where the surrounding tile owns focus.
  final bool focusable;

  @override
  State<_ProfileAvatarTapTarget> createState() =>
      _ProfileAvatarTapTargetState();
}

class _ProfileAvatarTapTargetState extends State<_ProfileAvatarTapTarget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  TickerFuture? _releaseAnimation;
  bool _activating = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1,
          end: 0.94,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 25,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.94,
          end: 1.05,
        ).chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 35,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.05,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 40,
      ),
    ]).animate(_controller);
  }

  Future<void> runSelection() async {
    if (_activating) return;
    _activating = true;
    _releaseAnimation ??= _controller.forward();
    try {
      await widget.onTap();
    } finally {
      _releaseAnimation = null;
      _activating = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.diameter,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: _avatar()),
        // Small lock on profiles that ask for a PIN. Ignores pointer input so
        // the whole avatar stays one tap target.
        Positioned(
          right: -2,
          bottom: -2,
          child: IgnorePointer(
            child: ProfileLockBadge(profileId: widget.profileId),
          ),
        ),
      ],
    ),
  );

  Widget _avatar() => Listener(
      onPointerDown: (_) {
        if (!_activating) {
          _releaseAnimation = null;
          _controller.animateTo(
            0.25,
            duration: const Duration(milliseconds: 65),
            curve: Curves.easeOutCubic,
          );
        }
      },
      onPointerUp: (_) {
        if (!_activating) _releaseAnimation ??= _controller.forward();
      },
      onPointerCancel: (_) {
        _releaseAnimation = null;
        if (!_activating) {
          _controller.animateBack(
            0,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOutCubic,
          );
        }
      },
      child: ScaleTransition(
        key: ValueKey('profile-avatar-${widget.profileId}'),
        scale: _scale,
        child: Hero(
          tag: viewerProfileHeroTag(widget.profileId),
          flightShuttleBuilder: (_, _, _, fromHeroContext, _) => FittedBox(
            key: const ValueKey('profile-flight-avatar'),
            fit: BoxFit.contain,
            child: (fromHeroContext.widget as Hero).child,
          ),
          child: Material(
            key: ValueKey('profile-avatar-fill-${widget.profileId}'),
            color: widget.fill,
            shape: widget.shape,
            clipBehavior: Clip.antiAlias,
            child: InkResponse(
              key: ValueKey('profile-avatar-ink-${widget.profileId}'),
              containedInkWell: true,
              highlightShape: BoxShape.circle,
              customBorder: widget.shape,
              radius: widget.diameter / 2,
              splashColor: AppColors.textPrimary.withValues(alpha: 0.28),
              highlightColor: AppColors.textPrimary.withValues(alpha: 0.10),
              canRequestFocus: widget.focusable,
              onTap: runSelection,
              child: SizedBox.square(
                dimension: widget.diameter,
                child: Center(child: widget.child),
              ),
            ),
          ),
        ),
      ),
    );
}

/// Windows: small lock shown on a profile that has a PIN — the synced account
/// lock as this PC last saw it, or an old PC-only PIN not yet moved. Pops in
/// and out as locks change. Draws nothing elsewhere (phone/TV keep upstream's
/// picker) or when no lock store is registered (tests).
class ProfileLockBadge extends StatelessWidget {
  const ProfileLockBadge({super.key, required this.profileId});
  final String profileId;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return const SizedBox.shrink();
    }
    final legacy = sl.isRegistered<ProfilePinStore>()
        ? sl<ProfilePinStore>()
        : null;
    final locks = sl.isRegistered<ProfileLockStore>()
        ? sl<ProfileLockStore>()
        : null;
    final synced = locks is SyncedProfileLockStore ? locks : null;
    if (legacy == null && synced == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([
        ?legacy,
        ?synced?.statusChanges,
      ]),
      builder: (_, _) => FutureBuilder<bool?>(
        // Saved status only: no network request per avatar.
        future: synced?.cachedLocked(profileId),
        builder: (_, cached) => _badge(
          (legacy?.isLocked(profileId) ?? false) || cached.data == true,
        ),
      ),
    );
  }

  Widget _badge(bool locked) => AnimatedScale(
        scale: locked ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutBack,
        child: Container(
          key: ValueKey('profile-lock-$profileId'),
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A23),
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF3C2D3A)),
          ),
          child: Center(
            child: SvgPicture.asset(
              'assets/icons/lucide/lock.svg',
              width: 11,
              height: 11,
              colorFilter: const ColorFilter.mode(
                Color(0xFFE3C6EA),
                BlendMode.srcIn,
              ),
            ),
          ),
        ),
      );
}

/// Windows picker (acct-7): position (0-based) chosen by a number key, from
/// the top row or the numpad, 1-9. Null for any other key.
@visibleForTesting
int? desktopPickerDigitIndex(LogicalKeyboardKey key) {
  const top = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];
  const pad = [
    LogicalKeyboardKey.numpad1,
    LogicalKeyboardKey.numpad2,
    LogicalKeyboardKey.numpad3,
    LogicalKeyboardKey.numpad4,
    LogicalKeyboardKey.numpad5,
    LogicalKeyboardKey.numpad6,
    LogicalKeyboardKey.numpad7,
    LogicalKeyboardKey.numpad8,
    LogicalKeyboardKey.numpad9,
  ];
  final index = top.indexOf(key);
  if (index >= 0) return index;
  final padIndex = pad.indexOf(key);
  return padIndex >= 0 ? padIndex : null;
}

/// Rebuilds with whether [profileId] has a PIN as this PC last saw it (the
/// synced lock's saved status, or an old PC-only PIN). No network request,
/// same source as [ProfileLockBadge]. Used for the Windows picker tooltip.
class _ProfileLockStatus extends StatelessWidget {
  const _ProfileLockStatus({required this.profileId, required this.builder});

  final String profileId;
  final Widget Function(bool locked) builder;

  @override
  Widget build(BuildContext context) {
    final legacy = sl.isRegistered<ProfilePinStore>()
        ? sl<ProfilePinStore>()
        : null;
    final locks = sl.isRegistered<ProfileLockStore>()
        ? sl<ProfileLockStore>()
        : null;
    final synced = locks is SyncedProfileLockStore ? locks : null;
    if (legacy == null && synced == null) return builder(false);
    return ListenableBuilder(
      listenable: Listenable.merge([?legacy, ?synced?.statusChanges]),
      builder: (_, _) => FutureBuilder<bool?>(
        future: synced?.cachedLocked(profileId),
        builder: (_, cached) => builder(
          (legacy?.isLocked(profileId) ?? false) || cached.data == true,
        ),
      ),
    );
  }
}

/// One focusable tile of the Windows "Who's watching" grid (acct-7).
///
/// Owns keyboard focus for the tile (the avatar's own ink is not a Tab stop)
/// and draws an accent ring while focused. Enter / Space activate it, the
/// arrow keys move focus to the neighbouring tile, and right-click, the Menu
/// key or Shift+F10 open [onMenu]. A tooltip shows [tooltip] on hover.
class _DesktopPickerTile extends StatefulWidget {
  const _DesktopPickerTile({
    super.key,
    required this.builder,
    required this.onActivate,
    required this.tooltip,
    required this.semanticLabel,
    this.onMenu,
    this.autofocus = false,
  });

  /// Builds the tile; `focused` lets it brighten the name like TV does.
  final Widget Function(bool focused) builder;
  final VoidCallback onActivate;
  final String tooltip;
  final String semanticLabel;

  /// Opens the profile menu at a global [position] (right-click) or below
  /// the tile ([anchor], keyboard).
  final void Function(Offset? position, BuildContext anchor)? onMenu;
  final bool autofocus;

  @override
  State<_DesktopPickerTile> createState() => _DesktopPickerTileState();
}

class _DesktopPickerTileState extends State<_DesktopPickerTile> {
  late final FocusNode _focus = FocusNode(debugLabel: 'desktop-picker-tile');
  bool _focused = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (event is KeyDownEvent &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.space)) {
      widget.onActivate();
      return KeyEventResult.handled;
    }
    final direction = switch (key) {
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      _ => null,
    };
    if (direction != null) {
      node.focusInDirection(direction);
      // Handled even at the edge, so the arrow never leaves the grid.
      return KeyEventResult.handled;
    }
    final menu = widget.onMenu;
    if (menu != null &&
        event is KeyDownEvent &&
        (key == LogicalKeyboardKey.contextMenu ||
            (key == LogicalKeyboardKey.f10 &&
                HardwareKeyboard.instance.isShiftPressed))) {
      menu(null, context);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final menu = widget.onMenu;
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: Focus(
        focusNode: _focus,
        autofocus: widget.autofocus,
        onKeyEvent: _onKey,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: Tooltip(
          message: widget.tooltip,
          waitDuration: const Duration(milliseconds: 500),
          // A click also moves keyboard focus here, so arrows continue from
          // the tile the mouse used. A Listener (not a tap recogniser) so it
          // never competes with the avatar's own tap.
          child: Listener(
            onPointerDown: (_) => _focus.requestFocus(),
            child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onSecondaryTapUp: menu == null
                ? null
                : (details) => menu(details.globalPosition, context),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: _focused ? AppColors.accent : Colors.transparent,
                  width: 2,
                ),
              ),
              child: widget.builder(_focused),
            ),
          ),
          ),
        ),
      ),
    );
  }
}

import 'dart:async';
import 'package:flutter/material.dart';

import '../../core/desktop/desktop_window.dart';
import '../../core/di/injector.dart';
import '../../core/profiles/profile_pin_store.dart';
import '../../core/profiles/profile_shell_scope.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/profiles/profile_lock_store.dart';
import '../../core/profiles/profile_lock_remote.dart';
import '../../core/theme/app_colors.dart';
import '../../l10n/l10n.dart';
import 'desktop_profile_relock.dart';
import 'profile_unlock.dart' show profileHasPin, hasLegacyPcPin;
import 'viewer_profiles_screen.dart';
import '../auth/auth_screens.dart' show LoginScreen;
import '../auth/auth_cubit.dart';
import '../player/desktop_floating_player.dart';

class ProfileLaunchGate extends StatefulWidget {
  const ProfileLaunchGate({super.key, required this.child});

  final Widget child;

  @override
  State<ProfileLaunchGate> createState() => _ProfileLaunchGateState();
}

class _ProfileLaunchGateState extends State<ProfileLaunchGate> {
  // Content waits for [_ensureGate] whenever a lock store exists, so the
  // synced lock (the one profile lock on every platform) decides there.
  late bool _deferContent =
      sl<ViewerProfileStore>().askOnLaunch ||
      sl.isRegistered<ProfileLockStore>() ||
      sl.isRegistered<ProfilePinStore>();
  bool _pickerShown = false;
  Object? _lockError;
  late final ViewerProfileStore _profiles = sl<ViewerProfileStore>();
  late (String, String) _profileContext;
  StreamSubscription<AuthState>? _authSubscription;
  String? _authUserId;
  int _checkGeneration = 0;

  // Windows (acct-11): Ctrl+L, idle time and Windows locking relock the
  // active profile. start() is a no-op on phone and TV.
  late final DesktopProfileRelock _relock = DesktopProfileRelock(
    onLockRequested: _relockActiveProfile,
  );

  @override
  void initState() {
    super.initState();
    _relock.start();
    _profileContext = (_profiles.ownerKey, _profiles.activeId);
    _profiles.active.addListener(_onProfileChanged);
    if (sl.isRegistered<AuthCubit>()) {
      final auth = sl<AuthCubit>();
      _authUserId = auth.state.user?.id;
      _authSubscription = auth.stream.listen((state) {
        if (!mounted || state.user?.id == _authUserId) return;
        _authUserId = state.user?.id;
        _checkGeneration++;
        if (sl.isRegistered<ProfileLockStore>()) {
          final locks = sl<ProfileLockStore>();
          locks.clearSwitchApprovals();
          locks.lockEntry(_profiles.activeId);
        }
        setState(() {
          _deferContent = true;
          _lockError = null;
        });
        if (_profiles.isLoadedForCurrentUser && !_pickerShown) {
          _ensureGate(checkLaunchPreference: false);
        }
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureGate();
    });
  }

  void _onProfileChanged() {
    if (!mounted) return;
    final next = (_profiles.ownerKey, _profiles.activeId);
    if (next == _profileContext) return;
    final ownerChanged = next.$1 != _profileContext.$1;
    _profileContext = next;
    _checkGeneration++;
    final locks = sl.isRegistered<ProfileLockStore>()
        ? sl<ProfileLockStore>()
        : null;
    if (ownerChanged) locks?.clearSwitchApprovals();
    final approved = locks?.consumeSwitchApproval(next.$2) ?? false;
    if (!approved) locks?.lockEntry(next.$2);
    if (_pickerShown) return;
    setState(() {
      _deferContent = !approved;
      _lockError = null;
    });
    if (!approved) _ensureGate(checkLaunchPreference: false);
  }

  @override
  void dispose() {
    _relock.dispose();
    _profiles.active.removeListener(_onProfileChanged);
    _authSubscription?.cancel();
    super.dispose();
  }

  /// Windows "Lock profile now" / auto-lock (acct-11). When the active
  /// profile has a PIN, forget that it was unlocked and stop at the profile
  /// picker, exactly like a locked launch: picking it again asks the PIN.
  /// A profile without a PIN has nothing to lock; a manual request says so.
  Future<void> _relockActiveProfile(ProfileRelockReason reason) async {
    if (!mounted || _pickerShown || _deferContent) return;
    final locks = sl.isRegistered<ProfileLockStore>()
        ? sl<ProfileLockStore>()
        : null;
    final active = _profiles.activeProfile;
    final hasPin = await profileHasPin(active.id, locks);
    if (!mounted || _pickerShown || _deferContent) return;
    if (!hasPin) {
      if (reason == ProfileRelockReason.manual) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.setPinToLock,
            ),
          ),
        );
      }
      return;
    }
    locks?.clearSwitchApprovals();
    locks?.lockEntry(active.id);
    // The picker needs the full window, not the mini player.
    if (DesktopWindow.miniPlayer.value) {
      await DesktopWindow.exitMiniPlayer();
    }
    // Windows: the floating mini player sits above every page and would show
    // over the PIN picker. Stop it (progress is saved) before locking.
    await DesktopFloatingPlayer.instance.close();
    if (!mounted || _pickerShown) return;
    _checkGeneration++;
    setState(() {
      _deferContent = true;
      _lockError = null;
    });
    _pickerShown = true;
    unawaited(_showPicker());
  }

  /// Decides whether launch stops at the picker. Asking off means straight
  /// in — even for a locked active profile. The locks stay set (switching
  /// profiles inside the app still asks), only the launch-time force is
  /// lifted, so there is deliberately no PIN prompt on this path.
  Future<void> _ensureGate({bool checkLaunchPreference = true}) async {
    if (_pickerShown) return;
    final generation = ++_checkGeneration;
    setState(() {
      _lockError = null;
      _deferContent = true;
    });
    final store = sl<ViewerProfileStore>();
    // One profile has nothing to choose between, so go straight in. A locked
    // profile still reaches the picker below, so its lock is enforced. Only
    // trust the count once this account's profiles have loaded: right after
    // a first sign-in the list can still be the phone's single local one.
    final onlyOne = store.isLoadedForCurrentUser && store.profiles.length == 1;
    if (checkLaunchPreference && store.askOnLaunch && !onlyOne) {
      _pickerShown = true;
      if (mounted) _showPicker();
      return;
    }
    // Windows: an old PC-only PIN that has not been moved into the synced
    // lock yet kept its launch promise (stop at the picker whatever "ask on
    // launch" says), so protection is not silently lost. Choosing the profile
    // there asks that PIN once and moves it ([ensureProfileAccess]); after
    // that launch behaves exactly like the phone. Checked on every gate run
    // (also after a sign-in or an unapproved active-profile change), not only
    // at launch, so such a profile never opens without its PIN.
    if (sl.isRegistered<ProfilePinStore>() &&
        await hasLegacyPcPin(store.activeId)) {
      if (!mounted || generation != _checkGeneration || _pickerShown) return;
      _pickerShown = true;
      _showPicker();
      return;
    }
    try {
      if (sl.isRegistered<ProfileLockStore>()) {
        final locks = sl<ProfileLockStore>();
        final active = store.activeProfile;
        bool locked = false;
        try {
          locked = await locks.isLocked(active.id);
        } on ProfileLockException {
          // Asking is off: launch never enforces the lock, so an unreadable
          // status (offline with no cache yet, dead backend) must not trap
          // the user on the error screen — go straight in. Asking on keeps
          // the existing behavior: surface the failure instead of silently
          // skipping the picker.
          if (store.askOnLaunch) rethrow;
        }
        if (!mounted || generation != _checkGeneration) return;
        if (locked && !locks.isUnlocked(active.id) && store.askOnLaunch) {
          _pickerShown = true;
          _showPicker();
          return;
        }
      }
      if (mounted && generation == _checkGeneration) {
        setState(() => _deferContent = false);
      }
    } catch (error) {
      if (mounted && generation == _checkGeneration) {
        setState(() => _lockError = error);
      }
    }
  }

  Future<void> _showPicker() async {
    final route = ProfilePickerRoute(
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      builder: (pickerContext) => PopScope(
        canPop: false,
        child: ViewerProfilesScreen(
          selectionOnly: true,
          onProfilePrepared: _releaseShell,
          onSelected: () => _popPicker(pickerContext),
        ),
      ),
    );
    await Navigator.of(context).push<void>(route);
    await route.completed;
    if (!mounted) return;
    setState(() => _pickerShown = false);
    if (mounted && _deferContent) {
      _ensureGate(checkLaunchPreference: false);
    }
  }

  void _releaseShell() {
    if (mounted && _deferContent) setState(() => _deferContent = false);
  }

  Future<void> _popPicker(BuildContext pickerContext) async {
    // Wait until the dock and the enabled source Hero both have a layout.
    await WidgetsBinding.instance.endOfFrame;
    if (!pickerContext.mounted) return;
    final navigator = Navigator.of(pickerContext);
    final route = ModalRoute.of(pickerContext);
    // Close the picker itself. A blind pop() closes whatever is on top, and a
    // prompt (update dialog, sheet) pushed during the avatar animation would
    // be closed instead, leaving the picker up underneath it.
    if (route == null || route.isCurrent) {
      navigator.pop(); // normal path, keeps the fade + Hero
    } else if (route.isActive) {
      navigator.removeRoute(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ProfileShellScope(
      deferContent: _deferContent,
      deferTabs: _pickerShown,
      child: _lockError != null
          ? Material(
              color: AppColors.bg,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _lockError is ProfileLockException
                          ? (_lockError as ProfileLockException).message
                          : context.l10n.somethingWentWrong,
                    ),
                    const SizedBox(height: 12),
                    if (_lockError is ProfileLockException &&
                        (_lockError as ProfileLockException).code ==
                            'sign_in_required')
                      FilledButton(
                        onPressed: () async {
                          await Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => const LoginScreen(),
                            ),
                          );
                          if (mounted) _ensureGate();
                        },
                        child: const Text('Sign in'),
                      ),
                    FilledButton(
                      onPressed: _ensureGate,
                      child: Text(context.l10n.retry),
                    ),
                  ],
                ),
              ),
            )
          : widget.child,
    );
  }
}

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/di/injector.dart';
import '../../core/profiles/profile_pin_store.dart';
import '../auth/auth_cubit.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/profiles/viewer_profile_avatar.dart';
import '../../core/theme/app_colors.dart';

/// Result of one PIN submission as the dialog needs to show it.
typedef PinAttempt = ({bool ok, String? message, Duration? lockedFor});

const _ok = (ok: true, message: null, lockedFor: null);

/// Translates a store check into dialog feedback.
PinAttempt describePinCheck(PinCheck check) => switch (check.result) {
  PinResult.ok => _ok,
  PinResult.wrong => (
    ok: false,
    message: check.attemptsLeft == 1
        ? 'Incorrect PIN. 1 attempt left.'
        : 'Incorrect PIN. ${check.attemptsLeft} attempts left.',
    lockedFor: null,
  ),
  PinResult.lockedOut => (
    ok: false,
    message: 'Too many attempts.',
    lockedFor: check.retryAfter,
  ),
};

/// Photo to show in a PIN dialog: the profile's own, else the account photo for
/// the default profile, matching the picker.
String? pinDialogPhoto(ViewerProfile profile) => profilePhotoForFace(
  profile: profile,
  accountPhotoUrl: sl.isRegistered<AuthCubit>()
      ? sl<AuthCubit>().state.avatarUrl
      : null,
);

// The old PC-only PIN is no longer a profile lock of its own: the synced
// account lock is. These dialogs only verify an old PIN once so
// profile_unlock.dart can move it into the synced lock.

/// Asks for [profile]'s PIN. Returns true only when it was entered correctly.
/// Type four digits (no Enter needed); Esc cancels. [onAccepted] receives the
/// correct PIN so it can be moved into the synced account lock.
Future<bool> showProfilePinPrompt(
  BuildContext context, {
  required ViewerProfile profile,
  required ProfilePinStore store,
  String? photoUrl,
  String title = 'Enter PIN',
  String? subtitle,
  ValueChanged<String>? onAccepted,
}) async {
  final title0 = ValueNotifier<String>(title);
  final result = await _show(
    context,
    profile: profile,
    photoUrl: photoUrl,
    title: title0,
    subtitle: subtitle ?? 'for ${profile.name}',
    onSubmit: (pin) async {
      final attempt = describePinCheck(await store.verify(profile.id, pin));
      if (attempt.ok) onAccepted?.call(pin);
      return attempt;
    },
  );
  title0.dispose();
  return result ?? false;
}

/// Sets or changes [profile]'s PIN. When one already exists the current PIN is
/// asked for first. Returns true when a new PIN was saved.
Future<bool> showSetProfilePin(
  BuildContext context, {
  required ViewerProfile profile,
  required ProfilePinStore store,
  String? photoUrl,
}) async {
  if (store.isLocked(profile.id)) {
    final allowed = await showProfilePinPrompt(
      context,
      profile: profile,
      store: store,
      photoUrl: photoUrl,
      title: 'Enter current PIN',
    );
    if (!allowed || !context.mounted) return false;
  }
  final title = ValueNotifier<String>('Choose a PIN');
  String? first;
  final saved = await _show(
    context,
    profile: profile,
    photoUrl: photoUrl,
    title: title,
    subtitle: 'Four digits for ${profile.name}',
    onSubmit: (pin) async {
      if (first == null) {
        first = pin;
        title.value = 'Confirm your PIN';
        return (ok: false, message: null, lockedFor: null);
      }
      if (first != pin) {
        first = null;
        title.value = 'Choose a PIN';
        return (
          ok: false,
          message: "PINs didn't match. Try again.",
          lockedFor: null,
        );
      }
      await store.setPin(profile.id, pin);
      return _ok;
    },
  );
  title.dispose();
  return saved ?? false;
}

/// Removes [profile]'s PIN after confirming it. Returns true when removed.
Future<bool> showRemoveProfilePin(
  BuildContext context, {
  required ViewerProfile profile,
  required ProfilePinStore store,
  String? photoUrl,
}) async {
  final title = ValueNotifier<String>('Enter PIN to remove');
  final removed = await _show(
    context,
    profile: profile,
    photoUrl: photoUrl,
    title: title,
    subtitle: 'for ${profile.name}',
    onSubmit: (pin) async =>
        describePinCheck(await store.removePin(profile.id, pin)),
  );
  title.dispose();
  return removed ?? false;
}

Future<bool?> _show(
  BuildContext context, {
  required ViewerProfile profile,
  required String? photoUrl,
  required ValueListenable<String> title,
  required String subtitle,
  required Future<PinAttempt> Function(String pin) onSubmit,
}) => showGeneralDialog<bool>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Cancel',
  barrierColor: Colors.black.withValues(alpha: 0.62),
  transitionDuration: const Duration(milliseconds: 190),
  pageBuilder: (_, _, _) => _PinDialog(
    profile: profile,
    photoUrl: photoUrl,
    title: title,
    subtitle: subtitle,
    onSubmit: onSubmit,
  ),
  // Fade in with a slight scale, like other desktop dialogs in the app.
  transitionBuilder: (_, animation, _, child) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeIn,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
        child: child,
      ),
    );
  },
);

class _PinDialog extends StatefulWidget {
  const _PinDialog({
    required this.profile,
    required this.photoUrl,
    required this.title,
    required this.subtitle,
    required this.onSubmit,
  });
  final ViewerProfile profile;
  final String? photoUrl;
  final ValueListenable<String> title;
  final String subtitle;
  final Future<PinAttempt> Function(String pin) onSubmit;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
  );
  Timer? _countdown;
  Duration? _lockedFor;
  String? _message;
  bool _busy = false;

  bool get _locked => _lockedFor != null;

  @override
  void dispose() {
    _countdown?.cancel();
    _shake.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _changed(String value) async {
    if (_busy || _locked) return;
    if (_message != null && value.isNotEmpty) setState(() => _message = null);
    setState(() {});
    if (value.length != ProfilePinStore.pinLength) return;
    // Tint the boxes right away so a slower check never looks like nothing
    // happened.
    setState(() => _busy = true);
    final attempt = await widget.onSubmit(value);
    _busy = false;
    if (!mounted) return;
    if (attempt.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    _controller.clear();
    setState(() => _message = attempt.message);
    // A rejected PIN shakes; a stage change (message == null) does not.
    if (attempt.message != null) unawaited(_shake.forward(from: 0));
    final lock = attempt.lockedFor;
    if (lock != null) _startLockout(lock);
    _focus.requestFocus();
  }

  void _startLockout(Duration duration) {
    _countdown?.cancel();
    setState(() => _lockedFor = duration);
    _countdown = Timer.periodic(const Duration(seconds: 1), (timer) {
      final left = (_lockedFor ?? Duration.zero) - const Duration(seconds: 1);
      if (!mounted) return;
      if (left <= Duration.zero) {
        timer.cancel();
        setState(() {
          _lockedFor = null;
          _message = null;
        });
        _focus.requestFocus();
      } else {
        setState(() => _lockedFor = left);
      }
    });
  }

  String _clock(Duration d) {
    final seconds = d.inSeconds.clamp(0, 86400);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final entered = _controller.text.length;
    final danger = _message != null || _locked;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 340,
          padding: const EdgeInsets.fromLTRB(28, 26, 28, 22),
          decoration: BoxDecoration(
            color: const Color(0xFF15151D),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF3C2D3A)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipOval(
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: ColoredBox(
                    color: viewerProfileAvatarColor(widget.profile.avatar),
                    child: Center(
                      child: ProfileAvatarFace(
                        profile: widget.profile,
                        photoUrl: widget.photoUrl,
                        iconSize: 30,
                        photoDiameter: 64,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              ValueListenableBuilder<String>(
                valueListenable: widget.title,
                builder: (_, title, _) => AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  child: Text(
                    title,
                    key: ValueKey(title),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.subtitle,
                style: const TextStyle(fontSize: 12, color: Color(0xFF9A97A6)),
              ),
              const SizedBox(height: 22),
              AnimatedBuilder(
                animation: _shake,
                builder: (_, child) => Transform.translate(
                  offset: Offset(
                    math.sin(_shake.value * math.pi * 6) *
                        (1 - _shake.value) *
                        10,
                    0,
                  ),
                  child: child,
                ),
                child: Semantics(
                  label: 'PIN, $entered of ${ProfilePinStore.pinLength} digits',
                  textField: true,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < ProfilePinStore.pinLength; i++)
                            Padding(
                              padding: EdgeInsets.only(left: i == 0 ? 0 : 12),
                              child: _Cell(
                                filled: i < entered,
                                active: i == entered && !_locked,
                                danger: danger,
                                checking: _busy,
                              ),
                            ),
                        ],
                      ),
                      // The real input sits invisibly on top of the cells, so
                      // typing, paste and the Windows touch keyboard all work.
                      Positioned.fill(
                        child: Opacity(
                          opacity: 0,
                          child: TextField(
                            controller: _controller,
                            focusNode: _focus,
                            autofocus: true,
                            enabled: !_locked,
                            keyboardType: TextInputType.number,
                            enableInteractiveSelection: false,
                            showCursor: false,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(
                                ProfilePinStore.pinLength,
                              ),
                            ],
                            onChanged: _changed,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 34,
                child: Text(
                  _locked
                      ? '${_message ?? 'Locked.'} Try again in ${_clock(_lockedFor!)}'
                      : (_message ?? ''),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: Color(0xFFFF7B8C),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One PIN digit: an empty box, the active box, or a filled dot.
class _Cell extends StatelessWidget {
  const _Cell({
    required this.filled,
    required this.active,
    required this.danger,
    this.checking = false,
  });
  final bool filled, active, danger, checking;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 140),
    width: 48,
    height: 56,
    decoration: BoxDecoration(
      color: const Color(0xFF1C1C27),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        width: active ? 1.6 : 1,
        color: danger
            ? const Color(0xFFFF7B8C)
            : checking || active
            ? AppColors.accent
            : const Color(0xFF34283A),
      ),
    ),
    child: Center(
      child: AnimatedScale(
        scale: filled ? 1 : 0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutBack,
        child: const SizedBox(
          width: 12,
          height: 12,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    ),
  );
}

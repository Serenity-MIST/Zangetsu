import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../core/ui/settings_widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/app_mode.dart';
import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/di/injector.dart';
import '../../core/profiles/klipy_gif_service.dart';
import '../../core/profiles/profile_avatar_uploader.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/profiles/viewer_profile_avatar.dart';
import '../../core/supabase/supabase_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/buttons.dart';
import '../../core/ui/desktop_docked_panel.dart';
import '../../core/tv/tv_focusable.dart';
import '../profiles/desktop_avatar_input.dart';
import '../profiles/klipy_gif_picker.dart';
import 'auth_cubit.dart';
import 'auth_screens_tv.dart';
import 'pair_tv_screen.dart';
import 'reconnect.dart';
import '../../l10n/l10n.dart';
import '../../l10n/ui_strings.dart';

/// Returns true if logged in. Otherwise shows a "Sign in to {action}" snackbar
/// with a Sign-in action and returns false — the gate for My List / history.
bool requireLogin(BuildContext context, {String? action}) {
  if (context.read<AuthCubit>().state.isLoggedIn) return true;
  final act = action ?? context.l10n.signInToUseThis;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        backgroundColor: AppColors.surface2,
        behavior: SnackBarBehavior.floating,
        content: Text(
          context.l10n.signInToAction(act),
          style: AppText.body.copyWith(color: Colors.white),
        ),
        action: SnackBarAction(
          label: context.l10n.signIn,
          textColor: AppColors.accent,
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const LoginScreen())),
        ),
      ),
    );
  return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared dark text field
// ─────────────────────────────────────────────────────────────────────────────

class _Field extends StatefulWidget {
  const _Field({
    super.key,
    required this.controller,
    required this.hint,
    this.icon,
    this.obscure = false,
    this.keyboard,
    this.focusNode,
    this.autofocus = false,
    this.textInputAction,
    this.onSubmitted,
    this.autofillHints,
  });
  final TextEditingController controller;
  final String hint;
  final IconData? icon;
  final bool obscure;
  final TextInputType? keyboard;

  // Desktop sign-in extras (acct-2). The forms only pass these on Windows,
  // so the phone form keeps its previous behaviour.
  final FocusNode? focusNode;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final Iterable<String>? autofillHints;

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> {
  // Whether a password field currently shows its text (Windows eye toggle).
  bool _revealed = false;

  // The eye button is skipped by Tab so Tab still moves field to field.
  final FocusNode _toggleFocus = FocusNode(skipTraversal: true);

  @override
  void dispose() {
    _toggleFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The show-password toggle is Windows only; phone keeps the plain field.
    final showToggle = widget.obscure && desktopPanelsEnabled;
    return TextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      obscureText: widget.obscure && !_revealed,
      keyboardType: widget.keyboard,
      textInputAction: widget.textInputAction,
      onSubmitted: widget.onSubmitted,
      autofillHints: widget.autofillHints,
      style: AppText.body.copyWith(color: AppColors.textPrimary),
      decoration: InputDecoration(
        hintText: widget.hint,
        hintStyle: AppText.body.copyWith(color: AppColors.textTertiary),
        prefixIcon: widget.icon == null
            ? null
            : Icon(widget.icon, color: AppColors.textTertiary, size: 20),
        suffixIcon: showToggle
            ? IconButton(
                key: const ValueKey('auth-password-reveal'),
                focusNode: _toggleFocus,
                tooltip: _revealed
                    ? context.l10n.hidePassword
                    : context.l10n.showPassword,
                icon: Icon(
                  _revealed
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: AppColors.textTertiary,
                  size: 20,
                ),
                onPressed: () => setState(() => _revealed = !_revealed),
              )
            : null,
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.hairline, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppColors.accent, width: 1),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Login
// ─────────────────────────────────────────────────────────────────────────────

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();

  // Lets Enter in the email field move on to the password (Windows).
  final _passwordFocus = FocusNode();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit(BuildContext context) async {
    // Enter can fire while a request is already running; ignore repeats.
    if (context.read<AuthCubit>().state.busy) return;
    final ok = await context.read<AuthCubit>().login(
      _email.text.trim(),
      _password.text,
    );
    if (ok && context.mounted) Navigator.of(context).pop();
  }

  /// context.l10n.forgotPassword — ask for the account email and send an Appwrite
  /// recovery link (completed on the hosted reset page). Works while signed out.
  Future<void> _forgotPassword(BuildContext context) async {
    // Windows: graphite prompt (Enter sends, Esc cancels); the phone keeps
    // the AlertDialog below unchanged.
    if (desktopPanelsEnabled) {
      final email = await showAccountTextPrompt(
        context,
        title: context.l10n.resetPassword,
        message:
            "Enter your account email and we'll send a link to set a new "
            'password.',
        label: context.l10n.email,
        hint: context.l10n.youExampleCom,
        initial: _email.text.trim(),
        confirmLabel: context.l10n.sendLink,
        keyboardType: TextInputType.emailAddress,
      );
      if (email == null || email.isEmpty || !context.mounted) return;
      await _sendRecovery(context, email);
      return;
    }
    final controller = TextEditingController(text: _email.text.trim());
    final email = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(context.l10n.resetPassword),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Enter your account email and we'll send a link to set a new "
              'password.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: context.l10n.email,
                hintText: context.l10n.youExampleCom,
              ),
              onSubmitted: (v) => Navigator.of(dctx).pop(v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(controller.text.trim()),
            child: Text(context.l10n.sendLink),
          ),
        ],
      ),
    );
    controller.dispose();
    if (email == null || email.isEmpty || !context.mounted) return;
    await _sendRecovery(context, email);
  }

  /// Sends the recovery link and reports the result (shared by the phone
  /// dialog and the Windows prompt).
  Future<void> _sendRecovery(BuildContext context, String email) async {
    final err = await context.read<AuthCubit>().sendRecovery(email);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(err ?? context.l10n.resetLinkSent)));
  }

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const LoginScreenTv();
    // Windows gets desktop form keys: email focused on open, Enter moves to
    // the password and submits from there, plus password-manager hints.
    final desktop = desktopPanelsEnabled;
    return _AuthScaffold(
      title: context.l10n.welcomeBack,
      subtitle: context.l10n.signInToSyncYourListAcrossDevices,
      children: [
        _Field(
          key: const ValueKey('auth-login-email'),
          controller: _email,
          hint: context.l10n.email,
          icon: Icons.mail_outline,
          keyboard: TextInputType.emailAddress,
          autofocus: desktop,
          textInputAction: desktop ? TextInputAction.next : null,
          onSubmitted: desktop ? (_) => _passwordFocus.requestFocus() : null,
          autofillHints: desktop
              ? const [AutofillHints.email, AutofillHints.username]
              : null,
        ),
        const SizedBox(height: 12),
        _Field(
          key: const ValueKey('auth-login-password'),
          controller: _password,
          hint: context.l10n.password,
          icon: Icons.lock_outline,
          obscure: true,
          focusNode: desktop ? _passwordFocus : null,
          textInputAction: desktop ? TextInputAction.done : null,
          onSubmitted: desktop ? (_) => _submit(context) : null,
          autofillHints: desktop ? const [AutofillHints.password] : null,
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton(
            onPressed: () => _forgotPassword(context),
            child: Text(context.l10n.forgotPassword),
          ),
        ),
        const SizedBox(height: 8),
        BlocBuilder<AuthCubit, AuthState>(
          builder: (context, state) => _SubmitBlock(
            label: context.l10n.logIn,
            busy: state.busy,
            error: localizeAuthError(context.l10n, state.error),
            onPressed: () => _submit(context),
          ),
        ),
        const SizedBox(height: 14),
        _SwitchLink(
          prompt: context.l10n.dontHaveAnAccount,
          action: context.l10n.signUp,
          onTap: () => Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const SignupScreen()),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Signup
// ─────────────────────────────────────────────────────────────────────────────

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});
  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  // Enter in one field moves to the next on Windows (name -> email -> password).
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();

  /// Photo picked before the account exists. Uploaded right after signUp
  /// succeeds (the avatars bucket needs an authenticated session, which only
  /// exists once the account + session are created).
  String? _avatarPath;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final x = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      // Avatars render at ~40–96px, so 256px is still 2–3× the display size —
      // keeps the Appwrite bucket tiny (~15–30 KB/pic) with no visible quality loss.
      maxWidth: 256,
      maxHeight: 256,
      imageQuality: 80,
    );
    if (x != null && mounted) setState(() => _avatarPath = x.path);
  }

  Future<void> _submit(BuildContext context) async {
    // Enter can fire while a request is already running; ignore repeats.
    if (context.read<AuthCubit>().state.busy) return;
    if (_password.text.length < 8) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(context.l10n.passwordMustBeAtLeast8Characters),
          ),
        );
      return;
    }
    final auth = context.read<AuthCubit>();
    final ok = await auth.signUp(
      _name.text.trim(),
      _email.text.trim(),
      _password.text,
    );
    if (!ok) return; // error already surfaced via state
    // Session is live now — upload the chosen photo before leaving.
    if (_avatarPath != null) await auth.updateAvatar(_avatarPath!);
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const SignupScreenTv();
    // Windows gets desktop form keys: the first field is focused on open,
    // Enter moves down the form and submits from the password field.
    final desktop = desktopPanelsEnabled;
    return _AuthScaffold(
      title: context.l10n.createAccount,
      subtitle: context.l10n.saveYourListAndContinueWatchingAnywhere,
      children: [
        Center(
          child: _AvatarPicker(path: _avatarPath, onTap: _pickAvatar),
        ),
        const SizedBox(height: 24),
        _Field(
          key: const ValueKey('auth-signup-name'),
          controller: _name,
          hint: context.l10n.name,
          icon: Icons.person_outline,
          autofocus: desktop,
          textInputAction: desktop ? TextInputAction.next : null,
          onSubmitted: desktop ? (_) => _emailFocus.requestFocus() : null,
          autofillHints: desktop ? const [AutofillHints.name] : null,
        ),
        const SizedBox(height: 12),
        _Field(
          key: const ValueKey('auth-signup-email'),
          controller: _email,
          hint: context.l10n.email,
          icon: Icons.mail_outline,
          keyboard: TextInputType.emailAddress,
          focusNode: desktop ? _emailFocus : null,
          textInputAction: desktop ? TextInputAction.next : null,
          onSubmitted: desktop ? (_) => _passwordFocus.requestFocus() : null,
          autofillHints: desktop ? const [AutofillHints.email] : null,
        ),
        const SizedBox(height: 12),
        _Field(
          key: const ValueKey('auth-signup-password'),
          controller: _password,
          hint: context.l10n.password8Characters,
          icon: Icons.lock_outline,
          obscure: true,
          focusNode: desktop ? _passwordFocus : null,
          textInputAction: desktop ? TextInputAction.done : null,
          onSubmitted: desktop ? (_) => _submit(context) : null,
          autofillHints: desktop ? const [AutofillHints.newPassword] : null,
        ),
        const SizedBox(height: 20),
        BlocBuilder<AuthCubit, AuthState>(
          builder: (context, state) => _SubmitBlock(
            label: context.l10n.createAccount,
            busy: state.busy,
            error: localizeAuthError(context.l10n, state.error),
            onPressed: () => _submit(context),
          ),
        ),
        const SizedBox(height: 14),
        _SwitchLink(
          prompt: 'Already have an account?',
          action: context.l10n.logIn,
          onTap: () => Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const LoginScreen()),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Profile (logged-in)
// ─────────────────────────────────────────────────────────────────────────────

class ProfileAccountSection extends StatefulWidget {
  const ProfileAccountSection({super.key});

  @override
  State<ProfileAccountSection> createState() => _ProfileAccountSectionState();
}

class _ProfileAccountSectionState extends State<ProfileAccountSection> {
  bool _avatarUploading = false;

  /// Windows (acct-6): Upload image / Upload GIF / Search GIFs as a menu
  /// anchored to the avatar instead of the phone bottom sheet.
  Future<void> _pickAvatarDesktop(
    BuildContext context,
    BuildContext anchor,
  ) async {
    final action = await showDesktopAvatarMenu(context, anchor: anchor);
    if (action == null || !context.mounted) return;
    switch (action) {
      case DesktopAvatarAction.uploadImage:
        await _pickAvatarFile(context, gif: false);
      case DesktopAvatarAction.uploadGif:
        await _pickAvatarFile(context, gif: true);
      case DesktopAvatarAction.searchGifs:
        final gif = await showProfileKlipyGifPicker(
          context,
          KlipyGifService.shared,
        );
        if (gif == null || !context.mounted) return;
        await _useAccountPhotoUrl(context, gif.avatarUrl);
    }
  }

  /// Windows file chooser for an image or GIF, then the normal upload.
  /// Reuses the drop/paste reader so size limits match.
  Future<void> _pickAvatarFile(
    BuildContext context, {
    required bool gif,
  }) async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: gif
            ? const ['gif']
            : const ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
      );
      final path = file?.path;
      if (path == null || !context.mounted) return;
      final read = await readDesktopAvatarFile(path);
      if (!context.mounted || read == null) return;
      if (read.bytes == null) {
        _showAvatarError(context, read.error!);
        return;
      }
      await _uploadAccountAvatar(context, read.bytes!);
    } catch (_) {
      if (context.mounted) {
        _showAvatarError(
          context,
          context.l10n.couldNotReadImageFile,
        );
      }
    }
  }

  void _showAvatarError(BuildContext context, String message) =>
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(message)));

  /// Saves an already-hosted picture (a KLIPY GIF) as the account photo,
  /// then removes the previous upload the same way a new upload does.
  Future<void> _useAccountPhotoUrl(BuildContext context, String url) async {
    final profiles = sl<ViewerProfileStore>();
    final profile = profiles.profiles.firstWhere(
      (profile) => profile.id == kDefaultProfileId,
    );
    setState(() => _avatarUploading = true);
    try {
      final synced = await profiles.update(
        profile.id,
        photoUrl: url,
        clearPhotoUrl: false,
      );
      final saved = profiles.profiles.any(
        (item) => item.id == profile.id && item.photoUrl == url,
      );
      if (!saved) throw StateError('Profile photo was not saved');
      final token =
          sl<SupabaseService>().client.auth.currentSession?.accessToken;
      if (synced &&
          token != null &&
          profile.photoUrl != null &&
          profile.photoUrl != url &&
          !profiles.profiles.any(
            (other) =>
                other.id != profile.id && other.photoUrl == profile.photoUrl,
          )) {
        await ProfileAvatarUploader(
          sl<Dio>(),
        ).delete(url: profile.photoUrl!, token: token);
      }
    } catch (_) {
      if (context.mounted) {
        _showAvatarError(context, context.l10n.couldntUpdatePhoto);
      }
    } finally {
      if (mounted) setState(() => _avatarUploading = false);
    }
  }

  Future<void> _pickAvatar(BuildContext context) async {
    final pickGif = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Photo from gallery'),
              onTap: () => Navigator.of(context).pop(false),
            ),
            ListTile(
              leading: const Icon(Icons.movie_filter_outlined),
              title: const Text('Animated GIF file'),
              onTap: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (pickGif == null || !mounted) return;

    late final Uint8List bytes;
    if (pickGif) {
      try {
        final file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: const ['gif'],
        );
        if (file == null || !mounted) return;
        if (await file.length() > ProfileAvatarUploader.maxGifSourceBytes) {
          if (context.mounted) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              const SnackBar(
                content: Text(
                  'This GIF is too large to optimize safely. Try a smaller file.',
                ),
              ),
            );
          }
          return;
        }
        if (!mounted) return;
        bytes = await file.readAsBytes();
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('Could not read that GIF file.')),
          );
        }
        return;
      }
    } else {
      final x = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: ProfileAvatarUploader.maxAvatarDimension.toDouble(),
        maxHeight: ProfileAvatarUploader.maxAvatarDimension.toDouble(),
        imageQuality: 100,
      );
      if (x == null || !context.mounted) return;
      bytes = await x.readAsBytes();
    }

    if (!context.mounted) return;
    await _uploadAccountAvatar(context, bytes);
  }

  Future<void> _uploadAccountAvatar(
    BuildContext context,
    Uint8List bytes,
  ) async {
    if (!context.mounted) return;
    final profiles = sl<ViewerProfileStore>();
    final profile = profiles.profiles.firstWhere(
      (profile) => profile.id == kDefaultProfileId,
    );
    final token = sl<SupabaseService>().client.auth.currentSession?.accessToken;
    if (token == null) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(context.l10n.couldntUpdatePhoto)));
      return;
    }

    setState(() => _avatarUploading = true);
    final uploader = ProfileAvatarUploader(sl<Dio>());
    String? uploadedUrl;
    var savedLocally = false;
    try {
      uploadedUrl = await uploader.upload(bytes: bytes, token: token);
      if (uploadedUrl == null) throw StateError('Avatar upload failed');

      final synced = await profiles.update(
        profile.id,
        photoUrl: uploadedUrl,
        clearPhotoUrl: false,
      );
      savedLocally = profiles.profiles.any(
        (item) => item.id == profile.id && item.photoUrl == uploadedUrl,
      );
      if (!savedLocally) throw StateError('Profile photo was not saved');

      if (synced &&
          profile.photoUrl != null &&
          profile.photoUrl != uploadedUrl &&
          !profiles.profiles.any(
            (other) =>
                other.id != profile.id && other.photoUrl == profile.photoUrl,
          )) {
        await uploader.delete(url: profile.photoUrl!, token: token);
      }
    } catch (_) {
      if (uploadedUrl != null && !savedLocally) {
        await uploader.delete(url: uploadedUrl, token: token);
      }
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(context.l10n.couldntUpdatePhoto)),
        );
      }
    } finally {
      if (mounted) setState(() => _avatarUploading = false);
    }
  }

  /// Keep the sign-in account name and default viewer-profile name in sync.
  Future<void> _editName(BuildContext context, String current) async {
    final ctrl = TextEditingController(text: current);
    // Windows: graphite prompt (Enter saves, Esc cancels); the phone keeps
    // the AlertDialog below unchanged.
    final name = desktopPanelsEnabled
        ? await showAccountTextPrompt(
            context,
            title: context.l10n.editName,
            hint: context.l10n.yourName,
            initial: current,
            confirmLabel: context.l10n.save,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
          )
        : await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.editName),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          maxLength: 40,
          decoration: InputDecoration(hintText: context.l10n.yourName),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(context.l10n.save),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !context.mounted) {
      return;
    }
    final auth = context.read<AuthCubit>();
    final profiles = sl<ViewerProfileStore>();
    final defaultProfile = profiles.profiles.firstWhere(
      (profile) => profile.id == kDefaultProfileId,
    );
    final updateAccount = auth.state.displayName != name;
    final updateProfile = defaultProfile.name != name;
    if (!updateAccount && !updateProfile) return;

    final messenger = ScaffoldMessenger.of(context);
    final oldAccountName = auth.state.displayName;
    if (updateAccount && !await auth.updateName(name)) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(context.l10n.couldnTUpdateYourName)),
      );
      return;
    }
    if (!updateProfile || await profiles.rename(defaultProfile.id, name)) {
      return;
    }

    final profileRestored = await profiles.rename(
      defaultProfile.id,
      defaultProfile.name,
    );
    final accountRestored =
        !updateAccount || await auth.updateName(oldAccountName);
    if (context.mounted) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            profileRestored && accountRestored
                ? context.l10n.couldnTUpdateYourName
                : 'Could not restore both names. Check your connection.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => BlocBuilder<AuthCubit, AuthState>(
    builder: (context, state) {
      final isTv = sl.isRegistered<AppMode>() && sl<AppMode>().isTv;
      if (!state.isLoggedIn) {
        void signIn() {
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(24, isTv ? 20 : 28, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(context.l10n.notSignedIn),
              const SizedBox(height: 12),
              if (isTv)
                TvFocusable(
                  autofocus: true,
                  semanticLabel: context.l10n.signIn,
                  onTap: signIn,
                  variant: TvFocusVariant.row,
                  borderRadius: 14,
                  child: Container(
                    height: 56,
                    decoration: BoxDecoration(
                      color: const Color(0x1AFFFFFF),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.hairline, width: 0.5),
                    ),
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.login_rounded,
                            color: AppColors.textPrimary,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            context.l10n.signIn,
                            style: AppText.button.copyWith(
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else
                SecondaryButton(
                  label: context.l10n.signIn,
                  icon: Icons.login_rounded,
                  onPressed: signIn,
                ),
            ],
          ),
        );
      }

      Widget accountAvatar() {
        final radius = isTv ? 56.0 : 48.0;
        final profiles = sl.isRegistered<ViewerProfileStore>()
            ? sl<ViewerProfileStore>()
            : null;
        Widget buildAvatar(String? accountPhotoUrl) => CircleAvatar(
          radius: radius,
          backgroundColor: AppColors.surface2,
          backgroundImage: accountPhotoUrl != null
              ? CachedNetworkImageProvider(accountPhotoUrl)
              : null,
          child: accountPhotoUrl == null
              ? Text(
                  state.displayName.isNotEmpty
                      ? state.displayName[0].toUpperCase()
                      : '?',
                  style: AppText.largeTitle,
                )
              : null,
        );
        if (profiles == null) return buildAvatar(state.avatarUrl);
        return ValueListenableBuilder<int>(
          valueListenable: profiles.revision,
          builder: (context, _, _) {
            final defaultProfile = profiles.profiles.firstWhere(
              (profile) => profile.id == kDefaultProfileId,
            );
            return buildAvatar(
              profilePhotoForFace(
                profile: defaultProfile,
                accountPhotoUrl: state.avatarUrl,
              ),
            );
          },
        );
      }

      final avatar = accountAvatar();
      final avatarBusy = state.busy || _avatarUploading;
      final name = Text(state.displayName, style: AppText.title);
      final logout = isTv
          ? TvFocusable(
              onTap: () {
                context.read<AuthCubit>().logout();
                Navigator.of(context).pop();
              },
              child: SizedBox(
                height: 56,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0x1AFFFFFF),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.hairline, width: 0.5),
                  ),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.logout_rounded,
                          color: AppColors.textPrimary,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          context.l10n.logOut,
                          style: AppText.button.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          : SecondaryButton(
              label: context.l10n.logOut,
              icon: Icons.logout_rounded,
              onPressed: () async {
                // Backs up an un-synced library first / warns before wiping.
                final done = await safeLogout(context);
                if (done && context.mounted) Navigator.of(context).pop();
              },
            );

      return Padding(
        padding: EdgeInsets.fromLTRB(24, isTv ? 20 : 28, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: isTv
                  ? avatar
                  // Windows: an image dropped or pasted on the avatar is
                  // uploaded; clicking opens the avatar menu below it.
                  : DesktopAvatarDropZone(
                      key: const ValueKey('account-avatar-drop'),
                      enabled: !avatarBusy,
                      borderRadius: BorderRadius.circular(999),
                      onImage: (bytes) => _uploadAccountAvatar(context, bytes),
                      onError: (message) => _showAvatarError(context, message),
                      child: Builder(
                        builder: (avatarContext) => GestureDetector(
                          key: const ValueKey('account-avatar-button'),
                          onTap: avatarBusy
                              ? null
                              : desktopPanelsEnabled
                              ? () => _pickAvatarDesktop(context, avatarContext)
                              : () => _pickAvatar(context),
                          child: Stack(
                            alignment: AlignmentDirectional.bottomEnd,
                            children: [
                              avatar,
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: AppColors.accent,
                                  shape: BoxShape.circle,
                                ),
                                child: avatarBusy
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.camera_alt_rounded,
                                        size: 14,
                                        color: Colors.white,
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 16),
            Center(
              child: isTv
                  ? name
                  : InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _editName(context, state.displayName),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                state.displayName,
                                style: AppText.title,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 7),
                            const Icon(
                              Icons.edit_rounded,
                              size: 15,
                              color: AppColors.textTertiary,
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(state.user?.email ?? '', style: AppText.caption),
            ),
            SizedBox(height: isTv ? 24 : 32),
            // Phone pairing remains available on mobile; desktop signs in directly.
            if (!isTv && !Platform.isWindows) ...[
              SizedBox(
                width: double.infinity,
                child: SecondaryButton(
                  label: 'Pair a TV or PC',
                  icon: Icons.tv_rounded,
                  onPressed: () =>
                      Navigator.of(context).push(PairTvScreen.route()),
                ),
              ),
              const SizedBox(height: 12),
            ],
            SizedBox(width: double.infinity, child: logout),
          ],
        ),
      );
    },
  );
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const ProfileScreenTv();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(context.l10n.profile),
      body: ListView(children: const [ProfileAccountSection()]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared bits
// ─────────────────────────────────────────────────────────────────────────────

/// Circular avatar picker for the signup form — shows the chosen image or a
/// placeholder with a camera badge + context.l10n.addPhoto caption.
class _AvatarPicker extends StatelessWidget {
  const _AvatarPicker({required this.path, required this.onTap});
  final String? path;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            alignment: AlignmentDirectional.bottomEnd,
            children: [
              CircleAvatar(
                radius: 44,
                backgroundColor: AppColors.surface2,
                backgroundImage: path != null ? FileImage(File(path!)) : null,
                child: path == null
                    ? const Icon(
                        Icons.person_outline,
                        size: 40,
                        color: AppColors.textTertiary,
                      )
                    : null,
              ),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.camera_alt_rounded,
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            path == null ? context.l10n.addPhoto : context.l10n.changePhoto,
            style: AppText.caption.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({
    required this.title,
    required this.subtitle,
    required this.children,
  });
  final String title;
  final String subtitle;
  final List<Widget> children;

  /// Width of the centred sign-in card on Windows.
  static const double desktopCardWidth = 440;

  @override
  Widget build(BuildContext context) {
    final header = <Widget>[
      Text(title, style: AppText.largeTitle),
      const SizedBox(height: 8),
      Text(subtitle, style: AppText.body),
      const SizedBox(height: 28),
    ];
    if (desktopPanelsEnabled) return _desktop(context, header);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(backgroundColor: Colors.transparent),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          children: [...header, ...children],
        ),
      ),
    );
  }

  /// Windows: the form sits in a ~440px graphite card centred in the window
  /// instead of stretching across a wide monitor. AutofillGroup lets password
  /// managers treat the fields as one sign-in form.
  Widget _desktop(BuildContext context, List<Widget> header) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(backgroundColor: Colors.transparent),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: desktopCardWidth),
              child: DecoratedBox(
                key: const ValueKey('auth-desktop-card'),
                decoration: BoxDecoration(
                  color: DesktopPanelColors.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: DesktopPanelColors.edge),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
                  child: AutofillGroup(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [...header, ...children],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SubmitBlock extends StatelessWidget {
  const _SubmitBlock({
    required this.label,
    required this.busy,
    required this.error,
    required this.onPressed,
  });
  final String label;
  final bool busy;
  final String? error;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null) ...[
          Text(
            error!,
            style: AppText.caption.copyWith(color: AppColors.accent),
          ),
          const SizedBox(height: 10),
        ],
        SizedBox(
          height: 52,
          child: busy
              ? Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: AppColors.accent,
                    ),
                  ),
                )
              : PrimaryButton(label: label, onPressed: onPressed),
        ),
      ],
    );
  }
}

class _SwitchLink extends StatelessWidget {
  const _SwitchLink({
    required this.prompt,
    required this.action,
    required this.onTap,
  });
  final String prompt;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Text.rich(
          TextSpan(
            text: '$prompt ',
            style: AppText.caption,
            children: [
              TextSpan(
                text: action,
                style: AppText.caption.copyWith(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Windows text prompt for the account page (reset-password email, edit
/// name): the graphite frame and buttons of showDesktopConfirm with one
/// field. Enter submits, Esc cancels. Returns the trimmed text, or null when
/// cancelled. Phone screens never call this; they keep their AlertDialogs.
@visibleForTesting
Future<String?> showAccountTextPrompt(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String? message,
  String? label,
  String? hint,
  String initial = '',
  int? maxLength,
  TextInputType? keyboardType,
  TextCapitalization textCapitalization = TextCapitalization.none,
}) => showDialog<String>(
  context: context,
  // Same navigator as showDesktopConfirm, so it sits over the shell.
  useRootNavigator: false,
  builder: (_) => _AccountTextPrompt(
    title: title,
    confirmLabel: confirmLabel,
    message: message,
    label: label,
    hint: hint,
    initial: initial,
    maxLength: maxLength,
    keyboardType: keyboardType,
    textCapitalization: textCapitalization,
  ),
);

/// Body of [showAccountTextPrompt]. Stateful so it owns (and disposes, after
/// the exit animation) its text controller.
class _AccountTextPrompt extends StatefulWidget {
  const _AccountTextPrompt({
    required this.title,
    required this.confirmLabel,
    required this.message,
    required this.label,
    required this.hint,
    required this.initial,
    required this.maxLength,
    required this.keyboardType,
    required this.textCapitalization,
  });

  final String title, confirmLabel, initial;
  final String? message, label, hint;
  final int? maxLength;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;

  @override
  State<_AccountTextPrompt> createState() => _AccountTextPromptState();
}

class _AccountTextPromptState extends State<_AccountTextPrompt> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_text.text.trim());

  /// Graphite field border; the accent marks the focused state.
  OutlineInputBorder _border(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: color),
  );

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: DesktopPanelColors.surface,
    surfaceTintColor: Colors.transparent,
    insetPadding: const EdgeInsets.all(24),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: DesktopPanelColors.edge),
    ),
    clipBehavior: Clip.antiAlias,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: AppText.headline.copyWith(
                fontSize: 20,
                color: AppColors.textPrimary,
              ),
            ),
            if (widget.message != null) ...[
              const SizedBox(height: 10),
              Text(
                widget.message!,
                style: AppText.body.copyWith(
                  color: AppColors.textSecondary,
                  height: 1.45,
                ),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _text,
              autofocus: true,
              keyboardType: widget.keyboardType,
              textCapitalization: widget.textCapitalization,
              textInputAction: TextInputAction.done,
              maxLength: widget.maxLength,
              cursorColor: AppColors.accent,
              style: AppText.body.copyWith(color: AppColors.textPrimary),
              // Enter submits from the field; Esc is the dialog's dismiss.
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                isDense: true,
                labelText: widget.label,
                hintText: widget.hint,
                hintStyle: AppText.body.copyWith(
                  color: AppColors.textTertiary,
                ),
                filled: true,
                fillColor: DesktopChrome.field,
                border: _border(DesktopPanelColors.edge),
                enabledBorder: _border(DesktopPanelColors.edge),
                focusedBorder: _border(AppColors.accent),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                  ),
                  child: Text(context.l10n.cancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: DesktopChrome.onAccent(AppColors.accent),
                  ),
                  child: Text(widget.confirmLabel),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

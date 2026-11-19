import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;

import '../../core/backup/auto_backup_runner.dart';
import '../../core/backup/restore_safety.dart';
import '../../core/desktop/desktop_native.dart';
import '../../core/desktop/desktop_prefs.dart';
import '../../core/desktop/desktop_reveal.dart';
import '../../core/stremio/stremio_backup_cipher.dart';
import '../../core/ui/desktop_settings_surface.dart';
import 'auto_backup_settings_panel.dart';
import 'restore_preview_dialog.dart';
import 'stremio_backup_password_dialog.dart';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_mode.dart';
import '../../core/backup/backup_cloud.dart';
import '../../core/backup/backup_file.dart';
import '../../core/backup/backup_payload.dart';
import '../../core/backup/backup_service.dart';
import '../../core/di/injector.dart';
import '../../core/profiles/profile_lock_store.dart';
import '../../core/profiles/profile_lock_remote.dart';
import '../../core/profiles/viewer_profile.dart';
import '../profiles/profile_lock_gate.dart';
import '../profiles/profile_unlock.dart'
    show ensureProfileAccess, hasLegacyPcPin;
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../core/ui/app_dialog.dart';
import '../../core/ui/settings_widgets.dart';
import '../auth/auth_cubit.dart';
import '../auth/auth_screens.dart';
import '../../l10n/l10n.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  /// Test hook replacing the app relaunch behind 'Restart now' (Windows).
  @visibleForTesting
  static Future<void> Function()? debugRestartApp;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final Set<BackupBundle> _selected = {...BackupBundle.values};
  bool _busy = false;

  BackupService get _service => sl<BackupService>();
  BackupCloud get _cloud => sl<BackupCloud>();

  bool get _isTv => sl<AppMode>().isTv;

  // ── Last cloud backup date (acct-8) ─────────────────────────────────────
  // Fetched once per signed-in account (timestamp only) and again after an
  // upload, never from build(), so ticking a checkbox doesn't re-query.

  /// The account [_lastCloudBackup] was fetched for.
  String? _lastCloudUid;

  /// The in-flight or finished date lookup shown under the restore card.
  Future<DateTime?>? _lastCloudBackup;

  /// Starts a fresh lookup for [uid] (null clears it).
  void _refreshLastCloudBackup(String? uid) {
    _lastCloudUid = uid;
    _lastCloudBackup = uid == null || !sl.isRegistered<BackupCloud>()
        ? null
        : _cloud.lastBackupAt(uid).catchError((Object _) => null);
  }

  // ── Saved backups list (acct-10, Windows) ───────────────────────────────

  /// Backup files in the automatic-backup and app Backups folders.
  Future<List<File>>? _savedBackups;

  /// Kept so the listener can be removed (each `changes` call is new).
  Listenable? _prefsListenable;

  void _reloadSavedBackups() {
    if (!mounted) return;
    setState(() {
      _savedBackups = BackupFile().listBackupsIn(
        AutoBackupRunner.listedFolders(),
      );
    });
  }

  @override
  void initState() {
    super.initState();
    try {
      _refreshLastCloudBackup(context.read<AuthCubit>().state.user?.id);
    } catch (_) {
      // No AuthCubit above (some tests); the date line is hidden anyway.
    }
    if (_isWindows) {
      _savedBackups = BackupFile().listBackupsIn(
        AutoBackupRunner.listedFolders(),
      );
      // Refresh the list when a backup is written or the folder changes.
      AutoBackupRunner.revision.addListener(_reloadSavedBackups);
      _prefsListenable = DesktopPrefs.changes..addListener(_reloadSavedBackups);
    }
  }

  @override
  void dispose() {
    AutoBackupRunner.revision.removeListener(_reloadSavedBackups);
    _prefsListenable?.removeListener(_reloadSavedBackups);
    super.dispose();
  }

  Future<bool> _authorizeBackup() async {
    try {
      if (sl.isRegistered<ProfileLockStore>() &&
          sl.isRegistered<ViewerProfileStore>()) {
        final locks = sl<ProfileLockStore>();
        for (final profile in sl<ViewerProfileStore>().profiles) {
          // Windows: an old PC-only PIN not yet moved into the synced lock
          // still guards its profile's data here (asks it once, then moves
          // it). Always false on phone and TV.
          if (await hasLegacyPcPin(profile.id)) {
            if (!mounted || !await ensureProfileAccess(context, profile)) {
              return false;
            }
            continue;
          }
          if (await locks.isLocked(profile.id) &&
              !locks.isUnlocked(profile.id)) {
            if (!mounted || !await ensureProfileUnlocked(context, profile)) {
              return false;
            }
          }
        }
      }
      await _service.authorize();
      return mounted;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is ProfileLockException
                  ? error.message
                  : context.l10n.somethingWentWrong,
            ),
          ),
        );
      }
      return false;
    }
  }

  Future<void> _backupToCloud() async {
    if (!requireLogin(context, action: context.l10n.signInToBackUpToCloud)) {
      return;
    }
    final uid = context.read<AuthCubit>().state.user?.id;
    if (uid == null) return;
    setState(() => _busy = true);
    try {
      if (!await _authorizeBackup()) return;
      await _cloud.upload(uid, await _service.buildProtected(_selected));
      if (!mounted) return;
      // The date line under the restore card now shows this upload.
      setState(() => _refreshLastCloudBackup(uid));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.backedUpToCloud)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.cloudBackupFailed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _addonPassword({required bool confirm}) => showDialog<String>(
    context: context,
    builder: (_) => StremioBackupPasswordDialog(confirm: confirm),
  );

  /// Windows build: native-desktop wording and the Save-as flow below.
  bool get _isWindows => defaultTargetPlatform == TargetPlatform.windows;

  /// Windows: build the backup, let the user choose where it goes with the
  /// native Save-as dialog, then show the real path with a "Show in folder"
  /// action. Cancelling the dialog is silent and saves nothing.
  Future<void> _saveToFileWindows(String? password) async {
    setState(() => _busy = true);
    String? path;
    try {
      if (!await _authorizeBackup()) return;
      final payload = await _service.buildProtected(
        _selected,
        forFile: true,
        password: password,
      );
      path = await BackupFile().exportToChosenFile(payload);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "Couldn't save the backup file. Choose a folder you can write "
              'to and try again.',
            ),
          ),
        );
      }
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (path == null || !mounted) return; // dialog cancelled
    final saved = path;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: const ValueKey('backup-saved-snackbar'),
        duration: const Duration(seconds: 8),
        content: Text('Backup saved to $saved'),
        action: SnackBarAction(
          label: 'Show in folder',
          onPressed: () => unawaited(revealInExplorer(saved)),
        ),
      ),
    );
  }

  Future<void> _saveToFile() async {
    String? password;
    if (_selected.contains(BackupBundle.sources)) {
      password = await _addonPassword(confirm: true);
      if (!mounted || password == null) return;
    }
    if (_isWindows) return _saveToFileWindows(password);
    setState(() => _busy = true);
    try {
      if (!await _authorizeBackup()) return;
      // On TV also keep an app-private copy so restore-from-file can list it
      // without a document picker (see [_restoreFromFile]).
      final path = await BackupFile().export(
        await _service.buildProtected(
          _selected,
          forFile: true,
          password: password,
        ),
        keepLocalCopy: _isTv,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            path == null
                ? context
                      .l10n
                      .couldnTSaveTheBackupFileStoragePermissionMayBeNeeded
                : context.l10n.savedToDownloadsZangetsu,
          ),
        ),
      );
    } catch (_) {
      // File-system errors must leave an actionable result, not an unhandled
      // future that makes the Save button appear to have done nothing.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.couldnTSaveTheBackupFileStoragePermissionMayBeNeeded,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreFromCloud() async {
    if (!requireLogin(context, action: context.l10n.signInToRestoreFromCloud)) {
      return;
    }
    final uid = context.read<AuthCubit>().state.user?.id;
    if (uid == null) return;
    if (_isWindows) return _restoreFromCloudWindows(uid);
    setState(() => _busy = true);
    late final RestoreReport report;
    try {
      if (!await _authorizeBackup()) return;
      final p = await _cloud.download(uid);
      if (!mounted) return;
      if (p == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.noCloudBackupFound)),
        );
        return;
      }
      report = await _service.restore(p, _selected);
    } catch (_) {
      // A temporary cloud outage must not escape the button handler or leave
      // users without an explanation. Preserve all local data on failure.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.restoreFailed(context.l10n.somethingWentWrong),
          ),
        ),
      );
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) _showResultAfterBusy(report);
  }

  // ── Windows restore (acct-4, acct-10, acct-12) ──────────────────────────

  /// Windows: download the cloud backup, then preview it before restoring.
  Future<void> _restoreFromCloudWindows(String uid) async {
    setState(() => _busy = true);
    Map<String, dynamic>? p;
    try {
      p = await _cloud.download(uid);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.restoreFailed(context.l10n.somethingWentWrong),
            ),
          ),
        );
      }
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (p == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.noCloudBackupFound)));
      return;
    }
    await _restoreWithPreview(p, context.l10n.yourCloudBackup);
  }

  /// Windows: Open dialog (filtered to .json), then preview and restore.
  Future<void> _restoreFromFileWindows() async {
    Map<String, dynamic>? p;
    try {
      p = await BackupFile().import();
    } on FormatException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.thatFileIsnTAValidBackup)),
        );
      }
      return;
    } catch (_) {
      return;
    }
    if (p == null || !mounted) return;
    await _restoreWithPreview(p, context.l10n.backupFile);
  }

  /// Windows: restore one of the files listed under 'Saved backups'.
  Future<void> _restoreSavedFile(File file) async {
    Map<String, dynamic> p;
    try {
      p = await BackupFile().readBackup(file);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.couldnTReadThatBackupFile)),
        );
      }
      return;
    }
    if (!mounted) return;
    await _restoreWithPreview(p, file.uri.pathSegments.last);
  }

  /// Windows restore: preview (what's inside, per-part checkboxes, settings
  /// warning), add-on password if needed, an automatic safety copy of the
  /// current library and settings, the restore itself, then a result dialog
  /// with 'Restart now' and 'Undo restore'.
  ///
  /// The parts restored are the ones ticked in the preview, not the
  /// 'Include in the backup' checkboxes (those only shape new backups).
  Future<void> _restoreWithPreview(
    Map<String, dynamic> p,
    String sourceLabel,
  ) async {
    if (p['app'] != 'zangetsu') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.thatFileIsnTAValidBackup)),
      );
      return;
    }
    final chosen = await showRestorePreview(
      context,
      payload: p,
      sourceLabel: sourceLabel,
    );
    if (chosen == null || chosen.isEmpty || !mounted) return;
    String? password;
    final sources = (p['bundles'] as Map?)?['sources'];
    final envelope = sources is Map ? sources['stremio'] : null;
    if (chosen.contains(BackupBundle.sources) &&
        envelope is Map &&
        envelope['format'] == StremioBackupCipher.format) {
      password = await _addonPassword(confirm: false);
      if (!mounted || password == null) return;
    }
    setState(() => _busy = true);
    RestoreReport? report;
    RestoreSafetySnapshot? safety;
    String? safetyPath;
    try {
      if (!await _authorizeBackup()) return;
      // Sources install extensions, which a box copy can't undo, so the
      // safety copy covers library and settings only.
      final undoable = chosen.difference({BackupBundle.sources});
      safety = RestoreSafetySnapshot.capture(
        RestoreSafetySnapshot.boxNamesFor(undoable),
      );
      safetyPath = await AutoBackupRunner.saveSafetyCopy(undoable);
      report = await _service.restore(p, chosen, password: password);
    } on BackupFormatException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.restoreFailed('$e'))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (report == null || !mounted) return;
    final done = report;
    final snapshot = safety;
    // After the busy overlay is gone, like [_showResultAfterBusy].
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final action = await showRestoreResult(
      context,
      restored: done.restored,
      failures: done.failures,
      canUndo: snapshot != null && snapshot.boxNames.isNotEmpty,
      safetyCopyPath: safetyPath,
    );
    if (!mounted) return;
    switch (action) {
      case RestoreResultAction.restartNow:
        await _restartApp();
      case RestoreResultAction.undo:
        await _undoRestore(snapshot!);
      case RestoreResultAction.later:
        break;
    }
  }

  /// Puts library and settings back to the safety copy, then offers a restart.
  Future<void> _undoRestore(RestoreSafetySnapshot snapshot) async {
    setState(() => _busy = true);
    try {
      await snapshot.rollback();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: const ValueKey('restore-undone-snackbar'),
        duration: const Duration(seconds: 8),
        content: Text(
          context.l10n.restoreUndone,
        ),
        action: SnackBarAction(
          label: context.l10n.restartNow,
          onPressed: () => unawaited(_restartApp()),
        ),
      ),
    );
  }

  /// Relaunches Zangetsu so every screen reloads the restored data.
  Future<void> _restartApp() =>
      (BackupScreen.debugRestartApp ?? DesktopNative.restartApp)();

  Future<void> _restoreFromFile() async {
    if (_isWindows) return _restoreFromFileWindows();
    // On TV, prefer the SAF document picker too — Android TV's DocumentsUI is
    // D-pad-navigable, so a backup transferred from another device (e.g. the
    // phone app) can be browsed to and restored. Fall back to scanning the
    // app-readable backup files on boxes that genuinely lack a picker.
    Map<String, dynamic>? p;
    try {
      p = await BackupFile().import();
    } on FormatException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.thatFileIsnTAValidBackup)),
      );
      if (!_isTv) return;
      p = null; // on TV, fall back to the app-readable local picker below
    } catch (_) {
      p = null;
    }
    if (_isTv) p ??= await _pickLocalBackupTv();
    if (p == null || !mounted) return;
    String? password;
    final sources = (p['bundles'] as Map?)?['sources'];
    final envelope = sources is Map ? sources['stremio'] : null;
    if (_selected.contains(BackupBundle.sources) &&
        envelope is Map &&
        envelope['format'] == StremioBackupCipher.format) {
      password = await _addonPassword(confirm: false);
      if (!mounted || password == null) return;
    }
    setState(() => _busy = true);
    RestoreReport? report;
    try {
      if (!await _authorizeBackup()) return;
      report = await _service.restore(p, _selected, password: password);
    } on BackupFormatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.restoreFailed('$e'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (report != null && mounted) _showResultAfterBusy(report);
  }

  /// TV restore: enumerate app-readable backup files and show a D-pad list.
  /// Returns the parsed backup, or null if none exist / the user backs out.
  Future<Map<String, dynamic>?> _pickLocalBackupTv() async {
    final backup = BackupFile();
    final files = await backup.listLocalBackups();
    if (!mounted) return null;
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.noBackupFilesOnDevice)),
      );
      return null;
    }
    final chosen = await showDialog<File>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppColors.surface,
        title: Text(context.l10n.pickABackup, style: AppText.headline),
        children: [
          for (var i = 0; i < files.length; i++)
            TvListFocusable(
              autofocus: i == 0,
              onTap: () => Navigator.pop(ctx, files[i]),
              semanticLabel: _backupLabel(files[i]),
              // Row focus is an accent wash over the dark surface, not a white
              // pill — keep the text and icon light or they disappear into it.
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.description_outlined,
                      color: AppColors.textSecondary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _backupLabel(files[i]),
                        style: AppText.body.copyWith(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (chosen == null) return null;
    try {
      return await backup.readBackup(chosen);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.couldnTReadThatBackupFile)),
        );
      }
      return null;
    }
  }

  /// Friendly label for a backup file, parsed from its
  /// `zangetsu-backup-YYYYMMDD-HHMM.json` name (falls back to the raw name).
  String _backupLabel(File f) {
    final name = f.uri.pathSegments.last;
    final m = RegExp(r'(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})').firstMatch(name);
    if (m == null) return name;
    return '${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}';
  }

  /// Show after the busy overlay has rebuilt away — otherwise that setState
  /// can re-seed D-pad focus on a [SettingsTile] and the dialog never gets it.
  void _showResultAfterBusy(RestoreReport r) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showResult(r);
    });
  }

  void _showResult(RestoreReport r) {
    final names = r.restored
        .map(
          (b) => switch (b) {
            BackupBundle.sources => context.l10n.sourcesAndRepos,
            BackupBundle.library => context.l10n.libraryBundle,
            BackupBundle.settings => context.l10n.appSettingsBundle,
          },
        )
        .join(', ');
    final l10n = context.l10n;
    AppDialog.alert(
      context,
      title: l10n.restoreComplete,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.restoredColon(names)),
          if (r.hasFailures) ...[
            const SizedBox(height: 8),
            Text(l10n.couldnTReinstall(r.failures.join('\n'))),
          ],
          const SizedBox(height: 8),
          Text(l10n.reopenZangetsuToSeeRestoredLibrarySources),
        ],
      ),
    );
  }

  Widget _bundleRow(BackupBundle bundle, String label, String subtitle) {
    final selected = _selected.contains(bundle);
    void toggle() => setState(() {
      if (_selected.contains(bundle)) {
        _selected.remove(bundle);
      } else {
        _selected.add(bundle);
      }
    });
    // On TV, SettingsTile is already D-pad focusable (white pill). Phones keep
    // the Material CheckboxListTile.
    if (_isTv) {
      return SettingsTile(
        icon: selected
            ? Icons.check_box_rounded
            : Icons.check_box_outline_blank_rounded,
        title: label,
        subtitle: subtitle,
        onTap: _busy ? null : toggle,
      );
    }
    // Windows settings workspace: a graphite row with a trailing checkbox, the
    // same pattern as Privacy's "Adult catalogue", so these rows match the
    // padding, type and hover of every other desktop settings row.
    if (DesktopSettingsScope.contains(context)) {
      return SettingsTile(
        icon: switch (bundle) {
          BackupBundle.sources => Icons.extension_outlined,
          BackupBundle.library => Icons.video_library_outlined,
          BackupBundle.settings => Icons.tune_rounded,
        },
        title: label,
        subtitle: subtitle,
        onTap: _busy ? null : toggle,
        trailing: Checkbox(
          key: ValueKey('backup-bundle-${bundle.name}'),
          value: selected,
          activeColor: AppColors.accent,
          onChanged: _busy ? null : (_) => toggle(),
        ),
      );
    }
    // Transparent Material so the tile's ink/splash paints above the
    // SettingsCard's DecoratedBox background (Flutter asserts otherwise — the
    // card colour would hide the splash).
    return Material(
      type: MaterialType.transparency,
      child: CheckboxListTile(
        value: selected,
        onChanged: _busy ? null : (v) => toggle(),
        title: Text(
          label,
          style: AppText.body.copyWith(color: AppColors.textPrimary),
        ),
        subtitle: Text(subtitle, style: AppText.caption),
        activeColor: AppColors.accent,
        controlAffinity: ListTileControlAffinity.leading,
      ),
    );
  }

  String _fmtDt(DateTime dt) {
    final l = dt.toLocal();
    final mo = l.month.toString().padLeft(2, '0');
    final d = l.day.toString().padLeft(2, '0');
    final h = l.hour.toString().padLeft(2, '0');
    final mi = l.minute.toString().padLeft(2, '0');
    return '${l.year}-$mo-$d $h:$mi';
  }

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthCubit>().state.user?.id;
    // Desktop panels are inset 22px, so loose captions line up at 24px there.
    final hPad = DesktopSettingsScope.contains(context) ? 24.0 : 16.0;

    // Signing in or out (or switching account) fetches that account's last
    // cloud backup date once; plain rebuilds reuse the cached lookup.
    return BlocListener<AuthCubit, AuthState>(
      listenWhen: (a, b) => a.user?.id != b.user?.id,
      listener: (_, state) {
        if (state.user?.id != _lastCloudUid) {
          setState(() => _refreshLastCloudBackup(state.user?.id));
        }
      },
      child: _scaffold(context, uid, hPad),
    );
  }

  /// Windows: one row per saved backup file, with Restore and Show in folder.
  Widget _savedBackupsSection(double hPad) {
    return FutureBuilder<List<File>>(
      future: _savedBackups,
      builder: (context, snap) {
        final files = snap.data ?? const <File>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSectionLabel(context.l10n.savedBackups),
            if (files.isEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(hPad, 4, hPad, 4),
                child: Text(
                  snap.connectionState == ConnectionState.done
                      ? context.l10n.noBackupsInFoldersYet
                      : context.l10n.lookingForBackups,
                  style: AppText.caption,
                ),
              )
            else
              SettingsCard(
                children: [
                  // Newest first; older ones stay reachable via the folder.
                  for (final f in files.take(20)) _savedBackupRow(f),
                ],
              ),
          ],
        );
      },
    );
  }

  /// One saved backup: when it was made, what kind it is, and its actions.
  Widget _savedBackupRow(File f) {
    final name = f.uri.pathSegments.last;
    final lower = name.toLowerCase();
    final kind = lower.startsWith('${AutoBackupRunner.autoPrefix}-')
        ? context.l10n.automaticBackup
        : lower.startsWith('${AutoBackupRunner.safetyPrefix}-')
        ? context.l10n.safetyCopyBeforeRestore
        : context.l10n.backupKind;
    return SettingsTile(
      key: ValueKey('saved-backup-$name'),
      icon: Icons.description_outlined,
      title: _backupLabel(f),
      subtitle: '$kind · ${f.parent.path}',
      subtitleMaxLines: null,
      onTap: _busy ? null : () => _restoreSavedFile(f),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: _busy ? null : () => _restoreSavedFile(f),
            child: Text(context.l10n.restore),
          ),
          TextButton(
            onPressed: () => unawaited(revealInExplorer(f.path)),
            child: Text(context.l10n.showInFolder),
          ),
        ],
      ),
    );
  }

  Widget _scaffold(BuildContext context, String? uid, double hPad) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(context.l10n.backupAndRestore),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 28),
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(hPad, 4, hPad, 4),
                child: Text(
                  // Windows restores replace settings, so say so there; the
                  // phone wording is unchanged.
                  _isWindows
                      ? context.l10n.backupIntroWindows
                      : 'Save your sources, list and settings — to a file on your '
                            'device or to your Zangetsu account. Restoring only adds '
                            'things back; it never deletes what you already have.',
                  style: AppText.caption,
                ),
              ),
              SettingsSectionLabel(context.l10n.includeInTheBackup),
              SettingsCard(
                children: [
                  _bundleRow(
                    BackupBundle.sources,
                    context.l10n.sourcesAndRepos,
                    context.l10n.installedSourcesAndRepoLinks,
                  ),
                  _bundleRow(
                    BackupBundle.library,
                    context.l10n.libraryBundle,
                    context.l10n.myListAndContinueWatching,
                  ),
                  _bundleRow(
                    BackupBundle.settings,
                    context.l10n.appSettingsBundle,
                    context.l10n.playerSubtitlesQualityPreferences,
                  ),
                ],
              ),
              const SettingsSectionLabel('Create a backup'),
              SettingsCard(
                children: [
                  SettingsTile(
                    autofocus: true,
                    icon: Icons.save_alt_outlined,
                    title: context.l10n.saveToAFile,
                    // Windows asks where to save; phones save to Downloads.
                    subtitle: _isWindows
                        ? 'Choose where to save a backup file on this PC'
                        : context.l10n.saveABackupFileToYourDownloadsFolder,
                    onTap: _busy ? null : _saveToFile,
                  ),
                  SettingsTile(
                    icon: Icons.cloud_upload_outlined,
                    title: context.l10n.backUpToCloud,
                    subtitle: context.l10n.saveACopyToYourAccountNeedsSignIn,
                    onTap: _busy ? null : _backupToCloud,
                  ),
                ],
              ),
              const SettingsSectionLabel('Restore a backup'),
              SettingsCard(
                children: [
                  SettingsTile(
                    icon: Icons.folder_open_outlined,
                    title: context.l10n.restoreFromAFile,
                    subtitle: context.l10n.pickABackupFileYouSavedEarlier,
                    onTap: _busy ? null : _restoreFromFile,
                  ),
                  SettingsTile(
                    icon: Icons.cloud_download_outlined,
                    title: context.l10n.restoreFromCloud,
                    subtitle: context.l10n.bringBackYourLatestCloudBackup,
                    onTap: _busy ? null : _restoreFromCloud,
                  ),
                ],
              ),
              if (uid != null)
                Padding(
                  padding: EdgeInsets.fromLTRB(hPad, 8, hPad, 0),
                  child: FutureBuilder<DateTime?>(
                    // Cached lookup (acct-8): see _refreshLastCloudBackup.
                    future: _lastCloudBackup,
                    builder: (_, snap) {
                      final dt = snap.data;
                      final label = dt == null
                          ? context.l10n.never
                          : _fmtDt(dt);
                      return Text(
                        'Last cloud backup: $label',
                        style: AppText.caption,
                      );
                    },
                  ),
                ),
              // Windows: automatic backups (settings) and the backups found
              // in the backup folders, each restorable (acct-10).
              if (_isWindows) ...[
                const SizedBox(height: 8),
                const AutoBackupSettingsPanel(),
                _savedBackupsSection(hPad),
              ],
            ],
          ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x55000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}

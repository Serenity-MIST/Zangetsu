import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/desktop/desktop_prefs.dart';
import '../../core/desktop/desktop_reveal.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/desktop_settings_surface.dart';
import '../../core/ui/settings_widgets.dart';
import '../../l10n/l10n.dart';

/// Test hook: replaces the Windows folder picker.
@visibleForTesting
Future<String?> Function()? debugPickAutoBackupFolder;

/// Label for an automatic backup frequency.
/// Uses appL10n (no context needed); it follows the app language.
String autoBackupFrequencyLabel(AutoBackupFrequency f) => switch (f) {
  AutoBackupFrequency.daily => appL10n.everyDay,
  AutoBackupFrequency.weekly => appL10n.everyWeek,
};

/// Settings block for automatic scheduled backups (acct-10 Option A): on/off,
/// the folder (for example a OneDrive folder), how often, and how many to
/// keep. It only stores the choices in [DesktopPrefs]; the backup screen
/// embeds it and the backup runner reads the same values on launch.
class AutoBackupSettingsPanel extends StatefulWidget {
  const AutoBackupSettingsPanel({super.key});

  @override
  State<AutoBackupSettingsPanel> createState() =>
      _AutoBackupSettingsPanelState();
}

class _AutoBackupSettingsPanelState extends State<AutoBackupSettingsPanel> {
  Future<void> _chooseFolder() async {
    final pick = debugPickAutoBackupFolder;
    final path = pick != null
        ? await pick()
        : await FilePicker.getDirectoryPath(
            dialogTitle: context.l10n.chooseAutoBackupFolder,
          );
    if (path == null || path.isEmpty) return;
    await DesktopPrefs.setAutoBackupFolder(path);
  }

  Future<void> _openFolder() async {
    final folder = DesktopPrefs.autoBackupFolder;
    if (folder == null) return;
    final ok = await revealInExplorer(folder);
    if (!ok && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(context.l10n.folderNoLongerExists),
        ),
      );
    }
  }

  Future<void> _pickFrequency() async {
    final picked = await showGraphiteSettingsChoice<AutoBackupFrequency>(
      context,
      title: context.l10n.howOften,
      options: [
        for (final f in AutoBackupFrequency.values)
          (f, autoBackupFrequencyLabel(f)),
      ],
      current: DesktopPrefs.autoBackupFrequency,
    );
    if (picked != null) await DesktopPrefs.setAutoBackupFrequency(picked);
  }

  Future<void> _pickKeep() async {
    final picked = await showGraphiteSettingsChoice<int>(
      context,
      title: context.l10n.keepLabel,
      description: context.l10n.olderAutoBackupsDeleted,
      options: [
        for (final n in DesktopPrefs.autoBackupKeepChoices)
          (n, context.l10n.lastNBackups(n)),
      ],
      current: DesktopPrefs.autoBackupKeep,
    );
    if (picked != null) await DesktopPrefs.setAutoBackupKeep(picked);
  }

  Future<void> _setEnabled(bool v) async {
    // Turning it on with no folder asks for one first; cancelling leaves it
    // off so the runner never has nowhere to write.
    if (v && DesktopPrefs.autoBackupFolder == null) {
      await _chooseFolder();
      if (DesktopPrefs.autoBackupFolder == null) return;
    }
    await DesktopPrefs.setAutoBackupEnabled(v);
  }

  // "Last run" text under the toggle.
  String _lastRunText() {
    final last = DesktopPrefs.autoBackupLastRun;
    if (last == null) return context.l10n.noAutoBackupYet;
    final local = last.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return context.l10n.lastBackupAt(
      '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DesktopPrefs.changes,
      builder: (context, _) {
        final enabled = DesktopPrefs.autoBackupEnabled;
        final folder = DesktopPrefs.autoBackupFolder;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSectionLabel(context.l10n.automaticBackups),
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.backup_outlined,
                  title: context.l10n.backUpAutomatically,
                  subtitle: enabled
                      ? _lastRunText()
                      : context.l10n.saveBackupOnSchedule,
                  subtitleMaxLines: null,
                  onTap: () => _setEnabled(!enabled),
                  trailing: Switch.adaptive(
                    value: enabled,
                    activeThumbColor: AppColors.accent,
                    onChanged: _setEnabled,
                  ),
                ),
                SettingsTile(
                  icon: Icons.folder_outlined,
                  title: context.l10n.folderLabel,
                  subtitle: folder ?? context.l10n.notChosen,
                  subtitleMaxLines: null,
                  onTap: _chooseFolder,
                  trailing: folder == null
                      ? null
                      : TextButton(
                          onPressed: _openFolder,
                          child: Text(context.l10n.openFolder),
                        ),
                ),
                SettingsTile(
                  icon: Icons.event_repeat_outlined,
                  title: context.l10n.howOften,
                  trailing: _value(
                    autoBackupFrequencyLabel(DesktopPrefs.autoBackupFrequency),
                  ),
                  onTap: _pickFrequency,
                ),
                SettingsTile(
                  icon: Icons.layers_outlined,
                  title: context.l10n.keepLabel,
                  trailing: _value(
                    context.l10n.lastN(DesktopPrefs.autoBackupKeep),
                  ),
                  onTap: _pickKeep,
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  // Small value label used as a choice row's trailing.
  Widget _value(String text) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(color: AppColors.textSecondary),
  );
}

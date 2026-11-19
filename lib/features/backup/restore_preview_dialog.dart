import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/backup/backup_payload.dart';
import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_docked_panel.dart';
import '../../l10n/l10n.dart';

/// Windows restore preview (acct-4 Option A): shows when the backup was made
/// and what is inside it with counts, lets the user tick which parts to
/// restore, and warns that settings will be replaced. Returns the ticked
/// bundles, or null when cancelled.
///
/// [payload] is the raw backup map (as read from a file or the cloud).
Future<Set<BackupBundle>?> showRestorePreview(
  BuildContext context, {
  required Map<String, dynamic> payload,
  required String sourceLabel,
}) => showDialog<Set<BackupBundle>>(
  context: context,
  builder: (_) =>
      RestorePreviewDialog(payload: payload, sourceLabel: sourceLabel),
);

/// Display name of a bundle in the preview.
/// Uses appL10n (no context needed); it follows the app language.
String restoreBundleLabel(BackupBundle b) => switch (b) {
  BackupBundle.sources => appL10n.sourcesAndReposText,
  BackupBundle.library => appL10n.libraryLabel,
  BackupBundle.settings => appL10n.appSettingsBundle,
};

/// Translated "N things" text for one backup count. The labels from
/// summarizeBackup are fixed English ids; unknown ones are shown as they are.
String backupCountText(AppLocalizations l10n, BackupCount c) =>
    switch (c.label) {
      'sources' => l10n.backupCountSources(c.count),
      'repos' => l10n.backupCountRepos(c.count),
      'list items' => l10n.backupCountListItems(c.count),
      'in Continue Watching' => l10n.backupCountContinueWatching(c.count),
      'reading history' => l10n.backupCountReadingHistory(c.count),
      'categories' => l10n.backupCountCategories(c.count),
      'resume points' => l10n.backupCountResumePoints(c.count),
      'setting groups' => l10n.backupCountSettingGroups(c.count),
      'hand-made title matches' => l10n.backupCountTitleMatches(c.count),
      _ => '${c.count} ${c.label}',
    };

/// What the user picked in the Windows restore-complete dialog.
enum RestoreResultAction { restartNow, undo, later }

/// Windows restore-complete dialog (acct-4 + acct-12): what was restored,
/// any failures, where the safety copy went, and the actions 'Restart now'
/// (relaunches the app so every screen reloads), 'Undo restore' (only when a
/// safety copy exists) and 'Later'. Returns the chosen action.
Future<RestoreResultAction> showRestoreResult(
  BuildContext context, {
  required Set<BackupBundle> restored,
  required List<String> failures,
  required bool canUndo,
  String? safetyCopyPath,
}) async {
  final action = await showDialog<RestoreResultAction>(
    context: context,
    builder: (dialogContext) {
      void pick(RestoreResultAction a) => Navigator.of(dialogContext).pop(a);
      return CallbackShortcuts(
        // Enter restarts (the main action), Esc means Later.
        // includeRepeats: false so an Enter still held down from confirming
        // the preview can't restart the app by itself.
        bindings: {
          const SingleActivator(
            LogicalKeyboardKey.enter,
            includeRepeats: false,
          ): () =>
              pick(RestoreResultAction.restartNow),
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              pick(RestoreResultAction.later),
        },
        child: Focus(
          autofocus: true,
          child: _graphiteFrame(
            dialogContext,
            maxWidth: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dialogContext.l10n.restoreComplete,
                  style: AppText.headline.copyWith(
                    fontSize: 20,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  dialogContext.l10n.restoredParts(restored.map(restoreBundleLabel).join(', ')),
                  style: AppText.body.copyWith(color: AppColors.textPrimary),
                ),
                if (failures.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    dialogContext.l10n.couldntReinstall(failures.join('\n')),
                    style: AppText.caption,
                  ),
                ],
                if (safetyCopyPath != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    dialogContext.l10n.safetyCopyOfPreviousData(safetyCopyPath),
                    key: const ValueKey('restore-result-safety-path'),
                    style: AppText.caption,
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  dialogContext.l10n.restartToSeeRestored,
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 18),
                // Wrap, not Row: long translations (or large text) move the
                // buttons onto a second line instead of overflowing.
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (canUndo)
                      TextButton(
                        key: const ValueKey('restore-result-undo'),
                        onPressed: () => pick(RestoreResultAction.undo),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.textSecondary,
                        ),
                        child: Text(dialogContext.l10n.undoRestore),
                      ),
                    TextButton(
                      onPressed: () => pick(RestoreResultAction.later),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.textSecondary,
                      ),
                      child: Text(dialogContext.l10n.later),
                    ),
                    FilledButton(
                      key: const ValueKey('restore-result-restart'),
                      onPressed: () => pick(RestoreResultAction.restartNow),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: DesktopChrome.onAccent(
                          AppColors.accent,
                        ),
                      ),
                      child: Text(dialogContext.l10n.restartNow),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  return action ?? RestoreResultAction.later;
}

/// The rounded graphite dialog frame (radius 20, panel surface and edge),
/// the same look as the desktop confirm and settings-choice dialogs.
Widget _graphiteFrame(
  BuildContext context, {
  required Widget child,
  double maxWidth = 500,
}) => Dialog(
  backgroundColor: DesktopPanelColors.surface,
  surfaceTintColor: Colors.transparent,
  insetPadding: const EdgeInsets.all(24),
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(20),
    side: BorderSide(color: DesktopPanelColors.edge),
  ),
  clipBehavior: Clip.antiAlias,
  child: ConstrainedBox(
    constraints: BoxConstraints(
      maxWidth: maxWidth,
      maxHeight: MediaQuery.sizeOf(context).height * 0.85,
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
      child: child,
    ),
  ),
);

/// 'YYYY-MM-DD HH:MM' in local time.
String formatBackupDate(DateTime dt) {
  final l = dt.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} '
      '${two(l.hour)}:${two(l.minute)}';
}

/// The preview body. Public for widget tests.
class RestorePreviewDialog extends StatefulWidget {
  const RestorePreviewDialog({
    super.key,
    required this.payload,
    required this.sourceLabel,
  });

  final Map<String, dynamic> payload;

  /// Where the backup came from, e.g. 'From your cloud backup'.
  final String sourceLabel;

  @override
  State<RestorePreviewDialog> createState() => _RestorePreviewDialogState();
}

class _RestorePreviewDialogState extends State<RestorePreviewDialog> {
  late final Map<BackupBundle, List<BackupCount>> _summary = summarizeBackup(
    widget.payload,
  );

  /// Parts to restore; starts as everything the backup holds.
  late final Set<BackupBundle> _ticked = {..._summary.keys};

  void _confirm() {
    if (_ticked.isEmpty) return;
    Navigator.of(context).pop({..._ticked});
  }

  /// '120 list items · 34 in Continue Watching', skipping zero counts.
  String _countsLine(List<BackupCount> counts) {
    final parts = [
      for (final c in counts)
        if (c.count > 0) backupCountText(context.l10n, c),
    ];
    return parts.isEmpty
        ? context.l10n.nothingSavedInPart
        : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final created = backupCreatedAt(widget.payload);
    final settingsTicked = _ticked.contains(BackupBundle.settings);
    return CallbackShortcuts(
      // Enter restores, Esc cancels, as in the other graphite dialogs.
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): _confirm,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _confirm,
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        // Same rounded graphite frame as the desktop confirm dialogs.
        child: _graphiteFrame(
          context,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.restoreThisBackup,
                style: AppText.headline.copyWith(
                  fontSize: 20,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                created == null
                    ? context.l10n.backupSourceDateUnknown(widget.sourceLabel)
                    : context.l10n.backupSourceMadeOn(widget.sourceLabel, formatBackupDate(created)),
                key: const ValueKey('restore-preview-date'),
                style: AppText.caption,
              ),
              const SizedBox(height: 14),
              Text(
                context.l10n.chooseWhatToRestore,
                style: AppText.body.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 6),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [for (final b in BackupBundle.values) _row(b)],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (settingsTicked)
                _note(
                  Icons.warning_amber_rounded,
                  context.l10n.settingsWillBeReplaced,
                ),
              // The safety copy only covers library and settings, so the note
              // shows only when one of them is ticked, and says when the
              // ticked sources can't be undone.
              if (_ticked.contains(BackupBundle.library) || settingsTicked)
                _note(
                  Icons.shield_outlined,
                  _ticked.contains(BackupBundle.sources)
                      ? context.l10n.safetyCopySourcesNoUndo
                      : context.l10n.safetyCopyUndoRestore,
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
                    key: const ValueKey('restore-preview-confirm'),
                    onPressed: _ticked.isEmpty ? null : _confirm,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: DesktopChrome.onAccent(AppColors.accent),
                    ),
                    child: Text(context.l10n.restore),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One part of the backup: checkbox, name and counts. Parts the backup
  /// doesn't contain are shown greyed out with no checkbox action.
  Widget _row(BackupBundle b) {
    final counts = _summary[b];
    final present = counts != null;
    final ticked = _ticked.contains(b);
    void toggle() => setState(() {
      if (!_ticked.remove(b)) _ticked.add(b);
    });
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: present ? toggle : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Checkbox(
              key: ValueKey('restore-preview-${b.name}'),
              value: present && ticked,
              activeColor: AppColors.accent,
              onChanged: present ? (_) => toggle() : null,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    restoreBundleLabel(b),
                    style: AppText.body.copyWith(
                      color: present
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                  ),
                  Text(
                    present
                        ? _countsLine(counts)
                        : context.l10n.notInThisBackup,
                    style: AppText.caption,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Small icon + text line under the list (warning / safety-copy note).
  Widget _note(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: AppColors.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: AppText.caption.copyWith(height: 1.4)),
        ),
      ],
    ),
  );
}

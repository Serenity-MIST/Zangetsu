import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/desktop/desktop_shortcut_labels.dart';
import '../../core/desktop/desktop_shortcuts.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/app_dialog.dart';
import '../../core/ui/desktop_settings_surface.dart';
import '../../core/ui/settings_widgets.dart';
import '../../l10n/l10n.dart';

/// Section title for each shortcut scope (Settings page and help overlay).
/// Uses appL10n (no context needed); it follows the app language.
String keyboardShortcutScopeLabel(DesktopShortcutScope scope) =>
    switch (scope) {
      DesktopShortcutScope.app => appL10n.shortcutScopeEverywhere,
      DesktopShortcutScope.home => appL10n.home,
      DesktopShortcutScope.showPage => appL10n.shortcutScopeShowPage,
      DesktopShortcutScope.player => appL10n.sectionPlayer,
      DesktopShortcutScope.reader => appL10n.reader,
      DesktopShortcutScope.downloads => appL10n.settingsSectionDownloads,
      DesktopShortcutScope.lists => appL10n.shortcutScopeLists,
      DesktopShortcutScope.settings => appL10n.settingsTitle,
    };

// Graphite dialog colours shared with showGraphiteSettingsChoice; getters
// (set-9) so they follow Pure black and custom backgrounds.
Color get _dialogFill => GraphiteSettingsColors.dialog;
Color get _dialogEdge => GraphiteSettingsColors.dialogEdge;

/// Settings page listing every Windows keyboard shortcut, grouped by where
/// it works, with a search box. Player actions can be remapped (Change /
/// Reset) and the whole table reset to defaults. Read from the same registry
/// the real key handlers use, so it never drifts from the app.
class KeyboardShortcutsScreen extends StatelessWidget {
  const KeyboardShortcutsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Reachable from the help overlay outside the settings workspace too;
    // provide the desktop scope so it always renders the graphite design.
    if (defaultTargetPlatform == TargetPlatform.windows &&
        !DesktopSettingsScope.contains(context)) {
      return const DesktopSettingsScope(child: _KeyboardShortcutsPage());
    }
    return const _KeyboardShortcutsPage();
  }
}

/// The page body; stateful only for the search query.
class _KeyboardShortcutsPage extends StatefulWidget {
  const _KeyboardShortcutsPage();

  @override
  State<_KeyboardShortcutsPage> createState() => _KeyboardShortcutsPageState();
}

class _KeyboardShortcutsPageState extends State<_KeyboardShortcutsPage> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // Matches the action name, its description, its keys or its section.
  bool _matches(DesktopShortcutSpec s) {
    if (_query.isEmpty) return true;
    // Translated name and description, plus the English ones so either matches.
    final l10n = context.l10n;
    final hay =
        '${desktopShortcutLabel(l10n, s)} ${desktopShortcutDescription(l10n, s) ?? ''} '
        '${s.label} ${s.description ?? ''} '
                '${DesktopShortcuts.describeAll(s.id)} '
                '${keyboardShortcutScopeLabel(s.scope)}'
            .toLowerCase();
    return hay.contains(_query);
  }

  Future<void> _resetAll() async {
    final ok = await AppDialog.confirm(
      context,
      title: context.l10n.resetAllShortcutsQuestion,
      message: context.l10n.resetAllShortcutsMessage,
      confirmLabel: context.l10n.resetAll,
      destructive: true,
    );
    if (ok) await DesktopShortcuts.resetAll();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: settingsPageBackground(context),
      appBar: settingsAppBar(
        context.l10n.keyboardShortcuts,
        actions: [
          // Only offered when there is something to reset.
          ListenableBuilder(
            listenable: DesktopShortcuts.changes,
            builder: (context, _) {
              final any = DesktopShortcuts.all.any(
                (s) => DesktopShortcuts.isOverridden(s.id),
              );
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: TextButton.icon(
                  onPressed: any ? _resetAll : null,
                  icon: const Icon(Icons.restart_alt_rounded, size: 18),
                  label: Text(context.l10n.resetAll),
                ),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListenableBuilder(
            listenable: DesktopShortcuts.changes,
            builder: (context, _) {
              final specs = DesktopShortcuts.all.where(_matches).toList();
              return ListView(
                padding: const EdgeInsets.only(top: 12, bottom: 28),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    child: _SearchField(
                      controller: _search,
                      onChanged: (v) =>
                          setState(() => _query = v.trim().toLowerCase()),
                    ),
                  ),
                  if (specs.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        context.l10n.noShortcutsMatch,
                        textAlign: TextAlign.center,
                        style: AppText.caption,
                      ),
                    ),
                  for (final scope in DesktopShortcutScope.values)
                    if (specs.any((s) => s.scope == scope)) ...[
                      SettingsSectionLabel(keyboardShortcutScopeLabel(scope)),
                      SettingsCard(
                        children: [
                          for (final s in specs.where((s) => s.scope == scope))
                            _ShortcutRow(spec: s),
                        ],
                      ),
                    ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Rounded graphite search box at the top of the page.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    onChanged: onChanged,
    style: AppText.body.copyWith(color: AppColors.textPrimary),
    decoration: InputDecoration(
      hintText: context.l10n.searchShortcuts,
      prefixIcon: const Icon(Icons.search_rounded, size: 20),
      filled: true,
      // set-9: lighter end of the themed panel gradient.
      fillColor: GraphiteSettingsColors.panelGradient.first,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: GraphiteSettingsColors.panelEdge,
        ), // set-9
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: GraphiteSettingsColors.panelEdge,
        ), // set-9
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: AppColors.accent),
      ),
    ),
  );
}

/// One action: its name, keys as chips and, for remappable actions,
/// Change and Reset buttons.
class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.spec});

  final DesktopShortcutSpec spec;

  @override
  Widget build(BuildContext context) {
    final changed = DesktopShortcuts.isOverridden(spec.id);
    return SettingsTile(
      icon: Icons.keyboard_alt_outlined,
      title: desktopShortcutLabel(context.l10n, spec),
      subtitle: [
        if (desktopShortcutDescription(context.l10n, spec) case final d?) d,
        if (changed) context.l10n.changedFromDefault,
      ].join(' · ').ifEmptyNull,
      onTap: spec.remappable
          ? () => showShortcutCaptureDialog(context, spec)
          : null,
      trailing: Wrap(
        spacing: 6,
        runSpacing: 6,
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          KeyboardShortcutKeys(id: spec.id),
          if (spec.remappable) ...[
            TextButton(
              onPressed: () => showShortcutCaptureDialog(context, spec),
              child: Text(context.l10n.change),
            ),
            if (changed)
              TextButton(
                onPressed: () => DesktopShortcuts.clearOverride(spec.id),
                child: Text(context.l10n.reset),
              ),
          ],
        ],
      ),
    );
  }
}

extension on String {
  // Empty subtitle should not render an empty line.
  String? get ifEmptyNull => isEmpty ? null : this;
}

/// The keys of one action drawn as small key caps, e.g. [Ctrl+F] [/].
class KeyboardShortcutKeys extends StatelessWidget {
  const KeyboardShortcutKeys({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    final keys = DesktopShortcuts.activatorsFor(id);
    // The ten digit keys read better as one '0-9' cap.
    final labels = keys.isEmpty
        ? [context.l10n.shortcutNotSet]
        : DesktopShortcuts.describeAll(id) == '0-9'
        ? ['0-9']
        : keys.map(DesktopShortcuts.describe).toList();
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [for (final l in labels) KeyCap(label: l)],
    );
  }
}

/// One key cap chip in the graphite style.
class KeyCap extends StatelessWidget {
  const KeyCap({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: const Color(0xFF24252D),
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: const Color(0xFF3A3B43)),
    ),
    child: Text(
      label,
      style: AppText.caption.copyWith(
        color: AppColors.textPrimary,
        fontWeight: FontWeight.w600,
        fontSize: 12,
      ),
    ),
  );
}

/// Key-capture dialog for remapping [spec]: press the new combination, see
/// a warning naming any action that already uses it, then Save or Cancel.
/// Esc cancels (it is never captured). Returns true when a key was saved.
Future<bool> showShortcutCaptureDialog(
  BuildContext context,
  DesktopShortcutSpec spec,
) async {
  final saved = await showDialog<bool>(
    context: context,
    useRootNavigator: false,
    builder: (_) => _CaptureDialog(spec: spec),
  );
  return saved ?? false;
}

class _CaptureDialog extends StatefulWidget {
  const _CaptureDialog({required this.spec});

  final DesktopShortcutSpec spec;

  @override
  State<_CaptureDialog> createState() => _CaptureDialogState();
}

class _CaptureDialogState extends State<_CaptureDialog> {
  SingleActivator? _captured;

  // Focus of the capture box. Kept so a click on the box takes keys back
  // after Tab has moved focus to the Cancel / Save buttons.
  final _captureFocus = FocusNode(debugLabel: 'shortcut-capture');

  @override
  void dispose() {
    _captureFocus.dispose();
    super.dispose();
  }

  // Pure modifier presses only update the hint; the combination is taken
  // when a non-modifier key goes down.
  static final _modifiers = {
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.capsLock,
  };

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    // Esc closes; Tab keeps moving focus to the buttons.
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop(false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) return KeyEventResult.ignored;
    if (_modifiers.contains(key)) return KeyEventResult.handled;
    final kb = HardwareKeyboard.instance;
    // A typed '?' is stored as Shift+/ so it matches the help binding.
    final activator = event.character == '?'
        ? const SingleActivator(LogicalKeyboardKey.slash, shift: true)
        : SingleActivator(
            key,
            control: kb.isControlPressed,
            shift: kb.isShiftPressed,
            alt: kb.isAltPressed,
            meta: kb.isMetaPressed,
          );
    setState(() => _captured = activator);
    return KeyEventResult.handled;
  }

  Future<void> _save() async {
    final a = _captured;
    if (a == null) return;
    await DesktopShortcuts.setOverride(widget.spec.id, [a]);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final a = _captured;
    final conflictId = a == null
        ? null
        : DesktopShortcuts.conflictWith(widget.spec.id, a);
    final conflict = conflictId == null
        ? null
        : DesktopShortcuts.spec(conflictId);
    return Dialog(
      backgroundColor: _dialogFill,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: _dialogEdge),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.changeShortcut,
                style: AppText.headline.copyWith(
                  fontSize: 22,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                desktopShortcutLabel(context.l10n, widget.spec),
                style: AppText.caption.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 18),
              // The capture surface owns focus so every key lands here.
              Focus(
                focusNode: _captureFocus,
                autofocus: true,
                onKeyEvent: _onKey,
                // Clicking the box gives it the keyboard again.
                child: GestureDetector(
                  onTap: _captureFocus.requestFocus,
                  child: Container(
                    key: const ValueKey('shortcut-capture-box'),
                    width: double.infinity,
                    height: 72,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      // set-9: darker end of the themed panel gradient.
                      color: GraphiteSettingsColors.panelGradient.last,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.accent),
                    ),
                    child: a == null
                        ? Text(
                            context.l10n.pressNewKeyCombination,
                            style: AppText.body.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          )
                        : KeyCap(label: DesktopShortcuts.describe(a)),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                context.l10n.currentShortcut(DesktopShortcuts.describeAll(widget.spec.id)),
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
              ),
              if (conflict != null) ...[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: Color(0xFFF0B232),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        // Names the other action so the user knows what
                        // they would be shadowing.
                        context.l10n.shortcutAlreadyUsedBy(desktopShortcutLabel(context.l10n, conflict), keyboardShortcutScopeLabel(conflict.scope)),
                        key: const ValueKey('shortcut-conflict'),
                        style: AppText.caption.copyWith(
                          color: const Color(0xFFF0B232),
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(context.l10n.cancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: a == null ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(context.l10n.save),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The '?' help overlay used by the player, reader and shell: a centred
/// graphite panel listing [scope]'s shortcuts first, then everything else.
/// Esc or the close button dismisses it; "Customise" opens the Settings page.
Future<void> showKeyboardShortcutsHelp(
  BuildContext context, {
  DesktopShortcutScope? scope,
}) {
  // The requested scope first, then app-wide keys, then the rest.
  final order = <DesktopShortcutScope>[
    ?scope,
    if (scope != DesktopShortcutScope.app) DesktopShortcutScope.app,
    for (final s in DesktopShortcutScope.values)
      if (s != scope && s != DesktopShortcutScope.app) s,
  ];
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final specs = DesktopShortcuts.all;
      return Dialog(
        key: const ValueKey('keyboard-shortcuts-help'),
        backgroundColor: _dialogFill,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: _dialogEdge),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.82,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 14, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.l10n.keyboardShortcuts,
                        style: AppText.headline.copyWith(
                          fontSize: 22,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.of(dialogContext).pop();
                        // The page that opened the overlay may have gone
                        // (e.g. the player closed); only push while alive.
                        if (!context.mounted) return;
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const KeyboardShortcutsScreen(),
                          ),
                        );
                      },
                      child: Text(context.l10n.customise),
                    ),
                    IconButton(
                      tooltip: MaterialLocalizations.of(
                        dialogContext,
                      ).closeButtonTooltip,
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close_rounded),
                      color: AppColors.textSecondary,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Divider(height: 1, color: _dialogEdge),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(top: 6, right: 8),
                    children: [
                      for (final s in order)
                        if (specs.any((x) => x.scope == s)) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 14, bottom: 6),
                            child: Text(
                              keyboardShortcutScopeLabel(s),
                              style: AppText.body.copyWith(
                                color: s == scope
                                    ? AppColors.accent
                                    : AppColors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          for (final spec in specs.where((x) => x.scope == s))
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      desktopShortcutLabel(context.l10n, spec),
                                      style: AppText.caption.copyWith(
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                  ),
                                  KeyboardShortcutKeys(id: spec.id),
                                ],
                              ),
                            ),
                        ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

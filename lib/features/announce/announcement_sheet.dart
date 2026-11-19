import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/announce/announcement.dart';
import '../../core/announce/announcement_service.dart';
import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_settings_surface.dart' show GraphiteSettingsColors;
import '../../core/tv/tv_list_focusable.dart';
import '../../l10n/l10n.dart';

/// Fetch the announcements feed and, if something new arrived, pop the newest
/// one as a bottom sheet over the running UI. [context] must be a live widget
/// context under the app Navigator (call it from a home screen's post-frame).
/// Marks every freshly-arrived announcement as seen afterwards (they remain in
/// the Notifications history), so nothing re-pops on the next launch.
/// Fire-and-forget; never throws in normal use.
Future<void> maybeShowAnnouncement(BuildContext context) async {
  final fresh = await sl<AnnouncementService>().check();
  if (fresh.isEmpty) return;
  if (context.mounted) {
    await showAnnouncementSheet(context, fresh.first);
  }
  final store = sl<AnnouncementStore>();
  for (final a in fresh) {
    await store.markSeen(a.id);
  }
}

/// Show a single announcement as a modal bottom sheet.
Future<void> showAnnouncementSheet(BuildContext context, Announcement a) {
  // Windows: a centred graphite dialog (Esc / click outside / X close it)
  // instead of a phone bottom sheet. Same content and actions.
  if (defaultTargetPlatform == TargetPlatform.windows) {
    return showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (_) => _AnnouncementSheet(a: a, desktop: true),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    useRootNavigator: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _AnnouncementSheet(a: a),
  );
}

/// Graphite dialog surface and edge on Windows (matches the desktop settings
/// dialogs and the media info dialog).
// A getter (set-9) so it follows Pure black and custom backgrounds.
Color get _kDesktopSurface => GraphiteSettingsColors.dialog;
Color get _kDesktopEdge => GraphiteSettingsColors.dialogEdge;

class _AnnouncementSheet extends StatelessWidget {
  const _AnnouncementSheet({required this.a, this.desktop = false});

  final Announcement a;

  /// Windows dialog presentation: no grab handle, a header close button and
  /// desktop-shaped buttons.
  final bool desktop;

  (IconData, Color) get _badge => switch (a.type) {
    'warning' => (Icons.warning_amber_rounded, const Color(0xFFF2B01E)),
    'update' => (Icons.system_update_rounded, AppColors.accent),
    _ => (Icons.campaign_rounded, AppColors.accent),
  };

  Future<void> _openAction() async {
    final url = a.actionUrl;
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final (icon, tint) = _badge;
    if (desktop) return _desktopDialog(context, icon, tint);
    final isTv = sl<AppMode>().isTv;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        // Cap the height so a long message scrolls instead of overflowing —
        // important on TV (short landscape) where the body can be many lines.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Grab handle.
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: AppColors.hairline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Header + body scroll together; the buttons stay pinned below.
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(9),
                            decoration: BoxDecoration(
                              color: tint.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(icon, color: tint, size: 24),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  a.title,
                                  style: AppText.headline.copyWith(
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (a.date != null && a.date!.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(a.date!, style: AppText.caption),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (a.imageUrl != null && a.imageUrl!.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            a.imageUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          ),
                        ),
                      ],
                      if (a.body.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          a.body,
                          style: AppText.body.copyWith(
                            color: AppColors.textSecondary,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (a.actionLabel != null && a.actionUrl != null) ...[
                    _sheetButton(
                      context,
                      label: a.actionLabel!,
                      filled: false,
                      autofocus: false,
                      isTv: isTv,
                      onTap: () {
                        Navigator.of(context).pop();
                        _openAction();
                      },
                    ),
                    const SizedBox(width: 12),
                  ],
                  _sheetButton(
                    context,
                    label: context.l10n.gotIt,
                    filled: true,
                    // On TV give the primary button initial focus so OK dismisses.
                    autofocus: isTv,
                    isTv: isTv,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Windows: bounded centred card. Header (badge, title, date, close) stays
  /// fixed, image + body scroll, and the same action buttons sit at the end.
  Widget _desktopDialog(BuildContext context, IconData icon, Color tint) {
    final h = MediaQuery.sizeOf(context).height;
    final hasImage = a.imageUrl != null && a.imageUrl!.isNotEmpty;
    return Dialog(
      backgroundColor: _kDesktopSurface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(32),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: _kDesktopEdge),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: h * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 14, 14),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: tint, size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          a.title,
                          style: AppText.headline.copyWith(
                            fontSize: 20,
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (a.date != null && a.date!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(a.date!, style: AppText.caption),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                    color: AppColors.textSecondary,
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: _kDesktopEdge),
            if (hasImage || a.body.isNotEmpty)
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 18, 24, 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (hasImage) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            a.imageUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          ),
                        ),
                        if (a.body.isNotEmpty) const SizedBox(height: 16),
                      ],
                      if (a.body.isNotEmpty)
                        SelectableText(
                          a.body,
                          style: AppText.body.copyWith(
                            color: AppColors.textSecondary,
                            height: 1.45,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (a.actionLabel != null && a.actionUrl != null) ...[
                    _sheetButton(
                      context,
                      label: a.actionLabel!,
                      filled: false,
                      autofocus: false,
                      isTv: false,
                      onTap: () {
                        Navigator.of(context).pop();
                        _openAction();
                      },
                    ),
                    const SizedBox(width: 10),
                  ],
                  _sheetButton(
                    context,
                    label: context.l10n.gotIt,
                    filled: true,
                    // Enter acknowledges, matching a desktop default button.
                    autofocus: true,
                    isTv: false,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sheetButton(
    BuildContext context, {
    required String label,
    required bool filled,
    required bool autofocus,
    required bool isTv,
    required VoidCallback onTap,
  }) {
    // Windows: settings-style 10px corners instead of phone stadium pills.
    final desktopShape = desktop
        ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))
        : null;
    final button = filled
        ? FilledButton(
            autofocus: desktop && autofocus,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              shape: desktopShape,
            ),
            onPressed: onTap,
            child: Text(label),
          )
        : OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.textPrimary,
              side: BorderSide(
                color: desktop ? _kDesktopEdge : AppColors.hairline,
              ),
              shape: desktopShape,
            ),
            onPressed: onTap,
            child: Text(label),
          );
    if (!isTv) return button;
    // On TV the D-pad drives focus; TvFocusable handles OK-key activation.
    return TvListFocusable(autofocus: autofocus, onTap: onTap, child: button);
  }
}

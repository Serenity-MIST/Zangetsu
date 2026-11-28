import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_config.dart';
import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_alert_dialog.dart' show TvFocusClaim;
import '../../core/ui/desktop_settings_surface.dart' show GraphiteSettingsColors;
import '../../core/tv/tv_list_focusable.dart';

const _telegramUrl = 'https://t.me/ZangetsuStream';
const _discordUrl = kDiscordInviteUrl;
const _flagsBox = 'app_flags';
const _seenKey = 'communitySheetSeen';

/// One-time "join the community" bottom sheet, shown once per install (new and
/// existing users) on launch, then never again. Gated by its OWN Hive flag —
/// independent of the per-id announcement system, so future announcements still
/// show. Fire-and-forget; never throws (a welcome must not block startup).
Future<void> maybeShowCommunitySheet(BuildContext context) async {
  try {
    final box = Hive.isBoxOpen(_flagsBox)
        ? Hive.box(_flagsBox)
        : await openBoxSafely(_flagsBox);
    if (box.get(_seenKey) == true) return;
    if (!context.mounted) return;
    await showCommunitySheet(context);
    // Mark seen after it's shown; if the app is killed mid-sheet it may show
    // once more next launch — acceptable, and safer than never showing it.
    await box.put(_seenKey, true);
  } catch (_) {
    // Never break launch on the welcome sheet.
  }
}

/// Show the community sheet directly (bypasses the seen-flag) — e.g. a future
/// "Community" entry in Settings could reuse this.
Future<void> showCommunitySheet(BuildContext context) {
  // Windows: a centred graphite dialog (Esc / click outside / X close it)
  // instead of a phone bottom sheet. Same content and links.
  if (defaultTargetPlatform == TargetPlatform.windows) {
    return showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (_) => const _CommunitySheet(desktop: true),
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
    builder: (_) => const _CommunitySheet(),
  );
}

/// Graphite dialog surface and edge on Windows (matches the desktop settings
/// dialogs and the media info dialog).
// A getter (set-9) so it follows Pure black and custom backgrounds.
Color get _kDesktopSurface => GraphiteSettingsColors.dialog;
Color get _kDesktopEdge => GraphiteSettingsColors.dialogEdge;

class _CommunitySheet extends StatefulWidget {
  const _CommunitySheet({this.desktop = false});

  /// Windows dialog presentation: no grab handle, a close button and
  /// desktop-sized buttons.
  final bool desktop;

  @override
  State<_CommunitySheet> createState() => _CommunitySheetState();
}

class _CommunitySheetState extends State<_CommunitySheet> {
  final FocusNode _firstNode = FocusNode(debugLabel: 'community-telegram');

  /// Windows dialog presentation; see [_CommunitySheet.desktop].
  bool get desktop => widget.desktop;

  @override
  void dispose() {
    _firstNode.dispose();
    super.dispose();
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // A missing browser/app shouldn't crash — silently ignore.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (desktop) return _desktopDialog(context);
    final isTv = sl<AppMode>().isTv;
    final sheet = SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.groups_rounded,
                    color: AppColors.accent,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'Join the Zangetsu community',
                    style: AppText.headline.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Updates, requests, and help — come say hi.',
              style: AppText.body.copyWith(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 22),
            _linkButton(
              context,
              icon: Icons.send_rounded,
              label: 'Telegram  ·  @ZangetsuStream',
              color: const Color(0xFF229ED9),
              url: _telegramUrl,
              autofocus: isTv, // first button gets D-pad focus on TV
              isTv: isTv,
            ),
            const SizedBox(height: 12),
            _linkButton(
              context,
              icon: Icons.forum_rounded,
              label: 'Discord',
              color: const Color(0xFF5865F2),
              url: _discordUrl,
              autofocus: false,
              isTv: isTv,
            ),
            const SizedBox(height: 6),
            Center(child: _laterButton(context, isTv: isTv)),
          ],
        ),
      ),
    );
    if (!isTv) return sheet;
    // Home behind the sheet can mount autofocused rows late; keep the D-pad
    // here so "Maybe later" stays reachable.
    return TvFocusClaim(targets: [_firstNode], child: sheet);
  }

  /// Windows: bounded centred card with a header close button. The links and
  /// "Maybe later" behave exactly as on phone.
  Widget _desktopDialog(BuildContext context) {
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
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 14, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.groups_rounded,
                      color: AppColors.accent,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Join the Zangetsu community',
                      style: AppText.headline.copyWith(
                        fontSize: 20,
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
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
              // Body keeps clear of the close button's extra right inset.
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 12),
                    Text(
                      'Updates, requests, and help — come say hi.',
                      style: AppText.body.copyWith(
                        color: AppColors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Divider(height: 1, color: _kDesktopEdge),
                    const SizedBox(height: 18),
                    _linkButton(
                      context,
                      icon: Icons.send_rounded,
                      label: 'Telegram  ·  @ZangetsuStream',
                      color: const Color(0xFF229ED9),
                      url: _telegramUrl,
                      autofocus: false,
                      isTv: false,
                      desktop: true,
                    ),
                    const SizedBox(height: 10),
                    _linkButton(
                      context,
                      icon: Icons.forum_rounded,
                      label: 'Discord',
                      color: const Color(0xFF5865F2),
                      url: _discordUrl,
                      autofocus: false,
                      isTv: false,
                      desktop: true,
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: _laterButton(context, isTv: false),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _linkButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required String url,
    required bool autofocus,
    required bool isTv,
    bool desktop = false,
  }) {
    void go() {
      Navigator.of(context).pop();
      _open(url);
    }

    final button = FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        // Windows: desktop-height button with the settings corner radius.
        minimumSize: Size.fromHeight(desktop ? 44 : 50),
        alignment: AlignmentDirectional.centerStart,
        shape: desktop
            ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))
            : null,
      ),
      onPressed: go,
      icon: Icon(icon),
      label: Text(label),
    );
    if (!isTv) return button;
    // On TV the D-pad drives focus; TvFocusable handles OK-key activation.
    // ExcludeFocus: one D-pad stop per button, always the one with the ring.
    return TvListFocusable(
      autofocus: autofocus,
      focusNode: autofocus ? _firstNode : null,
      onTap: go,
      child: ExcludeFocus(child: button),
    );
  }

  Widget _laterButton(BuildContext context, {required bool isTv}) {
    void dismiss() => Navigator.of(context).pop();
    final button = TextButton(
      onPressed: dismiss,
      child: Text(
        'Maybe later',
        style: AppText.body.copyWith(color: AppColors.textTertiary),
      ),
    );
    if (!isTv) return button;
    return TvListFocusable(onTap: dismiss, child: ExcludeFocus(child: button));
  }
}

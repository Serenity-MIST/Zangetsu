import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../playback/subtitle_language.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../desktop/desktop_chrome_colors.dart';
import 'desktop_settings_surface.dart';

/// Bottom sheet to pick the global subtitle preference. Returns '' (Auto),
/// 'off', a language iso1, or null when dismissed. Used by Settings and the
/// in-player Audio & Subs panel.
///
/// Windows opens a searchable graphite dialog instead (see
/// [_showDesktopSubtitleLanguagePicker]); the result contract is the same.
Future<String?> showSubtitleLanguagePicker(
  BuildContext context,
  String current, {
  ValueChanged<ModalRoute<dynamic>?>? onRoute,
}) {
  if (defaultTargetPlatform == TargetPlatform.windows) {
    return _showDesktopSubtitleLanguagePicker(
      context,
      current,
      onRoute: onRoute,
    );
  }
  Widget row(String label, String value) => ListTile(
    onTap: () => Navigator.pop(context, value),
    title: Text(
      label,
      style: AppText.body.copyWith(color: AppColors.textPrimary),
    ),
    trailing: current == value
        ? Icon(Icons.check, color: AppColors.accent)
        : null,
  );
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.6,
    ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      onRoute?.call(ModalRoute.of(ctx));
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textTertiary.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text('Subtitle language', style: AppText.headline),
              ),
            ),
            const Divider(color: AppColors.hairline, height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  row('Auto', ''),
                  row('Off', 'off'),
                  for (final lang in kSubtitleLanguages)
                    row(lang.name, lang.iso1),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

/// Windows: centred graphite dialog (same surface as the other desktop
/// settings pickers) with a filter field, since the language list is long
/// and a PC has a keyboard. Auto and Off stay pinned above the filter
/// results. [onRoute] receives the dialog's route, like the bottom sheet's.
Future<String?> _showDesktopSubtitleLanguagePicker(
  BuildContext context,
  String current, {
  ValueChanged<ModalRoute<dynamic>?>? onRoute,
}) {
  final options = <(String, String)>[
    ('', 'Auto'),
    ('off', 'Off'),
    for (final lang in kSubtitleLanguages) (lang.iso1, lang.name),
  ];
  var query = '';
  return showDialog<String>(
    context: context,
    useRootNavigator: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, update) {
        onRoute?.call(ModalRoute.of(dialogContext));
        final q = query.trim().toLowerCase();
        final shown = [
          for (final o in options)
            if (q.isEmpty ||
                o.$1.isEmpty ||
                o.$1 == 'off' ||
                o.$2.toLowerCase().contains(q) ||
                o.$1.toLowerCase() == q)
              o,
        ];
        return Dialog(
          key: const ValueKey('subtitle-language-desktop-dialog'),
          // set-9: themed graphite colours (stock greys by default).
          backgroundColor: GraphiteSettingsColors.dialog,
          surfaceTintColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: GraphiteSettingsColors.dialogEdge),
          ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 520,
              maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.8,
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Subtitle language',
                          style: AppText.headline.copyWith(
                            fontSize: 22,
                            color: AppColors.textPrimary,
                          ),
                        ),
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
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('subtitle-language-filter'),
                    autofocus: true,
                    onChanged: (v) => update(() => query = v),
                    style: AppText.body.copyWith(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Filter languages',
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      filled: true,
                      fillColor: DesktopChrome
                          .frame, // set-9: themed frame (stock 0xFF101114)
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: GraphiteSettingsColors.dialogEdge,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: GraphiteSettingsColors.dialogEdge,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Divider(height: 1, color: GraphiteSettingsColors.dialogEdge),
                  const SizedBox(height: 8),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final (value, label) in shown)
                          Semantics(
                            checked: value == current,
                            inMutuallyExclusiveGroup: true,
                            child: GraphiteSettingsControl(
                              icon: value == current
                                  ? Icons.radio_button_checked_rounded
                                  : Icons.radio_button_unchecked_rounded,
                              title: label,
                              onTap: () =>
                                  Navigator.of(dialogContext).pop(value),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

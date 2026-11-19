import 'package:flutter/material.dart';

import '../../core/i18n/source_languages.dart';
import '../../core/prefs/source_lang_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../core/ui/desktop_docked_panel.dart';
import '../../core/ui/desktop_settings_surface.dart';
import '../../l10n/l10n.dart';

/// Multi-select language picker for the Mihon/Aniyomi catalogs. One row per
/// filterable language; toggling writes straight through to [prefs] so the
/// lists that listen to it re-filter live.
///
/// [present] is the set of language codes your installed sources actually use.
/// It is merged into the built-in list, because the built-in list cannot be
/// finished: 41 codes in the real Mihon catalogue are missing from it (`tl`,
/// `gl`, `mo`, `other`…), and a language with no row here is a language
/// [sourceLangVisible] refuses to filter — which is exactly why MangaDot kept
/// listing Moldovan and Guarani after you'd chosen English.
Future<void> showSourceLanguageSheet(
  BuildContext context,
  LangPrefs prefs, {
  Set<String> present = const {},
}) {
  final codes = _codesFor(present);
  // Windows: a centred graphite dialog like the app's desktop settings
  // pickers, not a phone bottom sheet (src-7 A).
  if (desktopPanelsEnabled) {
    return showDialog<void>(
      context: context,
      builder: (_) => _DesktopLanguageDialog(prefs: prefs, codes: codes),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setSheet) {
            final enabled = prefs.enabled ?? defaultSourceLangs();
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
                  child: Row(
                    children: [
                      Text(context.l10n.languages, style: AppText.headline),
                      const Spacer(),
                      Text(
                        '${enabled.where(kSourceLanguages.containsKey).length} of ${codes.length}',
                        style: AppText.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final code in codes)
                        CheckboxListTile(
                          value: enabled.contains(code),
                          onChanged: (v) {
                            final next = {...enabled};
                            if (v ?? false) {
                              next.add(code);
                            } else {
                              next.remove(code);
                            }
                            prefs.setEnabled(next);
                            setSheet(() {});
                          },
                          activeColor: AppColors.accent,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(sourceLangLabel(code)),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      );
    },
  );
}

/// D-pad-navigable variant of [showSourceLanguageSheet] for the Aniyomi TV
/// screen — each language is a [TvFocusable] row with an accent highlight and a
/// checkbox that flips on OK.
Future<void> showSourceLanguageSheetTv(
  BuildContext context,
  LangPrefs prefs, {
  Set<String> present = const {},
}) {
  final codes = _codesFor(present);
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.7),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setSheet) {
          final enabled = prefs.enabled ?? defaultSourceLangs();
          return Center(
            child: Container(
              width: 460,
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(ctx).height * 0.82,
              ),
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
                    child: Text(
                      context.l10n.languages,
                      style: AppText.headline,
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        for (var i = 0; i < codes.length; i++)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 3,
                              horizontal: 4,
                            ),
                            child: TvListFocusable(
                              autofocus: i == 0,
                              semanticLabel: sourceLangLabel(codes[i]),
                              onTap: () {
                                final next = {...enabled};
                                if (next.contains(codes[i])) {
                                  next.remove(codes[i]);
                                } else {
                                  next.add(codes[i]);
                                }
                                prefs.setEnabled(next);
                                setSheet(() {});
                              },
                              builder: (focused) {
                                final on = enabled.contains(codes[i]);
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.surface2,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        on
                                            ? Icons.check_box_rounded
                                            : Icons
                                                  .check_box_outline_blank_rounded,
                                        color: on
                                            ? AppColors.accent
                                            : AppColors.textSecondary,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: ExcludeSemantics(
                                          child: Text(
                                            sourceLangLabel(codes[i]),
                                            style: AppText.body,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

/// The built-in list plus anything your sources actually use, English first.
/// An unknown code has no friendly name, so [sourceLangLabel] shows the code
/// itself — better than the language being unfilterable.
List<String> _codesFor(Set<String> present) {
  final known = sortedSourceLangCodes();
  final extra = present.where((c) => !kSourceLanguages.containsKey(c)).toList()
    ..sort();
  return [...known, ...extra];
}

/// Windows language picker (src-7 A): the graphite dialog of the desktop
/// settings with a search box. Each tick writes straight through to [prefs]
/// like the phone sheet, so the lists behind re-filter live. Esc closes.
class _DesktopLanguageDialog extends StatefulWidget {
  const _DesktopLanguageDialog({required this.prefs, required this.codes});

  final LangPrefs prefs;
  final List<String> codes;

  @override
  State<_DesktopLanguageDialog> createState() => _DesktopLanguageDialogState();
}

class _DesktopLanguageDialogState extends State<_DesktopLanguageDialog> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toggle(String code, Set<String> enabled) {
    final next = {...enabled};
    if (!next.remove(code)) next.add(code);
    widget.prefs.setEnabled(next);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.prefs.enabled ?? defaultSourceLangs();
    final q = _search.text.trim().toLowerCase();
    final shown = [
      for (final code in widget.codes)
        if (q.isEmpty ||
            code.toLowerCase().contains(q) ||
            sourceLangLabel(code).toLowerCase().contains(q))
          code,
    ];
    return DesktopEscCloses(
      child: Dialog(
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
            maxWidth: 520,
            maxHeight: MediaQuery.sizeOf(context).height * .8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DesktopPanelTitleBar(
                title: context.l10n.languages,
                subtitle:
                    '${enabled.where(kSourceLanguages.containsKey).length} of '
                    '${widget.codes.length}',
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: TextField(
                  controller: _search,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  style: AppText.body,
                  decoration: InputDecoration(
                    hintText: context.l10n.mangaTranslationSearchLanguages,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    filled: true,
                    fillColor: AppColors.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              Divider(height: 1, color: DesktopPanelColors.edge),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  children: [
                    for (final code in shown)
                      GraphiteSettingsControl(
                        key: ValueKey('desktop-lang-$code'),
                        icon: enabled.contains(code)
                            ? Icons.check_box_outlined
                            : Icons.check_box_outline_blank,
                        title: sourceLangLabel(code),
                        onTap: () => _toggle(code, enabled),
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
}

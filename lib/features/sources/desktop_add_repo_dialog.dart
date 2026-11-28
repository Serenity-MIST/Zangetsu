// Windows 'Add repository' dialog for the Sources manager: one URL field for
// every ecosystem, with the ecosystem auto-detected (or picked by hand).
//
// Detection is two-step: URL heuristics first (pure, unit tested), then one
// GET of the link and a look at its JSON keys. When neither is sure the user
// picks from the list. The actual add goes through
// DesktopSourceActions.addRepo, i.e. each ecosystem's existing add path.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/desktop/desktop_reveal.dart';
import '../../core/desktop/extension_runtime.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_docked_panel.dart';
import '../../l10n/l10n.dart';
import 'aniyomi_repo_tab.dart' show AniyomiAddRepoDialog;
import 'desktop_sources_actions.dart';
import 'desktop_sources_model.dart';
import 'lnreader_sources_screen.dart' show LnReaderAddRepoDialog;
import 'mihon_repo_tab.dart' show MihonAddRepoDialog;
import 'sources_desktop_kit.dart' show DesktopAddRepoAssist;

// ---------------------------------------------------------------------------
// Detection (pure)
// ---------------------------------------------------------------------------

/// Guesses the ecosystem of a repository link from the URL alone, or null
/// when the URL does not say. Only returns an answer when the file name or
/// path is specific to one ecosystem.
DesktopEcosystem? detectRepoEcosystemFromUrl(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return null;
  if (raw.toLowerCase().startsWith('stremio://')) {
    return DesktopEcosystem.stremio;
  }
  final uri = Uri.tryParse(raw);
  final path = (uri?.path ?? raw).toLowerCase();
  final whole = raw.toLowerCase();
  final file = path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '';
  if (file == 'manifest.json') return DesktopEcosystem.stremio;
  if (file == 'plugins.min.json' || whole.contains('lnreader')) {
    return DesktopEcosystem.lnreader;
  }
  if (file == 'anime_index.json' ||
      file == 'manga_index.json' ||
      file == 'novel_index.json' ||
      whole.contains('mangayomi')) {
    return DesktopEcosystem.mangayomi;
  }
  if (file == 'index.min.json' || file == 'index.json') {
    // Tachiyomi-style index: the same shape for Aniyomi and Mihon, so only
    // a telling name decides. Otherwise the JSON peek looks at the pkgs.
    if (whole.contains('aniyomi') || whole.contains('anime')) {
      return DesktopEcosystem.aniyomi;
    }
    if (whole.contains('mihon') ||
        whole.contains('keiyoushi') ||
        whole.contains('tachiyomi')) {
      return DesktopEcosystem.mihon;
    }
    return null;
  }
  if (file == 'repo.json' || whole.contains('cloudstream')) {
    return DesktopEcosystem.cloudstream;
  }
  return null;
}

/// Guesses the ecosystem from a repository's decoded JSON body, or null.
DesktopEcosystem? detectRepoEcosystemFromJson(Object? json) {
  if (json is Map) {
    if (json.containsKey('pluginLists')) return DesktopEcosystem.cloudstream;
    // A Stremio add-on manifest describes its resources and catalogues.
    if (json.containsKey('resources') &&
        (json.containsKey('catalogs') || json.containsKey('types'))) {
      return DesktopEcosystem.stremio;
    }
    final sources = json['sources'];
    if (sources is List &&
        sources.whereType<Map>().any(
          (s) => s.containsKey('file') || s.containsKey('type'),
        )) {
      return DesktopEcosystem.zangetsu;
    }
    return null;
  }
  if (json is List) {
    final items = json.whereType<Map>().take(20).toList();
    if (items.isEmpty) return null;
    // Tachiyomi-style index: Aniyomi packages carry '.animeextension.'.
    final pkgs = [
      for (final m in items)
        if (m['pkg'] is String) m['pkg'] as String,
    ];
    if (pkgs.isNotEmpty) {
      if (pkgs.any((p) => p.contains('.animeextension.'))) {
        return DesktopEcosystem.aniyomi;
      }
      if (pkgs.any((p) => p.contains('.extension.'))) {
        return DesktopEcosystem.mihon;
      }
      return null;
    }
    bool every(bool Function(Map m) test) => items.every(test);
    if (every((m) => m.containsKey('internalName'))) {
      return DesktopEcosystem.cloudstream;
    }
    if (every(
      (m) => m.containsKey('itemType') || m.containsKey('sourceCodeLanguage'),
    )) {
      return DesktopEcosystem.mangayomi;
    }
    if (every((m) => m.containsKey('site') && m.containsKey('url'))) {
      return DesktopEcosystem.lnreader;
    }
  }
  return null;
}

/// Downloads [url] and decodes it as JSON. Used by the dialog's second
/// detection step; any failure returns null (the user then picks).
Future<Object?> _fetchRepoJson(String url) async {
  try {
    final dio = sl.isRegistered<Dio>() ? sl<Dio>() : Dio();
    final res = await dio
        .get<String>(
          url.trim().replaceFirst(RegExp('^stremio://'), 'https://'),
          options: Options(responseType: ResponseType.plain),
        )
        .timeout(const Duration(seconds: 12));
    final body = res.data;
    return body == null ? null : jsonDecode(body);
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Dialog
// ---------------------------------------------------------------------------

/// Shows the add-repository dialog and reports the result in a SnackBar.
/// Returns true when something was added.
Future<bool> showDesktopAddRepoDialog(
  BuildContext context, {
  DesktopEcosystem? initialEcosystem,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final message = await showDialog<String>(
    context: context,
    builder: (_) => DesktopAddRepoDialog(initialEcosystem: initialEcosystem),
  );
  if (message == null) return false;
  if (messenger != null && messenger.mounted) {
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
  return true;
}

/// Graphite dialog: URL field (clipboard pre-fill and drop via
/// [DesktopAddRepoAssist]) plus an ecosystem dropdown with 'Auto-detect'.
/// Pops with the success message, or null when cancelled.
class DesktopAddRepoDialog extends StatefulWidget {
  const DesktopAddRepoDialog({
    super.key,
    this.initialEcosystem,
    this.fetchJson,
    this.addRepo,
  });

  /// Pre-selected ecosystem (null = Auto-detect).
  final DesktopEcosystem? initialEcosystem;

  /// Test seam for the JSON peek (defaults to one GET of the link).
  final Future<Object?> Function(String url)? fetchJson;

  /// Test seam for the add (defaults to [DesktopSourceActions.addRepo]).
  final Future<String> Function(DesktopEcosystem eco, String url)? addRepo;

  @override
  State<DesktopAddRepoDialog> createState() => _DesktopAddRepoDialogState();
}

class _DesktopAddRepoDialogState extends State<DesktopAddRepoDialog> {
  final _url = TextEditingController();

  /// The user's pick; null = Auto-detect.
  late DesktopEcosystem? _picked = widget.initialEcosystem;

  /// Inline error under the form.
  String? _error;

  /// True while detecting / adding.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Re-run the URL guess as the user types or a link is pre-filled.
    _url.addListener(_onUrlChanged);
  }

  void _onUrlChanged() {
    if (mounted) setState(() => _error = null);
  }

  @override
  void dispose() {
    _url.removeListener(_onUrlChanged);
    _url.dispose();
    super.dispose();
  }

  /// The ecosystem that will be used right now without a network peek.
  DesktopEcosystem? get _guess =>
      _picked ?? detectRepoEcosystemFromUrl(_url.text);

  /// Detect (if needed), then add through the ecosystem's own path.
  Future<void> _submit() async {
    final url = _url.text.trim();
    if (url.isEmpty || _busy) {
      if (url.isEmpty) setState(() => _error = 'Paste a repository link first');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    var eco = _guess;
    if (eco == null) {
      final json = await (widget.fetchJson ?? _fetchRepoJson)(url);
      eco = detectRepoEcosystemFromJson(json);
    }
    if (!mounted) return;
    if (eco == null) {
      setState(() {
        _busy = false;
        _error =
            "Couldn't tell which kind of repository this is. "
            'Pick its ecosystem from the list.';
      });
      return;
    }
    try {
      final add = widget.addRepo ?? DesktopSourceActions.addRepo;
      final message = await add(eco, url);
      if (mounted) Navigator.of(context).pop(message);
    } catch (e) {
      if (!mounted) return;
      final text = '$e'.replaceFirst(
        RegExp(r'^(Bad state|FormatException|Exception): '),
        '',
      );
      setState(() {
        _busy = false;
        _error = 'Could not add the ${eco!.label} repository: $text';
      });
    }
  }

  /// 'More options…': the ecosystem's own add dialog (which keeps its
  /// recommended-repo list), or its manager when it has no public dialog.
  Future<void> _moreOptions() async {
    final eco = _guess;
    final nav = Navigator.of(context);
    if (eco == null) {
      setState(() => _error = 'Pick an ecosystem first to see its options.');
      return;
    }
    final Widget? own = switch (eco) {
      DesktopEcosystem.aniyomi => AniyomiAddRepoDialog(
        alreadyAddedUrls: DesktopSourceActions.addedRepoUrls(eco),
      ),
      DesktopEcosystem.mihon => MihonAddRepoDialog(
        alreadyAddedUrls: DesktopSourceActions.addedRepoUrls(eco),
      ),
      DesktopEcosystem.lnreader => const LnReaderAddRepoDialog(),
      _ => null,
    };
    if (own == null) {
      // Zangetsu (recommended repos, rename), CloudStream, Mangayomi
      // (repository types) and Stremio keep their extras in their manager.
      nav.pop();
      unawaited(DesktopSourceActions.openEcosystemManager(nav.context, eco));
      return;
    }
    final url = await showDialog<String>(context: context, builder: (_) => own);
    if (url == null || url.isEmpty || !mounted) return;
    _url.text = url;
    setState(() => _picked = eco);
    await _submit();
  }

  @override
  Widget build(BuildContext context) {
    final guess = _guess;
    final engineNote =
        (guess == DesktopEcosystem.aniyomi ||
            guess == DesktopEcosystem.mihon) &&
        DesktopExtensionRuntime.engineMissing;
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
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DesktopPanelTitleBar(
                title: context.l10n.addRepository,
                // Translated subtitle under the title.
                subtitle: context.l10n.desktopAddRepoSubtitle,
              ),
              Divider(height: 1, color: DesktopPanelColors.edge),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DesktopAddRepoAssist(
                      controller: _url,
                      child: TextField(
                        key: const ValueKey('desktop-add-repo-url'),
                        controller: _url,
                        autofocus: true,
                        enabled: !_busy,
                        style: AppText.body.copyWith(
                          color: AppColors.textPrimary,
                        ),
                        cursorColor: AppColors.accent,
                        decoration: InputDecoration(
                          // Field label and hint come from the translations.
                          labelText: context.l10n.desktopRepoLinkLabel,
                          hintText: context.l10n.desktopRepoLinkHint,
                          filled: true,
                          fillColor: AppColors.surface2,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onSubmitted: (_) => unawaited(_submit()),
                      ),
                    ),
                    const SizedBox(height: 14),
                    // Keyed by the pick: the form field reads its value only
                    // once, so a pick made elsewhere ('More options…') must
                    // rebuild it to show the chosen ecosystem.
                    KeyedSubtree(
                      key: ValueKey('desktop-add-repo-eco-${_picked?.name}'),
                      child: _EcosystemDropdown(
                        value: _picked,
                        detected: _picked == null
                            ? detectRepoEcosystemFromUrl(_url.text)
                            : null,
                        enabled: !_busy,
                        onChanged: (v) => setState(() {
                          _picked = v;
                          _error = null;
                        }),
                      ),
                    ),
                    if (engineNote) ...[
                      const SizedBox(height: 12),
                      const DesktopEngineMissingNotice(compact: true),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        key: const ValueKey('desktop-add-repo-error'),
                        style: AppText.caption.copyWith(
                          color: AppColors.accent,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 16, 14),
                child: Row(
                  children: [
                    TextButton(
                      key: const ValueKey('desktop-add-repo-more'),
                      onPressed: _busy ? null : () => unawaited(_moreOptions()),
                      // Translated; no longer const since it reads context.
                      child: Text(context.l10n.desktopMoreOptions),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: Text(context.l10n.cancel),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const ValueKey('desktop-add-repo-submit'),
                      onPressed: _busy ? null : () => unawaited(_submit()),
                      child: _busy
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(context.l10n.add),
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

/// 'Ecosystem' dropdown: Auto-detect plus every ecosystem. While on
/// Auto-detect it names what the link looks like, so the user can see the
/// guess before adding.
class _EcosystemDropdown extends StatelessWidget {
  const _EcosystemDropdown({
    required this.value,
    required this.detected,
    required this.enabled,
    required this.onChanged,
  });

  final DesktopEcosystem? value;
  final DesktopEcosystem? detected;
  final bool enabled;
  final ValueChanged<DesktopEcosystem?> onChanged;

  @override
  Widget build(BuildContext context) {
    final auto = detected == null
        ? 'Auto-detect'
        : 'Auto-detect (looks like ${detected!.label})';
    return DropdownButtonFormField<DesktopEcosystem?>(
      key: const ValueKey('desktop-add-repo-ecosystem'),
      initialValue: value,
      isExpanded: true,
      dropdownColor: DesktopPanelColors.surface,
      borderRadius: BorderRadius.circular(12),
      decoration: InputDecoration(
        // Translated field label.
        labelText: context.l10n.desktopEcosystemLabel,
        filled: true,
        fillColor: AppColors.surface2,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      items: [
        DropdownMenuItem<DesktopEcosystem?>(value: null, child: Text(auto)),
        for (final e in DesktopEcosystem.values)
          DropdownMenuItem<DesktopEcosystem?>(value: e, child: Text(e.label)),
      ],
      onChanged: enabled ? onChanged : null,
    );
  }
}

/// Notice shown when the bundled extension engine (needed by Aniyomi and
/// Mihon) is missing: the existing explanation plus an 'Open folder' button
/// that opens the app folder, as the old Providers hub row did.
class DesktopEngineMissingNotice extends StatelessWidget {
  const DesktopEngineMissingNotice({super.key, this.compact = false});

  /// Smaller padding for use inside a dialog.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('desktop-sources-engine-missing'),
      padding: EdgeInsets.all(compact ? 10 : 12),
      decoration: BoxDecoration(
        color: AppColors.accentSoft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: AppColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Aniyomi and Mihon: ${context.l10n.extensionEngineNotFound}',
                  style: AppText.caption.copyWith(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  key: const ValueKey('desktop-sources-open-folder'),
                  onPressed: () => unawaited(
                    revealInExplorer(p.dirname(Platform.resolvedExecutable)),
                  ),
                  icon: const Icon(Icons.folder_open_rounded, size: 16),
                  label: Text(context.l10n.openFolder),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

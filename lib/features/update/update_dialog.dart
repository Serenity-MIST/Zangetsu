import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/update/update_service.dart';
import '../../l10n/l10n.dart';

/// Where Windows builds are published. The in-app updater only knows the
/// upstream Android APK releases, so the desktop build never downloads or
/// installs anything itself; it sends the user to this page instead (same
/// destination as the Windows "Windows updates" settings row).
const String kWindowsUpdatesUrl =
    'https://github.com/Serenity-MIST/Zangetsu/commits/zangetsu-windows-desktop';

/// Opens [kWindowsUpdatesUrl] in the browser. Replaceable in tests.
@visibleForTesting
Future<bool> Function(Uri uri) updatePageLauncher = (uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

bool get _isWindowsUi => defaultTargetPlatform == TargetPlatform.windows;

/// Graphite dialog surface and edge on Windows (matches the desktop settings
/// dialogs).
const Color _kDesktopSurface = Color(0xFF1A1B20);
const Color _kDesktopEdge = Color(0xFF36373E);

/// Check for an update and, if one exists, show the update dialog.
///
/// In [manual] mode (the Settings "Check for updates" tap) it also tells the
/// user when they're already up to date. In auto mode (app launch) it stays
/// silent unless a newer, non-skipped release is found — so it never nags.
Future<void> maybeShowUpdateDialog(
  BuildContext context, {
  bool manual = false,
}) async {
  // Windows: the updater only checks Android APK releases, so a manual check
  // can't truthfully say "you're on the latest version". Open the Windows
  // updates page instead; the silent launch check stays silent.
  if (_isWindowsUi) {
    if (manual) await _openWindowsUpdatesPage();
    return;
  }
  final service = UpdateService();
  final info = await service.checkForUpdate(respectSkip: !manual);
  if (!context.mounted) return;
  if (info == null) {
    if (manual) {
      final v = await service.currentVersion();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.onLatestVersion(v.isEmpty ? '' : ' (v$v)'),
          ),
        ),
      );
    }
    return;
  }
  await showUpdateInfoDialog(context, info: info, service: service);
}

/// Show the dialog for an already-found [info]. Public for widget tests.
@visibleForTesting
Future<void> showUpdateInfoDialog(
  BuildContext context, {
  required UpdateInfo info,
  required UpdateService service,
}) => showDialog<void>(
  context: context,
  // Windows: darker barrier like the other desktop dialogs.
  barrierColor: _isWindowsUi ? Colors.black.withValues(alpha: 0.6) : null,
  builder: (_) => _UpdateDialog(info: info, service: service),
);

/// Best-effort browser launch; a missing browser must not crash the app.
Future<bool> _openWindowsUpdatesPage() async {
  try {
    return await updatePageLauncher(Uri.parse(kWindowsUpdatesUrl));
  } catch (_) {
    return false;
  }
}

/// Confirmation shown when the user flips the "Beta updates" switch on, so it's
/// never a silent opt-in. Returns true if they chose to join.
Future<bool> confirmJoinBeta(BuildContext context) async {
  final joined = await showDialog<bool>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.science_outlined, color: AppColors.accent, size: 26),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(ctx.l10n.joinBetaUpdates, style: AppText.title),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              ctx.l10n.joinBetaUpdatesBody,
              style: AppText.body.copyWith(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                spacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: Text(
                      ctx.l10n.notNow,
                      style: AppText.button.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                    ),
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: Text(
                      ctx.l10n.joinBeta,
                      style: AppText.button.copyWith(color: Colors.white),
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
  return joined ?? false;
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info, required this.service});

  final UpdateInfo info;
  final UpdateService service;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double? _progress; // null until the download starts
  bool _busy = false; // downloading or installing
  String? _error;

  /// Windows: never download/install an APK; open the Windows updates page in
  /// the browser and close the dialog once it opened.
  Future<void> _openUpdatesPage() async {
    final ok = await _openWindowsUpdatesPage();
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _error = "Couldn't open the browser.");
    }
  }

  Future<void> _startUpdate() async {
    if (_isWindowsUi) return _openUpdatesPage();
    setState(() {
      _busy = true;
      _progress = 0;
      _error = null;
    });
    try {
      final file = await widget.service.downloadApk(
        widget.info.apkUrl,
        expectedSize: widget.info.apkSize,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() => _progress = 1);
      final ok = await widget.service.installApk(file);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(); // installer launched — close the dialog
      } else {
        setState(() {
          _busy = false;
          _error = context.l10n.couldnTOpenInstaller;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
        _error = context.l10n.downloadFailedCheckConnection;
      });
    }
  }

  /// Windows: centred graphite card with a close button, desktop buttons and
  /// a browser action instead of the APK installer flow.
  Widget _desktopDialog(BuildContext context) {
    final notes = widget.info.notes;
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    return Dialog(
      backgroundColor: _kDesktopSurface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(32),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: _kDesktopEdge),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
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
                      color: AppColors.accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.system_update_rounded,
                      color: AppColors.accent,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.info.isPrerelease
                              ? context.l10n.betaUpdateAvailable
                              : context.l10n.updateAvailable,
                          style: AppText.headline.copyWith(
                            fontSize: 20,
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Version ${widget.info.version}',
                          style: AppText.caption.copyWith(
                            color: AppColors.accent,
                          ),
                        ),
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
            const Divider(height: 1, color: _kDesktopEdge),
            if (notes.isNotEmpty)
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(context.l10n.whatSNew, style: AppText.caption),
                      const SizedBox(height: 6),
                      _ReleaseNotes(notes),
                    ],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'The Windows build updates from its GitHub page; nothing '
                    'is downloaded or installed in the app.',
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: AppText.caption.copyWith(color: AppColors.accent),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton(
                        style: TextButton.styleFrom(shape: buttonShape),
                        onPressed: () async {
                          await widget.service.skipVersion(widget.info.version);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                        child: Text(
                          context.l10n.skip,
                          style: AppText.button.copyWith(
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          shape: buttonShape,
                          foregroundColor: AppColors.textPrimary,
                          side: const BorderSide(color: _kDesktopEdge),
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(context.l10n.later),
                      ),
                      FilledButton.icon(
                        key: const ValueKey('update-open-page'),
                        autofocus: true,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.white,
                          shape: buttonShape,
                        ),
                        onPressed: _openUpdatesPage,
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        label: const Text('Open updates page'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isWindowsUi) return _desktopDialog(context);
    final notes = widget.info.notes;
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.system_update_rounded,
                  color: AppColors.accent,
                  size: 26,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.info.isPrerelease
                        ? context.l10n.betaUpdateAvailable
                        : context.l10n.updateAvailable,
                    style: AppText.title,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Version ${widget.info.version}',
              style: AppText.caption.copyWith(color: AppColors.accent),
            ),
            const SizedBox(height: 14),
            if (notes.isNotEmpty) ...[
              Text(context.l10n.whatSNew, style: AppText.caption),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(child: _ReleaseNotes(notes)),
              ),
              const SizedBox(height: 14),
            ],
            if (_progress != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 6,
                  backgroundColor: AppColors.surface2,
                  color: AppColors.accent,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _progress! >= 1
                    ? context.l10n.startingInstaller
                    : context.l10n.downloadingPercent(
                        (_progress! * 100).round(),
                      ),
                style: AppText.caption,
              ),
              const SizedBox(height: 8),
            ],
            if (_error != null) ...[
              Text(
                _error!,
                style: AppText.caption.copyWith(color: AppColors.accent),
              ),
              const SizedBox(height: 8),
            ],
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                spacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (!_busy)
                    TextButton(
                      onPressed: () async {
                        await widget.service.skipVersion(widget.info.version);
                        if (context.mounted) Navigator.of(context).pop();
                      },
                      child: Text(
                        context.l10n.skip,
                        style: AppText.button.copyWith(
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ),
                  if (!_busy)
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(
                        context.l10n.later,
                        style: AppText.button.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                    ),
                    onPressed: _busy ? null : _startUpdate,
                    child: Text(
                      _error != null ? context.l10n.retry : context.l10n.update,
                      style: AppText.button.copyWith(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders GitHub release notes (markdown) as clean styled text — no markdown
/// package needed. Handles the common changelog subset: `#`/`##`/`###` headers,
/// `-`/`*`/`+` bullets, `**bold**`/`__bold__`, `*italic*`/`_italic_`,
/// `` `code` ``, `[text](url)` links (shown as their text), `---` rules, and
/// blank-line spacing. Soft-wrapped lines inside a paragraph/bullet are merged
/// first, so an inline span (e.g. `**bold**`) that wraps across a source newline
/// still renders. Anything it doesn't recognise falls through as plain text.
class _ReleaseNotes extends StatelessWidget {
  const _ReleaseNotes(this.source);

  final String source;

  @override
  Widget build(BuildContext context) {
    final base = AppText.body.copyWith(
      color: AppColors.textSecondary,
      height: 1.4,
    );
    final widgets = <Widget>[];
    for (final b in _blocks(source)) {
      switch (b.type) {
        case 'blank':
          widgets.add(const SizedBox(height: 8));
        case 'hr':
          widgets.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Divider(
                color: AppColors.textTertiary.withValues(alpha: 0.3),
                height: 1,
              ),
            ),
          );
        case 'header':
          widgets.add(
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: Text.rich(
                _inline(
                  b.text,
                  base.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: b.level <= 1 ? 16 : (b.level == 2 ? 15 : 14),
                  ),
                ),
              ),
            ),
          );
        case 'bullet':
          widgets.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('•  ', style: base),
                  Expanded(child: Text.rich(_inline(b.text, base))),
                ],
              ),
            ),
          );
        default:
          widgets.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text.rich(_inline(b.text, base)),
            ),
          );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: widgets,
    );
  }

  /// Group the markdown into logical blocks, merging soft-wrapped continuation
  /// lines into the preceding paragraph/bullet so inline spans that wrap across
  /// source newlines aren't split (which would leak literal `**` markers).
  List<_Blk> _blocks(String src) {
    final out = <_Blk>[];
    for (final raw in src.replaceAll('\r\n', '\n').split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) {
        out.add(_Blk('blank'));
      } else if (RegExp(r'^([-*_])\1{2,}$').hasMatch(line)) {
        out.add(_Blk('hr'));
      } else if (RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line) case final h?) {
        out.add(_Blk('header', h.group(2)!, h.group(1)!.length));
      } else if (RegExp(r'^[-*+]\s+(.*)$').firstMatch(line) case final b?) {
        out.add(_Blk('bullet', b.group(1)!));
      } else if (out.isNotEmpty &&
          (out.last.type == 'bullet' || out.last.type == 'p')) {
        out.last.text = '${out.last.text} $line'; // soft-wrap continuation
      } else {
        out.add(_Blk('p', line));
      }
    }
    return out;
  }

  /// Inline markdown → styled spans: `**bold**`/`__bold__`, `*italic*`/`_italic_`,
  /// `` `code` ``, and `[text](url)` links collapsed to their text.
  TextSpan _inline(String text, TextStyle style) {
    final delinked = text.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\(([^)]+)\)'),
      (m) => m.group(1) ?? '',
    );
    final spans = <TextSpan>[];
    final pattern = RegExp(r'(\*\*|__)(.+?)\1|(\*|_)(.+?)\3|`([^`]+)`');
    var i = 0;
    for (final m in pattern.allMatches(delinked)) {
      if (m.start > i) {
        spans.add(TextSpan(text: delinked.substring(i, m.start), style: style));
      }
      if (m.group(2) != null) {
        spans.add(
          TextSpan(
            text: m.group(2),
            style: style.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
      } else if (m.group(4) != null) {
        spans.add(
          TextSpan(
            text: m.group(4),
            style: style.copyWith(fontStyle: FontStyle.italic),
          ),
        );
      } else if (m.group(5) != null) {
        spans.add(
          TextSpan(
            text: m.group(5),
            style: style.copyWith(fontFamily: 'monospace', color: Colors.white),
          ),
        );
      }
      i = m.end;
    }
    if (i < delinked.length) {
      spans.add(TextSpan(text: delinked.substring(i), style: style));
    }
    return TextSpan(children: spans, style: style);
  }
}

/// One logical markdown block: type ∈ {blank, hr, header, bullet, p}.
class _Blk {
  _Blk(this.type, [this.text = '', this.level = 0]);
  final String type;
  String text;
  final int level;
}

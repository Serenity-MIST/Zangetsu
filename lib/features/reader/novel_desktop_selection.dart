import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/desktop/desktop_context_menu.dart';
import '../../l10n/l10n.dart';

/// Windows novel text selection (reader-11 A): drag or double-click to
/// select, Ctrl+C to copy, and a right-click menu with Copy, Search the web
/// and Translate in the app's graphite menu style.
class NovelSelectionArea extends StatefulWidget {
  const NovelSelectionArea({
    super.key,
    required this.child,
    this.onSelectionText,
  });

  final Widget child;

  /// Reports the selected text ('' when nothing is selected), so the reader
  /// can tell a click that only clears a selection from a page click.
  final ValueChanged<String>? onSelectionText;

  /// Longest text handed to a web search or translation; longer selections
  /// are cut so the address stays within what browsers accept.
  static const int maxWebTextLength = 1500;

  /// Address that searches the web for [text].
  static Uri searchUri(String text) =>
      Uri.https('www.google.com', '/search', {'q': _trimmed(text)});

  /// Address that translates [text] into [targetLanguage].
  static Uri translateUri(String text, String targetLanguage) =>
      Uri.https('translate.google.com', '/', {
        'sl': 'auto',
        'tl': targetLanguage,
        'text': _trimmed(text),
        'op': 'translate',
      });

  static String _trimmed(String text) {
    final t = text.trim();
    return t.length > maxWebTextLength ? t.substring(0, maxWebTextLength) : t;
  }

  @override
  State<NovelSelectionArea> createState() => _NovelSelectionAreaState();
}

class _NovelSelectionAreaState extends State<NovelSelectionArea> {
  /// The current selection. Kept here because opening the menu moves focus
  /// away from the text, which clears the selection itself.
  String _selected = '';

  void _onSelection(SelectedContent? content) {
    _selected = content?.plainText ?? '';
    widget.onSelectionText?.call(_selected);
  }

  /// Opens the graphite menu at [position] (global) for the current text.
  Future<void> _openMenu(Offset position) async {
    final text = _selected.trim();
    final has = text.isNotEmpty;
    final language = Localizations.localeOf(context).languageCode;
    await showDesktopContextMenu<void>(
      context,
      position: position,
      items: [
        DesktopMenuItem(
          label: context.l10n.copy,
          icon: Icons.copy_rounded,
          shortcut: 'Ctrl+C',
          enabled: has,
          onTap: () => Clipboard.setData(ClipboardData(text: text)),
        ),
        const DesktopMenuItem.divider(),
        DesktopMenuItem(
          label: context.l10n.searchTheWeb,
          icon: Icons.travel_explore_rounded,
          enabled: has,
          onTap: () => _launch(NovelSelectionArea.searchUri(text)),
        ),
        DesktopMenuItem(
          label: context.l10n.translate,
          icon: Icons.translate_rounded,
          enabled: has,
          onTap: () => _launch(NovelSelectionArea.translateUri(text, language)),
        ),
      ],
    );
  }

  /// Opens [uri] in the default browser; a failure just does nothing.
  Future<void> _launch(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => SelectionArea(
    onSelectionChanged: _onSelection,
    // Flutter's own toolbar is swapped for the app's menu: the builder only
    // places a one-shot launcher that hides the toolbar and opens the menu.
    contextMenuBuilder: (menuContext, state) => _MenuLauncher(
      onOpen: () {
        final anchor = state.contextMenuAnchors.primaryAnchor;
        state.hideToolbar();
        _openMenu(anchor);
      },
    ),
    child: widget.child,
  );
}

/// Runs [onOpen] once, after the frame it was built in.
class _MenuLauncher extends StatefulWidget {
  const _MenuLauncher({required this.onOpen});

  final VoidCallback onOpen;

  @override
  State<_MenuLauncher> createState() => _MenuLauncherState();
}

class _MenuLauncherState extends State<_MenuLauncher> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onOpen());
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

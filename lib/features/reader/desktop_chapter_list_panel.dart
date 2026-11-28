import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/desktop/desktop_context_menu.dart';
import '../../core/models/episode.dart';
import '../../core/reading/chapter_nav.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import 'reader_chrome.dart';
import '../../l10n/l10n.dart';

/// Windows chapter list for the manga reader (reader-10, Option B).
///
/// Opened in the reader's side panel instead of the phone sheet. Adds what a
/// 300+ chapter series needs: a filter box (number or title), read chapters
/// dimmed with a tick, downloaded chapters marked, keyboard navigation that
/// starts on the chapter being read (Up/Down/PageUp/PageDown, Enter opens),
/// and a right-click menu with Mark read up to here and Download.
class DesktopChapterListPanel extends StatefulWidget {
  const DesktopChapterListPanel({
    super.key,
    required this.title,
    required this.chapters,
    required this.currentIndex,
    required this.isRead,
    required this.isDownloaded,
    required this.onOpen,
    this.subtitle,
    this.onMarkReadUpTo,
    this.onDownload,
    this.changes,
  });

  /// Panel heading ('Chapters').
  final String title;

  /// Line under the heading, e.g. '42 of 300'.
  final String? subtitle;

  /// The series' chapters, ascending (same list the reader steps through).
  final List<Episode> chapters;

  /// Index of the chapter open in the reader; selected when the panel opens.
  final int currentIndex;

  /// Read / downloaded state for a chapter index, asked on every build so the
  /// markers follow [changes].
  final bool Function(int index) isRead;
  final bool Function(int index) isDownloaded;

  /// Opens a chapter. The panel closes itself first.
  final ValueChanged<int> onOpen;

  /// Context-menu actions; a null callback hides that row.
  final Future<void> Function(int index)? onMarkReadUpTo;
  final Future<void> Function(int index)? onDownload;

  /// Rebuilds the markers when read or download state changes elsewhere.
  final Listenable? changes;

  @override
  State<DesktopChapterListPanel> createState() =>
      _DesktopChapterListPanelState();
}

class _DesktopChapterListPanelState extends State<DesktopChapterListPanel> {
  /// Fixed row height: lets the list jump straight to a row by index.
  static const double _rowHeight = 46;

  final TextEditingController _query = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'chapter-list-search');

  /// Owned here and disposed with the panel (the old sheet leaked one).
  late final ScrollController _scroll;

  /// Chapter indices that match the filter, in list order.
  late List<int> _visible;

  /// Position in [_visible] of the keyboard-selected row.
  int _selected = 0;

  /// Guards against Enter (key) and onSubmitted both opening a chapter.
  bool _opened = false;

  @override
  void initState() {
    super.initState();
    _visible = List<int>.generate(widget.chapters.length, (i) => i);
    _selected = widget.currentIndex.clamp(0, _visible.length - 1).toInt();
    // Opens with the current chapter a few rows from the top, so the
    // chapters around it are visible too.
    _scroll = ScrollController(
      initialScrollOffset: ((_selected - 3) * _rowHeight).clamp(
        0.0,
        double.infinity,
      ),
    );
  }

  @override
  void dispose() {
    _query.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Display title for a chapter: its own title, else 'Chapter N'.
  String _titleOf(int i) {
    final t = widget.chapters[i].title.trim();
    return t.isNotEmpty
        ? t
        : context.l10n.chapterNumberTitle(chapterNumberLabel(widget.chapters, i));
  }

  /// Re-filters by number or title and keeps the selection on the current
  /// chapter when it still matches, else on the first match.
  void _filter(String text) {
    final q = text.trim().toLowerCase();
    final next = <int>[
      for (var i = 0; i < widget.chapters.length; i++)
        if (q.isEmpty ||
            chapterNumberLabel(widget.chapters, i) == q ||
            chapterNumberLabel(widget.chapters, i).startsWith(q) ||
            _titleOf(i).toLowerCase().contains(q))
          i,
    ];
    final keep = next.indexOf(widget.currentIndex);
    setState(() {
      _visible = next;
      _selected = q.isEmpty && keep >= 0 ? keep : 0;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  /// Moves the keyboard selection by [delta] rows and scrolls it into view.
  void _move(int delta) {
    if (_visible.isEmpty) return;
    setState(() {
      _selected = (_selected + delta).clamp(0, _visible.length - 1).toInt();
    });
    _reveal();
  }

  /// Scrolls just enough to show the selected row.
  void _reveal() {
    if (!mounted || !_scroll.hasClients || _visible.isEmpty) return;
    final p = _scroll.position;
    final top = _selected * _rowHeight;
    final bottom = top + _rowHeight;
    if (top < p.pixels) {
      _scroll.jumpTo(top.clamp(p.minScrollExtent, p.maxScrollExtent));
    } else if (bottom > p.pixels + p.viewportDimension) {
      _scroll.jumpTo(
        (bottom - p.viewportDimension).clamp(
          p.minScrollExtent,
          p.maxScrollExtent,
        ),
      );
    }
  }

  /// Rows that fit in the list, for PageUp/PageDown.
  int get _pageRows => _scroll.hasClients
      ? (_scroll.position.viewportDimension / _rowHeight).floor().clamp(1, 50)
      : 8;

  /// Closes the panel and opens chapter [index], once.
  void _open(int index) {
    if (_opened) return;
    _opened = true;
    Navigator.of(context).pop();
    widget.onOpen(index);
  }

  /// Opens the selected row (Enter in the search box or the list).
  void _openSelected() {
    if (_visible.isEmpty) return;
    _open(_visible[_selected]);
  }

  /// Right-click menu for chapter [index] at [position].
  Future<void> _menu(int index, Offset position) async {
    setState(() => _selected = _visible.indexOf(index).clamp(0, 1 << 30));
    final downloaded = widget.isDownloaded(index);
    await showDesktopContextMenu<void>(
      context,
      position: position,
      items: [
        DesktopMenuItem(
          label: context.l10n.open,
          icon: Icons.menu_book_rounded,
          onTap: () => _open(index),
        ),
        if (widget.onMarkReadUpTo != null || widget.onDownload != null)
          const DesktopMenuItem.divider(),
        if (widget.onMarkReadUpTo != null)
          DesktopMenuItem(
            label: context.l10n.markReadUpToHere,
            icon: Icons.done_all_rounded,
            onTap: () async {
              await widget.onMarkReadUpTo!(index);
              if (mounted) setState(() {});
            },
          ),
        if (widget.onDownload != null)
          DesktopMenuItem(
            label: downloaded ? context.l10n.downloaded : context.l10n.download,
            icon: downloaded
                ? Icons.download_done_rounded
                : Icons.download_rounded,
            enabled: !downloaded,
            onTap: () async {
              await widget.onDownload!(index);
              if (mounted) setState(() {});
            },
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Wins over the text field's own caret keys: the arrows walk the list
    // while the filter keeps focus, so typing and navigating never conflict.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.pageDown): () =>
            _move(_pageRows),
        const SingleActivator(LogicalKeyboardKey.pageUp): () =>
            _move(-_pageRows),
        const SingleActivator(LogicalKeyboardKey.home, control: true): () =>
            _move(-_visible.length),
        const SingleActivator(LogicalKeyboardKey.end, control: true): () =>
            _move(_visible.length),
        const SingleActivator(LogicalKeyboardKey.enter): _openSelected,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _openSelected,
      },
      child: ReaderSheetShell(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(widget.title, style: AppText.headline),
                    ),
                    IconButton(
                      key: const ValueKey('reader-panel-close'),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      icon: const Icon(Icons.close_rounded, size: 20),
                      color: AppColors.textSecondary,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              if (widget.subtitle != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    widget.subtitle!,
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  key: const ValueKey('reader-chapter-search'),
                  controller: _query,
                  focusNode: _searchFocus,
                  autofocus: true,
                  onChanged: _filter,
                  onSubmitted: (_) => _openSelected(),
                  style: AppText.body,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: context.l10n.goToChapterOrSearch,
                    prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    filled: true,
                    fillColor: DesktopChrome.field,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              Flexible(
                child: _visible.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          context.l10n.noChaptersMatch,
                          textAlign: TextAlign.center,
                          style: AppText.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      )
                    : ListenableBuilder(
                        listenable: widget.changes ?? _NoChanges.instance,
                        builder: (context, _) => ListView.builder(
                          key: const ValueKey('reader-chapter-list'),
                          controller: _scroll,
                          itemCount: _visible.length,
                          itemExtent: _rowHeight,
                          itemBuilder: (context, row) =>
                              _row(_visible[row], row == _selected),
                        ),
                      ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// One chapter row: number, title, then downloaded / read / current marks.
  Widget _row(int i, bool selected) {
    final current = i == widget.currentIndex;
    final read = widget.isRead(i);
    final downloaded = widget.isDownloaded(i);
    // Read chapters are dimmed, the open one is accented.
    final color = current
        ? AppColors.accent
        : read
        ? AppColors.textTertiary
        : AppColors.textPrimary;
    return Material(
      key: ValueKey('reader-chapter-row-$i'),
      color: selected
          ? DesktopChrome.selectedFill(AppColors.accent)
          : Colors.transparent,
      child: InkWell(
        // The list never takes focus away from the filter box.
        canRequestFocus: false,
        onTap: () => _open(i),
        onSecondaryTapUp: (d) => _menu(i, d.globalPosition),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            children: [
              SizedBox(
                width: 50,
                child: Text(
                  chapterNumberLabel(widget.chapters, i),
                  style: AppText.caption.copyWith(
                    color: current ? AppColors.accent : AppColors.textSecondary,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  _titleOf(i),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(
                    color: color,
                    fontWeight: current ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ),
              if (downloaded)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Tooltip(
                    message: context.l10n.downloaded,
                    child: Icon(
                      Icons.download_done_rounded,
                      key: ValueKey('reader-chapter-downloaded-$i'),
                      size: 16,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              if (read && !current)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Tooltip(
                    message: context.l10n.read,
                    child: Icon(
                      Icons.check_rounded,
                      key: ValueKey('reader-chapter-read-$i'),
                      size: 16,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ),
              if (current)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    size: 18,
                    color: AppColors.accent,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stand-in listenable when the caller has nothing to watch.
class _NoChanges extends ChangeNotifier {
  _NoChanges._();
  static final _NoChanges instance = _NoChanges._();
}

/// Owns a [ScrollController] for a list built inside a sheet builder, so it
/// is disposed with the sheet instead of leaking (reader-10). The phone
/// chapter sheet keeps its exact look and only gets its controller from here.
class ReaderOwnedScrollController extends StatefulWidget {
  const ReaderOwnedScrollController({
    super.key,
    required this.initialScrollOffset,
    required this.builder,
  });

  final double initialScrollOffset;
  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  @override
  State<ReaderOwnedScrollController> createState() =>
      _ReaderOwnedScrollControllerState();
}

class _ReaderOwnedScrollControllerState
    extends State<ReaderOwnedScrollController> {
  late final ScrollController _controller = ScrollController(
    initialScrollOffset: widget.initialScrollOffset,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}

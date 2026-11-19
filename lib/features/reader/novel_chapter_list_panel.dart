import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/desktop/desktop_chrome_colors.dart';
import '../../core/desktop/desktop_context_menu.dart';
import '../../core/di/injector.dart';
import '../../core/download/chapter_download_store.dart';
import '../../core/download/chapter_downloader.dart';
import '../../core/download/chapter_download.dart';
import '../../core/mode/content_mode.dart';
import '../../core/models/episode.dart';
import '../../core/reading/chapter_nav.dart';
import '../../core/reading/read_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import 'reader_chrome.dart';
import '../../l10n/l10n.dart';

/// Windows novel chapter list (reader-10 B), shown in the reader's side
/// panel: a filter box, read chapters dimmed, downloaded ones marked, the
/// current chapter selected and scrolled into view, Up/Down/PageUp/PageDown/
/// Home/End to move, Enter to open, and a right-click (or Menu key) menu with
/// Open, Mark read up to here, Mark as read/unread and Download.
class NovelChapterListPanel extends StatefulWidget {
  const NovelChapterListPanel({
    super.key,
    required this.chapters,
    required this.currentIndex,
    required this.sourceId,
    required this.showId,
    required this.showTitle,
    required this.cover,
    required this.onOpen,
    this.title,
  });

  /// Chapters in reading order (ascending).
  final List<Episode> chapters;
  final int currentIndex;
  final String sourceId;
  final String showId;
  final String showTitle;
  final String? cover;

  /// Opens the chapter at this index of [chapters]; the panel closes first.
  final ValueChanged<int> onOpen;
  /// Panel heading; null shows the translated "Chapters".
  final String? title;

  /// Height of one row; used to scroll the selection into view.
  static const double rowHeight = 48;

  /// Indices of [chapters] whose number or title matches [query].
  static List<int> filter(List<Episode> chapters, String query) {
    final q = query.trim().toLowerCase();
    return [
      for (var i = 0; i < chapters.length; i++)
        if (q.isEmpty ||
            chapterNumberLabel(chapters, i).toLowerCase().contains(q) ||
            chapters[i].title.toLowerCase().contains(q))
          i,
    ];
  }

  @override
  State<NovelChapterListPanel> createState() => _NovelChapterListPanelState();
}

class _NovelChapterListPanelState extends State<NovelChapterListPanel> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'chapter-filter');
  late final ScrollController _scroll = ScrollController(
    initialScrollOffset:
        ((widget.currentIndex - 3) * NovelChapterListPanel.rowHeight)
            .clamp(0, double.infinity)
            .toDouble(),
  );

  /// Visible chapter indices after filtering.
  late List<int> _visible = NovelChapterListPanel.filter(widget.chapters, '');

  /// Index (into [widget.chapters]) of the highlighted row.
  late int _selected = widget.currentIndex;

  @override
  void dispose() {
    _query.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _isRead(int i) {
    if (!sl.isRegistered<ReadStore>()) return false;
    try {
      return sl<ReadStore>().finished(
        widget.sourceId,
        widget.showId,
        widget.chapters[i].id,
      );
    } catch (_) {
      return false;
    }
  }

  bool _isDownloaded(int i) {
    if (!sl.isRegistered<ChapterDownloadStore>()) return false;
    try {
      return sl<ChapterDownloadStore>().isDownloaded(
        widget.sourceId,
        widget.chapters[i].url,
      );
    } catch (_) {
      return false;
    }
  }

  void _onQuery(String q) {
    setState(() {
      _visible = NovelChapterListPanel.filter(widget.chapters, q);
      if (!_visible.contains(_selected) && _visible.isNotEmpty) {
        _selected = _visible.first;
      }
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _reveal();
  }

  /// Moves the highlight by [delta] rows (clamped) and keeps it on screen.
  void _move(int delta) {
    if (_visible.isEmpty) return;
    final at = _visible.indexOf(_selected);
    final next = ((at < 0 ? 0 : at) + delta).clamp(0, _visible.length - 1);
    setState(() => _selected = _visible[next]);
    _reveal();
  }

  /// Scrolls just enough to show the highlighted row.
  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final row = _visible.indexOf(_selected);
      if (row < 0) return;
      const h = NovelChapterListPanel.rowHeight;
      final top = row * h;
      final p = _scroll.position;
      if (top < p.pixels) {
        _scroll.jumpTo(top);
      } else if (top + h > p.pixels + p.viewportDimension) {
        _scroll.jumpTo(
          (top + h - p.viewportDimension).clamp(0, p.maxScrollExtent),
        );
      }
    });
  }

  void _open(int i) {
    Navigator.of(context).pop();
    widget.onOpen(i);
  }

  /// Keys from the filter box: arrows and paging move the highlight, Enter
  /// opens it, the Menu key opens its context menu.
  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final page =
        (_scroll.hasClients
                ? _scroll.position.viewportDimension ~/
                      NovelChapterListPanel.rowHeight
                : 8)
            .clamp(1, 50);
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
    } else if (key == LogicalKeyboardKey.pageDown) {
      _move(page);
    } else if (key == LogicalKeyboardKey.pageUp) {
      _move(-page);
    } else if (key == LogicalKeyboardKey.home &&
        HardwareKeyboard.instance.isControlPressed) {
      _move(-_visible.length);
    } else if (key == LogicalKeyboardKey.end &&
        HardwareKeyboard.instance.isControlPressed) {
      _move(_visible.length);
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_visible.contains(_selected)) _open(_selected);
    } else if (key == LogicalKeyboardKey.contextMenu ||
        (key == LogicalKeyboardKey.f10 &&
            HardwareKeyboard.instance.isShiftPressed)) {
      if (_visible.contains(_selected)) _menu(_selected, null);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Right-click / Menu key actions for chapter [i].
  Future<void> _menu(int i, Offset? position) async {
    setState(() => _selected = i);
    final read = _isRead(i);
    final downloaded = _isDownloaded(i);
    final canDownload =
        !downloaded &&
        sl.isRegistered<ChapterDownloader>() &&
        !sl<ChapterDownloader>().isBusy(
          ChapterDownload.idFor(widget.sourceId, widget.chapters[i].url),
        );
    await showDesktopContextMenu<void>(
      context,
      position: position,
      items: [
        DesktopMenuItem(
          label: context.l10n.open,
          icon: Icons.menu_book_rounded,
          shortcut: 'Enter',
          onTap: () => _open(i),
        ),
        const DesktopMenuItem.divider(),
        DesktopMenuItem(
          label: context.l10n.markReadUpToHere,
          icon: Icons.done_all_rounded,
          onTap: () => _markUpTo(i),
        ),
        DesktopMenuItem(
          label: read ? context.l10n.markAsUnread : context.l10n.markAsRead,
          icon: read ? Icons.remove_done_rounded : Icons.done_rounded,
          onTap: () => _setRead([i], !read),
        ),
        const DesktopMenuItem.divider(),
        DesktopMenuItem(
          label: downloaded ? context.l10n.downloaded : context.l10n.download,
          icon: downloaded
              ? Icons.download_done_rounded
              : Icons.download_rounded,
          enabled: canDownload,
          onTap: () => _download(i),
        ),
      ],
    );
    // Focus returns to the filter box so the keys keep working.
    if (mounted) _searchFocus.requestFocus();
  }

  /// Marks every chapter from the first up to [i] as read.
  Future<void> _markUpTo(int i) =>
      _setRead([for (var k = 0; k <= i; k++) k], true);

  Future<void> _setRead(List<int> indices, bool read) async {
    if (!sl.isRegistered<ReadStore>()) return;
    for (final k in indices) {
      await sl<ReadStore>().setRead(
        widget.sourceId,
        widget.showId,
        widget.chapters[k].id,
        read: read,
      );
    }
    if (mounted) setState(() {});
  }

  Future<void> _download(int i) async {
    if (!sl.isRegistered<ChapterDownloader>()) return;
    await sl<ChapterDownloader>().enqueue(
      chapter: widget.chapters[i],
      sourceId: widget.sourceId,
      showId: widget.showId,
      showTitle: widget.showTitle,
      cover: widget.cover,
      mode: ContentMode.novel,
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return ReaderSheetShell(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 2),
              child: Row(
                children: [
                  Expanded(child: Text(widget.title ?? context.l10n.chapters, style: AppText.headline)),
                  IconButton(
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                context.l10n.chapterXOfY(chapterNumberLabel(widget.chapters, widget.currentIndex), chapterCountLabel(widget.chapters)),
                style: AppText.caption.copyWith(color: AppColors.textSecondary),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Focus(
                onKeyEvent: _key,
                skipTraversal: true,
                child: TextField(
                  key: const ValueKey('reader-chapter-filter'),
                  controller: _query,
                  focusNode: _searchFocus,
                  autofocus: true,
                  onChanged: _onQuery,
                  style: AppText.body.copyWith(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: context.l10n.filterByNumberOrTitle,
                    hintStyle: AppText.body.copyWith(
                      color: AppColors.textTertiary,
                    ),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
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
                  : ListView.builder(
                      key: const ValueKey('reader-chapter-list'),
                      controller: _scroll,
                      itemExtent: NovelChapterListPanel.rowHeight,
                      itemCount: _visible.length,
                      itemBuilder: (context, row) => _row(_visible[row]),
                    ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// One chapter row: number, title, read dimming, downloaded tick and the
  /// current-chapter marker.
  Widget _row(int i) {
    final current = i == widget.currentIndex;
    final selected = i == _selected;
    final read = _isRead(i) && !current;
    final chapter = widget.chapters[i];
    final base = current ? AppColors.accent : Colors.white;
    final color = read ? base.withValues(alpha: 0.45) : base;
    return GestureDetector(
      onSecondaryTapUp: (d) => _menu(i, d.globalPosition),
      child: Material(
        color: selected
            ? DesktopChrome.selectedFill(AppColors.accent)
            : Colors.transparent,
        child: InkWell(
          key: ValueKey('reader-chapter-row-$i'),
          canRequestFocus: false,
          onTap: () => _open(i),
          onHover: (h) {
            if (h && _selected != i) setState(() => _selected = i);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                SizedBox(
                  width: 50,
                  child: Text(
                    chapterNumberLabel(widget.chapters, i),
                    style: AppText.caption.copyWith(
                      color: current
                          ? AppColors.accent
                          : AppColors.textSecondary.withValues(
                              alpha: read ? 0.5 : 1,
                            ),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    chapter.title.trim().isNotEmpty
                        ? chapter.title
                        : context.l10n.chapterNumberTitle(chapterNumberLabel(widget.chapters, i)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(
                      color: color,
                      fontWeight: current ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ),
                if (_isDownloaded(i))
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Tooltip(
                      message: context.l10n.downloaded,
                      child: Icon(
                        Icons.download_done_rounded,
                        size: 16,
                        color: AppColors.textSecondary.withValues(alpha: 0.8),
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
      ),
    );
  }
}

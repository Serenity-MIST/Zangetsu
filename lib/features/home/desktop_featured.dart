import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/models/media_item.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/featured_hero.dart';
import '../../core/ui/native_cover_provider.dart';
import '../../core/ui/artwork_quality.dart';
import '../../core/ui/banner_style.dart';

/// Portrait art keeps its natural shape; only real backdrops fill the banner.
class DesktopFeatured extends StatefulWidget {
  const DesktopFeatured({
    super.key,
    required this.items,
    required this.reading,
    required this.inList,
    required this.onPlay,
    required this.onInfo,
    required this.onToggleList,
    required this.meta,
    this.imageBuilder,
    this.style = BannerStyle.defaultId,
  });
  final List<MediaItem> items;
  final bool reading;
  final bool Function(MediaItem) inList;
  final void Function(MediaItem) onPlay, onInfo, onToggleList;
  final Future<HeroMeta?> Function(MediaItem) meta;
  final Widget Function(MediaItem)? imageBuilder;

  /// Follows the same persisted Card/Panels/Edge choice as Interface settings.
  final String style;
  @override
  State<DesktopFeatured> createState() => _DesktopFeaturedState();
}

/// Rotates featured titles only when visible and not hovered; owns the timer.
class _DesktopFeaturedState extends State<DesktopFeatured> {
  int _index = 0;
  Timer? _timer;
  bool _hovered = false;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (mounted &&
          !_hovered &&
          TickerMode.valuesOf(context).enabled &&
          widget.items.length > 1)
        _move(1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Wraps previous/next navigation around the current featured title count.
  void _move(int delta) =>
      setState(() => _index = (_index + delta) % widget.items.length);

  /// Loads artwork through source-aware image headers with a safe placeholder.
  Widget _art(MediaItem item, {bool backdrop = false}) {
    if (widget.imageBuilder != null) return widget.imageBuilder!(item);
    final url = backdrop ? item.banner : item.cover;
    if (url == null || url.isEmpty)
      return ColoredBox(color: AppColors.surface2);
    return LayoutBuilder(
      builder: (context, bounds) => Image(
        image: ResizeImage(
          nativeCoverProvider(desktopArtworkUrl(url), item.coverHeaders),
          width: artworkDecodeWidth(
            bounds.maxWidth,
            MediaQuery.devicePixelRatioOf(context),
          ),
        ),
        filterQuality: FilterQuality.medium,
        fit: backdrop ? BoxFit.cover : BoxFit.contain,
        errorBuilder: (_, _, _) => ColoredBox(color: AppColors.surface2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final item = widget.items[_index % widget.items.length];
    return MouseRegion(
      onEnter: (_) => _hovered = true,
      onExit: (_) => _hovered = false,
      child: LayoutBuilder(
        builder: (context, bounds) {
          final compact = bounds.maxWidth < 850;
          final edge = widget.style == BannerStyle.edgeId;
          final panels = widget.style == BannerStyle.panelsId;
          return Container(
            key: ValueKey('desktop-banner-${widget.style}'),
            height: edge ? (compact ? 370 : 430) : (compact ? 330 : 380),
            margin: EdgeInsets.fromLTRB(edge ? 0 : 16, 8, edge ? 0 : 16, 12),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(edge ? 0 : 24),
              border: Border.all(color: AppColors.hairline),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.surface2, AppColors.surface, AppColors.bg],
              ),
            ),
            child: Stack(
              children: [
                if (panels)
                  Positioned.fill(
                    child: Row(
                      children: [
                        // Retain whole portraits in a desktop spread instead of
                        // stretching one small cover across the full window.
                        for (var offset = 0; offset < 3; offset++)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: _art(
                                widget.items[(_index + offset) %
                                    widget.items.length],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (!panels && item.banner?.isNotEmpty == true) ...[
                  Positioned.fill(child: _art(item, backdrop: true)),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            AppColors.bg,
                            AppColors.bg.withValues(alpha: .88),
                            AppColors.bg.withValues(alpha: .15),
                          ],
                          stops: const [0, .45, 1],
                        ),
                      ),
                    ),
                  ),
                ],
                if (panels)
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Color(0xF508080D),
                            Color(0x8808080D),
                            Color(0x4408080D),
                          ],
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.all(compact ? 28 : 40),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              widget.reading
                                  ? 'FEATURED READING'
                                  : 'IN THE SPOTLIGHT',
                              style: TextStyle(
                                color: AppColors.accent,
                                letterSpacing: 2.5,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 18),
                            Text(
                              item.title,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: compact ? 28 : 36,
                                height: 1.12,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 16),
                            FutureBuilder<HeroMeta?>(
                              future: widget.meta(item),
                              builder: (_, snapshot) {
                                final genres =
                                    snapshot.data?.genres ?? item.genres;
                                return Text(
                                  genres.take(3).join('  ·  '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 13,
                                  ),
                                );
                              },
                            ),
                            const SizedBox(height: 24),
                            Wrap(
                              spacing: 10,
                              runSpacing: 8,
                              children: [
                                FilledButton.icon(
                                  onPressed: () => widget.onPlay(item),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: AppColors.accent,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 22,
                                      vertical: 18,
                                    ),
                                  ),
                                  icon: Icon(
                                    widget.reading
                                        ? Icons.menu_book_rounded
                                        : Icons.play_arrow_rounded,
                                  ),
                                  label: Text(
                                    widget.reading
                                        ? 'Start reading'
                                        : 'Watch now',
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () => widget.onInfo(item),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 18,
                                      vertical: 18,
                                    ),
                                  ),
                                  icon: const Icon(Icons.info_outline_rounded),
                                  label: const Text('Details'),
                                ),
                                IconButton.filledTonal(
                                  onPressed: () => widget.onToggleList(item),
                                  tooltip: 'My List',
                                  icon: Icon(
                                    widget.inList(item)
                                        ? Icons.check_rounded
                                        : Icons.add_rounded,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (!panels &&
                          item.banner?.isNotEmpty != true &&
                          bounds.maxWidth >= 620) ...[
                        SizedBox(width: compact ? 24 : 60),
                        SizedBox(
                          width: compact ? 170 : 210,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: _art(item),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Positioned(
                  right: 18,
                  bottom: 14,
                  child: Row(
                    children: [
                      Text(
                        '${_index % widget.items.length + 1} / ${widget.items.length}',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: () => _move(-1),
                        tooltip: 'Previous feature',
                        icon: const Icon(Icons.chevron_left_rounded),
                      ),
                      IconButton(
                        onPressed: () => _move(1),
                        tooltip: 'Next feature',
                        icon: const Icon(Icons.chevron_right_rounded),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

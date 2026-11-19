import 'desktop_media_card.dart';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../app_mode.dart';
import '../cache/app_image_cache.dart';
import '../di/injector.dart';
import '../metadata/title_logo_service.dart';
import '../models/media_item.dart';
import '../stremio/stremio_poster_shape.dart';
import '../playback/playback_prefs.dart';

import 'image_fade.dart';
import '../aniyomi/aniyomi_image_provider.dart';
import '../mihon/mihon_image_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'artwork_quality.dart';

const _posterTextScrim = LinearGradient(
  begin: Alignment.bottomCenter,
  end: Alignment.topCenter,
  colors: [Color(0x8C0B0B0F), Color(0x2E0B0B0F), Color(0x000B0B0F)],
  stops: [0, 0.26, 0.68],
);

class PosterCard extends StatefulWidget {
  const PosterCard({
    super.key,
    required this.title,
    this.imageUrl,
    this.wideImageUrl,
    this.headers,
    this.onTap,
    this.onLongPress,
    this.tags = const [],
    this.cellWidth = 180,
    this.showTitle = true,
    this.logoItem,
    this.qualityBadge,
    this.dubBadge,
    this.scoreBadge,
    this.genres = const [],
    this.isAdult = false,
    this.progressBadge,
    this.topRightBadge,
    this.wideOverride,
  });
  final String title;
  final String? imageUrl;
  final String? wideImageUrl;
  final Map<String, String>? headers;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Small overlay badges drawn at the bottom-left of the art (e.g. SUB/DUB).
  final List<String> tags;

  /// Release quality ("4K", "HD", "CAM"), drawn in the TOP-RIGHT corner —
  /// its own spot, so it reads at a glance and never competes with the
  /// SUB/DUB tags along the bottom. Null for the many sources that don't
  /// report one, and the corner stays empty.
  ///
  /// Pass the raw label; the card applies the user's quality-label setting.
  final String? qualityBadge;

  /// "SUB" / "DUB" / "SUB DUB" for anime listings that report it. Sits opposite
  /// the quality badge and follows the audio-label setting.
  final String? dubBadge;

  /// Community score, 0-100, from the metadata catalogue — see
  /// [MediaItem.score]. Follows the score-label setting.
  ///
  /// Only catalogue rows carry one, so this is null on source posters and the
  /// badge simply never appears there. It shares the top-right corner with the
  /// quality badge for that reason: a poster has a score or a resolution,
  /// never both.
  final int? scoreBadge;
  final List<String> genres;
  final bool isAdult;
  final String? progressBadge;
  final Widget? topRightBadge;

  /// Home catalogue artwork can declare its shape independently of preferences.
  final bool? wideOverride;
  final double cellWidth;

  /// When false, omit an external title. An inside-image title still follows
  /// the saved placement setting, including TV cards.
  final bool showTitle;

  /// Metadata identity for title-logo lookup. When absent, the title is
  /// searched by name only when the user selects poster title artwork.
  final MediaItem? logoItem;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

/// Poster preferences, read defensively for standalone widget tests.
PlaybackPrefs? get _posterPrefs {
  try {
    return sl<PlaybackPrefs>();
  } catch (_) {
    return null;
  }
}

/// Only geometry consumers depend on this scope; cards listen to the same
/// revision themselves so standalone cards and widget tests also update.
class PosterCardScope extends InheritedNotifier<ValueNotifier<int>> {
  PosterCardScope({super.key, required super.child})
    : super(notifier: PlaybackPrefs.posterRevision);

  static void watch(BuildContext context) {
    context.dependOnInheritedWidgetOfExactType<PosterCardScope>();
  }
}

PosterCardLayout posterLayout(BuildContext context) {
  PosterCardScope.watch(context);
  return _posterPrefs?.posterCardLayout ?? PosterCardLayout.portrait;
}

PosterCardSize _posterSize(PosterCardLayout layout) {
  final prefs = _posterPrefs;
  return layout == PosterCardLayout.wide
      ? prefs?.posterLandscapeSize ?? PosterCardSize.standard
      : prefs?.posterPortraitSize ?? PosterCardSize.standard;
}

double posterCardScale(BuildContext context) =>
    switch (_posterSize(posterLayout(context))) {
      PosterCardSize.small => 0.85,
      PosterCardSize.standard => 1,
      PosterCardSize.large => 1.15,
    };

int _columnsForSize(int base, PosterCardSize size) => switch (size) {
  PosterCardSize.small => base + 1,
  PosterCardSize.standard => base,
  PosterCardSize.large => base - 1,
};

int _responsiveColumns(
  int desired, {
  required double availableWidth,
  required double minimumCellWidth,
  required double spacing,
  required int maxColumns,
}) {
  final widthLimit = ((availableWidth + spacing) / (minimumCellWidth + spacing))
      .floor()
      .clamp(1, maxColumns);
  return desired.clamp(1, widthLimit).toInt();
}

int posterGridColumns(BuildContext context) {
  final wide = posterLayout(context) == PosterCardLayout.wide;
  final availableWidth = MediaQuery.sizeOf(context).width - 32;
  // Desktop grids use the same card scale as Home instead of stretching the
  // phone's two/three columns across a full PC window.
  if (defaultTargetPlatform == TargetPlatform.windows) {
    return math.max(
      1,
      ((availableWidth + 12) / (posterRowWidth(context) + 12)).ceil(),
    );
  }
  final base = wide ? 2 : 3;
  return _responsiveColumns(
    _columnsForSize(
      base,
      _posterSize(wide ? PosterCardLayout.wide : PosterCardLayout.portrait),
    ),
    availableWidth: availableWidth,
    minimumCellWidth: wide ? 110 : 72,
    spacing: 12,
    maxColumns: 6,
  );
}

double posterGridCellWidth(BuildContext context) {
  final columns = posterGridColumns(context);
  return (MediaQuery.sizeOf(context).width - 32 - 12 * (columns - 1)) / columns;
}

double posterRowWidth(BuildContext context) {
  final wide = posterLayout(context) == PosterCardLayout.wide;
  final desktop = defaultTargetPlatform == TargetPlatform.windows;
  return (wide ? (desktop ? 248 : 184) : (desktop ? 166 : 116)) *
      posterCardScale(context);
}

double posterRowHeight(BuildContext context) {
  final wide = posterLayout(context) == PosterCardLayout.wide;
  if (defaultTargetPlatform == TargetPlatform.windows) {
    return DesktopMediaCard.height(
      posterRowWidth(context),
      MediaQuery.textScalerOf(context).scale(1),
      wide: wide,
      titleInside: posterTitleInside(context, wide: wide),
    );
  }
  return posterCellHeight(
    posterRowWidth(context),
    textScaler: MediaQuery.textScalerOf(context),
    wide: wide,
    titleInside: posterTitleInside(context, wide: wide),
  );
}

int tvPosterGridColumns(BuildContext context) {
  final wide = posterLayout(context) == PosterCardLayout.wide;
  return _responsiveColumns(
    _columnsForSize(
      wide ? 4 : 6,
      _posterSize(wide ? PosterCardLayout.wide : PosterCardLayout.portrait),
    ),
    availableWidth: MediaQuery.sizeOf(context).width - 80,
    minimumCellWidth: wide ? 150 : 100,
    spacing: 18,
    maxColumns: 10,
  );
}

double tvPosterGridAspect(BuildContext context) {
  final wide = posterLayout(context) == PosterCardLayout.wide;
  final placement =
      _posterPrefs?.posterTitlePlacement ?? PosterTitlePlacement.adaptive;
  if (placement == PosterTitlePlacement.adaptive) {
    return wide ? 16 / 9 : 0.56;
  }
  final columns = tvPosterGridColumns(context);
  final width =
      (MediaQuery.sizeOf(context).width - 80 - 18 * (columns - 1)) / columns;
  final artHeight = wide ? width * 9 / 16 : width * 1.5;
  final titleHeight = posterTitleInside(context, wide: wide)
      ? 0.0
      : _kTitleGap + 20;
  return width / (artHeight + titleHeight);
}

bool posterTitleInside(
  BuildContext context, {
  required bool wide,
  MediaItem? item,
}) {
  PosterCardScope.watch(context);
  return switch (_posterPrefs?.posterTitlePlacement ??
      PosterTitlePlacement.adaptive) {
    // Windows keeps captions below the art; elsewhere upstream keeps Stremio
    // addon artwork's own title placement.
    PosterTitlePlacement.adaptive =>
      defaultTargetPlatform == TargetPlatform.windows ||
              item?.sourceId == 'stremio'
          ? false
          : wide,
    PosterTitlePlacement.inside => true,
    PosterTitlePlacement.below => false,
  };
}

class _PosterCardState extends State<PosterCard> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    PlaybackPrefs.posterRevision.addListener(_refresh);
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    PlaybackPrefs.posterRevision.removeListener(_refresh);
    super.dispose();
  }

  void _handleTapDown(TapDownDetails _) => setState(() => _pressed = true);
  void _handleTapUp(TapUpDetails _) => setState(() => _pressed = false);
  void _handleTapCancel() => setState(() => _pressed = false);

  /// The Aniyomi source id for this cover, or null when the header is absent
  /// or malformed. Parsing here (instead of inline with `!`/`int.parse`) keeps
  /// a bad `x-ani-src` value or a null cover from throwing during build — an
  /// unhandled throw here renders the whole card as Flutter's grey error box.
  int? get _aniSrcId {
    final raw = widget.headers?['x-ani-src'];
    if (raw == null || widget.imageUrl == null) return null;
    return int.tryParse(raw);
  }

  /// The Mihon source id for this cover, or null. Twin of [_aniSrcId] — routes
  /// Cloudflare-gated manga covers through the native, cf_clearance-carrying
  /// [MihonImage] instead of CachedNetworkImage.
  int? get _mihonSrcId {
    final raw = widget.headers?['x-mihon-src'];
    if (raw == null || widget.imageUrl == null) return null;
    return int.tryParse(raw);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _buildCard(context, constraints),
  );

  /// Sizes decoding to the real card constraint, including desktop grids and
  /// display scaling, instead of a caller's nominal phone-sized cell width.
  Widget _buildCard(BuildContext context, BoxConstraints constraints) {
    final landscapeMode = posterLayout(context) == PosterCardLayout.wide;
    final wide = widget.wideOverride ?? landscapeMode;
    final titleInside = posterTitleInside(
      context,
      wide: wide,
      item: widget.wideOverride == null ? null : widget.logoItem,
    );
    final titleBoxHeight = _posterTitleHeight(MediaQuery.textScalerOf(context));
    final stremio = widget.logoItem?.sourceId == 'stremio';
    final artUrl = stremio
        ? stremioPosterImage(widget.logoItem!, landscape: landscapeMode)
        : widget.wideOverride == null &&
              wide &&
              widget.wideImageUrl?.isNotEmpty == true
        ? widget.wideImageUrl
        : widget.imageUrl;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      final card = desktopPosterCard(
        context,
        title: widget.title,
        wide: wide,
        titleInside: titleInside,
        artUrl: artUrl,
        sourceImageUrl: widget.imageUrl,
        headers: widget.headers,
        logoItem: widget.logoItem,
        cellWidth: widget.cellWidth,
        onTap: widget.onTap,
        onMenu: widget.onLongPress,
        showTitle: widget.showTitle,
        tags: widget.tags,
        qualityBadge: widget.qualityBadge,
        dubBadge: widget.dubBadge,
        scoreBadge: widget.scoreBadge,
        genres: widget.genres,
        isAdult: widget.isAdult,
        progressBadge: widget.progressBadge,
      );
      // DesktopMediaCard has no corner slot, so upstream's top-right badge
      // (e.g. the Stremio marker in My List) is overlaid on the artwork here.
      if (widget.topRightBadge == null) return card;
      return Stack(
        children: [
          Positioned.fill(child: card),
          Positioned(
            top: 6,
            right: 6,
            child: IgnorePointer(child: widget.topRightBadge!),
          ),
        ],
      );
    }
    final overlayTitle =
        titleInside ||
        (stremio &&
            landscapeMode &&
            (_posterPrefs?.posterTitlePlacement ??
                    PosterTitlePlacement.adaptive) ==
                PosterTitlePlacement.adaptive &&
            widget.logoItem!.landscapePoster?.trim().isNotEmpty != true &&
            widget.logoItem!.banner?.trim().isNotEmpty == true &&
            artUrl == widget.logoItem!.banner);
    final artFit = BoxFit.cover;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final paintedWidth = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : widget.cellWidth;
    final memW = artworkDecodeWidth(paintedWidth, dpr, maximum: 2048);
    final aniSrcId = artUrl == widget.imageUrl ? _aniSrcId : null;
    final mihonSrcId = artUrl == widget.imageUrl ? _mihonSrcId : null;
    // Only wire the press-scale handlers when this card is actually tappable.
    // On TV the card is wrapped in a TvFocusable and passed onTap: null — if we
    // still attached onTapDown/Up/Cancel they'd claim the tap in the gesture
    // arena and do nothing (onTap is null), swallowing the touch before the
    // parent TvFocusable's onTap could fire. Null handlers = no recognizer = the
    // parent gets the tap. (D-pad is unaffected; it never uses the arena.)
    final interactive = widget.onTap != null || widget.onLongPress != null;
    final prefs = _posterPrefs;
    final hasBottomBadges =
        widget.tags.isNotEmpty ||
        (prefs?.posterProgressBadge == true && widget.progressBadge != null);
    final showGenre =
        wide && prefs?.posterGenreBadge == true && widget.genres.isNotEmpty;
    final showAdult = prefs?.posterAdultBadge == true && widget.isAdult;
    final hasRightBadges = showGenre || showAdult;
    final bottomBadges = Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final tag in widget.tags)
          _PosterTag(tag, maxWidth: widget.cellWidth - 22),
        if (prefs?.posterProgressBadge == true && widget.progressBadge != null)
          _PosterTag(widget.progressBadge!, maxWidth: widget.cellWidth - 22),
      ],
    );
    Widget networkArtwork(String url, [Set<String> failedUrls = const {}]) {
      return CachedNetworkImage(
        imageUrl: url,
        cacheManager: AppImageCache.manager,
        httpHeaders: url == widget.imageUrl ? widget.headers : null,
        memCacheWidth: memW,
        fit: artFit,
        fadeInDuration: sl.isRegistered<AppMode>() && sl<AppMode>().isTv
            ? Duration.zero
            : const Duration(milliseconds: 180),
        placeholder: (_, _) => ColoredBox(color: AppColors.surface2),
        errorWidget: (_, _, _) {
          final failed = {...failedUrls, url};
          final next = stremio
              ? stremioPosterImage(
                  widget.logoItem!,
                  landscape: landscapeMode,
                  failedUrls: failed,
                )
              : null;
          return next == null
              ? ColoredBox(color: AppColors.surface2)
              : networkArtwork(next, failed);
        },
      );
    }

    return RepaintBoundary(
      child: MouseRegion(
        cursor: interactive ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          onLongPress: defaultTargetPlatform == TargetPlatform.windows
              ? null
              : widget.onLongPress,
          onSecondaryTap: defaultTargetPlatform == TargetPlatform.windows
              ? widget.onLongPress
              : null,
          onTapDown: interactive ? _handleTapDown : null,
          onTapUp: interactive ? _handleTapUp : null,
          onTapCancel: interactive ? _handleTapCancel : null,
          child: AnimatedScale(
            scale: _pressed
                ? 0.97
                : _hovered && defaultTargetPlatform == TargetPlatform.windows
                ? 1.025
                : 1.0,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ClipRSuperellipse(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (artUrl == null)
                          ColoredBox(color: AppColors.surface2)
                        else if (aniSrcId != null || mihonSrcId != null)
                          // Aniyomi/Mihon path: fetch bytes through the source's own
                          // OkHttpClient (carries CF session cookies) instead of
                          // going through CachedNetworkImage which can't pass CF.
                          Image(
                            // Resize to the cell's pixel width so a big cover
                            // doesn't sit full-res in the image cache (matches the
                            // memCacheWidth the non-native path already uses).
                            image: ResizeImage(
                              aniSrcId != null
                                  ? AniyomiImage(aniSrcId, artUrl)
                                  : MihonImage(mihonSrcId!, artUrl),
                              width: memW,
                            ),
                            fit: artFit,
                            frameBuilder: imageFadeIn,
                            loadingBuilder: (_, child, progress) =>
                                progress == null
                                ? child
                                : ColoredBox(color: AppColors.surface2),
                            errorBuilder: (context, error, stackTrace) =>
                                ColoredBox(color: AppColors.surface2),
                          )
                        else
                          networkArtwork(artUrl),
                        if (overlayTitle || hasBottomBadges || hasRightBadges)
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: _posterTextScrim,
                            ),
                          ),
                        if (widget.topRightBadge != null ||
                            (widget.qualityBadge != null &&
                                (prefs?.posterQualityBadge ?? true)) ||
                            (widget.scoreBadge != null &&
                                widget.qualityBadge == null &&
                                (prefs?.posterScoreBadge ?? true)))
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (widget.qualityBadge != null &&
                                    (prefs?.posterQualityBadge ?? true))
                                  _PosterTag(widget.qualityBadge!)
                                else if (widget.scoreBadge != null &&
                                    widget.qualityBadge == null &&
                                    (prefs?.posterScoreBadge ?? true))
                                  _ScoreTag(widget.scoreBadge!),
                                if (widget.topRightBadge != null)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: IgnorePointer(
                                      child: widget.topRightBadge!,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        if (widget.dubBadge != null &&
                            (prefs?.posterAudioBadge ?? true))
                          Positioned(
                            top: 6,
                            left: 6,
                            child: _PosterTag(widget.dubBadge!),
                          ),
                        if (overlayTitle || hasBottomBadges || hasRightBadges)
                          Positioned(
                            left: 6,
                            bottom: 6,
                            right: 6,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                if (overlayTitle || hasBottomBadges)
                                  Expanded(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (hasBottomBadges) ...[
                                          bottomBadges,
                                          if (overlayTitle &&
                                              widget.title.isNotEmpty)
                                            const SizedBox(height: 4),
                                        ],
                                        if (overlayTitle &&
                                            widget.title.isNotEmpty)
                                          ExcludeSemantics(
                                            excluding: !widget.showTitle,
                                            child: PosterCardTitle(
                                              title: widget.title,
                                              logoItem: widget.logoItem,
                                              width: widget.cellWidth - 12,
                                              maxHeight: wide ? 34 : 54,
                                              addonOverlay:
                                                  stremio && !titleInside,
                                            ),
                                          ),
                                      ],
                                    ),
                                  )
                                else
                                  const Spacer(),
                                if (hasRightBadges) ...[
                                  if (overlayTitle || hasBottomBadges)
                                    const SizedBox(width: 4),
                                  if (showGenre)
                                    _PosterTag(
                                      widget.genres.first,
                                      maxWidth: widget.cellWidth * 0.3,
                                    ),
                                  if (showGenre && showAdult)
                                    const SizedBox(width: 3),
                                  if (showAdult) const _PosterTag('18+'),
                                ],
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (widget.showTitle && !titleInside) ...[
                  const SizedBox(height: _kTitleGap),
                  // A FIXED two-line box, even for a one-line title. The image
                  // above is Expanded, so a shorter title used to hand it the
                  // leftover space and posters came out different heights across
                  // the same row. Pinning the text also pins the gap to whatever
                  // follows the row.
                  SizedBox(
                    height: titleBoxHeight,
                    child: PosterCardTitle(
                      title: widget.title,
                      logoItem: widget.logoItem,
                      width: widget.cellWidth,
                      maxHeight: titleBoxHeight,
                      inside: false,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The Windows poster card with every Poster cards preference applied: title
/// placement ([titleInside]), title artwork, and the score / progress / 18+ /
/// genre / quality / sub-dub badge switches. [PosterCard] uses it on Windows,
/// and the desktop Home shelves call it directly (with a [rank]) so Home
/// follows exactly the same settings as search, see-all and My List.
///
/// [artUrl] is the artwork already chosen for the card's shape; headers are
/// only sent when it is the source cover ([sourceImageUrl]).
DesktopMediaCard desktopPosterCard(
  BuildContext context, {
  required String title,
  required bool wide,
  required bool titleInside,
  String? artUrl,
  String? sourceImageUrl,
  Map<String, String>? headers,
  MediaItem? logoItem,
  double cellWidth = 180,
  VoidCallback? onTap,
  VoidCallback? onMenu,
  bool showTitle = true,
  List<String> tags = const [],
  String? qualityBadge,
  String? dubBadge,
  int? scoreBadge,
  List<String> genres = const [],
  bool isAdult = false,
  String? progressBadge,
  int? rank,
  Key? key,
  Key? artworkKey,
}) {
  final prefs = _posterPrefs;
  return DesktopMediaCard(
    key: key,
    artworkKey: artworkKey,
    title: title,
    rank: rank,
    titleInside: titleInside,
    titleWidget: prefs?.posterTitleStyle == PosterTitleStyle.artwork
        ? PosterCardTitle(
            title: title,
            logoItem: logoItem,
            width: cellWidth,
            maxHeight: MediaQuery.textScalerOf(context).scale(34),
            inside: titleInside,
          )
        : null,
    // Upstream's art choice (Stremio shapes, catalogue wideOverride) feeds
    // the desktop card; headers only belong to the source cover.
    image: artUrl,
    headers: artUrl == sourceImageUrl ? headers : null,
    onTap: onTap,
    onMenu: onMenu,
    showTitle: showTitle,
    score: (prefs?.posterScoreBadge ?? true) ? scoreBadge : null,
    badges: [
      ...tags,
      if (progressBadge != null && prefs?.posterProgressBadge == true)
        progressBadge,
      if (isAdult && prefs?.posterAdultBadge == true) '18+',
      if (wide && genres.isNotEmpty && prefs?.posterGenreBadge == true)
        genres.first,
      if (qualityBadge != null && (prefs?.posterQualityBadge ?? true))
        qualityBadge,
      if (dubBadge != null && (prefs?.posterAudioBadge ?? true)) dubBadge,
    ],
  );
}

/// [desktopPosterCard] for a catalogue [item], choosing its artwork the way
/// [PosterCard] does for the current Shape setting (banner art in Landscape,
/// Stremio's own shapes for addon items). Used by the desktop Home shelves.
DesktopMediaCard desktopPosterCardForItem(
  BuildContext context,
  MediaItem item, {
  required double cellWidth,
  VoidCallback? onTap,
  VoidCallback? onMenu,
  List<String> tags = const [],
  String? progressBadge,
  int? rank,
  Key? artworkKey,
}) {
  final wide = posterLayout(context) == PosterCardLayout.wide;
  final artUrl = item.sourceId == 'stremio'
      ? stremioPosterImage(item, landscape: wide)
      : wide && item.banner?.isNotEmpty == true
      ? item.banner
      : item.cover;
  return desktopPosterCard(
    context,
    title: item.title,
    wide: wide,
    titleInside: posterTitleInside(context, wide: wide),
    artUrl: artUrl,
    sourceImageUrl: item.cover,
    headers: item.coverHeaders,
    logoItem: item,
    cellWidth: cellWidth,
    onTap: onTap,
    onMenu: onMenu,
    tags: tags,
    qualityBadge: item.quality,
    dubBadge: item.dubBadge,
    scoreBadge: item.score,
    genres: item.genres,
    isAdult: item.isAdult,
    progressBadge: progressBadge,
    rank: rank,
    artworkKey: artworkKey,
  );
}

class PosterCardTitle extends StatefulWidget {
  const PosterCardTitle({
    super.key,
    required this.title,
    this.logoItem,
    required this.width,
    required this.maxHeight,
    this.inside = true,
    this.maxLines = 2,
    this.textStyle,
    this.addonOverlay = false,
  });

  final String title;
  final MediaItem? logoItem;
  final double width;
  final double maxHeight;
  final bool inside;
  final int maxLines;
  final TextStyle? textStyle;
  final bool addonOverlay;

  @override
  State<PosterCardTitle> createState() => _PosterCardTitleState();
}

class _PosterCardTitleState extends State<PosterCardTitle> {
  String? _logoUrl;
  String? _loadedTitle;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    PlaybackPrefs.posterRevision.addListener(_refresh);
    _loadLogo();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {});
    _loadLogo();
  }

  @override
  void didUpdateWidget(PosterCardTitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title ||
        oldWidget.logoItem?.id != widget.logoItem?.id ||
        oldWidget.logoItem?.tmdbId != widget.logoItem?.tmdbId ||
        oldWidget.logoItem?.englishTitle != widget.logoItem?.englishTitle ||
        oldWidget.logoItem?.titleLogo != widget.logoItem?.titleLogo) {
      _logoUrl = null;
      _loadedTitle = null;
      _loadLogo();
    }
  }

  Future<void> _loadLogo() async {
    if (_posterPrefs?.posterTitleStyle != PosterTitleStyle.artwork ||
        widget.logoItem == null ||
        _loadedTitle == widget.title ||
        !sl.isRegistered<TitleLogoService>()) {
      return;
    }
    final title = widget.title;
    final request = ++_request;
    _loadedTitle = title;
    try {
      final url = await sl<TitleLogoService>().logoForPoster(widget.logoItem!);
      if (mounted && request == _request && widget.title == title) {
        setState(() => _logoUrl = url);
      }
    } catch (_) {
      // Title artwork is optional; the regular title remains visible.
    }
  }

  @override
  void dispose() {
    PlaybackPrefs.posterRevision.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final addonOverlay = widget.addonOverlay
        ? widget.logoItem?.titleLogo
        : null;
    final addonUri = Uri.tryParse(addonOverlay ?? '');
    final validAddonLogo =
        addonUri != null &&
        addonUri.host.isNotEmpty &&
        (addonUri.scheme == 'https' || addonUri.scheme == 'http');
    final logo = validAddonLogo
        ? addonOverlay
        : _posterPrefs?.posterTitleStyle == PosterTitleStyle.artwork
        ? _logoUrl
        : null;
    if (logo != null) {
      return CachedNetworkImage(
        imageUrl: logo,
        cacheManager: AppImageCache.manager,
        width: widget.width,
        height: widget.maxHeight,
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        fadeInDuration: const Duration(milliseconds: 180),
        placeholder: (context, url) => _text(),
        errorWidget: (context, url, error) => _text(),
      );
    }
    return _text();
  }

  Widget _text() => Text(
    widget.title,
    maxLines: widget.maxLines,
    overflow: TextOverflow.ellipsis,
    style:
        widget.textStyle ??
        AppText.caption.copyWith(
          color: AppColors.textPrimary,
          fontWeight: widget.inside ? FontWeight.w700 : null,
        ),
  );
}

/// Height of exactly two lines of the poster title, derived from the style so a
/// change to the type scale carries here instead of silently clipping.
/// Round each line up because paragraph layout rounds fractional line heights.
double _posterTitleHeight(TextScaler textScaler) =>
    (textScaler.scale(AppText.caption.fontSize!) * AppText.caption.height!)
        .ceilToDouble() *
    2;

/// Gap between the poster art and its title.
const double _kTitleGap = 8;

/// Aspect ratio (width / height) for a grid cell holding a [PosterCard] of
/// [cellWidth]. The title area is reserved below the art unless placement puts
/// it inside the image.
///
/// Grids used to hardcode 0.62, which squashed the art to roughly 1.2:1 while
/// the horizontal rows drew a proper 1.5 — the same poster looked like a
/// different component depending on which screen you were on.
double posterCellHeight(
  double cellWidth, {
  TextScaler textScaler = TextScaler.noScaling,
  bool wide = false,
  bool titleInside = false,
  double? artAspectRatio,
}) {
  final artHeight = artAspectRatio != null
      ? cellWidth / artAspectRatio
      : wide
      ? cellWidth * 9 / 16
      : cellWidth * 1.5;
  final titleHeight = titleInside
      ? 0.0
      : _kTitleGap + _posterTitleHeight(textScaler);
  final height = artHeight + titleHeight;
  return titleHeight == 0 ? height : height.ceilToDouble();
}

double posterCellAspect(
  double cellWidth, {
  TextScaler textScaler = TextScaler.noScaling,
  bool wide = false,
  bool titleInside = false,
}) =>
    cellWidth /
    posterCellHeight(
      cellWidth,
      textScaler: textScaler,
      wide: wide,
      titleInside: titleInside,
    );

/// [posterCellAspect] for the app's standard poster grid: three columns, 16px
/// page padding, 12px between cells. Depends on the screen width, so it cannot
/// be a constant — which is exactly why the hardcoded 0.62 drifted.
double posterGridAspect(BuildContext context) {
  final width = posterGridCellWidth(context);
  final wide = posterLayout(context) == PosterCardLayout.wide;
  final titleInside = posterTitleInside(context, wide: wide);
  if (defaultTargetPlatform == TargetPlatform.windows) {
    return width /
        DesktopMediaCard.height(
          width,
          MediaQuery.textScalerOf(context).scale(1),
          wide: wide,
          titleInside: titleInside,
        );
  }
  return posterCellAspect(
    width,
    textScaler: MediaQuery.textScalerOf(context),
    wide: wide,
    titleInside: titleInside,
  );
}

/// Small frosted badge drawn over poster art (e.g. "SUB", "DUB", "MOVIE").
/// The score chip. A star rather than a bare number: "8.6" alone on a poster
/// reads as an episode count or a year just as easily as a rating.
///
/// Carried as 0-100 because that is what the catalogues agree on, shown out of
/// 10 because that is what people read a rating as.
class _ScoreTag extends StatelessWidget {
  const _ScoreTag(this.score);

  /// 0-100, as [MediaItem.score].
  final int score;

  String get _outOfTen => (score / 10).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 2, 5, 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 10, color: Color(0xFFFFC53D)),
          const SizedBox(width: 2),
          Text(
            _outOfTen,
            style: TextStyle(
              fontFamily: AppText.fontFamily,
              fontFamilyFallback: AppText.fontFamilyFallback,
              fontSize: 9,
              height: 1.1,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// Desktop columns use the available viewport, including a sidebar or sheet.
/// The phone keeps its established three-column layout.
SliverGridDelegate posterGridDelegate(BuildContext context) =>
    defaultTargetPlatform == TargetPlatform.windows
    ? DesktopPosterGridDelegate(
        wide: posterLayout(context) == PosterCardLayout.wide,
        titleInside: posterTitleInside(
          context,
          wide: posterLayout(context) == PosterCardLayout.wide,
        ),
        scale: posterCardScale(context),
        textScale: MediaQuery.textScalerOf(context).scale(1),
      )
    : SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: posterGridColumns(context),
        childAspectRatio: posterGridAspect(context),
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
      );

/// Fits more poster columns as desktop space grows, using poster-cell sizing
/// so cover proportions and caption space remain consistent across widths.
class DesktopPosterGridDelegate extends SliverGridDelegate {
  const DesktopPosterGridDelegate({
    this.wide = false,
    this.titleInside = false,
    this.scale = 1,
    this.textScale = 1,
  });
  final bool wide;
  final bool titleInside;
  final double scale;
  final double textScale;
  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    const gap = 12.0;
    final count =
        ((constraints.crossAxisExtent + gap) / ((wide ? 260 : 180) * scale))
            .ceil()
            .clamp(1, 30);
    final width = (constraints.crossAxisExtent - gap * (count - 1)) / count;
    final height = DesktopMediaCard.height(
      width,
      textScale,
      wide: wide,
      titleInside: titleInside,
    );
    return SliverGridRegularTileLayout(
      crossAxisCount: count,
      mainAxisStride: height + 28,
      crossAxisStride: width + gap,
      childMainAxisExtent: height,
      childCrossAxisExtent: width,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(covariant DesktopPosterGridDelegate oldDelegate) =>
      wide != oldDelegate.wide ||
      titleInside != oldDelegate.titleInside ||
      scale != oldDelegate.scale ||
      textScale != oldDelegate.textScale;
}

class _PosterTag extends StatelessWidget {
  const _PosterTag(this.text, {this.maxWidth});
  final String text;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth ?? double.infinity),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: AppText.fontFamily,
            fontFamilyFallback: AppText.fontFamilyFallback,
            fontSize: 9,
            height: 1.1,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

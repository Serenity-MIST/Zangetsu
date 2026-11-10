import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'artwork_quality.dart';
import 'native_cover_provider.dart';
import 'progressive_artwork.dart';

/// One Windows media-card language across Home, library, search and catalogues.
/// Data/actions stay owned by callers; only presentation and pointer states live here.
class DesktopMediaCard extends StatelessWidget {
  const DesktopMediaCard({
    super.key,
    required this.title,
    this.image,
    this.headers,
    this.onTap,
    this.onMenu,
    this.score,
    this.rank,
    this.badges = const [],
    this.showTitle = true,
    this.titleInside = false,
    this.titleWidget,
    this.artworkKey,
  });
  final String title;
  final String? image;
  final Map<String, String>? headers;
  final VoidCallback? onTap, onMenu;
  final int? score, rank;
  final List<String> badges;
  final bool showTitle, titleInside;
  final Widget? titleWidget;
  final Key? artworkKey;
  static double height(
    double width,
    double textScale, {
    bool wide = false,
    bool titleInside = false,
  }) => width * (wide ? 9 / 16 : .94) + (titleInside ? 0 : textScale * 56);
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final textHeight = MediaQuery.textScalerOf(context).scale(56);
      // Captions retain the same click/right-click actions as the artwork.
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onSecondaryTap: onMenu,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DesktopMediaSurface(
                key: artworkKey,
                onTap: onTap,
                onMenu: onMenu,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DesktopMediaArtwork(
                      url: image,
                      headers: headers,
                      width: bounds.maxWidth,
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Color(0x66000000), Colors.transparent],
                          stops: [0, .5],
                        ),
                      ),
                    ),
                    if (titleInside && showTitle)
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: 8,
                        child:
                            titleWidget ??
                            Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                      ),
                    if (badges.isNotEmpty)
                      Positioned(
                        left: 6,
                        top: titleInside ? 6 : null,
                        bottom: titleInside ? null : 6,
                        right: 6,
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 3,
                          children: [
                            for (final badge in badges)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xC0101318),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(
                                  badge,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 9,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (showTitle && !titleInside)
              SizedBox(
                height: textHeight,
                child: Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (rank != null) ...[
                        Text(
                          '$rank',
                          style: const TextStyle(
                            fontFamily: 'Georgia',
                            fontSize: 23,
                            height: 1,
                          ),
                        ),
                        const SizedBox(width: 9),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            titleWidget ??
                                Text(
                                  title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    height: 1.2,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                            if (score != null) ...[
                              const SizedBox(height: 4),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SvgPicture.asset(
                                    'assets/icons/lucide/star.svg',
                                    width: 10,
                                    height: 10,
                                    colorFilter: const ColorFilter.mode(
                                      Color(0xFFEAC458),
                                      BlendMode.srcIn,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    (score! / 10).toStringAsFixed(1),
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: Color(0xFFADB2BE),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// Fresh source-aware artwork primitive, preserving protected-source headers.
class DesktopMediaArtwork extends StatelessWidget {
  const DesktopMediaArtwork({
    super.key,
    required this.url,
    required this.width,
    this.headers,
  });
  final String? url;
  final double width;
  final Map<String, String>? headers;
  @override
  Widget build(BuildContext context) {
    if (url?.isNotEmpty != true) {
      return const ColoredBox(color: Color(0xFF20252D));
    }
    final previewUrl = artworkPreviewUrl(url!);
    final fullUrl = desktopArtworkUrl(url!);
    final targetWidth = artworkDecodeWidth(
      width,
      MediaQuery.devicePixelRatioOf(context),
    );
    final staged = previewUrl != fullUrl;
    return ProgressiveArtwork(
      preview: ResizeImage(
        nativeCoverProvider(previewUrl, headers),
        width: staged ? math.min(targetWidth, 320) : targetWidth,
      ),
      full: staged
          ? ResizeImage(
              nativeCoverProvider(fullUrl, headers),
              width: targetWidth,
            )
          : null,
    );
  }
}

/// Shared motion only within this new Home design, with reduced-motion support.
class DesktopMediaSurface extends StatefulWidget {
  const DesktopMediaSurface({
    super.key,
    required this.child,
    this.onTap,
    this.onMenu,
  });
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onMenu;
  @override
  State<DesktopMediaSurface> createState() => DesktopMediaSurfaceState();
}

/// Owns only the pointer/focus highlight, never media or library state.
class DesktopMediaSurfaceState extends State<DesktopMediaSurface> {
  bool _active = false;
  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 160),
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: const Color(0xFF12161B),
      borderRadius: BorderRadius.circular(11),
      border: Border.all(
        color: _active ? const Color(0xFFFF3656) : const Color(0xFF2A3038),
      ),
    ),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onSecondaryTap: widget.onMenu,
        onHover: (v) => setState(() => _active = v),
        onFocusChange: (v) => setState(() => _active = v),
        child: widget.child,
      ),
    ),
  );
}

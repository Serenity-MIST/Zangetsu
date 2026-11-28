import 'package:flutter/material.dart';

import '../../core/playback/playback_prefs.dart' show PosterCardLayout;
import '../../core/theme/app_colors.dart';
import '../../core/ui/poster_card.dart';

/// Windows loading placeholders that are EXACTLY the size of the real result
/// cards, so nothing jumps from big boxes to small posters when results land.
///
/// The old [SkeletonGrid] is a fixed three-column grid, which on a wide
/// window drew a few huge boxes that then shrank into the real posters. This
/// grid uses the same [posterGridDelegate] as the results grid, and each cell
/// is shaped like a [DesktopMediaCard]: rounded art filling the cell plus,
/// when titles sit below the art, a caption strip of the same height.
///
/// One shared animation drives every cell (like [SkeletonGrid]); it holds
/// still when the system asks for reduced motion.
class DesktopPosterSkeletonGrid extends StatelessWidget {
  const DesktopPosterSkeletonGrid({
    super.key,
    this.count = 12,
    this.padding = const EdgeInsets.fromLTRB(16, 6, 16, 0),
  });

  /// How many placeholder cards to draw.
  final int count;

  /// Same padding as the results grid, so the columns line up.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final wide = posterLayout(context) == PosterCardLayout.wide;
    final captionBelow = !posterTitleInside(context, wide: wide);
    return _Shimmer(
      builder: (context, opacity) => GridView.builder(
        key: const ValueKey('desktop-poster-skeleton-grid'),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: padding,
        gridDelegate: posterGridDelegate(context),
        itemCount: count,
        itemBuilder: (context, i) => DesktopPosterSkeletonCard(
          key: ValueKey('desktop-poster-skeleton-$i'),
          opacity: opacity,
          captionBelow: captionBelow,
        ),
      ),
    );
  }
}

/// A horizontal row of placeholder cards at the real row-card size
/// ([posterRowWidth] x [posterRowHeight]), for sources laid out as rows.
class DesktopPosterSkeletonRow extends StatelessWidget {
  const DesktopPosterSkeletonRow({super.key, this.count = 8});

  /// How many placeholder cards to draw (extra ones are clipped).
  final int count;

  @override
  Widget build(BuildContext context) {
    final width = posterRowWidth(context);
    final height = posterRowHeight(context);
    final wide = posterLayout(context) == PosterCardLayout.wide;
    final captionBelow = !posterTitleInside(context, wide: wide);
    return _Shimmer(
      builder: (context, opacity) => SizedBox(
        key: const ValueKey('desktop-poster-skeleton-row'),
        height: height,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: count,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (context, i) => SizedBox(
            width: width,
            child: DesktopPosterSkeletonCard(
              opacity: opacity,
              captionBelow: captionBelow,
            ),
          ),
        ),
      ),
    );
  }
}

/// One placeholder card: art box (radius 11, like DesktopMediaSurface) and,
/// when [captionBelow], two text bars in a strip as tall as the real caption.
class DesktopPosterSkeletonCard extends StatelessWidget {
  const DesktopPosterSkeletonCard({
    super.key,
    required this.opacity,
    required this.captionBelow,
  });

  /// Current shimmer strength (0..1) from the shared animation.
  final double opacity;

  /// True when titles sit under the art (the Windows default).
  final bool captionBelow;

  @override
  Widget build(BuildContext context) {
    final fill = AppColors.surface2.withValues(alpha: opacity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(11),
            ),
            child: const SizedBox.expand(),
          ),
        ),
        if (captionBelow)
          SizedBox(
            // Same caption height DesktopMediaCard reserves.
            height: MediaQuery.textScalerOf(context).scale(56),
            child: Padding(
              padding: const EdgeInsets.only(top: 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FractionallySizedBox(widthFactor: 0.8, child: _bar(fill, 10)),
                  const SizedBox(height: 7),
                  FractionallySizedBox(widthFactor: 0.45, child: _bar(fill, 8)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// A rounded text placeholder bar.
  Widget _bar(Color color, double height) => Container(
    height: height,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(4),
    ),
  );
}

/// One shared pulse for a whole skeleton block.
class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.builder});

  /// Builds the block for the current opacity.
  final Widget Function(BuildContext context, double opacity) builder;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  late final Animation<double> _anim = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeInOut,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion: hold a steady mid tone instead of pulsing.
    if (MediaQuery.disableAnimationsOf(context)) {
      _ctrl
        ..stop()
        ..value = 0.5;
    } else if (!_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: _anim,
      builder: (context, _) =>
          widget.builder(context, 0.3 + 0.25 * _anim.value),
    ),
  );
}

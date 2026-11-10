import 'package:flutter/material.dart';

/// Paints a lightweight preview before requesting the full image. Full-image
/// failure never removes a usable preview, and stale callbacks cannot upgrade
/// a different card after its artwork changes.
class ProgressiveArtwork extends StatefulWidget {
  const ProgressiveArtwork({super.key, required this.preview, this.full, this.fallback});
  final ImageProvider preview;
  final ImageProvider? full;

  /// Optional offline icon/poster when the preview cannot be fetched.
  final Widget? fallback;
  @override
  State<ProgressiveArtwork> createState() => _ProgressiveArtworkState();
}

/// Starts the full request only after preview decode (or a preview failure).
class _ProgressiveArtworkState extends State<ProgressiveArtwork> {
  bool _upgrade = false;
  bool _scheduled = false;
  int _generation = 0;

  @override
  void didUpdateWidget(covariant ProgressiveArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preview != widget.preview || oldWidget.full != widget.full) {
      _generation++;
      _upgrade = false;
      _scheduled = false;
    }
  }

  void _previewFinished() {
    if (_upgrade || _scheduled || widget.full == null) return;
    _scheduled = true;
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      setState(() => _upgrade = true);
    });
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      const ColoredBox(color: Color(0xFF20252D)),
      Image(
        image: widget.preview,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        frameBuilder: (context, child, frame, synchronous) {
          if (frame != null) _previewFinished();
          return child;
        },
        errorBuilder: (_, _, _) {
          _previewFinished();
          return widget.fallback ?? const SizedBox.shrink();
        },
      ),
      if (_upgrade && widget.full != null)
        Image(
          image: widget.full!,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          frameBuilder: (context, child, frame, synchronous) => AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 180),
            child: child,
          ),
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
    ],
  );
}

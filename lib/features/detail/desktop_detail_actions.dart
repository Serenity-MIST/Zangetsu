import 'package:flutter/material.dart';

/// Desktop title actions share one row; narrower windows keep readable
/// buttons and move the source selector below them.
class DesktopDetailActions extends StatelessWidget {
  const DesktopDetailActions({
    super.key,
    required this.play,
    this.download,
    this.source,
  });
  final Widget play;
  final Widget? download;
  final Widget? source;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth >= 680) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 180, child: play),
            if (download != null) ...[
              const SizedBox(width: 10),
              SizedBox(width: 180, child: download),
            ],
            if (source != null) ...[
              const SizedBox(width: 16),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: source!,
                ),
              ),
            ],
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: play),
              if (download != null) ...[
                const SizedBox(width: 10),
                Expanded(child: download!),
              ],
            ],
          ),
          if (source != null) ...[const SizedBox(height: 8), source!],
        ],
      );
    },
  );
}

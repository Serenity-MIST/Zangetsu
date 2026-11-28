import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:cue/cue.dart';
import '../../core/desktop/desktop_context_menu.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/desktop_docked_panel.dart' show desktopPanelsEnabled;
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';

class DownloadEntrance extends StatelessWidget {
  const DownloadEntrance({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return Cue.onMount(
      motion: const CueMotion.easeOut(Duration(milliseconds: 220)),
      acts: const [Act.fadeIn(from: .6), Act.translateY(from: 8)],
      child: RepaintBoundary(child: child),
    );
  }
}

class DownloadArtwork extends StatelessWidget {
  const DownloadArtwork({
    super.key,
    required this.heroTag,
    this.cover,
    this.coverHeaders,
    this.radius = 12,
  });
  final Object heroTag;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final double radius;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final decodeWidth =
          (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context))
              .round()
              .clamp(1, 720);
      final artwork = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: ColoredBox(
          color: AppColors.surface2,
          child: cover?.isNotEmpty == true
              ? CachedNetworkImage(
                  imageUrl: cover!,
                  httpHeaders: coverHeaders,
                  fit: BoxFit.cover,
                  memCacheWidth: decodeWidth,
                  placeholder: (_, _) => const SizedBox.expand(),
                  errorWidget: (_, _, _) => const Icon(
                    Icons.movie_outlined,
                    color: AppColors.textTertiary,
                  ),
                )
              : const Icon(Icons.movie_outlined, color: AppColors.textTertiary),
        ),
      );
      if (MediaQuery.disableAnimationsOf(context)) return artwork;
      return Hero(
        tag: heroTag,
        transitionOnUserGestures: true,
        // Keep the grid's decoded image throughout the flight.
        flightShuttleBuilder: (_, _, direction, from, to) =>
            ((direction == HeroFlightDirection.push ? from : to).widget as Hero)
                .child,
        child: artwork,
      );
    },
  );
}

class DownloadLibraryPoster extends StatelessWidget {
  const DownloadLibraryPoster({
    super.key,
    required this.title,
    required this.heroTag,
    this.cover,
    this.coverHeaders,
    required this.countLabel,
    required this.sizeLabel,
    this.status,
    this.progress,
    this.isDownloading = false,
    required this.onOpen,
    required this.onDelete,
    required this.deleteTooltip,
  });
  final String title;
  final Object heroTag;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final String countLabel;
  final String sizeLabel;
  final String? status;
  final double? progress;
  final bool isDownloading;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  final String deleteTooltip;

  /// Windows menu rows, shared by the overflow button, right-click and the
  /// Menu key / Shift+F10, so all three offer the same actions.
  List<DesktopMenuItem<Object?>> _desktopMenuItems(AppLocalizations l10n) => [
    DesktopMenuItem(
      label: l10n.open,
      icon: Icons.open_in_new_rounded,
      onTap: onOpen,
    ),
    const DesktopMenuItem.divider(),
    DesktopMenuItem(
      label: l10n.deleteAll,
      icon: Icons.delete_outline_rounded,
      destructive: true,
      onTap: onDelete,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Right-click / Menu key menu on Windows; the region returns the poster
    // untouched on phone and TV.
    return DesktopContextMenuRegion(
      items: () => _desktopMenuItems(l10n),
      child: _poster(context, l10n),
    );
  }

  /// The poster itself: artwork, title row with overflow, size and status.
  Widget _poster(BuildContext context, AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 2 / 3,
          child: Material(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onOpen,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DownloadArtwork(
                    heroTag: heroTag,
                    cover: cover,
                    coverHeaders: coverHeaders,
                  ),
                  PositionedDirectional(
                    start: 6,
                    bottom: 8,
                    child: Tooltip(
                      message: countLabel,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppColors.bg.withValues(alpha: .85),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 3,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.download_rounded, size: 12),
                              const SizedBox(width: 3),
                              Text(
                                countLabel,
                                style: AppText.caption.copyWith(
                                  fontSize: 10,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (progress != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: progress!.clamp(0, 1),
                        minHeight: 3,
                        color: AppColors.accent,
                        backgroundColor: AppColors.surface2,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: InkWell(
                onTap: onOpen,
                child: Text(
                  title,
                  style: AppText.body.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            // Windows: a hoverable overflow button that opens the compact
            // graphite menu under itself (same items as right-click).
            if (desktopPanelsEnabled)
              SizedBox(
                width: 28,
                height: 32,
                child: Builder(
                  builder: (buttonContext) => IconButton(
                    key: const ValueKey('download-poster-overflow'),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
                    icon: const Icon(
                      Icons.more_vert_rounded,
                      size: 18,
                      color: AppColors.textSecondary,
                    ),
                    onPressed: () => showDesktopContextMenu<Object?>(
                      context,
                      anchor: buttonContext,
                      items: _desktopMenuItems(l10n),
                    ),
                  ),
                ),
              )
            else
            // Phone keeps the Material popup menu exactly as before.
            SizedBox(
              width: 24,
              height: 32,
              child: PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                tooltip: deleteTooltip,
                icon: const Icon(
                  Icons.more_vert_rounded,
                  size: 18,
                  color: AppColors.textSecondary,
                ),
                onSelected: (_) => onDelete(),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        const Icon(Icons.delete_outline_rounded, size: 20),
                        const SizedBox(width: 10),
                        Text(l10n.deleteAll),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        Text(sizeLabel, style: AppText.caption.copyWith(fontSize: 10)),
        if (status != null) ...[
          const SizedBox(height: 3),
          Text(
            status!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(
              fontSize: 10,
              color: isDownloading ? AppColors.accent : AppColors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

class DownloadTitleSummary extends StatelessWidget {
  const DownloadTitleSummary({
    super.key,
    required this.title,
    required this.heroTag,
    required this.subtitle,
    this.cover,
    this.coverHeaders,
    required this.onDelete,
    required this.deleteTooltip,
    this.actions = const [],
  });
  final String title;
  final Object heroTag;
  final String subtitle;

  /// Buttons under the subtitle (Windows: Continue and Open show page, dl-8).
  /// Empty on phone, so its header is unchanged.
  final List<Widget> actions;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final VoidCallback? onDelete;
  final String deleteTooltip;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
    child: Row(
      children: [
        SizedBox(
          width: 56,
          height: 80,
          child: DownloadArtwork(
            heroTag: heroTag,
            cover: cover,
            coverHeaders: coverHeaders,
            radius: 10,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.headline.copyWith(fontSize: 17),
              ),
              const SizedBox(height: 6),
              Text(subtitle, style: AppText.caption.copyWith(fontSize: 11)),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
            ],
          ),
        ),
        if (onDelete != null)
          IconButton(
            onPressed: onDelete,
            tooltip: deleteTooltip,
            icon: const Icon(
              Icons.delete_outline_rounded,
              size: 21,
              color: AppColors.textSecondary,
            ),
          ),
      ],
    ),
  );
}

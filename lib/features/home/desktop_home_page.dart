import '../../core/ui/desktop_media_card.dart';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_item.dart';
import '../../core/ui/featured_hero.dart' show HeroMeta;

const _ink = Color(0xFF0D1013);
const _muted = Color(0xFFADB2BE);
const _red = Color(0xFFFF3656);

/// Fresh Windows Home view model. It carries real progress and actions, never
/// presentation widgets from the phone Home or the previous desktop layout.
class DesktopHomeResume {
  const DesktopHomeResume({
    required this.title,
    required this.subtitle,
    required this.progress,
    required this.open,
    this.menu,
    this.image,
    this.headers,
    this.remaining,
  });
  final String title, subtitle;
  final double progress;
  final String? image, remaining;
  final Map<String, String>? headers;
  final VoidCallback open;
  final VoidCallback? menu;
}

/// A library release with trustworthy text supplied by the data adapter.
class DesktopHomeRelease {
  const DesktopHomeRelease({
    required this.title,
    required this.subtitle,
    required this.open,
    this.image,
    this.headers,
  });
  final String title, subtitle;
  final String? image;
  final Map<String, String>? headers;
  final VoidCallback open;
}

/// Entirely new desktop composition based on the approved screenshot. Legacy
/// Home cards, banner styles, mobile headers and shelf widgets never enter it.
class DesktopHomePage extends StatefulWidget {
  const DesktopHomePage({
    super.key,
    required this.featured,
    required this.sections,
    required this.resume,
    required this.releases,
    required this.reading,
    required this.onOpen,
    required this.onPlay,
    required this.onMenu,
    required this.onSection,
    required this.onHistory,
    required this.onReleases,
    required this.onRefresh,
    required this.meta,
    required this.playLabel,
    this.loading = false,
    this.error,
    this.onCatalogue,
    this.onVerify,
    this.onReconnect,
    this.reconnectLabel = 'Reconnect to sync',
    this.footer,
  });
  final List<MediaItem> featured;
  final List<HomeSection> sections;
  final List<DesktopHomeResume> resume;
  final List<DesktopHomeRelease> releases;
  final bool reading, loading;
  final String? error;
  final ValueChanged<MediaItem> onOpen, onPlay, onMenu;
  final ValueChanged<HomeSection> onSection;
  final VoidCallback onHistory, onReleases;
  final Future<void> Function() onRefresh;
  final Future<HeroMeta?> Function(MediaItem) meta;
  final String Function(MediaItem) playLabel;
  final VoidCallback? onCatalogue;
  final VoidCallback? onVerify;
  final VoidCallback? onReconnect;
  final String reconnectLabel;
  final Widget? footer;
  @override
  State<DesktopHomePage> createState() => _DesktopHomePageState();
}

/// Keeps scroll and featured selection local without copying any account data.
class _DesktopHomePageState extends State<DesktopHomePage> {
  final _scroll = ScrollController();
  int _featuredIndex = 0;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: _ink,
    child: LayoutBuilder(
      builder: (context, bounds) {
        final width = bounds.maxWidth;
        final scaled = MediaQuery.textScalerOf(context).scale(14) > 21;
        final wide = width >= 1000 && !scaled;
        final hero = widget.featured.isEmpty
            ? null
            : widget.featured[_featuredIndex % widget.featured.length];
        final shelves = [...widget.sections];
        // The reference leads with Trending. Keep every other real source section.
        final trending = shelves.indexWhere(
          (s) => s.title.toLowerCase().contains('trending'),
        );
        if (trending > 0) shelves.insert(0, shelves.removeAt(trending));
        return Scrollbar(
          controller: _scroll,
          child: CustomScrollView(
            controller: _scroll,
            key: const PageStorageKey('desktop-reference-home'),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverList.list(
                  children: [
                    if (widget.onReconnect != null) ...[
                      _SessionNotice(
                        label: widget.reconnectLabel,
                        onReconnect: widget.onReconnect!,
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (hero != null)
                      _CinematicHero(
                        item: hero,
                        meta: widget.meta(hero),
                        height: scaled
                            ? 520
                            : ((width - 32) * .226).clamp(280, 350),
                        onPlay: () => widget.onPlay(hero),
                        onDetails: () => widget.onOpen(hero),
                        playLabel: widget.playLabel(hero),
                        onCatalogue: widget.onCatalogue,
                        onNext: widget.featured.length > 1
                            ? () => setState(
                                () => _featuredIndex =
                                    (_featuredIndex + 1) %
                                    widget.featured.length,
                              )
                            : null,
                      )
                    else
                      _HomeFeedback(
                        loading: widget.loading,
                        message: widget.error ?? 'Your catalogue is empty.',
                        onRetry: widget.onRefresh,
                        onVerify: widget.onVerify,
                        onCatalogue: widget.onCatalogue,
                      ),
                    const SizedBox(height: 12),
                    if (widget.resume.isNotEmpty || widget.releases.isNotEmpty)
                      wide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 77,
                                  child: _ResumeShelf(
                                    items: widget.resume,
                                    reading: widget.reading,
                                    onAll: widget.onHistory,
                                  ),
                                ),
                                const SizedBox(width: 20),
                                Expanded(
                                  flex: 23,
                                  child: _LibraryReleasePanel(
                                    items: widget.releases,
                                    onAll: widget.onReleases,
                                  ),
                                ),
                              ],
                            )
                          : Column(
                              children: [
                                _ResumeShelf(
                                  items: widget.resume,
                                  reading: widget.reading,
                                  onAll: widget.onHistory,
                                ),
                                if (widget.releases.isNotEmpty)
                                  _LibraryReleasePanel(
                                    items: widget.releases,
                                    onAll: widget.onReleases,
                                  ),
                              ],
                            ),
                    for (final section in shelves.where(
                      (s) => s.items.isNotEmpty,
                    )) ...[
                      const SizedBox(height: 16),
                      _RankedPosterShelf(
                        section: section,
                        onAll: () => widget.onSection(section),
                        onOpen: widget.onOpen,
                        onMenu: widget.onMenu,
                        ranked:
                            identical(section, shelves.first) &&
                            section.title.toLowerCase().contains('trending'),
                      ),
                    ],
                    if (widget.loading && hero != null)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: LinearProgressIndicator(
                          minHeight: 2,
                          color: _red,
                        ),
                      ),
                    if (widget.footer != null) ...[
                      const SizedBox(height: 20),
                      widget.footer!,
                    ],
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

/// New typography-led feature with real wide artwork and bounded description.
class _CinematicHero extends StatelessWidget {
  const _CinematicHero({
    required this.item,
    required this.meta,
    required this.height,
    required this.onPlay,
    required this.onDetails,
    required this.playLabel,
    this.onCatalogue,
    this.onNext,
  });
  final MediaItem item;
  final Future<HeroMeta?> meta;
  final double height;
  final VoidCallback onPlay, onDetails;
  final VoidCallback? onCatalogue, onNext;
  final String playLabel;
  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('desktop-home-feature'),
    height: height,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFF30343A)),
    ),
    child: LayoutBuilder(
      builder: (context, bounds) => Stack(
        fit: StackFit.expand,
        children: [
          DesktopMediaArtwork(
            url: item.banner ?? item.cover,
            headers: item.coverHeaders,
            width: bounds.maxWidth,
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0xFA080B0E),
                  Color(0xD9080B0E),
                  Color(0x16080B0E),
                ],
                stops: [0, .32, 1],
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.center,
                colors: [Color(0x85080B0E), Colors.transparent],
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: bounds.maxWidth < 700 ? 22 : 42,
                vertical: 22,
              ),
              child: SizedBox(
                width: bounds.maxWidth < 700
                    ? bounds.maxWidth - 44
                    : bounds.maxWidth * .43,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      onTap: onCatalogue,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          'ZANGETSU PRESENTS',
                          style: TextStyle(
                            fontSize: 9,
                            letterSpacing: 3.3,
                            color: Color(0xFFB9BDC7),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Georgia',
                        fontSize: bounds.maxWidth < 700 ? 29 : 40,
                        height: 1.02,
                        letterSpacing: -.8,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFFF5F5F7),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Flexible(
                      child: FutureBuilder<HeroMeta?>(
                        future: meta,
                        builder: (context, snap) {
                          final description = snap.data?.description
                              ?.replaceAll(RegExp(r'<[^>]*>'), '')
                              .trim();
                          return Text(
                            description?.isNotEmpty == true
                                ? description!
                                : (snap.data?.genres ?? item.genres)
                                      .take(3)
                                      .join(' · '),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              height: 1.5,
                              color: _muted,
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        _HeroAction(
                          label: playLabel,
                          icon: 'play',
                          primary: true,
                          onTap: onPlay,
                        ),
                        _HeroAction(label: 'Details', onTap: onDetails),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (onNext != null)
            Positioned(
              right: 10,
              bottom: 10,
              child: _HomeIconButton(
                icon: 'chevron-right',
                label: 'Next feature',
                onTap: onNext!,
              ),
            ),
        ],
      ),
    ),
  );
}

/// Newly composed landscape resume shelf; no legacy ContinueCard is used.
class _ResumeShelf extends StatelessWidget {
  const _ResumeShelf({
    required this.items,
    required this.reading,
    required this.onAll,
  });
  final List<DesktopHomeResume> items;
  final bool reading;
  final VoidCallback onAll;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _SectionHeading(
        title: reading ? 'Continue reading' : 'Continue watching',
        onAll: onAll,
      ),
      if (items.isEmpty)
        const SizedBox(
          height: 150,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Your next story starts here.',
              style: TextStyle(color: _muted),
            ),
          ),
        ),
      if (items.isNotEmpty)
        LayoutBuilder(
          builder: (context, bounds) {
            final count = bounds.maxWidth >= 620
                ? 3
                : bounds.maxWidth >= 420
                ? 2
                : 1;
            final width = (bounds.maxWidth - (count - 1) * 12) / count;
            final textHeight = MediaQuery.textScalerOf(context).scale(52);
            return _HorizontalShelf(
              height: width * .36 + textHeight,
              width: width,
              count: items.length,
              gap: 12,
              builder: (index) {
                final entry = items[index];
                return DesktopMediaSurface(
                  key: ValueKey('desktop-home-resume-$index'),
                  onTap: entry.open,
                  onMenu: entry.menu,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            DesktopMediaArtwork(
                              url: entry.image,
                              headers: entry.headers,
                              width: width,
                            ),
                            if (entry.remaining != null)
                              Positioned(
                                top: 6,
                                right: 6,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xCC15191F),
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                  child: Text(
                                    entry.remaining!,
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                ),
                              ),
                            Positioned(
                              left: 8,
                              right: 8,
                              bottom: 2,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: entry.progress.clamp(0, 1),
                                  minHeight: 3,
                                  color: _red,
                                  backgroundColor: const Color(0xFF45464C),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(9, 7, 9, 7),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    entry.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '${(entry.progress.clamp(0, 1) * 100).round()}%',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: _muted,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              entry.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: _muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
    ],
  );
}

/// Quiet compact release list. Unknown dates/episodes are never fabricated.
class _LibraryReleasePanel extends StatelessWidget {
  const _LibraryReleasePanel({required this.items, required this.onAll});
  final List<DesktopHomeRelease> items;
  final VoidCallback onAll;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeading(title: 'New from your list', onAll: onAll),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Text(
              'No new releases available from your connected library.',
              style: TextStyle(fontSize: 11, color: _muted, height: 1.5),
            ),
          ),
        for (final item in items.take(3))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              onTap: item.open,
              borderRadius: BorderRadius.circular(8),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: SizedBox(
                      width: 40,
                      height: 48,
                      child: DesktopMediaArtwork(
                        url: item.image,
                        headers: item.headers,
                        width: 40,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          item.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10, color: _red),
                        ),
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
}

/// A new ranked poster shelf with consistent geometry, independent of old
/// mobile poster preferences. All entries remain reachable horizontally.
class _RankedPosterShelf extends StatelessWidget {
  const _RankedPosterShelf({
    required this.section,
    required this.onAll,
    required this.onOpen,
    required this.onMenu,
    required this.ranked,
  });
  final HomeSection section;
  final VoidCallback onAll;
  final ValueChanged<MediaItem> onOpen, onMenu;
  final bool ranked;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      _SectionHeading(title: section.title, onAll: onAll),
      LayoutBuilder(
        builder: (context, bounds) {
          final count = bounds.maxWidth >= 1050
              ? 7
              : math.max(2, (bounds.maxWidth / 165).floor());
          final width = (bounds.maxWidth - (count - 1) * 12) / count;
          final textHeight = MediaQuery.textScalerOf(context).scale(56);
          return _HorizontalShelf(
            height: width * .94 + textHeight,
            width: width,
            count: section.items.length,
            gap: 12,
            builder: (index) {
              final item = section.items[index];
              return DesktopMediaCard(
                artworkKey:ValueKey('desktop-home-poster-${section.title}-$index'),
                title:item.title,image:item.cover,headers:item.coverHeaders,
                score:item.score,rank:ranked ? index+1 : null,
                onTap:()=>onOpen(item),onMenu:()=>onMenu(item));
            },
          );
        },
      ),
    ],
  );
}

/// Owns horizontal input; vertical wheel events continue to the Home scroller.
class _HorizontalShelf extends StatefulWidget {
  const _HorizontalShelf({
    required this.height,
    required this.width,
    required this.count,
    required this.gap,
    required this.builder,
  });
  final double height, width, gap;
  final int count;
  final Widget Function(int) builder;
  @override
  State<_HorizontalShelf> createState() => _HorizontalShelfState();
}

/// Disposes the shelf controller independently from the vertical Home scroller.
class _HorizontalShelfState extends State<_HorizontalShelf> {
  final _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: widget.height,
    child: ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: const {
          PointerDeviceKind.mouse,
          PointerDeviceKind.touch,
          PointerDeviceKind.trackpad,
        },
      ),
      child: Scrollbar(
        controller: _scroll,
        child: ListView.separated(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          itemCount: widget.count,
          separatorBuilder: (_, _) => SizedBox(width: widget.gap),
          itemBuilder: (_, index) =>
              SizedBox(width: widget.width, child: widget.builder(index)),
        ),
      ),
    ),
  );
}

/// Bundled official Lucide SVG; the surrounding button owns its semantics.
class DesktopHomeIcon extends StatelessWidget {
  const DesktopHomeIcon(
    this.name, {
    super.key,
    this.size = 18,
    this.color = Colors.white,
  });
  final String name;
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SvgPicture.asset(
      'assets/icons/lucide/$name.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    ),
  );
}

/// Section title and a single Lucide browse action.
class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.onAll});
  final String title;
  final VoidCallback onAll;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.textScalerOf(context).scale(34).clamp(34, 80),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        _HomeIconButton(
          icon: 'chevron-right',
          label: 'See all $title',
          onTap: onAll,
        ),
      ],
    ),
  );
}

/// Compact accessible Lucide action target.
class _HomeIconButton extends StatelessWidget {
  const _HomeIconButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final String icon, label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: label,
    onPressed: onTap,
    icon: DesktopHomeIcon(icon, size: 17, color: _muted),
  );
}

/// New rectangular hero action with the reference corner radius.
class _HeroAction extends StatelessWidget {
  const _HeroAction({
    required this.label,
    required this.onTap,
    this.icon,
    this.primary = false,
  });
  final String label;
  final String? icon;
  final VoidCallback onTap;
  final bool primary;
  @override
  Widget build(BuildContext context) => Material(
    color: primary ? _red : const Color(0x8013181E),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(color: primary ? _red : const Color(0xFF727881)),
    ),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 11),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              DesktopHomeIcon(icon!, size: 16),
              const SizedBox(width: 10),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 2,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Restores account recovery in the new desktop design without signing out or
/// touching cached library data. The owner controls visibility from auth state.
class _SessionNotice extends StatelessWidget {
  const _SessionNotice({required this.label, required this.onReconnect});
  final String label;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFF21161B),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFF57303C)),
    ),
    child: Wrap(
      spacing: 16,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const DesktopHomeIcon('user-round', size: 18, color: _red),
        const Text(
          'Your session expired. Reconnect to sync your library.',
          style: TextStyle(color: _muted, fontSize: 13),
        ),
        _HeroAction(label: label, onTap: onReconnect),
      ],
    ),
  );
}

/// Explicit loading/empty/error state with a recoverable action.
class _HomeFeedback extends StatelessWidget {
  const _HomeFeedback({
    required this.loading,
    required this.message,
    required this.onRetry,
    this.onVerify,
    this.onCatalogue,
  });
  final bool loading;
  final String message;
  final Future<void> Function() onRetry;
  final VoidCallback? onVerify;
  final VoidCallback? onCatalogue;
  @override
  Widget build(BuildContext context) => ConstrainedBox(
    // Recovery text and actions must grow with Windows text scaling. The
    // parent Home scroll view owns overflow instead of clipping this panel.
    constraints: const BoxConstraints(minHeight: 240),
    child: Center(
      child: loading
          ? const CircularProgressIndicator(color: _red)
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(message, style: const TextStyle(color: _muted)),
                const SizedBox(height: 16),
                if (onVerify != null) ...[
                  _HeroAction(
                    label: 'Verify website',
                    icon: 'info',
                    onTap: onVerify!,
                  ),
                  const SizedBox(height: 10),
                ],
                // A failed source must not hide the route to another catalogue.
                if (onCatalogue != null) ...[
                  _HeroAction(
                    label: 'Choose catalogue',
                    icon: 'blocks',
                    onTap: onCatalogue!,
                  ),
                  const SizedBox(height: 10),
                ],
                _HeroAction(
                  label: 'Refresh catalogue',
                  icon: 'rotate-cw',
                  onTap: onRetry,
                ),
              ],
            ),
    ),
  );
}

/// Newly styled desktop action menu; existing controllers supply its actions.
Future<void> showDesktopHomeMenu(
  BuildContext context, {
  required String title,
  required List<({String label, String icon, VoidCallback run})> actions,
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) => Dialog(
    backgroundColor: const Color(0xFF151A20),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: Color(0xFF353C46)),
    ),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 420,
        maxHeight: MediaQuery.sizeOf(context).height * .8,
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final action in actions)
                TextButton(
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                    action.run();
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.all(14),
                  ),
                  child: Row(
                    children: [
                      DesktopHomeIcon(action.icon, color: _muted),
                      const SizedBox(width: 14),
                      Expanded(child: Text(action.label)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  ),
);

/// Secondary routes stay reachable without restoring the old oversized cards.
class DesktopHomeUtilities extends StatelessWidget {
  const DesktopHomeUtilities({super.key, required this.actions});
  final List<({String label, String icon, VoidCallback run})> actions;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 16,
    runSpacing: 8,
    children: [
      for (final action in actions)
        TextButton.icon(
          onPressed: action.run,
          icon: DesktopHomeIcon(action.icon, size: 15, color: _muted),
          label: Text(
            action.label,
            style: const TextStyle(fontSize: 11, color: _muted),
          ),
        ),
    ],
  );
}

import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../di/injector.dart';
import '../mode/content_mode.dart';
import '../mode/content_mode_cubit.dart';
import '../theme/app_colors.dart';
import '../zmode/zmode_prefs.dart';
import '../../features/home/cubit/home_cubit.dart';
import '../../features/shell/mode_bar.dart';
import 'desktop_catalogue_switch.dart';
import 'desktop_chrome_colors.dart';
import 'desktop_context_menu.dart';
import '../ui/desktop_svg.dart';
import '../../l10n/l10n.dart';

/// Desktop-only media pill, independent of native window controls.
class DesktopMediaSelector extends StatefulWidget {
  const DesktopMediaSelector({super.key});

  /// True while a mode write runs; tabs are disabled meanwhile. Shared so
  /// the Alt+1..4 shortcuts (shell-7) and the pill never race each other.
  static final ValueNotifier<bool> changing = ValueNotifier<bool>(false);

  /// Switches to [choice] exactly as clicking its tab does. Used by the pill
  /// and by the Alt+1..4 app shortcuts (shell-7).
  static Future<void> select(ModeChoice choice) async {
    if (changing.value) return;
    changing.value = true;
    try {
      await ZModePrefs.setStreamKind(choice.kind);
      await sl<ContentModeCubit>().setMode(choice.mode);
      // Network loading must not lock the media tabs. Home discards stale
      // requests when another selection starts a newer load.
      if (sl.isRegistered<HomeCubit>()) {
        unawaited(sl<HomeCubit>().load(reset: true));
      }
    } finally {
      changing.value = false;
    }
  }

  @override
  State<DesktopMediaSelector> createState() => _DesktopMediaSelectorState();
}

/// Only local mode writes are serialized; network loads never disable tabs.
class _DesktopMediaSelectorState extends State<DesktopMediaSelector> {
  // shell-13: a solid tinted fill instead of a live background blur. The
  // old translucent colour is blended over the frame once, so the pill
  // looks the same without redrawing a blur every frame.
  Color get _fill =>
      Color.alphaBlend(const Color(0xB324252B), DesktopChrome.frame);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: _fill,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0x24FFFFFF)),
    ),
    child: BlocBuilder<ContentModeCubit, ContentMode>(
      bloc: sl<ContentModeCubit>(),
      builder: (context, mode) => ListenableBuilder(
        listenable: Listenable.merge([
          ZModePrefs.revision,
          DesktopMediaSelector.changing,
        ]),
        // The shell caps the pill's width, so the catalogue name gets the
        // space the tabs leave (see _catalogueLabelBudget) and ellipsizes
        // inside it instead of being hard-clipped by the scroll view.
        builder: (context, _) => LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final choice in modeChoices)
                  _MediaCaptionTab(
                    label: choice.label(context),
                    selected:
                        choice.mode == mode &&
                        (mode != ContentMode.anime ||
                            choice.kind == ZModePrefs.streamKind),
                    onTap: DesktopMediaSelector.changing.value
                        ? null
                        : () => DesktopMediaSelector.select(choice),
                  ),
                // home-6: catalogue switch (AniList / MAL / Stremio /
                // extensions) right in the pill; hidden until Home publishes.
                _CatalogueButton(
                  maxLabelWidth: _catalogueLabelBudget(context, box.maxWidth),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  /// Width left for the catalogue name once the media tabs, the divider and
  /// the chip's own icon / chevron / padding are laid out in [pillWidth].
  /// Clamped to 48..200: never vanishes, never lets the pill grow unbounded.
  double _catalogueLabelBudget(BuildContext context, double pillWidth) {
    if (!pillWidth.isFinite) return _maxCatalogueLabelWidth;
    final style = DefaultTextStyle.of(
      context,
    ).style.merge(const TextStyle(fontSize: 13));
    var tabs = 0.0;
    for (final choice in modeChoices) {
      final painter = TextPainter(
        text: TextSpan(text: choice.label(context), style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      // Each tab adds 16px of padding on both sides.
      tabs += painter.width.ceilToDouble() + 32;
      painter.dispose();
    }
    // Divider 1 + 2x4 margin; chip: 2x12 padding, 16 icon, 7 gap, 4 gap,
    // 14 chevron; 1px slack for rounding.
    const chrome = 9.0 + 24 + 16 + 7 + 4 + 14 + 1;
    return (pillWidth - tabs - chrome).clamp(
      _minCatalogueLabelWidth,
      _maxCatalogueLabelWidth,
    );
  }
}

/// Smallest width the catalogue name may shrink to in the pill.
const double _minCatalogueLabelWidth = 48;

/// Widest the catalogue name may grow in the pill.
const double _maxCatalogueLabelWidth = 200;

/// home-6: shows the catalogue Home is using and opens a menu of every
/// catalogue, grouped (Trackers / Extensions ...) with a tick on the
/// current one. Nothing is drawn while no options are published.
class _CatalogueButton extends StatelessWidget {
  const _CatalogueButton({required this.maxLabelWidth});

  /// Room for the catalogue name; longer names end in an ellipsis.
  final double maxLabelWidth;

  /// Opens the grouped menu below the button and runs the picked option.
  Future<void> _open(BuildContext context) async {
    final options = DesktopCatalogueSwitch.options.value;
    final current = DesktopCatalogueSwitch.currentId.value;
    // Keep the published order of groups; options keep their order within.
    final groups = <String, List<DesktopCatalogueOption>>{};
    for (final option in options) {
      groups.putIfAbsent(option.group, () => []).add(option);
    }
    final items = <DesktopMenuItem<String>>[];
    for (final group in groups.entries) {
      if (items.isNotEmpty) items.add(const DesktopMenuItem.divider());
      // A disabled row acts as the group heading.
      items.add(DesktopMenuItem<String>(label: group.key, enabled: false));
      for (final option in group.value) {
        items.add(
          DesktopMenuItem<String>(
            label: option.label,
            icon: option.icon,
            value: option.id,
            checked: option.id == current,
            onTap: option.onSelect,
          ),
        );
      }
    }
    await showDesktopContextMenu<String>(
      context,
      anchor: context,
      items: items,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      DesktopCatalogueSwitch.options,
      DesktopCatalogueSwitch.currentId,
    ]),
    builder: (context, _) {
      final options = DesktopCatalogueSwitch.options.value;
      if (options.isEmpty) return const SizedBox.shrink();
      final currentId = DesktopCatalogueSwitch.currentId.value;
      final current = options
          .where((option) => option.id == currentId)
          .firstOrNull;
      // The pill only names what is on screen (e.g. 'AniList'); the menu
      // keeps the full labels.
      final label =
          current?.shortLabel ?? current?.label ?? context.l10n.catalogue;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Thin divider between the media tabs and the catalogue button.
          Container(
            width: 1,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: const Color(0x24FFFFFF),
          ),
          Tooltip(
            message: context.l10n.chooseCatalogue,
            child: Semantics(
              button: true,
              label: context.l10n.catalogueNamed(label),
              child: Builder(
                // The Builder's context is the button itself, so the menu
                // opens right below it.
                builder: (buttonContext) => InkWell(
                  key: const ValueKey('desktop-catalogue-switch'),
                  onTap: () => _open(buttonContext),
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    child: ExcludeSemantics(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _CatalogueIcon(option: current),
                          const SizedBox(width: 7),
                          ConstrainedBox(
                            // The room the tabs leave in the pill (at most
                            // 200), so short names show whole and long
                            // source names end in an ellipsis.
                            constraints: BoxConstraints(
                              maxWidth: maxLabelWidth,
                            ),
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          SvgPicture.asset(
                            'assets/icons/lucide/chevron-down.svg',
                            width: 14,
                            height: 14,
                            renderingStrategy: desktopSvgStrategy,
                            colorFilter: const ColorFilter.mode(
                              AppColors.textSecondary,
                              BlendMode.srcIn,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// Small icon for the current catalogue: its own icon, its logo, or a
/// generic blocks icon when neither is given.
class _CatalogueIcon extends StatelessWidget {
  const _CatalogueIcon({required this.option});
  final DesktopCatalogueOption? option;
  @override
  Widget build(BuildContext context) {
    final icon = option?.icon;
    if (icon != null) {
      return Icon(icon, size: 15, color: AppColors.textSecondary);
    }
    final url = option?.iconUrl;
    final fallback = SvgPicture.asset(
      'assets/icons/lucide/blocks.svg',
      width: 15,
      height: 15,
      renderingStrategy: desktopSvgStrategy,
      colorFilter: const ColorFilter.mode(
        AppColors.textSecondary,
        BlendMode.srcIn,
      ),
    );
    if (url == null || url.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: CachedNetworkImage(
        imageUrl: url,
        width: 16,
        height: 16,
        fit: BoxFit.cover,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}

/// Compact selected pill target with standard keyboard and pointer semantics.
class _MediaCaptionTab extends StatelessWidget {
  const _MediaCaptionTab({
    required this.label,
    required this.selected,
    this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent.withValues(alpha: .18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected ? Colors.white : AppColors.textSecondary,
          ),
        ),
      ),
    ),
  );
}

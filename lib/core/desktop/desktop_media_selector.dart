import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../di/injector.dart';
import '../mode/content_mode.dart';
import '../mode/content_mode_cubit.dart';
import '../theme/app_colors.dart';
import '../zmode/zmode_prefs.dart';
import '../../features/home/cubit/home_cubit.dart';
import '../../features/shell/mode_bar.dart';

/// Desktop-only acrylic media pill, independent of native window controls.
class DesktopMediaSelector extends StatefulWidget {
  const DesktopMediaSelector({super.key});
  @override
  State<DesktopMediaSelector> createState() => _DesktopMediaSelectorState();
}

/// Only local mode writes are serialized; network loads never disable tabs.
class _DesktopMediaSelectorState extends State<DesktopMediaSelector> {
  bool _changing = false;
  Future<void> _pick(ContentMode mode, StreamKind kind) async {
    if (_changing) return;
    setState(() => _changing = true);
    try {
      await ZModePrefs.setStreamKind(kind);
      await sl<ContentModeCubit>().setMode(mode);
      // Network loading must not lock the media tabs. Home discards stale
      // requests when another selection starts a newer load.
      if (sl.isRegistered<HomeCubit>()) {
        unawaited(sl<HomeCubit>().load(reset: true));
      }
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(24),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: const Color(0xB324252B),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0x24FFFFFF)),
        ),
        child: BlocBuilder<ContentModeCubit, ContentMode>(
          bloc: sl<ContentModeCubit>(),
          builder: (context, mode) => ValueListenableBuilder<int>(
            valueListenable: ZModePrefs.revision,
            builder: (context, _, _) => SingleChildScrollView(
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
                      onTap: _changing
                          ? null
                          : () => _pick(choice.mode, choice.kind),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
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

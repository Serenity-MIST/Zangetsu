import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

/// Desktop source ranking row. The screen owns order, persistence and health;
/// this view supplies immediate pointer dragging and standard keyboard buttons.
class DesktopSourcePriorityRow extends StatelessWidget {
  const DesktopSourcePriorityRow({
    super.key,
    required this.index,
    required this.count,
    required this.name,
    required this.tried,
    required this.onMoveUp,
    required this.onMoveDown,
    this.repo,
    this.reason,
    this.health,
  });

  final int index;
  final int count;
  final String name;
  final String? repo;
  final String? reason;
  final bool tried;
  final ({String label, Color color})? health;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: tried ? const Color(0xFF1B1C20) : const Color(0xFF141519),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFF303137)),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 460;
        final moves = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Move $name up',
              onPressed: index > 0 ? onMoveUp : null,
              icon: const Icon(Icons.arrow_upward_rounded, size: 20),
            ),
            IconButton(
              tooltip: 'Move $name down',
              onPressed: index < count - 1 ? onMoveDown : null,
              icon: const Icon(Icons.arrow_downward_rounded, size: 20),
            ),
          ],
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: Tooltip(
                    message: 'Drag to reorder $name',
                    child: ReorderableDragStartListener(
                      index: index,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 8, 12, 8),
                        child: Icon(
                          Icons.drag_indicator_rounded,
                          color: AppColors.textSecondary,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${index + 1}. $name',
                        style: AppText.body.copyWith(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (repo != null) ...[
                        const SizedBox(height: 4),
                        Text(repo!, style: AppText.caption),
                      ],
                      if (reason != null) ...[
                        const SizedBox(height: 4),
                        Text(reason!, style: AppText.caption),
                      ],
                      if (health case final status?) ...[
                        const SizedBox(height: 6),
                        Text(
                          status.label,
                          style: AppText.caption.copyWith(color: status.color),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!narrow) ...[const SizedBox(width: 12), moves],
              ],
            ),
            if (narrow)
              Align(alignment: AlignmentDirectional.centerEnd, child: moves),
          ],
        );
      },
    ),
  );
}

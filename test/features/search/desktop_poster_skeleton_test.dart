// Windows loading placeholders must be exactly the size of the real result
// cards, so nothing jumps from big boxes to small posters when results land.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/desktop_media_card.dart';
import 'package:watch_app/core/ui/poster_card.dart';
import 'package:watch_app/features/search/desktop_poster_skeleton.dart';

/// A widget test run as Windows; the variant resets the platform override.
void winTestWidgets(String description, WidgetTesterCallback body) =>
    testWidgets(
      description,
      body,
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

void main() {
  /// The skeleton above a real grid with the results page's delegate and
  /// padding, in a 1366 px wide window.
  Future<void> pumpBoth(WidgetTester t) async {
    t.view.physicalSize = const Size(1366, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                const DesktopPosterSkeletonGrid(count: 4),
                Builder(
                  builder: (context) => GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                    gridDelegate: posterGridDelegate(context),
                    itemCount: 2,
                    itemBuilder: (_, i) =>
                        SizedBox.expand(key: ValueKey('real-$i')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await t.pump();
  }

  winTestWidgets('skeleton cell equals the real card cell at 1366 px', (
    t,
  ) async {
    await pumpBoth(t);
    final skeleton = t.getSize(
      find.byKey(const ValueKey('desktop-poster-skeleton-0')),
    );
    final real = t.getSize(find.byKey(const ValueKey('real-0')));
    expect(skeleton, real);

    // And both match the delegate's own layout for that width.
    final layout =
        const DesktopPosterGridDelegate().getLayout(
              const SliverConstraints(
                axisDirection: AxisDirection.down,
                growthDirection: GrowthDirection.forward,
                userScrollDirection: ScrollDirection.idle,
                scrollOffset: 0,
                precedingScrollExtent: 0,
                overlap: 0,
                remainingPaintExtent: 900,
                crossAxisExtent: 1366 - 32,
                crossAxisDirection: AxisDirection.right,
                viewportMainAxisExtent: 900,
                remainingCacheExtent: 900,
                cacheOrigin: 0,
              ),
            )
            as SliverGridRegularTileLayout;
    expect(skeleton.width, closeTo(layout.childCrossAxisExtent, 0.01));
    expect(skeleton.height, closeTo(layout.childMainAxisExtent, 0.01));
    expect(
      skeleton.height,
      closeTo(DesktopMediaCard.height(skeleton.width, 1), 0.01),
    );
    // A normal poster cell on a wide window, not a huge three-column box.
    expect(skeleton.width, lessThan(240));
  });

  winTestWidgets('the art box leaves room for the caption strip', (t) async {
    await pumpBoth(t);
    final cell = find.byKey(const ValueKey('desktop-poster-skeleton-0'));
    final art = find
        .descendant(of: cell, matching: find.byType(DecoratedBox))
        .first;
    final cellSize = t.getSize(cell);
    // Art is width * .94 tall; the 56 px caption strip sits under it.
    expect(t.getSize(art).height, closeTo(cellSize.width * .94, 0.01));
  });

  winTestWidgets('the row skeleton uses the row card size', (t) async {
    await t.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              final size = Size(
                posterRowWidth(context),
                posterRowHeight(context),
              );
              return Column(
                children: [
                  Text(
                    '${size.width}x${size.height}',
                    key: const ValueKey('size'),
                  ),
                  const DesktopPosterSkeletonRow(count: 3),
                ],
              );
            },
          ),
        ),
      ),
    );
    final expected = t.widget<Text>(find.byKey(const ValueKey('size'))).data!;
    final card = t.getSize(find.byType(DesktopPosterSkeletonCard).first);
    expect('${card.width}x${card.height}', expected);
  });
}

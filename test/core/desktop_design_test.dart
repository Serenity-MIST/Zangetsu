import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/theme/app_theme.dart';
import 'package:watch_app/core/ui/banner_style.dart';
import 'package:watch_app/features/home/desktop_featured.dart';

void main() {
  // Every persisted style must render on both wide and compact PC windows.
  for (final style in BannerStyle.options) {
  for (final width in [1366.0, 800.0, 480.0]) {
    testWidgets('featured desktop ${style.id} renders at $width without overflow', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final font = FontLoader('Nunito')
          ..addFont(rootBundle.load('assets/fonts/Nunito-Regular.ttf'));
        await font.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });
      tester.view.physicalSize = Size(width, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      final item = MediaItem(
        id: 'fixture',
        title: 'Frieren: Beyond Journey’s End',
        url: '',
        sourceId: 'fixture',
        type: ProviderType.anime,
        genres: const ['Adventure', 'Fantasy', 'Drama'],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Discover', style: TextStyle(fontSize: 26)),
                    ),
                  ),
                  DesktopFeatured(
                    style: style.id,
                    items: [item],
                    reading: false,
                    inList: (_) => false,
                    onPlay: (_) {},
                    onInfo: (_) {},
                    onToggleList: (_) {},
                    meta: (_) async => null,
                    imageBuilder: (_) => Image.asset(
                      'assets/icon/preview_crescent.png',
                      fit: BoxFit.contain,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(ValueKey('desktop-banner-${style.id}')), findsOneWidget);
      if (width == 1366) {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('merge-work/settings-audit/previews').create(recursive: true);
          await File(
            'merge-work/settings-audit/previews/banner-${style.id}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  }
}

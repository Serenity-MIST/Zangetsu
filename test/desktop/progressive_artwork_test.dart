import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/progressive_artwork.dart';
import 'package:watch_app/core/ui/artwork_quality.dart';

/// Controlled decode completion verifies request order without using HTTP.
class _ControlledImage extends ImageProvider<_ControlledImage> {
  final completion = Completer<ImageInfo>();
  int loads = 0;
  @override
  Future<_ControlledImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
    _ControlledImage key,
    ImageDecoderCallback decode,
  ) {
    loads++;
    return OneFrameImageStreamCompleter(completion.future);
  }
}

Widget _view(_ControlledImage preview, _ControlledImage full) => MaterialApp(
  home: Center(
    child: SizedBox(
      width: 100,
      height: 100,
      child: ProgressiveArtwork(preview: preview, full: full),
    ),
  ),
);

void main() {
  test('small variants preserve unrelated signed extension URLs', () {
    expect(
      artworkPreviewUrl('https://image.tmdb.org/t/p/original/a.jpg'),
      'https://image.tmdb.org/t/p/w185/a.jpg',
    );
    const signed = 'https://images.example/cover.jpg?signature=keep';
    expect(artworkPreviewUrl(signed), signed);
  });
  testWidgets('full waits for preview and failure keeps preview', (
    tester,
  ) async {
    final preview = _ControlledImage(), full = _ControlledImage();
    final image = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.red, BlendMode.src);
      return recorder.endRecording().toImage(2, 2);
    });
    await tester.pumpWidget(_view(preview, full));
    expect(preview.loads, 1);
    expect(full.loads, 0);
    preview.completion.complete(ImageInfo(image: image!));
    await tester.pump();
    await tester.pump();
    expect(full.loads, 1);
    full.completion.completeError(StateError('full quality unavailable'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((w) => w is Image && w.image == preview),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('failed thumbnail stages retain the explicit offline fallback', (tester) async {
    final preview = _ControlledImage(), full = _ControlledImage();
    await tester.pumpWidget(MaterialApp(home: SizedBox(width: 80, height: 48,
      child: ProgressiveArtwork(preview: preview, full: full, fallback: const Text('Offline poster')))));
    preview.completion.completeError(StateError('thumbnail unavailable'));
    await tester.pump(); await tester.pump();
    full.completion.completeError(StateError('full unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('Offline poster'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('changed cards do not start the old full request', (
    tester,
  ) async {
    final oldPreview = _ControlledImage(), oldFull = _ControlledImage();
    final nextPreview = _ControlledImage(), nextFull = _ControlledImage();
    await tester.pumpWidget(_view(oldPreview, oldFull));
    await tester.pumpWidget(_view(nextPreview, nextFull));
    expect(oldFull.loads, 0);
    expect(nextPreview.loads, 1);
    expect(nextFull.loads, 0);
    expect(tester.takeException(), isNull);
  });
}

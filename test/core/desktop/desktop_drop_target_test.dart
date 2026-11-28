import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_drop_target.dart';
import 'package:watch_app/core/desktop/desktop_native.dart';

/// Sends a drop through the same handler the Windows runner calls.
Future<void> _drop(Offset at, {List<String> paths = const [], String? text}) =>
    DesktopNative.debugHandleNativeCall(
      MethodCall('drop', {
        'paths': paths,
        'text': text,
        'x': at.dx,
        'y': at.dy,
      }),
    );

/// Moves the native drag pointer (null = drag left the window).
Future<void> _drag(Offset? at) => DesktopNative.debugHandleNativeCall(
  at == null
      ? const MethodCall('dragLeave')
      : MethodCall('dragUpdate', {'x': at.dx, 'y': at.dy}),
);

// Windows-only UI behaviour; the variant resets the platform override.
final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

void main() {
  // Two targets side by side: left 0..200, right 200..400 (top 0..100).
  Widget targets({
    required List<String> left,
    required List<String> right,
    List<bool>? hover,
    bool rightAcceptsText = false,
  }) => Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DesktopDropTarget(
            onDrop: (event) => left.add(event.paths.join(',')),
            onHoverChanged: hover?.add,
            child: const SizedBox(width: 200, height: 100),
          ),
          DesktopDropTarget(
            acceptFiles: false,
            acceptText: rightAcceptsText,
            onDrop: (event) => right.add(event.text ?? ''),
            child: const SizedBox(width: 200, height: 100),
          ),
        ],
      ),
    ),
  );

  testWidgets('drops reach only the target under the pointer', (tester) async {
    final left = <String>[];
    final right = <String>[];
    await tester.pumpWidget(
      targets(left: left, right: right, rightAcceptsText: true),
    );
    await _drop(const Offset(50, 50), paths: [r'C:\a.mkv']);
    await _drop(const Offset(250, 50), text: 'https://example.com');
    // Outside both boxes: ignored.
    await _drop(const Offset(50, 300), paths: [r'C:\b.mkv']);
    expect(left, [r'C:\a.mkv']);
    expect(right, ['https://example.com']);
  }, variant: _windows);

  testWidgets('content filters apply per target', (tester) async {
    final left = <String>[];
    final right = <String>[];
    await tester.pumpWidget(targets(left: left, right: right));
    // Text on a files-only target and files on a text-off target: ignored.
    await _drop(const Offset(50, 50), text: 'hello');
    await _drop(const Offset(250, 50), paths: [r'C:\a.mkv']);
    expect(left, isEmpty);
    expect(right, isEmpty);
  }, variant: _windows);

  testWidgets('hover follows the drag position', (tester) async {
    final hover = <bool>[];
    await tester.pumpWidget(targets(left: [], right: [], hover: hover));
    await _drag(const Offset(20, 20));
    await _drag(const Offset(30, 30));
    await _drag(const Offset(260, 30));
    await _drag(const Offset(40, 40));
    await _drag(null);
    expect(hover, [true, false, true, false]);
  }, variant: _windows);

  testWidgets('off Windows the target is inert', (tester) async {
    final left = <String>[];
    await tester.pumpWidget(targets(left: left, right: []));
    await _drop(const Offset(50, 50), paths: [r'C:\a.mkv']);
    expect(left, isEmpty);
  });

  test('accepts() checks the content kind', () {
    const files = DesktopDropEvent(paths: ['x'], position: Offset.zero);
    const text = DesktopDropEvent(text: 'y', position: Offset.zero);
    expect(
      DesktopDropTarget.accepts(files, acceptFiles: true, acceptText: false),
      isTrue,
    );
    expect(
      DesktopDropTarget.accepts(text, acceptFiles: true, acceptText: false),
      isFalse,
    );
    expect(
      DesktopDropTarget.accepts(text, acceptFiles: false, acceptText: true),
      isTrue,
    );
  });
}

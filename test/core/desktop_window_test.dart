import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('fullscreen state and setters use the native window contract', () async {
    const channel = MethodChannel('com.spyou.zangetsu/window');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'isFullscreen' ? true : null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    expect(await DesktopWindow.isFullscreen(), isTrue);
    await DesktopWindow.setFullscreen(false);
    expect(calls.map((call) => call.method), ['isFullscreen', 'setFullscreen']);
    expect(calls.last.arguments, isFalse);
  });
  testWidgets('F11 reaches the native fullscreen toggle from app content', (tester) async {
    var calls = 0;
    const channel = MethodChannel('com.spyou.zangetsu/window');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'toggleFullscreen');
      calls++;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const MaterialApp(home: DesktopWindow(
      child: Scaffold(body: Center(child: Text('Home'))),
    )));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(calls, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(calls, 2);
  }, skip: !Platform.isWindows);
}

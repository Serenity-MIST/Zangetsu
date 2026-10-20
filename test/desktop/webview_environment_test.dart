// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';

/// Verifies the Windows bridge uses the same environment id for creation and
/// disposal, so successful verification cannot fail during browser cleanup.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('each environment disposes its own native channel', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const factory = MethodChannel(
      'com.pichillilorenzo/flutter_webview_environment',
    );
    final created = <String>[];
    final disposed = <String>[];
    messenger.setMockMethodCallHandler(factory, (call) async {
      final id = (call.arguments as Map)['id'] as String;
      created.add(id);
      messenger.setMockMethodCallHandler(
        MethodChannel('com.pichillilorenzo/flutter_webview_environment_$id'),
        (call) async {
          disposed.add(id);
          return null;
        },
      );
      return null;
    });
    try {
      final first = await WindowsWebViewEnvironment.static().create();
      final second = await WindowsWebViewEnvironment.static().create();
      expect(first.id, isNot(second.id));
      await first.dispose();
      await second.dispose();
      expect(disposed, created);
    } finally {
      messenger.setMockMethodCallHandler(factory, null);
      for (final id in created) {
        messenger.setMockMethodCallHandler(
          MethodChannel('com.pichillilorenzo/flutter_webview_environment_$id'),
          null,
        );
      }
    }
  });
}

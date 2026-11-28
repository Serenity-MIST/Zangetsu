import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:watch_app/core/desktop/extension_boot_failures.dart';
import 'package:watch_app/core/desktop/extension_load_failures.dart';
import 'package:watch_app/core/desktop/extension_runtime.dart';

// src-10 Option C: the Aniyomi / Mihon boot steps list installed extensions
// that cannot load (engine missing, or a boot step threw) in the notice.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ext_boot_failures');
    Hive.init(dir.path);
    ExtensionLoadFailures.debugReset();
    // Keep the notice timer from firing a real SnackBar.
    ExtensionLoadFailures.debugShowNotice = (_) {};
    debugBootFailuresOnWindows = true;
  });

  tearDown(() async {
    ExtensionLoadFailures.debugReset();
    DesktopExtensionRuntime.debugResetBootSteps();
    DesktopExtensionRuntime.debugAvailableOverride = null;
    debugBootFailuresOnWindows = null;
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('missing engine with nothing installed lists nothing', () async {
    DesktopExtensionRuntime.debugAvailableOverride = false;
    await reportMissingExtensionEngine(
      ecosystem: 'Aniyomi',
      installedBoxName: 'boot_test_empty',
      boot: () async {},
    );
    expect(ExtensionLoadFailures.failures.value, isEmpty);
  });

  test('missing engine with installed extensions is listed; Retry boots '
      'again once the engine is back', () async {
    final box = await Hive.openBox<dynamic>('boot_test_installed');
    await box.put('pkg.a', 'a.apk');
    DesktopExtensionRuntime.debugAvailableOverride = false;
    var boots = 0;
    await reportMissingExtensionEngine(
      ecosystem: 'Mihon',
      installedBoxName: 'boot_test_installed',
      boot: () async => boots++,
    );
    final entry = ExtensionLoadFailures.failures.value.single;
    expect(entry.ecosystem, 'Mihon');
    expect(entry.message, missingEngineMessage);

    // Still missing: Retry keeps the entry and does not boot.
    await ExtensionLoadFailures.retryAll();
    expect(boots, 0);
    expect(ExtensionLoadFailures.failures.value, hasLength(1));

    // Files restored: Retry clears the entry and runs the boot step.
    DesktopExtensionRuntime.debugAvailableOverride = true;
    await ExtensionLoadFailures.retryAll();
    expect(boots, 1);
    expect(ExtensionLoadFailures.failures.value, isEmpty);
  });

  test('boot failure is listed once and skipped when already reported', () {
    reportExtensionBootFailure(
      'Aniyomi',
      PlatformException(code: 'X', message: 'list failed'),
      () async {},
    );
    expect(ExtensionLoadFailures.failures.value.single.message, 'list failed');

    // An engine-level failure already explains the problem: no duplicate.
    ExtensionLoadFailures.debugReset();
    ExtensionLoadFailures.debugShowNotice = (_) {};
    ExtensionLoadFailures.report(
      const ExtensionLoadFailure(
        ecosystem: DesktopExtensionRuntime.engineEcosystem,
        name: 'engine',
        message: 'down',
      ),
    );
    reportExtensionBootFailure('Mihon', 'boom', () async {});
    expect(ExtensionLoadFailures.failures.value, hasLength(1));
  });

  // Reviewer fix: when the engine already explains the failure, the boot
  // entry is skipped, but its boot step must still be kept so the engine
  // Retry can register the sources again (else they stay missing).
  test('skipped boot failure still registers its boot step', () async {
    ExtensionLoadFailures.report(
      const ExtensionLoadFailure(
        ecosystem: DesktopExtensionRuntime.engineEcosystem,
        name: 'engine',
        message: 'down',
      ),
    );
    var boots = 0;
    reportExtensionBootFailure('Aniyomi', 'boom', () async => boots++);
    expect(ExtensionLoadFailures.failures.value, hasLength(1));
    await DesktopExtensionRuntime.runBootSteps();
    expect(boots, 1);
    // Scoped run: another ecosystem's step does not run.
    await DesktopExtensionRuntime.runBootSteps('Mihon');
    expect(boots, 1);
  });

  test('a successful boot-step rerun clears its Startup entry', () async {
    reportExtensionBootFailure('Mihon', 'boom', () async {});
    expect(ExtensionLoadFailures.failures.value.single.name, bootFailureEntry);
    await DesktopExtensionRuntime.runBootSteps('Mihon');
    expect(ExtensionLoadFailures.failures.value, isEmpty);
  });

  test('off Windows nothing is reported', () async {
    debugBootFailuresOnWindows = false;
    reportExtensionBootFailure('Aniyomi', 'boom', () async {});
    expect(ExtensionLoadFailures.failures.value, isEmpty);
  });
}

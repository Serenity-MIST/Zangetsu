import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../hive/safe_box.dart';
import 'extension_load_failures.dart';
import 'extension_runtime.dart';

/// src-10 (Windows): startup reporting for the Aniyomi / Mihon boot steps in
/// the injector, so installed extensions that cannot load are listed in the
/// one-time load-failure notice instead of silently disappearing.

/// Name of the notice entry for installed extensions that could not load
/// because the bundled engine files are missing.
/// These three are ids as well as English text: the notice clears entries by
/// name, so they stay fixed and extensionFailureText translates them on show.
const missingEngineEntry = 'Installed extensions';

/// Name of the notice entry for a boot step that threw.
const bootFailureEntry = 'Startup';

/// Text shown when the engine files are missing (same wording as the hub).
const missingEngineMessage =
    'Extension engine not found. Re-extract the app folder.';

/// Lets tests run the Windows-only paths on any host.
@visibleForTesting
bool? debugBootFailuresOnWindows;

/// Real OS check: the engine and its files only exist on Windows.
bool get _onWindows => debugBootFailuresOnWindows ?? Platform.isWindows;

/// When the extension engine files are missing but the user has installed
/// [ecosystem] extensions, lists them in the load-failure notice. Retry
/// re-reads the disk (e.g. after re-extracting the app folder) and, if the
/// engine is back, runs [boot] again. No-op off Windows.
Future<void> reportMissingExtensionEngine({
  required String ecosystem,
  required String installedBoxName,
  required Future<void> Function() boot,
}) async {
  if (!_onWindows) return;
  try {
    if (!Hive.isBoxOpen(installedBoxName)) {
      await openBoxSafely<dynamic>(installedBoxName);
    }
    // Nothing installed: nothing went missing, so no notice.
    if (Hive.box<dynamic>(installedBoxName).isEmpty) return;
  } catch (_) {
    return; // the notice is never worth a boot failure
  }
  ExtensionLoadFailures.registerRetry(ecosystem, () async {
    DesktopExtensionRuntime.recheckAvailability();
    if (!DesktopExtensionRuntime.isAvailable) return; // still missing
    ExtensionLoadFailures.clear(ecosystem, name: missingEngineEntry);
    await boot();
  });
  ExtensionLoadFailures.report(
    ExtensionLoadFailure(
      ecosystem: ecosystem,
      name: missingEngineEntry,
      message: missingEngineMessage,
    ),
  );
}

/// A boot step that threw (e.g. listing sources failed) is listed in the
/// notice with a Retry that runs [boot] again. The entry is skipped when the
/// engine or an extension folder already reported a failure for it, so one
/// problem is not listed twice; their Retry then runs [boot] afterwards
/// (see [DesktopExtensionRuntime.registerBootStep]). No-op off Windows.
void reportExtensionBootFailure(
  String ecosystem,
  Object error,
  Future<void> Function() boot,
) {
  if (!_onWindows) return;
  // How a Retry reloads AND registers this ecosystem's sources. Registered
  // even when the entry itself is skipped below: the engine and folder
  // Retries only reload inside the engine, so they run this afterwards,
  // otherwise the sources would stay missing after a "successful" Retry.
  Future<void> rerun() async {
    ExtensionLoadFailures.clear(ecosystem, name: bootFailureEntry);
    await boot();
  }

  DesktopExtensionRuntime.registerBootStep(ecosystem, rerun);
  final alreadyListed = ExtensionLoadFailures.failures.value.any(
    (f) =>
        (f.ecosystem == ecosystem && f.name != bootFailureEntry) ||
        f.ecosystem == DesktopExtensionRuntime.engineEcosystem,
  );
  if (alreadyListed) return;
  ExtensionLoadFailures.registerRetry(ecosystem, rerun);
  ExtensionLoadFailures.report(
    ExtensionLoadFailure(
      ecosystem: ecosystem,
      name: bootFailureEntry,
      message: error is PlatformException
          ? (error.message ?? error.code)
          : '$error',
    ),
  );
}

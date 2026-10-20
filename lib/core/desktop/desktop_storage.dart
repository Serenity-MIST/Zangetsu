import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// One selected root; the Windows profile retains only the location pointer.
class DesktopStorage {
  static String? root;

  /// Selects/restores the root before services open files, then redirects
  /// path_provider and shared-preference APIs to the selected location.
  static Future<void> initialize() async {
    if (!Platform.isWindows) return;
    final original = PathProviderPlatform.instance;
    final previous = await original.getApplicationSupportPath();
    if (previous == null)
      throw StateError('Windows application data is unavailable');
    final pointer = File(p.join(previous, 'storage-root.json'));
    String? selected;
    try {
      final data = jsonDecode(await pointer.readAsString());
      selected = data['root'] as String?;
      if (selected != null && !await Directory(selected).exists())
        selected = null;
    } catch (_) {}
    if (selected == null) {
      final done = Completer<String>();
      runApp(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(),
          home: _StorageSetup(
            onChosen: (value) {
              if (!done.isCompleted) done.complete(value);
            },
            previous: previous,
          ),
        ),
      );
      selected = await done.future;
      await pointer.parent.create(recursive: true);
      await pointer.writeAsString(jsonEncode({'root': selected}), flush: true);
    }
    root = selected;
    for (final name in ['AppData', 'Downloads', 'Backups']) {
      await Directory(p.join(selected, name)).create(recursive: true);
    }
    PathProviderPlatform.instance = _SelectedPaths(original, selected);
    // Shared preferences constructs its own Windows provider; route the auth
    // session file as well as path_provider clients to the selected folder.
    final windowsPaths = _SelectedWindowsPaths(selected);
    final legacyPreferences = SharedPreferencesStorePlatform.instance;
    if (legacyPreferences is SharedPreferencesWindows)
      legacyPreferences.pathProvider = windowsPaths;
    final preferences = SharedPreferencesAsyncPlatform.instance;
    if (preferences is SharedPreferencesAsyncWindows)
      preferences.pathProvider = windowsPaths;
  }

  /// Copy before activation, retaining originals and avoiding links/self-copy.
  static Future<void> migrate(String previous, String selected) async {
    final destination = p.join(selected, 'AppData');
    final source = p.normalize(p.absolute(previous));
    final target = p.normalize(p.absolute(destination));
    if (p.equals(source, target)) return;
    await Directory(target).create(recursive: true);
    if (!await Directory(source).exists()) return;
    await for (final entry in Directory(
      source,
    ).list(recursive: true, followLinks: false)) {
      if (entry is! File || p.isWithin(target, entry.path)) continue;
      final relative = p.relative(entry.path, from: source);
      if (relative == 'storage-root.json' ||
          relative.endsWith('.lock') ||
          relative.startsWith('browser'))
        continue;
      final copied = File(p.join(target, relative));
      if (await copied.exists()) continue;
      await copied.parent.create(recursive: true);
      await entry.copy(copied.path);
    }
  }
}

/// Redirects app-owned paths while preserving the system Documents location.
class _SelectedPaths extends PathProviderPlatform {
  _SelectedPaths(this.original, this.root);
  final PathProviderPlatform original;
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => p.join(root, 'AppData');
  @override
  Future<String?> getApplicationCachePath() async =>
      p.join(root, 'AppData', 'Cache');
  @override
  Future<String?> getTemporaryPath() async {
    final directory = Directory(p.join(root, 'AppData', 'Temp'));
    await directory.create(recursive: true);
    return directory.path;
  }

  @override
  Future<String?> getApplicationDocumentsPath() =>
      original.getApplicationDocumentsPath();
  @override
  Future<String?> getDownloadsPath() async => p.join(root, 'Downloads');
}

/// First-launch folder chooser shown before account/database initialization.
class _StorageSetup extends StatefulWidget {
  const _StorageSetup({required this.onChosen, required this.previous});
  final void Function(String) onChosen;
  final String previous;
  @override
  State<_StorageSetup> createState() => _StorageSetupState();
}

/// Checks write access and migrates existing data before accepting a folder.
class _StorageSetupState extends State<_StorageSetup> {
  bool busy = false;
  String? error;

  /// Picks a directory, probes write access and retains originals on migration.
  /// Cancellation keeps setup open rather than starting in an unknown root.
  Future<void> choose() async {
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose your Zangetsu data folder',
    );
    if (folder == null || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final probe = File(p.join(folder, '.zangetsu-write-check'));
      await probe.writeAsString('');
      await probe.delete();
      await DesktopStorage.migrate(widget.previous, folder);
      widget.onChosen(folder);
    } catch (_) {
      if (mounted)
        setState(() {
          busy = false;
          error = 'This folder could not be used. Choose another folder.';
        });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xff0b0b10),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.folder_rounded,
                size: 64,
                color: Color(0xffff465b),
              ),
              const SizedBox(height: 24),
              const Text(
                'Choose your data folder',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Text(
                'Your accounts, library, downloads and backups will live here, organized in AppData, Downloads and Backups.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              if (busy)
                const CircularProgressIndicator()
              else
                FilledButton.icon(
                  onPressed: choose,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Choose folder'),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(error!),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Redirects shared-preference implementations that construct a path provider.
class _SelectedWindowsPaths extends PathProviderWindows {
  _SelectedWindowsPaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => p.join(root, 'AppData');
}

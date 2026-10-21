import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Windows app-owned data lives in the OS application-support directory.
/// Downloads have an independent location and never move with app preferences.
class DesktopStorage {
  static String? root;
  static String? downloadsRoot;
  static String? previousRoot;

  /// Repoints app-owned extension/cache records after an upgrade. Download
  /// paths and files outside the old AppData tree are deliberately unchanged.
  static String relocatedAppPath(String value) {
    if (root == null || previousRoot == null || !p.isAbsolute(value)) {
      return value;
    }
    final previous = p.normalize(p.join(previousRoot!, 'AppData'));
    final target = p.normalize(p.join(root!, 'AppData'));
    final path = p.normalize(value);
    if (p.equals(previous, path)) return target;
    if (!p.isWithin(previous, path)) return value;
    return p.join(target, p.relative(path, from: previous));
  }

  /// Completes migration before Hive, auth sessions or browser profiles open.
  static Future<void> initialize() async {
    if (!Platform.isWindows) return;
    final original = PathProviderPlatform.instance;
    final support = await original.getApplicationSupportPath();
    final downloads = await original.getDownloadsPath();
    if (support == null || downloads == null) {
      throw StateError('Windows application folders are unavailable');
    }
    // A missing removable legacy folder must offer recovery, not a black
    // startup screen or a fresh empty account. No database is open at this point.
    while (true) {
      try {
        await prepare(
          supportPath: support,
          systemDownloadsPath: downloads,
          onMigrating: () => runApp(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData.dark(),
              home: const _StorageProgressScreen(),
            ),
          ),
        );
        break;
      } catch (_) {
        final retry = Completer<void>();
        runApp(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData.dark(),
            home: _StorageRecoveryScreen(
              onRetry: () {
                if (!retry.isCompleted) retry.complete();
              },
            ),
          ),
        );
        await retry.future;
      }
    }
    PathProviderPlatform.instance = _ApplicationPaths(
      original,
      root!,
      downloadsRoot!,
    );
  }

  /// Restores versioned routing or copies the legacy root before committing it.
  /// The old directory remains an untouched rollback copy; a failed copy leaves
  /// routing unchanged, so retrying startup resumes safely instead of losing data.
  static Future<void> prepare({
    required String supportPath,
    required String systemDownloadsPath,
    VoidCallback? onMigrating,
  }) async {
    final pointer = File(p.join(supportPath, 'storage-root.json'));
    Map<String, dynamic> saved = {};
    final previousPointer = File('${pointer.path}.previous');
    final routing = await pointer.exists() ? pointer : previousPointer;
    if (await routing.exists()) {
      // Corruption must be visible rather than treated as a fresh empty account.
      saved = Map<String, dynamic>.from(
        jsonDecode(await routing.readAsString()) as Map,
      );
    }
    final legacyRoot = saved['root'] as String?;
    final version = saved['version'] as int? ?? 1;
    final downloads =
        (saved['downloadsRoot'] as String?) ??
        (version < 2 && legacyRoot != null
            ? p.join(legacyRoot, 'Downloads')
            : p.join(systemDownloadsPath, 'Zangetsu'));
    await Directory(supportPath).create(recursive: true);
    if (version < 2) {
      onMigrating?.call();
      final source = legacyRoot == null
          ? supportPath
          : p.join(legacyRoot, 'AppData');
      if (legacyRoot != null && !await Directory(source).exists()) {
        throw StateError(
          'The previous Zangetsu data folder is unavailable. Restore it before starting.',
        );
      }
      await migrate(source, supportPath);
      // SharedPreferencesWindows intentionally owns its native support path.
      // Move the active session there rather than overriding a test-only API.
      final session = File(p.join(source, 'shared_preferences.json'));
      if (await session.exists()) {
        await _copyFileVerified(
          session,
          File(p.join(supportPath, 'shared_preferences.json')),
          File(
            p.join(
              supportPath,
              'MigrationBackups',
              'native-shared_preferences.json',
            ),
          ),
        );
      }
      if (legacyRoot != null &&
          !p.equals(p.absolute(legacyRoot), p.absolute(supportPath))) {
        await _copyVerified(
          p.join(legacyRoot, 'Backups'),
          p.join(supportPath, 'Backups'),
        );
      }
      final staged = File('${pointer.path}.pending');
      await staged.writeAsString(
        jsonEncode({
          'version': 2,
          'root': supportPath,
          'downloadsRoot': downloads,
          if (legacyRoot != null) 'previousRoot': legacyRoot,
        }),
        flush: true,
      );
      // On Windows rename does not replace an existing destination. Preserve the
      // old pointer first; if interrupted, prepare() can still recover from it.
      if (await pointer.exists()) {
        final backup = File('${pointer.path}.previous');
        if (!await backup.exists()) await pointer.copy(backup.path);
      }
      if (await pointer.exists()) await pointer.delete();
      await staged.rename(pointer.path);
    }
    root = supportPath;
    previousRoot = version < 2 ? legacyRoot : saved['previousRoot'] as String?;
    downloadsRoot = downloads;
    await Directory(p.join(supportPath, 'AppData')).create(recursive: true);
    await Directory(p.join(supportPath, 'Backups')).create(recursive: true);
    // Download folders are created by the download flow, not by app startup.
    // An unplugged download drive must not lock the user out of their library.
  }

  /// Public migration entry retained for upgrades from the selected-root layout.
  static Future<void> migrate(String previous, String selected) =>
      _copyVerified(previous, p.join(selected, 'AppData'));

  /// Copies closed data files through staging files and verifies SHA-256 bytes.
  /// Existing different destinations are backed up before replacement. Symlinks,
  /// runtime locks and the migration destination itself are never traversed.
  static Future<void> _copyVerified(String previous, String destination) async {
    final source = p.normalize(p.absolute(previous));
    final target = p.normalize(p.absolute(destination));
    if (p.equals(source, target) || !await Directory(source).exists()) return;
    if (p.isWithin(source, target) && p.basename(target) != 'AppData') {
      throw StateError('Invalid nested migration destination');
    }
    await Directory(target).create(recursive: true);
    final pending = <Directory>[Directory(source)];
    while (pending.isNotEmpty) {
      await for (final entry in pending.removeLast().list(followLinks: false)) {
        final name = p.basename(entry.path);
        if (p.equals(entry.path, target) ||
            p.isWithin(target, entry.path) ||
            name == 'MigrationBackups' ||
            (p.isWithin(source, target) && name == 'Backups') ||
            name == 'storage-root.json' ||
            name.startsWith('storage-root.json.') ||
            name.endsWith('.lock') ||
            name.endsWith('.migrating') ||
            const {
              'LOCK',
              'SingletonLock',
              'SingletonCookie',
              'SingletonSocket',
              'DevToolsActivePort',
            }.contains(name)) {
          continue;
        }
        if (entry is Directory) {
          pending.add(entry);
        } else if (entry is File) {
          final relative = p.relative(entry.path, from: source);
          final copied = File(p.join(target, relative));
          await _copyFileVerified(
            entry,
            copied,
            File(p.join(p.dirname(target), 'MigrationBackups', relative)),
          );
        }
      }
    }
  }

  /// Verifies each staged file and keeps the first displaced destination for
  /// rollback. A second interrupted run can safely compare and reuse its copy.
  static Future<void> _copyFileVerified(
    File source,
    File target,
    File backup,
  ) async {
    if (p.equals(
      p.normalize(p.absolute(source.path)),
      p.normalize(p.absolute(target.path)),
    )) {
      return;
    }
    final sourceDigest = await sha256.bind(source.openRead()).first;
    if (await target.exists()) {
      if (await sha256.bind(target.openRead()).first == sourceDigest) return;
      await backup.parent.create(recursive: true);
      if (!await backup.exists()) await target.copy(backup.path);
    }
    await target.parent.create(recursive: true);
    final staged = File('${target.path}.migrating');
    await source.copy(staged.path);
    if (await sha256.bind(staged.openRead()).first != sourceDigest) {
      throw StateError('Could not verify migrated application data');
    }
    await staged.copy(target.path);
    if (await sha256.bind(target.openRead()).first != sourceDigest) {
      throw StateError('Could not verify activated application data');
    }
    await staged.delete();
  }
}

/// Routes application files to AppData while leaving Documents unchanged.
class _ApplicationPaths extends PathProviderPlatform {
  _ApplicationPaths(this.original, this.root, this.downloads);
  final PathProviderPlatform original;
  final String root;
  final String downloads;
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
  Future<String?> getDownloadsPath() async => downloads;
}

/// Explains a failed pre-boot migration without offering destructive reset.
class _StorageRecoveryScreen extends StatelessWidget {
  const _StorageRecoveryScreen({required this.onRetry});
  final VoidCallback onRetry;

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
                Icons.folder_off_outlined,
                size: 48,
                color: Color(0xffff465b),
              ),
              const SizedBox(height: 20),
              const Text(
                'Your app data could not be opened',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              const Text(
                'Your previous files have been kept. Make sure the previous data folder or drive is available and there is enough free space, then try again.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Keeps the first upgrade responsive while large extension/browser files copy.
class _StorageProgressScreen extends StatelessWidget {
  const _StorageProgressScreen();
  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: Color(0xff0b0b10),
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0xffff465b),
            ),
          ),
          SizedBox(height: 24),
          Text(
            'Preparing your library',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 12),
          Text(
            'Keeping your accounts and settings safe. Your downloads will stay where they are.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

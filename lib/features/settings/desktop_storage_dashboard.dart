import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

import '../../core/cache/media_cache.dart';
import '../../core/desktop/desktop_dialogs.dart';
import '../../core/desktop/desktop_storage.dart';
import '../../core/di/injector.dart';
import '../../core/logging/app_logger.dart';
import '../../core/provider/provider_downloader.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';
import '../../l10n/l10n.dart';

// Windows Storage dashboard (set-6, Option A): one place listing every bucket
// of space the app uses, each with its size and its own Clear button. Before
// this, image/video cache sat under Playback, the poster and source-script
// caches under Storage, sizes were shown differently, and "Clear provider
// cache" wiped the downloaded source scripts in one click with no warning.

/// One kind of space the app uses on this PC.
class StorageBucket {
  const StorageBucket({
    required this.id,
    required this.icon,
    required this.title,
    required this.description,
    required this.measure,
    this.clear,
    this.confirmTitle,
    this.confirmMessage,
    this.destructive = false,
    this.open,
    this.openLabel,
  });

  /// Stable id, used for widget keys and tests.
  final String id;
  final IconData icon;
  final String title;

  /// What lives here, shown under the size.
  final String description;

  /// Bytes used right now.
  final Future<int> Function() measure;

  /// Empties the bucket; null when it can't be cleared here (downloads).
  final Future<void> Function()? clear;

  /// Set for risky buckets: a confirmation is shown first. The message gets
  /// the formatted size so the person knows what they're about to free.
  final String? confirmTitle;
  final String Function(String size)? confirmMessage;

  /// The confirm button is drawn as destructive.
  final bool destructive;

  /// Optional extra action (e.g. "Open" for downloads).
  final VoidCallback? open;
  final String? openLabel;
}

/// The dashboard itself. [buckets] defaults to the real Windows buckets;
/// tests pass fakes.
class DesktopStorageDashboard extends StatefulWidget {
  const DesktopStorageDashboard({super.key, this.buckets, this.onOpenDownloads});

  final List<StorageBucket>? buckets;

  /// Opens the download location settings (the downloads row's action).
  final VoidCallback? onOpenDownloads;

  @override
  State<DesktopStorageDashboard> createState() =>
      _DesktopStorageDashboardState();
}

class _DesktopStorageDashboardState extends State<DesktopStorageDashboard> {
  late final List<StorageBucket> _buckets =
      widget.buckets ?? windowsStorageBuckets(onOpenDownloads: widget.onOpenDownloads);

  /// Measured size per bucket id; missing = still measuring.
  final Map<String, int> _sizes = {};

  /// Buckets being cleared right now (their button shows a spinner).
  final Set<String> _clearing = {};

  @override
  void initState() {
    super.initState();
    for (final b in _buckets) {
      unawaited(_measure(b));
    }
  }

  Future<void> _measure(StorageBucket b) async {
    int size;
    try {
      size = await b.measure();
    } catch (_) {
      size = 0; // unreadable folder: show 0 rather than "measuring" forever
    }
    if (mounted) setState(() => _sizes[b.id] = size);
  }

  Future<void> _clear(StorageBucket b) async {
    final clear = b.clear;
    if (clear == null || _clearing.contains(b.id)) return;
    final before = _sizes[b.id];
    final sizeText = before == null
        ? context.l10n.someSpace
        : MediaCache.formatBytes(before);
    if (b.confirmTitle != null) {
      final ok = await showDesktopConfirm(
        context,
        title: b.confirmTitle!,
        message: b.confirmMessage?.call(sizeText) ?? '',
        confirmLabel: context.l10n.clear,
        destructive: b.destructive,
      );
      if (!ok || !mounted) return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _clearing.add(b.id));
    try {
      await clear();
    } catch (e) {
      AppLogger.instance.log('Clearing ${b.id} failed: $e');
    }
    await _measure(b);
    if (!mounted) return;
    setState(() => _clearing.remove(b.id));
    final after = _sizes[b.id] ?? 0;
    final freed = before == null ? null : (before - after).clamp(0, before);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            freed == null
                ? context.l10n.bucketCleared(b.title)
                : context.l10n.bucketClearedFreed(b.title, MediaCache.formatBytes(freed)),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    // Total of everything measured so far, downloads shown separately.
    final appTotal = _buckets
        .where((b) => b.id != 'downloads')
        .fold<int>(0, (sum, b) => sum + (_sizes[b.id] ?? 0));
    final allMeasured = _buckets.every((b) => _sizes.containsKey(b.id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(26, 4, 24, 10),
          child: Text(
            allMeasured
                ? context.l10n.appUsesStorage(MediaCache.formatBytes(appTotal))
                : context.l10n.measuringStorage,
            key: const ValueKey('storage-total'),
            style: AppText.caption,
          ),
        ),
        SettingsCard(
          children: [for (final b in _buckets) _row(b)],
        ),
      ],
    );
  }

  Widget _row(StorageBucket b) {
    final size = _sizes[b.id];
    final busy = _clearing.contains(b.id);
    final sizeText = size == null
        ? context.l10n.measuringEllipsis
        : MediaCache.formatBytes(size);
    return SettingsTile(
      key: ValueKey('storage-bucket-${b.id}'),
      icon: b.icon,
      title: b.title,
      subtitle: '$sizeText · ${b.description}',
      subtitleMaxLines: null,
      // Row click = the main action (Clear, or Open for downloads).
      onTap: busy ? null : (b.clear != null ? () => _clear(b) : b.open),
      trailing: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (b.open != null)
                  TextButton(
                    onPressed: b.open,
                    child: Text(b.openLabel ?? context.l10n.open),
                  ),
                if (b.clear != null)
                  TextButton(
                    key: ValueKey('storage-clear-${b.id}'),
                    onPressed: (size ?? 0) == 0 && size != null
                        ? null
                        : () => _clear(b),
                    style: TextButton.styleFrom(
                      foregroundColor: b.destructive
                          ? AppColors.accent
                          : AppColors.textPrimary,
                    ),
                    child: Text(context.l10n.clear),
                  ),
              ],
            ),
    );
  }
}

// ── The real Windows buckets ─────────────────────────────────────────────────

/// `<root>\AppData`, where path_provider's support dir points on Windows.
String? get _appData {
  final root = DesktopStorage.root;
  return root == null ? null : p.join(root, 'AppData');
}

/// Total size of the files under [path] (recursive, no symlinks). 0 when the
/// folder is missing or unreadable.
Future<int> storageFolderBytes(String? path) async {
  if (path == null) return 0;
  final dir = Directory(path);
  if (!await dir.exists()) return 0;
  var total = 0;
  try {
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {} // in use / vanished: skip it
      }
    }
  } catch (_) {}
  return total;
}

Future<int> _fileBytes(String? path) async {
  if (path == null) return 0;
  try {
    final f = File(path);
    return await f.exists() ? await f.length() : 0;
  } catch (_) {
    return 0;
  }
}

/// Deletes everything inside [path] (the folder itself stays). Entries in
/// use, usually files another part of the app has open, are skipped instead
/// of failing the whole clear.
Future<void> emptyStorageFolder(String? path) async {
  if (path == null) return;
  final dir = Directory(path);
  if (!await dir.exists()) return;
  try {
    await for (final e in dir.list(followLinks: false)) {
      try {
        await e.delete(recursive: true);
      } catch (_) {} // in use: leave it
    }
  } catch (_) {}
}

String? _under(String? base, String name) =>
    base == null ? null : p.join(base, name);

// Folders where installed extensions keep their files and data.
const _extensionFolders = [
  'aniyomi',
  'mihon',
  'mangayomi',
  'cloudstream',
  'desktop-extensions',
];

/// Every bucket shown on Windows, in display order.
List<StorageBucket> windowsStorageBuckets({VoidCallback? onOpenDownloads}) {
  final data = _appData;
  final engine = _under(data, 'desktop-extensions');
  final engineLog = _under(engine, 'extension-engine.log');
  final appLog = _under(data, 'zangetsu.log');
  final savedLogs = _under(data, 'logs');
  final pageFiles = _under(data, 'page_files');
  // No context here; appL10n follows the app language.
  final l10n = appL10n;
  return [
    StorageBucket(
      id: 'posters',
      icon: Icons.image_outlined,
      title: l10n.storagePostersTitle,
      description: l10n.storagePostersDescription,
      measure: MediaCache.imageCacheBytes,
      clear: MediaCache.clearImageCache,
    ),
    StorageBucket(
      id: 'temp',
      icon: Icons.movie_outlined,
      title: l10n.storageTempTitle,
      description: l10n.storageTempDescription,
      measure: () async {
        // The temp area also holds the poster cache, counted above.
        final temp = await MediaCache.sizeBytes();
        final posters = await MediaCache.imageCacheBytes();
        return (temp - posters).clamp(0, temp) +
            await storageFolderBytes(pageFiles);
      },
      clear: () async {
        await MediaCache.clear();
        if (pageFiles != null) {
          await emptyStorageFolder(pageFiles);
        }
      },
    ),
    StorageBucket(
      id: 'sources',
      icon: Icons.code_rounded,
      title: l10n.storageScriptsTitle,
      description: l10n.storageScriptsDescription,
      measure: () async => providerScriptBytes(),
      clear: () => sl<ProviderDownloader>().clear(),
      confirmTitle: l10n.storageScriptsConfirmTitle,
      confirmMessage: (size) =>
          l10n.storageScriptsConfirmMessage(size),
      destructive: true,
    ),
    StorageBucket(
      id: 'extensions',
      // Material twin of the Lucide 'blocks' icon used for Sources in the
      // Settings nav and on the rail, so this bucket reads as "sources".
      icon: Icons.widgets_outlined,
      title: l10n.storageExtensionsTitle,
      description: l10n.storageExtensionsDescription,
      measure: () async {
        var total = 0;
        for (final name in _extensionFolders) {
          total += await storageFolderBytes(_under(data, name));
        }
        // The engine log is counted under Logs instead.
        return (total - await _fileBytes(engineLog)).clamp(0, total);
      },
      clear: () async {
        final cache = _under(engine, 'cache');
        if (cache != null) {
          await emptyStorageFolder(cache);
        }
      },
      confirmTitle: l10n.storageExtensionsConfirmTitle,
      confirmMessage: (size) =>
          l10n.storageExtensionsConfirmMessage(size),
    ),
    StorageBucket(
      id: 'logs',
      icon: Icons.receipt_long_outlined,
      title: l10n.storageLogsTitle,
      description: l10n.storageLogsDescription,
      measure: () async =>
          await _fileBytes(appLog) +
          await _fileBytes(engineLog) +
          await storageFolderBytes(savedLogs),
      clear: () async {
        // A log line queued meanwhile is simply appended after the truncate.
        for (final path in [appLog, engineLog]) {
          if (path == null) continue;
          try {
            final f = File(path);
            if (await f.exists()) await f.writeAsString('');
          } catch (_) {} // held open by the extension engine: keep it
        }
        if (savedLogs != null) {
          await emptyStorageFolder(savedLogs);
        }
      },
      confirmTitle: l10n.storageLogsConfirmTitle,
      confirmMessage: (size) =>
          l10n.storageLogsConfirmMessage(size),
    ),
    StorageBucket(
      id: 'downloads',
      icon: Icons.download_rounded,
      title: l10n.settingsSectionDownloads,
      description:
          DesktopStorage.downloadsRoot ?? l10n.storageDownloadsDescription,
      measure: () => storageFolderBytes(DesktopStorage.downloadsRoot),
      open: onOpenDownloads,
      openLabel: l10n.manage,
    ),
  ];
}

/// Size of the cached provider scripts (the Hive box's JS text). 0 when the
/// box isn't open.
int providerScriptBytes() {
  if (!Hive.isBoxOpen(ProviderDownloader.boxName)) return 0;
  var total = 0;
  for (final v in Hive.box<Map>(ProviderDownloader.boxName).values) {
    final js = v['jsCode'];
    if (js is String) total += utf8.encode(js).length;
  }
  return total;
}

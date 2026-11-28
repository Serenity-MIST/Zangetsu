import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../core/desktop/desktop_reveal.dart';
import '../../core/ui/desktop_settings_surface.dart';
import '../../core/di/injector.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/ui/settings_search_target.dart';
import 'desktop_settings_workspace.dart' show DesktopSettingsColumn;

/// A clear, human folder name derived from a SAF directory tree URI — the
/// SAME uri downloads are written into — so the label can never misname the
/// real target. E.g.
///   …/tree/primary%3AMovies          → "Internal storage › Movies"
///   …/tree/primary%3AMovies%2FAnime  → "Internal storage › Movies › Anime"
///   …/tree/1A2B-3C4D%3ADownloads     → "SD card › Downloads"
String folderLabelFromUri(Uri treeUri) {
  final segs = treeUri.pathSegments;
  final docId = segs.isEmpty ? '' : Uri.decodeComponent(segs.last);
  final colon = docId.indexOf(':');
  final volume = colon < 0 ? '' : docId.substring(0, colon);
  final path = colon < 0 ? docId : docId.substring(colon + 1);
  final root = volume.isEmpty
      ? null
      : (volume == 'primary' ? 'Internal storage' : 'SD card');
  final parts = path.split('/').where((p) => p.isNotEmpty).toList();
  if (root == null && parts.isEmpty) return 'Folder';
  return [?root, ...parts].join(' › ');
}

/// Lets the user pick a custom SAF directory for MP4 downloads, or reset
/// back to the default Downloads › Zangetsu location.
class DownloadLocationScreen extends StatefulWidget {
  const DownloadLocationScreen({super.key});

  @override
  State<DownloadLocationScreen> createState() => _DownloadLocationScreenState();
}

class _DownloadLocationScreenState extends State<DownloadLocationScreen> {
  // Detected drives (internal + any SD/USB/SSD) — the CloudStream-style list
  // that works without the SAF picker. Loaded from the native side.
  List<({String path, String label, bool removable})> _volumes = const [];

  @override
  void initState() {
    super.initState();
    _loadVolumes();
  }

  Future<void> _loadVolumes() async {
    // Only Android exposes its storage-volume API. Windows uses the native
    // directory picker and must not initialize download services to list it.
    if (_isWindows) return;
    final v = await sl<DownloadManager>().listDownloadVolumes();
    if (mounted) setState(() => _volumes = v);
  }

  /// Windows build: desktop styling, real paths and Explorer actions.
  bool get _isWindows => defaultTargetPlatform == TargetPlatform.windows;

  @override
  Widget build(BuildContext context) {
    // Windows reaches this page from the Downloads dock tab, Home and the
    // reader export too, all outside the settings workspace. Provide the
    // desktop settings scope here so it always renders the graphite design,
    // with the column centred in the window since no sidebar stands beside it.
    if (_isWindows && !DesktopSettingsScope.contains(context)) {
      return DesktopSettingsScope(
        standalone: true,
        child: Builder(builder: _page),
      );
    }
    return _page(context);
  }

  /// Windows: pick a folder; a folder that can't be written is refused with
  /// the reason, so the label never names a folder downloads would fail in.
  Future<void> _chooseWindowsFolder() async {
    final prefs = sl<DownloadPrefs>();
    final messenger = ScaffoldMessenger.of(context);
    final changed = await prefs.chooseDesktopFolder();
    if (!mounted) return;
    setState(() {});
    final error = prefs.lastFolderError;
    if (error != null) {
      (messenger..hideCurrentSnackBar()).showSnackBar(
        SnackBar(content: Text(error)),
      );
    } else if (changed) {
      (messenger..hideCurrentSnackBar()).showSnackBar(
        SnackBar(
          content: Text('New downloads will save to ${prefs.locationUri}'),
        ),
      );
    }
  }

  /// Windows: back to Downloads\Zangetsu, applied immediately.
  Future<void> _resetWindowsFolder() async {
    final prefs = sl<DownloadPrefs>();
    final messenger = ScaffoldMessenger.of(context);
    await prefs.resetToDefault();
    if (!mounted) return;
    setState(() {});
    (messenger..hideCurrentSnackBar()).showSnackBar(
      SnackBar(
        content: Text('New downloads will save to ${prefs.locationUri}'),
      ),
    );
  }

  /// Windows: opens the current download folder in File Explorer. The folder
  /// is created on the first download, so a missing one is explained.
  Future<void> _openWindowsFolder(String path) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await revealInExplorer(path)) {
      (messenger..hideCurrentSnackBar()).showSnackBar(
        const SnackBar(
          content: Text(
            "This folder doesn't exist yet. Zangetsu creates it with your "
            'first download.',
          ),
        ),
      );
    }
  }

  /// Windows page body: the folder as a full path and open/choose/reset
  /// actions, laid out like the Reader page: a plain list from the left edge
  /// whose cards cap themselves at the shared settings width.
  Widget _windowsPage(BuildContext context) {
    final prefs = sl<DownloadPrefs>();
    final current = prefs.locationUri;
    final hasFolder =
        current != null && current.isNotEmpty && !isUriPath(current);
    final fallback = DownloadPrefs.windowsDefaultFolder;
    return Scaffold(
      backgroundColor: settingsPageBackground(context),
      appBar: settingsAppBar(context.l10n.downloadLocation),
      body: ListView(
        padding: DesktopSettingsScope.listPadding(context, top: 4, bottom: 28),
        children: [
          SettingsSectionLabel(context.l10n.currentLocation, first: true),
          SettingsCard(
            children: [
              SettingsTile(
                key: const ValueKey('download-location-current'),
                icon: Icons.folder_rounded,
                title: hasFolder
                    ? current
                    : 'Choose a folder before your first download',
                subtitle: hasFolder && prefs.isDefaultLocation
                    ? 'Default folder'
                    : null,
              ),
              if (hasFolder)
                SettingsTile(
                  key: const ValueKey('download-location-open'),
                  icon: Icons.open_in_new_rounded,
                  title: context.l10n.openInFileExplorer,
                  onTap: () => _openWindowsFolder(current),
                ),
            ],
          ),
          const SettingsSectionLabel('Change location'),
          SettingsCard(
            children: [
              SettingsTile(
                key: const ValueKey('download-location-choose'),
                icon: Icons.folder_open_outlined,
                title: context.l10n.chooseFolder,
                subtitle: 'Pick any folder or drive on this PC',
                onTap: _chooseWindowsFolder,
              ),
              // Hidden while the default is already in use: resetting
              // would change nothing.
              if (!prefs.isDefaultLocation && fallback != null)
                SettingsTile(
                  key: const ValueKey('download-location-reset'),
                  icon: Icons.restore_rounded,
                  title: context.l10n.resetToDefault,
                  subtitle: fallback,
                  onTap: _resetWindowsFolder,
                ),
            ],
          ),
          // Under the cards, starting where the section titles do.
          DesktopSettingsColumn(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(2, 12, 2, 0),
              child: Text(
                context.l10n.newDownloadsSaveHere,
                style: AppText.caption,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _page(BuildContext context) {
    if (_isWindows) return _windowsPage(context);
    final prefs = sl<DownloadPrefs>();
    final current = prefs.locationUri;
    return Scaffold(
      backgroundColor: settingsPageBackground(context),
      appBar: settingsAppBar(context.l10n.downloadLocation),
      body: SettingsSearchList(
        padding: const EdgeInsets.only(top: 4, bottom: 28),
        children: [
          SettingsSectionLabel(context.l10n.currentLocation),
          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.folder_rounded,
                      color: AppColors.textSecondary,
                      size: 22,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        downloadDestinationLabel(
                          keepPrivate: prefs.keepPrivate,
                          locationLabel: prefs.locationLabel,
                          publicFallback: _isWindows
                              ? 'Choose a folder before your first download'
                              : context.l10n.downloadsZangetsu,
                        ),
                        style: AppText.body,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // While the private toggle is on, a picked folder is OVERRIDDEN — the
          // file never leaves app storage. Offering the drive list and the
          // folder picker then is a lie: they look actionable but change
          // nothing. Hide them instead, so the screen states one truth.
          if (!prefs.keepPrivate && _volumes.isNotEmpty) ...[
            SettingsSectionLabel(context.l10n.availableDrives),
            SettingsCard(
              children: [
                for (final v in _volumes)
                  SettingsTile(
                    icon: v.removable
                        ? Icons.sd_storage_rounded
                        : Icons.smartphone_rounded,
                    title: v.label,
                    subtitle: v.removable
                        ? context.l10n.removableDrive
                        : context.l10n.onThisDevice,
                    iconAccent: current == v.path,
                    trailing: current == v.path
                        ? Icon(
                            Icons.check_rounded,
                            color: AppColors.accent,
                            size: 20,
                          )
                        : null,
                    onTap: () async {
                      await sl<DownloadPrefs>().setLocation(v.path, v.label);
                      if (mounted) setState(() {});
                    },
                  ),
              ],
            ),
          ],
          if (!prefs.keepPrivate)
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.folder_open_outlined,
                  title: context.l10n.chooseFolder,
                  onTap: () async {
                    if (_isWindows) {
                      await prefs.chooseDesktopFolder();
                      if (mounted) setState(() {});
                      return;
                    }
                    final uri = await FileDownloader().uri.pickDirectory(
                      persistedUriPermission: true,
                    );
                    if (uri == null) return; // canceled
                    await sl<DownloadPrefs>().setLocation(
                      uri.toString(),
                      folderLabelFromUri(uri),
                    );
                    if (mounted) setState(() {});
                  },
                ),
                if (prefs.locationUri != null)
                  SettingsTile(
                    icon: Icons.restore_rounded,
                    title: context.l10n.resetToDefault,
                    onTap: () async {
                      await sl<DownloadPrefs>().setLocation(null, null);
                      if (mounted) setState(() {});
                    },
                  ),
              ],
            ),
          // Its own section label, like every other group on this screen: without
          // one the toggle card butts straight against the folder card above and
          // reads as part of it. This is the gap that separates them.
          if (!_isWindows) ...[
            SettingsSectionLabel(context.l10n.privacy),
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.lock_outline_rounded,
                  title: context.l10n.keepDownloadsPrivate,
                  subtitle: context.l10n.keepDownloadsPrivateSubtitle,
                  subtitleMaxLines: null,
                  onTap: () async {
                    await prefs.setKeepPrivate(!prefs.keepPrivate);
                    if (mounted) setState(() {});
                  },
                  trailing: Switch.adaptive(
                    value: prefs.keepPrivate,
                    activeThumbColor: AppColors.accent,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (v) async {
                      await prefs.setKeepPrivate(v);
                      if (mounted) setState(() {});
                    },
                  ),
                ),
              ],
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              context.l10n.newDownloadsSaveHere,
              style: AppText.caption,
            ),
          ),
        ],
      ),
    );
  }
}

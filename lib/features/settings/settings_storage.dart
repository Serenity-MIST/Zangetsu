// Storage settings: cache and space used by the app.
part of 'settings_screen.dart';

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

class StorageSettingsScreen extends StatefulWidget {
  const StorageSettingsScreen({super.key});

  @override
  State<StorageSettingsScreen> createState() => _StorageSettingsScreenState();
}

class _StorageSettingsScreenState extends State<StorageSettingsScreen> {
  /// Windows build: shows the real cache size and the app data folder.
  /// Read through the theme (it defaults to defaultTargetPlatform) because
  /// this part file cannot add its own foundation import.
  bool get _isWindows => Theme.of(context).platform == TargetPlatform.windows;

  // Windows sizes and clears every bucket in [DesktopStorageDashboard]
  // (set-6), so the per-row Windows measuring that used to live here is gone;
  // the rows below are phone/TV only.

  Future<void> _clearImageCache() async {
    final messenger = ScaffoldMessenger.of(context);
    final cleared = context.l10n.imageCacheCleared;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    try {
      await DefaultCacheManager().emptyCache();
    } catch (_) {
      // Best-effort — clearing the live image cache above is the part
      // that matters for freeing memory immediately.
    }
    messenger.showSnackBar(SnackBar(content: Text(cleared)));
  }

  Future<void> _clearProviderCache() async {
    final messenger = ScaffoldMessenger.of(context);
    final cleared = context.l10n.providerCacheCleared;
    await sl<ProviderDownloader>().clear();
    messenger.showSnackBar(SnackBar(content: Text(cleared)));
  }

  /// Windows: opens the app's data folder in File Explorer.
  Future<void> _openAppData() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await MediaCache.openAppDataFolder()) {
      messenger.showSnackBar(
        const SnackBar(content: Text("The app data folder couldn't be found.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final appData = _isWindows ? MediaCache.appDataFolder : null;
    // Windows (set-6): one dashboard with a size and Clear per bucket, risky
    // ones confirmed. Phone/TV keep the original two rows below.
    if (_isWindows) {
      return Scaffold(
        backgroundColor: settingsPageBackground(context),
        appBar: settingsAppBar(context.l10n.storage),
        body: ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 28),
          children: [
            DesktopStorageDashboard(
              onOpenDownloads: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DownloadLocationScreen(),
                ),
              ),
            ),
            if (appData != null) ...[
              const SizedBox(height: 12),
              SettingsCard(
                children: [
                  // Where settings, sources and caches live on this PC.
                  SettingsTile(
                    key: const ValueKey('storage-open-app-data'),
                    icon: Icons.folder_open_outlined,
                    title: context.l10n.openAppDataFolder,
                    subtitle: appData,
                    onTap: _openAppData,
                  ),
                ],
              ),
            ],
          ],
        ),
      );
    }
    return Scaffold(
      backgroundColor: settingsPageBackground(context),
      appBar: settingsAppBar(context.l10n.storage),
      body: SettingsSearchList(
        clipBehavior: sl<AppMode>().isTv ? Clip.none : Clip.hardEdge,
        padding: const EdgeInsets.only(top: 8, bottom: 28),
        children: [
          SettingsCard(
            children: [
              SettingsTile(
                autofocus: true,
                icon: Icons.image_outlined,
                title: context.l10n.clearImageCache,
                onTap: _clearImageCache,
              ),
              SettingsTile(
                icon: Icons.cleaning_services_outlined,
                title: context.l10n.clearProviderCache,
                subtitle: context.l10n.cachedSourceJsFiles,
                onTap: _clearProviderCache,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

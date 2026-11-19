enum BackupBundle { sources, library, settings }

class BackupFormatException implements Exception {
  const BackupFormatException(this.message);
  final String message;
  @override
  String toString() => 'BackupFormatException: $message';
}

const _kApp = 'zangetsu';
const _kVersion = 1;

Map<String, dynamic> wrapPayload(
  Map<BackupBundle, Map<String, dynamic>> bundles, {
  required String createdAtIso,
}) => {
  'app': _kApp,
  'version': _kVersion,
  'createdAt': createdAtIso,
  'bundles': {for (final e in bundles.entries) e.key.name: e.value},
};

/// When the backup in [raw] was made (its `createdAt`), or null when missing
/// or unreadable. Shown in the restore preview.
DateTime? backupCreatedAt(Map<String, dynamic> raw) {
  final v = raw['createdAt'];
  return v is String ? DateTime.tryParse(v) : null;
}

/// One counted thing inside a bundle, e.g. (count: 120, label: 'list items').
typedef BackupCount = ({int count, String label});

/// What a backup holds, per bundle, with counts for the restore preview
/// (acct-4). Bundles missing from the backup are absent from the map. Never
/// throws: odd or old payloads just give fewer counts.
Map<BackupBundle, List<BackupCount>> summarizeBackup(Map<String, dynamic> raw) {
  final bundles = raw['bundles'];
  if (bundles is! Map) return const {};
  int len(Object? v) => v is List ? v.length : (v is Map ? v.length : 0);
  final out = <BackupBundle, List<BackupCount>>{};

  final sources = bundles['sources'];
  if (sources is Map) {
    // Installed sources from every extension kind the sources bundle knows.
    final installed =
        len(sources['providers']) +
        len(sources['csPlugins']) +
        len(sources['aniyomiPkgs']) +
        len(sources['mihonPkgs']) +
        len(sources['lnreaderPkgs']) +
        len(sources['mangayomiSourceKeys']);
    final repos =
        len(sources['jsRepoUrls']) +
        len(sources['csRepoUrls']) +
        len(sources['aniyomiRepoUrls']) +
        len(sources['mihonRepoUrls']) +
        len(sources['lnreaderRepoUrls']) +
        len(sources['mangayomiRepoUrls']);
    out[BackupBundle.sources] = [
      // Labels are stable ids; the restore dialog turns them into
      // translated "N things" text (backupCountText).
      (count: installed, label: 'sources'),
      (count: repos, label: 'repos'),
    ];
  }

  final library = bundles['library'];
  if (library is Map) {
    // Categories: count the category rows, not the per-title assignment rows.
    var categories = 0;
    final cats = library['listCategories'];
    if (cats is Map) {
      for (final e in cats.entries) {
        if (e.key.toString().endsWith('__categories__')) {
          categories += len(e.value);
        }
      }
    }
    out[BackupBundle.library] = [
      (
        count: len(library['myList']) + len(library['profileMyList']),
        label: 'list items',
      ),
      (
        count: len(library['history']) + len(library['profileHistory']),
        label: 'in Continue Watching',
      ),
      (count: len(library['readHistory']), label: 'reading history'),
      (count: categories, label: 'categories'),
      (count: len(library['resumePositions']), label: 'resume points'),
    ];
  }

  final settings = bundles['settings'];
  if (settings is Map) {
    out[BackupBundle.settings] = [
      (
        // Setting groups = every box except the hand-made matches.
        count: settings.keys.where((k) => k != 'zmode_matches').length,
        label: 'setting groups',
      ),
      (
        count: (settings['zmode_matches'] is Map)
            ? (settings['zmode_matches'] as Map).keys
                  .where((k) => !k.toString().startsWith('label:'))
                  .length
            : 0,
        label: 'hand-made title matches',
      ),
    ];
  }
  return out;
}

Map<BackupBundle, Map<String, dynamic>> unwrapPayload(
  Map<String, dynamic> raw,
) {
  if (raw['app'] != _kApp) {
    throw const BackupFormatException("This isn't a Zangetsu backup.");
  }
  if ((raw['version'] as num? ?? 0) > _kVersion) {
    throw const BackupFormatException('Made by a newer version of Zangetsu.');
  }
  final bundles = (raw['bundles'] as Map?) ?? const {};
  final out = <BackupBundle, Map<String, dynamic>>{};
  for (final b in BackupBundle.values) {
    final v = bundles[b.name];
    if (v is Map) out[b] = Map<String, dynamic>.from(v);
  }
  return out;
}

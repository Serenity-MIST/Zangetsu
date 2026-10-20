import 'dart:math';
import '../../core/mode/content_mode.dart';
import '../../core/models/provider_info.dart';
import '../../core/zmode/zmode_prefs.dart';

import '../../core/models/watch_status.dart';
import 'cubit/my_list_cubit.dart';

/// Picks one entry from the already-filtered library view, or null when it is
/// empty. The optional [random] keeps the choice deterministic in tests.
T? pickRandomLibraryEntry<T>(List<T> entries, {Random? random}) {
  if (entries.isEmpty) return null;
  return entries[(random ?? Random()).nextInt(entries.length)];
}

/// Fixed tab order matching the phone My List screen.
const libraryStatusTabOrder = [
  WatchStatus.watching,
  WatchStatus.planning,
  WatchStatus.completed,
  WatchStatus.paused,
  WatchStatus.dropped,
];

/// Statuses that actually have at least one entry, in [libraryStatusTabOrder].
List<WatchStatus> presentLibraryStatuses(List<MyListEntry> entries) =>
    libraryStatusTabOrder
        .where((s) => entries.any((e) => e.status == s))
        .toList();

/// Filter a library list the same way the phone tabs do.
List<MyListEntry> filterLibraryEntries(
  List<MyListEntry> entries, {
  WatchStatus? status,
  String? customList,
  bool Function(MyListEntry)? inCategory,
}) {
  return [
    for (final e in entries)
      if ((status == null || e.status == status) &&
          (customList == null || e.customLists.contains(customList)) &&
          (inCategory == null || inCategory(e)))
        e,
  ];
}

/// Filters New-style My List by dock media, separating anime from movie/TV
/// within Streaming without changing the underlying saved entries.
List<MyListEntry> libraryEntriesForDock(
  List<MyListEntry> entries,
  ContentMode mode,
  StreamKind kind,
) => entries
    .where(
      (e) =>
          mode.matchesProvider(e.item.type) &&
          (mode != ContentMode.anime ||
              e.item.type ==
                  (kind == StreamKind.movie
                      ? ProviderType.movie
                      : ProviderType.anime)),
    )
    .toList();

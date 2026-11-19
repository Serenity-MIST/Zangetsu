import 'dart:io';

import 'package:path/path.dart' as p;

import 'download_record.dart';

/// Subtitle file types the player can load from disk.
const _subtitleExtensions = {'.srt', '.vtt', '.ass', '.ssa', '.sub'};

/// Label given to a saved subtitle whose language is not in its file name:
/// HLS rendition files (`<video>_<n>.vtt`) and languages written in a
/// non-Latin script, which the saved name turns into underscores.
const String kUnlabelledSubtitle = 'Subtitles';

/// Finds the subtitle files saved for one downloaded video by looking at disk.
///
/// The download manager writes each subtitle as
/// `<show folder>/Subtitles/<video file name>_<language>_<n>.<ext>` (or
/// `<video file name>_<n>.vtt` for HLS renditions). Some downloads ended up
/// with those files on disk but an empty subtitle list in their record, so the
/// player showed nothing. This recovers them.
///
/// Matching is strict: a file must start with this video's full file name
/// (which contains the download's unique 32-character tag) followed by `_`,
/// so another episode's subtitles can never be picked up, not even episode 10
/// for episode 1. Links, empty files and anything outside the folder are
/// ignored. It only reads; nothing is created, changed or deleted.
///
/// The first file found (by number) is marked as the default track.
List<OfflineSubtitle> discoverSubtitleSidecars(String videoPath) {
  if (videoPath.isEmpty) return const [];
  final stem = p.basenameWithoutExtension(videoPath);
  if (stem.isEmpty) return const [];
  final folder = p.join(p.dirname(videoPath), 'Subtitles');
  final dir = Directory(folder);
  final found = <({int index, OfflineSubtitle sub})>[];
  try {
    if (!dir.existsSync()) return const [];
    final prefix = '${stem.toLowerCase()}_';
    // Cheap name checks first; the folder is shared by every episode of the
    // show. listSync(followLinks: false) reports links as Link, not File, so
    // the type check below already skips them.
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if (!_subtitleExtensions.contains(ext)) continue;
      final name = p.basenameWithoutExtension(entity.path);
      // Case-insensitive: Windows treats these names as the same file.
      if (!name.toLowerCase().startsWith(prefix)) continue;
      if (!p.isWithin(folder, entity.path)) continue;
      final parsed = _parseSuffix(name.substring(stem.length + 1));
      if (parsed == null) continue;
      try {
        if (entity.lengthSync() == 0) continue;
      } on FileSystemException {
        continue;
      }
      found.add((
        index: parsed.index,
        sub: OfflineSubtitle(
          lang: parsed.language,
          label: parsed.language,
          path: entity.path,
        ),
      ));
    }
  } on FileSystemException {
    return const [];
  }
  found.sort((a, b) => a.index.compareTo(b.index));
  return [
    for (var i = 0; i < found.length; i++)
      OfflineSubtitle(
        lang: found[i].sub.lang,
        label: found[i].sub.label,
        path: found[i].sub.path,
        isDefault: i == 0,
      ),
  ];
}

/// Splits the part after `<video name>_` into a readable language and the
/// track number: `English__Original_Audio__1` → ("English Original Audio", 1),
/// `en_2` → ("en", 2), `1` → ("Subtitles", 1). Returns null for anything that
/// does not end in a track number (not one of ours).
({String language, int index})? _parseSuffix(String suffix) {
  // "1" (HLS rendition) or "_1" / "___1" (a language name that was blank or
  // written in a non-Latin script, which the saved name turned into
  // underscores): still a real subtitle, just without a readable language.
  final unlabelled = RegExp(r'^_*(\d+)$').firstMatch(suffix);
  if (unlabelled != null) {
    return (
      language: kUnlabelledSubtitle,
      index: int.parse(unlabelled.group(1)!),
    );
  }
  final match = RegExp(r'^(.+?)_+(\d+)$').firstMatch(suffix);
  if (match == null) return null;
  // The manager turned spaces and brackets into underscores; undo that for a
  // readable label. Language matching in the player works on names too.
  final language = match.group(1)!.replaceAll(RegExp(r'_+'), ' ').trim();
  return (
    language: language.isEmpty ? kUnlabelledSubtitle : language,
    index: int.parse(match.group(2)!),
  );
}

/// The subtitles to use for [record]: its own saved list when those files
/// still exist, otherwise whatever [discoverSubtitleSidecars] finds next to the
/// video. Never returns entries whose file is missing.
List<OfflineSubtitle> playableSubtitlesFor(DownloadRecord record) {
  final saved = [
    for (final s in record.subtitles)
      if (s.path.isNotEmpty && File(s.path).existsSync()) s,
  ];
  if (saved.isNotEmpty) return saved;
  final path = record.filePath;
  if (path == null || path.isEmpty) return const [];
  return discoverSubtitleSidecars(path);
}

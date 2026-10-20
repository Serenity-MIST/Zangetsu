import '../playback/subtitle_language.dart';

/// Select one complete subtitle in the requested language, before any download.
List<T> downloadSubtitleSelection<T>(
  List<T> tracks,
  String preference, {
  required String Function(T) language,
  required String Function(T) label,
}) {
  if (preference == 'off') return [];
  final wanted = languageByPref(preference);
  if (wanted == null) return [];
  final matches = tracks
      .where(
        (track) =>
            matchesSourceLang('${language(track)} ${label(track)}', wanted),
      )
      .toList();
  if (matches.isEmpty) return [];
  final full = matches
      .where(
        (track) => !RegExp(
          r'\b(forced|signs|songs)\b',
          caseSensitive: false,
        ).hasMatch(label(track)),
      )
      .toList();
  return [full.isEmpty ? matches.first : full.first];
}

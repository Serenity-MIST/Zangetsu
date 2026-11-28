import '../playback/hls.dart';
import '../playback/subtitle_language.dart';

/// The requested spoken language is absent from the selected video's group.
class HlsAudioSelectionException implements Exception {
  const HlsAudioSelectionException(this.language);
  final String language;
  @override
  String toString() =>
      'The selected audio language ($language) is unavailable in this stream';
}

/// Select one external audio rendition, preserving the video/audio group link.
/// Null means this variant has no external rendition to download separately;
/// it does not certify the language of audio already multiplexed in the video.
HlsAudioRendition? selectDownloadAudio(
  String master,
  String masterUrl,
  HlsVariant variant, {
  String? preferredLanguage,
}) {
  final group = variant.audioGroup;
  if (group == null || group.isEmpty) return null;
  final renditions = parseHlsAudioRenditions(
    master,
    masterUrl,
  ).where((rendition) => rendition.groupId == group).toList();
  if (renditions.isEmpty) return null;
  final preference = preferredLanguage?.trim().toLowerCase() ?? '';
  final matching = preference.isEmpty
      ? renditions
      : renditions.where((rendition) {
          final languages = kSubtitleLanguages
              .where((language) => matchesSourceLang(preference, language))
              .toList();
          return languages.length == 1
              ? matchesSourceLang(rendition.lang, languages.single) ||
                    matchesSourceLang(rendition.name, languages.single)
              : rendition.lang.toLowerCase() == preference;
        }).toList();
  if (matching.isEmpty) throw HlsAudioSelectionException(preference);
  return matching.firstWhere(
    (rendition) => rendition.isDefault,
    orElse: () => matching.first,
  );
}

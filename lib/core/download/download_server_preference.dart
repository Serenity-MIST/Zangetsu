import '../playback/subtitle_language.dart';
import '../models/video_source.dart';

/// Stable server affinity for a batch, never an episode-specific signed URL.
/// Fresh per-episode streams may change order or token while retaining a label
/// or host. Unavailable choices leave other mirrors available as fallbacks.
class DownloadServerPreference {
  const DownloadServerPreference({
    required this.label,
    required this.host,
    this.audioLanguage,
  });
  factory DownloadServerPreference.fromSource(VideoSource source) =>
      DownloadServerPreference(
        label: source.label?.trim() ?? '',
        host: Uri.tryParse(source.url)?.host.toLowerCase() ?? '',
        audioLanguage: _audioLanguage(source.audioLang),
      );
  final String label;
  final String host;

  /// Explicit source audio language, independent of sub/dub and subtitle prefs.
  /// Null means unspecified or multi-audio; it is not a verified English track.
  final String? audioLanguage;

  static String? _audioLanguage(String? value) {
    final text = value?.trim().toLowerCase() ?? '';
    if (text.isEmpty ||
        const ['und', 'mul', 'multi', 'unknown', 'multiple'].contains(text)) {
      return null;
    }
    final matches = kSubtitleLanguages
        .where((lang) => matchesSourceLang(text, lang))
        .toList();
    if (matches.length > 1) return null;
    return matches.isEmpty ? text : matches.single.iso1;
  }

  Map<String, dynamic> toMap() => {
    'label': label,
    'host': host,
    'audioLanguage': audioLanguage,
  };
  factory DownloadServerPreference.fromMap(Map raw) => DownloadServerPreference(
    label: raw['label'] is String ? raw['label'] as String : '',
    host: raw['host'] is String ? raw['host'] as String : '',
    audioLanguage: raw['audioLanguage'] is String
        ? _audioLanguage(raw['audioLanguage'] as String)
        : null,
  );

  /// Language constrains eligible links; stable server buckets retain quality
  /// order within each group. Unknown-language links cannot satisfy explicit audio.
  List<VideoSource> prioritize(List<VideoSource> sources) {
    int score(VideoSource source) =>
        (label.isNotEmpty &&
                source.label?.trim().toLowerCase() == label.toLowerCase()
            ? 2
            : 0) +
        (host.isNotEmpty &&
                Uri.tryParse(source.url)?.host.toLowerCase() ==
                    host.toLowerCase()
            ? 1
            : 0);
    return [
      for (var priority = 3; priority >= 0; priority--)
        ...sources.where(
          (source) =>
              score(source) == priority &&
              (audioLanguage == null ||
                  _audioLanguage(source.audioLang) == audioLanguage),
        ),
    ];
  }
}

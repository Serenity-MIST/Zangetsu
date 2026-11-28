import '../playback/subtitle_language.dart';
import '../models/video_source.dart';
import 'download_link_label.dart';

/// Stable server affinity for a batch, never an episode-specific signed URL.
/// Fresh per-episode streams may change order or token while retaining a label
/// or host. Unavailable choices leave other mirrors available as fallbacks.
class DownloadServerPreference {
  const DownloadServerPreference({
    required this.label,
    required this.host,
    this.audioLanguage,
    this.audioKind,
    this.exact = false,
  });

  /// Preference for the picked [source]. [exact] pins a single-episode pick
  /// to that server (see [exact]); batches leave it off.
  factory DownloadServerPreference.fromSource(
    VideoSource source, {
    bool exact = false,
  }) => DownloadServerPreference(
    // Server name, not just `label`: Aniyomi/Anikoto keep the server name in
    // `quality` ("HD - 1 - 1080p"), which used to leave this empty and made
    // every mirror on one host tie.
    label: downloadServerName(source),
    host: Uri.tryParse(source.url)?.host.toLowerCase() ?? '',
    audioLanguage: _audioLanguage(source.audioLang),
    audioKind: _kindName(source.kind),
    exact: exact,
  );

  /// Server name (provider label, or the server name carried in `quality`).
  final String label;
  final String host;

  /// Explicit source audio language, independent of sub/dub and subtitle prefs.
  /// Null means unspecified or multi-audio; it is not a verified English track.
  final String? audioLanguage;

  /// SUB/DUB/RAW kind of the picked link ('sub', 'dub', 'raw'); null when the
  /// pick had no known kind (old jobs, unlabelled sources).
  final String? audioKind;

  /// True for a link the viewer picked by hand for one episode: re-resolves
  /// keep only links of that same server name (when any still exist) and the
  /// job never sweeps to another source.
  final bool exact;

  /// Known kind name, or null for [AudioKind.unknown].
  static String? _kindName(AudioKind kind) =>
      kind == AudioKind.unknown ? null : kind.name;

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
    // Only written when set, so old readers see the same map as before.
    if (audioKind != null) 'audioKind': audioKind,
    if (exact) 'exact': true,
  };

  /// Tolerates maps saved before `audioKind`/`exact` existed.
  factory DownloadServerPreference.fromMap(Map raw) => DownloadServerPreference(
    label: raw['label'] is String ? raw['label'] as String : '',
    host: raw['host'] is String ? raw['host'] as String : '',
    audioLanguage: raw['audioLanguage'] is String
        ? _audioLanguage(raw['audioLanguage'] as String)
        : null,
    audioKind: const ['sub', 'dub', 'raw'].contains(raw['audioKind'])
        ? raw['audioKind'] as String
        : null,
    exact: raw['exact'] == true,
  );

  /// Orders [sources] for this preference:
  /// 1. audio language and audio kind are constraints: a link of another
  ///    known kind (SUB when DUB was picked) is never eligible; unknown-kind
  ///    links stay as a last resort;
  /// 2. then same kind before unknown kind, server-name match (2) before host
  ///    match (1), keeping the incoming (quality) order inside each bucket.
  /// An [exact] pick keeps only its own server's links whenever any exist.
  List<VideoSource> prioritize(List<VideoSource> sources) {
    final kind = audioKind;
    bool nameMatch(VideoSource source) =>
        label.isNotEmpty &&
        downloadServerName(source).toLowerCase() == label.toLowerCase();
    int score(VideoSource source) =>
        (kind != null && source.kind.name == kind ? 4 : 0) +
        (nameMatch(source) ? 2 : 0) +
        (host.isNotEmpty &&
                Uri.tryParse(source.url)?.host.toLowerCase() ==
                    host.toLowerCase()
            ? 1
            : 0);
    final eligible = sources
        .where(
          (source) =>
              (audioLanguage == null ||
                  _audioLanguage(source.audioLang) == audioLanguage) &&
              (kind == null ||
                  source.kind == AudioKind.unknown ||
                  source.kind.name == kind),
        )
        .toList();
    final ordered = [
      for (var priority = 7; priority >= 0; priority--)
        ...eligible.where((source) => score(source) == priority),
    ];
    if (!exact || !ordered.any(nameMatch)) return ordered;
    return ordered.where(nameMatch).toList();
  }
}

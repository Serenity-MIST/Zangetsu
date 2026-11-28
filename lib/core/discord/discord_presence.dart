import '../models/episode.dart';
import '../models/episode_title.dart';

/// Presence "details" line: episode number plus a real title when we have one.
/// Discord caps [details] at 128 characters.
String? discordEpisodeLabel(Episode ep, {int? fallbackNumber}) {
  final out = episodePresenceDetails(ep, fallbackNumber: fallbackNumber);
  if (out == null) return null;
  if (out.length <= 128) return out;
  return '${out.substring(0, 127)}…';
}

/// Unix-ms timestamps Discord uses to draw a Rich Presence progress bar.///
/// Both [startMs] and [endMs] must be set for a bar; start-only is elapsed
/// time; omitting both (paused / unknown) shows no timer so the bar cannot
/// keep marching on wall-clock time after a pause.
({int? startMs, int? endMs}) discordPlaybackTimestamps({
  required Duration position,
  required Duration duration,
  required bool playing,
  DateTime? now,
}) {
  if (!playing) return (startMs: null, endMs: null);
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final posMs = position.inMilliseconds < 0 ? 0 : position.inMilliseconds;
  final startMs = nowMs - posMs;
  if (duration <= Duration.zero) return (startMs: startMs, endMs: null);
  return (startMs: startMs, endMs: startMs + duration.inMilliseconds);
}

/// Resolve one presence line from the user's chosen source: the app name, the
/// title being watched, or the episode label. [appText] is what the App source
/// renders for this line ('Zangetsu' for name, 'on Zangetsu' for state). The
/// episode source falls back to the title when there is no episode label, so
/// a name line is never empty.
String discordSourceLine(
  String src, {
  required String title,
  String? episode,
  required String appText,
}) {
  if (src == 'title') return title;
  if (src == 'episode') {
    return (episode == null || episode.isEmpty) ? title : episode;
  }
  return appText;
}

/// Gateway `op: 3` presence payload. A null [activity] is an explicit clear
/// (`activities: []`) — dropping the socket without this leaves the last
/// Rich Presence stuck on the profile.
Map<String, dynamic> discordPresenceUpdate(
  DiscordActivity? activity,
  String appId, {
  String status = 'online',
}) {
  return {
    'since': null,
    'activities': activity == null
        ? <dynamic>[]
        : [activity.toJson(appId)],
    'status': status,
    'afk': false,
  };
}

/// Windows gateway only: returns a copy of an op 3 `d` payload with the
/// activity fields Discord refuses cleaned up, so one odd title cannot get
/// the socket closed:
///  * `details` / `state` / image texts that are blank or shorter than 2
///    characters are dropped, longer than 128 are cut to 128;
///  * a blank `name` falls back to the app name;
///  * timestamps are whole integer milliseconds (or dropped if not numbers);
///  * an empty `assets` / `timestamps` map is removed;
///  * at most 2 buttons, each label 1..32 characters with an http(s) URL.
/// Phone/TV keep sending [discordPresenceUpdate] unchanged.
Map<String, dynamic> discordSanitizePresenceUpdate(Map<String, dynamic> d) {
  final out = Map<String, dynamic>.from(d);
  final acts = d['activities'];
  if (acts is List) {
    out['activities'] = [
      for (final a in acts)
        if (a is Map) _sanitizeActivity(Map<String, dynamic>.from(a)),
    ];
  }
  return out;
}

/// Windows Social SDK only: returns a copy of an activity map cleaned up for
/// the SDK. The same rules as [discordSanitizePresenceUpdate], plus:
///  * images it cannot take ([discordSdkImageOk]) are dropped together with
///    their hover text;
///  * a button whose link is over Discord's 512 character limit is dropped, so
///    it cannot get the whole status refused.
/// Phones do not call this.
Map<String, dynamic> discordSanitizeSdkActivity(Map<String, dynamic> activity) {
  final out = _sanitizeActivity(
    Map<String, dynamic>.from(activity),
    longestButtonUrl: 512,
  );
  final assets = out['assets'];
  if (assets is! Map) return out;
  final m = Map<String, dynamic>.from(assets);
  for (final side in const ['large', 'small']) {
    final image = m['${side}_image'];
    if (image == null) continue;
    if (image is String && discordSdkImageOk(image)) continue;
    m.remove('${side}_image');
    m.remove('${side}_text');
  }
  if (m.isEmpty) {
    out.remove('assets');
  } else {
    out['assets'] = m;
  }
  return out;
}

/// Whether the Social SDK can show [image] on Windows: it takes plain http(s)
/// links of at most 300 characters (no local files, no `mp:` keys).
bool discordSdkImageOk(String image) =>
    image.length <= 300 && discordIsWebUrl(image);

/// Whether [url] is a plain http(s) link.
bool discordIsWebUrl(String url) {
  final scheme = Uri.tryParse(url)?.scheme;
  return scheme == 'http' || scheme == 'https';
}

/// Trims [v]; null when it is not a usable 2..128 character line.
String? _line(Object? v) {
  if (v is! String) return null;
  final s = v.trim();
  if (s.length < 2) return null;
  return s.length <= 128 ? s : s.substring(0, 128);
}

/// Cleans one activity map (see [discordSanitizePresenceUpdate]). Buttons with
/// a link over [longestButtonUrl] characters are dropped when it is given.
Map<String, dynamic> _sanitizeActivity(
  Map<String, dynamic> a, {
  int? longestButtonUrl,
}) {
  // Name is required by Discord; never send it blank.
  final name = (a['name'] is String) ? (a['name'] as String).trim() : '';
  a['name'] = name.isEmpty
      ? 'Zangetsu'
      : (name.length <= 128 ? name : name.substring(0, 128));
  // Optional text lines: drop when unusable instead of sending "" or " ".
  for (final k in const ['details', 'state']) {
    final v = _line(a[k]);
    if (v == null) {
      a.remove(k);
    } else {
      a[k] = v;
    }
  }
  // Assets: keep image keys, clean their hover texts, drop an empty map.
  final assets = a['assets'];
  if (assets is Map) {
    final m = <String, dynamic>{};
    for (final k in const ['large_image', 'small_image']) {
      final v = assets[k];
      if (v is String && v.trim().isNotEmpty) m[k] = v.trim();
    }
    for (final k in const ['large_text', 'small_text']) {
      final v = _line(assets[k]);
      if (v != null) m[k] = v;
    }
    if (m.isEmpty) {
      a.remove('assets');
    } else {
      a['assets'] = m;
    }
  }
  // Timestamps must be integer unix ms; floats/strings are rejected.
  final ts = a['timestamps'];
  if (ts is Map) {
    final m = <String, dynamic>{};
    for (final k in const ['start', 'end']) {
      final v = ts[k];
      if (v is num && v > 0) m[k] = v.toInt();
    }
    if (m.isEmpty) {
      a.remove('timestamps');
    } else {
      a['timestamps'] = m;
    }
  }
  // Buttons: labels and URLs travel as two parallel lists; keep only valid
  // pairs, at most 2, and drop both lists when none is left.
  final labels = a['buttons'];
  final meta = a['metadata'];
  final urls = meta is Map ? meta['button_urls'] : null;
  if (labels is List || urls != null) {
    final keepL = <String>[];
    final keepU = <String>[];
    if (labels is List && urls is List) {
      for (var i = 0; i < labels.length && i < urls.length; i++) {
        final l = labels[i];
        final u = urls[i];
        if (l is! String || u is! String) continue;
        final label = l.trim();
        if (label.isEmpty || label.length > 32) continue;
        final uri = Uri.tryParse(u);
        if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
          continue;
        }
        if (longestButtonUrl != null && u.length > longestButtonUrl) continue;
        keepL.add(label);
        keepU.add(u);
        if (keepL.length == 2) break;
      }
    }
    if (keepL.isEmpty) {
      a.remove('buttons');
      a.remove('metadata');
    } else {
      a['buttons'] = keepL;
      a['metadata'] = {'button_urls': keepU};
    }
  }
  return a;
}

/// A Discord activity (Rich Presence). [type]: 0 Playing · 2 Listening ·
/// 3 Watching. For Watching, [name] is what renders after "Watching ".
class DiscordActivity {
  const DiscordActivity({
    required this.name,
    this.type = 0,
    this.details,
    this.state,
    this.largeImage,
    this.largeText,
    this.smallImage,
    this.smallText,
    this.startMs,
    this.endMs,
    this.buttons = const [],
  });

  final String name;
  final int type;
  final String? details;
  final String? state;

  /// Asset key uploaded to the app, OR an `mp:external/...` key from the
  /// external-assets API (real poster URL).
  final String? largeImage;
  final String? largeText;
  final String? smallImage;
  final String? smallText;
  final int? startMs;
  final int? endMs;
  final List<({String label, String url})> buttons;

  Map<String, dynamic> toJson(String appId) {
    final assets = <String, dynamic>{
      if (largeImage != null) 'large_image': largeImage,
      if (largeText != null) 'large_text': largeText,
      if (smallImage != null) 'small_image': smallImage,
      if (smallText != null) 'small_text': smallText,
    };
    final ts = <String, dynamic>{
      if (startMs != null) 'start': startMs,
      if (endMs != null) 'end': endMs,
    };
    return {
      'name': name,
      'type': type,
      'application_id': appId,
      if (details != null) 'details': details,
      if (state != null) 'state': state,
      if (assets.isNotEmpty) 'assets': assets,
      if (ts.isNotEmpty) 'timestamps': ts,
      if (buttons.isNotEmpty) ...{
        'buttons': [for (final b in buttons) b.label],
        'metadata': {
          'button_urls': [for (final b in buttons) b.url],
        },
      },
    };
  }
}

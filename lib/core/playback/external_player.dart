import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../logging/app_logger.dart';
import '../ui/app_toast.dart';
import '../../l10n/l10n.dart';

/// Redacts query strings + long tokens so a logged stream URL stays readable
/// and doesn't leak signed credentials. Keeps host + path for diagnosis.
String _safeUrl(String url) {
  final q = url.indexOf('?');
  return q >= 0 ? '${url.substring(0, q)}?…' : url;
}

/// Bridge to the native `zangetsu/external_player` channel: lists installed
/// external video players and hands a resolved stream off to one via an
/// Android `ACTION_VIEW` intent (URL + headers + subtitles + title).
///
/// Android-only — every method is a no-op (returns empty/false) elsewhere.
class ExternalPlayer {
  static const MethodChannel _ch = MethodChannel('zangetsu/external_player');

  /// Installed video players as `(package, label, known)` rows, empty on
  /// non-Android.
  ///
  /// Ordered known-first: `known` players are the ones whose intent extras we
  /// know, so subtitles and the resume position reach them. The rest are
  /// whatever else on the device answers an `ACTION_VIEW` video intent — real
  /// players we've never heard of, but also galleries and browsers. Those still
  /// play (header-gated streams included — anything outside
  /// `kHeaderForwardingPlayers` is handed the local header-injecting proxy URL),
  /// they just may ignore the subtitle and position extras. Callers should
  /// present them under their own heading rather than mixed in.
  Future<List<({String package, String label, bool known})>> installed() async {
    if (!Platform.isAndroid) return const [];
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('getPlayers');
      return (raw ?? const []).map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return (
          package: '${m['package']}',
          label: '${m['label']}',
          // Absent on an older native build that predates the flag — treating
          // those as known keeps the previous behaviour instead of dumping the
          // whole list under "Other apps".
          known: m['known'] != '0',
        );
      }).toList();
    } catch (e) {
      // A MissingPluginException here means the native channel isn't in the
      // running build (e.g. native changes applied via hot reload — they need a
      // full reinstall).
      AppLogger.instance.log('[ext-player] getPlayers failed: $e', level: 'E');
      return const [];
    }
  }

  /// Registers [url] + [headers] with the native stream proxy and returns a
  /// URL the external player can play WITHOUT headers (the proxy injects them
  /// upstream). Advertises the phone's LAN IP when available so a Cast
  /// receiver (Shield / Chromecast) can fetch it; otherwise `127.0.0.1`.
  /// Returns null on non-Android or any failure, so the caller can fall back
  /// to the built-in player.
  Future<String?> proxyStreamUrl(
    String url,
    Map<String, String> headers,
  ) async {
    if (!Platform.isAndroid) return null;
    try {
      final local = await _ch.invokeMethod<String?>(
        'proxyUrl',
        <String, dynamic>{'url': url, 'headers': headers},
      );
      AppLogger.instance.log(
        '[ext-player] proxyUrl ${local == null ? "failed (null)" : "ok"} '
        'for ${_safeUrl(url)}',
        level: local == null ? 'E' : 'I',
      );
      return (local != null && local.isNotEmpty) ? local : null;
    } catch (e) {
      AppLogger.instance.log('[ext-player] proxyUrl error: $e', level: 'E');
      return null;
    }
  }

  /// Launches [url] in the external player [package]. Forwards [headers]
  /// (so header-gated streams work in players that honour them, e.g. MX
  /// Player), [subtitles] (`[{url, name}]`), [title], and a resume [positionMs].
  ///
  /// The Future completes when the external player **returns** (closes), with:
  ///  - `launched`: the player started at all (false = not installed / no
  ///    activity → caller should fall back immediately).
  ///  - `played`: the player reported it actually loaded/played the media.
  ///    When false, the player opened but couldn't play it → caller should fall
  ///    back to the built-in player.
  ///  - `positionMs`: watched position reported back (0 if unknown).
  Future<({bool launched, bool played, int positionMs})> launch({
    required String url,
    required String package,
    String? title,
    Map<String, String> headers = const {},
    List<Map<String, String>> subtitles = const [],
    int positionMs = 0,
  }) async {
    if (!Platform.isAndroid) {
      return (launched: false, played: false, positionMs: 0);
    }
    final isHls = url.toLowerCase().contains('.m3u8');
    // Logged so external-player failures are visible in exported logs (they
    // previously used debugPrint, which the log buffer doesn't capture). Header
    // presence matters: header-gated HLS only plays in players that honour the
    // Referer/UA extras (MX Player), and 403s in ones that ignore them (VLC).
    AppLogger.instance.log(
      '[ext-player] launch pkg=${package.isEmpty ? "(chooser)" : package} '
      'hls=$isHls headers=${headers.keys.toList()} subs=${subtitles.length} '
      'url=${_safeUrl(url)}',
    );
    try {
      final res = await _ch.invokeMethod<dynamic>('launch', <String, dynamic>{
        'url': url,
        'package': package,
        'title': title,
        'headers': headers,
        'subtitles': subtitles,
        'positionMs': positionMs,
      });
      final m = res is Map ? Map<String, dynamic>.from(res) : const {};
      final launched = m['launched'] == true;
      final played = m['played'] == true;
      // `played` is not a failure signal and never has been: VLC and friends
      // hand playback to their own task and return immediately, so a perfectly
      // healthy launch reports played=false. The caller keys off `launched`
      // alone — see PlayerScreen's launch handler, which leaves this screen on
      // launched=true and only opens the built-in player when the launch
      // itself failed. Logged at info for that reason; this line used to claim
      // a fallback that the code doesn't do, and reading it as gospel sent a
      // debugging session hunting through fallback logic while the real fault
      // was upstream of the player entirely.
      AppLogger.instance.log(
        '[ext-player] result launched=$launched played=$played '
        'pos=${(m['positionMs'] as num?)?.toInt() ?? 0}'
        '${launched && !played ? " — handed off; the player reports no "
                  "progress of its own, which is normal" : ""}',
        level: launched ? 'I' : 'E',
      );
      return (
        launched: launched,
        played: played,
        positionMs: (m['positionMs'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      AppLogger.instance.log('[ext-player] launch failed: $e', level: 'E');
      return (launched: false, played: false, positionMs: 0);
    }
  }
}

// ── Windows (player-12) ──────────────────────────────────────────────────────
// "Copy stream link" and "Open in external player" for the Windows player. The
// Android path above is unchanged; everything below only does real OS work
// when Platform.isWindows.

/// The stream URL plus the HTTP headers a stream needs, one per line after the
/// URL (`Referer: …`), so a power user can paste both into another tool. Just
/// the URL when no headers are needed.
String streamLinkWithHeaders(String url, Map<String, String>? headers) {
  final lines = <String>[url];
  for (final e in (headers ?? const <String, String>{}).entries) {
    if (e.key.trim().isEmpty || e.value.trim().isEmpty) continue;
    lines.add('${e.key}: ${e.value}');
  }
  return lines.join('\n');
}

/// Copies [url] (with its required [headers]) to the clipboard and says so.
Future<void> copyStreamLinkWithHeaders(
  BuildContext context,
  String url,
  Map<String, String>? headers,
) async {
  if (url.trim().isEmpty) return;
  final text = streamLinkWithHeaders(url, headers);
  final withHeaders = text.contains('\n');
  try {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      showAppToast(
        context,
        withHeaders
            ? context.l10n.streamLinkAndHeadersCopied
            : context.l10n.streamLinkCopied,
      );
    }
  } on PlatformException {
    if (context.mounted) showAppToast(context, context.l10n.couldNotCopyLink);
  }
}

/// The desktop players Zangetsu knows how to hand a stream to.
enum DesktopExternalPlayerKind { mpv, vlc, mpcHc }

/// One installed desktop player found by [DesktopExternalPlayers.detect].
class DesktopExternalPlayerApp {
  const DesktopExternalPlayerApp({required this.kind, required this.exePath});

  final DesktopExternalPlayerKind kind;

  /// Full path of the player's executable.
  final String exePath;

  /// Name shown in the menu.
  String get label => switch (kind) {
    DesktopExternalPlayerKind.mpv => 'mpv',
    DesktopExternalPlayerKind.vlc => 'VLC',
    DesktopExternalPlayerKind.mpcHc => 'MPC-HC',
  };

  /// Which headers this player can send: mpv any, VLC only Referer and
  /// User-Agent, MPC-HC none (it has no command-line option for them).
  bool canSend(String header) => switch (kind) {
    DesktopExternalPlayerKind.mpv => true,
    DesktopExternalPlayerKind.vlc =>
      header.toLowerCase() == 'referer' || header.toLowerCase() == 'user-agent',
    DesktopExternalPlayerKind.mpcHc => false,
  };

  /// True when this player cannot send at least one of [headers], so a
  /// header-protected stream may refuse to play there.
  bool dropsHeaders(Map<String, String>? headers) =>
      (headers ?? const {}).keys.any((h) => !canSend(h));
}

/// Finds and launches mpv, VLC and MPC-HC on Windows.
abstract final class DesktopExternalPlayers {
  /// Test hook: environment variables used instead of the real ones.
  @visibleForTesting
  static Map<String, String>? debugEnvironment;

  /// Test hook: file-exists check used instead of the real file system.
  @visibleForTesting
  static bool Function(String path)? debugFileExists;

  /// Test hook: registry read (key, value name or null for the default).
  @visibleForTesting
  static Future<String?> Function(String key, String? valueName)?
  debugRegistryRead;

  /// Test hook: replaces Process.start; returns whether it started.
  @visibleForTesting
  static Future<bool> Function(String exe, List<String> args)? debugStart;

  // Detection is cached for the session (a few registry reads per call).
  static Future<List<DesktopExternalPlayerApp>>? _cache;

  /// Installed players in a fixed order (mpv, VLC, MPC-HC); empty off
  /// Windows. Looks in PATH, the standard install folders and the registry.
  static Future<List<DesktopExternalPlayerApp>> detect({bool refresh = false}) {
    if (!_canDetect) return Future.value(const []);
    if (refresh || _cache == null) _cache = _detect();
    return _cache!;
  }

  /// Forgets cached detection and the test hooks (tests).
  @visibleForTesting
  static void debugReset() {
    _cache = null;
    debugEnvironment = null;
    debugFileExists = null;
    debugRegistryRead = null;
    debugStart = null;
  }

  // Real OS work only on Windows; tests that set hooks run anywhere.
  static bool get _canDetect =>
      Platform.isWindows || debugFileExists != null || debugEnvironment != null;

  static Map<String, String> get _env =>
      debugEnvironment ?? Platform.environment;

  static bool _exists(String path) {
    final hook = debugFileExists;
    if (hook != null) return hook(path);
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  static Future<List<DesktopExternalPlayerApp>> _detect() async {
    final out = <DesktopExternalPlayerApp>[];
    for (final kind in DesktopExternalPlayerKind.values) {
      final exe = await _find(kind);
      if (exe != null) {
        out.add(DesktopExternalPlayerApp(kind: kind, exePath: exe));
      }
    }
    AppLogger.instance.log(
      '[ext-player] windows players: ${out.map((p) => p.label).toList()}',
    );
    return out;
  }

  // Executable names to look for, per player.
  static List<String> _exeNames(DesktopExternalPlayerKind kind) =>
      switch (kind) {
        DesktopExternalPlayerKind.mpv => const ['mpv.exe'],
        DesktopExternalPlayerKind.vlc => const ['vlc.exe'],
        DesktopExternalPlayerKind.mpcHc => const [
          'mpc-hc64.exe',
          'mpc-hc.exe',
        ],
      };

  // Standard install folders, as (environment variable, sub folder).
  static List<(String, String)> _installDirs(DesktopExternalPlayerKind kind) =>
      switch (kind) {
        DesktopExternalPlayerKind.mpv => const [
          ('ProgramFiles', r'mpv'),
          ('LOCALAPPDATA', r'Programs\mpv'),
          ('USERPROFILE', r'scoop\apps\mpv\current'),
        ],
        DesktopExternalPlayerKind.vlc => const [
          ('ProgramFiles', r'VideoLAN\VLC'),
          ('ProgramFiles(x86)', r'VideoLAN\VLC'),
        ],
        DesktopExternalPlayerKind.mpcHc => const [
          ('ProgramFiles', r'MPC-HC'),
          ('ProgramFiles(x86)', r'MPC-HC'),
          ('ProgramFiles', r'K-Lite Codec Pack\MPC-HC64'),
          ('ProgramFiles(x86)', r'K-Lite Codec Pack\MPC-HC64'),
          ('ProgramFiles(x86)', r'K-Lite Codec Pack\MPC-HC'),
        ],
      };

  // Registry spots (key, value name; null = default value) that hold either
  // the executable path or the install folder.
  static List<(String, String?)> _registry(DesktopExternalPlayerKind kind) {
    const appPaths =
        r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths';
    const userAppPaths =
        r'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths';
    return switch (kind) {
      DesktopExternalPlayerKind.mpv => const [
        ('$appPaths\\mpv.exe', null),
        ('$userAppPaths\\mpv.exe', null),
      ],
      DesktopExternalPlayerKind.vlc => const [
        (r'HKLM\SOFTWARE\VideoLAN\VLC', null),
        (r'HKLM\SOFTWARE\VideoLAN\VLC', 'InstallDir'),
        (r'HKLM\SOFTWARE\WOW6432Node\VideoLAN\VLC', null),
        ('$appPaths\\vlc.exe', null),
      ],
      DesktopExternalPlayerKind.mpcHc => const [
        (r'HKCU\SOFTWARE\MPC-HC\MPC-HC', 'ExePath'),
        (r'HKCU\SOFTWARE\Gabest\Media Player Classic', 'ExePath'),
        ('$appPaths\\mpc-hc64.exe', null),
        ('$appPaths\\mpc-hc.exe', null),
      ],
    };
  }

  static Future<String?> _find(DesktopExternalPlayerKind kind) async {
    final names = _exeNames(kind);
    final env = _env;
    String? envVar(String name) {
      // Windows environment names are case-insensitive.
      for (final e in env.entries) {
        if (e.key.toLowerCase() == name.toLowerCase()) return e.value;
      }
      return null;
    }

    String join(String dir, String name) =>
        dir.endsWith('\\') ? '$dir$name' : '$dir\\$name';

    // 1) PATH.
    for (final dir in (envVar('PATH') ?? '').split(';')) {
      final d = dir.trim().replaceAll('"', '');
      if (d.isEmpty) continue;
      for (final n in names) {
        final path = join(d, n);
        if (_exists(path)) return path;
      }
    }
    // 2) Standard install folders.
    for (final (root, sub) in _installDirs(kind)) {
      final base = envVar(root);
      if (base == null || base.isEmpty) continue;
      for (final n in names) {
        final path = join(join(base, sub), n);
        if (_exists(path)) return path;
      }
    }
    // 3) Registry: a value is either the exe itself or its folder.
    for (final (key, value) in _registry(kind)) {
      final raw = await _readRegistry(key, value);
      if (raw == null || raw.trim().isEmpty) continue;
      final v = _expand(raw.trim().replaceAll('"', ''), envVar);
      if (v.toLowerCase().endsWith('.exe')) {
        if (_exists(v)) return v;
        continue;
      }
      for (final n in names) {
        final path = join(v, n);
        if (_exists(path)) return path;
      }
    }
    return null;
  }

  // Expands %VAR% references in a registry string.
  static String _expand(String s, String? Function(String) envVar) => s
      .replaceAllMapped(RegExp(r'%([^%]+)%'), (m) => envVar(m[1]!) ?? m[0]!);

  /// Reads one registry value with `reg query` (no plugin needed). Null when
  /// the key or value is missing.
  static Future<String?> _readRegistry(String key, String? valueName) async {
    final hook = debugRegistryRead;
    if (hook != null) return hook(key, valueName);
    if (!Platform.isWindows) return null;
    try {
      final res = await Process.run('reg', [
        'query',
        key,
        if (valueName == null) '/ve' else ...['/v', valueName],
      ]);
      if (res.exitCode != 0) return null;
      for (final line in '${res.stdout}'.split(RegExp(r'\r?\n'))) {
        final m = RegExp(r'\s+REG_(?:EXPAND_)?SZ\s+(.*)$').firstMatch(line);
        if (m != null) return m[1]!.trim();
      }
    } catch (_) {}
    return null;
  }

  /// Command-line arguments that open [url] in [app] with as many of
  /// [headers] as that player supports, and [title] as the window title.
  static List<String> argsFor(
    DesktopExternalPlayerApp app, {
    required String url,
    Map<String, String>? headers,
    String? title,
  }) {
    final h = headers ?? const <String, String>{};
    String? header(String name) {
      for (final e in h.entries) {
        if (e.key.toLowerCase() == name) return e.value;
      }
      return null;
    }

    final referer = header('referer');
    final agent = header('user-agent');
    final cleanTitle = title?.trim() ?? '';
    switch (app.kind) {
      case DesktopExternalPlayerKind.mpv:
        return [
          if (cleanTitle.isNotEmpty) '--force-media-title=$cleanTitle',
          if (referer != null) '--referrer=$referer',
          if (agent != null) '--user-agent=$agent',
          // Every other header as its own entry, so a comma inside a value
          // cannot split it.
          for (final e in h.entries)
            if (e.key.toLowerCase() != 'referer' &&
                e.key.toLowerCase() != 'user-agent')
              '--http-header-fields-append=${e.key}: ${e.value}',
          url,
        ];
      case DesktopExternalPlayerKind.vlc:
        return [
          if (cleanTitle.isNotEmpty) '--meta-title=$cleanTitle',
          url,
          // Per-item options follow the URL they apply to.
          if (referer != null) ':http-referrer=$referer',
          if (agent != null) ':http-user-agent=$agent',
        ];
      case DesktopExternalPlayerKind.mpcHc:
        // MPC-HC has no header options: the URL alone.
        return [url];
    }
  }

  /// Starts [app] with [url] (detached, so it outlives Zangetsu). Returns
  /// false when it could not be started.
  static Future<bool> launch(
    DesktopExternalPlayerApp app, {
    required String url,
    Map<String, String>? headers,
    String? title,
  }) async {
    final args = argsFor(app, url: url, headers: headers, title: title);
    AppLogger.instance.log(
      '[ext-player] windows launch ${app.label} '
      'headers=${(headers ?? const {}).keys.toList()} url=${_safeUrl(url)}',
    );
    final hook = debugStart;
    if (hook != null) return hook(app.exePath, args);
    if (!Platform.isWindows) return false;
    try {
      await Process.start(app.exePath, args, mode: ProcessStartMode.detached);
      return true;
    } catch (e) {
      AppLogger.instance.log(
        '[ext-player] windows launch failed: $e',
        level: 'E',
      );
      return false;
    }
  }
}

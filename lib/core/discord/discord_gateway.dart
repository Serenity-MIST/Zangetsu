import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'discord_config.dart';
import 'discord_presence.dart';

/// Windows only: how the desktop gateway waits between failed connections.
/// Each failure before READY doubles the wait (5s, 10s, 20s ... up to 5
/// minutes). When Discord keeps closing the socket with the same code, the
/// gateway stops trying until the app restarts or the Discord setting is
/// switched again, so a rejected login cannot loop forever.
class DiscordReconnectPolicy {
  DiscordReconnectPolicy({
    this.base = const Duration(seconds: 5),
    this.max = const Duration(minutes: 5),
    this.giveUpAfter = 6,
    this.stableAfter = const Duration(seconds: 60),
  });

  final Duration base;
  final Duration max;

  /// How many failures in a row with the same close code end the retries.
  /// Only Discord's own codes (4000 and up) count: anything lower (1001,
  /// 1006 ...) is the network, which comes back without anyone's help.
  final int giveUpAfter;

  /// True for a close code Discord itself chose, as opposed to a dead network.
  static bool _fromDiscord(int? code) => code != null && code >= 4000;

  int _failures = 0;
  int _sameCode = 0;
  int? _lastCode;
  bool _gaveUp = false;

  /// Failures since the last READY (0 while healthy).
  int get failures => _failures;

  /// How many of the latest failures in a row had the same close code. This
  /// is the number that decides the stop, so the give-up log line uses it
  /// (failures also counts earlier closes with other codes).
  int get sameCodeCount => _sameCode;

  /// True once retrying stopped for this gateway.
  bool get gaveUp => _gaveUp;

  /// Records a socket that closed before READY. Returns how long to wait
  /// before the next try, or null when it is time to stop retrying.
  Duration? onFailure(int? closeCode) {
    _failures++;
    _sameCode = closeCode != null && closeCode == _lastCode ? _sameCode + 1 : 1;
    _lastCode = closeCode;
    if (_fromDiscord(closeCode) && _sameCode >= giveUpAfter) {
      _gaveUp = true;
      return null;
    }
    return _grown(_failures);
  }

  /// 5s * 2^(step-1), capped; the shift is bounded so it cannot overflow.
  Duration _grown(int step) {
    final wait = base * (1 << (step - 1).clamp(0, 16));
    return wait > max ? max : wait;
  }

  /// A healthy session (READY) starts a fresh series.
  void onReady() {
    _failures = 0;
    _sameCode = 0;
    _lastCode = null;
    _gaveUp = false;
  }

  /// How long a READY session must stay open to count as healthy when it
  /// closes. Shorter sessions are "quick drops" (see [onDropAfterReady]).
  final Duration stableAfter;

  /// Quick drops in a row with the same close code, and that code.
  int _quickDrops = 0;
  int? _quickCode;

  /// Quick drops in a row whatever the code. A weak network can drop every
  /// session right after READY; those never end the retries, but the waits
  /// still grow so Discord is not asked to log in every 5 seconds all day.
  int _quickAny = 0;

  /// Quick drops in a row with the same close code (0 after a healthy one).
  int get quickDrops => _quickDrops;

  /// Records a socket that reached READY and then closed after [lived].
  ///
  /// Why: READY resets the failure series, so a session that Discord
  /// accepts and then closes again at once (for example code 4000 right
  /// after READY) would otherwise be retried every 5 seconds forever. A
  /// session that stayed up for [stableAfter] still starts a fresh series;
  /// quick drops with the same code count towards [giveUpAfter] like
  /// failures before READY do. Returns the wait before the next try, or null
  /// when it is time to stop retrying.
  Duration? onDropAfterReady(int? closeCode, Duration lived) {
    _quickAny = lived < stableAfter ? _quickAny + 1 : 0;
    final quick = lived < stableAfter && _fromDiscord(closeCode);
    if (!quick) {
      _quickDrops = 0;
      _quickCode = null;
    } else {
      _quickDrops = closeCode == _quickCode ? _quickDrops + 1 : 1;
      _quickCode = closeCode;
    }
    onReady();
    if (_quickDrops >= giveUpAfter) {
      _gaveUp = true;
      return null;
    }
    final wait = onFailure(closeCode);
    if (wait == null || _quickAny < 2) return wait;
    return _grown(_quickAny);
  }
}

/// Builds the gateway IDENTIFY frame (op 2).
///
/// [oauthShape] true (Windows): the shape Discord accepts for an OAuth
/// `Bearer` token from the Social Layer (`sdk.social_layer_presence`), as
/// used by the working raw-gateway Social RPC clients:
///  * `intents: 0` is sent. An OAuth connection is not a full user client, so
///    the gateway picks its events from the intents. The old payload (no
///    intents, Android client fields) got close 4000 "Unknown error" right
///    after IDENTIFY on every try, never READY, while a fake token still got
///    the normal 4004 — so the token was accepted and the session setup for
///    that payload shape is what failed.
///  * No `capabilities` and no `presence`: both are Discord-client-only
///    fields (they come from the old user-token "Discord Android" copy).
///  * Neutral `properties` naming this app on Windows, instead of pretending
///    to be the official Android client, which an OAuth token is not.
/// The token is always sent with a single `Bearer ` prefix.
///
/// [oauthShape] false: the original payload, byte for byte, so platforms
/// other than Windows that still use this raw gateway do not change.
Map<String, dynamic> discordIdentifyPayload(
  String token, {
  required bool oauthShape,
}) {
  if (!oauthShape) {
    return {
      'op': 2,
      'd': {
        'token': token,
        'capabilities': 0,
        'properties': {
          'os': 'Android',
          'browser': 'Discord Android',
          'device': DiscordConfig.appName,
        },
        'presence': {
          'status': 'online',
          'since': 0,
          'activities': [],
          'afk': false,
        },
        'compress': false,
      },
    };
  }
  return {
    'op': 2,
    'd': {
      'token': discordBearer(token),
      'intents': 0,
      'properties': {
        'os': 'windows',
        'browser': DiscordConfig.appName,
        'device': DiscordConfig.appName,
      },
      // Plain JSON frames: the URL asks for no zlib stream either.
      'compress': false,
    },
  };
}

/// Returns [token] with exactly one `Bearer ` prefix (an access token that
/// already carries it is left as is, so it is never doubled).
String discordBearer(String token) {
  final raw = token.trim();
  return raw.startsWith('Bearer ') ? raw : 'Bearer $raw';
}

/// Minimal Discord Gateway (v10) client for setting a user's Rich Presence.
/// Connects, IDENTIFYs with the OAuth Bearer token, heartbeats and pushes
/// presence (op 3). Auto-reconnects on drop / zombie connection. This is a
/// "self presence" client — it does not read events beyond what's needed.
///
/// The token is the OAuth access token prefixed with `Bearer` (the Social
/// Layer path — never a user token). When the gateway rejects the session
/// (op 9) it calls [onAuthFailure] so the owner can refresh and rotate the
/// token on the live socket via [updateToken] instead of reconnecting blind.
class DiscordGateway {
  /// [gatewayUrl], [policy] and [readyTimeout] exist so tests can point the
  /// gateway at a local fake server and use tiny waits; the app leaves them
  /// unset.
  DiscordGateway(
    this._token, {
    this.onAuthFailure,
    String? gatewayUrl,
    DiscordReconnectPolicy? policy,
    this.readyTimeout = const Duration(seconds: 20),
  }) : _url = gatewayUrl ?? DiscordConfig.gatewayUrl,
       _policy = policy ?? DiscordReconnectPolicy();
  String _token;
  final Future<void> Function()? onAuthFailure;

  /// Where the socket connects (Discord's gateway unless a test overrides it).
  final String _url;

  /// When the current socket got READY, to tell a healthy session from one
  /// Discord closes again at once (Windows back-off only).
  DateTime? _readyAt;

  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  Timer? _heartbeat;
  int? _seq;
  bool _acked = true;
  bool _ready = false;
  bool _closed = false;

  /// Windows only: growing waits between failed connects, and a stop after
  /// repeated identical failures. Phone and TV keep the fixed 5s retry.
  final bool _backoff = _windows;

  /// Windows only: send the OAuth (Social Layer) identify shape. Other
  /// platforms that use this raw gateway keep the old payload.
  static bool get _windows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  final DiscordReconnectPolicy _policy;
  Timer? _retryTimer;

  /// Windows only: how long an opened socket may take to reach READY. A
  /// socket that hangs (no HELLO, or HELLO but never READY) used to leave the
  /// presence "queued until READY" for ever.
  final Duration readyTimeout;
  Timer? _readyTimer;

  /// Counts opened sockets, to tell whether the owner already reconnected
  /// while it was handling a rejected login.
  int _opens = 0;

  /// Set while [clearThenClose] is on its way out, so nothing reconnects in
  /// between (Windows).
  bool _closing = false;

  /// The close code of the previous failure in the running series, so a
  /// change of code shows in the otherwise quiet log (Windows).
  int? _seriesCode;

  /// True when this gateway stopped retrying after repeated identical
  /// failures; the owner builds a new one on the next settings change.
  bool get gaveUp => _policy.gaveUp;

  /// While a failure series runs on Windows the per-try lines (opening,
  /// HELLO, IDENTIFY, closed) are muted so the log keeps one line per series.
  bool get _quiet => _backoff && _policy.failures > 0;

  void _log(String line) {
    if (!_quiet) debugPrint(line);
  }

  /// Latest presence to (re)apply once READY / after a reconnect. null = clear.
  DiscordActivity? _pending;
  String _pendingStatus = 'online';

  void connect() {
    _closed = false;
    _closing = false;
    _open();
  }

  /// Windows: try again now instead of waiting out a pending retry (the
  /// network came back, or the window was focused). Does nothing while
  /// connected, or once the gateway gave up.
  void retryNow() {
    if (!_backoff || _closed || _closing || gaveUp) return;
    if (!(_retryTimer?.isActive ?? false)) return;
    debugPrint('[discord] gateway retrying now');
    _open();
  }

  void _open() {
    _cleanupSocket();
    _ready = false;
    _opens++;
    _log('[discord] gateway opening $_url');
    if (_backoff) {
      _readyTimer = Timer(readyTimeout, () {
        if (_closed || _ready) return;
        _log(
          '[discord] gateway not READY after ${readyTimeout.inSeconds}s — '
          'reconnecting',
        );
        _scheduleReconnect();
      });
    }
    try {
      _ch = WebSocketChannel.connect(Uri.parse(_url));
      // The stream below already reports a failed connect; the same error
      // also lands on this future, where nobody listens and it would end up
      // in the log as an app error.
      if (_backoff) _ch!.ready.ignore();
      _sub = _ch!.stream.listen(
        _onMessage,
        onDone: _onDone,
        onError: (e, st) {
          debugPrint('[discord] gateway socket error: $e');
          _onDone();
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('[discord] gateway connect failed: $e');
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[discord] gateway bad json: $e');
      return;
    }
    if (msg['s'] != null) _seq = (msg['s'] as num).toInt();
    switch (msg['op'] as int?) {
      case 10: // HELLO
        final interval =
            ((msg['d'] as Map)['heartbeat_interval'] as num).toInt();
        _log('[discord] gateway HELLO heartbeat=${interval}ms — identifying');
        _startHeartbeat(interval);
        _identify();
      case 11: // heartbeat ACK
        _acked = true;
      case 1: // server requested a heartbeat
        _sendHeartbeat();
      case 7: // must reconnect
        debugPrint('[discord] gateway requested reconnect (op 7)');
        _reconnect();
      case 9: // invalid session
        debugPrint('[discord] gateway invalid session (op 9) — token/identify rejected');
        unawaited(_onInvalidSession());
        return;
      case 0: // dispatch
        final t = msg['t'] as String?;
        if (t == 'READY') {
          _ready = true;
          _readyTimer?.cancel();
          _readyTimer = null;
          if (_backoff && _policy.failures > 0) {
            debugPrint(
              '[discord] gateway recovered after ${_policy.failures} failed '
              'attempt(s)',
            );
          }
          _policy.onReady();
          _readyAt = DateTime.now();
          final user = (msg['d'] as Map?)?['user'] as Map?;
          final name = user?['username'] ?? user?['global_name'] ?? '?';
          debugPrint('[discord] gateway READY as $name — pushing presence');
          _sendPresence(_pending, _pendingStatus);
        }
    }
  }

  void _identify() {
    _log('[discord] gateway IDENTIFY');
    // Windows uses the OAuth-safe identify shape; other platforms keep the
    // original payload unchanged (see [discordIdentifyPayload]).
    _send(discordIdentifyPayload(_token, oauthShape: _windows));
  }

  /// Set (or clear, with null) the presence. Buffered until READY.
  void setPresence(DiscordActivity? activity, {String status = 'online'}) {
    _pending = activity;
    _pendingStatus = status;
    if (_ready) {
      _sendPresence(activity, status);
    } else {
      debugPrint(
        '[discord] presence queued until READY: ${activity == null ? "clear" : "type=${activity.type} ${activity.name}"}',
      );
    }
  }

  /// Push an empty activity list, wait for the frame to flush, then drop the
  /// socket. Closing without this leaves the last Rich Presence on the profile.
  Future<void> clearThenClose() async {
    if (_closed) return;
    _closing = true;
    setPresence(null, status: _pendingStatus);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await close();
  }

  void _sendPresence(DiscordActivity? a, String status) {
    debugPrint(
      a == null
          ? '[discord] sending presence clear'
          : '[discord] sending presence type=${a.type} name="${a.name}" '
              'details=${a.details} start=${a.startMs} end=${a.endMs}',
    );
    final d = discordPresenceUpdate(
      a,
      DiscordConfig.applicationId,
      status: status,
    );
    _send({
      'op': 3,
      // Windows: strip fields Discord rejects (empty / too long lines) so a
      // bad title cannot get the session closed after READY.
      'd': _windows ? discordSanitizePresenceUpdate(d) : d,
    });
  }

  void _startHeartbeat(int intervalMs) {
    _heartbeat?.cancel();
    _acked = true;
    _heartbeat = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      if (!_acked) {
        debugPrint('[discord] gateway heartbeat missed — reconnecting');
        _reconnect();
        return;
      }
      _sendHeartbeat();
    });
  }

  /// Session rejected: let the owner refresh first (it rotates the token on
  /// this socket); a blind reconnect with a dead token just loops op 9.
  Future<void> _onInvalidSession() async {
    if (_backoff) {
      // Windows: if the refresh changed nothing, wait like after any other
      // failure. Reconnecting at once with the same login spins. Taken before
      // the refresh: a session rejected right after READY is a quick drop.
      final wasReady = _ready;
      final lived = _lived();
      if (!await _ownerHandled()) {
        _scheduleReconnect(wasReady: wasReady, lived: lived);
      }
      return;
    }
    if (onAuthFailure != null) {
      await onAuthFailure!();
      if (_closed) return;
      // Owner logged out (gateway dropped) or rotated the token (socket
      // resumed) — either way nothing more to do here.
      if (_gatewayDropped()) return;
    }
    _reconnect();
  }

  bool _gatewayDropped() => _closed || _ch == null;

  /// Windows: asks the owner to deal with a rejected login. True when there
  /// is nothing left to do here: it reopened the socket, closed the gateway,
  /// or a retry is already waiting.
  Future<bool> _ownerHandled() async {
    final opens = _opens;
    try {
      // Bounded, so a refresh that never answers cannot end the retries. A
      // late answer still rotates the login through [updateToken].
      await onAuthFailure?.call().timeout(
        const Duration(seconds: 30),
        onTimeout: () {},
      );
    } catch (e) {
      debugPrint('[discord] login refresh failed: ${e.runtimeType}');
    }
    return _closed ||
        _closing ||
        _opens != opens ||
        (_retryTimer?.isActive ?? false);
  }

  /// Windows: Discord closed with 4004 (login rejected). Refresh first; the
  /// same login can only be rejected again.
  Future<void> _onLoginRejectedClose() async {
    // Taken before the cleanup and the refresh, so that READY followed by 4004
    // counts as a quick drop and its waits keep growing.
    final wasReady = _ready;
    final lived = _lived();
    _cleanupSocket();
    if (!await _ownerHandled()) {
      _scheduleReconnect(closeCode: 4004, wasReady: wasReady, lived: lived);
    }
  }

  /// How long the current session has been READY (zero when it never was).
  Duration _lived() {
    final at = _readyAt;
    return at == null ? Duration.zero : DateTime.now().difference(at);
  }

  /// Swap the credential on the live connection (post-refresh) without the
  /// reconnect storm.
  void updateToken(String token) {
    _token = token;
    debugPrint('[discord] gateway token rotated — re-identifying');
    _reconnect();
  }

  void _sendHeartbeat() {
    _acked = false;
    _send({'op': 1, 'd': _seq});
  }

  void _send(Map<String, dynamic> data) {
    try {
      _ch?.sink.add(jsonEncode(data));
    } catch (e) {
      debugPrint('[discord] gateway send failed: $e');
    }
  }

  void _onDone() {
    final code = _ch?.closeCode;
    final reason = _ch?.closeReason;
    final wasReady = _ready;
    _log(
      '[discord] gateway socket closed code=$code '
      'ready=$_ready closed=$_closed'
      '${reason == null || reason.isEmpty ? '' : ' reason="$reason"'}',
    );
    if (_backoff && !_closed && code == 4004) {
      unawaited(_onLoginRejectedClose());
      return;
    }
    if (!_closed) _scheduleReconnect(closeCode: code, wasReady: wasReady);
  }

  /// [lived]: how long the session was READY, when that was measured earlier
  /// than now (Windows).
  void _scheduleReconnect({
    int? closeCode,
    bool wasReady = false,
    Duration? lived,
  }) {
    _cleanupSocket();
    if (_closed || (_backoff && _closing)) return;
    if (!_backoff) {
      debugPrint('[discord] gateway reconnect in 5s');
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 5), () {
        if (!_closed) _open();
      });
      return;
    }
    // Windows: a socket that was READY and stayed up dropped normally, so
    // the series starts fresh; one that never got READY counts as a
    // failure, and one that got READY but was closed again at once counts
    // towards the same stop (so READY-then-close loops end too).
    final readyFor = lived ?? _lived();
    _readyAt = null;
    final firstInSeries = wasReady || _policy.failures == 0;
    final wait = wasReady
        ? _policy.onDropAfterReady(closeCode, readyFor)
        : _policy.onFailure(closeCode);
    if (wait == null) {
      // Report the identical closes that caused the stop, not every
      // failure since READY (mixed codes would overstate the count).
      final tries = wasReady ? _policy.quickDrops : _policy.sameCodeCount;
      debugPrint(
        '[discord] gateway keeps closing with code=$closeCode after '
        '$tries tries — stopped retrying until restart or a '
        'Discord settings change',
      );
      return;
    }
    final codeChanged = !firstInSeries && closeCode != _seriesCode;
    _seriesCode = closeCode;
    if (codeChanged) {
      // The series is quiet, but a different reason is worth one line.
      debugPrint('[discord] gateway now fails with code=$closeCode');
    }
    if (firstInSeries) {
      debugPrint(
        '[discord] gateway failed (code=$closeCode) — retrying with growing '
        'waits, starting at ${wait.inSeconds}s (further tries stay quiet)',
      );
    }
    _retryTimer?.cancel();
    _retryTimer = Timer(wait, () {
      if (!_closed) _open();
    });
  }

  void _reconnect() {
    if (_closed) return;
    _open();
  }

  void _cleanupSocket() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _readyTimer?.cancel();
    _readyTimer = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _sub?.cancel();
    _sub = null;
    try {
      _ch?.sink.close();
    } catch (_) {}
    _ch = null;
    _ready = false;
  }

  Future<void> close() async {
    _closed = true;
    _cleanupSocket();
    _pending = null;
  }
}

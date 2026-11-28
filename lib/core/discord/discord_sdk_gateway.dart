import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../boot_network.dart';
import '../platform/apple_tv.dart';
import 'discord_config.dart';
import 'discord_gateway.dart';
import 'discord_presence.dart';

bool get supportsNativeDiscordPresence =>
    !kIsWeb &&
    !isAppleTv &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Social SDK activity transport (phones, and Windows builds that carry the
/// SDK); the SDK owns authentication and reconnection.
///
/// On Windows it is also watched from here: the SDK client is started again
/// when it never gets ready or stays disconnected, and the activity is cleaned
/// up before it is sent. Phones keep the plain behaviour.
class DiscordSdkGateway extends DiscordGateway {
  DiscordSdkGateway(
    String token, {
    super.onAuthFailure,
    this.onUnavailable,
    DateTime Function()? now,
  }) : _token = token,
       _now = now ?? DateTime.now,
       super('');

  static DiscordSdkGateway? _owner;
  static const _channel = MethodChannel('zangetsu/discord_presence');

  /// The one answer for this run of the app; see [isAvailable].
  static Future<bool>? _availability;

  /// Windows: whether this build and PC can use the Social SDK. Asks the
  /// native side once. That only loads the DLL: no client, no network. A build
  /// without the SDK has no such channel, which counts as "no".
  static Future<bool> isAvailable() => _availability ??= _askAvailable();

  @visibleForTesting
  static void debugResetAvailability() => _availability = null;

  static Future<bool> _askAvailable() async {
    String reason;
    try {
      final answer = await _channel
          .invokeMethod<Object?>('isAvailable')
          .timeout(const Duration(seconds: 15));
      if (answer == 'ok') {
        debugPrint('[discord] SDK available');
        return true;
      }
      reason = answer is String && answer.isNotEmpty ? answer : 'no answer';
    } on MissingPluginException {
      reason = 'not in this build';
    } on TimeoutException {
      reason = 'timeout';
    } on PlatformException catch (e) {
      reason = e.code;
    } catch (e) {
      reason = '${e.runtimeType}';
    }
    debugPrint('[discord] SDK not available ($reason)');
    return false;
  }

  /// Taken once, so one gateway never changes rules halfway.
  final bool _isWindows =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// Windows: the SDK turned out not to be usable after all, so the owner can
  /// switch to the raw gateway.
  final void Function()? onUnavailable;

  /// Clock, injectable so tests can fake time.
  final DateTime Function() _now;

  String _token;
  bool _started = false;
  bool _closed = false;
  bool _hasPending = false;
  DiscordActivity? _activity;
  String _status = 'online';

  @override
  void connect() {
    _closed = false;
    _closing = false;
    _owner = this;
    _channel.setMethodCallHandler((call) async {
      if (_closed) return;
      if (call.method == 'authFailed') {
        // Before the owner is asked: if it refreshes, the new start replaces
        // this wait; if it cannot, the wait brings the next try.
        if (_isWindows) _onLoginFault();
        await onAuthFailure?.call();
      } else if (_isWindows) {
        _onWindowsStatus('${call.arguments}');
      } else {
        debugPrint('[discord] SDK ${call.method}: ${call.arguments}');
      }
    });
    unawaited(_start());
  }

  Future<void> _start() async {
    _started = false;
    final attempt = ++_attempt;
    if (_isWindows) {
      _ready = false;
      _state = '';
      _resendTimer?.cancel(); // a new client sends the status by itself
      _lastStart = _now();
      _arm(const Duration(seconds: 60));
    }
    final error = await _invoke('start', {
      'applicationId': DiscordConfig.applicationId,
      'token': _token,
    });
    if (_closed || !identical(_owner, this)) return;
    // Windows: a newer start replaced this one; its answer is the one that
    // counts.
    if (_isWindows && attempt != _attempt) return;
    if (error != null) {
      if (_isWindows &&
          !_closing &&
          (error == _missingPlugin || error == 'DISCORD_SDK_UNAVAILABLE')) {
        _watchdog?.cancel();
        onUnavailable?.call();
      }
      return;
    }
    _started = true;
    if (_hasPending) _send();
  }

  /// What [_invoke] answers when the native side is not there at all.
  static const _missingPlugin = 'missing plugin';

  /// Null when the call worked, else a short error code. The arguments of
  /// `start` hold the login and are never logged.
  Future<String?> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
      return null;
    } on PlatformException catch (e) {
      debugPrint('[discord] SDK $method failed: ${e.code}');
      return e.code;
    } on MissingPluginException {
      debugPrint('[discord] SDK unavailable on this build');
      return _missingPlugin;
    }
  }

  // ── Windows watchdog ─────────────────────────────────────────────────────
  // The SDK reconnects by itself, but can also end up stuck (never ready, or
  // disconnected for good). One timer waits for that and starts the client
  // again, with growing waits. Every restart leaves some native threads
  // behind, so it must never run in a tight loop or while the PC is offline.

  /// Counts starts, so a replaced start's answer is ignored (Windows).
  int _attempt = 0;
  bool _closing = false;
  bool _ready = false;

  /// Last connection state name from the SDK ('' after a start).
  String _state = '';
  DateTime? _lastStart;
  DateTime? _readyAt;

  /// Restarts since the SDK was last ready, and sessions in a row that were
  /// lost within a minute; both make the waits grow.
  int _restarts = 0;
  int _shortSessions = 0;
  Timer? _watchdog;

  /// True while the running timer waits out a fault (disconnected, login
  /// refused) and not merely a slow connect. More faults do not extend it.
  bool _faultWait = false;

  void _arm(Duration base, {bool fault = false}) {
    if (_closed || _closing) return;
    _watchdog?.cancel();
    _faultWait = fault;
    const longest = Duration(minutes: 5);
    // One short session is ordinary bad luck; only a row of them counts.
    final extra = _shortSessions > 1 ? _shortSessions - 1 : 0;
    final wait = base * (1 << (_restarts + extra).clamp(0, 8));
    _watchdog = Timer(wait > longest ? longest : wait, _onWatchdog);
  }

  void _armFault() {
    if (_faultWait && (_watchdog?.isActive ?? false)) return;
    _arm(const Duration(seconds: 10), fault: true);
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
    _faultWait = false;
  }

  /// Sends the status again after Discord refused the login for it while the
  /// client was connected (see [_onLoginFault]).
  Timer? _resendTimer;
  int _loginFaults = 0;
  DateTime? _lastLoginFault;

  /// Discord refused the login. A client that is not connected is started
  /// again after a wait. A connected one is left alone: only a new login helps
  /// it, and a restart would just get ready and be refused again, for ever. It
  /// sends its status again after a growing wait instead, which asks for a
  /// refresh again if the login is still refused. Getting ready or starting
  /// again does not shorten that wait; ten minutes without a refusal does.
  void _onLoginFault() {
    if (!_ready) {
      _armFault();
      return;
    }
    if (_closed || _closing) return;
    final last = _lastLoginFault;
    _lastLoginFault = _now();
    if (_resendTimer?.isActive ?? false) return;
    if (last == null || _now().difference(last) > const Duration(minutes: 10)) {
      _loginFaults = 0;
    }
    const longest = Duration(minutes: 5);
    final wait = const Duration(seconds: 10) * (1 << _loginFaults.clamp(0, 8));
    _loginFaults++;
    _resendTimer = Timer(wait > longest ? longest : wait, _onResend);
  }

  void _onResend() {
    if (_closed || _closing || !identical(_owner, this)) return;
    if (BootConnectivity.instance.offline.value) {
      _resendTimer = Timer(const Duration(minutes: 1), _onResend);
      return;
    }
    // Not connected: the watchdog is in charge, and a client that gets ready
    // sends its status by itself.
    if (_ready && _started && _hasPending) _send();
  }

  void _onWatchdog() {
    _stopWatchdog();
    if (_closed || _closing || !identical(_owner, this)) return;
    if (_ready) return; // never start a connected client again
    if (BootConnectivity.instance.offline.value) {
      debugPrint('[discord] SDK waiting for the network');
      return; // [retryNow] continues once it is back.
    }
    _restarts++;
    debugPrint('[discord] SDK not ready — starting again (try $_restarts)');
    unawaited(_start());
  }

  @override
  void retryNow() {
    if (!_isWindows || _closed || _closing || _ready) return;
    if (!identical(_owner, this)) return;
    // A focus change must not restart the client over and over offline.
    if (BootConnectivity.instance.offline.value) return;
    final last = _lastStart;
    final waiting = _watchdog?.isActive ?? false;
    if (waiting &&
        last != null &&
        _now().difference(last) <= const Duration(seconds: 10)) {
      return;
    }
    _restarts = 0;
    debugPrint('[discord] SDK retrying now');
    unawaited(_start());
  }

  /// Handles one status line from the native side (numbers only, no titles
  /// and no login).
  void _onWindowsStatus(String event) {
    // The log redactor hides whatever follows "token:", which here is only an
    // error number testers need to send us.
    final line = event.startsWith('token:')
        ? 'login:${event.substring('token:'.length)}'
        : event;
    debugPrint('[discord] SDK status: $line');
    if (event.startsWith('connection:')) {
      _onConnection(event.split(':')[1]);
    } else if (event.startsWith('token:error') &&
        _number(event, 'http') != 401) {
      // 401 comes with its own authFailed call.
      _armFault();
    } else if (event.startsWith('published:error')) {
      _onPublishError(event);
    }
  }

  void _onConnection(String state) {
    final before = _state;
    _state = state;
    if (state == 'Ready') {
      _ready = true;
      _readyAt = _now();
      _restarts = 0;
      _stopWatchdog();
      return;
    }
    final lostReady = _ready;
    _ready = false;
    if (lostReady) {
      final at = _readyAt;
      final short =
          at != null && _now().difference(at) < const Duration(minutes: 1);
      _shortSessions = short ? _shortSessions + 1 : 0;
    }
    if (state == 'Disconnected') {
      _armFault();
    } else if (lostReady || before == 'Disconnected') {
      _arm(const Duration(seconds: 60));
    }
  }

  static int? _number(String event, String key) {
    final m = RegExp('(?:^|:)$key=(-?\\d+)').firstMatch(event);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// How far the current activity's images were reduced after Discord refused
  /// it: 0 as given, 1 only the app logo, 2 none.
  int _imageStep = 0;

  /// Discord refused the activity, most likely over a poster it cannot use:
  /// send the same one with the app logo, then with no images at all. Not for
  /// a refused login, a rate limit or a server fault, which images don't fix.
  void _onPublishError(String event) {
    final error = _number(event, 'error');
    final http = _number(event, 'http') ?? 0;
    if (error != 2 && error != 6 && error != 9) return;
    if (http == 401 || http == 429 || (http >= 500 && http < 600)) return;
    final activity = _activity;
    if (activity == null || _closing || _imageStep >= 2) return;
    final assets = _windowsActivity(activity)['assets'];
    if (assets is! Map) return;
    final large = assets['large_image'];
    final small = assets['small_image'];
    if (large == null && small == null) return; // no image to give up
    final logoOnly = large == DiscordConfig.appLogoUrl && small == null;
    _imageStep = _imageStep == 0 && !logoOnly ? 1 : 2;
    debugPrint(
      '[discord] SDK refused the status — sending it again with '
      '${_imageStep == 1 ? 'the app logo' : 'no images'}',
    );
    if (_started) _send();
  }

  /// The activity as the SDK gets it on Windows: cleaned up, with the images
  /// reduced as far as [_imageStep] says.
  Map<String, dynamic> _windowsActivity(DiscordActivity activity) {
    final out = discordSanitizeSdkActivity(
      activity.toJson(DiscordConfig.applicationId),
    );
    final assets = out['assets'];
    if (_imageStep == 0 || assets is! Map) return out;
    if (_imageStep >= 2) {
      out.remove('assets');
      return out;
    }
    out['assets'] = <String, dynamic>{
      'large_image': DiscordConfig.appLogoUrl,
      if (assets['large_text'] != null) 'large_text': assets['large_text'],
    };
    return out;
  }

  @override
  void updateToken(String token) {
    if (_closed) return;
    _token = token.startsWith('Bearer ') ? token.substring(7) : token;
    unawaited(_start());
  }

  @override
  void setPresence(DiscordActivity? activity, {String status = 'online'}) {
    if (_closed) return;
    _activity = activity;
    _status = status;
    _imageStep = 0;
    _hasPending = true;
    if (_started) _send();
  }

  void _send() {
    if (!identical(_owner, this)) return;
    final activity = _activity;
    unawaited(
      _invoke(activity == null ? 'clear' : 'update', {
        'activity': activity == null
            ? null
            : _isWindows
            ? _windowsActivity(activity)
            : activity.toJson(DiscordConfig.applicationId),
        'status': _status,
      }),
    );
  }

  @override
  Future<void> clearThenClose() async {
    if (_closed) return;
    if (_isWindows) {
      // Nothing may start the client again on the way out.
      _closing = true;
      _stopWatchdog();
      _resendTimer?.cancel();
    }
    setPresence(null, status: _status);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await close();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _started = false;
    _activity = null;
    _stopWatchdog();
    _resendTimer?.cancel();
    // A delayed close from an old toggle must not shut down its replacement.
    if (!identical(_owner, this)) return;
    _owner = null;
    _channel.setMethodCallHandler(null);
    await _invoke('close');
  }
}

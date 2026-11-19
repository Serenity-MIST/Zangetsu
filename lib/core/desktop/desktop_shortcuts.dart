import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'desktop_prefs.dart';
import '../../l10n/l10n.dart';

/// Where a shortcut applies. App shortcuts work everywhere; the others only
/// while that page (or the player / reader) has focus.
enum DesktopShortcutScope {
  app,
  home,
  showPage,
  player,
  reader,
  downloads,
  lists,
  settings,
}

/// One named keyboard action with its default keys. The [id] is what code
/// binds against, so it never changes; the keys may be remapped by the user
/// when [remappable] is true.
class DesktopShortcutSpec {
  const DesktopShortcutSpec({
    required this.id,
    required this.scope,
    required this.label,
    required this.defaults,
    this.remappable = false,
    this.description,
  });

  /// Stable id, e.g. `player.playPause`.
  final String id;
  final DesktopShortcutScope scope;

  /// What the action does, shown on the Keyboard shortcuts page.
  final String label;

  /// Default key combinations (any of them triggers the action).
  final List<SingleActivator> defaults;

  /// Whether Settings lets the user change the keys.
  final bool remappable;

  /// Optional extra explanation shown under the label.
  final String? description;
}

/// Single registry of the Windows keyboard shortcuts. Features bind through
/// [bindings] / [matches] so the help overlay, the Settings page and the real
/// key handling all read the same table, and user remaps apply everywhere.
abstract final class DesktopShortcuts {
  // Registration order is kept so the Settings page lists actions in a
  // sensible order; the map gives O(1) lookups by id.
  static final List<String> _order = [];
  static final Map<String, DesktopShortcutSpec> _specs = {};

  // User remaps by id. Only remappable specs are honoured.
  static final Map<String, List<SingleActivator>> _overrides = {};

  static final _Notifier _changes = _Notifier();

  /// Fires when specs are registered or keys are remapped / reset.
  static Listenable get changes => _changes;

  /// Adds or replaces specs; re-registering an id keeps its position.
  static void register(Iterable<DesktopShortcutSpec> specs) {
    for (final s in specs) {
      if (!_specs.containsKey(s.id)) _order.add(s.id);
      _specs[s.id] = s;
    }
    _changes.ping();
  }

  /// Every registered spec, in registration order.
  static List<DesktopShortcutSpec> get all => [
    for (final id in _order) _specs[id]!,
  ];

  static DesktopShortcutSpec? spec(String id) => _specs[id];

  /// Whether the user has changed this action's keys.
  static bool isOverridden(String id) =>
      _overrides.containsKey(id) && (_specs[id]?.remappable ?? false);

  /// The keys that trigger [id] now: the user's remap if set, else defaults.
  static List<SingleActivator> activatorsFor(String id) {
    final override = _overrides[id];
    // Remaps only apply to actions that allow them (a stale saved remap for
    // an action that is no longer remappable is ignored).
    if (override != null && (_specs[id]?.remappable ?? false)) return override;
    return _specs[id]?.defaults ?? const [];
  }

  /// Builds a `CallbackShortcuts` map from `{id: callback}`. The '?' key is
  /// bound by character so it works on any keyboard layout (and does not
  /// fire twice next to a Shift+/ binding).
  static Map<ShortcutActivator, VoidCallback> bindings(
    Map<String, VoidCallback> actions,
  ) {
    final map = <ShortcutActivator, VoidCallback>{};
    for (final entry in actions.entries) {
      for (final a in activatorsFor(entry.key)) {
        map[_isQuestion(a) ? const CharacterActivator('?') : a] = entry.value;
      }
    }
    return map;
  }

  /// True when [event] is a key-down / repeat for one of [id]'s keys, for
  /// handlers that use onKeyEvent or HardwareKeyboard directly.
  static bool matches(String id, KeyEvent event) {
    if (event is KeyUpEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    for (final a in activatorsFor(id)) {
      if (_isQuestion(a)) {
        // Layout-independent '?': match the typed character, no Ctrl/Alt.
        if (event.character == '?' &&
            !keyboard.isControlPressed &&
            !keyboard.isAltPressed) {
          return true;
        }
      }
      if (a.accepts(event, keyboard)) return true;
    }
    return false;
  }

  /// Saves a remap for [id] (an empty list leaves the action unbound).
  static Future<void> setOverride(
    String id,
    List<SingleActivator> activators,
  ) async {
    _overrides[id] = List.unmodifiable(activators);
    _changes.ping();
    await _save();
  }

  /// Returns [id] to its default keys.
  static Future<void> clearOverride(String id) async {
    if (_overrides.remove(id) == null) return;
    _changes.ping();
    await _save();
  }

  /// Returns every action to its default keys.
  static Future<void> resetAll() async {
    _overrides.clear();
    _changes.ping();
    await _save();
  }

  /// Id of another action that already uses [a] where it would clash: in the
  /// same scope, or in the app scope (which applies everywhere). Null when
  /// the key is free.
  static String? conflictWith(String id, SingleActivator a) {
    final own = _specs[id];
    for (final otherId in _order) {
      if (otherId == id) continue;
      final other = _specs[otherId]!;
      final sameArea =
          own == null ||
          other.scope == own.scope ||
          other.scope == DesktopShortcutScope.app ||
          own.scope == DesktopShortcutScope.app;
      if (!sameArea) continue;
      if (activatorsFor(otherId).any((b) => sameActivator(a, b))) {
        return otherId;
      }
    }
    return null;
  }

  /// SingleActivator has no value equality; compare key and modifiers.
  static bool sameActivator(SingleActivator a, SingleActivator b) =>
      a.trigger == b.trigger &&
      a.control == b.control &&
      a.shift == b.shift &&
      a.alt == b.alt &&
      a.meta == b.meta;

  /// Human label such as 'Ctrl+Shift+F', 'Space' or '?'.
  static String describe(SingleActivator a) {
    if (_isQuestion(a)) return '?';
    final parts = <String>[
      if (a.control) 'Ctrl',
      if (a.alt) 'Alt',
      if (a.shift) 'Shift',
      if (a.meta) 'Win',
      _keyName(a.trigger),
    ];
    return parts.join('+');
  }

  /// All of [id]'s keys as one label: 'Space / K'. Ten digit keys collapse
  /// to '0-9' so the percent-jump row stays readable.
  static String describeAll(String id) {
    final list = activatorsFor(id);
    if (list.isEmpty) return appL10n.shortcutNotSet;
    final digits = list.where(_isPlainDigit).length;
    if (digits == 10 && list.length == 10) return '0-9';
    return list.map(describe).join(' / ');
  }

  /// Loads remaps saved in [DesktopPrefs] (called from [DesktopPrefs.init]).
  static void loadOverrides() {
    _overrides.clear();
    final raw = DesktopPrefs.readRaw(DesktopPrefs.shortcutOverridesKey);
    if (raw is Map) {
      for (final entry in raw.entries) {
        final id = entry.key;
        final list = entry.value;
        if (id is! String || list is! List) continue;
        final decoded = [
          for (final item in list)
            if (item is String) ?decodeActivator(item),
        ];
        _overrides[id] = List.unmodifiable(decoded);
      }
    }
    _changes.ping();
  }

  /// Test hook: forgets specs and remaps without touching storage.
  @visibleForTesting
  static void debugReset() {
    _order.clear();
    _specs.clear();
    _overrides.clear();
    _changes.ping();
  }

  // Stored as {id: ['<keyId>:<ctrl><shift><alt><meta>', ...]} so the Hive
  // box needs no adapters.
  static Future<void> _save() => DesktopPrefs.writeRaw(
    DesktopPrefs.shortcutOverridesKey,
    _overrides.isEmpty
        ? null
        : {
            for (final e in _overrides.entries)
              e.key: [for (final a in e.value) encodeActivator(a)],
          },
  );

  /// Serialises one activator for storage.
  @visibleForTesting
  static String encodeActivator(SingleActivator a) =>
      '${a.trigger.keyId}:${a.control ? 1 : 0}${a.shift ? 1 : 0}'
      '${a.alt ? 1 : 0}${a.meta ? 1 : 0}';

  /// Reads one stored activator; null when it is malformed.
  @visibleForTesting
  static SingleActivator? decodeActivator(String s) {
    final parts = s.split(':');
    if (parts.length != 2 || parts[1].length != 4) return null;
    final id = int.tryParse(parts[0]);
    if (id == null) return null;
    final key = LogicalKeyboardKey.findKeyByKeyId(id) ?? LogicalKeyboardKey(id);
    final m = parts[1];
    return SingleActivator(
      key,
      control: m[0] == '1',
      shift: m[1] == '1',
      alt: m[2] == '1',
      meta: m[3] == '1',
    );
  }

  // '?' is defined as Shift+/ (US layout) but shown and matched as '?'.
  static bool _isQuestion(SingleActivator a) =>
      a.trigger == LogicalKeyboardKey.slash &&
      a.shift &&
      !a.control &&
      !a.alt &&
      !a.meta;

  static bool _isPlainDigit(SingleActivator a) =>
      !a.control &&
      !a.shift &&
      !a.alt &&
      !a.meta &&
      a.trigger.keyId >= LogicalKeyboardKey.digit0.keyId &&
      a.trigger.keyId <= LogicalKeyboardKey.digit9.keyId;

  // Short, familiar names for keys whose Flutter label is long or blank.
  static final Map<LogicalKeyboardKey, String> _names = {
    LogicalKeyboardKey.space: 'Space',
    LogicalKeyboardKey.escape: 'Esc',
    LogicalKeyboardKey.enter: 'Enter',
    LogicalKeyboardKey.numpadEnter: 'Enter',
    LogicalKeyboardKey.arrowLeft: 'Left',
    LogicalKeyboardKey.arrowRight: 'Right',
    LogicalKeyboardKey.arrowUp: 'Up',
    LogicalKeyboardKey.arrowDown: 'Down',
    LogicalKeyboardKey.pageUp: 'Page Up',
    LogicalKeyboardKey.pageDown: 'Page Down',
    LogicalKeyboardKey.home: 'Home',
    LogicalKeyboardKey.end: 'End',
    LogicalKeyboardKey.delete: 'Delete',
    LogicalKeyboardKey.backspace: 'Backspace',
    LogicalKeyboardKey.tab: 'Tab',
    LogicalKeyboardKey.contextMenu: 'Menu',
    LogicalKeyboardKey.slash: '/',
    LogicalKeyboardKey.comma: ',',
    LogicalKeyboardKey.period: '.',
    LogicalKeyboardKey.equal: '=',
    LogicalKeyboardKey.minus: '-',
    LogicalKeyboardKey.bracketLeft: '[',
    LogicalKeyboardKey.bracketRight: ']',
    LogicalKeyboardKey.semicolon: ';',
    LogicalKeyboardKey.quote: "'",
    LogicalKeyboardKey.backquote: '`',
    LogicalKeyboardKey.backslash: r'\',
  };

  static String _keyName(LogicalKeyboardKey key) {
    final known = _names[key];
    if (known != null) return known;
    final label = key.keyLabel;
    // Letters come back lower-case on some layouts; longer names stay as-is.
    if (label.trim().isNotEmpty) {
      return label.length == 1 ? label.toUpperCase() : label;
    }
    return key.debugName ?? 'Key ${key.keyId}';
  }
}

/// ChangeNotifier with a public ping, kept private to this library.
class _Notifier extends ChangeNotifier {
  void ping() => notifyListeners();
}

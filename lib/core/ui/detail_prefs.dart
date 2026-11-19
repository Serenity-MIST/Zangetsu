import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

/// Detail-screen behaviour: whether episode/chapter lists open reversed
/// (newest first). Off by default. The per-screen reverse button keeps working
/// as-is — this only sets what every detail screen starts with.
///
/// Windows (show-10): the episode list also remembers list/grid view app-wide,
/// and the newest-first button writes back into [reverseEpisodesDefault], so
/// the last choice carries over to the next show.
class DetailPrefs {
  static const String boxName = 'ui_prefs';
  static const String _reverseKey = 'reverseEpisodesDefault';

  /// Windows (show-10): last list/grid choice in the episode list.
  static const String _gridKey = 'episodeGridView';

  static bool reverseEpisodesDefault = false;

  /// Windows (show-10): true when the episode list last showed the grid.
  /// Read at startup by [init]; phone never writes it, so it stays false.
  static bool episodeGridView = false;

  static Future<Box> _open() async => Hive.isBoxOpen(boxName)
      ? Hive.box(boxName)
      : await openBoxSafely(boxName);

  static Future<void> init() async {
    final box = await _open();
    reverseEpisodesDefault = box.get(_reverseKey, defaultValue: false) as bool;
    // Read defensively: a missing or odd value means "list", the old default.
    episodeGridView = box.get(_gridKey, defaultValue: false) == true;
  }

  static Future<void> setReverseEpisodesDefault(bool value) async {
    reverseEpisodesDefault = value;
    await (await _open()).put(_reverseKey, value);
  }

  /// Windows (show-10): remembers list/grid for every show. The in-memory
  /// value updates first, so the next detail page opens right. Only writes
  /// when [init] has opened the box (always, in the app); without it (widget
  /// tests) the choice lives in memory rather than opening storage here.
  static Future<void> setEpisodeGridView(bool value) async {
    episodeGridView = value;
    if (!Hive.isBoxOpen(boxName)) return;
    await Hive.box(boxName).put(_gridKey, value);
  }

  /// Windows (show-10): saves the newest-first button's choice as the
  /// app-wide default. Like [setEpisodeGridView] it never opens storage
  /// itself; [setReverseEpisodesDefault] (the settings switch) is unchanged.
  static Future<void> rememberReverseEpisodes(bool value) async {
    reverseEpisodesDefault = value;
    if (!Hive.isBoxOpen(boxName)) return;
    await Hive.box(boxName).put(_reverseKey, value);
  }
}

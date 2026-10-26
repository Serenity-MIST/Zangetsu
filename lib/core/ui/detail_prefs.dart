import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

/// Detail-screen behaviour: whether episode/chapter lists open reversed
/// (newest first). Off by default. The per-screen reverse button keeps working
/// as-is — this only sets what every detail screen starts with.
class DetailPrefs {
  static const String boxName = 'ui_prefs';
  static const String _reverseKey = 'reverseEpisodesDefault';

  static bool reverseEpisodesDefault = false;

  static Future<Box> _open() async => Hive.isBoxOpen(boxName)
      ? Hive.box(boxName)
      : await openBoxSafely(boxName);

  static Future<void> init() async {
    final box = await _open();
    reverseEpisodesDefault = box.get(_reverseKey, defaultValue: false) as bool;
  }

  static Future<void> setReverseEpisodesDefault(bool value) async {
    reverseEpisodesDefault = value;
    await (await _open()).put(_reverseKey, value);
  }
}

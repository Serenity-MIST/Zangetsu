import 'package:hive/hive.dart';

/// Value types the app opens Hive boxes with. Hive's `Hive.box<E>(name)` only
/// returns a box when E is EXACTLY the type it was opened with, so a reader
/// that does not know the type has to try each one.
///
/// `List` matters: `zmode_source_order` is a `Box<List>`, and without that case
/// a backup quietly skipped it.
Box<dynamic>? anyOpenBox(String name) {
  if (!Hive.isBoxOpen(name)) return null;
  // Each try is cheap: Hive throws straight away on a type mismatch.
  for (final get in <Box<dynamic> Function()>[
    () => Hive.box<Map>(name),
    () => Hive.box<String>(name),
    () => Hive.box<List>(name),
    () => Hive.box<dynamic>(name),
    () => Hive.box<int>(name),
    () => Hive.box<bool>(name),
    () => Hive.box<double>(name),
  ]) {
    try {
      return get();
    } catch (_) {
      // Not this type; try the next one.
    }
  }
  return null;
}

/// Deep copy of a Hive value into plain JSON-friendly maps and lists, so a
/// dumped box survives `jsonEncode` (Hive hands back `Map<dynamic, dynamic>`)
/// and later edits to the live box can't change the copy.
Object? plainCopy(Object? value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final e in value.entries) e.key.toString(): plainCopy(e.value),
    };
  }
  if (value is List) return [for (final v in value) plainCopy(v)];
  return value;
}

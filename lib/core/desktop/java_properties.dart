/// Removes one CloudStream DataStore namespace while preserving every other
/// property verbatim. The JVM writes Java properties, including escaped keys;
/// matching raw line prefixes would miss spaces/non-ASCII provider names.
({String text, int removed}) removeJavaPropertyNamespace(String text, String namespace) {
  final lines = text.split('\n');
  final kept = <String>[];
  var removed = 0;
  for (var index = 0; index < lines.length; index++) {
    final original = <String>[lines[index]];
    var logical = lines[index].replaceFirst(RegExp(r'\r$'), '');
    final comment = logical.trimLeft().startsWith('#') || logical.trimLeft().startsWith('!');
    while (!comment && _continues(logical) && index + 1 < lines.length) {
      final next = lines[++index];
      original.add(next);
      logical = logical.substring(0, logical.length - 1) +
          next.replaceFirst(RegExp(r'^[ \t\f]+'), '').replaceFirst(RegExp(r'\r$'), '');
    }
    final key = _propertyKey(logical);
    if (key != null && key.startsWith('$namespace/')) {
      removed++;
    } else {
      kept.addAll(original);
    }
  }
  return (text: kept.join('\n'), removed: removed);
}

/// Java properties continue a logical line after an odd trailing backslash.
bool _continues(String value) {
  var count = 0;
  for (var i = value.length - 1; i >= 0 && value[i] == '\\'; i--) {
    count++;
  }
  return count.isOdd;
}

/// Decodes only a property's key; values and unrelated formatting stay intact.
String? _propertyKey(String line) {
  final source = line.replaceFirst(RegExp(r'^[ \t\f]+'), '');
  if (source.isEmpty || source.startsWith('#') || source.startsWith('!')) return null;
  final key = StringBuffer();
  for (var i = 0; i < source.length; i++) {
    var char = source[i];
    if ('=: \t\f'.contains(char)) break;
    if (char == '\\') {
      if (++i >= source.length) throw const FormatException('Incomplete property key escape');
      char = source[i];
      if (char == 'u') {
        if (i + 4 >= source.length) throw const FormatException('Incomplete Unicode property key');
        final code = int.tryParse(source.substring(i + 1, i + 5), radix: 16);
        if (code == null) throw const FormatException('Invalid Unicode property key');
        key.writeCharCode(code);
        i += 4;
        continue;
      }
      char = switch (char) {'t' => '\t', 'n' => '\n', 'r' => '\r', 'f' => '\f', _ => char};
    }
    key.write(char);
  }
  return key.toString();
}

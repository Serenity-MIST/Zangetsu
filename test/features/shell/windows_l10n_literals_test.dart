import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/desktop/desktop_shortcut_catalog.dart';
import 'package:watch_app/core/desktop/desktop_shortcuts.dart';

/// shell-11 (Option A): Windows screens must read their text from the
/// translation files (lib/l10n/app_en.arb), not from English literals, so a
/// user in another language never sees a mixed-language app and Settings
/// search can find every row.
///
/// The checks read the sources, like settings_search_index_test.dart:
///  * no `// l10n` "move me later" markers are left anywhere in lib/;
///  * Windows-only files (lib/core/desktop/ and files named *desktop*) pass
///    no English literal to a label, tooltip, title, message or Text;
///  * every Windows keyboard shortcut has a translated name.

/// UI arguments and calls whose string argument is shown to the user.
final _uiLiteral = RegExp(
  r'''(?:\b(?:label|tooltip|title|subtitle|message|hintText|labelText|'''
  r'''description|confirmLabel|cancelLabel|semanticLabel|searchHint|'''
  r'''helperText|errorText|actionLabel|addLabel|hint|caption)\s*:\s*|'''
  r'''\bText\(\s*|showAppToast\([^,]+,\s*|_snack\(\s*|_toast\(\s*|'''
  r'''showGlobalSnack\(\s*)(['"])((?:(?!\1).)*)\1''',
);

/// Literals that are allowed to stay English, each with the reason.
const _allowed = {
  // Exception text for logs; screens show sourceFailureMessage instead.
  'Source timed out',
  'Extension engine HTTP \${reply.\$1}',
  // PlatformException text; callers treat CANCELLED quietly.
  'Verification cancelled',
  // PlatformException text (CANCELLED code); callers treat it quietly.
  'Verification not completed',
};

/// Key names stay as printed on the keyboard, so they are not words to
/// translate.
final _keyNames = RegExp(
  r'\b(?:Esc|Ctrl|Alt|Shift|Enter|Del|Tab|Home|End|Space|F\d{1,2})\b',
);

/// The text a literal shows once interpolations and key names are removed.
String _wordsIn(String literal) {
  var text = literal;
  // Remove ${...} from the innermost out, then $name.
  final braces = RegExp(r'\$\{[^{}]*\}');
  while (braces.hasMatch(text)) {
    text = text.replaceAll(braces, '');
  }
  // A quote inside an interpolation (`'${map['k']}'`) cuts the literal
  // short and leaves an unclosed `${`: that rest is code, not text.
  return text
      .replaceAll(RegExp(r'\$\{.*$'), '')
      .replaceAll(RegExp(r'\$\w+'), '')
      .replaceAll(_keyNames, '');
}

/// Every Dart file under [dir], recursively.
Iterable<File> _dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

/// Forward-slash path relative to the package root, for readable failures.
String _rel(File f) => f.path.replaceAll(r'\', '/');

/// TV files keep their own (separately owned) strings.
bool _isTv(String path) => path.contains('_tv');

void main() {
  test('no "// l10n" markers are left in lib/', () {
    final left = <String>[];
    for (final f in _dartFiles('lib')) {
      final path = _rel(f);
      if (_isTv(path) || path.startsWith('lib/l10n/')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('// l10n')) left.add('$path:${i + 1}');
      }
    }
    expect(
      left,
      isEmpty,
      reason:
          'Move these strings into lib/l10n/app_en.arb, run flutter gen-l10n '
          'and read them through context.l10n (or appL10n without a '
          'context):\n  ${left.join('\n  ')}',
    );
  });

  test('Windows-only screens show no English literals', () {
    final found = <String>[];
    for (final f in _dartFiles('lib')) {
      final path = _rel(f);
      final name = path.split('/').last;
      final windowsOnly =
          path.startsWith('lib/core/desktop/') || name.contains('desktop');
      if (!windowsOnly || _isTv(path)) continue;
      // The catalog keeps English source labels on purpose; the next test
      // checks each one is translated in desktop_shortcut_labels.dart.
      if (name == 'desktop_shortcut_catalog.dart') continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        for (final m in _uiLiteral.allMatches(line)) {
          final literal = m.group(2)!;
          if (_allowed.contains(literal)) continue;
          if (RegExp('[A-Za-z]{2}').hasMatch(_wordsIn(literal))) {
            found.add('$path:${i + 1}: $literal');
          }
        }
      }
    }
    expect(
      found,
      isEmpty,
      reason:
          'Windows text must come from lib/l10n/app_en.arb (context.l10n or '
          'appL10n). Add a key and use it, or, for text that must stay '
          'English (logs, brand names), add it to _allowed with a reason:\n  '
          '${found.join('\n  ')}',
    );
  });

  test('every Windows shortcut has a translated name', () {
    registerDefaultDesktopShortcuts();
    final labels = File(
      'lib/core/desktop/desktop_shortcut_labels.dart',
    ).readAsStringSync();
    // Numbered families are translated by their prefix.
    final numbered = RegExp(r'^(app\.section|app\.mode|show\.tab)\d$');
    final missing = [
      for (final spec in DesktopShortcuts.all)
        if (!numbered.hasMatch(spec.id) && !labels.contains("'${spec.id}'"))
          spec.id,
    ];
    expect(
      missing,
      isEmpty,
      reason:
          'Add these ids to desktopShortcutLabel in '
          'lib/core/desktop/desktop_shortcut_labels.dart:\n  '
          '${missing.join('\n  ')}',
    );
  });
}

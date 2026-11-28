import 'dart:io';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform, visibleForTesting;
import 'package:flutter/material.dart';

import '../../core/desktop/desktop_dialogs.dart';
import '../../core/reading/reader_prefs.dart';
import '../../l10n/l10n.dart';

/// Windows novel fonts (reader-11 B): the three built-in choices, the fonts
/// that ship with Windows, and every other font installed on the PC, picked
/// from a searchable list. Phones keep their three-way choice.

/// Fonts every current Windows install has, listed first so the common
/// reading faces are at hand without searching.
const List<String> kWindowsReadingFonts = [
  'Georgia',
  'Cambria',
  'Constantia',
  'Palatino Linotype',
  'Book Antiqua',
  'Times New Roman',
  'Sitka Text',
  'Calibri',
  'Candara',
  'Corbel',
  'Segoe UI',
  'Arial',
  'Verdana',
  'Tahoma',
  'Trebuchet MS',
  'Bahnschrift',
  'Consolas',
];

/// Installed fonts that only draw symbols or icons; never useful for text.
final RegExp _symbolFonts = RegExp(
  r'wingdings|webdings|marlett|^symbol$|mdl2|fluent icons|emoji|holomdl|'
  r'segoe ui symbol|ms outlook|ms reference specialty|bookshelf symbol',
  caseSensitive: false,
);

/// Style words Windows appends to a face's registry name ("Arial Bold
/// Italic"); stripped to get back to the family the text engine knows.
const Set<String> _styleWords = {
  'bold',
  'italic',
  'oblique',
  'light',
  'semilight',
  'semibold',
  'demibold',
  'extrabold',
  'extralight',
  'ultrabold',
  'ultralight',
  'black',
  'heavy',
  'medium',
  'thin',
  'regular',
  'condensed',
  'semicondensed',
  'narrow',
  'variable',
};

/// Turns the value names of the Windows Fonts registry key ("Arial Bold
/// (TrueType)", "Cambria & Cambria Math (TrueType)") into family names,
/// without duplicates, symbol fonts or style suffixes, sorted by name.
@visibleForTesting
List<String> parseWindowsFontNames(Iterable<String> registryNames) {
  final families = <String, String>{};
  for (final raw in registryNames) {
    // Drop the "(TrueType)" / "(OpenType)" tag.
    final name = raw.replaceAll(RegExp(r'\s*\([^)]*\)\s*$'), '').trim();
    for (final part in name.split(' & ')) {
      final words = part.trim().split(RegExp(r'\s+'));
      while (words.length > 1 &&
          _styleWords.contains(words.last.toLowerCase())) {
        words.removeLast();
      }
      final family = words.join(' ').trim();
      if (family.isEmpty || _symbolFonts.hasMatch(family)) continue;
      families.putIfAbsent(family.toLowerCase(), () => family);
    }
  }
  final list = families.values.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return list;
}

/// Pulls the value names out of `reg query` output: each value line is
/// `    <name>    REG_SZ    <file>`.
@visibleForTesting
List<String> parseRegQueryValueNames(String output) {
  final names = <String>[];
  for (final line in output.split(RegExp(r'\r?\n'))) {
    final match = RegExp(r'^\s{2,}(.+?)\s{2,}REG_\w+').firstMatch(line);
    if (match != null) names.add(match.group(1)!);
  }
  return names;
}

Future<List<String>>? _installedFonts;

/// Every font family installed for this PC and this user, read once from
/// the Fonts registry keys. Empty off Windows or when reading fails.
Future<List<String>> installedWindowsFonts() =>
    _installedFonts ??= _readInstalledFonts();

Future<List<String>> _readInstalledFonts() async {
  if (!Platform.isWindows) return const [];
  const key = r'\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts';
  final names = <String>[];
  for (final hive in const ['HKLM', 'HKCU']) {
    try {
      final result = await Process.run('reg', ['query', '$hive$key']);
      if (result.exitCode == 0) {
        names.addAll(parseRegQueryValueNames('${result.stdout}'));
      }
    } catch (_) {
      // A locked-down PC may refuse; the built-in list still works.
    }
  }
  return parseWindowsFontNames(names);
}

/// Display name for a [ReaderPrefs.fontFamily] value.
String novelFontLabel(String key, {String systemLabel = 'System'}) {
  final installed = ReaderPrefs.installedFontName(key);
  if (installed != null) return installed;
  final windows = defaultTargetPlatform == TargetPlatform.windows;
  return switch (key) {
    // Font names (Georgia, Segoe UI) are not translated.
    'serif' => windows ? appL10n.fontSerifNamed('Georgia') : 'Serif',
    'system' => windows ? '$systemLabel (Segoe UI)' : systemLabel,
    _ => 'Inter',
  };
}

/// Opens the searchable Windows font list and returns the picked
/// [ReaderPrefs.fontFamily] value, or null when it was dismissed. Each row
/// previews its own face.
Future<String?> pickNovelFont(
  BuildContext context, {
  required String current,
  required String title,
  String systemLabel = 'System',
}) async {
  final installed = await installedWindowsFonts();
  if (!context.mounted) return null;
  final keys = <String>['inter', 'serif', 'system'];
  final seen = <String>{};
  for (final family in [...kWindowsReadingFonts, ...installed]) {
    if (seen.add(family.toLowerCase())) {
      keys.add(ReaderPrefs.installedFontKey(family));
    }
  }
  // A font picked earlier and since uninstalled still shows as current.
  if (!keys.contains(current)) keys.insert(3, current);
  return showDesktopChoiceDialog<String>(
    context,
    title: title,
    searchable: true,
    searchHint: context.l10n.searchFonts,
    current: current,
    options: [
      for (final k in keys) (k, novelFontLabel(k, systemLabel: systemLabel)),
    ],
    leading: {
      for (final k in keys)
        k: SizedBox(
          width: 34,
          child: Text(
            'Aa',
            style: TextStyle(
              fontFamily: _previewFamily(k),
              fontSize: 17,
              color: Colors.white,
            ),
          ),
        ),
    },
  );
}

/// The face a picker row previews in (matches what the reader will use).
String? _previewFamily(String key) =>
    ReaderPrefs.installedFontName(key) ??
    switch (key) {
      'serif' => 'Georgia',
      'system' => 'Segoe UI',
      _ => 'Inter',
    };

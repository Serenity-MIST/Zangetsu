/// Enumerates settings controls and their handlers without opening user data.
/// Run with `dart run tool/audit_desktop_settings.dart`; JSON/CSV reports live
/// under the ignored merge-work directory, so no generated docs are shipped.
library;

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// Collects each concrete control, including controls behind platform gates.
class SettingsInventory extends RecursiveAstVisitor<void> {
  SettingsInventory(this.path, this.lines, this.translations);
  final String path;
  final List<int> lines;
  final Map<String, dynamic> translations;
  final entries = <Map<String, Object?>>[];

  /// Resolves English localisation keys while retaining dynamic source labels.
  String label(Expression? value) {
    if (value == null) return '';
    if (value is SimpleStringLiteral) return value.value;
    final source = value.toSource();
    final key = RegExp(r'(?:l10n|context\.l10n)\.(\w+)').firstMatch(source)?[1];
    return key != null && translations[key] is String
        ? translations[key] as String
        : source;
  }

  /// Records the callback and enclosing conditional rather than assuming a
  /// preference write proves its effect is implemented on Windows.
  void record(AstNode node, String control, ArgumentList arguments) {
    final args = <String, Expression>{
      for (final arg in arguments.arguments.whereType<NamedExpression>())
        arg.name.label.name: arg.expression,
    };
    final title = label(args['title'] ?? args['label']);
    if (title.isEmpty) return;
    final gates = <String>[];
    for (
      AstNode? parent = node.parent;
      parent != null;
      parent = parent.parent
    ) {
      if (parent is IfElement) gates.add(parent.expression.toSource());
      if (parent is IfStatement) gates.add(parent.expression.toSource());
    }
    entries.add({
      'id': '$path:${lines.where((offset) => offset <= node.offset).length}',
      'file': path,
      'line': lines.where((offset) => offset <= node.offset).length,
      'control': control,
      'title': title,
      'value': (args['value'] ?? args['current'])?.toSource(),
      'handler':
          (args['onChanged'] ??
                  args['onTap'] ??
                  args['onPressed'] ??
                  args['onPicked'] ??
                  args['onChangeEnd'] ??
                  args['save'])
              ?.toSource(),
      'trailing': args['trailing']?.toSource(),
      'conditions': gates.reversed.toList(),
      'status': 'pending',
      'evidence': '',
    });
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final type = node.constructorName.type.toSource();
    if (const {
      'SettingsTile',
      '_SettingsEntry',
      'SwitchListTile',
      'CheckboxListTile',
      'RadioListTile',
      'DropdownButtonFormField',
      '_ToggleRow',
      '_PickerRow',
    }.contains(type)) {
      record(node, type, node.argumentList);
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final named = node.argumentList.arguments.whereType<NamedExpression>();
    final hasTitle = named.any((arg) => arg.name.label.name == 'title');
    final hasAction = named.any(
      (arg) => const {
        'onChanged',
        'onTap',
        'onPressed',
        'onPicked',
        'onChangeEnd',
        'save',
      }.contains(arg.name.label.name),
    );
    if ((hasTitle && hasAction) ||
        const {
          '_pickerRow',
          '_switchRow',
          '_toggle',
          '_toggleRow',
          '_sliderRow',
          '_tile',
          '_picker',
          '_choice',
          'SettingsTile',
          '_SettingsEntry',
          'SwitchListTile',
          'CheckboxListTile',
          'RadioListTile',
          '_ToggleRow',
          '_PickerRow',
          '_switchTile',
        }.contains(node.methodName.name) ||
        const {
          'SwitchListTile',
          'CheckboxListTile',
          'RadioListTile',
        }.contains(node.target?.toSource())) {
      record(node, node.methodName.name, node.argumentList);
    }
    // Several settings screens use positional helper rows for switches and
    // choices. Preserve their title/value/handler instead of counting only
    // constructors with named title arguments.
    if (const {
          '_switch',
          '_sizeRow',
          '_placementRow',
        }.contains(node.methodName.name) &&
        node.argumentList.arguments.length >= 2) {
      final args = node.argumentList.arguments;
      entries.add({
        'id': '$path:${lines.where((offset) => offset <= node.offset).length}',
        'file': path,
        'line': lines.where((offset) => offset <= node.offset).length,
        'control': node.methodName.name,
        'title': label(args[1]),
        'value': args.length > 3 ? args[3].toSource() : null,
        'handler': args.last.toSource(),
        'conditions': <String>[],
        'status': 'pending',
        'evidence': '',
      });
    }
    super.visitMethodInvocation(node);
  }
}

/// Produces a stable inventory spanning settings, source preferences and
/// in-reader settings; conditions keep unavailable mobile controls visible
/// to the audit rather than silently dropping them from the checklist.
void main() {
  final translations =
      jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;
  final entries = <Map<String, Object?>>[];
  for (final file in Directory(
    'lib',
  ).listSync(recursive: true).whereType<File>()) {
    final path = file.path.replaceAll('\\', '/');
    if (!path.endsWith('.dart') ||
        !(path.startsWith('lib/features/settings/') ||
            path.startsWith('lib/features/player/') ||
            path.startsWith('lib/features/reader/') ||
            path.contains('settings_sheet') ||
            path.contains('appearance_sheet') ||
            path.endsWith('source_settings_screen.dart') ||
            path.endsWith('source_prefs_screen.dart')))
      continue;
    final result = parseString(content: file.readAsStringSync(), path: path);
    final visitor = SettingsInventory(
      path,
      result.lineInfo.lineStarts,
      translations,
    );
    result.unit.accept(visitor);
    entries.addAll(visitor.entries);
  }
  final directory = Directory('merge-work/settings-audit')
    ..createSync(recursive: true);
  File(
    '${directory.path}/inventory.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(entries));
  String csv(Object? value) => '"${('$value').replaceAll('"', '""')}"';
  File('${directory.path}/inventory.csv').writeAsStringSync(
    [
      'id,title,control,conditions,status,evidence',
      for (final row in entries)
        [
          row['id'],
          row['title'],
          row['control'],
          (row['conditions'] as List).join(' && '),
          row['status'],
          row['evidence'],
        ].map(csv).join(','),
    ].join('\n'),
  );
  stdout.writeln('Settings controls inventoried: ${entries.length}');
}

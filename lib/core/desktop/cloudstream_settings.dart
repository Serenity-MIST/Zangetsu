import 'dart:async';
import 'package:cs3_engine/cs3_engine.dart';
import 'package:flutter/material.dart';
import '../ui/global_messenger.dart';

/// Opens a Flutter renderer for the plugin's declarative settings UI.
/// Android-only settings activities are outside this protocol.
Future<void> showCloudStreamSettings(Cs3Engine engine, String plugin) async {
  final context = rootNavigatorKey.currentContext;
  if (context == null) throw StateError('Settings are not ready.');
  await showDialog<void>(
    context: context,
    builder: (_) => _ExtensionSettings(engine: engine, plugin: plugin),
  );
}

/// Owns one plugin settings dialog and its engine UI session.
class _ExtensionSettings extends StatefulWidget {
  const _ExtensionSettings({required this.engine, required this.plugin});
  final Cs3Engine engine;
  final String plugin;
  @override
  State<_ExtensionSettings> createState() => _ExtensionSettingsState();
}

/// Applies engine UI updates and releases session/controller resources on close.
class _ExtensionSettingsState extends State<_ExtensionSettings> {
  StreamSubscription<Map<String, dynamic>>? _subscription;
  final _fields = <int, TextEditingController>{};
  List<dynamic> _windows = [];
  int? _session;
  String? _error;
  @override
  void initState() {
    super.initState();
    _subscription = widget.engine.events.listen((event) {
      if (!mounted || event['plugin'] != widget.plugin) return;
      if (event['event'] == 'ui') {
        setState(() {
          _session = (event['session'] as num).toInt();
          _windows = event['windows'] as List? ?? [];
        });
      } else if (event['event'] == 'uiClosed') {
        Navigator.of(context).pop();
      }
    });
    widget.engine
        .openSettings(widget.plugin)
        .then((session) {
          _session = session;
        })
        .catchError((Object error) {
          if (mounted) setState(() => _error = '$error');
        });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    if (_session != null)
      unawaited(widget.engine.closeUi(_session!, force: true));
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  /// Sends a control action to the active session and displays protocol failures.
  Future<void> _act(int id, String action, [Object? value]) async {
    if (_session == null) return;
    try {
      await widget.engine.uiAction(_session!, id, action, value);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  /// Recursively maps supported engine controls to Flutter widgets.
  Widget _node(Map node) {
    final id = (node['id'] as num?)?.toInt() ?? 0;
    final text = '${node['text'] ?? node['label'] ?? ''}';
    final enabled = node['enabled'] != false;
    final children = [
      for (final child in node['children'] as List? ?? const [])
        if (child is Map) _node(child),
    ];
    Widget result;
    switch (node['kind']) {
      case 'switch':
      case 'checkbox':
      case 'radio':
        result = SwitchListTile(
          title: Text(text),
          value: node['checked'] == true,
          onChanged: enabled ? (value) => _act(id, 'check', value) : null,
        );
      case 'field':
        final field = _fields.putIfAbsent(
          id,
          () => TextEditingController(text: text),
        );
        result = TextField(
          controller: field,
          enabled: enabled,
          obscureText: node['input'] == 'password',
          decoration: InputDecoration(
            labelText: '${node['hint'] ?? node['label'] ?? ''}',
            border: const OutlineInputBorder(),
          ),
          onChanged: (value) => _act(id, 'text', value),
          onSubmitted: (_) => _act(id, 'submit'),
        );
      case 'button':
      case 'iconButton':
        result = TextButton(
          onPressed: enabled ? () => _act(id, 'click') : null,
          child: Text(text.isEmpty ? '${node['icon'] ?? 'Open'}' : text),
        );
      case 'dropdown':
        final options = node['options'] as List? ?? [];
        final selected = (node['selected'] as num?)?.toInt();
        result = DropdownButton<int>(
          isExpanded: true,
          value: selected != null && selected >= 0 && selected < options.length
              ? selected
              : null,
          items: [
            for (var i = 0; i < options.length; i++)
              DropdownMenuItem(value: i, child: Text('${options[i]}')),
          ],
          onChanged: enabled ? (value) => _act(id, 'select', value) : null,
        );
      case 'slider':
        final max = (node['max'] as num?)?.toDouble() ?? 100;
        result = Slider(
          value: ((node['value'] as num?)?.toDouble() ?? 0).clamp(0, max),
          max: max > 0 ? max : 1,
          onChanged: enabled ? (value) => _act(id, 'slide', value) : null,
        );
      case 'progress':
        result = const LinearProgressIndicator();
      case 'page':
        result = const Text(
          'This extension uses an embedded Android settings page that is not supported yet.',
        );
      default:
        result = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (text.isNotEmpty)
              Text(
                text,
                style: node['heading'] == true
                    ? Theme.of(context).textTheme.titleMedium
                    : null,
              ),
            ...children,
          ],
        );
        if (node['tappable'] == true)
          result = InkWell(
            onTap: enabled ? () => _act(id, 'click') : null,
            child: result,
          );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      child: result,
    );
  }

  @override
  Widget build(BuildContext context) {
    final window = _windows.isEmpty ? null : _windows.last as Map;
    return Dialog(
      child: SizedBox(
        width: 580,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${window?['title'] ?? 'Extension settings'}',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: _error != null
                      ? Text(_error!)
                      : window?['root'] is Map
                      ? _node(window!['root'] as Map)
                      : const CircularProgressIndicator(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

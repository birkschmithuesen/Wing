import 'selection_viewport.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:flutter/material.dart';

import '../models/connection.dart';

/// Edits access-proxy headers while keeping saved secret values hidden.
class GatewayHeadersEditor extends StatefulWidget {
  final Set<String> savedNames;
  final bool enabled;
  final ValueChanged<GatewayHeaderEdit> onChanged;

  const GatewayHeadersEditor({
    super.key,
    required this.savedNames,
    this.enabled = true,
    required this.onChanged,
  });

  @override
  State<GatewayHeadersEditor> createState() => _GatewayHeadersEditorState();
}

class _HeaderRow {
  final String? savedName;
  final TextEditingController name;
  final TextEditingController value = TextEditingController();

  _HeaderRow([this.savedName])
    : name = TextEditingController(text: savedName ?? '');

  void dispose() {
    name.dispose();
    value.dispose();
  }
}

class _GatewayHeadersEditorState extends State<GatewayHeadersEditor> {
  late List<_HeaderRow> _rows = _savedRows();

  List<_HeaderRow> _savedRows() {
    final names = widget.savedNames.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names.map(_HeaderRow.new).toList();
  }

  @override
  void didUpdateWidget(covariant GatewayHeadersEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.savedNames.length == widget.savedNames.length &&
        oldWidget.savedNames.containsAll(widget.savedNames)) {
      return;
    }
    for (final row in _rows) {
      row.dispose();
    }
    _rows = _savedRows();
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  GatewayHeaderEdit _captureEdit() => GatewayHeaderEdit([
    for (final row in _rows)
      GatewayHeaderDraft(
        savedName: row.savedName,
        name: row.name.text,
        value: row.value.text,
      ),
  ]);

  void _publishEdit() {
    setState(() {});
    final edit = _captureEdit();
    if (edit.update != null) widget.onChanged(edit);
  }

  void _add() {
    if (!widget.enabled) {
      return;
    }
    setState(() => _rows.add(_HeaderRow()));
  }

  void _remove(int index) {
    if (!widget.enabled) {
      return;
    }
    final row = _rows.removeAt(index);
    row.dispose();
    _publishEdit();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('Access header credentials'),
      const SizedBox(height: 4),
      Text(
        'Use the names and values supplied by your administrator. Saved values stay hidden.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      for (final entry in _rows.indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              viewportSelection(
                TextFormField(
                  key: ObjectKey(entry.$2.name),
                  controller: entry.$2.name,
                  enabled: widget.enabled,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (_) => _captureEdit().nameError(entry.$1),
                  onChanged: (_) => _publishEdit(),
                  decoration: const InputDecoration(labelText: 'Header name'),
                  autocorrect: false,
                ),
              ),
              viewportSelection(
                TextFormField(
                  key: ObjectKey(entry.$2.value),
                  controller: entry.$2.value,
                  enabled: widget.enabled,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (_) => _captureEdit().valueError(entry.$1),
                  onChanged: (_) => _publishEdit(),
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(
                    labelText: 'Value',
                    hintText: entry.$2.savedName == null
                        ? null
                        : 'Keep saved value',
                  ),
                  autocorrect: false,
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: StudioButtonPress(
                  child: IconButton(
                    tooltip: 'Remove header',
                    onPressed: widget.enabled ? () => _remove(entry.$1) : null,
                    icon: const Icon(Icons.close),
                  ),
                ),
              ),
            ],
          ),
        ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: StudioButtonPress(
          child: IconButton.filled(
            tooltip: 'Add header',
            onPressed: widget.enabled ? _add : null,
            icon: const Icon(Icons.add),
          ),
        ),
      ),
    ],
  );
}

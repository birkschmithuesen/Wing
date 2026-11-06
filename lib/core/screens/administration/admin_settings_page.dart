import '../../widgets/selection_viewport.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import '../../widgets/studio_capacity_meter.dart';
import 'dart:async';
import '../../widgets/studio_select.dart';
import 'package:flutter/material.dart';
import '../../widgets/compact_switch.dart';
import '../../services/administration_repository.dart';
import '../../models/model_choice.dart';
import '../../models/settings_edit.dart';
import '../../services/settings_edit_session.dart';
import 'admin_widgets.dart';

class AdminSettingsPage extends StatefulWidget {
  final ProfileAdministration profile;
  final String title;
  final List<AdminField> fields;
  final String? explanation;
  final ConfiguredModel? expectedModel;
  final String? initialField;
  const AdminSettingsPage({
    super.key,
    required this.profile,
    required this.title,
    required this.fields,
    this.explanation,
    this.expectedModel,
    this.initialField,
  });
  @override
  State<AdminSettingsPage> createState() => _AdminSettingsPageState();
}

class _AdminSettingsPageState extends State<AdminSettingsPage> {
  late final _profile = widget.profile;
  final _noticeAnchor = GlobalKey();
  late final session = SettingsEditSession(
    _profile,
    fields: widget.fields,
    expectedModel: widget.expectedModel,
  );
  SettingsEditState get state => session.state;
  List<SettingsFieldState> get _fields => state.fields;
  final _inputs = <String, TextEditingController>{};
  String? get _error => state.error;
  bool get _saving => state.saving;
  bool get _loading => state.loading;
  bool _leave = false;
  final _anchors = <String, GlobalKey>{};
  bool _emphasizeField = false, _revealed = false;
  Timer? _emphasisTimer;
  int get _dirtyCount => state.dirtyCount;
  bool get _dirty => _dirtyCount > 0;

  void _sessionChanged() {
    if (!mounted ||
        _loading ||
        !state.hasObservation ||
        _revealed ||
        widget.initialField == null) {
      return;
    }
    _revealed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _revealField();
      }
    });
  }

  void _syncInputs() {
    for (final item in _fields) {
      final key = item.field.key;
      _anchors.putIfAbsent(key, GlobalKey.new);
      final input = _inputs.putIfAbsent(key, TextEditingController.new);
      if (input.text != item.text) {
        input.text = item.text;
      }
    }
  }

  Future<void> _revealField() async {
    await WidgetsBinding.instance.endOfFrame;
    final target = _anchors[widget.initialField]?.currentContext;
    if (!mounted || target == null || !target.mounted) {
      return;
    }
    final reduced = MediaQuery.disableAnimationsOf(context);
    setState(() => _emphasizeField = !reduced);
    await Scrollable.ensureVisible(
      target,
      alignment: .15,
      duration: reduced ? Duration.zero : const Duration(milliseconds: 200),
    );
    if (!mounted || reduced) {
      return;
    }
    _emphasisTimer?.cancel();
    _emphasisTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _emphasizeField = false);
      }
    });
  }

  void _resolve(SettingsFieldState item, {required bool useServer}) =>
      session.resolve(item.field.key, useServer: useServer);
  @override
  void initState() {
    super.initState();
    session.addListener(_sessionChanged);
  }

  @override
  void dispose() {
    session.removeListener(_sessionChanged);
    session.dispose();
    _emphasisTimer?.cancel();
    for (final input in _inputs.values) {
      input.dispose();
    }
    super.dispose();
  }

  Future<void> _load() => session.load();

  Future<void> _close() async {
    if (_saving) {
      return;
    }
    if (_dirty &&
        !await adminConfirm(
          context,
          'Discard edits?',
          'Your unsaved changes to ${_profile.name} will be discarded.',
          action: 'Discard',

          actionIcon: Icons.delete_outline,
          destructive: true,
        )) {
      return;
    }
    if (mounted) {
      setState(() => _leave = true);
      Navigator.pop(context);
    }
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    FocusScope.of(context).unfocus();
    final result = await session.save();
    if (!mounted) {
      return;
    }
    if (result == SettingsSaveOutcome.confirmed) {
      // Scope and the existing-chat caveat are already visible in the page.
      // Keep completion feedback compact above the fixed keyboard-safe footer.
      adminMessage(context, 'Settings saved.');
    } else if (_error != null) {
      revealAdminNotice(context, _noticeAnchor);
    }
  }

  Widget _field(SettingsFieldState item) {
    final field = item.field;
    final value = item.value;
    if (field.kind == AdminFieldKind.toggle) {
      if (value is! bool) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(field.label, style: Theme.of(context).textTheme.bodyLarge),
            const Text(
              'Current value unavailable. Choose explicitly to set it.',
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final enabled in [true, false])
                  StudioButtonPress(
                    child: OutlinedButton(
                      onPressed: _saving
                          ? null
                          : () => session.setValue(field.key, enabled),
                      child: Text(enabled ? 'Enable' : 'Disable'),
                    ),
                  ),
              ],
            ),
          ],
        );
      }
      return CompactSwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(field.label),
        subtitle: field.help.isEmpty ? null : Text(field.help),
        value: value == true,
        onChanged: _saving ? null : (v) => session.setValue(field.key, v),
      );
    }
    if (field.kind == AdminFieldKind.choice) {
      final choices = item.choices;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StudioSelect<String>(
            value: value is String ? value : null,
            label: field.label,
            options: [
              for (final v in choices)
                (value: v, label: v.isEmpty ? 'Server default' : v),
            ],
            onChanged: _saving ? null : (v) => session.setValue(field.key, v),
          ),
          if (item.choiceDescription != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                item.choiceDescription!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (field.help.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                field.help,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      );
    }
    final numeric = {
      AdminFieldKind.integer,
      AdminFieldKind.decimal,
    }.contains(field.kind);
    final largeText = MediaQuery.textScalerOf(context).scale(16) >= 24;
    final input = viewportSelection(
      TextFormField(
        key: ValueKey('setting:${field.key}'),
        controller: _inputs[field.key],
        enabled: !_saving,
        decoration: InputDecoration(
          labelText: largeText ? null : field.label,
          suffixText: field.percentage ? '%' : null,
          helperText: field.help.isEmpty ? null : field.help,
          helperMaxLines: 8,
        ),
        minLines: field.kind == AdminFieldKind.lines ? 3 : 1,
        maxLines: field.kind == AdminFieldKind.lines ? 6 : 1,
        keyboardType: numeric
            ? const TextInputType.numberWithOptions(decimal: true)
            : null,
        autovalidateMode: AutovalidateMode.always,
        validator: (_) => item.error,
        onChanged: (text) => session.setText(field.key, text),
      ),
    );
    if (!largeText) {
      return input;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(field.label, style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 8),
        Semantics(label: field.label, child: input),
      ],
    );
  }

  Widget _comparison(SettingsFieldState item) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Current server value: ${item.serverText}',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        Text(
          'Your value: ${item.text}',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        Wrap(
          spacing: 8,
          children: [
            StudioButtonPress(
              child: OutlinedButton(
                onPressed: _saving
                    ? null
                    : () => _resolve(item, useServer: false),
                child: const Text('Keep my value'),
              ),
            ),
            StudioButtonPress(
              child: TextButton(
                onPressed: _saving
                    ? null
                    : () => _resolve(item, useServer: true),
                child: const Text('Use server value'),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _compressionDiagram() => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Make room in long conversations',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        const Text(
          'Compression starts at the threshold and aims for the target below. Recent protected messages stay in context.',
        ),
        for (final (key, label) in [
          ('compression.threshold', 'Start at'),
          ('compression.target_ratio', 'Target'),
        ])
          if (_fields.where((item) => item.field.key == key).firstOrNull
              case final item? when item.value is num) ...[
            const SizedBox(height: 12),
            Text('$label ${item.text}%'),
            const SizedBox(height: 4),
            StudioCapacityMeter(
              fraction: (item.value as num).toDouble().clamp(0, 1),
              label: '$label ${item.text} percent of capacity',
            ),
          ],
        const SizedBox(height: 8),
        Text(
          'Configured limits · Not live usage',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      _syncInputs();
      return PopScope(
        canPop: _leave || (!_dirty && !_saving),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            _close();
          }
        },
        child: AdminPage(
          title: widget.title,
          scope: _profile.label,
          bottomNavigationBar: _loading || !state.hasObservation
              ? null
              : AdminEditorActions(
                  dirtyCount: _dirtyCount,
                  saving: _saving,
                  onClose: _close,
                  onSave: state.canSave ? _save : null,
                ),
          child: _loading && !state.hasObservation
              ? StudioPageLoading.waiting(label: 'Loading settings')
              : !state.hasObservation
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: AdminNotice.error(
                    _error ?? 'Settings unavailable',
                    retry: _load,
                  ),
                )
              : Column(
                  children: [
                    Expanded(
                      child: Form(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'Saved for this profile. Existing chats may keep their current settings.',
                              ),
                              const SizedBox(height: 16),
                              if (_fields.any((item) => item.field.percentage))
                                _compressionDiagram(),
                              if (widget.explanation != null)
                                AdminNotice(widget.explanation!),
                              if (_error != null)
                                AdminNotice.error(_error!, key: _noticeAnchor),
                              if (state.uncertain)
                                StudioButtonPress(
                                  child: TextButton(
                                    onPressed: _loading || _saving
                                        ? null
                                        : session.reviewUncertain,
                                    child: const Text('Refresh and review'),
                                  ),
                                ),
                              if (_fields.length < session.requestedCount)
                                const AdminNotice(
                                  'Some settings are not exposed by this server.',
                                ),
                              for (final item in _fields)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 20),
                                  child: Container(
                                    key: _anchors[item.field.key],
                                    decoration: BoxDecoration(
                                      color:
                                          _emphasizeField &&
                                              widget.initialField ==
                                                  item.field.key
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.primaryContainer
                                          : null,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        _field(item),
                                        if (item.conflicted) _comparison(item),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      );
    },
  );
}

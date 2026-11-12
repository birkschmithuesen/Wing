import 'package:flutter/foundation.dart';

import '../models/model_choice.dart';
import '../models/settings_edit.dart';
import 'administration_repository.dart';
import 'settings_edit_session.dart';

/// One subagent route draft. SettingsEditSession owns conflict detection,
/// dispatch lifetime and confirmed config readback; this owner owns route policy.
class DelegationModelSession extends ChangeNotifier {
  DelegationModelSession(this.profile) : _edit = _editor(profile) {
    _edit.addListener(_changed);
  }

  final ProfileAdministration profile;
  SettingsEditSession _edit;
  bool _disposed = false, _loadingCatalog = false;
  String? _catalogError;
  List<ModelChoice> _choices = const [];
  int _catalogGeneration = 0;
  static final _fields = [
    for (final key in ['model', 'provider', 'base_url', 'api_key', 'api_mode'])
      AdminField('delegation.$key', key, AdminFieldKind.text),
  ];
  static SettingsEditSession _editor(ProfileAdministration profile) =>
      SettingsEditSession(
        profile,
        fields: _fields,
        invariantKeys: _fields.map((field) => field.key),
      );

  SettingsEditState get edit => _edit.state;
  List<ModelChoice> get choices => _choices;
  bool get loading => edit.loading || _loadingCatalog;
  String? get error => edit.error ?? _catalogError;
  String _value(String key) =>
      edit.fields
              .where((field) => field.field.key == 'delegation.$key')
              .firstOrNull
              ?.value
          as String? ??
      '';
  bool get hasDirectEndpoint => _value('base_url').isNotEmpty;
  ModelSelection get selection =>
      _value('model').isEmpty && _value('provider').isEmpty
      ? const ModelSelection.special(ModelSpecialChoice.automatic)
      : ModelSelection.model(
          ModelChoice(provider: _value('provider'), model: _value('model')),
        );
  String get routeLabel => hasDirectEndpoint
      ? 'Direct endpoint · ${_value('model')}'
      : switch (selection.choice) {
          final choice? =>
            '${choice.provider.isEmpty ? 'Parent provider' : choice.provider} / ${choice.model}',
          null => 'Inherit parent model',
        };
  bool get canChoose =>
      !loading &&
      !edit.saving &&
      !edit.uncertain &&
      edit.hasObservation &&
      edit.fields.length == _fields.length;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    if (_disposed || edit.saving) return;
    await Future.wait([_edit.load(), catalog()]);
  }

  Future<List<ModelChoice>> catalog({bool refresh = false}) async {
    if (_disposed) return const [];
    final generation = ++_catalogGeneration;
    _loadingCatalog = true;
    _catalogError = null;
    _changed();
    try {
      final result = await profile.modelCatalog.load(
        explicitOnly: true,
        refresh: refresh,
      );
      if (!_disposed && generation == _catalogGeneration) {
        _choices = List.unmodifiable(result.choices);
      }
    } catch (failure) {
      if (!_disposed && generation == _catalogGeneration) {
        _catalogError = administrationError(failure);
      }
    } finally {
      if (!_disposed && generation == _catalogGeneration) {
        _loadingCatalog = false;
        _changed();
      }
    }
    return _choices;
  }

  void choose(ModelSelection selection) {
    if (!canChoose) return;
    final choice = selection.choice;
    if (choice != null &&
        !_choices.any(
          (row) => row.provider == choice.provider && row.model == choice.model,
        )) {
      return;
    }
    if (choice == null && selection.special != ModelSpecialChoice.automatic) {
      return;
    }
    // A catalog/parent route leaves the direct endpoint as one intent. Never
    // leave a stale URL, key or wire protocol attached to the selected provider.
    for (final entry in {
      'model': choice?.model ?? '',
      'provider': choice?.provider ?? '',
      'base_url': '',
      'api_key': '',
      'api_mode': '',
    }.entries) {
      _edit.setText('delegation.${entry.key}', entry.value);
    }
  }

  Future<SettingsSaveOutcome> save() => _edit.save();
  Future<void> reviewUncertain() => _edit.reviewUncertain();
  void resolve({required bool useServer}) {
    if (useServer) {
      _edit.removeListener(_changed);
      _edit.dispose();
      _edit = _editor(profile)..addListener(_changed);
      _changed();
      return;
    }
    for (final field in edit.fields.where((field) => field.conflicted)) {
      _edit.resolve(field.field.key, useServer: false);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _catalogGeneration++;
    _edit.removeListener(_changed);
    _edit.dispose();
    super.dispose();
  }
}

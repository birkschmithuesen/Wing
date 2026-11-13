import 'dart:async';
import 'package:flutter/foundation.dart';

import '../models/model_choice.dart';
import '../models/settings_edit.dart';
import 'administration_repository.dart';

enum SettingsSaveOutcome {
  confirmed,
  invalid,
  blocked,
  failed,
  uncertain,
  retired,
}

class SettingsFieldState {
  SettingsFieldState(
    this.field,
    this.value,
    this.text,
    this.error,
    this.conflicted,
    this.serverText,
  ) : choices = List.unmodifiable({
        ...field.choices,
        if (value is String) value,
      });
  final AdminField field;
  final Object? value;
  final String text, serverText;
  final String? error;
  final bool conflicted;
  String? get choiceDescription => field.describeChoice(value);
  final List<String> choices;
}

class SettingsEditState {
  SettingsEditState({
    required Iterable<SettingsFieldState> fields,
    required this.loading,
    required this.saving,
    required this.hasObservation,
    required this.dirtyCount,
    required this.error,
    required this.uncertain,
    required this.canSave,
  }) : fields = List.unmodifiable(fields);
  final List<SettingsFieldState> fields;
  final bool loading, saving, hasObservation, uncertain, canSave;
  final int dirtyCount;
  final String? error;
}

/// One captured profile's edit lifetime. Opening baseline is local intent, not
/// a shared runtime cache. After dispatch, remote work finishes with its own
/// retained connection lease; route disposal only retires publication authority.
class SettingsEditSession extends ChangeNotifier {
  SettingsEditSession(
    this.profile, {
    required Iterable<AdminField> fields,
    this.expectedModel,
    Iterable<String> invariantKeys = const [],
  }) : _requested = List.unmodifiable(fields),
       _invariantKeys = Set.unmodifiable(invariantKeys) {
    if (_requested.map((field) => field.key).toSet().length !=
            _requested.length ||
        _requested.any((field) => field.modelCapability) &&
            expectedModel == null ||
        _invariantKeys.any(
          (key) => !_requested.any((field) => field.key == key),
        )) {
      throw ArgumentError(
        'Settings fields require unique keys and captured model capability ownership',
      );
    }
    profile.server.retain();
    unawaited(load());
  }
  final ProfileAdministration profile;
  final ConfiguredModel? expectedModel;
  final List<AdminField> _requested;
  final Set<String> _invariantKeys;
  List<AdminField> _fields = const [];
  Map<String, Object?>? _baseline;
  final _values = <String, Object?>{};
  final _texts = <String, String>{};
  final _inputErrors = <String, String>{};
  final _conflicts = <String, Object?>{};
  bool _showValidation = false;
  bool _disposed = false, _loading = true, _saving = false, _uncertain = false;
  int _generation = 0;
  String? _error;
  int get requestedCount => _requested.length;
  String get profileName => profile.name;
  bool _owns(int generation) => !_disposed && generation == _generation;
  void _emit() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  bool _changed(AdminField field) =>
      _baseline != null &&
      (!sameSetting(_values[field.key], _baseline![field.key]) ||
          _inputErrors.containsKey(field.key) &&
              _texts[field.key] != field.format(_baseline![field.key]));
  SettingsEditState get state {
    final dirty = _fields.where(_changed).length;
    return SettingsEditState(
      fields: [
        for (final field in _fields)
          SettingsFieldState(
            field,
            _values[field.key],
            _texts[field.key] ?? field.format(_values[field.key]),
            _showValidation ? _inputErrors[field.key] : null,
            _conflicts.containsKey(field.key),
            field.format(_conflicts[field.key]),
          ),
      ],
      loading: _loading,
      saving: _saving,
      hasObservation: _baseline != null,
      dirtyCount: dirty,
      error: _error,
      uncertain: _uncertain,
      canSave:
          !_disposed &&
          !_saving &&
          !_loading &&
          !_uncertain &&
          dirty > 0 &&
          _conflicts.isEmpty,
    );
  }

  Future<void> load() async {
    if (_disposed || _saving || _uncertain) {
      return;
    }
    final generation = ++_generation;
    _loading = true;
    _error = null;
    _emit();
    try {
      final results = await Future.wait([
        profile.config(),
        profile.read('config/schema'),
      ]);
      if (!_owns(generation)) {
        return;
      }
      final schema = results[1]['fields'];
      if (schema is! Map || schema.keys.any((key) => key is! String)) {
        throw const FormatException('Missing settings schema');
      }
      final config = results[0];
      final available = _requested
          .where(
            (field) =>
                schema.containsKey(field.key) ||
                field.modelCapability ||
                setting(config, field.key) != null,
          )
          .toList();
      final opening = settingsProjection(
        config,
        available.map((field) => field.key),
      );
      // A refresh never silently replaces an already opened draft/baseline.
      if (_baseline == null) {
        _fields = List.unmodifiable(available);
        _baseline = opening;
        _values.addAll(opening);
        for (final field in _fields) {
          _texts[field.key] = field.format(opening[field.key]);
        }
      }
    } catch (error) {
      if (_owns(generation)) {
        _error = _failure(error);
      }
    } finally {
      if (_owns(generation)) {
        _loading = false;
        _emit();
      }
    }
  }

  AdminField? _field(String key) =>
      _fields.where((field) => field.key == key).firstOrNull;
  void setText(String key, String text) {
    if (_disposed || _saving) {
      return;
    }
    final field = _field(key);
    if (field == null ||
        field.kind == AdminFieldKind.toggle ||
        field.kind == AdminFieldKind.choice) {
      return;
    }
    _texts[key] = text;
    final value = text == field.format(_baseline![key])
        ? _baseline![key]
        : field.parse(text);
    _values[key] = immutableSetting(value);
    final problem = sameSetting(value, _baseline![key])
        ? null
        : field.validate(value);
    if (problem == null) {
      _inputErrors.remove(key);
    } else {
      _inputErrors[key] = problem;
    }
    if (!_uncertain) {
      _error = null;
    }
    _emit();
  }

  void setValue(String key, Object? value) {
    if (_disposed || _saving) {
      return;
    }
    final field = _field(key);
    if (field == null ||
        !{AdminFieldKind.toggle, AdminFieldKind.choice}.contains(field.kind) ||
        field.kind == AdminFieldKind.toggle && value is! bool ||
        field.kind == AdminFieldKind.choice &&
            (value is! String ||
                !{
                  ...field.choices,
                  if (_baseline![key] is String) _baseline![key] as String,
                }.contains(value))) {
      return;
    }
    _values[key] = immutableSetting(value);
    _texts[key] = field.format(value);
    _inputErrors.remove(key);
    if (!_uncertain) {
      _error = null;
    }
    _emit();
  }

  void resolve(String key, {required bool useServer}) {
    if (_disposed || _saving || !_conflicts.containsKey(key)) {
      return;
    }
    final field = _field(key)!;
    final latest = _conflicts.remove(key);
    _baseline = Map.unmodifiable({..._baseline!, key: latest});
    if (useServer) {
      _values[key] = latest;
      _texts[key] = field.format(latest);
      _inputErrors.remove(key);
    }
    if (_conflicts.isEmpty) {
      _error = null;
    }
    _emit();
  }

  Future<SettingsSaveOutcome> save() async {
    if (_disposed) {
      return SettingsSaveOutcome.retired;
    }
    if (!state.canSave) {
      return SettingsSaveOutcome.blocked;
    }
    for (final field in _fields.where(_changed)) {
      final problem =
          _inputErrors[field.key] ?? field.validate(_values[field.key]);
      if (problem != null) {
        _inputErrors[field.key] = problem;
      }
    }
    if (_inputErrors.isNotEmpty) {
      _showValidation = true;
      _emit();
      return SettingsSaveOutcome.invalid;
    }
    final intent = SettingsEditIntent(
      baseline: _baseline!,
      invariants: _invariantKeys,
      desired: {
        for (final field in _fields.where(_changed))
          field.key: _values[field.key],
      },
    );
    final generation = ++_generation;
    var dispatched = false;
    var dispatchActive = true;
    _saving = true;
    _error = null;
    _emit();
    profile.server.retain();
    try {
      final saved = await profile.saveSettings(
        intent,
        canDispatch: () => dispatchActive && _owns(generation),
        onDispatched: () => dispatched = true,
        expectedModel: expectedModel,
      );
      if (!_owns(generation)) {
        return SettingsSaveOutcome.retired;
      }
      _baseline = settingsProjection(saved, _fields.map((field) => field.key));
      _values
        ..clear()
        ..addAll(_baseline!);
      for (final field in _fields) {
        _texts[field.key] = field.format(_values[field.key]);
      }
      return SettingsSaveOutcome.confirmed;
    } catch (error) {
      if (!_owns(generation)) {
        return SettingsSaveOutcome.retired;
      }
      if (error is SettingsEditConflict) {
        _conflicts.addAll(error.values);
      }
      _uncertain = dispatched && error is! SettingsWriteRejected;
      _error = _uncertain
          ? 'Save not confirmed. Your edits are kept. Refresh and review before saving again.'
          : _failure(error);
      return _uncertain
          ? SettingsSaveOutcome.uncertain
          : SettingsSaveOutcome.failed;
    } finally {
      dispatchActive = false;
      profile.server.release();
      if (_owns(generation)) {
        _saving = false;
        _emit();
      }
    }
  }

  /// Explicit review reads fresh values but keeps the user's draft. Differences
  /// become per-field choices; it never repeats the uncertain HTTP request.
  Future<void> reviewUncertain() async {
    if (_disposed || _saving || !_uncertain) {
      return;
    }
    final generation = ++_generation;
    _loading = true;
    _emit();
    try {
      final current = await profile.config();
      if (!_owns(generation)) {
        return;
      }
      _conflicts.clear();
      for (final field in _fields) {
        final value = immutableSetting(setting(current, field.key));
        final changed = _changed(field);
        if (changed && !sameSetting(value, _values[field.key])) {
          _conflicts[field.key] = value;
        } else {
          _baseline = Map.unmodifiable({..._baseline!, field.key: value});
          if (!changed) {
            _values[field.key] = value;
            _texts[field.key] = field.format(value);
          }
        }
      }
      _uncertain = false;
      _error = _conflicts.isEmpty
          ? null
          : 'Review the current server values before saving your choices.';
    } catch (error) {
      if (_owns(generation)) {
        _error = _failure(error);
      }
    } finally {
      if (_owns(generation)) {
        _loading = false;
        _emit();
      }
    }
  }

  static String _failure(Object error) => error is AdministrationFailure
      ? error.message
      : 'Could not load settings. Your edits are kept. Refresh to try again.';
  @override
  void dispose() {
    _disposed = true;
    _generation++;
    profile.server.release();
    super.dispose();
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/model_choice.dart';
import '../models/scheduled_task.dart';
import '../models/scheduled_task_edit.dart';
import 'scheduled_tasks_controller.dart';
import 'scheduled_tasks_repository.dart';

enum TaskEditText { name, prompt }

enum TaskCatchUp { inherit, runOnce, skip }

enum TaskEditCatalog { delivery, rooms, models, blueprints }

enum TaskEditOutcome {
  confirmed,
  invalid,
  blocked,
  failed,
  uncertain,
  disposed,
}

enum TaskReviewOutcome { applied, cancelled, incomplete, retired }

/// Only the issuing session can consume this immutable, captured review. The
/// view stages decisions over passive fields, never a baseline or update map.
class ScheduledTaskConflictReview {
  ScheduledTaskConflictReview._(this._review, this._generation, this._revision);
  final TaskEditReview _review;
  final int _generation, _revision;
  List<TaskConflictObservation> get fields => _review.fields;
}

/// Passive picker bounds; opening/cancelling a picker never edits the schedule.
class TaskDatePickerInput {
  const TaskDatePickerInput({
    required this.firstDate,
    required this.lastDate,
    required this.initialDate,
    required this.initialTime,
  });
  final DateTime firstDate, lastDate, initialDate, initialTime;
}

class TaskDestinationChoice {
  const TaskDestinationChoice({
    required this.id,
    required this.label,
    required this.description,
    required this.selected,
    required this.enabled,
    required this.discovered,
  });
  final String id, label, description;
  final bool selected, enabled, discovered;
}

/// Every editable/domain fact is captured here. Views retain text/focus and
/// transient picker state only; this immutable snapshot never aliases inputs.
class ScheduledTaskEditState {
  ScheduledTaskEditState({
    required this.name,
    required this.prompt,
    required this.schedule,
    required this.selection,
    required this.deliveryChoices,
    required this.models,
    required this.templateCatalog,
    required this.template,
    required this.templateValues,
    required this.dirty,
    required this.saving,
    required this.reviewing,
    required this.canReview,
    required this.canSubmit,
    required this.error,
    required this.conflicts,
    required this.targetError,
    required this.roomError,
    required this.modelError,
    required this.templateError,
    required this.editing,
    required this.scriptOnly,
    required this.customEndpoint,
    required this.timezone,
    required this.graceMinutes,
    required this.catchUp,
  });
  final String name, prompt, timezone, graceMinutes;
  final TaskCatchUp catchUp;
  final TaskScheduleDraft schedule;
  final ModelSelection selection;
  final List<TaskDestinationChoice> deliveryChoices;
  final List<ModelChoice>? models;
  final List<TaskTemplate>? templateCatalog;
  final TaskTemplate? template;
  final Map<String, String> templateValues;
  final bool dirty,
      saving,
      reviewing,
      canReview,
      canSubmit,
      editing,
      scriptOnly,
      customEndpoint;
  final String? error, targetError, roomError, modelError, templateError;
  final List<String> conflicts;
}

/// One route's form/catalog lifetime. It submits through the existing retained
/// action owner, which alone owns dispatch, task cache and durable uncertainty.
class ScheduledTaskEditSession extends ChangeNotifier {
  ScheduledTaskEditSession(
    this.controller, {
    ScheduledTask? original,
    DateTime Function()? now,
  }) : _baseline = original,
       _now = now ?? DateTime.now,
       _name = original?.name ?? '',
       _prompt = original?.prompt ?? '',
       _schedule = TaskScheduleDraft.open(original),
       _selected = {
         ...original?.destinations ?? ['local'],
       },
       _selection = original == null || original.text('model').isEmpty
           ? const ModelSelection.special(ModelSpecialChoice.profileDefault)
           : ModelSelection.model(
               ModelChoice(
                 provider: original.text('provider'),
                 model: original.text('model'),
               ),
             ) {
    if (original != null &&
        original.profileName != controller.repository.profile.name) {
      throw const TaskPreflightFailure('The task belongs to another profile.');
    }
    controller.addListener(_emit);
    unawaited(load(TaskEditCatalog.delivery));
    unawaited(load(TaskEditCatalog.rooms));
    unawaited(load(TaskEditCatalog.models));
    if (original == null) unawaited(load(TaskEditCatalog.blueprints));
  }
  final ScheduledTasksController controller;
  ScheduledTask? _baseline;
  final DateTime Function() _now;
  String _name, _prompt;
  TaskScheduleDraft _schedule;
  final _policyEdits = <String, dynamic>{};
  String? _graceInput;
  Object? _policy(String key) =>
      _policyEdits.containsKey(key) ? _policyEdits[key] : _baseline?.data[key];
  Set<String> _selected;
  ModelSelection _selection;
  List<TaskDeliveryTarget>? _targets;
  List<TaskDeliveryTarget>? _rooms;
  Iterable<TaskDeliveryTarget> get _allTargets => [...?_targets, ...?_rooms];
  List<ModelChoice>? _models;
  List<TaskTemplate>? _templates;
  TaskTemplate? _template;
  Map<String, String> _templateValues = const {};
  final _loads = <TaskEditCatalog, int>{};
  final _pendingLoads = <TaskEditCatalog>{};
  final _loadErrors = <TaskEditCatalog, String>{};
  bool _disposed = false, _dirty = false, _saving = false, _reviewing = false;
  int _saveGeneration = 0;
  int _reviewGeneration = 0, _revision = 0;
  ScheduledTaskConflictReview? _activeReview;
  String? _error;
  List<String> _conflicts = const [];
  String get id => _baseline?.id ?? '__create__';
  String get scopeLabel => controller.repository.profile.label;
  String get profileName => controller.repository.profile.name;
  TaskDatePickerInput get datePickerInput {
    final now = _now().toLocal();
    final first = DateTime(now.year, now.month, now.day);
    final last = DateTime(now.year + 10);
    final chosen = _schedule.once ?? now;
    final day = DateTime(chosen.year, chosen.month, chosen.day);
    final initial = day.isBefore(first)
        ? first
        : day.isAfter(last)
        ? last
        : day;
    return TaskDatePickerInput(
      firstDate: first,
      lastDate: last,
      initialDate: initial,
      initialTime: chosen,
    );
  }

  void setOnceDateTime(
    DateTime date, {
    required int hour,
    required int minute,
  }) {
    setSchedule(
      _schedule.copyWith(
        once: DateTime(date.year, date.month, date.day, hour, minute),
      ),
    );
  }

  ScheduledTaskEditState get state => ScheduledTaskEditState(
    timezone: _policy('timezone')?.toString() ?? '',
    graceMinutes: _graceInput ?? _policy('grace_minutes')?.toString() ?? '',
    catchUp: switch (_policy('catch_up')) {
      true => TaskCatchUp.runOnce,
      false => TaskCatchUp.skip,
      _ => TaskCatchUp.inherit,
    },
    name: _name,
    prompt: _prompt,
    schedule: _schedule,
    selection: _selection,
    deliveryChoices: List.unmodifiable([
      for (final target in _allTargets)
        TaskDestinationChoice(
          id: target.id,
          label: target.label,
          description: target.isRoom
              ? 'Group chat · Output @mentions wake those bots; no mention posts information only.'
              : target.id == 'local'
              ? 'Saved by Hermes; not downloaded to this phone.'
              : target.configured
              ? 'Connected server destination'
              : 'Set a home channel on the server first.',
          selected: _selected.contains(target.id),
          discovered: true,
          enabled:
              !_saving &&
              (target.configured || _selected.contains(target.id)) &&
              (!_selected.contains(target.id) || _selected.length > 1),
        ),
      for (final id in _selected.where(
        (id) => !_allTargets.any((target) => target.id == id),
      ))
        TaskDestinationChoice(
          id: id,
          label: id == 'local' ? 'Save on server' : id,
          description: _targets == null
              ? 'Current selection'
              : 'Current selection unavailable in discovery',
          selected: true,
          discovered: false,
          enabled: !_saving && _targets != null && _selected.length > 1,
        ),
    ]),
    models: _models,
    templateCatalog: _templates,
    template: _template,
    templateValues: _templateValues,
    dirty: _dirty,
    saving: _saving,
    reviewing: _reviewing,
    canReview:
        !_disposed &&
        !_saving &&
        !_reviewing &&
        _baseline != null &&
        _conflicts.isNotEmpty &&
        !controller.blocked(id),
    canSubmit:
        !_disposed &&
        !_saving &&
        !_reviewing &&
        !controller.blocked(id) &&
        _template?.supported != false,
    error: _error,
    conflicts: _conflicts,
    targetError: _loadErrors[TaskEditCatalog.delivery],
    roomError: _loadErrors[TaskEditCatalog.rooms],
    modelError: _loadErrors[TaskEditCatalog.models],
    templateError: _loadErrors[TaskEditCatalog.blueprints],
    editing: _baseline != null,
    scriptOnly: _baseline?.scriptOnly == true,
    customEndpoint: _baseline?.text('base_url').isNotEmpty == true,
  );
  bool get loadingRooms => _pendingLoads.contains(TaskEditCatalog.rooms);
  bool get loadingDestinations =>
      _pendingLoads.contains(TaskEditCatalog.delivery);
  bool loadingCatalog(TaskEditCatalog catalog) =>
      _pendingLoads.contains(catalog);

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void _changed() {
    _revision++;
    _reviewGeneration++;
    _activeReview = null;
    _reviewing = false;
    _dirty = true;
    _error = null;
    _conflicts = const [];
    _emit();
  }

  void setText(TaskEditText field, String value) {
    if (_disposed || _saving) return;
    switch (field) {
      case TaskEditText.name:
        _name = value;
      case TaskEditText.prompt:
        if (_baseline?.scriptOnly == true) return;
        _prompt = value;
    }
    _changed();
  }

  void setSchedule(TaskScheduleDraft value) {
    if (_disposed || _saving) return;
    _schedule = value;
    _changed();
  }

  void setTimezone(String value) {
    if (_disposed || _saving) return;
    _policyEdits['timezone'] = value.trim().isEmpty ? null : value.trim();
    _changed();
  }

  void setGrace(String value) {
    if (_disposed || _saving) return;
    _graceInput = value;
    _policyEdits['grace_minutes'] = value.trim().isEmpty
        ? null
        : int.tryParse(value.trim());
    _changed();
  }

  void setCatchUp(TaskCatchUp value) {
    if (_disposed || _saving) return;
    _policyEdits['catch_up'] = switch (value) {
      TaskCatchUp.inherit => null,
      TaskCatchUp.runOnce => true,
      TaskCatchUp.skip => false,
    };
    _changed();
  }

  String? _validatePolicy() {
    if (_graceInput != null &&
        _graceInput!.trim().isNotEmpty &&
        (int.tryParse(_graceInput!.trim()) == null ||
            int.parse(_graceInput!.trim()) < 0 ||
            int.parse(_graceInput!.trim()) > 1440)) {
      return 'Use 0–1440 whole minutes for the late-run window, or leave it empty.';
    }
    final expression = _schedule.expression.trim();
    final cron = expression.split(RegExp(r'\s+')).length == 5;
    if ((_policyEdits.containsKey('grace_minutes') || _schedule.changed) &&
        _policy('grace_minutes') != null &&
        !cron) {
      return 'A late-run window applies only to cron schedules. Clear it before choosing an interval or one-time run.';
    }
    return null;
  }

  void setDestination(String id, bool selected) {
    if (_disposed || _saving) return;
    final choice = state.deliveryChoices
        .where((choice) => choice.id == id)
        .firstOrNull;
    if (choice == null || !choice.enabled || choice.selected == selected) {
      return;
    }
    _selected = {..._selected};
    selected ? _selected.add(id) : _selected.remove(id);
    _changed();
  }

  void setModel(ModelSelection value) {
    if (_disposed ||
        _saving ||
        _baseline?.scriptOnly == true ||
        state.customEndpoint) {
      return;
    }
    if (value.special != null &&
        value.special != ModelSpecialChoice.profileDefault) {
      return;
    }
    _selection = value;
    _changed();
  }

  void setTemplate(String key) {
    if (_disposed || _saving || _baseline != null) return;
    if (key.isEmpty) {
      _template = null;
      _templateValues = const {};
    } else {
      final selected = _templates
          ?.where((template) => template.key == key)
          .firstOrNull;
      if (selected == null || !selected.supported) return;
      _template = selected;
      _templateValues = selected.initialValues;
    }
    _changed();
  }

  void setTemplateValue(String name, String value) {
    if (_disposed ||
        _saving ||
        _template?.inputFields.any((field) => field.name == name) != true) {
      return;
    }
    _templateValues = Map.unmodifiable({..._templateValues, name: value});
    _changed();
  }

  String? validatePrompt(String? value) =>
      (value?.trim().isEmpty ?? true) && _baseline?.hasServerExecution != true
      ? 'Add instructions for your agent.'
      : null;
  Future<List<ModelChoice>> refreshModels() async {
    await load(TaskEditCatalog.models, refresh: true);
    return _models ?? const [];
  }

  Future<void> load(TaskEditCatalog catalog, {bool refresh = false}) async {
    if (_disposed) return;
    final generation = (_loads[catalog] ?? 0) + 1;
    _loads[catalog] = generation;
    _pendingLoads.add(catalog);
    _emit();
    try {
      switch (catalog) {
        case TaskEditCatalog.delivery:
          final result = await controller.repository.destinations();
          if (_disposed || _loads[catalog] != generation) return;
          _targets = List.unmodifiable(result);
        case TaskEditCatalog.rooms:
          final result = await controller.repository.roomDestinations();
          if (_disposed || _loads[catalog] != generation) return;
          _rooms = List.unmodifiable(result);
        case TaskEditCatalog.models:
          final result = (await controller.repository.profile.modelCatalog.load(
            explicitOnly: true,
            refresh: refresh,
          )).choices;
          if (_disposed || _loads[catalog] != generation) return;
          _models = List.unmodifiable(result);
        case TaskEditCatalog.blueprints:
          final result = await controller.repository.templates();
          if (_disposed || _loads[catalog] != generation) return;
          _templates = List.unmodifiable(result);
      }
      _loadErrors.remove(catalog);
    } catch (error) {
      if (_disposed || _loads[catalog] != generation) return;
      _loadErrors[catalog] = taskFailure(error);
    } finally {
      if (!_disposed && _loads[catalog] == generation) {
        _pendingLoads.remove(catalog);
        _emit();
      }
    }
  }

  Map<String, dynamic> _values() => {
    'name': _name.trim(),
    'schedule': _schedule.expression,
    'deliver': _selected.join(','),
    ..._policyEdits,
    if (_baseline?.scriptOnly != true) 'prompt': _prompt.trim(),
    if (_baseline?.scriptOnly != true && !state.customEndpoint) ...{
      'model': _selection.choice?.model,
      'provider': _selection.choice?.provider,
    },
  };

  bool _ownsReview(int generation, int revision) =>
      !_disposed &&
      !_saving &&
      generation == _reviewGeneration &&
      revision == _revision;

  Future<ScheduledTaskConflictReview?> reviewConflicts() async {
    final baseline = _baseline;
    if (!state.canReview || baseline == null) return null;
    final intent = TaskEditIntent(baseline: baseline, values: _values());
    final generation = ++_reviewGeneration;
    final revision = _revision;
    _activeReview = null;
    _reviewing = true;
    _emit();
    try {
      if (!_ownsReview(generation, revision)) return null;
      // Detail lookup can follow stock's actual-owner redirect. A review must
      // instead establish membership in this captured profile's fresh list.
      final tasks = await controller.repository.list();
      if (!_ownsReview(generation, revision)) return null;
      final current = tasks.where((task) => task.id == baseline.id).firstOrNull;
      if (current == null) {
        throw const TaskPreflightFailure(
          'This task is no longer available in this profile. Your edits are kept.',
        );
      }
      final review = ScheduledTaskConflictReview._(
        intent.review(current),
        generation,
        revision,
      );
      _activeReview = review;
      return review;
    } catch (failure) {
      if (_ownsReview(generation, revision)) _error = taskFailure(failure);
      return null;
    } finally {
      if (_ownsReview(generation, revision)) {
        _reviewing = false;
        _emit();
      }
    }
  }

  bool _ownsTicket(ScheduledTaskConflictReview review) =>
      identical(review, _activeReview) &&
      _ownsReview(review._generation, review._revision);

  TaskReviewOutcome cancelReview(ScheduledTaskConflictReview review) {
    if (!_ownsTicket(review)) return TaskReviewOutcome.retired;
    _activeReview = null;
    _reviewGeneration++;
    return TaskReviewOutcome.cancelled;
  }

  TaskReviewOutcome applyReview(
    ScheduledTaskConflictReview review,
    Map<TaskConflictField, TaskConflictDecision> decisions,
  ) {
    if (!_ownsTicket(review) || controller.blocked(id)) {
      return TaskReviewOutcome.retired;
    }
    final TaskEditIntent reconciled;
    try {
      reconciled = review._review.reconcile(decisions);
    } on ArgumentError {
      return TaskReviewOutcome.incomplete;
    }
    final current = reconciled.baseline;
    final retained = reconciled.values;
    if (!retained.containsKey('name')) _name = current.name;
    if (!retained.containsKey('prompt')) _prompt = current.prompt;
    if (!retained.containsKey('schedule')) {
      _schedule = TaskScheduleDraft.open(current);
    }
    if (!retained.containsKey('deliver')) _selected = {...current.destinations};
    if (!retained.containsKey('model') && !retained.containsKey('provider')) {
      _selection = current.text('model').isEmpty
          ? const ModelSelection.special(ModelSpecialChoice.profileDefault)
          : ModelSelection.model(
              ModelChoice(
                provider: current.text('provider'),
                model: current.text('model'),
              ),
            );
    }
    for (final key in ['timezone', 'grace_minutes', 'catch_up']) {
      if (!retained.containsKey(key)) {
        _policyEdits.remove(key);
        if (key == 'grace_minutes') _graceInput = null;
      }
    }
    _baseline = current;
    _dirty = retained.isNotEmpty;
    _error = null;
    _conflicts = const [];
    _revision++;
    _reviewGeneration++;
    _activeReview = null;
    _emit();
    return TaskReviewOutcome.applied;
  }

  Future<TaskEditOutcome> save() async {
    if (_disposed) return TaskEditOutcome.disposed;
    if (!state.canSubmit) return TaskEditOutcome.blocked;
    String? problem;
    if (_template == null) {
      problem =
          validatePrompt(_prompt) ??
          _schedule.validate(_now()) ??
          _validatePolicy();
    } else {
      for (final field in _template!.inputFields) {
        problem = field.validate(_templateValues[field.name] ?? '');
        if (problem != null) break;
      }
    }
    problem ??= _selected.isEmpty
        ? 'Choose at least one result destination.'
        : null;
    if (problem != null) {
      _error = problem;
      _emit();
      return TaskEditOutcome.invalid;
    }
    final generation = ++_saveGeneration;
    _reviewGeneration++;
    _activeReview = null;
    _saving = true;
    _error = null;
    _emit();
    try {
      final ScheduledTask? result;
      if (_template != null) {
        result = await controller.instantiate(
          _template!,
          _template!.submission(_templateValues, _selected.join(',')),
        );
      } else {
        result = await controller.save(_values(), original: _baseline);
      }
      if (_disposed || generation != _saveGeneration) {
        return TaskEditOutcome.disposed;
      }
      if (result == null) return TaskEditOutcome.blocked;
      _dirty = false;
      return TaskEditOutcome.confirmed;
    } catch (error) {
      if (_disposed || generation != _saveGeneration) {
        return TaskEditOutcome.disposed;
      }
      _error = controller.error ?? taskFailure(error);
      if (error is TaskEditConflict) _conflicts = error.fields;
      return controller.uncertain.containsKey(id)
          ? TaskEditOutcome.uncertain
          : TaskEditOutcome.failed;
    } finally {
      if (!_disposed && generation == _saveGeneration) {
        _saving = false;
        _emit();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _saveGeneration++;
    _reviewGeneration++;
    _activeReview = null;
    _loads.clear();
    controller.removeListener(_emit);
    super.dispose();
  }
}

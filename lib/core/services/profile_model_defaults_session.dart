import 'package:wing/core/models/model_catalog.dart';
import 'package:flutter/foundation.dart';

import '../models/model_choice.dart';
import '../models/profile_model_defaults.dart';
import 'administration_repository.dart';
import 'workspace_connection_failure.dart';

enum HelperChangeState { pending, conflict, uncertain }

enum HelperConfirmationKind { reset, expensive, retry }

enum HelperSaveOutcome { saved, cancelled, retired, failed }

class HelperChangeConfirmation {
  const HelperChangeConfirmation(this.kind, {this.message = ''});
  final HelperConfirmationKind kind;
  final String message;
}

typedef ConfirmHelperChange =
    Future<bool> Function(HelperChangeConfirmation confirmation);

class HelperEditDraft {
  HelperEditDraft._(
    this._owner,
    this._revision,
    this.baseline,
    this.choices,
    this.initialSelection,
  );
  final Object _owner;
  final int _revision;
  final HelperModelAssignment baseline;
  final List<ModelChoice> choices;
  final ModelSelection initialSelection;
}

class PendingHelperChange {
  const PendingHelperChange(this.selection, this.state);

  final ModelSelection selection;
  final HelperChangeState state;
}

class HelperRowObservation {
  const HelperRowObservation(
    this.assignment,
    this.pending,
    this.available,
    this.canChoose,
  );
  final HelperModelAssignment assignment;
  final PendingHelperChange? pending;
  final bool available, canChoose;
}

class _HelperIntent {
  _HelperIntent({
    required this.task,
    required this.selection,
    required List<HelperModelAssignment> baseline,
    required List<HelperModelAssignment> desired,
  }) : baseline = List.unmodifiable(baseline),
       desired = List.unmodifiable(desired);
  final String? task;
  final ModelSelection selection;
  // Opening intent is immutable. Observation refresh and retry cannot rebase it.
  final List<HelperModelAssignment> baseline, desired;
}

/// One route owns defaults observations and helper command authority. The
/// captured profile never follows another workspace selection. Stock has no
/// atomic expected-version mutation: fresh preflight detects observed conflicts,
/// not a write racing between that observation and server dispatch.
class ProfileModelDefaultsSession extends ChangeNotifier {
  ProfileModelDefaultsSession(this.profile);
  final ProfileAdministration profile;
  final _owner = Object();
  final _pending = <String?, _HelperIntent>{};
  final _states = <String?, HelperChangeState>{};
  ModelDefaultsObservation? _observation;
  ModelProviderAccess? _access;
  bool _disposed = false,
      _loading = true,
      _busy = false,
      _awaitingConfirmation = false,
      _accessLoading = false;
  int _reads = 0,
      _commands = 0,
      _revision = 0,
      _picker = 0,
      _accessReads = 0,
      _catalogReads = 0;
  String? _error, _accessError;
  bool _readRetryable = false;
  DateTime? _checkedAt;

  ModelDefaultsObservation? get observation => _observation;
  ModelProviderAccess? get access => _access;
  bool get loading => _loading;
  bool get busy => _busy;
  bool get working => _busy && !_awaitingConfirmation;
  bool get accessLoading => _accessLoading;
  String? get error => _error;
  String? get accessError => _accessError;
  DateTime? get checkedAt => _checkedAt;
  bool get canRecoverRead =>
      !_disposed && !_loading && !_busy && _readRetryable;
  bool get canReset =>
      !_disposed && !_busy && _observation != null && _pending.isEmpty;
  List<HelperRowObservation> get helperRows => List.unmodifiable([
    for (final row in _observation?.helpers ?? const <HelperModelAssignment>[])
      HelperRowObservation(
        row,
        pendingFor(row.task),
        _observation!.choices.any(
          (choice) =>
              choice.provider == row.provider && choice.model == row.model,
        ),
        !_busy &&
            !_pending.containsKey(null) &&
            (!_pending.containsKey(row.task) ||
                _states[row.task] == HelperChangeState.pending),
      ),
  ]);
  PendingHelperChange? pendingFor(String? task) {
    final intent = _pending[task];
    return intent == null
        ? null
        : PendingHelperChange(intent.selection, _states[task]!);
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  bool _owns(int generation) => !_disposed && generation == _commands;

  Future<bool> _ask(
    int generation,
    ConfirmHelperChange confirm,
    HelperChangeConfirmation question,
  ) async {
    if (!_owns(generation)) throw StateError('Helper edit retired');
    _awaitingConfirmation = true;
    _changed();
    try {
      return await confirm(question);
    } finally {
      if (_owns(generation)) {
        _awaitingConfirmation = false;
        _changed();
      }
    }
  }

  int _beginCommand() {
    // A pre-command observation cannot replace the command's verified readback.
    _reads++;
    _accessReads++;
    _catalogReads++;
    _loading = false;
    _accessLoading = false;
    _readRetryable = false;
    return ++_commands;
  }

  Future<void> load() async {
    if (_disposed || _busy) return;
    final generation = ++_reads;
    _loading = true;
    _readRetryable = false;
    _error = null;
    _changed();
    try {
      final values = await Future.wait<Object>([
        profile.read('model/info'),
        profile.modelCatalog.load(explicitOnly: true, supersede: true),
        profile.read('model/auxiliary'),
      ]);
      final observation = ModelDefaultsObservation.fromResponses(
        values[0] as Map<String, dynamic>,
        values[1] as ModelCatalog,
        values[2] as Map<String, dynamic>,
      );
      if (_disposed || generation != _reads || _busy) return;
      if (_observation?.model.provider != observation.model.provider) {
        _access = null;
      }
      _observation = observation;
      _checkedAt = DateTime.now();
      await refreshAccess();
    } catch (failure) {
      if (!_disposed && generation == _reads) {
        _error = administrationError(failure);
        _readRetryable = isTemporaryWorkspaceFailure(failure);
      }
    } finally {
      if (!_disposed && generation == _reads) {
        _loading = false;
        _changed();
      }
    }
  }

  Future<void> refreshAccess() async {
    final observation = _observation;
    if (_disposed || observation == null) return;
    final generation = ++_accessReads;
    _accessLoading = true;
    _accessError = null;
    _changed();
    try {
      final response = await profile.read('providers/oauth');
      if (_disposed ||
          generation != _accessReads ||
          !identical(observation.model, _observation?.model)) {
        return;
      }
      _access = ModelProviderAccess.fromResponse(response, observation.model);
    } catch (failure) {
      if (!_disposed && generation == _accessReads) {
        _accessError = administrationError(failure);
      }
    } finally {
      if (!_disposed && generation == _accessReads) {
        _accessLoading = false;
        _changed();
      }
    }
  }

  Future<List<ModelChoice>> catalog({bool refresh = false}) async {
    if (_disposed) throw StateError('Model defaults are closed');
    final generation = ++_catalogReads, commands = _commands, reads = _reads;
    final choices = (await profile.modelCatalog.load(
      explicitOnly: true,
      refresh: refresh,
    )).choices;
    if (_disposed ||
        generation != _catalogReads ||
        commands != _commands ||
        reads != _reads) {
      throw StateError('Model catalog was superseded');
    }
    _observation = _observation?.withChoices(choices);
    _changed();
    return List.unmodifiable(choices);
  }

  Future<HelperEditDraft?> prepareHelper(String task) async {
    final observation = _observation;
    if (_disposed || _busy || observation == null) return null;
    if (_pending.containsKey(null) ||
        (_pending.containsKey(task) &&
            _states[task] != HelperChangeState.pending)) {
      _error =
          'Review the pending helper result before choosing another model.';
      _changed();
      return null;
    }
    final previous = _pending[task];
    final baseline =
        previous?.baseline.single ??
        observation.helpers.where((row) => row.task == task).firstOrNull;
    if (baseline == null) return null;
    final revision = _revision, picker = ++_picker;
    try {
      final choices = await catalog();
      if (_disposed || _busy || picker != _picker || revision != _revision) {
        return null;
      }
      return HelperEditDraft._(
        _owner,
        revision,
        baseline,
        choices,
        previous?.selection ?? baseline.selection,
      );
    } catch (failure) {
      if (!_disposed && picker == _picker) {
        _error = administrationError(failure);
        _changed();
      }
      return null;
    }
  }

  Future<HelperSaveOutcome> selectHelper(
    HelperEditDraft draft,
    ModelSelection selection, {
    required ConfirmHelperChange confirm,
  }) async {
    if (_disposed ||
        _busy ||
        !identical(draft._owner, _owner) ||
        draft._revision != _revision) {
      return HelperSaveOutcome.retired;
    }
    if (selection.choice case final choice?) {
      if (!(_observation?.choices.any(
            (row) =>
                row.provider == choice.provider && row.model == choice.model,
          ) ??
          false)) {
        _error = 'That helper model is no longer in the catalog. Choose again.';
        _changed();
        return HelperSaveOutcome.failed;
      }
    }
    final intent = _HelperIntent(
      task: draft.baseline.task,
      selection: selection,
      baseline: [draft.baseline],
      desired: [draft.baseline.selecting(selection)],
    );
    _pending[intent.task] = intent;
    _states[intent.task] = HelperChangeState.pending;
    _revision++;
    return _save(intent, confirm);
  }

  Future<HelperSaveOutcome> resetHelpers({
    required ConfirmHelperChange confirm,
  }) async {
    final observation = _observation;
    if (_disposed || _busy || observation == null || _pending.isNotEmpty) {
      return HelperSaveOutcome.retired;
    }
    final generation = _beginCommand();
    _busy = true;
    _changed();
    final intent = _HelperIntent(
      task: null,
      selection: const ModelSelection.special(ModelSpecialChoice.automatic),
      baseline: observation.helpers,
      desired: observation.helpers.map((row) => row.automaticReset).toList(),
    );
    try {
      final accepted = await _ask(
        generation,
        confirm,
        const HelperChangeConfirmation(HelperConfirmationKind.reset),
      );
      if (!_owns(generation)) return HelperSaveOutcome.retired;
      if (!accepted) return HelperSaveOutcome.cancelled;
      _pending[null] = intent;
      _states[null] = HelperChangeState.pending;
      _revision++;
      return await _save(intent, confirm, activeGeneration: generation);
    } catch (failure) {
      if (_owns(generation)) _error = administrationError(failure);
      return _owns(generation)
          ? HelperSaveOutcome.failed
          : HelperSaveOutcome.retired;
    } finally {
      if (_owns(generation)) {
        _busy = false;
        _changed();
      }
    }
  }

  static bool _same(
    List<HelperModelAssignment> a,
    List<HelperModelAssignment> b,
  ) => a.length == b.length && a.every((row) => b.contains(row));
  List<HelperModelAssignment> _targets(
    List<HelperModelAssignment> rows,
    _HelperIntent intent,
  ) => intent.task == null
      ? rows
      : rows.where((row) => row.task == intent.task).toList();

  Future<HelperSaveOutcome> retryHelper(
    String? task, {
    required ConfirmHelperChange confirm,
  }) async {
    final intent = _pending[task];
    if (_disposed || _busy || intent == null) return HelperSaveOutcome.retired;
    final generation = _beginCommand();
    _busy = true;
    _error = null;
    _changed();
    try {
      final current = HelperModelAssignment.fromResponse(
        await profile.read('model/auxiliary'),
      );
      if (!_owns(generation) || !identical(intent, _pending[task])) {
        return HelperSaveOutcome.retired;
      }
      final targets = _targets(current, intent);
      if (_same(targets, intent.desired)) {
        if (intent.task == null) await _verifyResetCredentials(intent);
        if (!_owns(generation)) return HelperSaveOutcome.retired;
        _resolve(intent, current);
        return HelperSaveOutcome.saved;
      }
      if (!_same(targets, intent.baseline)) {
        _states[task] = HelperChangeState.conflict;
        throw const AdministrationFailure(
          'Helper defaults changed elsewhere. Discard the pending edit and choose again after reviewing the current settings.',
        );
      }
      final accepted = await _ask(
        generation,
        confirm,
        HelperChangeConfirmation(HelperConfirmationKind.retry),
      );
      if (!_owns(generation) || !identical(intent, _pending[task])) {
        return HelperSaveOutcome.retired;
      }
      if (!accepted) return HelperSaveOutcome.cancelled;
      // Explicit consent does not change the original comparison baseline.
      return await _save(intent, confirm, activeGeneration: generation);
    } catch (failure) {
      if (_owns(generation)) {
        _error = administrationError(failure, writing: true);
      }
      return _owns(generation)
          ? HelperSaveOutcome.failed
          : HelperSaveOutcome.retired;
    } finally {
      if (_owns(generation)) {
        _busy = false;
        _changed();
      }
    }
  }

  void discardPending(String? task) {
    if (_disposed || _busy) return;
    _pending.remove(task);
    _states.remove(task);
    _revision++;
    _picker++;
    _error = null;
    _changed();
  }

  Future<void> _preflight(_HelperIntent intent, int generation) async {
    if (intent.selection.choice case final choice?) {
      final choices = (await profile.modelCatalog.load(
        explicitOnly: true,
      )).choices;
      if (!_owns(generation)) throw StateError('Helper edit retired');
      _observation = _observation?.withChoices(choices);
      if (!choices.any(
        (row) => row.provider == choice.provider && row.model == choice.model,
      )) {
        throw const AdministrationFailure(
          'That helper model is no longer in the catalog. Choose again.',
        );
      }
    }
    final rows = HelperModelAssignment.fromResponse(
      await profile.read('model/auxiliary'),
    );
    if (!_owns(generation)) throw StateError('Helper edit retired');
    if (!_same(_targets(rows, intent), intent.baseline)) {
      _states[intent.task] = HelperChangeState.conflict;
      throw const AdministrationFailure(
        'Helper defaults changed elsewhere. Review the current settings; your pending choice is kept.',
      );
    }
    // Membership is the final await immediately before dispatch. Do not call
    // write(), whose own hidden discovery await could outlive this authority.
    await profile.requireProfile();
    if (!_owns(generation)) throw StateError('Helper edit retired');
  }

  Future<void> _verifyResetCredentials(_HelperIntent intent) async {
    final config = await profile.config();
    final auxiliary = config['auxiliary'];
    if (auxiliary is! Map) {
      throw const FormatException('Missing helper configuration');
    }
    for (final row in intent.desired) {
      final slot = auxiliary[row.task];
      if (slot is! Map ||
          [
            'api_key',
            'api',
            'key_env',
            'api_key_env',
            'api_mode',
          ].any(slot.containsKey)) {
        throw const AdministrationFailure(
          'Helper reset credentials could not be confirmed. Your pending reset is kept.',
        );
      }
    }
  }

  void _resolve(_HelperIntent intent, List<HelperModelAssignment> rows) {
    if (!identical(_pending[intent.task], intent)) return;
    _pending.remove(intent.task);
    _states.remove(intent.task);
    _observation = _observation?.withHelpers(rows);
    _error = null;
    _revision++;
  }

  Future<HelperSaveOutcome> _save(
    _HelperIntent intent,
    ConfirmHelperChange confirm, {
    int? activeGeneration,
  }) async {
    if (_disposed ||
        (_busy && activeGeneration == null) ||
        !identical(_pending[intent.task], intent)) {
      return HelperSaveOutcome.retired;
    }
    final generation = activeGeneration ?? _beginCommand();
    if (!_owns(generation)) return HelperSaveOutcome.retired;
    _busy = true;
    _error = null;
    _changed();
    var mayHaveWritten = false;
    var dispatchActive = true;
    try {
      final body = <String, dynamic>{
        'scope': 'auxiliary',
        'task': intent.task ?? '__reset__',
        'provider': intent.selection.choice?.provider ?? 'auto',
        'model': intent.selection.choice?.model ?? '',
      };
      Future<Map<String, dynamic>> dispatch({bool confirmed = false}) async {
        await _preflight(intent, generation);
        if (!_owns(generation)) throw StateError('Helper edit retired');
        return profile.server.ownedMutation(
          'POST',
          'model/set',
          {'profile': profile.name},
          {
            ...body,
            'profile': profile.name,
            if (confirmed) 'confirm_expensive_model': true,
          },
          () => dispatchActive && _owns(generation),
          () {
            mayHaveWritten = true;
            _states[intent.task] = HelperChangeState.uncertain;
          },
        );
      }

      var result = await dispatch();
      if (!_owns(generation)) return HelperSaveOutcome.retired;
      if (result['confirm_required'] == true) {
        mayHaveWritten = false;
        _states[intent.task] = HelperChangeState.pending;
        final message = result['confirm_message'];
        final accepted = await _ask(
          generation,
          confirm,
          HelperChangeConfirmation(
            HelperConfirmationKind.expensive,
            message: message is String
                ? message
                : 'This model may increase cost.',
          ),
        );
        if (!_owns(generation)) return HelperSaveOutcome.retired;
        if (!accepted) return HelperSaveOutcome.cancelled;
        result = await dispatch(confirmed: true);
      }
      if (!_owns(generation)) return HelperSaveOutcome.retired;
      if (result['confirm_required'] == true) {
        mayHaveWritten = false;
        _states[intent.task] = HelperChangeState.pending;
      }
      if (result['ok'] != true || result['confirm_required'] == true) {
        throw const AdministrationFailure(
          'Helper model change was not acknowledged.',
        );
      }
      final after = HelperModelAssignment.fromResponse(
        await profile.read('model/auxiliary'),
      );
      if (!_owns(generation)) return HelperSaveOutcome.retired;
      if (!_same(_targets(after, intent), intent.desired)) {
        throw const AdministrationFailure(
          'Helper model save could not be confirmed. Your pending choice is kept.',
        );
      }
      if (intent.task == null) await _verifyResetCredentials(intent);
      if (!_owns(generation)) return HelperSaveOutcome.retired;
      _resolve(intent, after);
      return HelperSaveOutcome.saved;
    } catch (failure) {
      if (_owns(generation)) {
        if (mayHaveWritten &&
            _states[intent.task] != HelperChangeState.conflict) {
          _states[intent.task] = HelperChangeState.uncertain;
        }
        _error = administrationError(failure, writing: true);
      }
      return _owns(generation)
          ? HelperSaveOutcome.failed
          : HelperSaveOutcome.retired;
    } finally {
      // A timeout does not cancel authentication. Its continuation must lose
      // physical dispatch authority even if this route/generation stays live.
      dispatchActive = false;
      if (activeGeneration == null && _owns(generation)) {
        _busy = false;
        _changed();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _reads++;
    _commands++;
    _picker++;
    _accessReads++;
    _catalogReads++;
    super.dispose();
  }
}

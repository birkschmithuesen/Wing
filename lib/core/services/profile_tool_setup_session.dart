import 'package:flutter/foundation.dart';

import '../models/model_choice.dart';
import '../models/profile_tool_setup.dart';
import 'administration_operation_session.dart';
import 'administration_repository.dart';
import 'workspace_connection_failure.dart';
import 'connection_manager.dart' show DashboardHttpException;

/// One captured tool setup route. Its model page borrows this same owner.
/// Readback never converts an acknowledged write into an uncertain mutation.
class ProfileToolSetupSession extends ChangeNotifier {
  ProfileToolSetupSession(this._profile, {required this.tool}) {
    if (tool.isEmpty) {
      throw ArgumentError.value(tool, 'tool');
    }
    _profile.server.retain();
  }

  final ProfileAdministration _profile;
  final String tool;
  String get profileName => _profile.name;
  String get scopeLabel => _profile.label;
  String get _base => 'tools/toolsets/${Uri.encodeComponent(tool)}';
  ProfileToolSetupState _state = const ProfileToolSetupState(
    readiness: null,
    models: null,
    pendingModel: null,
    phase: ToolSetupPhase.idle,
    readinessVerified: false,
    modelsVerified: false,
    reviewRequired: false,
    acknowledgement: null,
    error: null,
  );
  ProfileToolSetupState get state => _state;
  bool _disposed = false;
  int _generation = 0;
  int _notificationDepth = 0;
  String? _modelBaseline, _modelPlugin;
  ToolModelEditor? _modelEditor;
  bool _readinessRetryable = false, _modelsRetryable = false;
  bool get canRecoverReadiness =>
      !_disposed && !_state.busy && _readinessRetryable;
  bool canRecoverModels(ToolModelEditor editor) =>
      _ownsEditor(editor) && !_state.busy && _modelsRetryable;

  bool _owns(int generation) => !_disposed && generation == _generation;

  void _publish({
    ToolSetupReadiness? readiness,
    ToolModelsObservation? models,
    bool clearModels = false,
    String? pendingModel,
    bool clearPendingModel = false,
    ToolSetupPhase? phase,
    bool? readinessVerified,
    bool? modelsVerified,
    bool? reviewRequired,
    ToolSetupAcknowledgement? acknowledgement,
    required String? error,
  }) {
    if (_disposed) {
      return;
    }
    _state = ProfileToolSetupState(
      readiness: readiness ?? _state.readiness,
      models: clearModels ? null : models ?? _state.models,
      pendingModel: clearPendingModel
          ? null
          : pendingModel ?? _state.pendingModel,
      phase: phase ?? _state.phase,
      readinessVerified: readinessVerified ?? _state.readinessVerified,
      modelsVerified: modelsVerified ?? _state.modelsVerified,
      reviewRequired: reviewRequired ?? _state.reviewRequired,
      acknowledgement: acknowledgement ?? _state.acknowledgement,
      error: error,
    );
    ++_notificationDepth;
    try {
      notifyListeners();
    } finally {
      --_notificationDepth;
      if (_disposed && _notificationDepth == 0) {
        super.dispose();
      }
    }
  }

  Future<ToolSetupReadiness> _readReadiness() async =>
      ToolSetupReadiness.decode(await _profile.read('$_base/config'), tool);

  Future<ToolModelsObservation> _readModels(String provider) async =>
      ToolModelsObservation.decode(
        await _profile.read('$_base/models', {'provider': provider}),
        tool,
        provider,
      );

  Future<void> refresh() async {
    if (_disposed ||
        (_state.busy && _state.phase != ToolSetupPhase.loadingReadiness)) {
      return;
    }
    _readinessRetryable = false;
    final generation = ++_generation;
    _profile.server.retain();
    _publish(
      phase: ToolSetupPhase.loadingReadiness,
      readinessVerified: false,
      error: null,
    );
    try {
      if (!_owns(generation)) {
        return;
      }
      final readiness = await _readReadiness();
      if (!_owns(generation)) {
        return;
      }
      _publish(
        readiness: readiness,
        readinessVerified: true,
        reviewRequired: false,
        error: null,
      );
    } catch (error) {
      if (_owns(generation)) {
        _readinessRetryable = isTemporaryWorkspaceFailure(error);
        _publish(readinessVerified: false, error: administrationError(error));
      }
    } finally {
      _profile.server.release();
      if (_owns(generation)) {
        _publish(phase: ToolSetupPhase.idle, error: _state.error);
      }
    }
  }

  ToolModelEditor openModelEditor(String provider) {
    if (_disposed ||
        _state.busy ||
        provider.isEmpty ||
        !const {'image_gen', 'video_gen'}.contains(tool)) {
      throw const AdministrationFailure('This model editor is unavailable.');
    }
    return _modelEditor = ToolModelEditor(provider);
  }

  void releaseModelEditor(ToolModelEditor editor) {
    if (!identical(_modelEditor, editor)) {
      return;
    }
    _modelEditor = null;
    if (_state.phase == ToolSetupPhase.loadingModels) {
      ++_generation;
      _publish(
        phase: ToolSetupPhase.idle,
        modelsVerified: false,
        error: _state.error,
      );
    }
  }

  bool _ownsEditor(ToolModelEditor editor) =>
      !_disposed && identical(_modelEditor, editor);

  Future<void> reviewCredentials(Future<void> Function() open) async {
    if (_disposed || _state.busy) {
      return;
    }
    await open();
    if (!_disposed) {
      await refresh();
    }
  }

  /// Starting another provider's catalog invalidates the older read and intent.
  /// Refreshing the same catalog preserves a dirty model's opening baseline.
  Future<void> loadModels(ToolModelEditor editor) async {
    final provider = editor.provider;
    if (!_ownsEditor(editor) ||
        provider.isEmpty ||
        !const {'image_gen', 'video_gen'}.contains(tool) ||
        (_state.busy && _state.phase != ToolSetupPhase.loadingModels)) {
      return;
    }
    _modelsRetryable = false;
    final changed = _state.models?.provider != provider;
    final generation = ++_generation;
    _profile.server.retain();
    _publish(
      clearModels: changed,
      clearPendingModel: changed,
      phase: ToolSetupPhase.loadingModels,
      modelsVerified: false,
      error: null,
    );
    try {
      if (!(_owns(generation) && _ownsEditor(editor))) {
        return;
      }
      final models = await _readModels(provider);
      if (!(_owns(generation) && _ownsEditor(editor))) {
        return;
      }
      if (_state.pendingModel == null) {
        _modelBaseline = models.current;
        _modelPlugin = models.plugin;
      }
      _publish(
        models: models,
        modelsVerified: true,
        reviewRequired: false,
        error: null,
      );
    } catch (error) {
      if (_owns(generation) && _ownsEditor(editor)) {
        _modelsRetryable = isTemporaryWorkspaceFailure(error);
        _publish(modelsVerified: false, error: administrationError(error));
      }
    } finally {
      _profile.server.release();
      if (_owns(generation) && _ownsEditor(editor)) {
        _publish(phase: ToolSetupPhase.idle, error: _state.error);
      }
    }
  }

  Future<List<ModelChoice>> refreshModelChoices(ToolModelEditor editor) async {
    await loadModels(editor);
    if (!_ownsEditor(editor) || !_state.modelsVerified) {
      throw AdministrationFailure(
        _state.error ?? 'The model catalog is unavailable.',
      );
    }
    return _state.models!.choices;
  }

  void stageModel(ToolModelEditor editor, ModelChoice choice) {
    final models = _state.models;
    if (!_ownsEditor(editor) ||
        !_state.canStageModel ||
        models == null ||
        editor.provider != models.provider ||
        choice.provider != models.provider ||
        !models.choices.any((row) => row.model == choice.model)) {
      return;
    }
    _modelBaseline = models.current;
    _modelPlugin = models.plugin;
    _publish(pendingModel: choice.model, error: null);
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String endpoint,
    Map<String, dynamic> body,
    bool Function() active,
    void Function() onDispatched,
  ) async {
    await _profile.requireProfile();
    if (!active()) {
      throw const AdministrationFailure('This tool setup editor is closed.');
    }
    return _profile.server.ownedMutation(
      method,
      endpoint,
      {'profile': profileName},
      {...body, 'profile': profileName},
      active,
      onDispatched,
    );
  }

  Future<void> selectProvider(
    String name, {
    required ToolWebCapability? capability,
  }) async {
    final opening = _state.readiness?.provider(name);
    if (_disposed ||
        !_state.canChooseProvider ||
        opening == null ||
        (tool == 'web' ? capability == null : capability != null)) {
      return;
    }
    final generation = ++_generation;
    var authority = true,
        dispatched = false,
        acknowledged = false,
        rejected = false;
    bool active() => authority && _owns(generation);
    _profile.server.retain();
    _publish(phase: ToolSetupPhase.saving, error: null);
    try {
      if (!active()) {
        return;
      }
      final latest = await _readReadiness();
      if (!active()) {
        return;
      }
      final row = latest.provider(name);
      if (row == null ||
          !latest.canSelectProvider ||
          (capability != null &&
              (!row.capabilities.contains(capability) ||
                  row.webBackend != opening.webBackend))) {
        throw const AdministrationFailure(
          'Provider setup changed. Refresh and review before selecting it.',
        );
      }
      final receipt = await _send(
        'PUT',
        '$_base/provider',
        {
          'provider': name,
          if (capability != null) 'capability': capability.name,
        },
        active,
        () => dispatched = true,
      );
      rejected = receipt['ok'] == false;
      if (receipt['ok'] != true ||
          receipt['name'] != tool ||
          receipt['provider'] != name ||
          (capability != null && receipt['capability'] != capability.name) ||
          (receipt['needs_nous_auth'] != null &&
              receipt['needs_nous_auth'] is! bool)) {
        throw const FormatException('Provider selection was not acknowledged');
      }
      acknowledged = true;
      if (!active()) {
        return;
      }
      _publish(
        acknowledgement: ToolSetupAcknowledgement.provider(
          needsAccount: receipt['needs_nous_auth'] == true,
        ),
        readinessVerified: false,
        modelsVerified: false,
        error: null,
      );
      if (!active()) {
        return;
      }
      final after = await _readReadiness();
      if (!active()) {
        return;
      }
      _publish(readiness: after, readinessVerified: true, error: null);
    } catch (error) {
      if (active()) {
        _publish(
          readinessVerified: false,
          reviewRequired:
              dispatched && !acknowledged && !rejected && !_rejected(error),
          error: acknowledged
              ? 'Selection saved. Readiness is unavailable; refresh to check it.'
              : rejected || _rejected(error)
              ? 'The server rejected this selection. Refresh and review.'
              : dispatched
              ? 'Provider selection was not confirmed. Refresh and review before trying again.'
              : administrationError(error, writing: true),
        );
      }
    } finally {
      authority = false;
      _profile.server.release();
      if (_owns(generation)) {
        _publish(phase: ToolSetupPhase.idle, error: _state.error);
      }
    }
  }

  Future<void> saveModel(ToolModelEditor editor) async {
    final opening = _state.models;
    final target = _state.pendingModel;
    if (!_ownsEditor(editor) ||
        !_state.canSaveModel ||
        opening == null ||
        editor.provider != opening.provider ||
        target == null) {
      return;
    }
    final generation = ++_generation;
    var authority = true,
        dispatched = false,
        acknowledged = false,
        rejected = false;
    ToolModelsObservation? preflight;
    bool active() => authority && _owns(generation) && _ownsEditor(editor);
    bool observed() => authority && _owns(generation);
    _profile.server.retain();
    _publish(phase: ToolSetupPhase.saving, error: null);
    try {
      if (!active()) {
        return;
      }
      final latest = await _readModels(opening.provider);
      if (!active()) {
        return;
      }
      if (!latest.hasModels ||
          latest.plugin != _modelPlugin ||
          !latest.choices.any((choice) => choice.model == target)) {
        throw const AdministrationFailure(
          'This provider’s model catalog changed. Refresh and review. Your edits are kept.',
        );
      }
      if (latest.current == target) {
        _modelBaseline = latest.current;
        _publish(
          models: latest,
          clearPendingModel: true,
          modelsVerified: true,
          error: null,
        );
        return;
      }
      if (latest.current != _modelBaseline) {
        throw const AdministrationFailure(
          'The model changed elsewhere. Refresh and review. Your edits are kept.',
        );
      }
      preflight = latest;
      final receipt = await _send(
        'PUT',
        '$_base/model',
        {'provider': opening.provider, 'model': target},
        active,
        () => dispatched = true,
      );
      rejected = receipt['ok'] == false;
      if (receipt['ok'] != true ||
          receipt['name'] != tool ||
          receipt['model'] != target ||
          receipt['plugin'] != latest.plugin) {
        throw const FormatException('Model selection was not acknowledged');
      }
      acknowledged = true;
      if (!observed()) {
        return;
      }
      _publish(
        acknowledgement: const ToolSetupAcknowledgement.model(),
        clearPendingModel: true,
        modelsVerified: false,
        error: null,
      );
      if (!observed()) {
        return;
      }
      final after = await _readModels(opening.provider);
      if (!observed()) {
        return;
      }
      _modelBaseline = after.current;
      _modelPlugin = after.plugin;
      _publish(models: after, modelsVerified: true, error: null);
    } catch (error) {
      if (observed()) {
        _publish(
          models: preflight,
          modelsVerified:
              !acknowledged &&
              preflight != null &&
              (rejected || _rejected(error)),
          reviewRequired:
              dispatched && !acknowledged && !rejected && !_rejected(error),
          error: acknowledged
              ? 'Model selection saved. The catalog is unavailable; refresh to check it.'
              : rejected || _rejected(error)
              ? 'The server rejected this selection. Your edits are kept. Refresh and review.'
              : dispatched
              ? 'Model selection was not confirmed. Your edits are kept. Refresh and review before trying again.'
              : administrationError(error, writing: true),
        );
      }
    } finally {
      authority = false;
      _profile.server.release();
      if (_owns(generation)) {
        _publish(phase: ToolSetupPhase.idle, error: _state.error);
      }
    }
  }

  Future<void> runSetup(
    String key, {
    required Future<bool> Function() confirm,
    required Future<void> Function(AdministrationOperationSession) showResult,
  }) async {
    if (_disposed ||
        _state.busy ||
        !_state.readinessVerified ||
        _state.reviewRequired ||
        !_state.readiness!.providers.any((row) => row.setupKey == key)) {
      return;
    }
    final generation = ++_generation;
    var authority = true,
        dispatched = false,
        acknowledged = false,
        rejected = false;
    bool active() => authority && _owns(generation);
    _profile.server.retain();
    _publish(phase: ToolSetupPhase.confirming, error: null);
    try {
      if (!active() || !await confirm() || !active()) {
        return;
      }
      _publish(phase: ToolSetupPhase.saving, error: null);
      if (!active()) {
        return;
      }
      final latest = await _readReadiness();
      if (!active()) {
        return;
      }
      if (!latest.providers.any((row) => row.setupKey == key)) {
        throw const AdministrationFailure(
          'Setup requirements changed. Refresh and review.',
        );
      }
      final receipt = await _send(
        'POST',
        '$_base/post-setup',
        {'key': key},
        active,
        () => dispatched = true,
      );
      rejected = receipt['ok'] == false;
      if (receipt['ok'] != true ||
          receipt['key'] != key ||
          receipt['name'] != 'tools-post-setup' ||
          receipt['pid'] is! int ||
          (receipt['pid'] as int) <= 0) {
        throw const FormatException('Setup start was not acknowledged');
      }
      acknowledged = true;
      if (!active()) {
        return;
      }
      final operation = AdministrationOperationSession.fromReceipt(
        _profile.server,
        receipt,
      );
      try {
        _publish(
          phase: ToolSetupPhase.reviewingResult,
          readinessVerified: false,
          acknowledgement: const ToolSetupAcknowledgement.setup(),
          error: null,
        );
        if (!active()) {
          return;
        }
        await showResult(operation);
      } finally {
        operation.dispose();
      }
      if (!active()) {
        return;
      }
      final after = await _readReadiness();
      if (active()) {
        _publish(readiness: after, readinessVerified: true, error: null);
      }
    } catch (error) {
      if (active()) {
        _publish(
          readinessVerified: false,
          reviewRequired:
              dispatched && !acknowledged && !rejected && !_rejected(error),
          error: acknowledged
              ? 'Setup started. Its result or readiness is unavailable; refresh to check it.'
              : rejected || _rejected(error)
              ? 'The server rejected this setup request. Refresh and review.'
              : dispatched
              ? 'Setup start was not confirmed. Refresh and review before starting another operation.'
              : administrationError(error, writing: true),
        );
      }
    } finally {
      authority = false;
      _profile.server.release();
      if (_owns(generation)) {
        _publish(phase: ToolSetupPhase.idle, error: _state.error);
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    ++_generation;
    _profile.server.release();
    if (_notificationDepth == 0) {
      super.dispose();
    }
  }
}

bool _rejected(Object error) =>
    error is DashboardHttpException &&
    const {400, 401, 403, 404, 405, 422}.contains(error.statusCode);

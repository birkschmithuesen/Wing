import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/administration_operation.dart';
import 'administration_repository.dart';
import 'workspace_connection_failure.dart';

class AdministrationOperationState {
  const AdministrationOperationState(
    this.observation,
    this.loading,
    this.retired,
  );
  final AdminDiagnosticObservation observation;
  final bool loading, retired;
  bool get canRefresh => !retired && !loading;
  bool get canRunAgain =>
      canRefresh && (observation.terminal || observation.resultUnavailable);
}

/// The only polling writer for a captured action. Views borrow this owner.
class AdministrationOperationSession extends ChangeNotifier {
  AdministrationOperationSession(
    this._server,
    this.action, {
    AdminDiagnosticObservation? initial,
    DateTime Function()? now,
  }) : _observation =
           initial ??
           AdminDiagnosticObservation(action, const {'running': true}, null),
       _now = now ?? DateTime.now {
    if (_observation.action.name != action.name ||
        _observation.action.pid != action.pid) {
      throw ArgumentError('Initial observation belongs to another operation');
    }
    _server.retain();
    if (!_observation.terminal) _timer = Timer(Duration.zero, refresh);
  }
  factory AdministrationOperationSession.fromReceipt(
    AdministrationRepository server,
    Map<String, dynamic> receipt,
  ) {
    try {
      if (receipt['ok'] != true) {
        throw const FormatException('Unacknowledged operation');
      }
      return AdministrationOperationSession(
        server,
        AdministrationAction.fromJson(receipt),
      );
    } on FormatException {
      throw const AdministrationFailure(
        'Operation started, but tracking is unavailable. Refresh its result.',
      );
    }
  }
  final AdministrationRepository _server;
  final AdministrationAction action;
  final DateTime Function() _now;
  AdminDiagnosticObservation _observation;
  Timer? _timer;
  Future<void>? _pending;
  bool _disposed = false;
  int _notificationDepth = 0;
  AdministrationOperationState get state =>
      AdministrationOperationState(_observation, _pending != null, _disposed);
  String get connectionId => _server.connectionId;
  String get connectionIdentity => _server.connectionIdentity;

  Future<void> refresh() {
    if (_disposed) return Future.value();
    if (_pending case final pending?) return pending;
    final completed = Completer<void>();
    _pending = completed.future;
    _timer?.cancel();
    _timer = null;
    _server.retain();
    _emit();
    unawaited(_read(completed));
    return completed.future;
  }

  Future<void> _read(Completer<void> completed) async {
    try {
      if (_disposed) return;
      final status = await _server.read(
        'actions/${Uri.encodeComponent(action.name)}/status',
        {
          'lines': {'doctor', 'security-audit'}.contains(action.name)
              ? '2000'
              : '100',
        },
      );
      if (_disposed) return;
      if (status['name'] != action.name ||
          !status.containsKey('pid') ||
          (status['pid'] != null && status['pid'] is! int) ||
          status['running'] is! bool ||
          (status['exit_code'] != null && status['exit_code'] is! int) ||
          status['lines'] is! List ||
          (status['lines'] as List).any((line) => line is! String) ||
          status['running'] == true &&
              (status['exit_code'] != null || status['pid'] == null)) {
        throw const AdministrationFailure(
          'The server returned an invalid operation result.',
        );
      }
      if (status['pid'] != action.pid) {
        _observation = _observation.withReadError(
          _observation.diagnostic
              ? 'This diagnostic’s result is no longer available. Run it again.'
              : 'This operation’s result is no longer available. Refresh the affected resource.',
          resultUnavailable: true,
        );
        return;
      }
      _observation = AdminDiagnosticObservation(action, status, _now());
      if (_observation.running == true) {
        _timer = Timer(const Duration(seconds: 3), refresh);
      }
    } catch (error) {
      if (_disposed) return;
      _observation = _observation.withReadError(administrationError(error));
      if (isTemporaryWorkspaceFailure(error)) {
        _timer = Timer(const Duration(seconds: 15), refresh);
      }
    } finally {
      _server.release();
      _pending = null;
      _emit();
      completed.complete();
    }
  }

  void _emit() {
    if (_disposed) return;
    ++_notificationDepth;
    try {
      notifyListeners();
    } finally {
      --_notificationDepth;
      if (_disposed && _notificationDepth == 0) super.dispose();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _server.release();
    if (_notificationDepth == 0) super.dispose();
  }
}

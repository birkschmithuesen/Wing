import 'dart:io';
import 'package:flutter/foundation.dart';

import '../../fork/network_gate.dart';
import 'connection_manager.dart';
import 'workspace_connection_failure.dart';

enum ServerConnectionPhase {
  unchecked,
  connected,
  reconnecting,
  limited,
  disconnected,
}

enum ConnectionAvailability { unchecked, available, unavailable }

/// One owner per exact saved connection identity; never persisted as live truth.
class ServerConnectionStatus extends ChangeNotifier {
  final String label;
  ConnectionAvailability access = ConnectionAvailability.unchecked;
  final Map<String, ConnectionAvailability> _live = {};
  final Map<String, bool> _recoveries = {};
  final Map<String, String> _failedRecoveries = {};
  String? _accessProblem;
  bool? _chatEndpointSupported;
  bool get chatEndpointUnsupported => _chatEndpointSupported == false;
  String? get recoveryProblem => _failedRecoveries.values.lastOrNull;
  String? get problem => chatEndpointUnsupported
      ? chatEndpointFailureMessage
      : recoveryProblem ?? _accessProblem;
  Future<void> Function()? retry;
  bool get recoveryAttemptInProgress =>
      _recoveries.values.any((active) => active);
  VoidCallback? onInterruption;
  bool _closed = false;

  late final networkGate = NetworkGate(_changed);
  bool get networkAvailable => networkGate.available;

  ServerConnectionStatus(this.label);

  ConnectionAvailability get live =>
      _live.values.contains(ConnectionAvailability.unavailable)
      ? ConnectionAvailability.unavailable
      : _live.values.contains(ConnectionAvailability.available)
      ? ConnectionAvailability.available
      : ConnectionAvailability.unchecked;

  /// Transport health is independent of a particular chat's restoration.
  /// An unchecked channel cannot establish recovery of a retained incident.
  ConnectionAvailability get transportAvailability {
    if (access == ConnectionAvailability.unavailable ||
        live == ConnectionAvailability.unavailable) {
      return ConnectionAvailability.unavailable;
    }
    if (access == ConnectionAvailability.available &&
        live == ConnectionAvailability.available) {
      return ConnectionAvailability.available;
    }
    return ConnectionAvailability.unchecked;
  }

  bool hasLiveObservation(String owner) => _live.containsKey(owner);
  bool liveAvailable(String owner) =>
      _live[owner] == ConnectionAvailability.available;
  ServerConnectionPhase get phase {
    if (!networkGate.available) return ServerConnectionPhase.disconnected;
    if (_recoveries.isNotEmpty) return ServerConnectionPhase.reconnecting;
    if (chatEndpointUnsupported) return ServerConnectionPhase.disconnected;
    if (_failedRecoveries.isNotEmpty) return ServerConnectionPhase.disconnected;
    if (access == ConnectionAvailability.available &&
        live == ConnectionAvailability.available) {
      return ServerConnectionPhase.connected;
    }
    if (access == ConnectionAvailability.available ||
        live == ConnectionAvailability.available) {
      return ServerConnectionPhase.limited;
    }
    if (access == ConnectionAvailability.unavailable ||
        live == ConnectionAvailability.unavailable) {
      return ServerConnectionPhase.disconnected;
    }
    return ServerConnectionPhase.unchecked;
  }

  String get description => chatEndpointUnsupported && _recoveries.isEmpty
      ? 'Chat address needs changing'
      : switch (phase) {
          ServerConnectionPhase.unchecked => 'Not checked',
          ServerConnectionPhase.connected => 'Connected',
          ServerConnectionPhase.reconnecting => 'Reconnecting',
          ServerConnectionPhase.limited =>
            live == ConnectionAvailability.unavailable
                ? 'Live updates interrupted'
                : live == ConnectionAvailability.unchecked
                ? 'Live chat not checked'
                : 'Server access interrupted',
          ServerConnectionPhase.disconnected =>
            recoveryProblem == null
                ? 'Disconnected'
                : 'Conversation unavailable',
        };
  void _changed() {
    if (!_closed) notifyListeners();
  }

  /// The exact socket's stock greeting owns endpoint support. HTTP reads and
  /// auxiliary socket liveness cannot clear a known incompatible chat address.
  void observeChatEndpoint(bool supported) {
    if (_closed) return;
    _chatEndpointSupported = supported;
    _changed();
  }

  void beginRecovery(String owner) => _setRecovery(owner, active: true);

  /// The destination still needs recovery, but Retry can bypass its backoff.
  void waitForRecovery(String owner) => _setRecovery(owner, active: false);

  void _setRecovery(String owner, {required bool active}) {
    if (_closed) return;
    _failedRecoveries.remove(owner);
    _recoveries[owner] = active;
    _changed();
  }

  void endRecovery(String owner) {
    if (_closed) return;
    _recoveries.remove(owner);
    _failedRecoveries.remove(owner);
    _changed();
  }

  /// A healthy transport does not establish that its destination was restored.
  /// Keep stopped recovery visible until that owner retries or is dismissed.
  void failRecovery(String owner, String message) {
    if (_closed) return;
    _recoveries.remove(owner);
    _failedRecoveries[owner] = message;
    _changed();
  }

  void accessAvailable() {
    if (_closed) return;
    access = ConnectionAvailability.available;
    _accessProblem = null;
    _changed();
  }

  void networkLost() {
    if (_closed) return;
    networkGate.lost();
  }

  void networkRestored() {
    if (_closed) return;
    networkGate.restored();
  }

  void liveChanged(String owner, bool connected) {
    if (_closed) return;
    _live[owner] = connected
        ? ConnectionAvailability.available
        : ConnectionAvailability.unavailable;
    _changed();
  }

  void forgetLive(String owner) {
    if (_closed) return;
    _live.remove(owner);
    _changed();
  }

  void accessFailed(Object failure) {
    if (_closed) return;
    if (failure is TlsException ||
        isTemporaryWorkspaceFailure(failure) ||
        failure is DashboardHttpException &&
            {401, 403}.contains(failure.statusCode)) {
      access = ConnectionAvailability.unavailable;
      _accessProblem = isTemporaryWorkspaceFailure(failure)
          ? null
          : workspaceFailureMessage(failure);
      _changed();
      if (isTemporaryWorkspaceFailure(failure)) onInterruption?.call();
    } else if (failure is DashboardHttpException) {
      // A rejected operation is a response, not a lost connection.
      accessAvailable();
    }
  }

  Future<T> observeAccess<T>(Future<T> Function() action) async {
    try {
      final result = await action();
      accessAvailable();
      return result;
    } catch (failure) {
      accessFailed(failure);
      rethrow;
    }
  }

  @override
  void dispose() {
    _closed = true;
    retry = null;
    onInterruption = null;
    super.dispose();
  }
}

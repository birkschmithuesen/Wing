import 'dart:io';
import 'package:flutter/foundation.dart';

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
  final Set<String> _recoveries = {};
  final Map<String, String> _failedRecoveries = {};
  String? _accessProblem;
  String? get recoveryProblem => _failedRecoveries.values.lastOrNull;
  String? get problem => recoveryProblem ?? _accessProblem;
  DateTime? lastConnected;
  Future<void> Function()? retry;
  VoidCallback? onInterruption;
  bool _closed = false;

  /// The device's own network, reported by the OS (not a server probe). This
  /// overrides an in-flight recovery: a reconnect attempt can look promising
  /// while the radio is still down, and the stock backoff budget (up to 31 s
  /// over 5 attempts) is far slower than the OS's own loss notice.
  bool _networkAvailable = true;
  bool get networkAvailable => _networkAvailable;

  ServerConnectionStatus(this.label);

  ConnectionAvailability get live =>
      _live.values.contains(ConnectionAvailability.unavailable)
      ? ConnectionAvailability.unavailable
      : _live.values.contains(ConnectionAvailability.available)
      ? ConnectionAvailability.available
      : ConnectionAvailability.unchecked;
  bool hasLiveObservation(String owner) => _live.containsKey(owner);
  bool liveAvailable(String owner) =>
      _live[owner] == ConnectionAvailability.available;
  ServerConnectionPhase get phase {
    if (!_networkAvailable) return ServerConnectionPhase.disconnected;
    if (_recoveries.isNotEmpty) return ServerConnectionPhase.reconnecting;
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

  String get description => switch (phase) {
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
      recoveryProblem == null ? 'Disconnected' : 'Conversation unavailable',
  };
  void _changed() {
    if (!_closed) notifyListeners();
  }

  void beginRecovery(String owner) {
    if (_closed) return;
    _failedRecoveries.remove(owner);
    _recoveries.add(owner);
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
    lastConnected = DateTime.now();
    _changed();
  }

  /// The OS reports the device has no network at all (e.g. airplane mode).
  /// Deliberately not cleared by [accessAvailable]: a reconnect attempt can
  /// succeed against a transport the OS itself has not vouched for (a stale
  /// socket, a route the radio state doesn't actually govern), which is the
  /// exact failure this guards against. Only an explicit [networkRestored]
  /// call, from the same OS notice, lifts it.
  void networkLost() {
    if (_closed) return;
    _networkAvailable = false;
    _changed();
  }

  void networkRestored() {
    if (_closed) return;
    _networkAvailable = true;
    _changed();
  }

  void liveChanged(String owner, bool connected) {
    if (_closed) return;
    _live[owner] = connected
        ? ConnectionAvailability.available
        : ConnectionAvailability.unavailable;
    if (connected) lastConnected = DateTime.now();
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

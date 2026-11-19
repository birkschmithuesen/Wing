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
  String? get recoveryProblem =>
      _focusedEntries(_failedRecoveries).values.lastOrNull;
  String? get problem => chatEndpointUnsupported
      ? chatEndpointFailureMessage
      : recoveryProblem ?? _accessProblem;
  Future<void> Function()? retry;
  bool get recoveryAttemptInProgress =>
      _focusedEntries(_recoveries).values.any((active) => active);

  // Fork: one owner per served profile shares this connection-level status
  // (see `_recoveries`/`_live` keyed by profile name), so a background
  // profile's own reconnect, failure or stale socket must not keep the
  // header/admission gates (`phase`, `recoveryAttemptInProgress`) stuck on
  // the profile the user actually has open. `focusOwner` narrows those
  // getters, and `phase`'s live-chat check below (`_focusedLive`), to the
  // selected owner plus the connection-wide pseudo-owners below. The public
  // `live`/`access` getters stay unscoped so the Hermes health "Alerts"
  // surface still sees a background chat going unavailable (t_a8358240 kept
  // that distinction); `transportAvailability`, built from those, is
  // intentionally unscoped too (it is the Alerts surface's input, not the
  // header's).
  static const _crossCuttingOwners = {
    'initialization',
    'notification',
    'notification-resume',
  };
  String? _focusedOwner;

  /// Call with the selected profile's name once one is chosen; call with
  /// `null` before any profile is selected (falls back to the old
  /// every-owner aggregate).
  void focusOwner(String? owner) {
    if (_closed || _focusedOwner == owner) return;
    _focusedOwner = owner;
    _changed();
  }

  bool _ownerInFocus(String owner) =>
      _focusedOwner == null ||
      owner == _focusedOwner ||
      _crossCuttingOwners.contains(owner);

  Map<String, V> _focusedEntries<V>(Map<String, V> owners) =>
      _focusedOwner == null
      ? owners
      : Map.fromEntries(
          owners.entries.where((entry) => _ownerInFocus(entry.key)),
        );
  VoidCallback? onInterruption;
  bool _closed = false;

  late final networkGate = NetworkGate(_changed);
  bool get networkAvailable => networkGate.available;

  ServerConnectionStatus(this.label);

  ConnectionAvailability get live => _aggregateLive(_live);

  /// What `phase` must use instead of [live]: a background profile going
  /// unavailable while the focused one is fine must not turn the header
  /// orange (t_1d748269).
  ConnectionAvailability get _focusedLive =>
      _aggregateLive(_focusedEntries(_live));

  static ConnectionAvailability _aggregateLive(
    Map<String, ConnectionAvailability> owners,
  ) => owners.values.contains(ConnectionAvailability.unavailable)
      ? ConnectionAvailability.unavailable
      : owners.values.contains(ConnectionAvailability.available)
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
    if (_recoveries.keys.any(_ownerInFocus)) {
      return ServerConnectionPhase.reconnecting;
    }
    if (chatEndpointUnsupported) return ServerConnectionPhase.disconnected;
    if (_failedRecoveries.keys.any(_ownerInFocus)) {
      return ServerConnectionPhase.disconnected;
    }
    if (access == ConnectionAvailability.available &&
        _focusedLive == ConnectionAvailability.available) {
      return ServerConnectionPhase.connected;
    }
    if (access == ConnectionAvailability.available ||
        _focusedLive == ConnectionAvailability.available) {
      return ServerConnectionPhase.limited;
    }
    if (access == ConnectionAvailability.unavailable ||
        _focusedLive == ConnectionAvailability.unavailable) {
      return ServerConnectionPhase.disconnected;
    }
    return ServerConnectionPhase.unchecked;
  }

  String get description =>
      chatEndpointUnsupported && !_recoveries.keys.any(_ownerInFocus)
      ? 'Chat address needs changing'
      : switch (phase) {
          ServerConnectionPhase.unchecked => 'Not checked',
          ServerConnectionPhase.connected => 'Connected',
          ServerConnectionPhase.reconnecting => 'Reconnecting',
          ServerConnectionPhase.limited =>
            _focusedLive == ConnectionAvailability.unavailable
                ? 'Live updates interrupted'
                : _focusedLive == ConnectionAvailability.unchecked
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

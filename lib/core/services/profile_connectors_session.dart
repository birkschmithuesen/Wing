import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/profile_connectors.dart';
import 'administration_repository.dart';
import 'connection_manager.dart' show DashboardHttpException;
import 'mcp_error.dart';
import 'mcp_oauth.dart';
import 'mcp_setup.dart';
import 'workspace_connection_failure.dart';
import 'ws_client.dart';

/// One captured inventory; details borrow it rather than retaining another list.
class ProfileConnectorsSession extends ChangeNotifier {
  ProfileConnectorsSession(this._profile) {
    _profile.server.retain();
  }
  final ProfileAdministration _profile;
  String get profileName => _profile.name;
  String get scopeLabel => _profile.label;
  List<ProfileConnector> _connectors = const [];
  ConnectorDetailRoute? _detail;
  ConnectorProbe? _probe;
  ConnectorPhase _phase = ConnectorPhase.idle;
  bool _checked = false, _verified = false, _review = false, _retryable = false;
  bool _disposed = false, _refreshPending = false;
  int _generation = 0, _notificationDepth = 0;
  String? _error, _notice;
  ConnectorFailureScope? _failureScope;
  ProfileConnectorsState get state => ProfileConnectorsState(
    connectors: _connectors,
    checked: _checked,
    verified: _verified,
    phase: _phase,
    probe: _probe,
    reviewRequired: _review,
    error: _error,
    notice: _notice,
    failureScope: _failureScope,
    runtime:
        _profile.server.connectorInventory.runtimeObservations[profileName],
    runtimeError: _profile.server.connectorInventory.runtimeError(profileName),
  );
  bool get canRecoverRead => !_disposed && !state.busy && _retryable;
  bool _live(int generation) => !_disposed && generation == _generation;
  void _emit() {
    if (_disposed) return;
    _notificationDepth++;
    try {
      notifyListeners();
    } finally {
      _notificationDepth--;
      if (_disposed && _notificationDepth == 0) super.dispose();
    }
  }

  Future<List<ProfileConnector>> _read() async => ProfileConnector.decodeList(
    await _profile.server.connectorInventory.refresh(profileName),
  );
  Future<void> refresh() async {
    if (_disposed) return;
    if (_phase != ConnectorPhase.idle && _phase != ConnectorPhase.reading) {
      _refreshPending = true;
      return;
    }
    final generation = ++_generation;
    _phase = ConnectorPhase.reading;
    _verified = false;
    _error = null;
    _failureScope = null;
    _retryable = false;
    _profile.server.retain();
    _emit();
    try {
      if (!_live(generation)) return;
      final rows = await _read();
      if (!_live(generation)) return;
      _connectors = rows;
      _checked = true;
      _verified = true;
      _review = false;
    } catch (failure) {
      if (_live(generation)) {
        _failureScope = ConnectorFailureScope.read;
        _error = administrationError(failure);
        _retryable = isTemporaryWorkspaceFailure(failure);
      }
    } finally {
      _profile.server.release();
      if (_live(generation)) {
        _phase = ConnectorPhase.idle;
        _emit();
      }
    }
  }

  ConnectorDetailRoute openDetail(String name, {required bool signInOnOpen}) {
    if (_disposed || state.busy) {
      throw const AdministrationFailure('Connector work is still running.');
    }
    _probe = null;
    return _detail = ConnectorDetailRoute._(this, name, signInOnOpen, false);
  }

  /// An alert can open a detail without mounting an inventory underneath it.
  static ConnectorDetailRoute openStandaloneDetail(
    ProfileAdministration profile,
    String name,
  ) {
    final session = ProfileConnectorsSession(profile);
    final route = ConnectorDetailRoute._(session, name, false, true);
    session._detail = route;
    return route;
  }

  /// A picker replacement owns a new inventory; the original child borrows this one.
  ConnectorDetailRoute detailForProfile(
    String name, {
    required String profileName,
    required bool signInOnOpen,
  }) {
    if (profileName == this.profileName && !_disposed) {
      return openDetail(name, signInOnOpen: signInOnOpen);
    }
    final selected = ProfileConnectorsSession(
      _profile.server.profile(profileName),
    );
    final route = ConnectorDetailRoute._(selected, name, signInOnOpen, true);
    selected._detail = route;
    return route;
  }

  McpSetupSession setupForProfile(String profileName) {
    if (profileName == this.profileName && !_disposed) {
      return createSetup();
    }
    return McpSetupSession(_profile.server.profile(profileName));
  }

  void releaseDetail(ConnectorDetailRoute route) {
    if (!identical(route, _detail)) return;
    _detail = null;
    if (_phase == ConnectorPhase.reading) {
      ++_generation;
      _phase = ConnectorPhase.idle;
      _verified = false;
      _emit();
    }
  }

  ProfileConnector? connector(ConnectorDetailRoute route) =>
      _connectors.where((row) => row.name == route.name).firstOrNull;
  bool canConfigure(ConnectorDetailRoute route) =>
      identical(route, _detail) &&
      state.canMutate &&
      connector(route)?.canConfigure == true;
  McpSetupSession createSetup() {
    if (_disposed || !state.canMutate) {
      throw const AdministrationFailure(
        'Refresh connectors before adding one.',
      );
    }
    return McpSetupSession(_profile);
  }

  bool canSignIn(ConnectorDetailRoute route) =>
      !_disposed &&
      identical(route, _detail) &&
      state.canMutate &&
      connector(route)?.canSignIn == true;
  McpOAuth createSignIn(
    ConnectorDetailRoute route, {
    required McpLoopbackFactory bindLoopback,
  }) {
    if (!canSignIn(route)) {
      throw const AdministrationFailure(
        'Refresh this connector before signing in.',
      );
    }
    return McpOAuth(
      profile: _profile,
      name: route.name,
      bindLoopback: bindLoopback,
    );
  }

  void returnedFromSignIn(ConnectorDetailRoute route) {
    if (_disposed || !identical(_detail, route)) return;
    _probe = null;
    _error = null;
    _failureScope = null;
    _emit();
  }

  Future<void> toggle(ProfileConnector row, bool enabled) async {
    if (!_connectors.any((candidate) => identical(candidate, row)) ||
        !row.canConfigure) {
      return;
    }
    await _command(
      null,
      null,
      ConnectorPhase.saving,
      'PUT',
      'mcp/servers/${Uri.encodeComponent(row.name)}/enabled',
      {'enabled': enabled},
      preflight: (rows) {
        final current = rows.where((r) => r.name == row.name).firstOrNull;
        if (current?.canConfigure != true) {
          throw const AdministrationFailure('This connector cannot be edited.');
        }
      },
      acknowledge: (result) =>
          result['ok'] == true &&
          result['name'] == row.name &&
          result['enabled'] == enabled,
      notice:
          'Saved. Reconnect MCP tools to apply this change to existing chats.',
      verify: (rows) =>
          rows.where((r) => r.name == row.name).firstOrNull?.enabled == enabled,
    );
  }

  Future<void> test(
    ConnectorDetailRoute route,
    Future<bool> Function() confirm,
  ) async {
    if (!identical(_detail, route) || connector(route) == null) return;
    await _command(
      route,
      confirm,
      ConnectorPhase.testing,
      'POST',
      'mcp/servers/${Uri.encodeComponent(route.name)}/test',
      const {},
      preflight: (rows) {
        if (!rows.any((row) => row.name == route.name)) {
          throw const AdministrationFailure(
            'This connector is no longer available.',
          );
        }
      },
      probe: true,
    );
  }

  Future<bool> remove(
    ConnectorDetailRoute route,
    Future<bool> Function() confirm,
  ) async {
    if (!canConfigure(route)) return false;
    return _command(
      route,
      confirm,
      ConnectorPhase.saving,
      'DELETE',
      'mcp/servers/${Uri.encodeComponent(route.name)}',
      const {},
      preflight: (rows) {
        if (rows
                .where((row) => row.name == route.name)
                .firstOrNull
                ?.canConfigure !=
            true) {
          throw const AdministrationFailure(
            'This connector cannot be removed.',
          );
        }
      },
      acknowledge: (result) => result['ok'] == true,
      notice: 'Connector removed.',
      verify: (rows) => !rows.any((row) => row.name == route.name),
    );
  }

  Future<bool> _command(
    ConnectorDetailRoute? child,
    Future<bool> Function()? confirm,
    ConnectorPhase phase,
    String method,
    String path,
    Map<String, dynamic> body, {
    required void Function(List<ProfileConnector>) preflight,
    bool Function(Map<String, dynamic>)? acknowledge,
    String? notice,
    bool Function(List<ProfileConnector>)? verify,
    bool probe = false,
  }) async {
    if (_disposed || !state.canMutate) return false;
    final generation = ++_generation;
    bool live() => _live(generation);
    bool active() => live() && (child == null || identical(_detail, child));
    var dispatched = false, acknowledged = false;
    _phase = confirm == null ? phase : ConnectorPhase.confirming;
    _error = null;
    _notice = null;
    _failureScope = null;
    _profile.server.retain();
    _emit();
    try {
      if (!active() || confirm != null && !await confirm() || !active()) {
        return false;
      }
      if (probe) _probe = null;
      _phase = phase;
      _emit();
      if (!active()) return false;
      preflight(await _read());
      if (!active()) return false;
      await _profile.requireProfile();
      if (!active()) return false;
      final result = await _profile.server.ownedMutation(
        method,
        path,
        {'profile': profileName},
        {...body, 'profile': profileName},
        active,
        () {
          dispatched = true;
          if (!probe) {
            _profile.server.connectorInventory.invalidate(profileName);
          }
        },
      );
      if (probe) {
        final observation = ConnectorProbe.decode(
          result,
          (error) => mcpErrorMessage(error, summary: 'Connection test failed.'),
        );
        if (!live()) return false;
        _probe = observation;
        return observation.connected;
      }
      if (acknowledge?.call(result) != true) {
        throw const FormatException(
          'Connector setting could not be confirmed.',
        );
      }
      acknowledged = true;
      if (!live()) return false;
      _notice = notice;
      _verified = false;
      _emit();
      if (!live()) return false;
      final rows = await _read();
      if (!live()) return false;
      if (verify?.call(rows) != true) {
        throw const AdministrationFailure(
          'Connector setting could not be confirmed.',
        );
      }
      _connectors = rows;
      _checked = true;
      _verified = true;
      return true;
    } catch (failure) {
      if (live()) {
        _verified = false;
        _failureScope = acknowledged
            ? ConnectorFailureScope.read
            : ConnectorFailureScope.command;
        _review = !probe && dispatched && !acknowledged && !_rejected(failure);
        if (probe) {
          _probe = ConnectorProbe(
            tools: const [],
            failure: mcpErrorMessage(
              failure is AdministrationFailure ? failure.serverError : null,
              summary: 'Connection test failed.',
            ),
          );
          _error =
              'The current connector status is unavailable. Refresh before testing again.';
        } else {
          _error = acknowledged
              ? '$notice The current connector list is unavailable; refresh to check it.'
              : _review
              ? 'Connector setting could not be confirmed. Refresh the connector list before retrying.'
              : administrationError(failure, writing: true);
        }
      }
      return false;
    } finally {
      _profile.server.release();
      if (live()) {
        _phase = ConnectorPhase.idle;
        _emit();
        if (_refreshPending && live()) {
          _refreshPending = false;
          await refresh();
        }
      }
    }
  }

  Future<void> reconnect(Future<bool> Function() confirm) async {
    if (_disposed || state.busy) return;
    final generation = ++_generation;
    bool active() => _live(generation);
    _phase = ConnectorPhase.confirming;
    _error = null;
    _notice = null;
    _failureScope = null;
    _profile.server.retain();
    _emit();
    try {
      if (!active() || !await confirm() || !active()) return;
      _phase = ConnectorPhase.reconnecting;
      _emit();
      if (!active()) return;
      // This is process-wide; default supplies transport, never profile scope.
      final result = await _profile.server
          .gateway('default')
          .reloadMcp(confirm: true, canDispatch: active, onDispatched: () {});
      if (result['status'] != 'reloaded') {
        throw const AdministrationFailure(
          'MCP tool reconnection could not be confirmed.',
        );
      }
      if (active()) _notice = 'MCP tools reconnected.';
    } catch (failure) {
      if (active()) {
        _failureScope = ConnectorFailureScope.command;
        _error = switch (failure) {
          JsonRpcError(reason: 'request_timeout') || TimeoutException() =>
            'MCP tool reconnection timed out. It may still be running on the server. Check connector status before retrying.',
          JsonRpcError(reason: 'connection_closed') =>
            'The connection closed before reconnection could be confirmed. Reconnect to the server and check connector status before retrying.',
          JsonRpcError() => mcpErrorMessage(
            failure.message,
            summary: 'MCP tool reconnection failed.',
          ),
          AdministrationFailure() => failure.message,
          _ =>
            'MCP tool reconnection could not be confirmed. Check the server connection before retrying.',
        };
      }
    } finally {
      _profile.server.release();
      if (active()) {
        _phase = ConnectorPhase.idle;
        _emit();
        if (_refreshPending && active()) {
          _refreshPending = false;
          await refresh();
        }
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    _profile.server.release();
    if (_notificationDepth == 0) super.dispose();
  }
}

bool _rejected(Object failure) =>
    failure is DashboardHttpException &&
    const {400, 401, 403, 404, 405, 409, 422}.contains(failure.statusCode);

/// Issued route authority. It never transfers an old profile's observations.
final class ConnectorDetailRoute {
  ConnectorDetailRoute._(
    this.session,
    this.name,
    this.signInOnOpen,
    this._ownsSession,
  );
  final ProfileConnectorsSession session;
  final String name;
  final bool signInOnOpen;
  final bool _ownsSession;
  bool _disposed = false;
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    session.releaseDetail(this);
    if (_ownsSession) session.dispose();
  }
}

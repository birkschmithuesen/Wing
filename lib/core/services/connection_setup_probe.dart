import 'dashboard_oauth_session.dart';
import 'connection_access.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/hermes_profile.dart';
import 'connection_manager.dart';
import 'profile_gateway.dart';
import 'profiles_repository.dart';
import 'workspace_connection_failure.dart';

enum ConnectionCheck { profiles, chat, history }

enum ConnectionCheckStatus { waiting, checking, available, failed }

/// Owns provisional network resources; it never saves or sends a chat message.
abstract interface class ConnectionProbe {
  Future<ProfileDiscovery> discover();
  Future<void> connect(HermesProfile profile);
  Future<void> history();
  void close();
}

class DashboardConnectionProbe implements ConnectionProbe {
  DashboardConnectionProbe(this.access)
    : _profiles = ProfilesRepository.forConnection(access);

  final ConnectionAccess access;
  SavedConnection get connection => access.connection;
  final ProfilesRepository _profiles;
  ProfileGateway? _gateway;
  bool _closed = false;

  @override
  Future<ProfileDiscovery> discover() => _profiles.discover();

  @override
  Future<void> connect(HermesProfile profile) async {
    if (_closed) throw StateError('Connection check cancelled');
    final gateway = ProfileGateway.forConnection(
      access,
      WorkspaceScope(connectionId: connection.id, profileName: profile.name),
    );
    _gateway = gateway;
    await gateway.connect();
  }

  @override
  Future<void> history() async {
    if (_closed) throw StateError('Connection check cancelled');
    await _gateway!.sessions();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _profiles.close();
    _gateway?.close();
  }
}

/// Separates checking access from committing the user's connection.
class ConnectionSetupProbe extends ChangeNotifier {
  ConnectionSetupProbe({
    this.createProbe = DashboardConnectionProbe.new,
    this.deadline = const Duration(seconds: 15),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final ConnectionProbe Function(ConnectionAccess) createProbe;
  final Duration deadline;
  final DateTime Function() _now;
  final statuses = {
    for (final stage in ConnectionCheck.values)
      stage: ConnectionCheckStatus.waiting,
  };
  ConnectionProbe? _probe;
  ConnectionAccess? _access;
  int _generation = 0;
  bool checking = false;
  ProfileDiscovery? discovery;
  String? error;
  int? httpStatus;
  ConnectionCheck? failedStage;
  bool chatEndpointUnsupported = false;
  DateTime? checkedAt;

  bool get verified =>
      discovery != null &&
      error == null &&
      statuses.values.every(
        (status) => status == ConnectionCheckStatus.available,
      );

  SavedConnection get verifiedConnection {
    if (!verified || _access == null) {
      throw StateError('This connection is not verified.');
    }
    return _access!.persistenceSnapshot;
  }

  Future<void> check(ConnectionAccess access) async {
    cancel();
    _access = access;
    final generation = _generation;
    checking = true;
    notifyListeners();
    ConnectionCheck stage = ConnectionCheck.profiles;
    ConnectionProbe? probe;
    try {
      probe = createProbe(access);
      _probe = probe;
      for (stage in ConnectionCheck.values) {
        statuses[stage] = ConnectionCheckStatus.checking;
        notifyListeners();
        switch (stage) {
          case ConnectionCheck.profiles:
            final result = await probe.discover().timeout(deadline);
            if (generation != _generation) return;
            discovery = result;
          case ConnectionCheck.chat:
            await probe.connect(discovery!.serverPreferred).timeout(deadline);
          case ConnectionCheck.history:
            await probe.history().timeout(deadline);
        }
        if (generation != _generation) return;
        statuses[stage] = ConnectionCheckStatus.available;
        notifyListeners();
      }
    } catch (failure) {
      if (generation != _generation) return;
      statuses[stage] = ConnectionCheckStatus.failed;
      failedStage = stage;
      chatEndpointUnsupported = isUnsupportedChatEndpoint(failure);
      httpStatus = failure is DashboardHttpException
          ? failure.statusCode
          : null;
      error = _failureMessage(failure, stage);
    } finally {
      probe?.close();
      if (generation == _generation) {
        _probe = null;
        checking = false;
        checkedAt = _now();
        notifyListeners();
      }
    }
  }

  static String _failureMessage(Object error, ConnectionCheck stage) {
    if (isUnsupportedChatEndpoint(error)) return chatEndpointFailureMessage;
    if (error is CloudAccessException) return error.message;
    if (error is DashboardHttpException) {
      if ([301, 302, 303, 307, 308].contains(error.statusCode)) {
        return 'This address redirects. Enter the final gateway Webapp address.';
      }
      if (error.statusCode == 401 && error.endpoint == 'auth/password-login') {
        return 'The dashboard rejected this username or password.';
      }
      if ([401, 403].contains(error.statusCode)) {
        return 'Access was denied. Review your sign-in or custom access settings.';
      }
      if (stage == ConnectionCheck.profiles &&
          [404, 405].contains(error.statusCode)) {
        return 'This server doesn’t provide the profile access Wing needs. Check the gateway Webapp address and Connection guide.';
      }
    }
    if (error is TimeoutException) {
      return 'This check timed out. Check your phone’s network and the server, then try again.';
    }
    return switch (stage) {
      ConnectionCheck.profiles =>
        error is FormatException
            ? 'The server returned an unexpected profile response. Check the gateway Webapp address and Connection guide.'
            : 'Couldn’t reach your Hermes profiles. Check the address, sign-in and your phone’s network.',
      ConnectionCheck.chat =>
        'Profiles are available, but live chat couldn’t connect.',
      ConnectionCheck.history =>
        'Live chat connected, but chat history couldn’t be loaded.',
    };
  }

  void cancel() {
    _generation++;
    _probe?.close();
    _probe = null;
    _access = null;
    checking = false;
    discovery = null;
    error = null;
    httpStatus = null;
    failedStage = null;
    chatEndpointUnsupported = false;
    checkedAt = null;
    for (final stage in ConnectionCheck.values) {
      statuses[stage] = ConnectionCheckStatus.waiting;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _generation++;
    _probe?.close();
    super.dispose();
  }
}

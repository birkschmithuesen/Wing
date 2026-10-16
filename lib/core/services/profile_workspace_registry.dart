// Keep the factory's named argument public without exposing mutable state.
// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import 'connection_manager.dart';
import 'profile_connection_identity.dart';
import 'profile_workspace_controller.dart';

typedef ProfileControllerFactory =
    ProfileWorkspaceController Function(
      SavedConnection connection,
      String identity,
    );

/// Retained turns keep their original clients. Editing a connection creates a
/// separate owner; it never retargets sockets, drafts, or pending recovery.
class ProfileWorkspaceRegistry extends ChangeNotifier {
  final ProfileConnectionIdentity identities;
  final ProfileControllerFactory _create;
  final _controllers = <String, ProfileWorkspaceController>{};
  bool _closed = false;
  bool _hasActiveChats = false;
  String _monitoringFingerprint = '';

  Map<String, String> get monitoringSummary {
    final chats = _controllers.values.expand(
      (owner) => owner.notificationMonitoringChats,
    );
    return {
      'title': 'Watching chats',
      'text': chats.map((chat) => '${chat.title} · ${chat.state}').join('\n'),
    };
  }

  bool get hasActiveChats => _hasActiveChats;
  Iterable<ProfileWorkspaceController> get controllers => _controllers.values;

  void _activityChanged() {
    if (_closed) return;
    final active = _controllers.values.any((owner) => owner.hasActiveChats);
    final fingerprint = '$active:$monitoringSummary';
    if (_monitoringFingerprint == fingerprint) return;
    _monitoringFingerprint = fingerprint;
    _hasActiveChats = active;
    notifyListeners();
  }

  ProfileWorkspaceRegistry({
    required this.identities,
    required ProfileControllerFactory create,
  }) : _create = create;

  Future<ProfileWorkspaceController> forConnection(
    SavedConnection connection,
  ) async {
    final identity = await identities.resolve(connection);
    if (_closed) throw StateError('Workspace registry is closed');
    final controller = _controllers.putIfAbsent(identity, () {
      final owner = _create(connection, identity);
      owner.addListener(_activityChanged);
      return owner;
    });
    _activityChanged();
    return controller;
  }

  Future<ProfileWorkspaceController> forSession(
    SavedConnection connection,
    ProfileSessionKey target,
  ) async {
    final controller = await forConnection(connection);
    if (!controller.owns(target)) {
      throw StateError('The original connection settings have changed');
    }
    return controller;
  }

  void networkUnavailable() {
    if (_closed) return;
    for (final owner in _controllers.values) {
      owner.networkUnavailable();
    }
  }

  void recoverConnections() {
    if (_closed) return;
    for (final owner in _controllers.values) {
      if (owner.initialized ||
          owner.recovering ||
          owner.notificationChat != null) {
        owner.resumeConnection(networkChanged: true);
      }
    }
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    for (final controller in _controllers.values) {
      controller.removeListener(_activityChanged);
      controller.dispose();
    }
    _controllers.clear();
    super.dispose();
  }
}

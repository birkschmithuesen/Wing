import '../models/profile_session_key.dart';
import '../models/bots.dart';
import '../models/hermes_profile.dart';
// Keep the factory's named argument public without exposing mutable state.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'connection_manager.dart';
import 'connection_diagnostics.dart';
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
  final _monitoringBots =
      <
        WorkspaceScope,
        ({String title, ProfileSessionKey? root, ProfileSessionKey? tip})
      >{};
  bool _closed = false;
  bool _hasActiveChats = false;
  String _monitoringFingerprint = '';
  Set<String>? _configuredIdentities;
  int _configurationGeneration = 0;
  Timer? _retirement;
  bool _foreground = true;
  void setForeground(bool value) {
    _foreground = value;
    for (final controller in _controllers.values) {
      controller.setGroupNotificationsForeground(value);
    }
  }

  Map<String, String> get monitoringSummary {
    final chats = _controllers.values
        .expand((owner) => owner.notificationMonitoringChats)
        .toList();
    return {
      'title': 'Watching chats',
      'payload': chats.length == 1 ? chats.single.payload : '',
      'text': [
        ...chats.take(3).map((chat) {
          final bot = _monitoringBots[chat.key?.workspace];
          final title =
              bot != null &&
                  chat.key != null &&
                  (chat.key == bot.root || chat.key == bot.tip)
              ? bot.title
              : chat.title;
          return '$title · ${chat.state}';
        }),
        if (chats.length > 3)
          '${chats.length - 3} more ${chats.length == 4 ? 'chat' : 'chats'}',
      ].join('\n'),
    };
  }

  /// Borrow only immutable identity metadata from the existing Bots reader.
  /// Exact root/tip keys prevent another chat or instance inheriting its name.
  void observeMonitoringBotIdentity(WorkspaceScope scope, BotRecord? bot) {
    if (_closed) return;
    if (bot != null && bot.scope != scope) {
      throw ArgumentError('Bot identity belongs to another workspace');
    }
    final next = bot == null
        ? null
        : (title: bot.title, root: bot.chat, tip: bot.resolvedChat);
    if (_monitoringBots[scope] == next) return;
    if (next == null) {
      _monitoringBots.remove(scope);
    } else {
      _monitoringBots[scope] = next;
    }
    _activityChanged();
  }

  bool get hasActiveChats => _hasActiveChats;
  Iterable<ProfileWorkspaceController> get controllers => _controllers.values;

  void _activityChanged() {
    if (_closed) return;
    _scheduleRetirement();
    final active = _controllers.values.any((owner) => owner.hasActiveChats);
    final fingerprint =
        '$active:$monitoringSummary:${_controllers.values.map((owner) => '${owner.connectionIdentity}:${owner.initialized}:${owner.hasMountedRoutes}').join('|')}';
    if (_monitoringFingerprint == fingerprint) return;
    _monitoringFingerprint = fingerprint;
    _hasActiveChats = active;
    notifyListeners();
  }

  ProfileWorkspaceRegistry({
    required this.identities,
    required ProfileControllerFactory create,
  }) : _create = create;

  /// Reconcile the exact saved configuration, independently of notification
  /// lookups. A request for an old chat never makes its owner current again.
  Future<void> reconcileConnections(
    Iterable<SavedConnection> connections,
  ) async {
    final generation = ++_configurationGeneration;
    final saved = connections.toList();
    final identities = await Future.wait(saved.map(this.identities.resolve));
    if (_closed || generation != _configurationGeneration) return;
    _configuredIdentities = identities.toSet();
    for (var index = 0; index < saved.length; index++) {
      _controllers[identities[index]]?.observeConnectionLabel(
        saved[index].label,
      );
    }
    _retireSettledOwners();
  }

  void _scheduleRetirement() {
    if (_configuredIdentities == null || _retirement != null) return;
    // Leave the caller's await continuation time to initialize or mount a new
    // owner. Never dispose inside an owner's notification callback.
    _retirement = Timer(Duration.zero, () {
      _retirement = null;
      _retireSettledOwners();
    });
  }

  void _retireSettledOwners() {
    if (_closed || _configuredIdentities == null) return;
    var removed = false;
    for (final entry in _controllers.entries.toList()) {
      if (_configuredIdentities!.contains(entry.key) ||
          entry.value.hasRetentionObligations) {
        continue;
      }
      _controllers.remove(entry.key);
      _monitoringBots.removeWhere(
        (scope, _) => scope.connectionIdentity == entry.key,
      );
      entry.value.removeListener(_activityChanged);
      entry.value.retentionChanges.removeListener(_activityChanged);
      entry.value.dispose();
      removed = true;
    }
    if (removed) _activityChanged();
  }

  /// Resolve current secure saved authority before using the existing registry.
  Future<ProfileWorkspaceController> forSavedConnection(
    ConnectionManager manager,
    String connectionId, {
    required bool Function() canUse,
  }) async {
    if (_closed) {
      throw StateError('Workspace registry is closed');
    }
    if (!canUse()) {
      throw StateError('Workspace entry is no longer active');
    }
    final current = (await manager.loadConnectionsWithSecrets())
        .where((connection) => connection.id == connectionId)
        .firstOrNull;
    if (_closed) {
      throw StateError('Workspace registry is closed');
    }
    if (!canUse()) {
      throw StateError('Workspace entry is no longer active');
    }
    if (current == null) {
      throw StateError('The connection is unavailable');
    }
    final identity = await identities.resolve(current);
    if (!canUse()) {
      throw StateError('Workspace entry is no longer active');
    }
    return _forResolvedConnection(current, identity);
  }

  Future<ProfileWorkspaceController> forConnection(
    SavedConnection connection,
  ) async {
    final identity = await identities.resolve(connection);
    return _forResolvedConnection(connection, identity);
  }

  ProfileWorkspaceController _forResolvedConnection(
    SavedConnection connection,
    String identity,
  ) {
    if (_closed) throw StateError('Workspace registry is closed');
    final controller = _controllers.putIfAbsent(identity, () {
      final owner = _create(connection, identity);
      owner.setGroupNotificationsForeground(_foreground);
      owner.addListener(_activityChanged);
      owner.retentionChanges.addListener(_activityChanged);
      return owner;
    });
    controller.observeConnectionLabel(connection.label);
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

  void recoverConnections() => _resumeConnections(networkChanged: true);

  /// Foreground entry retries unavailable connections without replacing live ones.
  void resumeConnections() => _resumeConnections(networkChanged: false);

  void _resumeConnections({required bool networkChanged}) {
    if (_closed) return;
    _retireSettledOwners();
    for (final owner in _controllers.values) {
      final eligible =
          owner.initialized ||
          owner.recovering ||
          owner.notificationChat != null ||
          // A failed startup can be classified as permanent. A mounted route
          // still deserves a fresh attempt when the user returns to Wing.
          !networkChanged && owner.hasMountedRoutes;
      logConnectionDiagnostic(
        'registry.recovery_trigger',
        details: {
          'connection': owner.connection.id,
          'trigger': networkChanged ? 'network_changed' : 'foreground',
          'initialized': owner.initialized,
          'recovering': owner.recovering,
          'mounted': owner.hasMountedRoutes,
          'eligible': eligible,
        },
      );
      if (eligible) {
        unawaited(owner.resumeConnection(networkChanged: networkChanged));
      }
    }
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _retirement?.cancel();
    for (final controller in _controllers.values) {
      controller.removeListener(_activityChanged);
      controller.retentionChanges.removeListener(_activityChanged);
      controller.dispose();
    }
    _controllers.clear();
    _monitoringBots.clear();
    super.dispose();
  }
}

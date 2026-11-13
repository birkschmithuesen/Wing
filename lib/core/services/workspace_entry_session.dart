import 'package:flutter/foundation.dart';

import '../models/workspace_entry.dart';
import 'android_launch_intent_service.dart';
import 'app_preferences.dart';
import 'connection_manager.dart';
import 'profile_workspace_controller.dart';
import 'profile_workspace_registry.dart';

class WorkspaceEntryState {
  const WorkspaceEntryState({required this.opening, required this.error});
  final bool opening;
  final String? error;
}

/// An issued entry retains exact workspace authority, never a connection cache.
class WorkspaceEntryPlan {
  WorkspaceEntryPlan._(
    this.controller,
    this._owner,
    this._generation,
    this._launchRevision,
  );
  final ProfileWorkspaceController controller;
  final WorkspaceEntrySession _owner;
  final int _generation;
  final int _launchRevision;
}

/// One Home lifetime coordinates choice, secure admission and remembered entry.
/// Registry, launcher and preferences are borrowed, never disposed here.
class WorkspaceEntrySession extends ChangeNotifier {
  WorkspaceEntrySession({
    required ConnectionManager connectionManager,
    required AppPreferences appPreferences,
    required this._registry,
    required AndroidLaunchIntentService? launchIntents,
  }) : _manager = connectionManager,
       _preferences = appPreferences,
       _launcher = launchIntents {
    _remembered = _preferences.workspaceEntry;
    _remembered.addListener(_changed);
    _launcher?.pendingAction.addListener(_launchChanged);
  }

  final ConnectionManager _manager;
  final AppPreferences _preferences;
  final ProfileWorkspaceRegistry _registry;
  final AndroidLaunchIntentService? _launcher;
  late final ValueListenable<WorkspaceEntryFact> _remembered;
  bool _closed = false;
  bool _opening = false;
  bool _startupAttempted = false;
  String? _error;
  int _generation = 0;
  int _launchRevision = 0;
  int _notificationDepth = 0;

  WorkspaceEntryState get state => WorkspaceEntryState(
    opening: _opening,
    error: _error ?? _remembered.value.error,
  );

  void _changed() {
    if (_closed) {
      return;
    }
    _notificationDepth++;
    try {
      notifyListeners();
    } finally {
      _notificationDepth--;
      if (_closed && _notificationDepth == 0) {
        super.dispose();
      }
    }
  }

  void _launchChanged() {
    _launchRevision++;
  }

  void suppressStartupRestore() => _startupAttempted = true;

  SavedConnection? startupConnection({required bool hasPendingShare}) {
    if (_closed || _startupAttempted) {
      return null;
    }
    final connections = _manager.getConnections();
    if (connections.isEmpty) {
      return null;
    }
    _startupAttempted = true;
    if (hasPendingShare || _launcher?.pendingAction.value != null) {
      return null;
    }
    final fact = _remembered.value;
    if (fact.validity != WorkspaceEntryValidity.valid) {
      return null;
    }
    return connections
        .where((connection) => connection.id == fact.confirmedId)
        .firstOrNull;
  }

  SavedConnection? externalConnection() {
    if (_closed) {
      return null;
    }
    final connections = _manager.getConnections();
    final fact = _remembered.value;
    if (fact.validity == WorkspaceEntryValidity.unverified) {
      return null;
    }
    // A pending explicit choice is navigation intent, never a restart ACK.
    final requested = fact.busy ? fact.requestedId : null;
    if (requested == null && fact.validity == WorkspaceEntryValidity.invalid) {
      return null;
    }
    final preferred = connections
        .where((connection) => connection.id == (requested ?? fact.confirmedId))
        .firstOrNull;
    return preferred ?? (connections.length == 1 ? connections.single : null);
  }

  SavedConnection? sharedConnection(String? originalId) {
    if (_closed) {
      return null;
    }
    final connections = _manager.getConnections();
    final original = connections
        .where((connection) => connection.id == originalId)
        .firstOrNull;
    return original ?? (connections.length == 1 ? connections.single : null);
  }

  /// Passive connection indicators use the same fresh saved authority as entry.
  Future<ProfileWorkspaceController> controllerFor(SavedConnection connection) {
    if (_closed) {
      return Future.error(StateError('Workspace entry is closed'));
    }
    return _registry.forSavedConnection(
      _manager,
      connection.id,
      canUse: () => !_closed,
    );
  }

  Future<WorkspaceEntryPlan?> prepare(SavedConnection connection) async {
    if (_closed || _opening) {
      return null;
    }
    final generation = ++_generation;
    final launchRevision = _launchRevision;
    _opening = true;
    _error = null;
    _startupAttempted = true;
    _changed();
    if (_closed || generation != _generation) {
      return null;
    }
    try {
      final controller = await _registry.forSavedConnection(
        _manager,
        connection.id,
        canUse: () => !_closed && generation == _generation,
      );
      if (_closed || generation != _generation) {
        return null;
      }
      // Navigation is admitted independently of durable preference settlement.
      // This typed receipt absorbs failures and uses the app's sole FIFO.
      _preferences.admitWorkspaceEntry(connection.id);
      if (_closed || generation != _generation) {
        return null;
      }
      return WorkspaceEntryPlan._(controller, this, generation, launchRevision);
    } catch (_) {
      if (!_closed && generation == _generation) {
        _error = 'Connection ownership could not be verified securely.';
      }
      return null;
    } finally {
      if (!_closed && generation == _generation) {
        _opening = false;
        _changed();
      }
    }
  }

  bool isCurrent(WorkspaceEntryPlan plan) =>
      !_closed &&
      identical(plan._owner, this) &&
      plan._generation == _generation;

  AndroidLaunchAction? takeLaunchAction(WorkspaceEntryPlan plan) {
    if (!isCurrent(plan) || plan._launchRevision != _launchRevision) {
      return null;
    }
    return _launcher?.takePendingAction();
  }

  @override
  void dispose() {
    if (_closed) {
      return;
    }
    _closed = true;
    _generation++;
    _remembered.removeListener(_changed);
    _launcher?.pendingAction.removeListener(_launchChanged);
    if (_notificationDepth == 0) {
      super.dispose();
    }
  }
}

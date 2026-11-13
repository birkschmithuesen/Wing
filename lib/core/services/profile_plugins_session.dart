import 'package:flutter/foundation.dart';
import '../models/profile_plugins.dart';
import 'administration_repository.dart';
import 'workspace_connection_failure.dart';

/// One captured profile's inventory and toggle workflow; no polling or journal.
class ProfilePluginsSession extends ChangeNotifier {
  ProfilePluginsSession(this._profile) {
    _profile.server.retain();
  }
  final ProfileAdministration _profile;
  String get scopeLabel => _profile.label;
  ProfilePluginsState _state = ProfilePluginsState(
    hasObservation: false,
    rows: const [],
    phase: ProfilePluginsPhase.idle,
    verified: false,
    error: null,
    retryable: false,
    acknowledgement: null,
    maintenance: null,
  );
  ProfilePluginsState get state => _state;
  bool _disposed = false;
  int _generation = 0, _notificationDepth = 0;
  bool get canRecover => !_disposed && !_state.busy && _state.retryable;
  bool _active(int generation) => !_disposed && generation == _generation;
  void _publish(ProfilePluginsState state) {
    if (_disposed) {
      return;
    }
    _state = state;
    _notificationDepth++;
    try {
      notifyListeners();
    } finally {
      _notificationDepth--;
      if (_disposed && _notificationDepth == 0) {
        super.dispose();
      }
    }
  }

  String _readError(Object error) => error is FormatException
      ? 'The server returned an invalid response.'
      : administrationError(error);
  Future<List<ProfilePlugin>> _read() async => ProfilePlugin.inventory(
    await _profile.rpc('plugins.manage', const {'action': 'list'}),
  );
  Future<void> refresh() async {
    if (_disposed || _state.busy) {
      return;
    }
    final generation = ++_generation;
    _profile.server.retain();
    final previous = _state;
    try {
      _publish(
        ProfilePluginsState(
          rows: previous.rows,
          hasObservation: previous.hasObservation,
          phase: ProfilePluginsPhase.loading,
          verified: false,
          error: null,
          retryable: false,
          acknowledgement: previous.acknowledgement,
          maintenance: previous.maintenance,
        ),
      );
      if (!_active(generation)) {
        return;
      }
      final rows = await _read();
      if (!_active(generation)) {
        return;
      }
      _publish(
        ProfilePluginsState(
          rows: rows,
          phase: ProfilePluginsPhase.idle,
          verified: true,
          hasObservation: true,
          error: null,
          retryable: false,
          acknowledgement: previous.acknowledgement,
          maintenance: previous.maintenance,
        ),
      );
    } catch (error) {
      if (!_active(generation)) {
        return;
      }
      _publish(
        ProfilePluginsState(
          rows: previous.rows,
          phase: ProfilePluginsPhase.idle,
          hasObservation: previous.hasObservation,
          verified: false,
          error: _readError(error),
          retryable: isTemporaryWorkspaceFailure(error),
          acknowledgement: previous.acknowledgement,
          maintenance: previous.maintenance,
        ),
      );
    } finally {
      _profile.server.release();
    }
  }

  Future<void> toggle(ProfilePlugin opening, bool enabled) async {
    if (_disposed ||
        !_state.canToggle ||
        !_state.rows.any((row) => identical(row, opening))) {
      return;
    }
    final generation = ++_generation;
    final previous = _state;
    var rows = previous.rows;
    var dispatched = false;
    ProfilePluginAcknowledgement? acknowledgement;
    _profile.server.retain();
    try {
      _publish(
        ProfilePluginsState(
          rows: rows,
          phase: ProfilePluginsPhase.saving,
          hasObservation: previous.hasObservation,
          verified: false,
          error: null,
          retryable: false,
          acknowledgement: previous.acknowledgement,
          maintenance: previous.maintenance,
        ),
      );
      if (!_active(generation)) {
        return;
      }
      rows = await _read();
      if (!_active(generation)) {
        return;
      }
      final current = rows.where((row) => row.key == opening.key).firstOrNull;
      if (current == null || !current.sameIdentity(opening)) {
        throw const AdministrationFailure(
          'Plugin inventory changed. Refresh to continue.',
        );
      }
      if (current.enabled != enabled) {
        if (current.status != opening.status) {
          throw const AdministrationFailure(
            'Plugin setting changed elsewhere. Refresh to continue.',
          );
        }
        await _profile.requireProfile();
        if (!_active(generation)) {
          return;
        }
        final response = await _profile.gateway.togglePlugin(
          opening.key,
          enabled,
          canDispatch: () => _active(generation),
          onDispatched: () => dispatched = true,
        );
        acknowledgement = ProfilePluginAcknowledgement.decode(
          response,
          opening.key,
          enabled,
        );
        if (!_active(generation)) {
          return;
        }
        rows = await _read();
        if (!_active(generation)) {
          return;
        }
        final after = rows.where((row) => row.key == opening.key).firstOrNull;
        if (after == null ||
            !after.sameIdentity(opening) ||
            after.enabled != enabled) {
          throw const AdministrationFailure(
            'Plugin change saved, but current settings differ. Refresh to continue.',
          );
        }
      }
      _publish(
        ProfilePluginsState(
          rows: rows,
          phase: ProfilePluginsPhase.idle,
          verified: true,
          hasObservation: true,
          error: null,
          retryable: false,
          acknowledgement: acknowledgement ?? previous.acknowledgement,
          maintenance: previous.maintenance,
        ),
      );
    } catch (error) {
      if (!_active(generation)) {
        return;
      }
      final message = acknowledgement != null
          ? error is AdministrationFailure
                ? error.message
                : 'Plugin change saved. Current inventory is unavailable; refresh to check it.'
          : dispatched
          ? 'Plugin change could not be confirmed. Refresh before trying again.'
          : _readError(error);
      _publish(
        ProfilePluginsState(
          rows: rows,
          phase: ProfilePluginsPhase.idle,
          verified: false,
          hasObservation: previous.hasObservation,
          error: message,
          retryable: false,
          acknowledgement: acknowledgement ?? previous.acknowledgement,
          maintenance: previous.maintenance,
        ),
      );
    } finally {
      _profile.server.release();
    }
  }

  Future<void> updateInstalled() async {
    if (_disposed || !_state.canUpdate) return;
    final generation = ++_generation;
    final previous = _state;
    var rows = previous.rows;
    var dispatched = false;
    PluginMaintenanceResult? result;
    _profile.server.retain();
    _publish(
      ProfilePluginsState(
        hasObservation: previous.hasObservation,
        rows: rows,
        phase: ProfilePluginsPhase.updating,
        verified: false,
        error: null,
        retryable: false,
        acknowledgement: previous.acknowledgement,
        maintenance: previous.maintenance,
      ),
    );
    try {
      if (!_active(generation)) return;
      await _profile.requireProfile();
      if (!_active(generation)) return;
      final response = await _profile.gateway.updateInstalledPlugins(
        canDispatch: () => _active(generation),
        onDispatched: () => dispatched = true,
      );
      result = PluginMaintenanceResult.decode(response);
      if (!_active(generation)) return;
      // Publish the received mixed outcome while retaining pending feedback
      // through readback. A later read failure must not erase this receipt.
      _publish(
        ProfilePluginsState(
          hasObservation: previous.hasObservation,
          rows: rows,
          phase: ProfilePluginsPhase.updating,
          verified: false,
          error: null,
          retryable: false,
          acknowledgement: previous.acknowledgement,
          maintenance: result,
        ),
      );
      if (!_active(generation)) return;
      rows = await _read();
      if (!_active(generation)) return;
      _publish(
        ProfilePluginsState(
          hasObservation: true,
          rows: rows,
          phase: ProfilePluginsPhase.idle,
          verified: true,
          error: null,
          retryable: false,
          acknowledgement: previous.acknowledgement,
          maintenance: result,
        ),
      );
    } catch (error) {
      if (!_active(generation)) return;
      _publish(
        ProfilePluginsState(
          hasObservation: previous.hasObservation,
          rows: rows,
          phase: ProfilePluginsPhase.idle,
          verified: false,
          error: result != null
              ? 'Update results received. Current inventory is unavailable; refresh to check it.'
              : dispatched
              ? 'Plugin updates could not be confirmed. Refresh before trying again.'
              : _readError(error),
          retryable: false,
          acknowledgement: previous.acknowledgement,
          maintenance: result ?? previous.maintenance,
        ),
      );
    } finally {
      _profile.server.release();
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation++;
    _profile.server.release();
    if (_notificationDepth == 0) {
      super.dispose();
    }
  }
}

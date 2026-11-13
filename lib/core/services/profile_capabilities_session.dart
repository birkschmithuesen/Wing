import 'package:flutter/foundation.dart';

import '../models/profile_capabilities.dart';
import 'profile_gateway.dart';
import 'skill_reader_session.dart';
import '../models/skill_reader.dart';

/// Captured-profile commands and detached observations for one capabilities route.
/// Borrows its gateway; retiring the route revokes dispatch, not the connection.
class ProfileCapabilitiesSession extends ChangeNotifier {
  SkillReaderSession reader(SkillReaderTarget document) =>
      _gateway.skillReader(document);
  ProfileCapabilitiesSession(ProfileGateway gateway) : _gateway = gateway;
  final ProfileGateway _gateway;
  String get profileName => _gateway.scope.profileName;

  ProfileCapabilitiesState _state = ProfileCapabilitiesState(
    hasObservation: false,
    kind: ProfileCapabilityKind.tools,
    rows: const [],
    loading: true,
    operation: ProfileCapabilitiesOperation.idle,
    verified: false,
    error: null,
    notice: null,
  );
  ProfileCapabilitiesState get state => _state;
  int _generation = 0;
  bool _disposed = false;
  int _notificationDepth = 0;

  void _publish({
    bool? hasObservation,
    ProfileCapabilityKind? kind,
    Iterable<ProfileCapability>? rows,
    bool? loading,
    ProfileCapabilitiesOperation? operation,
    bool? verified,
    required String? error,
    required String? notice,
  }) {
    if (_disposed) return;
    _state = ProfileCapabilitiesState(
      hasObservation: hasObservation ?? _state.hasObservation,
      kind: kind ?? _state.kind,
      rows: rows ?? _state.rows,
      loading: loading ?? _state.loading,
      operation: operation ?? _state.operation,
      verified: verified ?? _state.verified,
      error: error,
      notice: notice,
    );
    _notificationDepth++;
    try {
      notifyListeners();
    } finally {
      _notificationDepth--;
      if (_disposed && _notificationDepth == 0) super.dispose();
    }
  }

  Future<void> load(ProfileCapabilityKind kind) async {
    if (_disposed) return;
    final generation = ++_generation;
    final changedKind = kind != _state.kind;
    _publish(
      kind: kind,
      rows: changedKind ? const [] : null,
      hasObservation: changedKind ? false : null,
      loading: true,
      verified: false,
      error: null,
      notice: changedKind ? null : _state.notice,
    );
    if (_disposed) return;
    try {
      final result = await _gateway.read(
        kind == ProfileCapabilityKind.skills ? 'skills' : 'tools/toolsets',
      );
      final rows = ProfileCapability.decode(result, kind);
      if (_disposed || generation != _generation) return;
      _publish(
        rows: rows,
        hasObservation: true,
        loading: false,
        verified: true,
        error: null,
        notice: _state.notice,
      );
    } catch (_) {
      if (_disposed || generation != _generation) return;
      _publish(
        loading: false,
        error:
            'Could not load ${kind == ProfileCapabilityKind.skills ? 'skills' : 'tools'} from this profile. Check the connection and retry.',
        notice: _state.notice,
      );
    }
  }

  Future<void> toggle(
    ProfileCapabilityKind kind,
    String name,
    bool enabled, {
    required Future<bool> Function(ProfileCapability row) confirm,
  }) async {
    if (_disposed || !_state.canToggle || _state.kind != kind) return;
    final matches = _state.rows.where((row) => row.name == name);
    if (matches.length != 1) return;
    final row = matches.single;
    if (row.enabled == enabled) return;
    final generation = _generation;
    bool active() =>
        !_disposed && generation == _generation && kind == _state.kind;
    final needsConfirmation =
        kind == ProfileCapabilityKind.tools &&
        enabled &&
        row.needsEnableConfirmation;
    _publish(
      operation: needsConfirmation
          ? ProfileCapabilitiesOperation.confirming
          : ProfileCapabilitiesOperation.saving,
      error: needsConfirmation ? _state.error : null,
      notice: needsConfirmation ? _state.notice : null,
    );
    if (!active()) return;
    var dispatched = false;
    try {
      if (needsConfirmation) {
        if (!await confirm(row) || !active()) return;
        _publish(
          operation: ProfileCapabilitiesOperation.saving,
          error: null,
          notice: null,
        );
        if (!active()) return;
      }
      await _gateway.requireProfile();
      if (!active()) return;
      final result = await _gateway.putOwned(
        kind == ProfileCapabilityKind.skills
            ? 'skills/toggle'
            : 'tools/toolsets/${Uri.encodeComponent(name)}',
        {
          if (kind == ProfileCapabilityKind.skills) 'name': name,
          'enabled': enabled,
        },
        canDispatch: active,
        onDispatched: () => dispatched = true,
      );
      if (result['ok'] != true ||
          result['name'] != name ||
          result['enabled'] != enabled ||
          (kind == ProfileCapabilityKind.tools &&
              ((row.platform != null && result['platform'] != row.platform) ||
                  (result['post_setup_started'] != null &&
                      result['post_setup_started'] is! String)))) {
        throw const FormatException('The change was not acknowledged');
      }
      if (!active()) return;
      _publish(
        rows: _state.rows.map(
          (item) => item.name == name ? item.withEnabled(enabled) : item,
        ),
        error: null,
        notice: result['post_setup_started'] != null
            ? 'Saved. Hermes started server setup; refresh to check readiness.'
            : 'Saved on the server for $profileName.',
      );
      if (!_disposed) await load(kind);
    } catch (_) {
      if (!active()) return;
      _publish(
        verified: !dispatched && _state.verified,
        error: dispatched
            ? 'The change could not be confirmed. Refresh to check the server before trying again.'
            : 'The change was not sent. Check the connection and retry.',
        notice: null,
      );
    } finally {
      if (!_disposed) {
        _publish(
          operation: ProfileCapabilitiesOperation.idle,
          error: _state.error,
          notice: _state.notice,
        );
      }
    }
  }

  Future<ProfileSkillInstructions?> instructions(String name) async {
    if (_disposed) return null;
    final generation = _generation;
    final result = await _gateway.read('skills/content', {'name': name});
    if (_disposed || generation != _generation) return null;
    if (result['name'] != name || result['content'] is! String) {
      throw const FormatException('Invalid skill content');
    }
    return ProfileSkillInstructions(
      name: name,
      content: result['content'] as String,
      sourcePath: result['path'] is String ? result['path'] as String : null,
    );
  }

  Future<void> reviewSetup(
    String name,
    Future<void> Function(String name) open,
  ) async {
    if (_disposed ||
        _state.busy ||
        _state.kind != ProfileCapabilityKind.tools ||
        !_state.rows.any((row) => row.name == name)) {
      return;
    }
    final generation = _generation;
    await open(name);
    if (!_disposed && generation == _generation) {
      await load(ProfileCapabilityKind.tools);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    if (_notificationDepth == 0) super.dispose();
  }
}

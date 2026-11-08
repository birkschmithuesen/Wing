import 'package:flutter/foundation.dart';
import '../models/hermes_profile.dart';
import '../models/profile_plugins.dart';
import '../models/wing_plugin.dart';
import 'administration_repository.dart';
import 'wing_plugin_releases.dart';
import 'ws_client.dart';

/// One captured backend's Wing inventory and serial, explicit maintenance batch.
/// Reads and mutations use stock profile routing; GitHub only supplies availability.
class WingPluginSession extends ChangeNotifier {
  WingPluginSession(
    this.server, {
    Future<WingPluginRelease> Function()? readRelease,
  }) : _readRelease = readRelease ?? readWingPluginRelease {
    server.retain();
  }
  final AdministrationRepository server;
  final Future<WingPluginRelease> Function() _readRelease;
  List<WingPluginProfile> _profiles = const [];
  List<WingPluginProfile> get profiles => List.unmodifiable(_profiles);
  WingPluginRelease? _release;
  WingPluginRelease? get release => _release;
  String? _error, _releaseError;
  String? get error => _error;
  String? get releaseError => _releaseError;
  String? _activeProfile;
  String? get activeProfile => _activeProfile;
  bool _busy = false, _explicit = false, _updating = false;
  bool get busy => _busy;
  bool get explicitBusy => _busy && _explicit;
  bool get updating => _updating;
  bool _verified = false, _releaseVerified = false, _disposed = false;
  int _notifications = 0;
  bool get canApply =>
      !_disposed &&
      !_busy &&
      _verified &&
      _releaseVerified &&
      _profiles.any(
        (row) =>
            row.observed &&
            (row.plugin == null ||
                !row.plugin!.enabled ||
                _release!.needsUpdate(row.plugin!)),
      );

  void _notify() {
    if (_disposed) return;
    _notifications++;
    try {
      notifyListeners();
    } finally {
      _notifications--;
      if (_disposed && _notifications == 0) super.dispose();
    }
  }

  Future<ProfilePlugin?> _read(HermesProfile profile) async {
    final rows = ProfilePlugin.inventory(
      await server.profile(profile.name).rpc('plugins.manage', const {
        'action': 'list',
      }),
    );
    final matches = rows
        .where((row) => row.name == 'wing' || row.key == 'wing')
        .toList();
    if (matches.length > 1 ||
        matches.any((row) => row.name != 'wing' || row.key != 'wing')) {
      throw const AdministrationFailure(
        'Wing plugin identity is ambiguous. Review installed plugins in Hermes.',
      );
    }
    return matches.firstOrNull;
  }

  String _readError(Object error) => error is FormatException
      ? 'The server returned an invalid plugin response.'
      : administrationError(error);

  Future<void> refresh({bool explicit = true}) async {
    if (_disposed || _busy) return;
    _busy = true;
    _explicit = explicit;
    _verified = false;
    _releaseVerified = false;
    _error = null;
    _releaseError = null;
    server.retain();
    try {
      _notify();
      if (_disposed) return;
      await Future.wait([_refreshRelease(), _refreshProfiles()]);
    } finally {
      if (!_disposed) {
        _busy = false;
        _notify();
      }
      server.release();
    }
  }

  Future<void> _refreshRelease() async {
    try {
      final release = await _readRelease();
      if (_disposed) return;
      _release = release;
      _releaseVerified = true;
    } catch (_) {
      if (!_disposed) {
        _releaseError =
            'Could not check GitHub releases. Refresh to try again.';
      }
    }
    _notify();
  }

  Future<void> _refreshProfiles() async {
    try {
      final discovery = await server.discover();
      if (_disposed) return;
      final old = {for (final row in _profiles) row.profile.name: row};
      _profiles = [
        for (final profile in discovery.profiles)
          WingPluginProfile(
            profile: profile,
            plugin: old[profile.name]?.plugin,
            observed: old[profile.name]?.observed ?? false,
          ),
      ];
      _notify();
      for (final profile in discovery.profiles) {
        if (_disposed) return;
        try {
          final plugin = await _read(profile);
          if (_disposed) return;
          _put(
            WingPluginProfile(profile: profile, plugin: plugin, observed: true),
          );
        } catch (error) {
          if (_disposed) return;
          _put(
            WingPluginProfile(
              profile: profile,
              plugin: old[profile.name]?.plugin,
              observed: old[profile.name]?.observed ?? false,
              error: _readError(error),
            ),
          );
        }
      }
      _verified = _profiles.every((row) => row.error == null);
    } catch (error) {
      if (!_disposed) _error = _readError(error);
    }
    _notify();
  }

  void _put(WingPluginProfile row) {
    if (_disposed) return;
    _profiles = [
      for (final old in _profiles)
        old.profile.name == row.profile.name ? row : old,
    ];
    _notify();
  }

  Future<void> applyToAll() async {
    if (!canApply) return;
    final target = _release!;
    _busy = true;
    _explicit = true;
    _updating = true;
    _verified = false;
    _error = null;
    server.retain();
    try {
      _notify();
      if (_disposed) return;
      final discovery = await server.discover();
      if (_disposed) return;
      final old = {for (final row in _profiles) row.profile.name: row};
      _profiles = [
        for (final profile in discovery.profiles)
          WingPluginProfile(
            profile: profile,
            plugin: old[profile.name]?.plugin,
            observed: old[profile.name]?.observed ?? false,
          ),
      ];
      for (final profile in discovery.profiles) {
        if (_disposed) return;
        _activeProfile = profile.label;
        _notify();
        if (_disposed) return;
        await _apply(profile, target);
      }
      // An uncertain result requires an inventory refresh before another write.
      // Verified success needs no additional user step.
      _verified = _profiles.every((row) => row.error == null);
    } catch (error) {
      if (!_disposed) _error = _readError(error);
    } finally {
      if (!_disposed) {
        _busy = false;
        _updating = false;
        _activeProfile = null;
        _notify();
      }
      server.release();
    }
  }

  Future<void> _apply(HermesProfile profile, WingPluginRelease target) async {
    final owner = server.profile(profile.name);
    ProfilePlugin? current;
    var observed = false, dispatched = false, acknowledged = false;
    var changed = false, restart = false, readingBack = false;
    try {
      // Re-read after every previous profile: installations can be shared.
      current = await _read(profile);
      observed = true;
      if (_disposed) return;
      _put(
        WingPluginProfile(profile: profile, plugin: current, observed: true),
      );
      if (_disposed) return;
      if (current == null || target.needsUpdate(current)) {
        await owner.requireProfile();
        if (_disposed) return;
        final response = current == null
            ? await owner.gateway.installPlugin(
                WingPluginRelease.repository,
                canDispatch: () => !_disposed,
                onDispatched: () => dispatched = true,
              )
            : await owner.gateway.updatePlugin(
                current.key,
                canDispatch: () => !_disposed,
                onDispatched: () => dispatched = true,
              );
        if (_disposed) return;
        if (response['ok'] == false) {
          final details = response['delta_lines'] is List
              ? (response['delta_lines'] as List).whereType<String>().join('\n')
              : '';
          throw AdministrationFailure(
            '${response['error'] ?? 'Update needs review in Hermes.'}${details.isEmpty ? '' : '\n$details'}',
          );
        }
        final name = current == null
            ? response['plugin_name']
            : response['name'];
        if (response['ok'] != true || name != 'wing') {
          throw const FormatException('Wing update was not acknowledged');
        }
        acknowledged = true;
        changed = true;
        restart = response['restart_required'] == true;
        readingBack = true;
        current = await _read(profile);
        readingBack = false;
        if (_disposed) return;
      }
      if (current == null) {
        throw const AdministrationFailure(
          'Wing is still missing after installation. Refresh to check.',
        );
      }
      if (!current.enabled) {
        await owner.requireProfile();
        if (_disposed) return;
        acknowledged = false;
        dispatched = false;
        final response = await owner.gateway.togglePlugin(
          current.key,
          true,
          canDispatch: () => !_disposed,
          onDispatched: () => dispatched = true,
        );
        if (_disposed) return;
        final receipt = ProfilePluginAcknowledgement.decode(
          response,
          current.key,
          true,
        );
        acknowledged = true;
        changed = true;
        restart = restart || receipt.restartRequired;
        readingBack = true;
        current = await _read(profile);
        readingBack = false;
        if (_disposed) return;
      }
      if (current == null || !current.enabled) {
        throw const AdministrationFailure(
          'Wing enablement could not be verified. Refresh to check.',
        );
      }
      if (target.needsUpdate(current)) {
        throw const AdministrationFailure(
          'Installed version is still behind the GitHub release. Review the plugin source or pin in Hermes.',
        );
      }
      _put(
        WingPluginProfile(
          profile: profile,
          plugin: current,
          observed: true,
          result: restart
              ? 'Updated. Restart Hermes to finish activation.'
              : changed
              ? 'Use a new chat for updated tools.'
              : 'Already up to date.',
        ),
      );
    } catch (error) {
      if (_disposed) return;
      final definite =
          error is AdministrationFailure ||
          (error is JsonRpcError && error.code != null);
      final message = readingBack
          ? 'Change accepted, but verification failed. Refresh to check the installed version.'
          : definite
          ? (error is JsonRpcError
                ? 'Hermes refused the change. Review the Wing plugin in Hermes, then refresh.'
                : _readError(error))
          : acknowledged
          ? 'Change accepted, but verification failed. Refresh to check the installed version.'
          : dispatched
          ? 'Update outcome is unknown. Refresh before trying again.'
          : _readError(error);
      _put(
        WingPluginProfile(
          profile: profile,
          plugin: current,
          observed: observed,
          error: message,
        ),
      );
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    server.release();
    if (_notifications == 0) super.dispose();
  }
}

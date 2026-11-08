import 'package:flutter/foundation.dart';
import '../models/hermes_profile.dart';
import '../models/profile_plugins.dart';
import '../models/wing_plugin.dart';
import 'administration_repository.dart';
import 'mcp_error.dart';
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
  String? _activeProfile, _operationProfileName;
  String? get operationProfileLabel =>
      _operationProfileName == null ? null : _activeProfile;
  String? get activeProfile => _activeProfile;
  bool _busy = false, _explicit = false, _updating = false;
  bool get busy => _busy;
  bool get explicitBusy => _busy && _explicit;
  bool get updating => _updating;
  bool _verified = false, _releaseVerified = false, _disposed = false;
  int _notifications = 0;
  bool get _canMaintain => !_disposed && !_busy && _releaseVerified;
  bool _needsChange(WingPluginProfile row) =>
      row.observed &&
      row.error == null &&
      (row.plugin == null ||
          !row.plugin!.enabled ||
          _release!.needsUpdate(row.plugin!));
  bool get canApply => _canMaintain && _verified && _profiles.any(_needsChange);
  bool canApplyTo(String profileName) =>
      _canMaintain &&
      _error == null &&
      _profiles.any(
        (row) => row.profile.name == profileName && _needsChange(row),
      );
  bool _canApplyScope(String? name) =>
      name == null ? canApply : canApplyTo(name);

  WingPluginRelease? _reviewRelease;
  WingPluginRelease? get reviewRelease => _reviewRelease;
  String? _reviewProfileName;
  String? get reviewProfileName => _reviewProfileName;
  String? get reviewProfileLabel => _profiles
      .where((row) => row.profile.name == _reviewProfileName)
      .firstOrNull
      ?.profile
      .label;
  bool get canConfirmReview =>
      _reviewRelease != null && _canApplyScope(_reviewProfileName);
  WingPluginOverview get overview => WingPluginOverview.fromProfiles(
    _profiles,
    _release,
    checking: _busy,
    updating: _updating,
    unavailable: _error != null || _releaseError != null,
  );
  String get progressLabel => _updating
      ? 'Updating Wing plugin in ${_activeProfile ?? 'all profiles'}'
      : 'Checking Wing plugin versions';

  /// The explicit action presents pin replacement in the manager before writing.
  Future<void> requestApply({String? profileName}) async {
    if (_reviewRelease != null || !_canApplyScope(profileName)) return;
    if (_hasPinnedUpdates(profileName)) {
      _reviewProfileName = profileName;
      _reviewRelease = _release;
      _notify();
      return;
    }
    await _applyScope(profileName);
  }

  void cancelReview() {
    if (_disposed || _busy) return;
    _reviewRelease = null;
    _reviewProfileName = null;
    _notify();
  }

  Future<void> confirmPinnedUpdate() async {
    if (!canConfirmReview) return;
    final approved = _reviewRelease;
    final profileName = _reviewProfileName;
    _reviewRelease = null;
    _reviewProfileName = null;
    await _applyScope(profileName, approvedPinnedRelease: approved);
  }

  bool get hasPinnedUpdates => _hasPinnedUpdates(null);
  bool _hasPinnedUpdates(String? profileName) =>
      _release != null &&
      _profiles.any(
        (row) =>
            (profileName == null || row.profile.name == profileName) &&
            row.plugin != null &&
            row.plugin!.pinnedSha?.isNotEmpty == true &&
            _release!.needsUpdate(row.plugin!),
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
    _reviewRelease = null;
    _reviewProfileName = null;
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

  Future<void> applyToAll({WingPluginRelease? approvedPinnedRelease}) =>
      _applyScope(null, approvedPinnedRelease: approvedPinnedRelease);

  Future<void> _applyScope(
    String? profileName, {
    WingPluginRelease? approvedPinnedRelease,
  }) async {
    if (!_canApplyScope(profileName)) return;
    if (approvedPinnedRelease != null &&
        !identical(_release, approvedPinnedRelease)) {
      _error = 'The release changed. Review the update again.';
      _notify();
      return;
    }
    final target = _release!;
    _busy = true;
    _explicit = true;
    _updating = true;
    _operationProfileName = profileName;
    _activeProfile = profileName == null
        ? null
        : _profiles
              .firstWhere((row) => row.profile.name == profileName)
              .profile
              .label;
    _verified = false;
    _error = null;
    server.retain();
    try {
      _notify();
      if (_disposed) return;
      final discovery = await server.discover();
      if (_disposed) return;
      final selected = discovery.profiles
          .where(
            (profile) => profileName == null || profile.name == profileName,
          )
          .toList();
      if (profileName != null && selected.isEmpty) {
        throw const AdministrationFailure(
          'This profile is no longer available. Refresh to check.',
        );
      }
      final old = {for (final row in _profiles) row.profile.name: row};
      _profiles = [
        for (final profile in discovery.profiles)
          if (profileName != null &&
              profile.name != profileName &&
              old.containsKey(profile.name))
            old[profile.name]!
          else
            WingPluginProfile(
              profile: profile,
              plugin: old[profile.name]?.plugin,
              observed: old[profile.name]?.observed ?? false,
            ),
      ];
      for (final profile in selected) {
        if (_disposed) return;
        _activeProfile = profile.label;
        _notify();
        if (_disposed) return;
        await _apply(profile, target, identical(target, approvedPinnedRelease));
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
        _operationProfileName = null;
        _notify();
      }
      server.release();
    }
  }

  Future<void> _apply(
    HermesProfile profile,
    WingPluginRelease target,
    bool replacePinned,
  ) async {
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
        final pinned = current?.pinnedSha?.isNotEmpty == true;
        if (pinned && !replacePinned) {
          throw const AdministrationFailure(
            'This Wing version is pinned. Refresh, then choose Install or update to review its replacement.',
          );
        }
        final installing = current == null || pinned;
        final response = installing
            ? await owner.gateway.installPlugin(
                WingPluginRelease.repository,
                ref: target.commitSha,
                replaceExisting: pinned,
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
            mcpErrorMessage(
              '${response['error'] ?? 'Update needs review in Hermes.'}${details.isEmpty ? '' : '\n$details'}',
              summary: 'Hermes refused the change.',
            ),
          );
        }
        final name = installing ? response['plugin_name'] : response['name'];
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
        if (installing && current?.pinnedSha != target.commitSha) {
          throw const AdministrationFailure(
            'Installed commit does not match the GitHub release. Refresh to check.',
          );
        }
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
                ? mcpErrorMessage(
                    error.message,
                    summary: 'Hermes refused the change.',
                  )
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

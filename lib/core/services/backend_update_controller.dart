import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/backend_update.dart';
import 'profile_gateway.dart';
import 'backend_update_channels.dart';
import 'workspace_connection_failure.dart';

class BackendUpdateController extends ChangeNotifier {
  final ProfileGateway gateway;
  final bool cloudManaged;

  BackendUpdateCheck? check;
  BackendUpdateChannel? channel;
  bool channelSaving = false;
  late final _channels = BackendUpdateChannels(
    gateway,
    readHealth: _readHealth,
  );
  Future<Map<String, dynamic>>? _healthRead;
  Future<void>? _availabilityRead;

  Future<Map<String, dynamic>> _readHealth() async {
    final request = _healthRead ??= gateway.read('health');
    try {
      return await request;
    } finally {
      if (identical(_healthRead, request)) _healthRead = null;
    }
  }

  String? installedVersion;
  bool versionLoading = false;
  bool versionStale = false;

  BackendUpdateStatus? status;
  BackendUpdatePhase phase = BackendUpdatePhase.idle;
  String? message;
  bool checking = false;
  bool starting = false;
  bool statusLoading = false;

  bool _disposed = false;
  bool _requestOutstanding = false;
  int _versionObservation = 0;
  int _checkGeneration = 0;
  int _statusGeneration = 0;
  Timer? _statusPoll;
  Future<void>? _statusRead;
  int updateAttempt = 0;
  String? _actionId;
  int? _actionPid;

  BackendUpdateController(this.gateway, {this.cloudManaged = false});

  bool get requestOutstanding => _requestOutstanding;
  bool get canStart =>
      !cloudManaged &&
      !checking &&
      !statusLoading &&
      !channelSaving &&
      !starting &&
      !_requestOutstanding &&
      phase != BackendUpdatePhase.running &&
      check?.canStart == true &&
      channel?.error == null &&
      channel?.targetSha != null;

  bool get canOpenChannelEditor =>
      !cloudManaged &&
      !statusLoading &&
      !starting &&
      !channelSaving &&
      !_requestOutstanding &&
      phase != BackendUpdatePhase.running &&
      check?.canApply != false &&
      channel?.canSelect != false;

  bool get canSelectChannel =>
      canOpenChannelEditor &&
      !checking &&
      check?.canApply == true &&
      channel?.canSelect == true;

  Future<(BackendUpdateCheck, BackendUpdateChannel?)> _readUpdateCheck() async {
    return _channels.check();
  }

  void _publishCheck(BackendUpdateCheck next, BackendUpdateChannel? track) {
    check = next;
    channel = track;
    if (next.currentVersion case final version?) {
      _versionObservation++;
      installedVersion = version;
      versionStale = false;
    }
    final identityMissing = next.canApply == true && track == null;
    phase = next.failed || identityMissing || track?.error != null
        ? BackendUpdatePhase.unknown
        : BackendUpdatePhase.ready;
    message = next.failed
        ? next.message ?? 'Update availability could not be checked. Try again.'
        : identityMissing
        ? 'The update channel could not be verified. Check for updates again.'
        : track?.error != null
        ? 'The ${track!.name} channel could not be checked. Try again.'
        : next.behind == 0
        ? null
        : next.message;
  }

  /// Installed identity must not wait for the host's remote GitHub comparison.
  Future<void> _readInstalledVersion() async {
    if (versionLoading || _disposed) return;
    final observation = _versionObservation;
    versionLoading = true;
    _notify();
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final health = await _readHealth().timeout(
            const Duration(seconds: 5),
          );
          if (_disposed || observation != _versionObservation) return;
          final version = health['version'];
          if (health['ok'] != true ||
              version is! String ||
              version.trim().isEmpty) {
            throw const FormatException('Missing server version');
          }
          _versionObservation++;
          installedVersion = version.trim();
          versionStale = false;
          return;
        } catch (error) {
          if (_disposed || observation != _versionObservation) return;
          if (attempt == 1 || !isTemporaryWorkspaceFailure(error)) {
            versionStale = installedVersion != null;
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
          if (_disposed || observation != _versionObservation) return;
        }
      }
    } finally {
      if (!_disposed) {
        versionLoading = false;
        _notify();
      }
    }
  }

  Future<void> checkForUpdate() {
    if (cloudManaged) {
      return _readInstalledVersion();
    }
    if (channelSaving ||
        starting ||
        _requestOutstanding ||
        phase == BackendUpdatePhase.running ||
        _disposed) {
      return Future.value();
    }
    return _availabilityRead ??= _refreshAvailability();
  }

  Future<void> _refreshAvailability() async {
    try {
      await Future.wait([_readInstalledVersion(), _checkForUpdate()]);
    } finally {
      _availabilityRead = null;
    }
  }

  Future<void> _checkForUpdate() async {
    if (checking ||
        channelSaving ||
        starting ||
        _requestOutstanding ||
        phase == BackendUpdatePhase.running) {
      return;
    }
    final generation = ++_checkGeneration;
    checking = true;
    _notify();
    try {
      final (next, track) = await _readUpdateCheck();
      if (!_currentCheck(generation)) return;
      _publishCheck(next, track);
    } catch (_) {
      if (!_currentCheck(generation)) return;
      check = null;
      channel = null;
      phase = BackendUpdatePhase.unknown;
      message = 'Update availability could not be checked. Try again.';
    } finally {
      if (_currentCheck(generation)) {
        checking = false;
        _notify();
      }
    }
  }

  Future<bool> startUpdate({
    required BackendUpdateChannel approvedChannel,
    required bool Function() canDispatch,
  }) async {
    if (cloudManaged ||
        _disposed ||
        !canDispatch() ||
        channelSaving ||
        starting ||
        _requestOutstanding ||
        phase == BackendUpdatePhase.running) {
      return false;
    }
    final generation = ++_checkGeneration;
    updateAttempt++;
    _statusPoll?.cancel();
    _statusGeneration++;
    _statusRead = null;
    statusLoading = false;
    status = null;
    _actionId = null;
    _actionPid = null;
    starting = true;
    checking = false;
    phase = BackendUpdatePhase.starting;
    message = null;
    _notify();
    var posted = false;
    try {
      final (fresh, track) = await _readUpdateCheck();
      if (!_currentCheck(generation)) return false;
      if (!canDispatch()) {
        phase = BackendUpdatePhase.refused;
        message =
            'This update action is no longer active. Nothing was started.';
        return false;
      }
      _publishCheck(fresh, track);
      if (track == null || !approvedChannel.sameUpdateIntent(track)) {
        phase = BackendUpdatePhase.refused;
        message = track == null
            ? 'The update channel could not be verified. Nothing was started.'
            : 'The update channel or target changed. Review it before updating.';
        return false;
      }
      if (!fresh.canStart ||
          fresh.failed ||
          track.error != null ||
          track.targetSha == null) {
        phase = BackendUpdatePhase.refused;
        message = fresh.failed
            ? fresh.message ??
                  'Update availability could not be checked. Nothing was started.'
            : fresh.canApply != true
            ? 'This server did not confirm that updates can be applied from the app.'
            : 'The server reports no update is available.';
        return false;
      }

      phase = BackendUpdatePhase.starting;

      final response = await gateway.postOwned(
        'hermes/update',
        const {},
        canDispatch: () => _currentCheck(generation) && canDispatch(),
        onDispatched: () {
          _requestOutstanding = true;
          posted = true;
        },
      );
      if (!_currentCheck(generation)) return false;
      if (response['ok'] == false) {
        _requestOutstanding = false;
        phase = BackendUpdatePhase.refused;
        message = 'The server refused to start the backend update.';
        return false;
      }
      if (response['ok'] != true) {
        phase = BackendUpdatePhase.unknown;
        message = 'The server response did not confirm the update request.';
        return false;
      }
      final name = response['name'];
      final pid = response['pid'];
      final rawActionId = response['action_id'];
      final alreadyRunning = response['already_running'] == true;
      if (name != 'hermes-update' ||
          pid is! int ||
          pid <= 0 ||
          rawActionId is! String ||
          rawActionId.trim().isEmpty) {
        phase = BackendUpdatePhase.unknown;
        message =
            'The server started an update but did not return its identity.';
        return false;
      }
      _actionId = rawActionId;
      _actionPid = pid;
      status = null;
      phase = BackendUpdatePhase.running;
      message = alreadyRunning
          ? 'A backend update is already running on this host. Its status is now tracked.'
          : 'Backend update started. Following update progress.';
      return true;
    } catch (_) {
      if (!_currentCheck(generation)) return false;
      phase = BackendUpdatePhase.unknown;
      message = posted
          ? 'The update request could not be confirmed. Check status before trying again.'
          : 'Update eligibility could not be confirmed. Nothing was started.';
      return false;
    } finally {
      if (_currentCheck(generation)) {
        starting = false;
        _notify();
        if (phase == BackendUpdatePhase.running) {
          _statusPoll = Timer(
            Duration.zero,
            () => unawaited(refreshStatus(background: true)),
          );
        }
      }
    }
  }

  Future<bool> selectChannel(
    String name,
    BackendUpdateChannel approved, {
    required bool Function() canDispatch,
  }) async {
    if (_disposed ||
        !canDispatch() ||
        !canSelectChannel ||
        name == channel?.name ||
        !{'stable', 'main'}.contains(name)) {
      return false;
    }
    final generation = ++_checkGeneration;
    channelSaving = true;
    message = null;
    _notify();
    var saved = false;
    try {
      final (fresh, track) = await _readUpdateCheck();
      if (!_currentCheck(generation) || !canDispatch()) return false;
      _publishCheck(fresh, track);
      if (fresh.canApply != true ||
          track == null ||
          !track.canSelect ||
          !approved.sameInstallation(track) ||
          approved.name != track.name ||
          approved.branch != track.branch) {
        message = 'The server update channel changed. Review it before saving.';
        return false;
      }
      await _channels.save(
        track,
        name,
        canDispatch: () => _currentCheck(generation) && canDispatch(),
      );
      if (!_currentCheck(generation)) return false;
      saved = true;
      check = null;
      channel = null;
      final (next, nextTrack) = await _readUpdateCheck();
      if (!_currentCheck(generation)) return false;
      _publishCheck(next, nextTrack);
      if (nextTrack?.name != name) {
        phase = BackendUpdatePhase.unknown;
        message =
            'The $name channel was saved, but its update check could not be confirmed. Check again.';
      }
      return true;
    } catch (_) {
      if (!_currentCheck(generation)) return false;
      check = null;
      channel = null;
      phase = BackendUpdatePhase.unknown;
      message = saved
          ? 'The $name channel was saved, but its update check failed. Check again.'
          : 'The channel save could not be confirmed. Try again.';
      return false;
    } finally {
      if (_currentCheck(generation)) {
        channelSaving = false;
        _notify();
      }
    }
  }

  Future<void> refreshStatus({bool background = false}) {
    if (cloudManaged || _disposed || starting || channelSaving) {
      return Future.value();
    }
    if (!background && !statusLoading) {
      statusLoading = true;
      _notify();
    }
    return _statusRead ??= _refreshStatus(background: background);
  }

  Future<void> _refreshStatus({required bool background}) async {
    _statusPoll?.cancel();
    final generation = ++_statusGeneration;
    statusLoading = !background;
    _notify();
    try {
      final next = BackendUpdateStatus.fromJson(
        await gateway.read('actions/hermes-update/status'),
      );
      if (!_currentStatus(generation)) return;
      if (next == null) throw const FormatException('Invalid update status');
      status = next;
      await _applyStatus(next, generation);
    } catch (_) {
      if (!_currentStatus(generation)) return;
      phase = BackendUpdatePhase.unknown;
      message = 'Backend update status is unavailable. Check again.';
    } finally {
      if (_currentStatus(generation)) {
        _statusRead = null;
        statusLoading = false;
        _notify();
        if (phase == BackendUpdatePhase.running) {
          _statusPoll = Timer(
            const Duration(seconds: 2),
            () => unawaited(refreshStatus(background: true)),
          );
        }
      }
    }
  }

  Future<void> _applyStatus(BackendUpdateStatus next, int generation) async {
    final actionId = _actionId;
    final pid = _actionPid;
    if (actionId == null && pid == null) {
      if (next.running) {
        phase = BackendUpdatePhase.running;
        message = 'A backend update is running on this host.';
      } else if (_requestOutstanding) {
        phase = BackendUpdatePhase.unknown;
        message =
            'This update request is still unconfirmed. Check the server before trying again.';
      } else {
        final receipt = await _readReceipt(generation);
        if (!_currentStatus(generation)) return;
        if (receipt == null) {
          phase = BackendUpdatePhase.unknown;
          message = 'No completed backend update could be confirmed.';
        } else {
          _applyOutcome(receipt.outcome, prefix: 'Last recorded update');
        }
      }
      return;
    }
    final exactAction = actionId != null && next.actionId == actionId;
    final samePid = pid != null && next.pid == pid;
    if (next.running) {
      if (samePid && (next.actionId == null || exactAction)) {
        phase = BackendUpdatePhase.running;
        message = 'Backend update is running on this host.';
      } else {
        phase = BackendUpdatePhase.unknown;
        message = 'The returned live status has a different update identity.';
      }
      return;
    }
    final sameProcessExit =
        next.actionId == null && samePid && next.exitCode != null;
    if (!exactAction && !sameProcessExit) {
      phase = BackendUpdatePhase.unknown;
      message = 'The returned status belongs to a different update.';
      return;
    }
    String? outcome;
    if (pid != null) {
      final receipt = await _readReceipt(generation);
      if (!_currentStatus(generation)) return;
      if (receipt?.pid == pid) outcome = receipt?.outcome;
    }
    _requestOutstanding = false;
    if (outcome != null) {
      _applyOutcome(outcome);
    } else if (next.exitCode != null && next.exitCode != 0) {
      phase = BackendUpdatePhase.failed;
      message = 'The backend update failed.';
    } else if (next.exitCode == 0) {
      phase = BackendUpdatePhase.unknown;
      message =
          'The update command exited successfully, but the full update outcome is unavailable.';
    } else {
      phase = BackendUpdatePhase.unknown;
      message = 'The update stopped without a confirmed outcome.';
    }
  }

  Future<BackendUpdateReceipt?> _readReceipt(int generation) async {
    try {
      final envelope = await gateway.read('hermes/update/receipt');
      if (!_currentStatus(generation)) return null;
      return BackendUpdateReceipt.fromJson(envelope['receipt']);
    } catch (_) {
      return null;
    }
  }

  void _applyOutcome(String outcome, {String? prefix}) {
    final lead = prefix ?? 'The backend update';
    if (outcome == 'partial') {
      phase = BackendUpdatePhase.partial;
      message = '$lead completed only partially.';
    } else if (outcome == 'refused') {
      phase = BackendUpdatePhase.refused;
      message = '$lead was refused.';
    } else if (outcome == 'failed') {
      phase = BackendUpdatePhase.failed;
      message = '$lead failed.';
    } else if (outcome == 'success') {
      phase = BackendUpdatePhase.succeeded;
      message = '$lead completed successfully.';
    } else {
      phase = BackendUpdatePhase.unknown;
      message = '$lead has an unknown outcome.';
    }
  }

  bool _currentCheck(int generation) =>
      !_disposed && generation == _checkGeneration;

  bool _currentStatus(int generation) =>
      !_disposed && generation == _statusGeneration;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _statusPoll?.cancel();
    _checkGeneration++;
    _statusGeneration++;
    super.dispose();
  }
}

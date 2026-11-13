import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/backend_update.dart';
import 'profile_gateway.dart';
import 'backend_update_channels.dart';
import 'backend_update_store.dart';
import 'workspace_connection_failure.dart';

class BackendUpdateController extends ChangeNotifier {
  final ProfileGateway gateway;
  final bool cloudManaged;
  final BackendUpdateStore store;

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
  bool get _requestOutstanding => store.current != null;
  int _versionObservation = 0;
  int _checkGeneration = 0;
  int _statusGeneration = 0;
  Timer? _statusPoll;
  Future<void>? _statusRead;
  int updateAttempt = 0;
  Future<bool>? _trackingRead;
  int _statusFailures = 0;
  String? _observedRequestId;

  BackendUpdateController(
    this.gateway, {
    required this.store,
    this.cloudManaged = false,
  }) {
    if (!cloudManaged) {
      store.addListener(_trackingChanged);
      if (store.loaded) {
        _trackingChanged();
      } else {
        unawaited(_loadTracking());
      }
    }
  }

  bool get trackingLoading => !cloudManaged && _trackingRead != null;

  Future<bool> _loadTracking() =>
      store.loaded ? Future.value(true) : _trackingRead ??= _restoreTracking();

  Future<bool> _restoreTracking() async {
    try {
      await store.load();
      if (_disposed) return false;
      _trackingChanged();
      return true;
    } catch (_) {
      if (!_disposed) {
        phase = BackendUpdatePhase.unknown;
        message =
            'Saved update tracking could not be read. Check progress to retry.';
      }
      return false;
    } finally {
      _trackingRead = null;
      _notify();
    }
  }

  void _trackingChanged() {
    if (_disposed) return;
    final attempt = store.current;
    if (attempt != null) {
      if (_observedRequestId != attempt.requestId) {
        _observedRequestId = attempt.requestId;
        if (!starting) {
          updateAttempt++;
          _retireStatusRead();
        }
        status = null;
        if (installedVersion == null) unawaited(_readInstalledVersion());
      }
      phase = starting && attempt.actionId == null
          ? BackendUpdatePhase.starting
          : attempt.actionId == null
          ? BackendUpdatePhase.unknown
          : BackendUpdatePhase.running;
      message = starting && attempt.actionId == null
          ? null
          : attempt.actionId == null
          ? 'Update outcome not yet confirmed.'
          : 'Update ongoing';
      if (!starting) _scheduleStatus(Duration.zero);
    } else if (store.completed case final receipt?) {
      _retireStatusRead();
      check = null;
      channel = null;
      _applyOutcome(receipt.outcome);
      unawaited(_readInstalledVersion());
    } else if (_observedRequestId != null) {
      _retireStatusRead();
      _observedRequestId = null;
      phase = check == null
          ? BackendUpdatePhase.idle
          : BackendUpdatePhase.ready;
      message = null;
    }
    _notify();
  }

  void _scheduleStatus(Duration delay) {
    _statusPoll?.cancel();
    if (_disposed) return;
    _statusPoll = Timer(
      delay,
      () => unawaited(refreshStatus(background: true)),
    );
  }

  void _retireStatusRead() {
    _statusPoll?.cancel();
    _statusGeneration++;
    _statusRead = null;
    statusLoading = false;
  }

  bool get requestOutstanding => _requestOutstanding;
  bool get canStart =>
      !cloudManaged &&
      store.loaded &&
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
      store.loaded &&
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
    if (_requestOutstanding) return;
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

  Future<void> checkForUpdate() async {
    if (cloudManaged) {
      return _readInstalledVersion();
    }
    if (!await _loadTracking() || _disposed) return;
    if (_requestOutstanding) return refreshStatus();
    if (channelSaving ||
        starting ||
        _requestOutstanding ||
        phase == BackendUpdatePhase.running ||
        _disposed) {
      return;
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
    final observedRequestId = _observedRequestId;
    checking = true;
    _notify();
    try {
      final (next, track) = await _readUpdateCheck();
      if (!_currentCheck(generation) ||
          _observedRequestId != observedRequestId) {
        return;
      }
      _publishCheck(next, track);
    } catch (_) {
      if (!_currentCheck(generation) ||
          _observedRequestId != observedRequestId) {
        return;
      }
      if (_requestOutstanding) return;
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
    if (!cloudManaged && (!await _loadTracking() || _disposed)) return false;
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
    _retireStatusRead();
    status = null;
    starting = true;
    checking = false;
    phase = BackendUpdatePhase.starting;
    message = null;
    _notify();
    var posted = false;
    BackendUpdateAttempt? attempt;
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

      attempt = BackendUpdateAttempt(
        requestId: const Uuid().v4(),
        installId: track.installId,
        installPath: track.installPath,
        home: track.home,
        targetSha: track.targetSha!,
        startedAt: DateTime.now().toUtc(),
      );
      if (!await store.reserve(attempt)) return false;

      final response = await gateway.postOwned(
        'hermes/update',
        const {},
        canDispatch: () =>
            _currentCheck(generation) &&
            canDispatch() &&
            store.current?.requestId == attempt?.requestId,
        onDispatched: () {
          posted = true;
        },
      );
      if (response['ok'] == false) {
        await store.clear(attempt.requestId);
        if (!_currentCheck(generation)) return false;
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
      // Acceptance must survive departure while the physical request is held.
      await store.accept(attempt.requestId, rawActionId, pid);
      if (!_currentCheck(generation)) return false;
      status = null;
      phase = BackendUpdatePhase.running;
      message = alreadyRunning
          ? 'Update ongoing. Following the existing update.'
          : 'Update ongoing';
      return true;
    } catch (_) {
      if (!_currentCheck(generation)) return false;
      if (posted &&
          store.current?.requestId == attempt?.requestId &&
          store.current?.actionId != null) {
        phase = BackendUpdatePhase.running;
        message = 'Update ongoing. Saved tracking will be retried.';
        return true;
      }
      phase = BackendUpdatePhase.unknown;
      message = posted
          ? 'Update outcome not yet confirmed.'
          : 'Update eligibility could not be confirmed. Nothing was started.';
      return false;
    } finally {
      if (!posted && attempt != null) {
        try {
          await store.clear(attempt.requestId);
        } catch (_) {
          if (!_disposed) {
            phase = BackendUpdatePhase.unknown;
            message =
                'Saved update tracking could not be cleared. Check progress to retry.';
          }
        }
      }
      if (_currentCheck(generation)) {
        starting = false;
        _notify();
        if (_requestOutstanding) _scheduleStatus(Duration.zero);
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
      if (!_currentCheck(generation) || !canDispatch() || _requestOutstanding) {
        return false;
      }
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
        canDispatch: () =>
            _currentCheck(generation) && canDispatch() && !_requestOutstanding,
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

  Future<void> refreshStatus({bool background = false}) async {
    if (cloudManaged || _disposed || starting || channelSaving) return;
    if (!await _loadTracking() || _disposed) return;
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
    BackendUpdateStatus? next;
    BackendUpdateReceipt? receipt;
    var unavailable = false;
    try {
      await store.persistAcceptance();
      if (!_currentStatus(generation)) return;
      try {
        next = BackendUpdateStatus.fromJson(
          await gateway.read('actions/hermes-update/status'),
        );
        unavailable = next == null;
      } catch (_) {
        unavailable = true;
      }
      if (!_currentStatus(generation)) return;
      try {
        final envelope = await gateway.read('hermes/update/receipt');
        receipt = BackendUpdateReceipt.fromJson(envelope['receipt']);
      } catch (_) {
        // An unavailable receipt never certifies completion or clears tracking.
      }
      if (!_currentStatus(generation)) return;
      if (next != null) status = next;
      await _applyStatus(next, receipt, unavailable: unavailable);
      _statusFailures = unavailable ? _statusFailures + 1 : 0;
    } catch (_) {
      if (!_currentStatus(generation)) return;
      phase = BackendUpdatePhase.unknown;
      message =
          'Saved update tracking could not be updated. Check progress to retry.';
      _statusFailures++;
    } finally {
      if (_currentStatus(generation)) {
        _statusRead = null;
        statusLoading = false;
        _notify();
        if (_requestOutstanding || phase == BackendUpdatePhase.running) {
          final seconds = (2 * (1 << (_statusFailures - 1).clamp(0, 4))).clamp(
            2,
            30,
          );
          _scheduleStatus(Duration(seconds: seconds));
        }
      }
    }
  }

  Future<void> _applyStatus(
    BackendUpdateStatus? next,
    BackendUpdateReceipt? receipt, {
    required bool unavailable,
  }) async {
    final attempt = store.current;
    if (attempt != null) {
      final actionId = attempt.actionId;
      // The stock action status can retain this exact action's receipt even
      // after a newer CLI update replaces the root-wide latest receipt.
      if (actionId != null &&
          receipt?.actionId != actionId &&
          next?.receipt?.actionId == actionId) {
        receipt = next!.receipt;
      }
      final matching = actionId != null && receipt?.actionId == actionId;
      if (matching && receipt!.terminal) {
        await store.clear(attempt.requestId, receipt: receipt);
      } else if (unavailable) {
        phase = actionId == null
            ? BackendUpdatePhase.unknown
            : BackendUpdatePhase.running;
        message = actionId == null
            ? 'Update outcome not yet confirmed. Waiting for the server to reconnect.'
            : 'Update ongoing. Waiting for the server to reconnect.';
      } else if (matching && receipt!.outcome == 'running' ||
          actionId != null &&
              next?.running == true &&
              next?.actionId == actionId) {
        phase = BackendUpdatePhase.running;
        message = 'Update ongoing';
      } else {
        phase = BackendUpdatePhase.unknown;
        message = 'Update outcome not yet confirmed.';
      }
      return;
    }
    if (receipt?.terminal == true &&
        (next?.running != true || next?.actionId == receipt?.actionId)) {
      _applyOutcome(receipt!.outcome, prefix: 'Last recorded update');
      return;
    }
    // A running server receipt survives the dashboard losing its process table.
    if (receipt?.outcome == 'running' && receipt?.actionId != null ||
        next?.running == true &&
            next?.actionId != null &&
            (next?.pid ?? 0) > 0) {
      final accepted = BackendUpdateAttempt(
        requestId: const Uuid().v4(),
        installId: null,
        installPath: null,
        home: null,
        targetSha: null,
        startedAt: DateTime.now().toUtc(),
        actionId: receipt?.outcome == 'running'
            ? receipt!.actionId
            : next!.actionId,
        pid: receipt?.outcome == 'running' ? receipt!.pid : next!.pid,
      );
      await store.reserve(accepted);
    } else if (next?.running == true) {
      phase = BackendUpdatePhase.running;
      message = 'Update ongoing';
    } else {
      phase = BackendUpdatePhase.unknown;
      message = unavailable
          ? 'Backend update status is unavailable. Check again.'
          : 'Update outcome not yet confirmed.';
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
    if (_disposed) return;
    _disposed = true;
    store.removeListener(_trackingChanged);
    _statusPoll?.cancel();
    _checkGeneration++;
    _statusGeneration++;
    super.dispose();
  }
}

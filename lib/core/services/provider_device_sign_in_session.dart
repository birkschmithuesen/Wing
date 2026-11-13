import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/provider_inventory.dart';
import '../models/provider_device_sign_in.dart';
import 'administration_repository.dart';
import 'workspace_connection_failure.dart';

/// Owns one captured device-code attempt, its timers and exact cleanup identity.
/// A start with unknown delivery has no recoverable session ID in stock and
/// cannot be repeated automatically. No credential/runtime cache is introduced.
class ProviderDeviceSignInSession extends ChangeNotifier {
  ProviderDeviceSignInSession(this.profile, this.target) {
    if (target.id.isEmpty || target.name.isEmpty) {
      throw ArgumentError.value(target);
    }
    profile.server.retain();
  }

  ProviderDeviceSession? get session => _session;
  ProviderDeviceStatus? get status => _status;
  String? get error => _error;
  bool get busy => _busy;
  bool get unknownStart => _unknownStart;
  final ProfileAdministration profile;
  final ProviderSignInTarget target;
  ProviderDeviceSession? _session;
  ProviderDeviceStatus? _status;
  String? _error;
  bool _busy = false,
      _unknownStart = false,
      _pollBlocked = false,
      _disposed = false;
  bool _cancelling = false, _cleanupPending = false;
  Object? _pollOperation, _cancelOperation;
  int _generation = 0;
  Timer? _timer, _deadlineTimer;
  Future<void> _cleanup = Future.value();
  Future<void> get cleanup => _cleanup;
  bool get pending =>
      _session != null && _status == ProviderDeviceStatus.pending;
  bool get showStart =>
      !pending && !_unknownStart && _status != ProviderDeviceStatus.approved;
  bool get canStart =>
      !_disposed &&
      !_busy &&
      !pending &&
      !_unknownStart &&
      !_cleanupPending &&
      _status != ProviderDeviceStatus.approved;
  bool get canRecover => !_disposed && pending && !_busy && !_pollBlocked;
  bool get canClose => !_disposed && !_busy;
  bool get statusIsError => {
    ProviderDeviceStatus.error,
    ProviderDeviceStatus.denied,
    ProviderDeviceStatus.expired,
    ProviderDeviceStatus.cancelled,
  }.contains(_status);
  String get statusLabel => _status?.name ?? (_unknownStart ? 'unknown' : '');
  void _changed() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  bool _owns(int generation) => !_disposed && generation == _generation;
  String get _providerPath =>
      'providers/oauth/${Uri.encodeComponent(target.id)}';

  Future<void> start() async {
    if (!canStart) {
      return;
    }
    final generation = ++_generation;
    var dispatchActive = true, dispatched = false;
    _busy = true;
    _error = null;
    _changed();
    profile.server.retain();
    try {
      await profile.requireProfile();
      if (!_owns(generation)) {
        return;
      }
      final response = await profile.server.ownedMutation(
        'POST',
        '$_providerPath/start',
        {'profile': profile.name},
        {'profile': profile.name},
        () => dispatchActive && _owns(generation),
        () => dispatched = true,
      );
      // Parse before publication: even a retired route must release a known
      // returned attempt, never turn it into another route's live sign-in.
      final identity = ProviderDeviceSession.returnedIdentity(response);
      final ProviderDeviceSession returned;
      try {
        returned = ProviderDeviceSession.fromStart(response, DateTime.now());
      } catch (_) {
        if (identity != null) {
          try {
            await _cancelIdentity(identity);
          } catch (_) {
            // Display rejection remains unconfirmed. No cleanup result grants
            // replay or publication authority, including on a retired route.
          }
        }
        rethrow;
      }
      if (!_owns(generation)) {
        await _cancelIdentity(returned.id);
        return;
      }
      _session = returned;
      _status = ProviderDeviceStatus.pending;
      _unknownStart = false;
      _pollBlocked = false;
      _deadlineTimer?.cancel();
      _deadlineTimer = Timer(
        returned.deadline.difference(DateTime.now()),
        _expire,
      );
      _schedule();
    } catch (failure) {
      if (_owns(generation)) {
        _unknownStart = dispatched;
        _error = dispatched
            ? 'Sign-in start could not be confirmed. Do not start another attempt here; check provider status before reopening.'
            : administrationError(failure, writing: true);
      }
    } finally {
      dispatchActive = false;
      profile.server.release();
      if (_owns(generation)) {
        _busy = false;
        _changed();
      }
    }
  }

  void _expire() {
    if (_disposed || !pending) {
      return;
    }
    _generation++;
    _timer?.cancel();
    _timer = null;
    _status = ProviderDeviceStatus.expired;
    // An accepted manual cancellation already owns this exact cleanup. Expiry
    // retires publication, but neither duplicates its DELETE nor its lease.
    if (!_cancelling) {
      _releaseKnown(_session!);
    }
    _changed();
  }

  void _schedule() {
    _timer?.cancel();
    if (!_disposed && pending) {
      _timer = Timer(_session!.pollInterval, poll);
    }
  }

  Future<void> poll() async {
    if (_disposed || !pending || _busy) {
      return;
    }
    final owned = _session!;
    if (!DateTime.now().isBefore(owned.deadline)) {
      _expire();
      return;
    }
    final generation = _generation;
    final operation = _pollOperation = Object();
    _timer?.cancel();
    _busy = true;
    _changed();
    try {
      final response = await profile.read(
        '$_providerPath/poll/${Uri.encodeComponent(owned.id)}',
      );
      final observed = owned.statusFromPoll(response);
      if (!_owns(generation) || !identical(owned, _session)) {
        return;
      }
      _status = observed;
      _pollBlocked = false;
      _error = null;
      if (pending) {
        _schedule();
      } else {
        _deadlineTimer?.cancel();
      }
    } catch (failure) {
      if (_owns(generation)) {
        _error = administrationError(failure);
        _pollBlocked = !isTemporaryWorkspaceFailure(failure);
      }
    } finally {
      if (identical(_pollOperation, operation)) {
        _pollOperation = null;
        if (!_disposed) {
          _busy = false;
          _changed();
        }
      }
    }
  }

  /// Each caller captured this exact identity from the current start response
  /// or an owned attempt. Cleanup drains its retained lease after route expiry.
  Future<void> _cancelIdentity(String identity) async {
    var dispatchActive = true;
    try {
      await profile.requireProfile();
      final result = await profile.server.ownedMutation(
        'DELETE',
        'providers/oauth/sessions/${Uri.encodeComponent(identity)}',
        {'profile': profile.name},
        const {},
        () => dispatchActive,
        () {},
      );
      if (result['ok'] != true || result['session_id'] != identity) {
        throw const AdministrationFailure(
          'Cancellation could not be confirmed. Retry before closing.',
        );
      }
    } finally {
      dispatchActive = false;
    }
  }

  Future<bool> cancel() {
    if (!canClose) {
      return Future.value(false);
    }
    if (!pending) {
      return Future.value(true);
    }
    final owned = _session!, generation = _generation;
    final operation = _cancelOperation = Object();
    _timer?.cancel();
    _busy = true;
    _cancelling = true;
    _cleanupPending = true;
    _error = null;
    _changed();
    profile.server.retain();
    final completion = (() async {
      try {
        // Expiry/disposal shares this cleanup and its lease. Generation only
        // controls publication; operation identity owns settlement occupancy.
        await _cancelIdentity(owned.id);
        if (!_owns(generation)) {
          return false;
        }
        _status = ProviderDeviceStatus.cancelled;
        _deadlineTimer?.cancel();
        return true;
      } catch (_) {
        if (_owns(generation)) {
          _error = 'Cancellation could not be confirmed. Retry before closing.';
        } else if (!_disposed &&
            identical(_cancelOperation, operation) &&
            _status == ProviderDeviceStatus.expired) {
          // A deadline does not establish that the accepted DELETE succeeded.
          _unknownStart = true;
          _error =
              'Sign-in cleanup could not be confirmed. Check provider status before reopening.';
        }
        return false;
      } finally {
        profile.server.release();
        if (identical(_cancelOperation, operation)) {
          _cancelOperation = null;
          _cancelling = false;
          _cleanupPending = false;
          if (!_disposed) {
            _busy = false;
            _changed();
          }
        }
      }
    })();
    _cleanup = completion.then<void>((_) {});
    return completion;
  }

  void browserUnavailable() {
    if (_disposed) {
      return;
    }
    _error =
        'Could not open the browser. Try opening the sign-in address below.';
    _changed();
  }

  void _releaseKnown(ProviderDeviceSession owned) {
    _cleanupPending = true;
    profile.server.retain();
    _cleanup = (() async {
      try {
        await _cancelIdentity(owned.id);
      } catch (_) {
        // A client deadline is not evidence that the server stopped its worker.
        // Unknown cleanup cannot authorize an overlapping attempt on this route.
        if (!_disposed) {
          _unknownStart = true;
          _error =
              'Sign-in cleanup could not be confirmed. Check provider status before reopening.';
        }
      } finally {
        profile.server.release();
        _cleanupPending = false;
        _changed();
      }
    })();
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    final owned = pending && !_cancelling ? _session : null;
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _deadlineTimer?.cancel();
    if (owned != null) {
      _releaseKnown(owned);
    }
    profile.server.release();
    super.dispose();
  }
}

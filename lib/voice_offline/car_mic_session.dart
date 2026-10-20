import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/services/android_voice.dart';

/// Hands-free / car-kit Bluetooth device classes (BluetoothClass.Device),
/// the same ones HeadsetMicRoute.kt already recognises as a valid mic
/// source (spec E2 = 2, t_4450aa3b). Headphone classes (0x0404, 0x0418,
/// see headphone_route.dart's `_headphoneClasses`) are deliberately not
/// included: only a car kit keeps its SCO link open for the whole
/// conversation (spec Birk decision 2026-10-19); headphones keep the old
/// per-dictation behaviour.
const _carKitClasses = {0x0408, 0x0420};

bool isCarKitClass(int? bluetoothClass) => _carKitClasses.contains(bluetoothClass);

/// Keeps a connected car kit's classic-SCO link open across a whole
/// conversation — dictation, listening-in (Mithören/TurnListener) and
/// read-aloud barge-in (Reinreden) rounds — instead of opening and closing
/// it per round (spec Birk decision 2026-10-19, ~18:00, in the car).
///
/// [beginRound] is idempotent while already open: callers invoke it before
/// every round and only the first call actually opens the link. A reply
/// that is slow to settle within the native readiness window falls back to
/// the phone mic for that one round ([beginRound] answers false) without
/// aborting the caller's loop (spec: SCO ready-timeout).
class CarMicSession {
  CarMicSession(
    this.device, {
    this.idleTimeout = const Duration(seconds: 120),
    void Function(String line)? log,
  }) : _log = log ?? debugPrint;

  final VoiceDevice device;

  /// Closes the link after this long without a [beginRound] call (spec:
  /// "spätestens nach N s ohne Aktivität", proposed 120 s).
  final Duration idleTimeout;
  final void Function(String line) _log;

  bool _open = false;
  Timer? _idleTimer;

  bool get isOpen => _open;

  /// Opens the link on the first call of a conversation and just resets the
  /// idle timer on every later one; never re-opens while already held.
  /// Returns whether this round should use the held car-kit mic (false asks
  /// the caller to fall back to the phone mic for this round only).
  Future<bool> beginRound(String reason) async {
    _touchIdle();
    if (_open) return true;
    final ready = await device.openMicLink(reason);
    if (!ready) {
      _log('WingMic sco=fail fallback=phone');
      return false;
    }
    _open = true;
    _log('WingMic sco=open reason=$reason');
    return true;
  }

  /// Ends the conversation. A no-op if nothing is held.
  Future<void> end(String reason) async {
    _cancelIdle();
    if (!_open) return;
    _open = false;
    await device.closeMicLink(reason);
    _log('WingMic sco=close reason=$reason');
  }

  void _touchIdle() {
    _cancelIdle();
    _idleTimer = Timer(idleTimeout, () => unawaited(end('idle')));
  }

  void _cancelIdle() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void dispose() => _cancelIdle();
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/controllers/voice_input_controller.dart';
import '../core/services/android_voice.dart';
import '../core/services/voice_preferences.dart';
import 'car_mode_bridge.dart';
import 'car_mode_screen.dart';
import 'car_mode_state.dart';

/// One car-mode visit over one chat. Owns the route, the screen-on holder, the
/// held recording and the text-free log (spec §4, §7).
class CarModeSession extends ChangeNotifier {
  CarModeSession({
    required this.device,
    required this.bridge,
    void Function(String line)? log,
    this.retryEvery = const Duration(seconds: 20),
    this.signalGap = const Duration(milliseconds: 250),
    this.deliveryFor = const Duration(seconds: 3),
  }) : _log = log ?? debugPrint;

  final VoiceDevice device;
  final CarModeBridge bridge;
  final Duration retryEvery;
  final Duration signalGap;

  /// How long the "added to the running turn" confirmation stays up.
  final Duration deliveryFor;
  final void Function(String line) _log;
  final _gate = CarTapGate();
  final _pulses = <Timer>[];
  bool _active = false;
  bool _held = false;
  bool _loopOn = false;
  bool _bargeInOn = false;
  bool _lostSignalled = false;
  Object? _chatKey;
  CarConnection _connection = CarConnection.ok;
  NavigatorState? _navigator;
  Route<void>? _route;
  Timer? _retry;
  CarDelivery? _delivery;
  Timer? _deliveryTimer;

  bool get active => _active;

  /// The in-session conversation-mode switch (hands-free, automatic end of
  /// turn). Session-local only; never reads or changes the saved
  /// [VoicePreferences.conversation].
  bool get loopOn => _loopOn;

  /// The in-session "Interrupt by speaking" switch. Session-local only;
  /// while on, it lifts the Wing car mode barge-in lock for this session
  /// (see classifyRoute's bargeInOverride and HeadphoneRoute.bargeInOverride
  /// in headphone_route.dart). The echo gate (PlaybackGate) stays unchanged.
  bool get bargeInOn => _bargeInOn;

  /// A finished recording waits in the chat draft for the connection.
  bool get held => _held;
  CarSnapshot get snapshot {
    final snap = bridge.read();
    return _delivery == null ? snap : snap.withDelivery(_delivery);
  }

  CarPhase get phase => carPhaseOf(snapshot, held: _held);

  Future<void> enter(BuildContext context) async {
    final snap = bridge.read();
    if (_active || snap.chatKey == null) return;
    // Active before the push: the workspace below keeps its focus.
    _active = true;
    _held = false;
    _loopOn = false;
    _bargeInOn = false;
    _lostSignalled = false;
    _chatKey = snap.chatKey;
    _connection = snap.connection;
    VoiceSwitchHolders.screenOn(device).set(this, true);
    bridge.changes.addListener(_changed);
    _log('WingCar enter route=${_routeName()} loop=${_loopName()}');
    notifyListeners();
    final navigator = _navigator = Navigator.of(context);
    final route = _route = MaterialPageRoute<void>(
      builder: (_) => CarModeScreen(session: this),
    );
    await navigator.push(route);
    // Android Back popped the route; after exit() this does nothing.
    _leave('back');
  }

  void exit(String reason) {
    if (!_active) return;
    _leave(reason);
    final route = _route;
    final navigator = _navigator;
    _route = null;
    if (route == null || navigator == null || !route.isActive) return;
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  void _leave(String reason) {
    if (!_active) return;
    bridge.leave();
    _end(reason);
  }

  void _end(String reason) {
    if (!_active) return;
    _active = false;
    _held = false;
    _loopOn = false;
    _bargeInOn = false;
    _retry?.cancel();
    _retry = null;
    _deliveryTimer?.cancel();
    _deliveryTimer = null;
    _delivery = null;
    for (final pulse in _pulses) {
      pulse.cancel();
    }
    _pulses.clear();
    bridge.changes.removeListener(_changed);
    VoiceSwitchHolders.screenOn(device).set(this, false);
    _log('WingCar exit reason=$reason');
    notifyListeners();
  }

  void _changed() {
    if (!_active) return;
    final snap = bridge.read();
    if (snap.chatKey != _chatKey) {
      exit('chatChanged');
      return;
    }
    _connectionChanged(snap.connection);
    if (_held &&
        snap.connection == CarConnection.ok &&
        !snap.working &&
        !snap.speaking &&
        snap.input == VoiceInputPhase.idle) {
      // Cleared before the send: only a new hold can send again.
      _held = false;
      _syncRetry();
      _log('WingCar release');
      // Outside this listener call: the send notifies the same listeners.
      scheduleMicrotask(() => unawaited(bridge.sendHeld()));
    }
    notifyListeners();
  }

  void _connectionChanged(CarConnection next) {
    if (next == _connection) return;
    _connection = next;
    _log('WingCar connection state=${next.name}');
    if (next == CarConnection.offline && !_lostSignalled) {
      _lostSignalled = true;
      _pulse(HapticFeedback.vibrate, 3);
    } else if (next == CarConnection.ok && _lostSignalled) {
      _lostSignalled = false;
      _pulse(HapticFeedback.heavyImpact, 2);
    }
    _syncRetry();
  }

  /// Vibration only: the cue tones cannot play on demand (spec §4.4).
  void _pulse(Future<void> Function() haptic, int times) {
    _pulses.removeWhere((timer) => !timer.isActive);
    for (var i = 0; i < times; i++) {
      _pulses.add(Timer(signalGap * i, () => unawaited(haptic())));
    }
  }

  /// `disconnected` stays until someone retries (spec §2.3).
  void _syncRetry() {
    final want = _active && _held && _connection == CarConnection.offline;
    if (!want) {
      _retry?.cancel();
      _retry = null;
    } else {
      _retry ??= Timer.periodic(retryEvery, (_) => unawaited(bridge.retry()));
    }
  }

  /// Called by the workspace before it sends a car-mode round. True: keep the
  /// draft and wait for the connection (spec §4.4).
  bool holdForConnection() {
    if (!_active) return false;
    final connection = bridge.read().connection;
    if (connection == CarConnection.ok) {
      if (_held) {
        // This send carries the held text with it.
        _held = false;
        _syncRetry();
        _log('WingCar release');
        notifyListeners();
      }
      return false;
    }
    _connectionChanged(connection);
    if (!_held) {
      _held = true;
      _log('WingCar hold');
    }
    _syncRetry();
    notifyListeners();
    return true;
  }

  Future<void> tap() async {
    if (!_active) return;
    final snap = bridge.read();
    final phase = carPhaseOf(snap, held: _held);
    final action = carTapActionFor(phase, snap);
    if (action == CarTapAction.ignore) {
      _log('WingCar tap phase=${phase.name} action=ignore');
      unawaited(HapticFeedback.vibrate());
      return;
    }
    if (!_gate.accept()) {
      _log('WingCar tap phase=${phase.name} action=debounced');
      return;
    }
    _log('WingCar tap phase=${phase.name} action=${action.name}');
    unawaited(HapticFeedback.heavyImpact());
    switch (action) {
      case CarTapAction.talk:
        if (phase == CarPhase.speaking) {
          final watch = Stopwatch()..start();
          await bridge.stopSpeech();
          _log('WingCar stopSpeech ms=${watch.elapsedMilliseconds}');
        }
        await bridge.talk();
      case CarTapAction.sendNow:
        await bridge.sendNow();
      case CarTapAction.ignore:
        break;
    }
  }

  /// Case 2 (loop switch off): rounds end by tap only (spec §4.2). Reads the
  /// session-local switch, never the saved [VoicePreferences.conversation].
  VoicePreferences roundSettings(VoicePreferences settings) =>
      _active && !_loopOn ? carTapOnlySettings(settings) : settings;

  /// The status-row switch (spec: top row, outside the tap area). Session-
  /// local only; leaving car mode resets it (see [_end]).
  void setLoop(bool on) {
    if (!_active || _loopOn == on) return;
    _loopOn = on;
    _log('WingCar loop=${on ? 'on' : 'off'} source=toggle');
    notifyListeners();
  }

  /// The second status-row switch, next to the conversation-mode switch.
  /// Session-local only; leaving car mode resets it (see [_end]). The
  /// workspace screen reads [bargeInOn] to lift the carMode barge-in lock
  /// for the running session (classifyRoute's bargeInOverride).
  void setBargeIn(bool on) {
    if (!_active || _bargeInOn == on) return;
    _bargeInOn = on;
    _log('WingCar bargeIn=${on ? 'on' : 'off'} source=toggle');
    notifyListeners();
  }

  /// Called by the workspace when a car-mode utterance is delivered. A steer
  /// or queue was added to the running turn: show the confirmation for
  /// [deliveryFor], then fall back to whichever hint currently applies.
  void logDelivery(CarDelivery delivery) {
    if (!_active) return;
    _log('WingCar deliver kind=${delivery.name}');
    if (delivery != CarDelivery.steer && delivery != CarDelivery.queue) return;
    _delivery = delivery;
    _deliveryTimer?.cancel();
    _deliveryTimer = Timer(deliveryFor, () {
      _delivery = null;
      notifyListeners();
    });
    notifyListeners();
  }

  /// The screen reports a finished horizontal drag (spec §4.8).
  void swiped({required bool exits}) {
    if (!_active) return;
    _log('WingCar swipe action=${exits ? 'exit' : 'short'}');
    if (exits) exit('swipe');
  }

  String _routeName() {
    try {
      return VoicePreferences.read(bridge.preferences).input.name;
    } on FormatException {
      return 'unknown';
    }
  }

  String _loopName() => _loopOn ? 'on' : 'off';

  @override
  void dispose() {
    final route = _route;
    final navigator = _navigator;
    _end('disposed');
    if (route != null && navigator != null && route.isActive) {
      // The workspace is going away; take the car route with it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) navigator.removeRoute(route);
      });
    }
    _gate.dispose();
    super.dispose();
  }
}

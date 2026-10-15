import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Native side of a conversation that continues with the screen off
/// (spec 2026-10-14 background): a microphone foreground service.
abstract interface class BackgroundVoiceHost {
  /// Starts or stops the hold. Resolves to whether it is held.
  Future<bool> hold(bool on);

  /// Reasons the native side ended the hold on its own:
  /// notification, dismissed, call, activityClosed.
  Stream<String> get stopped;
}

class AndroidBackgroundVoiceHost implements BackgroundVoiceHost {
  AndroidBackgroundVoiceHost._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'stopped') return;
      final args = call.arguments;
      _stopped.add(args is Map ? '${args['reason']}' : 'unknown');
    });
  }

  static final instance = AndroidBackgroundVoiceHost._();
  static const _channel = MethodChannel('com.tarkilhk.wing/background_voice');
  final _stopped = StreamController<String>.broadcast();

  @override
  Stream<String> get stopped => _stopped.stream;

  @override
  Future<bool> hold(bool on) async {
    final result = await _channel.invokeMapMethod<String, Object?>('hold', {
      'on': on,
    });
    return result?['held'] == true;
  }
}

/// Holds the microphone service while a vad conversation runs, so a lifecycle
/// pause no longer ends it. Calls to the host are serialised; each one
/// applies the latest wish.
class BackgroundVoice {
  BackgroundVoice(this._host, {required VoidCallback onStopped}) {
    _subscription = _host.stopped.listen((_) {
      if (!_held) return;
      _held = false;
      _want = false;
      onStopped();
    });
  }

  final BackgroundVoiceHost _host;
  late final StreamSubscription<String> _subscription;
  Future<void> _queue = Future.value();
  bool _held = false;
  bool _want = false;
  bool _resumed = true;
  bool _disposed = false;

  bool get held => _held;

  /// Held while Wing is not in the foreground (screen off, other app).
  bool get screenOff => _held && !_resumed;

  /// Completes when every `sync`/`dispose` queued so far has applied.
  Future<void> get settled => _queue;

  void sync({required bool want}) {
    if (_disposed || want == _want) return;
    _want = want;
    _queue = _queue.then((_) => _apply());
  }

  Future<void> _apply() async {
    final want = _want && !_disposed;
    if (want == _held) return;
    bool held;
    try {
      held = await _host.hold(want);
    } on Object {
      held = false;
    }
    _held = want && held;
  }

  /// A detached engine loses its view: voice ends as before.
  bool keepsVoice(AppLifecycleState state) =>
      _held && state != AppLifecycleState.detached;

  void lifecycle(AppLifecycleState state) =>
      _resumed = state == AppLifecycleState.resumed;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _queue = _queue.then((_) => _apply());
    unawaited(_subscription.cancel());
  }
}

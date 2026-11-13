import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One route owns Android's current capture target. Tokens fence retired views
/// and engine callbacks; this adapter has no conversation or backend authority.
class ScrollCaptureBridge {
  ScrollCaptureBridge(this.handle);
  static const channel = MethodChannel('com.tarkilhk.wing/scroll_capture');
  static ScrollCaptureBridge? _current;
  static int _nextId = 0;
  final int id = ++_nextId;
  bool get isCurrent => _current == this;
  final Future<Object?> Function(String method, Map<Object?, Object?> args)
  handle;
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> update(Map<String, Object> bounds) async {
    if (!supported) return;
    _current = this;
    channel.setMethodCallHandler((call) async {
      final args = Map<Object?, Object?>.from(call.arguments as Map);
      if (_current != this || args['id'] != id) return null;
      return handle(call.method, args);
    });
    try {
      await channel.invokeMethod<void>('register', {'id': id, ...bounds});
    } on MissingPluginException {
      // Host widget tests and non-Android embeddings have no native target.
    } on PlatformException {
      // Capture availability is independent of conversation availability.
    }
  }

  Future<void> dispose() async {
    if (!supported || _current != this) return;
    _current = null;
    channel.setMethodCallHandler(null);
    try {
      await channel.invokeMethod<void>('unregister', {'id': id});
    } on MissingPluginException {
      // The Android host may already have detached.
    } on PlatformException {
      // Retired Android hosts have no remaining capture authority.
    }
  }
}

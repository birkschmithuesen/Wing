import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidSharedFile {
  final String path;
  final String name;
  final String mediaType;
  final int byteLength;

  const AndroidSharedFile({
    required this.path,
    required this.name,
    required this.mediaType,
    required this.byteLength,
  });

  factory AndroidSharedFile.fromMap(Map<Object?, Object?> map) {
    final path = map['path'];
    final name = map['name'];
    final mediaType = map['mediaType'];
    final byteLength = map['byteLength'];
    return AndroidSharedFile(
      path: path is String ? path.trim() : '',
      name: name is String ? name.trim() : '',
      mediaType: mediaType is String
          ? mediaType.trim()
          : 'application/octet-stream',
      byteLength: byteLength is num ? byteLength.toInt() : 0,
    );
  }

  bool get isImage => mediaType.toLowerCase().startsWith('image/');
}

class AndroidSharePayload {
  final String? id;
  final String? text;
  final List<AndroidSharedFile> files;
  final Map<String, String>? target;

  const AndroidSharePayload({
    this.id,
    this.text,
    this.files = const [],
    this.target,
  });

  bool get isEmpty => (text == null || text!.isEmpty) && files.isEmpty;

  static AndroidSharePayload? fromPlatform(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final rawId = raw['id'];
    if (rawId is! String) {
      return null;
    }
    final id = rawId.trim();
    if (id.isEmpty) {
      return null;
    }
    final rawText = raw['text'];
    final textValue = rawText is String ? rawText.trim() : null;
    final rawFiles = raw['files'];
    if (rawFiles is! List) {
      return null;
    }
    final files = <AndroidSharedFile>[];
    for (final rawFile in rawFiles) {
      if (rawFile is! Map) {
        return null;
      }
      final file = AndroidSharedFile.fromMap(
        rawFile.map((key, value) => MapEntry<Object?, Object?>(key, value)),
      );
      if (file.path.isEmpty || file.name.isEmpty || file.byteLength <= 0) {
        return null;
      }
      files.add(file);
    }
    final payload = AndroidSharePayload(
      id: id,
      text: textValue == null || textValue.isEmpty ? null : textValue,
      files: files,
      target: _validatedTarget(raw['target']),
    );
    return payload.isEmpty ? null : payload;
  }
}

/// Receives text, URLs, images, and files sent through Android share intents.
class AndroidShareIntentService {
  static const channelName = 'com.tarkilhk.wing/share';
  static const _channel = MethodChannel(channelName);
  static const _genericIntakeError = 'Shared content could not be imported.';

  final ValueNotifier<AndroidSharePayload?> pendingShare =
      ValueNotifier<AndroidSharePayload?>(null);
  final ValueNotifier<String?> intakeError = ValueNotifier<String?>(null);

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler(_handleMethodCall);
    try {
      final raw = await _channel.invokeMethod<Object?>('getPendingShare');
      if (raw != null) {
        _publish(raw);
      }
    } on MissingPluginException {
      // Non-Android hosts have no share-intent bridge.
    } on PlatformException {
      intakeError.value = _genericIntakeError;
    }
  }

  Future<bool> acknowledgeShare(AndroidSharePayload payload) async {
    final current = pendingShare.value;
    final id = payload.id;
    if (current == null || id == null || id.isEmpty || current.id != id) {
      return false;
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('acknowledgeShare', {
        'id': id,
      });
      if (pendingShare.value?.id != id) {
        return false;
      }
      if (raw == null) {
        pendingShare.value = null;
        return true;
      }
      final next = AndroidSharePayload.fromPlatform(raw);
      if (next == null || next.id == id) {
        return false;
      }
      pendingShare.value = next;
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> capturePhoto(Map<String, String> target) async {
    final validatedTarget = _validatedTarget(target);
    if (validatedTarget == null) {
      throw StateError('Camera destination is unavailable.');
    }
    try {
      await _channel.invokeMethod<void>('capturePhoto', {
        'target': validatedTarget,
      });
    } on MissingPluginException {
      throw StateError('Camera is unavailable on this device.');
    } on PlatformException {
      throw StateError('Camera could not be opened.');
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'sharePayload':
        _publish(call.arguments);
        return;
      case 'shareError':
        final message = call.arguments is String
            ? (call.arguments as String).trim()
            : '';
        intakeError.value = message.isEmpty ? _genericIntakeError : message;
        return;
    }
  }

  void _publish(Object? raw) {
    final payload = AndroidSharePayload.fromPlatform(raw);
    if (payload == null) {
      intakeError.value = _genericIntakeError;
      return;
    }
    final current = pendingShare.value;
    if (current == null) {
      pendingShare.value = payload;
    }
    // Native always publishes its oldest queued item. Keep the current review
    // stable until that exact item has been acknowledged.
  }

  void clearIntakeError() => intakeError.value = null;

  void dispose() {
    _channel.setMethodCallHandler(null);
    pendingShare.dispose();
    intakeError.dispose();
  }
}

Map<String, String>? _validatedTarget(Object? raw) {
  if (raw is! Map) {
    return null;
  }
  final keys = raw.containsKey('room')
      ? const ['connection', 'connection_identity', 'room']
      : const ['connection', 'connection_identity', 'profile', 'session'];
  if (raw.keys.any((key) => !keys.contains(key))) return null;
  final target = <String, String>{};
  for (final key in keys) {
    final value = raw[key];
    if (value is! String || value.trim().isEmpty) {
      return null;
    }
    target[key] = value.trim();
  }
  return Map.unmodifiable(target);
}

import 'dart:async';
import 'package:flutter/services.dart';
import '../../voice_offline/speech_segments.dart';

class AndroidVoiceCapabilities {
  final bool recognitionAvailable;
  final List<String>? installedLanguages;
  final List<({String id, String label})> voices;
  const AndroidVoiceCapabilities({
    required this.recognitionAvailable,
    this.installedLanguages,
    this.voices = const [],
  });
  factory AndroidVoiceCapabilities.fromMap(Map<Object?, Object?> data) =>
      AndroidVoiceCapabilities(
        recognitionAvailable: data['recognitionAvailable'] == true,
        installedLanguages: (data['languages'] as List?)?.cast<String>(),
        voices: [
          for (final row in data['voices'] as List? ?? [])
            (id: (row as Map)['id'] as String, label: row['label'] as String),
        ],
      );
}

/// All operations are foreground-only. Request IDs isolate late native events.
abstract interface class VoiceDevice {
  Stream<Map<String, dynamic>> get events;
  Future<AndroidVoiceCapabilities> capabilities();
  Future<void> start(
    String id, {
    required bool local,
    required String language,
  });
  Future<Uint8List?> stop(String id, {required Duration timeout});
  Future<void> cancel(String id);
  Future<void> speak(
    String id,
    String text, {
    required String voice,
    required double rate,
  });
  Future<void> play(String id, Uint8List bytes);
  Future<void> stopPlayback(String id);
}

class AndroidVoice implements VoiceDevice {
  static final instance = AndroidVoice();
  static const channel = MethodChannel('com.tarkilhk.wing/voice');
  static Future<bool> requestPermission() async =>
      await channel.invokeMethod<bool>('requestPermission') ?? false;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  AndroidVoice() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'event') {
        _events.add(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
  }
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  @override
  Future<AndroidVoiceCapabilities> capabilities() async =>
      AndroidVoiceCapabilities.fromMap(
        await channel.invokeMapMethod<Object?, Object?>('capabilities') ?? {},
      );
  @override
  Future<void> start(
    String id, {
    required bool local,
    required String language,
  }) => channel.invokeMethod('start', {
    'id': id,
    'local': local,
    'language': language,
  });
  @override
  Future<Uint8List?> stop(String id, {required Duration timeout}) =>
      channel.invokeMethod<Uint8List>('stop', {
        'id': id,
        'timeoutMs': timeout.inMilliseconds,
      });
  @override
  Future<void> cancel(String id) => channel.invokeMethod('cancel', {'id': id});
  @override
  Future<void> speak(
    String id,
    String text, {
    required String voice,
    required double rate,
  }) => channel.invokeMethod('speak', {
    'id': id,
    'text': text,
    'voice': voice,
    'rate': rate,
    'segments': speechSegmentsPayload(text),
  });
  @override
  Future<void> play(String id, Uint8List bytes) =>
      channel.invokeMethod('play', {'id': id, 'bytes': bytes});
  @override
  Future<void> stopPlayback(String id) =>
      channel.invokeMethod('stopPlayback', {'id': id});
}

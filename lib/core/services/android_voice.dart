import 'dart:async';
import 'package:flutter/services.dart';
import 'vad_endpoint.dart';
import 'voice_preferences.dart';

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

  /// Route vad: own capture; probabilities arrive as `{id, first, windows}` events.
  Future<void> startVad(String id, VadCaptureOptions options);

  /// Ends the vad round and returns the on-device transcript of the decided windows,
  /// recognised piece by piece along [chunks] (same window indexing as [decision]).
  Future<String> finishVad(
    String id,
    VadDecision decision,
    VadEndpointConfig config, {
    List<VadChunk> chunks = const [],
  });
  Future<VadModelStatus> vadModelStatus();
  Future<void> installVadModel();
  Future<void> cancelVadModelInstall();
  Future<void> removeVadModel();
  Future<void> prepareVad();
  Future<void> releaseVad();
  Future<void> setMediaKeys(bool on);
  Future<void> keepScreenOn(bool on);
  Future<int> deleteVadDebugRecordings();
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
  });
  @override
  Future<void> play(String id, Uint8List bytes) =>
      channel.invokeMethod('play', {'id': id, 'bytes': bytes});
  @override
  Future<void> stopPlayback(String id) =>
      channel.invokeMethod('stopPlayback', {'id': id});

  @override
  Future<void> startVad(String id, VadCaptureOptions options) =>
      channel.invokeMethod('startVad', {'id': id, ...options.toMap()});
  @override
  Future<String> finishVad(
    String id,
    VadDecision decision,
    VadEndpointConfig config, {
    List<VadChunk> chunks = const [],
  }) async =>
      await channel.invokeMethod<String>('finishVad', {
        'id': id,
        'startWindow': decision.startWindow,
        'endWindow': decision.endWindow,
        'atWindow': decision.atWindow,
        'reason': decision.reason.name,
        'config': config.toJson(),
        'chunks': [for (final chunk in chunks) chunk.toList()],
      }) ??
      '';
  @override
  Future<VadModelStatus> vadModelStatus() async => VadModelStatus.fromMap(
    await channel.invokeMapMethod<Object?, Object?>('vadModelStatus') ?? {},
  );
  @override
  Future<void> installVadModel() => channel.invokeMethod('installVadModel');
  @override
  Future<void> cancelVadModelInstall() =>
      channel.invokeMethod('cancelVadModelInstall');
  @override
  Future<void> removeVadModel() => channel.invokeMethod('removeVadModel');
  @override
  Future<void> prepareVad() => channel.invokeMethod('prepareVad');
  @override
  Future<void> releaseVad() => channel.invokeMethod('releaseVad');
  @override
  Future<void> setMediaKeys(bool on) =>
      channel.invokeMethod('setMediaKeys', {'on': on});
  @override
  Future<void> keepScreenOn(bool on) =>
      channel.invokeMethod('keepScreenOn', {'on': on});
  @override
  Future<int> deleteVadDebugRecordings() async =>
      await channel.invokeMethod<int>('deleteVadDebugRecordings') ?? 0;
}

class VadCaptureOptions {
  const VadCaptureOptions({
    required this.cues,
    required this.debug,
    required this.source,
    required this.maxDuration,
    this.startCue,
    this.keepPlayback = false,
  });
  final bool cues;
  final bool debug;
  final VadAudioSource source;
  final Duration maxDuration;

  /// "Listening" beep before capture; defaults to [cues]. Listen rounds that
  /// restart silently turn it off and keep the "got it" tone.
  final bool? startCue;

  /// Start capture without stopping read-aloud (barge-in listen rounds).
  final bool keepPlayback;

  Map<String, Object> toMap() => {
    'cues': cues,
    'debug': debug,
    'source': source.name,
    'maxMs': maxDuration.inMilliseconds,
    'startCue': startCue ?? cues,
    'keepPlayback': keepPlayback,
  };
}

enum VadModelState { absent, downloading, verifying, unpacking, installed, failed }

class VadModelStatus {
  const VadModelStatus({
    required this.state,
    this.bytes = 0,
    this.total = 0,
    this.error,
  });
  factory VadModelStatus.fromMap(Map<Object?, Object?> data) => VadModelStatus(
    state: VadModelState.values.firstWhere(
      (state) => state.name == data['state'],
      orElse: () => VadModelState.failed,
    ),
    bytes: (data['bytes'] as num?)?.toInt() ?? 0,
    total: (data['total'] as num?)?.toInt() ?? 0,
    error: data['error'] as String?,
  );
  final VadModelState state;
  final int bytes;
  final int total;
  final String? error;
}

/// Media keys and keep-screen-on are single native switches. Several Dart
/// owners (stacked workspaces) may want them at once, so the native state
/// follows the set of holders: on while any holds, off when the last releases.
class VoiceSwitchHolders {
  VoiceSwitchHolders(this._apply);

  static final _byDevice = Expando<Map<String, VoiceSwitchHolders>>('holders');

  /// Shared holder set for one native switch of [device].
  static VoiceSwitchHolders mediaKeys(VoiceDevice device) =>
      _of(device, 'mediaKeys', device.setMediaKeys);

  static VoiceSwitchHolders screenOn(VoiceDevice device) =>
      _of(device, 'screenOn', device.keepScreenOn);

  static VoiceSwitchHolders _of(
    VoiceDevice device,
    String name,
    Future<void> Function(bool) apply,
  ) => (_byDevice[device] ??= {}).putIfAbsent(
    name,
    () => VoiceSwitchHolders(apply),
  );

  final Future<void> Function(bool) _apply;
  final _holders = <Object>{};

  /// Registers or drops [owner]; talks to the device only when the first
  /// holder arrives or the last one leaves.
  void set(Object owner, bool on) {
    final wasOn = _holders.isNotEmpty;
    if (on) {
      _holders.add(owner);
    } else {
      _holders.remove(owner);
    }
    final isOn = _holders.isNotEmpty;
    if (isOn != wasOn) {
      unawaited(_apply(isOn).catchError((Object _) {}));
    }
  }
}

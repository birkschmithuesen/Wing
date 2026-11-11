import 'dart:async';
import '../core/services/android_voice.dart';
import '../core/services/vad_endpoint.dart';
import '../core/services/voice_preferences.dart';

/// The vad, switch and mic-link operations of a voice device. Every production
/// and test [VoiceDevice] also implements this.
abstract interface class VadVoiceDevice {
  /// The vad side of [device]; every [VoiceDevice] implements both.
  static VadVoiceDevice of(VoiceDevice device) => device as VadVoiceDevice;

  /// Route vad: own capture; probabilities arrive as `{id, first, windows}` events.
  /// Answers true when a manual [VadCaptureOptions.mic] choice was not available and
  /// the native side fell back to automatic routing for this round.
  Future<bool> startVad(String id, VadCaptureOptions options);

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

  /// Opens the classic-SCO link for [reason] and keeps it open across every
  /// following vad round (dictation, listening-in, read-aloud barge-in)
  /// until [closeMicLink] — a car kit's SCO channel otherwise opens and
  /// closes per round (spec Birk decision 2026-10-19: car kits keep SCO open
  /// for the whole conversation). Answers whether the link became ready.
  Future<bool> openMicLink(String reason);

  /// Ends the hold started by [openMicLink].
  Future<void> closeMicLink(String reason);
}

/// Platform implementation on [AndroidVoice]'s channel; mixed into [AndroidVoice].
mixin AndroidVadVoice implements VadVoiceDevice {
  @override
  Future<bool> startVad(String id, VadCaptureOptions options) async =>
      await AndroidVoice.channel.invokeMethod<bool>('startVad', {
        'id': id,
        ...options.toMap(),
      }) ??
      false;
  @override
  Future<String> finishVad(
    String id,
    VadDecision decision,
    VadEndpointConfig config, {
    List<VadChunk> chunks = const [],
  }) async =>
      await AndroidVoice.channel.invokeMethod<String>('finishVad', {
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
    await AndroidVoice.channel.invokeMapMethod<Object?, Object?>(
          'vadModelStatus',
        ) ??
        {},
  );
  @override
  Future<void> installVadModel() =>
      AndroidVoice.channel.invokeMethod('installVadModel');
  @override
  Future<void> cancelVadModelInstall() =>
      AndroidVoice.channel.invokeMethod('cancelVadModelInstall');
  @override
  Future<void> removeVadModel() =>
      AndroidVoice.channel.invokeMethod('removeVadModel');
  @override
  Future<void> prepareVad() => AndroidVoice.channel.invokeMethod('prepareVad');
  @override
  Future<void> releaseVad() => AndroidVoice.channel.invokeMethod('releaseVad');
  @override
  Future<void> setMediaKeys(bool on) =>
      AndroidVoice.channel.invokeMethod('setMediaKeys', {'on': on});
  @override
  Future<void> keepScreenOn(bool on) =>
      AndroidVoice.channel.invokeMethod('keepScreenOn', {'on': on});
  @override
  Future<int> deleteVadDebugRecordings() async =>
      await AndroidVoice.channel.invokeMethod<int>('deleteVadDebugRecordings') ??
      0;
  @override
  Future<bool> openMicLink(String reason) async =>
      await AndroidVoice.channel.invokeMethod<bool>('openMicLink', {
        'reason': reason,
      }) ??
      false;
  @override
  Future<void> closeMicLink(String reason) =>
      AndroidVoice.channel.invokeMethod('closeMicLink', {'reason': reason});
}

class VadCaptureOptions {
  const VadCaptureOptions({
    required this.cues,
    required this.debug,
    required this.source,
    required this.maxDuration,
    this.startCue,
    this.keepPlayback = false,
    this.mic = VoiceMicRoute.auto,
    this.holdMic = false,
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

  /// Native side decides the headset only for [VoiceMicRoute.auto]; any other
  /// value skips the decision (spec 2026-10-18 manual mic).
  final VoiceMicRoute mic;

  /// A [CarMicSession] already holds the Bluetooth link open for this round;
  /// native skips its own per-round acquire/release and uses the held device
  /// (spec Birk decision 2026-10-19: car kits keep SCO open for the whole
  /// conversation, not just one round).
  final bool holdMic;

  Map<String, Object> toMap() => {
    'cues': cues,
    'debug': debug,
    'source': source.name,
    'maxMs': maxDuration.inMilliseconds,
    'startCue': startCue ?? cues,
    'keepPlayback': keepPlayback,
    'mic': mic.name,
    'holdMic': holdMic,
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
      _of(device, 'mediaKeys', VadVoiceDevice.of(device).setMediaKeys);

  static VoiceSwitchHolders screenOn(VoiceDevice device) =>
      _of(device, 'screenOn', VadVoiceDevice.of(device).keepScreenOn);

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

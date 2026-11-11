import 'dart:async';
import 'package:wing/core/services/vad_endpoint.dart';
import 'package:wing/voice_offline/vad_voice_device.dart';

/// Vad, switch and mic-link side of the fake voice device. The members below
/// the abstract fields are shared with [VoiceDeviceFixture].
mixin VadVoiceFixture implements VadVoiceDevice {
  abstract final StreamController<Map<String, dynamic>> stream;
  abstract final List<String> calls;
  abstract String? recording;
  abstract bool? local;
  abstract final Completer<void>? startDelay;
  abstract final Object? startError;

  Duration? lastStopTimeout;
  int vadStarts = 0;
  VadCaptureOptions? vadOptions;
  bool micFallback = false;
  final finishes = <VadDecision>[];
  final finishChunks = <List<VadChunk>>[];
  String vadTranscript = 'Hello from the phone';
  Completer<String>? finishDelay;
  Object? finishError;
  VadModelStatus modelStatus = const VadModelStatus(state: VadModelState.installed);
  final keepScreenOnCalls = <bool>[];
  final mediaKeysCalls = <bool>[];
  int prepares = 0;
  int releases = 0;
  int installs = 0;
  int cancelInstalls = 0;
  int removals = 0;
  int debugDeletes = 0;
  int _firstWindow = 0;
  final micLinkOpens = <String>[];
  final micLinkCloses = <String>[];
  bool micLinkReady = true;

  /// Sends one probability batch for the running vad round.
  void emitWindows(List<double> windows) {
    stream.add({'id': recording, 'first': _firstWindow, 'windows': windows});
    _firstWindow += windows.length;
  }

  void emitMediaKey() => stream.add({'mediaKey': 'playPause'});
  void emitModel(VadModelStatus status) {
    modelStatus = status;
    stream.add({
      'model': {
        'state': status.state.name,
        'bytes': status.bytes,
        'total': status.total,
        'error': ?status.error,
      },
    });
  }

  @override
  Future<bool> startVad(String id, VadCaptureOptions options) async {
    calls.add('startVad');
    vadStarts++;
    recording = id;
    local = true;
    vadOptions = options;
    _firstWindow = 0;
    if (startError != null) throw startError!;
    await startDelay?.future;
    return micFallback;
  }

  @override
  Future<String> finishVad(
    String id,
    VadDecision decision,
    VadEndpointConfig config, {
    List<VadChunk> chunks = const [],
  }) async {
    calls.add('finishVad');
    finishes.add(decision);
    finishChunks.add(chunks);
    if (finishError != null) throw finishError!;
    return finishDelay?.future ?? vadTranscript;
  }

  @override
  Future<VadModelStatus> vadModelStatus() async => modelStatus;
  @override
  Future<void> installVadModel() async => installs++;
  @override
  Future<void> cancelVadModelInstall() async => cancelInstalls++;
  @override
  Future<void> removeVadModel() async {
    removals++;
    modelStatus = const VadModelStatus(state: VadModelState.absent);
  }
  @override
  Future<void> prepareVad() async => prepares++;
  @override
  Future<void> releaseVad() async => releases++;
  @override
  Future<void> setMediaKeys(bool on) async => mediaKeysCalls.add(on);
  @override
  Future<void> keepScreenOn(bool on) async => keepScreenOnCalls.add(on);
  @override
  Future<int> deleteVadDebugRecordings() async {
    debugDeletes++;
    return 3;
  }

  @override
  Future<bool> openMicLink(String reason) async {
    micLinkOpens.add(reason);
    return micLinkReady;
  }

  @override
  Future<void> closeMicLink(String reason) async {
    micLinkCloses.add(reason);
  }
}

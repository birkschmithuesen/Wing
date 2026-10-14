import 'dart:async';
import 'dart:typed_data';
import 'package:wing/core/services/android_voice.dart';
import 'package:wing/core/services/hermes_voice.dart';
import 'package:wing/core/services/vad_endpoint.dart';

class VoiceDeviceFixture implements VoiceDevice {
  final stream = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final calls = <String>[];
  final cancelled = <String>[];
  String? recording;
  String? playing;
  bool? local;
  String? language;
  String? spoken;
  String? voice;
  double? rate;
  Completer<void>? startDelay;
  Completer<void>? playbackDelay;
  Object? startError;
  Duration? lastStopTimeout;
  int vadStarts = 0;
  VadCaptureOptions? vadOptions;
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
  Future<void> startVad(String id, VadCaptureOptions options) async {
    calls.add('startVad');
    vadStarts++;
    recording = id;
    local = true;
    vadOptions = options;
    _firstWindow = 0;
    if (startError != null) throw startError!;
    await startDelay?.future;
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
  AndroidVoiceCapabilities capabilitiesValue = const AndroidVoiceCapabilities(
    recognitionAvailable: true,
    installedLanguages: ['en-US', 'fr-FR'],
    voices: [
      (id: 'english', label: 'English · offline voice'),
      (id: 'french', label: 'French · offline voice'),
    ],
  );
  @override
  Stream<Map<String, dynamic>> get events => stream.stream;
  @override
  Future<AndroidVoiceCapabilities> capabilities() async => capabilitiesValue;
  @override
  Future<void> start(
    String id, {
    required bool local,
    required String language,
  }) async {
    calls.add('start');
    recording = id;
    this.local = local;
    this.language = language;
    if (startError != null) throw startError!;
    await startDelay?.future;
  }

  @override
  Future<Uint8List?> stop(String id, {required Duration timeout}) async {
    calls.add('stop');
    lastStopTimeout = timeout;
    return local == true ? null : Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<void> cancel(String id) async {
    cancelled.add(id);
    if (recording == id) recording = null;
  }

  @override
  Future<void> speak(
    String id,
    String text, {
    required String voice,
    required double rate,
  }) async {
    calls.add('speak');
    playing = id;
    spoken = text;
    this.voice = voice;
    this.rate = rate;
    await playbackDelay?.future;
  }

  @override
  Future<void> play(String id, Uint8List bytes) async {
    calls.add('play');
    playing = id;
    await playbackDelay?.future;
  }

  @override
  Future<void> stopPlayback(String id) async {
    calls.add('stopPlayback');
    if (playing == id) playing = null;
  }
}

class RemoteVoiceFixture implements RemoteVoice {
  final calls = <String>[];
  bool closed = false;
  String? spoken;
  Completer<String>? transcriptDelay;
  Completer<Uint8List>? synthesisDelay;
  Object? failure;
  @override
  Future<String> transcribe(Uint8List audio) async {
    calls.add('transcribe');
    if (failure != null) throw failure!;
    return transcriptDelay?.future ?? 'Hello from Hermes';
  }

  @override
  Future<Uint8List> synthesize(String text) async {
    calls.add('synthesize');
    spoken = text;
    if (failure != null) throw failure!;
    return synthesisDelay?.future ?? Uint8List.fromList([4, 5, 6]);
  }

  @override
  void close() {
    closed = true;
  }
}

import 'dart:async';
import 'dart:typed_data';
import 'package:wing/core/services/android_voice.dart';
import 'package:wing/core/services/hermes_voice.dart';
import 'package:wing/voice_offline/vad_voice_device.dart';
import 'vad_voice_fixture.dart';

class VoiceDeviceFixture with VadVoiceFixture implements VoiceDevice, VadVoiceDevice {
  @override
  final stream = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  @override
  final calls = <String>[];
  final cancelled = <String>[];
  @override
  String? recording;
  String? playing;
  @override
  bool? local;
  String? language;
  String? spoken;
  String? voice;
  double? rate;
  @override
  Completer<void>? startDelay;
  Completer<void>? playbackDelay;
  @override
  Object? startError;
  final vadOptionsHistory = <VadCaptureOptions>[];

  @override
  Future<bool> startVad(String id, VadCaptureOptions options) async {
    final result = await super.startVad(id, options);
    vadOptionsHistory.add(vadOptions!);
    return result;
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
  Future<Uint8List?> stop(String id, {Duration timeout = const Duration(seconds: 5)}) async {
    calls.add('stop');
    lastStopTimeout = timeout;
    if (recording != id) return null;
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

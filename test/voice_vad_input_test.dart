import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/controllers/voice_input_controller.dart';
import 'package:wing/core/services/vad_endpoint.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'support/voice_fixture.dart';

List<double> _p(double value, int count) => List.filled(count, value);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VoiceDeviceFixture device;
  late VoiceInputController recorder;
  TextEditingValue? result;
  const settings = VoicePreferences(
    input: VoiceInputRoute.vad,
    cues: false,
    debugRecordings: true,
    audioSource: VadAudioSource.recognition,
    vad: VadEndpointConfig(
      maxDuration: Duration(seconds: 60),
      noSpeechTimeout: Duration(seconds: 12),
    ),
  );

  setUp(() {
    device = VoiceDeviceFixture();
    recorder = VoiceInputController(
      device: device,
      createRemote: () => throw StateError('vad never uses Hermes'),
    );
    result = null;
  });
  tearDown(() async {
    recorder.dispose();
    await device.stream.close();
  });

  Future<void> start() => recorder.start(
    settings,
    const TextEditingValue(text: ''),
    (value) => result = value,
  );

  test('starts the own capture with the saved vad options', () async {
    await start();
    expect(device.calls, ['startVad']);
    expect(device.vadOptions!.toMap().containsKey('microphone'), isFalse);
    expect(device.vadOptions!.cues, isFalse);
    expect(device.vadOptions!.debug, isTrue);
    expect(device.vadOptions!.source, VadAudioSource.recognition);
    expect(device.vadOptions!.maxDuration, const Duration(seconds: 60));
    expect(recorder.phase, VoiceInputPhase.recording);
    expect(recorder.maxSeconds, 60);
    expect(recorder.vad, isTrue);
  });

  test('a pause ends the round by itself and inserts the phone transcript', () async {
    await start();
    device.emitWindows(_p(0.05, 40));
    device.emitWindows(_p(0.9, 60));
    expect(device.finishes, isEmpty);
    device.emitWindows(_p(0.1, 80));
    await pumpEventQueue();
    expect(device.finishes.single.reason, VadEndReason.pause);
    expect(device.finishes.single.startWindow, 30);
    expect(device.finishes.single.endWindow, 108);
    expect(result!.text, 'Hello from the phone');
    expect(recorder.finishedOnItsOwn, isTrue);
    expect(recorder.active, isFalse);
  });

  test('a thinking pause shorter than the setting keeps recording', () async {
    await start();
    device.emitWindows(_p(0.9, 30));
    device.emitWindows(_p(0.1, 31));
    device.emitWindows(_p(0.9, 10));
    await pumpEventQueue();
    expect(device.finishes, isEmpty);
    expect(recorder.phase, VoiceInputPhase.recording);
  });

  test('Stop ends the round manually and is not hands-free', () async {
    await start();
    device.emitWindows(_p(0.9, 20));
    await recorder.stop();
    await pumpEventQueue();
    expect(device.finishes.single.reason, VadEndReason.manual);
    expect(device.finishes.single.endWindow, 20);
    expect(result!.text, 'Hello from the phone');
    expect(recorder.finishedOnItsOwn, isFalse);
  });

  test('the media key ends the round hands-free', () async {
    await start();
    device.emitWindows(_p(0.9, 20));
    await recorder.stopHandsFree();
    await pumpEventQueue();
    expect(device.finishes.single.reason, VadEndReason.mediaKey);
    expect(recorder.finishedOnItsOwn, isTrue);
  });

  test('no speech within the no-speech timeout ends the round without recognition', () async {
    await start();
    // 12 s timeout = 375 windows. 7 s (218 windows) is no limit on this route.
    device.emitWindows(_p(0.05, 374));
    await pumpEventQueue();
    expect(recorder.phase, VoiceInputPhase.recording);
    expect(recorder.error, isNull);
    device.emitWindows(_p(0.05, 1));
    await pumpEventQueue();
    // The phone only learns the reason (for the debug JSON); Kotlin skips recognition.
    expect(device.finishes.single.reason, VadEndReason.noSpeech);
    expect(device.finishes.single.atWindow, 374);
    expect(recorder.error, 'No speech detected. Try again.');
    expect(device.cancelled, isNotEmpty);
    expect(result, isNull);
  });

  test('an empty transcript is reported as no speech', () async {
    device.vadTranscript = '  ';
    await start();
    device.emitWindows(_p(0.9, 20));
    device.emitWindows(_p(0.1, 60));
    await pumpEventQueue();
    expect(recorder.error, 'No speech detected. Try again.');
  });

  test('a missing model is reported from start', () async {
    device.startError = PlatformException(
      code: 'voice_unavailable',
      message: 'Download the speech model in App settings → Voice.',
    );
    await start();
    expect(recorder.error, 'Download the speech model in App settings → Voice.');
    expect(recorder.active, isFalse);
  });

  test('windows after the decision are ignored', () async {
    device.finishDelay = Completer<String>();
    await start();
    device.emitWindows(_p(0.9, 20));
    device.emitWindows(_p(0.1, 60));
    device.emitWindows(_p(0.9, 60));
    device.emitWindows(_p(0.1, 60));
    await pumpEventQueue();
    expect(device.finishes, hasLength(1));
    expect(recorder.phase, VoiceInputPhase.transcribing);
    device.finishDelay!.complete('Done');
    await pumpEventQueue();
    expect(result!.text, 'Done');
  });

  testWidgets('recognition gets a budget that scales with the segment', (tester) async {
    // Listeners run in the zone that subscribed; rebuild inside the fake-async
    // test zone so the recognition budget timer follows tester.pump.
    recorder.dispose();
    device = VoiceDeviceFixture();
    recorder = VoiceInputController(
      device: device,
      createRemote: () => throw StateError('vad never uses Hermes'),
    );
    device.finishDelay = Completer<String>();
    await start();
    // 2 s of speech + tail: budget = 10 s + half the segment (≈ 11.3 s).
    device.emitWindows(_p(0.9, 62));
    device.emitWindows(_p(0.1, 60));
    await tester.pump();
    expect(recorder.phase, VoiceInputPhase.transcribing);
    await tester.pump(const Duration(seconds: 11));
    expect(recorder.error, isNull, reason: 'still within the budget');
    await tester.pump(const Duration(seconds: 1));
    expect(recorder.error, 'Speech processing timed out. Please retry.');
    expect(device.cancelled, isNotEmpty);
  });
}

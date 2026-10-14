import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/vad_endpoint.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'package:wing/voice_offline/turn_listener.dart';
import '../support/voice_fixture.dart';

// pause is shortened from the 1800 ms default: at maxDuration = 2 s
// (62 windows) a 20-window speech leaves only 42 windows of silence budget
// before the round hits maxDuration, which is less than the default 57
// pause windows and would starve the pause decision this file exercises.
const settings = VoicePreferences(
  input: VoiceInputRoute.vad,
  conversation: true,
  vad: VadEndpointConfig(
    pause: Duration(milliseconds: 960),
    maxDuration: Duration(seconds: 2),
  ),
);

void main() {
  late VoiceDeviceFixture device;
  late TurnListener listener;
  late List<String> heard;
  late int barges;

  setUp(() {
    device = VoiceDeviceFixture();
    listener = TurnListener(device: device);
    heard = [];
    barges = 0;
    listener.onUtterance = heard.add;
    listener.onBarge = () async => barges++;
  });
  tearDown(() async {
    listener.dispose();
    await device.stream.close();
  });

  Future<void> say(double p, int count) async {
    device.emitWindows(List.filled(count, p));
    await pumpEventQueue();
  }

  test('an utterance is transcribed, handed over and the next round starts', () async {
    await listener.open(settings);
    expect(device.vadOptions!.keepPlayback, isTrue);
    expect(device.vadOptions!.startCue, isFalse);
    expect(listener.phase, ListenPhase.listening);
    await say(0.9, 20);
    expect(listener.speechInProgress, isTrue);
    await say(0.1, 60);
    expect(device.finishes.single.reason, VadEndReason.pause);
    expect(heard, ['Hello from the phone']);
    expect(device.vadStarts, 2);
    expect(listener.isOpen, isTrue);
  });

  test('silence restarts the round at max duration without recognition', () async {
    await listener.open(settings);
    final first = device.recording;
    await say(0.1, 70);
    expect(device.finishes, isEmpty);
    expect(device.cancelled, contains(first));
    expect(device.vadStarts, 2);
    expect(heard, isEmpty);
  });

  test('during playback a cough is rejected and read-aloud continues', () async {
    await listener.open(settings, playback: true);
    await say(0.8, 14);
    await say(0.1, 60);
    expect(barges, 0);
    expect(device.finishes, isEmpty);
    expect(heard, isEmpty);
    expect(device.vadStarts, 2);
  });

  test('during playback real speech stops read-aloud once and is transcribed', () async {
    await listener.open(settings, playback: true);
    await say(0.9, 30);
    expect(barges, 1);
    await say(0.1, 60);
    expect(barges, 1);
    expect(heard, ['Hello from the phone']);
  });

  test('after playback ended the normal rules apply again', () async {
    await listener.open(settings, playback: true);
    listener.setPlayback(false);
    await say(0.8, 14);
    await say(0.1, 60);
    expect(barges, 0);
    expect(heard, ['Hello from the phone']);
  });

  test('close cancels the round and nothing restarts', () async {
    await listener.open(settings);
    final id = device.recording;
    await listener.close('test');
    expect(device.cancelled, contains(id));
    expect(listener.isOpen, isFalse);
    await say(0.9, 30);
    await say(0.1, 60);
    expect(heard, isEmpty);
    expect(device.vadStarts, 1);
  });

  test('a transcript that arrives after close is dropped', () async {
    await listener.open(settings);
    device.finishDelay = Completer<String>();
    await say(0.9, 20);
    await say(0.1, 60);
    expect(listener.phase, ListenPhase.transcribing);
    await listener.close('test');
    device.finishDelay!.complete('Late words');
    await pumpEventQueue();
    expect(heard, isEmpty);
    expect(device.vadStarts, 1);
  });

  test('media key without speech closes, with speech ends the utterance', () async {
    await listener.open(settings);
    await listener.endUtterance();
    expect(listener.isOpen, isFalse);
    await listener.open(settings);
    await say(0.9, 20);
    await listener.endUtterance();
    await pumpEventQueue();
    expect(device.finishes.single.reason, VadEndReason.mediaKey);
    expect(heard, ['Hello from the phone']);
  });

  test('probe collects statistics only and closes', () async {
    final stats = await listener.probe(settings, () async {
      device.emitWindows([0.1, 0.2, 0.6, 0.6]);
      await pumpEventQueue();
    });
    expect(stats.windows, 4);
    expect(stats.max, 0.6);
    expect(stats.run50, 2);
    expect(device.vadOptions!.cues, isFalse);
    expect(device.finishes, isEmpty);
    expect(heard, isEmpty);
    expect(listener.isOpen, isFalse);
  });
}

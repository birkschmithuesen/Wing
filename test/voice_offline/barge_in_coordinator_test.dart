import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'package:wing/voice_offline/barge_in_coordinator.dart';
import 'package:wing/voice_offline/barge_in_policy.dart';
import 'package:wing/voice_offline/turn_listener.dart';
import '../support/voice_fixture.dart';

class _Target implements ListenTarget {
  ListenChatState current = ListenChatState.steerable;
  bool steerAnswer = true;
  ListenChatState? stateAfterSteer;
  final log = <String>[];

  @override
  ListenChatState get state => current;
  @override
  Future<bool> steer(String text) async {
    log.add('steer:$text');
    if (stateAfterSteer != null) current = stateAfterSteer!;
    return steerAnswer;
  }

  @override
  Future<void> queue(String text) async => log.add('queue:$text');
  @override
  Future<void> send(String text) async => log.add('send:$text');
}

const settings = VoicePreferences(input: VoiceInputRoute.vad, conversation: true);

void main() {
  late VoiceDeviceFixture device;
  late BargeInCoordinator coordinator;
  late _Target target;

  setUp(() async {
    device = VoiceDeviceFixture();
    coordinator = BargeInCoordinator(TurnListener(device: device));
    target = _Target();
    await coordinator.open('chat-a', target, settings);
  });
  tearDown(() async {
    coordinator.dispose();
    await device.stream.close();
  });

  Future<void> utter(String text) async {
    device.vadTranscript = text;
    device.emitWindows(List.filled(20, 0.9));
    device.emitWindows(List.filled(60, 0.1));
    await pumpEventQueue();
    await coordinator.settled;
  }

  test('a running turn is steered and remembered', () async {
    await utter('Testsatz eins');
    expect(target.log, ['steer:Testsatz eins']);
    expect(coordinator.steered, isTrue);
    coordinator.beginTurn();
    expect(coordinator.steered, isFalse);
  });

  test('a rejected steer on an ended turn becomes a normal prompt', () async {
    target.steerAnswer = false;
    target.stateAfterSteer = ListenChatState.idle;
    await utter('Testsatz zwei');
    expect(target.log, ['steer:Testsatz zwei', 'send:Testsatz zwei']);
    expect(coordinator.steered, isFalse);
  });

  test('a rejected steer on a still running turn is queued', () async {
    target.steerAnswer = false;
    await utter('Testsatz drei');
    expect(target.log, ['steer:Testsatz drei', 'queue:Testsatz drei']);
  });

  test('busy and idle chats queue or send directly', () async {
    target.current = ListenChatState.busy;
    await utter('Testsatz vier');
    target.current = ListenChatState.idle;
    await utter('Testsatz fünf');
    expect(target.log, ['queue:Testsatz vier', 'send:Testsatz fünf']);
  });

  test('fillers and empty transcripts are dropped', () async {
    await utter('ähm');
    await utter('  ');
    expect(target.log, isEmpty);
  });

  test('utterances are delivered one after another', () async {
    await utter('Testsatz sechs');
    await utter('Testsatz sieben');
    expect(target.log, ['steer:Testsatz sechs', 'steer:Testsatz sieben']);
  });

  test('close stops listening and forgets the target', () async {
    await coordinator.close('test');
    expect(coordinator.listening, isFalse);
    expect(coordinator.chat, isNull);
  });

  Future<void> bargeIn(String text) async {
    await coordinator.open(
      'chat-a',
      target,
      settings,
      playback: true,
      onBarge: () async {},
    );
    await utter(text);
  }

  test('words that cut off read-aloud carry the hint when sent or queued', () async {
    target.current = ListenChatState.idle;
    await bargeIn('Testsatz zwei, stopp');
    target.current = ListenChatState.busy;
    await bargeIn('Testsatz drei');
    expect(target.log, [
      'send:${withInterruptedReplyHint('Testsatz zwei, stopp')}',
      'queue:${withInterruptedReplyHint('Testsatz drei')}',
    ]);
  });

  test('a steer never carries the hint, even after a barge-in', () async {
    await bargeIn('Testsatz vier');
    expect(target.log, ['steer:Testsatz vier']);
  });
}

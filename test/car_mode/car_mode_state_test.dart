import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/car_mode/car_mode_state.dart';
import 'package:wing/core/controllers/voice_input_controller.dart';

void main() {
  const idle = CarSnapshot(chatKey: 'chat');

  test('phase priority: attention > listening > transcribing > speaking > waiting > thinking > error > idle', () {
    expect(carPhaseOf(idle), CarPhase.idle);
    expect(carPhaseOf(const CarSnapshot(chatKey: 'c', error: 'x')), CarPhase.error);
    expect(carPhaseOf(const CarSnapshot(chatKey: 'c', error: 'x', working: true)), CarPhase.thinking);
    expect(carPhaseOf(const CarSnapshot(chatKey: 'c', working: true), held: true), CarPhase.waiting);
    expect(carPhaseOf(const CarSnapshot(chatKey: 'c', speaking: true), held: true), CarPhase.speaking);
    expect(
      carPhaseOf(const CarSnapshot(chatKey: 'c', speaking: true, input: VoiceInputPhase.transcribing)),
      CarPhase.transcribing,
    );
    expect(carPhaseOf(const CarSnapshot(chatKey: 'c', input: VoiceInputPhase.starting)), CarPhase.listening);
    expect(
      carPhaseOf(const CarSnapshot(chatKey: 'c', input: VoiceInputPhase.recording), held: true),
      CarPhase.listening,
    );
    expect(
      carPhaseOf(const CarSnapshot(chatKey: 'c', input: VoiceInputPhase.recording, needsInput: true)),
      CarPhase.attention,
    );
    // The connection alone never changes the phase; the badge shows it.
    expect(carPhaseOf(const CarSnapshot(chatKey: 'c', connection: CarConnection.offline)), CarPhase.idle);
  });

  test('tap table of spec 4.3', () {
    CarTapAction tap(CarSnapshot s, {bool held = false}) => carTapActionFor(carPhaseOf(s, held: held), s);
    expect(tap(idle), CarTapAction.talk);
    expect(tap(const CarSnapshot(chatKey: 'c', input: VoiceInputPhase.starting)), CarTapAction.ignore);
    expect(tap(const CarSnapshot(chatKey: 'c', input: VoiceInputPhase.recording)), CarTapAction.sendNow);
    expect(tap(const CarSnapshot(chatKey: 'c', input: VoiceInputPhase.transcribing)), CarTapAction.ignore);
    expect(tap(const CarSnapshot(chatKey: 'c', working: true)), CarTapAction.talk);
    expect(tap(const CarSnapshot(chatKey: 'c', speaking: true)), CarTapAction.talk);
    expect(tap(idle, held: true), CarTapAction.talk);
    expect(tap(const CarSnapshot(chatKey: 'c', needsInput: true)), CarTapAction.ignore);
    expect(tap(const CarSnapshot(chatKey: 'c', error: 'x')), CarTapAction.talk);
    expect(tap(const CarSnapshot(chatKey: 'c', connection: CarConnection.offline)), CarTapAction.talk);
  });

  test('every phase has a label and an icon; texts of spec 4.3', () {
    for (final phase in CarPhase.values) {
      expect(carTextFor(phase, idle).label, isNotEmpty);
      expect(carIconFor(phase), isA<IconData>());
    }
    const error = CarSnapshot(chatKey: 'c', error: 'No speech detected. Try again.');
    expect(carTextFor(CarPhase.error, error).detail, 'No speech detected. Try again.');
    expect(carTextFor(CarPhase.idle, idle).label, 'Tap to talk');
    expect(carTextFor(CarPhase.listening, idle).hint, 'Tap to send');
    expect(carTextFor(CarPhase.waiting, idle).label, 'Waiting for connection');
    expect(carTextFor(CarPhase.waiting, idle).hint, 'Sends when back online');
  });

  test('status line: kind or tool name only, generic Working left to the thinking label', () {
    const terminal = CarSnapshot(chatKey: 'c', working: true, activity: 'Terminal');
    const working = CarSnapshot(chatKey: 'c', working: true, activity: carWorking);
    expect(carStatusLine(CarPhase.thinking, terminal), 'Terminal');
    expect(carStatusLine(CarPhase.listening, terminal), 'Terminal');
    expect(carStatusLine(CarPhase.thinking, working), isNull);
    expect(carStatusLine(CarPhase.listening, working), carWorking);
    expect(carStatusLine(CarPhase.idle, idle), isNull);
  });

  test('connection texts', () {
    expect(carConnectionText(CarConnection.ok).label, 'Connected');
    expect(carConnectionText(CarConnection.reconnecting).label, 'Reconnecting');
    expect(carConnectionText(CarConnection.offline).label, 'Offline');
    expect(
      CarConnection.values.map((c) => carConnectionText(c).icon).toSet(),
      hasLength(CarConnection.values.length),
    );
  });

  test('swipe exits on distance or on a fast flick, never on a short slide', () {
    expect(carSwipeExits(dx: -96, velocity: 0, width: 411), isTrue);
    expect(carSwipeExits(dx: 95, velocity: 0, width: 411), isFalse);
    expect(carSwipeExits(dx: 80, velocity: 0, width: 320), isTrue); // 25 % of 320 dp
    expect(carSwipeExits(dx: 50, velocity: -900, width: 411), isTrue);
    expect(carSwipeExits(dx: 40, velocity: 2000, width: 411), isFalse);
    expect(carSwipeExits(dx: 60, velocity: 600, width: 411), isFalse);
  });

  test('carDeliveryFor', () {
    expect(carDeliveryFor(working: false, steerAvailable: false, queueAvailable: false), CarDelivery.send);
    expect(carDeliveryFor(working: true, steerAvailable: true, queueAvailable: true), CarDelivery.steer);
    expect(carDeliveryFor(working: true, steerAvailable: false, queueAvailable: true), CarDelivery.queue);
    expect(carDeliveryFor(working: true, steerAvailable: false, queueAvailable: false), CarDelivery.end);
  });

  testWidgets('CarTapGate ignores a second tap within 600 ms, accepts after', (tester) async {
    final gate = CarTapGate();
    addTearDown(gate.dispose);
    expect(gate.accept(), isTrue);
    await tester.pump(const Duration(milliseconds: 599));
    expect(gate.accept(), isFalse);
    await tester.pump(const Duration(milliseconds: 2));
    expect(gate.accept(), isTrue);
    await tester.pump(const Duration(milliseconds: 700));
  });
}

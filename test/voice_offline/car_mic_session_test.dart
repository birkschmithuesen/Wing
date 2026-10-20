import 'package:flutter_test/flutter_test.dart';
import 'package:wing/voice_offline/car_mic_session.dart';

import '../support/voice_fixture.dart';

void main() {
  late VoiceDeviceFixture device;
  late List<String> logs;
  late CarMicSession session;

  setUp(() {
    device = VoiceDeviceFixture();
    logs = [];
    session = CarMicSession(
      device,
      idleTimeout: const Duration(milliseconds: 50),
      log: logs.add,
    );
  });

  tearDown(() => session.dispose());

  group('isCarKitClass (spec Birk decision 2026-10-19: car kit vs headphones)', () {
    test('hands-free and car-audio classes count as a car kit', () {
      expect(isCarKitClass(0x0408), isTrue);
      expect(isCarKitClass(0x0420), isTrue);
    });

    test('headphone classes and unknown do not', () {
      expect(isCarKitClass(0x0404), isFalse);
      expect(isCarKitClass(0x0418), isFalse);
      expect(isCarKitClass(null), isFalse);
    });
  });

  group('CarMicSession (Fake-AudioManager: SCO stays open for a whole conversation)', () {
    test('opens once and stays open across dictation, listening-in and read-aloud rounds', () async {
      expect(await session.beginRound('conversation'), isTrue);
      expect(await session.beginRound('conversation'), isTrue); // listening-in (Mithören)
      expect(await session.beginRound('conversation'), isTrue); // read-aloud barge-in (Reinreden)
      expect(await session.beginRound('conversation'), isTrue); // next dictation turn
      expect(device.micLinkOpens, ['conversation']);
      expect(device.micLinkCloses, isEmpty);
      expect(
        logs.where((line) => line.startsWith('WingMic sco=open')),
        ['WingMic sco=open reason=conversation'],
      );
      expect(session.isOpen, isTrue);
    });

    test('conversation end closes exactly once', () async {
      await session.beginRound('conversation');
      await session.end('end');
      expect(device.micLinkCloses, ['end']);
      expect(logs, contains('WingMic sco=close reason=end'));
      expect(session.isOpen, isFalse);
      // Ending an already-closed session is a no-op, not a second close.
      await session.end('end');
      expect(device.micLinkCloses, ['end']);
    });

    testWidgets('idle timeout closes the link automatically', (tester) async {
      await session.beginRound('conversation');
      await tester.pump(const Duration(milliseconds: 60));
      expect(device.micLinkCloses, ['idle']);
      expect(session.isOpen, isFalse);
    });

    testWidgets('activity resets the idle timer', (tester) async {
      await session.beginRound('conversation');
      await tester.pump(const Duration(milliseconds: 30));
      await session.beginRound('conversation');
      await tester.pump(const Duration(milliseconds: 30));
      expect(device.micLinkCloses, isEmpty);
      await tester.pump(const Duration(milliseconds: 30));
      expect(device.micLinkCloses, ['idle']);
    });

    test('a ready timeout falls back to the phone mic for this round without ending the loop', () async {
      device.micLinkReady = false;
      expect(await session.beginRound('conversation'), isFalse);
      expect(device.micLinkOpens, ['conversation']);
      expect(device.micLinkCloses, isEmpty);
      expect(logs, contains('WingMic sco=fail fallback=phone'));
      expect(session.isOpen, isFalse);
      // The next round can still try again; one failure does not abort it.
      device.micLinkReady = true;
      expect(await session.beginRound('conversation'), isTrue);
      expect(device.micLinkOpens, ['conversation', 'conversation']);
    });
  });
}

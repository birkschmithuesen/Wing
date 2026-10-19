import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/car_mode/car_mode_bridge.dart';
import 'package:wing/car_mode/car_mode_screen.dart';
import 'package:wing/car_mode/car_mode_session.dart';
import 'package:wing/car_mode/car_mode_state.dart';
import 'package:wing/core/controllers/voice_input_controller.dart';
import 'package:wing/core/services/voice_preferences.dart';
import '../support/voice_fixture.dart';

class _World extends ChangeNotifier {
  CarSnapshot snapshot = const CarSnapshot(chatKey: 'chat', title: 'Secret title');
  final calls = <String>[];
  void set(CarSnapshot next) {
    snapshot = next;
    notifyListeners();
  }
}

void main() {
  late VoiceDeviceFixture device;
  late _World world;
  late List<String> logs;
  late CarModeSession session;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    device = VoiceDeviceFixture();
    world = _World();
    logs = [];
    session = CarModeSession(
      device: device,
      log: logs.add,
      bridge: CarModeBridge(
        changes: world,
        read: () => world.snapshot,
        preferences: prefs,
        talk: () async => world.calls.add('talk'),
        sendNow: () async => world.calls.add('sendNow'),
        stopSpeech: () async => world.calls.add('stopSpeech'),
        retry: () async => world.calls.add('retry'),
        sendHeld: () async => world.calls.add('sendHeld'),
        leave: () => world.calls.add('leave'),
      ),
    );
  });
  tearDown(() async {
    session.dispose();
    await device.stream.close();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => session.enter(context),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  List<Object?> recordHaptics(WidgetTester tester) {
    final haptics = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    return haptics;
  }

  testWidgets('enter holds the screen on; a swipe exit leaves and releases it', (tester) async {
    await open(tester);
    expect(session.active, isTrue);
    expect(find.byType(CarModeScreen), findsOneWidget);
    expect(device.keepScreenOnCalls, [true]);
    expect(logs.first, 'WingCar enter route=local loop=off');
    session.swiped(exits: true);
    await tester.pumpAndSettle();
    expect(session.active, isFalse);
    expect(find.byType(CarModeScreen), findsNothing);
    expect(device.keepScreenOnCalls, [true, false]);
    expect(world.calls, ['leave']);
    expect(logs, containsAllInOrder(['WingCar swipe action=exit', 'WingCar exit reason=swipe']));
  });

  testWidgets('a short swipe neither leaves nor taps', (tester) async {
    await open(tester);
    session.swiped(exits: false);
    await tester.pump();
    expect(session.active, isTrue);
    expect(world.calls, isEmpty);
    expect(logs.last, 'WingCar swipe action=short');
    session.exit('test');
    await tester.pumpAndSettle();
  });

  testWidgets('Android Back leaves directly, without a hint', (tester) async {
    await open(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(session.active, isFalse);
    expect(find.byType(CarModeScreen), findsNothing);
    expect(world.calls, ['leave']);
    expect(device.keepScreenOnCalls, [true, false]);
    expect(logs.last, 'WingCar exit reason=back');
  });

  testWidgets('tap dispatches by phase and debounces', (tester) async {
    await open(tester);
    await session.tap();
    expect(world.calls, ['talk']);
    world.set(const CarSnapshot(chatKey: 'chat', input: VoiceInputPhase.recording));
    await session.tap(); // within 600 ms → debounced
    expect(world.calls, ['talk']);
    await tester.pump(const Duration(milliseconds: 650));
    await session.tap();
    expect(world.calls, ['talk', 'sendNow']);
    await tester.pump(const Duration(milliseconds: 650));
    world.set(const CarSnapshot(chatKey: 'chat', speaking: true));
    await session.tap();
    expect(world.calls, ['talk', 'sendNow', 'stopSpeech', 'talk']);
    await tester.pump(const Duration(milliseconds: 650));
    world.set(const CarSnapshot(chatKey: 'chat', needsInput: true));
    await session.tap();
    expect(world.calls.length, 4);
    expect(logs.last, 'WingCar tap phase=attention action=ignore');
    session.exit('test');
    await tester.pumpAndSettle();
  });

  testWidgets('a different chat on screen closes car mode', (tester) async {
    await open(tester);
    world.set(const CarSnapshot(chatKey: 'other'));
    await tester.pumpAndSettle();
    expect(session.active, isFalse);
    expect(find.byType(CarModeScreen), findsNothing);
    expect(logs.last, 'WingCar exit reason=chatChanged');
  });

  testWidgets('a held recording is released exactly once when the connection is back', (tester) async {
    await open(tester);
    world.set(const CarSnapshot(chatKey: 'chat', connection: CarConnection.offline));
    expect(session.holdForConnection(), isTrue);
    expect(session.phase, CarPhase.waiting);
    expect(session.holdForConnection(), isTrue); // still one hold
    expect(logs.where((l) => l == 'WingCar hold'), hasLength(1));
    world.set(const CarSnapshot(chatKey: 'chat', connection: CarConnection.reconnecting));
    world.set(const CarSnapshot(chatKey: 'chat', working: true));
    await tester.pump();
    expect(world.calls, isNot(contains('sendHeld'))); // Hermes still busy
    world.set(const CarSnapshot(chatKey: 'chat'));
    await tester.pump();
    world.set(const CarSnapshot(chatKey: 'chat'));
    world.set(const CarSnapshot(chatKey: 'chat'));
    await tester.pump();
    expect(world.calls.where((c) => c == 'sendHeld'), hasLength(1));
    expect(session.held, isFalse);
    expect(session.phase, CarPhase.idle);
    expect(session.holdForConnection(), isFalse); // connected: a normal send
    session.exit('test');
    await tester.pumpAndSettle();
  });

  testWidgets('a new round sent while connected carries the held text and clears the hold', (tester) async {
    await open(tester);
    world.set(const CarSnapshot(chatKey: 'chat', connection: CarConnection.offline));
    expect(session.holdForConnection(), isTrue);
    world.snapshot = const CarSnapshot(chatKey: 'chat', input: VoiceInputPhase.transcribing);
    expect(session.holdForConnection(), isFalse);
    expect(session.held, isFalse);
    world.set(const CarSnapshot(chatKey: 'chat'));
    await tester.pump();
    expect(world.calls, isNot(contains('sendHeld')));
    session.exit('test');
    await tester.pumpAndSettle();
  });

  testWidgets('while held and offline the session retries every 20 s', (tester) async {
    await open(tester);
    world.set(const CarSnapshot(chatKey: 'chat', connection: CarConnection.offline));
    session.holdForConnection();
    await tester.pump(const Duration(seconds: 19));
    expect(world.calls, isNot(contains('retry')));
    await tester.pump(const Duration(seconds: 2));
    expect(world.calls.where((c) => c == 'retry'), hasLength(1));
    await tester.pump(const Duration(seconds: 20));
    expect(world.calls.where((c) => c == 'retry'), hasLength(2));
    session.exit('test'); // cancels the timer
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 40));
    expect(world.calls.where((c) => c == 'retry'), hasLength(2));
  });

  testWidgets('connection loss vibrates three times, the return twice; blips stay quiet', (tester) async {
    final haptics = recordHaptics(tester);
    await open(tester);
    world.set(const CarSnapshot(chatKey: 'chat', connection: CarConnection.reconnecting));
    world.set(const CarSnapshot(chatKey: 'chat'));
    await tester.pump(const Duration(seconds: 1));
    expect(haptics, isEmpty);
    world.set(const CarSnapshot(chatKey: 'chat', connection: CarConnection.offline));
    await tester.pump(const Duration(seconds: 1));
    expect(haptics, [null, null, null]); // HapticFeedback.vibrate()
    world.set(const CarSnapshot(chatKey: 'chat', connection: CarConnection.reconnecting));
    world.set(const CarSnapshot(chatKey: 'chat'));
    await tester.pump(const Duration(seconds: 1));
    expect(haptics.skip(3), ['HapticFeedbackType.heavyImpact', 'HapticFeedbackType.heavyImpact']);
    expect(
      logs.where((l) => l.startsWith('WingCar connection')),
      [
        'WingCar connection state=reconnecting',
        'WingCar connection state=ok',
        'WingCar connection state=offline',
        'WingCar connection state=reconnecting',
        'WingCar connection state=ok',
      ],
    );
    session.exit('test');
    await tester.pumpAndSettle();
  });

  testWidgets('roundSettings: tap-only while the loop switch is off, no matter the saved setting', (tester) async {
    const off = VoicePreferences();
    const on = VoicePreferences(conversation: true);
    expect(identical(session.roundSettings(off), off), isTrue); // not in car mode
    await open(tester);
    expect(session.roundSettings(off).vad.pause, off.vad.maxDuration);
    // Mutation guard: a saved conversation=on must not leak into the loop.
    // If roundSettings reads settings.conversation again instead of the
    // session-local switch, this assertion goes red.
    expect(session.roundSettings(on).vad.pause, on.vad.maxDuration);
    session.setLoop(true);
    expect(identical(session.roundSettings(on), on), isTrue); // loop on: settings pass through
    session.exit('test');
    await tester.pumpAndSettle();
  });

  testWidgets('a saved conversation=on still enters with loop=off (spec: never starts hands-free)', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(VoicePreferences.conversationKey, 'on');
    await open(tester);
    expect(logs.first, 'WingCar enter route=local loop=off');
    expect(session.loopOn, isFalse);
    const saved = VoicePreferences(conversation: true);
    // Tap-only: the vad pause can never end the round before the limit.
    expect(session.roundSettings(saved).vad.pause, saved.vad.maxDuration);
    session.exit('test');
    await tester.pumpAndSettle();
  });

  testWidgets('the loop switch only affects the running session and resets on leave', (tester) async {
    await open(tester);
    expect(session.loopOn, isFalse);
    session.setLoop(true);
    expect(session.loopOn, isTrue);
    expect(logs.last, 'WingCar loop=on source=toggle');
    const saved = VoicePreferences();
    expect(identical(session.roundSettings(saved), saved), isTrue); // loop on: pass through
    session.setLoop(false);
    expect(logs.last, 'WingCar loop=off source=toggle');
    expect(session.roundSettings(saved).vad.pause, saved.vad.maxDuration); // loop off: tap-only again
    // The saved VoicePreferences.conversation flag never changes.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(VoicePreferences.conversationKey), isNull);
    session.exit('test');
    await tester.pumpAndSettle();
    await open(tester); // re-enter: back to off
    expect(session.loopOn, isFalse);
    expect(logs.last, 'WingCar enter route=local loop=off');
    session.exit('test');
    await tester.pumpAndSettle();
  });

  testWidgets('the Interrupt-by-speaking switch only affects the running session and resets on leave', (tester) async {
    await open(tester);
    expect(session.bargeInOn, isFalse);
    session.setBargeIn(true);
    expect(session.bargeInOn, isTrue);
    expect(logs.last, 'WingCar bargeIn=on source=toggle');
    session.setBargeIn(false);
    expect(session.bargeInOn, isFalse);
    expect(logs.last, 'WingCar bargeIn=off source=toggle');
    session.exit('test');
    await tester.pumpAndSettle();
    await open(tester); // re-enter: back to off
    expect(session.bargeInOn, isFalse);
    session.exit('test');
    await tester.pumpAndSettle();
  });

  testWidgets('logs never contain title, error, activity or held text', (tester) async {
    await open(tester);
    world.set(const CarSnapshot(
      chatKey: 'chat',
      title: 'Secret title',
      error: 'Secret error',
      activity: 'Secret tool',
      connection: CarConnection.offline,
    ));
    await session.tap();
    session.holdForConnection();
    session.logDelivery(CarDelivery.steer);
    await tester.pump(const Duration(milliseconds: 650));
    session.exit('test');
    await tester.pumpAndSettle();
    expect(logs, isNotEmpty);
    for (final line in logs) {
      expect(line, startsWith('WingCar '));
      expect(line, isNot(contains('Secret')));
    }
    expect(logs, contains('WingCar deliver kind=steer'));
    expect(logs, contains('WingCar tap phase=error action=talk'));
    expect(logs, contains('WingCar hold'));
  });
}

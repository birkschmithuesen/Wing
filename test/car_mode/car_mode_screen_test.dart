import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/car_mode/car_mode_bridge.dart';
import 'package:wing/car_mode/car_mode_screen.dart';
import 'package:wing/car_mode/car_mode_session.dart';
import 'package:wing/car_mode/car_mode_state.dart';
import 'package:wing/core/controllers/voice_input_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/voice_offline/headphone_route.dart';
import '../support/voice_fixture.dart';

class _World extends ChangeNotifier {
  CarSnapshot snapshot = const CarSnapshot(chatKey: 'chat', title: 'Weekend trip');
  final calls = <String>[];
  void set(CarSnapshot next) {
    snapshot = next;
    notifyListeners();
  }
}

void main() {
  const capture = bool.fromEnvironment('VOICE_REVIEW');
  const frame = Key('car-frame');
  setUpAll(() async {
    if (!capture) return;
    const path = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': ['Roboto-Regular.ttf'],
      'MaterialIcons': ['MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final name in entry.value) {
        loader.addFont(Future.value(ByteData.sublistView(File('$path/$name').readAsBytesSync())));
      }
      await loader.load();
    }
  });

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

  Future<void> show(
    WidgetTester tester, {
    Size size = const Size(411, 960),
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: wingTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: RepaintBoundary(key: frame, child: child!),
      ),
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

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(frame));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build/voice-review').createSync(recursive: true);
      await File('build/voice-review/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 700));
    session.exit('test');
    await tester.pumpAndSettle();
  }

  Finder button() => find.byKey(const ValueKey('car-button'));

  const states = {
    'idle': CarSnapshot(chatKey: 'chat', title: 'Weekend trip'),
    'listening': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', input: VoiceInputPhase.recording),
    'transcribing': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', input: VoiceInputPhase.transcribing),
    'thinking': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', working: true, activity: 'Terminal'),
    'speaking': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', speaking: true),
    'attention': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', needsInput: true),
    'error': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', error: 'No speech detected. Try again.'),
    'offline': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', connection: CarConnection.offline),
  };

  for (final MapEntry(key: name, value: snap) in states.entries) {
    testWidgets('$name renders its label, icon and connection', (tester) async {
      world.snapshot = snap;
      await show(tester);
      final phase = carPhaseOf(snap);
      expect(find.text(carTextFor(phase, snap).label), findsOneWidget);
      expect(find.byIcon(carIconFor(phase)), findsOneWidget);
      expect(find.text(carConnectionText(snap.connection).label), findsOneWidget);
      expect(find.text('Weekend trip'), findsOneWidget);
      await close(tester);
    });
  }

  testWidgets('waiting shows the held state; the status line shows the tool name', (tester) async {
    world.snapshot = const CarSnapshot(chatKey: 'chat', connection: CarConnection.offline);
    await show(tester);
    session.holdForConnection();
    await tester.pump();
    expect(find.text('Waiting for connection'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    world.set(const CarSnapshot(chatKey: 'chat', working: true, activity: 'Terminal'));
    await tester.pump();
    expect(find.text('Terminal'), findsOneWidget);
    await close(tester);
  });

  testWidgets('the button is the whole screen; badge and status line count as button', (tester) async {
    world.snapshot = const CarSnapshot(chatKey: 'chat', working: true, activity: 'Terminal');
    await show(tester);
    final rect = tester.getRect(button());
    expect(rect.width * rect.height, greaterThan(411 * 960 * .9));
    await tester.tap(find.byKey(const ValueKey('car-connection')));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.tap(find.byKey(const ValueKey('car-status')));
    await tester.pump(const Duration(milliseconds: 700));
    expect(world.calls, ['talk', 'talk']);
    await close(tester);
  });

  testWidgets('the status row carries a Conversation switch that never counts as a tap', (tester) async {
    await show(tester);
    final loopSwitch = find.byKey(const ValueKey('car-loop-switch'));
    expect(loopSwitch, findsOneWidget);
    expect(tester.widget<Switch>(loopSwitch).value, isFalse);
    await tester.tap(loopSwitch);
    await tester.pump();
    expect(session.loopOn, isTrue);
    expect(tester.widget<Switch>(loopSwitch).value, isTrue);
    // Flipping the switch must never be mistaken for a tap on the big button.
    expect(world.calls, isEmpty);
    expect(logs, contains('WingCar loop=on source=toggle'));
    await tester.tap(loopSwitch);
    await tester.pump();
    expect(session.loopOn, isFalse);
    expect(logs, contains('WingCar loop=off source=toggle'));
    await close(tester);
  });

  testWidgets('a reachable tap target: the switch is at least 44x44', (tester) async {
    await show(tester);
    final rect = tester.getRect(find.byKey(const ValueKey('car-loop-switch')));
    expect(rect.width, greaterThanOrEqualTo(44));
    expect(rect.height, greaterThanOrEqualTo(44));
    await close(tester);
  });

  testWidgets('the status row carries an Interrupt-by-speaking switch that never counts as a tap', (tester) async {
    await show(tester);
    final bargeInSwitch = find.byKey(const ValueKey('car-bargein-switch'));
    expect(bargeInSwitch, findsOneWidget);
    expect(tester.widget<Switch>(bargeInSwitch).value, isFalse);
    await tester.tap(bargeInSwitch);
    await tester.pump();
    expect(session.bargeInOn, isTrue);
    expect(tester.widget<Switch>(bargeInSwitch).value, isTrue);
    // Flipping the switch must never be mistaken for a tap on the big button.
    expect(world.calls, isEmpty);
    expect(logs, contains('WingCar bargeIn=on source=toggle'));
    await tester.tap(bargeInSwitch);
    await tester.pump();
    expect(session.bargeInOn, isFalse);
    expect(logs, contains('WingCar bargeIn=off source=toggle'));
    await close(tester);
  });

  testWidgets('a reachable tap target: the Interrupt-by-speaking switch is at least 44x44', (tester) async {
    await show(tester);
    final rect = tester.getRect(find.byKey(const ValueKey('car-bargein-switch')));
    expect(rect.width, greaterThanOrEqualTo(44));
    expect(rect.height, greaterThanOrEqualTo(44));
    await close(tester);
  });

  testWidgets(
    'acceptance: switch off keeps the carMode barge-in lock; switch on lifts it for this '
    'session, even over car speakers; leaving and re-entering resets it to off',
    (tester) async {
      await show(tester);
      final bargeInSwitch = find.byKey(const ValueKey('car-bargein-switch'));
      const carSpeaker = OutputRoute(supported: true, type: 2); // BUILTIN_SPEAKER

      // Switch off (default, unchanged behaviour): the carMode lock blocks
      // barge-in, even though "car mode" (wingCarMode: true) is active here.
      expect(
        classifyRoute(carSpeaker, wingCarMode: true, bargeInOverride: session.bargeInOn).headphones,
        isFalse,
      );

      await tester.tap(bargeInSwitch);
      await tester.pump();
      // Switch on: the lock lifts for this session, even over a car speaker
      // (not a wired headphone route).
      // Mutation guard: if the implementation still returns the carMode
      // lock despite the switch being on, this assertion goes red.
      expect(
        classifyRoute(carSpeaker, wingCarMode: true, bargeInOverride: session.bargeInOn).headphones,
        isTrue,
      );
      expect(session.bargeInOn, isTrue);

      await close(tester);
      await show(tester); // re-enter: back to off, never persisted
      expect(session.bargeInOn, isFalse);
      expect(
        classifyRoute(carSpeaker, wingCarMode: true, bargeInOverride: session.bargeInOn).headphones,
        isFalse,
      );
      await close(tester);
    },
  );

  testWidgets('a swipe exits and never starts a round', (tester) async {
    await show(tester);
    await tester.drag(button(), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(session.active, isFalse);
    expect(find.byType(CarModeScreen), findsNothing);
    expect(world.calls, ['leave']);
    expect(logs, contains('WingCar swipe action=exit'));
    expect(logs.where((l) => l.startsWith('WingCar tap')), isEmpty);
  });

  testWidgets('a swipe while listening exits without sending', (tester) async {
    world.snapshot = const CarSnapshot(chatKey: 'chat', input: VoiceInputPhase.recording);
    await show(tester);
    await tester.drag(button(), const Offset(220, 0));
    await tester.pumpAndSettle();
    expect(world.calls, ['leave']);
    expect(world.calls, isNot(contains('sendNow')));
  });

  testWidgets('a short slide or a vertical wobble is neither a tap nor an exit', (tester) async {
    await show(tester);
    await tester.drag(button(), const Offset(40, 0));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.drag(button(), const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 700));
    expect(session.active, isTrue);
    expect(world.calls, isEmpty);
    expect(logs, contains('WingCar swipe action=short'));
    await close(tester);
  });

  testWidgets('Back leaves directly', (tester) async {
    await show(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(session.active, isFalse);
    expect(find.byType(CarModeScreen), findsNothing);
    expect(world.calls, ['leave']);
  });

  testWidgets('the swipe hint shows for 6 s, the title stays', (tester) async {
    await show(tester);
    expect(find.byKey(const ValueKey('car-swipe-hint')), findsOneWidget);
    expect(find.text('Swipe to leave'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 6100));
    expect(find.text('Swipe to leave'), findsNothing);
    expect(find.text('Weekend trip'), findsOneWidget);
    await close(tester);
  });

  for (final brightness in Brightness.values) {
    for (final size in const [Size(411, 960), Size(960, 411), Size(320, 640)]) {
      for (final scale in const [1.0, 2.0]) {
        final tag = '${brightness.name}-${size.width.toInt()}x${size.height.toInt()}-${(scale * 100).toInt()}';
        testWidgets('all phases fit $tag', (tester) async {
          await show(tester, size: size, brightness: brightness, scale: scale);
          for (final MapEntry(key: name, value: snap) in states.entries) {
            world.set(snap);
            await tester.pump();
            expect(tester.takeException(), isNull, reason: name);
            final badge = tester.getSize(find.byKey(const ValueKey('car-connection')));
            expect(badge.height, greaterThanOrEqualTo(48));
            if (size.width == 411 || size.width == 960) {
              await screenshot(tester, 'car-$name-$tag');
            }
          }
          await close(tester);
        });
      }
    }
  }
}

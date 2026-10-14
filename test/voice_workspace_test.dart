import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/car_mode/car_mode_screen.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/android_voice.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import 'support/profile_browser_fixture.dart';
import 'support/voice_fixture.dart';

class _Fixture extends ProfileBrowserFixture {
  final gateways = <String, ProfileGateway>{};

  @override
  ProfileGateway gateway(WorkspaceScope scope) =>
      gateways[scope.profileName] = super.gateway(scope);

  @override
  List<Map<String, dynamic>> sessions(String profile) => [
    for (final row in super.sessions(profile)) {...row, 'unread': false},
  ];

  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => [
    {'id': 1, 'role': 'user', 'content': 'What should I check?'},
    {
      'id': 2,
      'role': 'assistant',
      'content':
          'Check the connection and try again.\n\n```sh\nprivate command\n```',
    },
  ];
}

void main() {
  late _Fixture fixture;
  late ProfileWorkspaceController controller;
  late VoiceDeviceFixture device;
  const capture = bool.fromEnvironment('VOICE_REVIEW');
  const frame = Key('voice-frame');
  setUpAll(() async {
    if (!capture) return;
    const path = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': ['Roboto-Regular.ttf'],
      'MaterialIcons': ['MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final name in entry.value) {
        loader.addFont(
          Future.value(
            ByteData.sublistView(File('$path/$name').readAsBytesSync()),
          ),
        );
      }
      await loader.load();
    }
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fixture = _Fixture();
    device = VoiceDeviceFixture();
    controller = ProfileWorkspaceController(
      connection: SavedConnection(
        id: 'voice-fixture',
        label: 'Voice test server',
        host: 'localhost',
        port: 1,
        apiKey: '',
      ),
      connectionIdentity: 'voice-fixture',
      preferences: await SharedPreferences.getInstance(),
      gatewayFactory: fixture.gateway,
    );
    await controller.initialize();
    await controller.openSession(
      ProfileSessionKey(controller.current!.scope, 'newest'),
    );
  });
  tearDown(() async {
    controller.dispose();
    await device.stream.close();
  });
  Future<void> show(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double scale = 1,
    AppDestination destination = AppDestination.chats,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(brightness),
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(320, 900),
            textScaler: TextScaler.linear(scale),
          ),
          child: RepaintBoundary(
            key: frame,
            child: ProfileWorkspaceScreen(
              controller: controller,
              voiceDevice: device,
              initialDestination: destination,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(frame),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build/voice-review').createSync(recursive: true);
      await File(
        'build/voice-review/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'dictation inserts editable text without sending and cancellation preserves draft',
    (tester) async {
      final chat = controller.current!.chat!;
      await controller.updateDraft(chat, 'Existing draft');
      await show(tester);
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      expect(find.textContaining('Recording ·'), findsOneWidget);
      device.stream.add({
        'id': device.recording,
        'text': 'new words',
        'final': true,
      });
      await tester.pumpAndSettle();
      expect(chat.draft, 'Existing draft new words');
      expect(fixture.calls.where((c) => c.$2 == 'session.prompt'), isEmpty);
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      device.stream.add({
        'id': device.recording,
        'text': 'discarded partial',
        'final': false,
      });
      await tester.pump();
      await tester.tap(find.text('Cancel recording'));
      await tester.pumpAndSettle();
      expect(chat.draft, 'Existing draft new words');
    },
  );
  testWidgets(
    'profile switch rejects late native transcription and releases microphone',
    (tester) async {
      await show(tester);
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      final old = device.recording;
      await controller.switchProfile('work');
      device.stream.add({'id': old, 'text': 'wrong profile', 'final': true});
      await tester.pumpAndSettle();
      expect(device.cancelled, contains(old));
      expect(find.text('wrong profile'), findsNothing);
      expect(controller.current!.chat?.draft ?? '', isEmpty);
    },
  );
  testWidgets('read aloud uses reply prose and stops before dictation', (
    tester,
  ) async {
    device.playbackDelay = Completer<void>();
    await show(tester);
    await tester.tap(find.byTooltip('Read aloud'));
    await tester.pump();
    expect(device.spoken, 'Check the connection and try again.');
    expect(device.calls, contains('speak'));
    expect(find.byTooltip('Stop reading aloud'), findsOneWidget);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    expect(device.playing, isNull);
    expect(device.recording, isNotNull);
    device.playbackDelay!.complete();
    await tester.tap(find.text('Cancel recording'));
    await tester.pumpAndSettle();
  });
  testWidgets('backgrounding cancels capture without changing draft', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    final id = device.recording;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    device.stream.add({'id': id, 'text': 'late', 'final': true});
    await tester.pump();
    expect(device.cancelled, contains(id));
    expect(controller.current!.chat!.draft, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  for (final brightness in Brightness.values) {
    testWidgets('recording composer fits 320dp at 200% text in $brightness', (
      tester,
    ) async {
      await show(tester, brightness: brightness, scale: 2);
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      device.stream.add({
        'id': device.recording,
        'text': 'A longer partial transcript that should wrap safely.',
        'final': false,
      });
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      await screenshot(tester, 'composer-${brightness.name}-200');
      await tester.tap(find.text('Cancel recording'));
      await tester.pumpAndSettle();
    });
  }

  // Conversation mode: hands-free dictate → send → spoken reply → listen.
  int starts() => device.calls.where((c) => c == 'start').length;
  int prompts() => fixture.calls.where((c) => c.$2 == 'prompt.submit').length;
  void gatewayEvent(String type, [Map<String, dynamic> data = const {}]) {
    final chat = controller.current!.chat!;
    fixture.gateways[chat.key.workspace.profileName]!.onEvent!(
      StreamEvent(type: type, data: data, sessionId: chat.runtimeId),
    );
  }

  Future<void> conversationMode(bool on) => controller.preferences.setString(
    VoicePreferences.conversationKey,
    on ? 'on' : 'off',
  );

  // A running turn shows a spinner, so pumpAndSettle would never settle.
  // The controller was created outside the test zone; runAsync lets its
  // pending writes finish so a send can reach the gateway.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> sayFinal(WidgetTester tester, String text) async {
    device.stream.add({'id': device.recording, 'text': text, 'final': true});
    await settle(tester);
  }

  Future<void> completeReply(WidgetTester tester, [String text = 'Sunny.']) async {
    gatewayEvent('message.complete', {'text': text});
    await settle(tester);
  }

  testWidgets('conversation mode sends a dictation that ended on its own', (
    tester,
  ) async {
    await conversationMode(true);
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    await sayFinal(tester, 'How is the weather');
    expect(prompts(), 1);
    expect(
      fixture.calls.lastWhere((c) => c.$2 == 'prompt.submit').$3['text'],
      'How is the weather',
    );
    expect(controller.current!.chat!.draft, isEmpty);
    gatewayEvent('message.complete', {'text': 'Done.'});
    await settle(tester);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
  });

  testWidgets(
    'a second dictation while the first turn still runs becomes a steering message',
    (tester) async {
      await conversationMode(true);
      await show(tester);
      final chat = controller.current!.chat!;
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      await sayFinal(tester, 'How is the weather');
      expect(prompts(), 1);
      expect(chat.busy, isTrue);
      // The reply has not arrived yet; the mic can be tapped again.
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      await sayFinal(tester, 'Actually, for tomorrow');
      expect(prompts(), 1, reason: 'no second turn was started');
      expect(fixture.calls.where((c) => c.$2 == 'session.steer').length, 1);
      expect(
        fixture.calls.lastWhere((c) => c.$2 == 'session.steer').$3['text'],
        'Actually, for tomorrow',
      );
      expect(chat.draft, isEmpty);
      // The conversation stayed alive: the turn's eventual reply still
      // continues the hands-free loop.
      await completeReply(tester, 'Tomorrow looks sunny.');
      expect(device.spoken, 'Tomorrow looks sunny.');
      await tester.tap(find.text('Cancel recording'));
      await settle(tester);
    },
  );

  testWidgets(
    'a dictation while reconnecting is queued and sent once reconnected',
    (tester) async {
      await conversationMode(true);
      await show(tester);
      final chat = controller.current!.chat!;
      chat.offlineSnapshot = true;
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      await sayFinal(tester, 'Queue me please');
      expect(prompts(), 0);
      expect(chat.queuedPrompts.map((p) => p.text), ['Queue me please']);
      expect(chat.draft, isEmpty);
      chat.offlineSnapshot = false;
      await tester.runAsync(() => controller.reconnect(chat.key.workspace));
      await settle(tester);
      expect(prompts(), 1);
      expect(chat.queuedPrompts, isEmpty);
      await completeReply(tester, 'Queued answer.');
      expect(device.spoken, 'Queued answer.');
      expect(starts(), 2, reason: 'the mic reopened after the queued reply');
      await tester.tap(find.text('Cancel recording'));
      await settle(tester);
    },
  );

  testWidgets('without conversation mode a final dictation is never sent', (
    tester,
  ) async {
    await conversationMode(false);
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    await sayFinal(tester, 'Just a draft');
    expect(controller.current!.chat!.draft, 'Just a draft');
    expect(prompts(), 0);
  });

  testWidgets('conversation mode never sends after the user pressed Stop', (
    tester,
  ) async {
    await conversationMode(true);
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    final id = device.recording;
    await tester.tap(find.text('Stop recording'));
    await tester.pump();
    device.stream.add({'id': id, 'text': 'Stopped words', 'final': true});
    await settle(tester);
    expect(controller.current!.chat!.draft, 'Stopped words');
    expect(prompts(), 0);
  });

  testWidgets('conversation reopens the microphone after the reply was spoken', (
    tester,
  ) async {
    await conversationMode(true);
    device.playbackDelay = Completer<void>();
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    await sayFinal(tester, 'Question one');
    expect(starts(), 1);
    gatewayEvent('message.complete', {'text': 'Answer one.'});
    await tester.pump();
    await tester.pump();
    expect(device.spoken, 'Answer one.');
    // Still speaking: the microphone stays closed until playback ended.
    expect(starts(), 1);
    device.playbackDelay!.complete();
    device.playbackDelay = null;
    await settle(tester);
    expect(starts(), 2);
    expect(find.textContaining('Recording ·'), findsOneWidget);
    // Second round trip continues the loop.
    await sayFinal(tester, 'Question two');
    expect(prompts(), 2);
    await completeReply(tester, 'Answer two.');
    expect(starts(), 3);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
  });

  testWidgets('Cancel ends the conversation and the microphone stays closed', (
    tester,
  ) async {
    await conversationMode(true);
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    await sayFinal(tester, 'Question');
    await completeReply(tester);
    expect(starts(), 2);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
    // A later reply in this chat must not reopen the microphone.
    controller.current!.chat!.status = ProfileTurnStatus.running;
    await completeReply(tester, 'Late reply.');
    expect(starts(), 2);
    expect(device.recording, isNull);
  });

  for (final failure in ['error', 'no speech']) {
    testWidgets('$failure ends the conversation and the microphone stays closed', (
      tester,
    ) async {
      await conversationMode(true);
      await show(tester);
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      await sayFinal(tester, 'Question');
      await completeReply(tester);
      expect(starts(), 2);
      if (failure == 'error') {
        device.stream.add({'id': device.recording, 'error': 'Recognizer busy'});
        await settle(tester);
      } else {
        await sayFinal(tester, '   ');
      }
      expect(find.textContaining('Recording ·'), findsNothing);
      expect(prompts(), 1);
      controller.current!.chat!.status = ProfileTurnStatus.running;
      await completeReply(tester, 'Late reply.');
      expect(starts(), 2);
    });
  }

  testWidgets('backgrounding during the spoken reply ends the conversation', (
    tester,
  ) async {
    await conversationMode(true);
    device.playbackDelay = Completer<void>();
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    await sayFinal(tester, 'Question');
    gatewayEvent('message.complete', {'text': 'Answer.'});
    await tester.pump();
    await tester.pump();
    expect(device.calls, contains('speak'));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    device.playbackDelay!.complete();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(device.calls, contains('stopPlayback'));
    expect(starts(), 1);
    expect(find.textContaining('Recording ·'), findsNothing);
  });

  for (final request in ['approval', 'clarify']) {
    testWidgets('a pending $request keeps the microphone closed', (
      tester,
    ) async {
      await conversationMode(true);
      await show(tester);
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      await sayFinal(tester, 'Clean up the disk');
      expect(prompts(), 1);
      gatewayEvent(
        request,
        request == 'approval'
            ? {'request_id': 'approve-1', 'command': 'rm -rf build'}
            : {
                'request_id': 'ask-1',
                'questions': [
                  {'qid': 'q0', 'question': 'Which disk?'},
                ],
              },
      );
      await tester.pump();
      await completeReply(tester, 'Waiting for you.');
      expect(device.spoken, 'Waiting for you.');
      expect(starts(), 1);
      expect(find.textContaining('Recording ·'), findsNothing);
    });
  }

  int vadStarts() => device.vadStarts;
  Future<void> vadRoute() => controller.preferences.setString(
    VoicePreferences.inputKey,
    'vad',
  );
  Future<void> windows(WidgetTester tester, double p, int count) async {
    device.emitWindows(List.filled(count, p));
    await settle(tester);
  }

  testWidgets('vad conversation sends after the pause', (tester) async {
    await vadRoute();
    await conversationMode(true);
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    expect(vadStarts(), 1);
    await windows(tester, 0.9, 30);
    await windows(tester, 0.1, 60);
    expect(device.finishes.single.reason.name, 'pause');
    expect(prompts(), 1);
    expect(
      fixture.calls.lastWhere((c) => c.$2 == 'prompt.submit').$3['text'],
      'Hello from the phone',
    );
    gatewayEvent('message.complete', {'text': 'Done.'});
    await settle(tester);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
  });

  testWidgets('vad thinking pause keeps the microphone open', (tester) async {
    await vadRoute();
    await conversationMode(true);
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    await windows(tester, 0.9, 30);
    await windows(tester, 0.1, 31);
    expect(device.finishes, isEmpty);
    expect(find.textContaining('Recording ·'), findsOneWidget);
    expect(prompts(), 0);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
  });

  testWidgets('media key ends a vad round and sends it in conversation mode', (
    tester,
  ) async {
    await vadRoute();
    await conversationMode(true);
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    await windows(tester, 0.9, 30);
    device.emitMediaKey();
    await settle(tester);
    expect(device.finishes.single.reason.name, 'mediaKey');
    expect(prompts(), 1);
    gatewayEvent('message.complete', {'text': 'Done.'});
    await settle(tester);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
  });

  testWidgets('media key starts a vad round when idle', (tester) async {
    await vadRoute();
    await show(tester);
    device.emitMediaKey();
    await settle(tester);
    expect(vadStarts(), 1);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
  });

  testWidgets('media key is ignored on the local route', (tester) async {
    await show(tester);
    device.emitMediaKey();
    await settle(tester);
    expect(starts(), 0);
    expect(vadStarts(), 0);
  });

  testWidgets('route vad preloads the model and enables media keys', (
    tester,
  ) async {
    await vadRoute();
    await show(tester);
    expect(device.prepares, 1);
    expect(device.mediaKeysCalls, [true]);
  });

  testWidgets('stacked workspaces leave media keys and screen on enabled', (
    tester,
  ) async {
    await vadRoute();
    await show(tester);
    expect(device.mediaKeysCalls, [true]);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => ProfileWorkspaceScreen(
            controller: controller,
            voiceDevice: device,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(device.mediaKeysCalls, [true]);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(device.mediaKeysCalls.last, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(device.mediaKeysCalls.last, isFalse);
  });

  testWidgets('a non-chat destination never holds media keys', (tester) async {
    await vadRoute();
    await show(tester, destination: AppDestination.activity);
    expect(device.mediaKeysCalls, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(device.mediaKeysCalls, isEmpty);
  });

  test('holders talk to the device only on the first and last holder', () {
    final fake = VoiceDeviceFixture();
    final holders = VoiceSwitchHolders.screenOn(fake);
    final a = Object(), b = Object();
    holders.set(a, true);
    holders.set(b, true);
    holders.set(a, false);
    expect(fake.keepScreenOnCalls, [true]);
    holders.set(b, false);
    holders.set(b, false);
    expect(fake.keepScreenOnCalls, [true, false]);
  });

  testWidgets('leaving the workspace releases media keys and the model', (
    tester,
  ) async {
    await vadRoute();
    await show(tester);
    expect(device.releases, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(device.mediaKeysCalls, [true, false]);
    expect(device.releases, 1);
  });

  testWidgets('backgrounding releases media keys and resume restores them', (
    tester,
  ) async {
    await vadRoute();
    await show(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(device.mediaKeysCalls, [true, false]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(device.mediaKeysCalls, [true, false, true]);
  });

  testWidgets('a running conversation keeps the screen on until it ends', (
    tester,
  ) async {
    await conversationMode(true);
    await show(tester);
    expect(device.keepScreenOnCalls, isEmpty);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    expect(device.keepScreenOnCalls, [true]);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
    expect(device.keepScreenOnCalls, [true, false]);
  });

  testWidgets('recording status shows the configured vad limit', (
    tester,
  ) async {
    await vadRoute();
    await controller.preferences.setString(VoicePreferences.vadMaxKey, '900');
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    expect(find.text('Recording · 0s / 900s'), findsOneWidget);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
  });

  testWidgets('recording status shows the default vad limit of 10 minutes', (
    tester,
  ) async {
    await vadRoute();
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    expect(find.text('Recording · 0s / 600s'), findsOneWidget);
    await screenshot(tester, 'vad-recording-light-100');
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
  });

  // Car mode: the whole screen is one button over the chat (docs/CAR_MODE.md).
  Finder carButton() => find.byKey(const ValueKey('car-button'));
  Future<void> openCarMode(WidgetTester tester) async {
    // Car mode holds sends unless the server counts as connected.
    controller.connectionStatus
      ..accessAvailable()
      ..liveChanged('car-test', true);
    await tester.pump();
    expect(controller.connectionStatus.phase, ServerConnectionPhase.connected);
    await tester.tap(find.byTooltip('Chat actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Car mode'));
    await tester.pumpAndSettle();
  }

  Future<void> tapCar(WidgetTester tester) async {
    await tester.tap(carButton());
    // Past the 600 ms debounce; lets async voice work run.
    await tester.pump(const Duration(milliseconds: 350));
    await settle(tester);
  }

  Future<void> swipeOut(WidgetTester tester) async {
    await tester.drag(carButton(), const Offset(-250, 0));
    await settle(tester);
    // The pop is a page transition, not a spinner: pumping a fixed, bounded
    // amount further (never pumpAndSettle, which a "Listening" pulse would
    // never let finish) lets it run out without risking a hang.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('car mode case 2: three rounds by tap only, read aloud, then idle with the mic closed', (
    tester,
  ) async {
    await vadRoute();
    await conversationMode(false);
    await show(tester);
    await openCarMode(tester);
    expect(find.byType(CarModeScreen), findsOneWidget);
    expect(find.text('Tap to talk'), findsOneWidget);
    expect(device.keepScreenOnCalls, [true]);
    for (var round = 1; round <= 3; round++) {
      await tapCar(tester); // tap = start recording
      expect(vadStarts(), round);
      expect(find.text('Listening'), findsOneWidget);
      await windows(tester, 0.9, 30);
      await windows(tester, 0.1, 200); // 6.4 s of silence: no automatic end in case 2
      expect(device.finishes, hasLength(round - 1));
      expect(prompts(), round - 1);
      await tapCar(tester); // tap = stop and send
      expect(device.finishes.last.reason.name, 'mediaKey');
      expect(prompts(), round);
      await completeReply(tester, 'Answer $round.');
      expect(device.spoken, 'Answer $round.'); // read aloud although Spoken replies is off
      expect(vadStarts(), round); // the microphone stays closed
      expect(find.text('Tap to talk'), findsOneWidget);
    }
    expect(controller.preferences.getString(VoicePreferences.conversationKey), 'off');
    expect(controller.preferences.getString(VoicePreferences.autoSpeakKey), isNot('on'));
    await swipeOut(tester);
    expect(find.byType(CarModeScreen), findsNothing);
    expect(device.keepScreenOnCalls.last, isFalse);
  });

  testWidgets('car mode case 1: the loop runs; a tap while listening sends at once', (tester) async {
    await conversationMode(true); // local route (default)
    await show(tester);
    await openCarMode(tester);
    await tapCar(tester);
    expect(starts(), 1);
    final id = device.recording;
    await tapCar(tester); // end of speech not detected: the tap sends now
    device.stream.add({'id': id, 'text': 'Question', 'final': true});
    await settle(tester);
    expect(prompts(), 1);
    await completeReply(tester, 'Answer.');
    expect(device.spoken, 'Answer.');
    expect(starts(), 2); // the saved loop reopened the microphone
    expect(find.text('Listening'), findsOneWidget);
    await swipeOut(tester);
    expect(device.recording, isNull);
  });

  testWidgets('car mode: a tap during read-aloud stops it, then opens the microphone', (tester) async {
    device.playbackDelay = Completer<void>();
    await show(tester);
    await openCarMode(tester);
    await tapCar(tester);
    final id = device.recording;
    await tapCar(tester);
    device.stream.add({'id': id, 'text': 'Question', 'final': true});
    await settle(tester);
    gatewayEvent('message.complete', {'text': 'A long answer.'});
    await tester.pump();
    await tester.pump();
    expect(find.text('Reading aloud'), findsOneWidget);
    device.calls.clear();
    await tapCar(tester);
    expect(device.calls, contains('stopPlayback'));
    expect(device.calls.indexOf('stopPlayback'), lessThan(device.calls.indexOf('start')));
    expect(find.text('Listening'), findsOneWidget);
    device.playbackDelay!.complete();
    device.playbackDelay = null;
    await swipeOut(tester);
  });

  testWidgets('car mode: focus stays under the car route (media keys on)', (tester) async {
    await vadRoute();
    await show(tester);
    await openCarMode(tester);
    // The "Chat actions" menu itself briefly covers the workspace before car
    // mode is entered; only the settled state (media keys on) matters here.
    expect(device.mediaKeysCalls.last, isTrue);
    await tapCar(tester);
    await windows(tester, 0.9, 30);
    await tapCar(tester);
    expect(prompts(), 1);
    expect(device.mediaKeysCalls.last, isTrue);
    gatewayEvent('message.complete', {'text': 'Done.'});
    await settle(tester);
    await swipeOut(tester);
  });

  testWidgets('car mode: a swipe exit cancels the recording and keeps the draft', (tester) async {
    final chat = controller.current!.chat!;
    await controller.updateDraft(chat, 'Typed before');
    await show(tester);
    await openCarMode(tester);
    await tapCar(tester);
    final id = device.recording;
    await swipeOut(tester);
    expect(find.byType(CarModeScreen), findsNothing);
    expect(device.cancelled, contains(id));
    expect(chat.draft, 'Typed before');
    expect(prompts(), 0);
  });

  testWidgets('car mode: the status line shows the running tool by name only', (tester) async {
    await show(tester);
    await openCarMode(tester);
    gatewayEvent('message.start');
    gatewayEvent('tool.start', {'name': 'terminal', 'tool_id': 't1', 'context': 'rm -rf /tmp/secret'});
    await settle(tester);
    expect(find.text('Hermes is working'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.textContaining('secret'), findsNothing);
    gatewayEvent('message.complete', {'text': 'Done.'});
    await settle(tester);
    await swipeOut(tester);
  });

  testWidgets('car mode: a recording finished offline waits and is sent once after reconnect', (
    tester,
  ) async {
    await vadRoute();
    await show(tester);
    await openCarMode(tester);
    await tapCar(tester);
    controller.connectionStatus.failRecovery('car-test', 'Offline');
    await settle(tester);
    expect(find.text('Offline'), findsOneWidget);
    await windows(tester, 0.9, 30); // recording goes on offline
    await tapCar(tester);
    expect(prompts(), 0);
    expect(find.text('Waiting for connection'), findsOneWidget);
    expect(controller.current!.chat!.draft, 'Hello from the phone'); // kept on the device
    controller.connectionStatus.endRecovery('car-test');
    await settle(tester);
    expect(prompts(), 1);
    expect(
      fixture.calls.lastWhere((c) => c.$2 == 'prompt.submit').$3['text'],
      'Hello from the phone',
    );
    controller.connectionStatus.liveChanged('car-test', true); // more notifications
    await settle(tester);
    expect(prompts(), 1);
    await completeReply(tester, 'Got it.');
    expect(device.spoken, 'Got it.');
    await swipeOut(tester);
  });

  testWidgets('car mode: a pending approval shows on screen and the tap does nothing', (tester) async {
    await show(tester);
    await openCarMode(tester);
    gatewayEvent('approval', {'request_id': 'approve-1', 'command': 'rm -rf build'});
    await settle(tester);
    expect(find.text('Needs you on screen'), findsOneWidget);
    // Session setup and the approval event itself already talk to
    // 'approval.pending'; only the tap's own effect matters here.
    final approvalCallsBeforeTap = fixture.calls
        .where((c) => c.$2.contains('approval'))
        .length;
    await tapCar(tester);
    expect(starts(), 0);
    expect(
      fixture.calls.where((c) => c.$2.contains('approval')).length,
      approvalCallsBeforeTap,
    );
    await swipeOut(tester);
  });

  testWidgets('car mode: speech during a running turn is steered into it', (tester) async {
    await show(tester);
    await openCarMode(tester);
    await tapCar(tester);
    var id = device.recording;
    await tapCar(tester);
    device.stream.add({'id': id, 'text': 'Plan the trip', 'final': true});
    await settle(tester);
    expect(prompts(), 1);
    controller.current!.chat!.status = ProfileTurnStatus.running;
    await tapCar(tester); // thinking → microphone (tap while working, option A)
    id = device.recording;
    expect(id, isNotNull);
    await tapCar(tester);
    device.stream.add({'id': id, 'text': 'Also the weather', 'final': true});
    await settle(tester);
    expect(prompts(), 1);
    expect(
      fixture.calls.where((c) => c.$2 == 'session.steer').single.$3['text'],
      'Also the weather',
    );
    await swipeOut(tester);
  });
}

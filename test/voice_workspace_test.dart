import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/theme/wing_theme.dart';
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
}

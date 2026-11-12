import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'support/profile_browser_fixture.dart';
import 'support/voice_fixture.dart';

class _Fixture extends ProfileBrowserFixture {
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
}

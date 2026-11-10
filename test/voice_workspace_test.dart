import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/connection_access.dart';
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
import 'package:wing/core/widgets/studio_error.dart';
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

class _CaptureBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

void main() {
  if (const bool.fromEnvironment('VOICE_REVIEW')) _CaptureBinding();
  late _Fixture fixture;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
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
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'voice-fixture',
          label: 'Voice test server',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'voice-fixture',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    await controller.initialize();
    await controller.openSession(
      ProfileSessionKey(controller.current!.scope, 'newest'),
    );
  });
  tearDown(() async {
    controller.dispose();
    appPreferences.dispose();
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
      RepaintBoundary(
        key: frame,
        child: MaterialApp(
          theme: wingTheme(brightness),
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(320, 900),
              textScaler: TextScaler.linear(scale),
            ),
            child: ProfileWorkspaceScreen(
              controller: controller,
              voiceDevice: device,
              createBotsSession: () => BotsSession((_) async => []),
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

  testWidgets('completed dictation inserts editable text without sending', (
    tester,
  ) async {
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
    expect(chat.composer.observation.text, 'Existing draft new words');
    expect(fixture.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
  });
  testWidgets(
    'cancelling dictation discards partial text and preserves the draft',
    (tester) async {
      final chat = controller.current!.chat!;
      await controller.updateDraft(chat, 'Existing draft');
      await show(tester);
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      device.stream.add({
        'id': device.recording,
        'text': 'discarded partial',
        'final': false,
      });
      await tester.pump();
      await tester.tap(find.byTooltip('Cancel recording'));
      await tester.pumpAndSettle();
      expect(chat.composer.observation.text, 'Existing draft');
      expect(fixture.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
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
      expect(
        controller.current!.chat?.composer.observation.text ?? '',
        isEmpty,
      );
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
    await tester.tap(find.byTooltip('Cancel recording'));
    await tester.pumpAndSettle();
  });
  testWidgets('backgrounding cancels capture without changing draft', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    final id = device.recording;
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    device.stream.add({'id': id, 'text': 'late', 'final': true});
    await tester.pump();
    expect(device.cancelled, contains(id));
    expect(controller.current!.chat!.composer.observation.text, isEmpty);
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'no-speech capsule preserves draft and expires in $brightness at $scale',
        (tester) async {
          final chat = controller.current!.chat!;
          await controller.updateDraft(chat, 'Keep this draft');
          await show(tester, brightness: brightness, scale: scale);
          final composer = find.byKey(const Key('profile-message-composer'));
          final originalBounds = tester.getRect(composer);
          await tester.tap(find.byTooltip('Dictate message'));
          await tester.pump();
          device.stream.add({
            'id': device.recording,
            'error': 'Native localized message',
            'code': 'no_speech',
          });
          await tester.pumpAndSettle();
          expect(find.text('No speech detected'), findsOneWidget);
          final capsule = find.ancestor(
            of: find.text('No speech detected'),
            matching: find.byType(StudioErrorFrame),
          );
          expect(
            tester.getRect(capsule).overlaps(tester.getRect(composer)),
            isFalse,
          );
          expect(tester.getRect(composer), originalBounds);
          expect(chat.composer.observation.text, 'Keep this draft');
          await screenshot(tester, 'no-speech-${brightness.name}-$scale');
          await tester.pump(const Duration(seconds: 4));
          await tester.pumpAndSettle();
          expect(find.text('No speech detected'), findsNothing);
          expect(chat.composer.observation.text, 'Keep this draft');
          expect(fixture.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
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
      await tester.tap(find.byTooltip('Cancel recording'));
      await tester.pumpAndSettle();
    });
  }
}

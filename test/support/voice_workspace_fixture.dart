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
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import 'package:wing/voice_offline/voice_offline_prefs.dart';
import 'background_voice_fixture.dart';
import 'headphone_route_fixture.dart';
import 'profile_browser_fixture.dart';
import 'voice_fixture.dart';

/// Profile browser fixture that keeps the gateways it hands out so tests can
/// inject stream events.
class VoiceWorkspaceFixture extends ProfileBrowserFixture {
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

/// Workspace harness for fork voice tests (was private in
/// test/voice_workspace_test.dart).
class VoiceWorkspaceHarness {
  VoiceWorkspaceHarness()
    : fixture = VoiceWorkspaceFixture(),
      device = VoiceDeviceFixture(),
      background = BackgroundVoiceFixture(),
      route = HeadphoneRouteFixture();

  static const capture = bool.fromEnvironment('VOICE_REVIEW');
  static const frame = Key('voice-frame');

  final VoiceWorkspaceFixture fixture;
  late final ProfileWorkspaceController controller;
  final VoiceDeviceFixture device;
  final BackgroundVoiceFixture background;
  final HeadphoneRouteFixture route;

  /// Loads the fonts the screenshot capture mode needs (setUpAll).
  static Future<void> loadCaptureFonts() async {
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
  }

  Future<void> setUp() async {
    SharedPreferences.setMockInitialValues({});
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
  }

  Future<void> tearDown() async {
    controller.dispose();
    await device.stream.close();
    await background.close();
    await route.close();
  }

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
              backgroundVoice: background,
              headphoneRoute: route,
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
    VoiceOfflinePrefs.conversationKey,
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

  int vadStarts() => device.vadStarts;
  Future<void> vadRoute() async {
    await controller.preferences.setString('voice.input', 'local');
    await controller.preferences.setString(
      VoiceOfflinePrefs.localEngineKey,
      'parakeet',
    );
  }
  Future<void> listenTurn(bool on) => controller.preferences.setString(
    VoiceOfflinePrefs.listenTurnKey,
    on ? 'on' : 'off',
  );
  Future<void> windows(WidgetTester tester, double p, int count) async {
    device.emitWindows(List.filled(count, p));
    await settle(tester);
  }

  Future<void> vadConversationTurn(WidgetTester tester) async {
    await vadRoute();
    await conversationMode(true);
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    await windows(tester, 0.9, 30);
    await windows(tester, 0.1, 60);
    expect(prompts(), 1);
  }

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

  // The status-row switch for the running car-mode session only (t_ce610125).
  Future<void> toggleCarLoop(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('car-loop-switch')));
    await tester.pump();
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
}

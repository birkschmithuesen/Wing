import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/controllers/voice_input_controller.dart';
import 'package:wing/core/controllers/voice_output_controller.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/voice_offline/voice_offline_prefs.dart';
import 'package:wing/voice_offline/workspace_voice_driver.dart';
import '../support/background_voice_fixture.dart';
import '../support/headphone_route_fixture.dart';
import '../support/profile_browser_fixture.dart';
import '../support/voice_fixture.dart';

/// Only the members the listen round reads; everything else is unused here.
class _Host implements WorkspaceVoiceHost {
  _Host(this.controller, this.voiceInput, this.voiceOutput);

  bool live = false;

  @override
  final ProfileWorkspaceController controller;
  @override
  final VoiceInputController voiceInput;
  @override
  final VoiceOutputController voiceOutput;
  @override
  bool get mounted => true;
  @override
  bool get liveVoiceActive => live;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late SharedPreferences prefs;
  late AppPreferences appPreferences;
  late ProfileWorkspaceController controller;
  late VoiceDeviceFixture device;
  late WorkspaceVoiceDriver driver;
  late _Host host;
  late ProfileChat chat;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      VoiceOfflinePrefs.localEngineKey: 'parakeet',
      VoiceOfflinePrefs.conversationKey: 'on',
      VoiceOfflinePrefs.listenTurnKey: 'on',
    });
    prefs = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(prefs);
    final fixture = ProfileBrowserFixture();
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'live-test',
          label: 'Live test',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'live-test',
      preferences: prefs,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    await controller.initialize();
    await controller.openSession(
      ProfileSessionKey(controller.current!.scope, 'newest'),
    );
    chat = controller.current!.chat!;
    device = VoiceDeviceFixture();
    host = _Host(
      controller,
      VoiceInputController(device: device),
      VoiceOutputController(device),
    );
    driver = WorkspaceVoiceDriver(
      host: host,
      device: device,
      backgroundHost: BackgroundVoiceFixture(),
      headphoneHost: HeadphoneRouteFixture(),
    );
  });

  tearDown(() async {
    driver.endLoop();
    host.voiceInput.dispose();
    host.voiceOutput.dispose();
    controller.dispose();
    appPreferences.dispose();
    await device.stream.close();
  });

  test('a listen round opens for the conversation when no live call runs', () async {
    driver.conversation = chat.key;
    driver.openListen(chat);
    await pumpEventQueue();
    expect(driver.bargeIn.listening, isTrue);
  });

  test('starting a live call ends the conversation loop: no listen round', () async {
    driver.conversation = chat.key;
    host.live = true;
    driver.openListen(chat);
    await pumpEventQueue();
    expect(driver.bargeIn.listening, isFalse);
    expect(device.vadStarts, 0);
    expect(driver.vadRoute(), isTrue);
  });
}

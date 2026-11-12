import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/voice_offline/barge_in_policy.dart';
import 'package:wing/voice_offline/chat_voice_view.dart';
import '../support/composer_fixture.dart';
import '../support/profile_browser_fixture.dart';

void main() {
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(prefs);
    final fixture = ProfileBrowserFixture();
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'view-test',
          label: 'View test',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'view-test',
      preferences: prefs,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    await controller.initialize();
    await controller.openSession(
      ProfileSessionKey(controller.current!.scope, 'newest'),
    );
    chat = controller.current!.chat!;
  });

  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  test('an idle chat is idle and not busy', () {
    expect(chat.listenState, ListenChatState.idle);
    expect(chat.voiceBusy, isFalse);
    expect(chat.needsUserInput, isFalse);
    expect(chat.voiceTurnEnded, isFalse);
    expect(chat.voiceEditingQueue, isFalse);
  });

  test('a running turn is busy and steerable until it completes', () {
    emitChatEvent(controller, chat, 'message.start');
    expect(chat.voiceBusy, isTrue);
    expect(chat.listenState, ListenChatState.steerable);
    emitChatEvent(controller, chat, 'message.complete', {'text': 'Done.'});
    expect(chat.voiceBusy, isFalse);
    expect(chat.listenState, ListenChatState.idle);
  });

  test('an approval request needs the user and stays steerable', () {
    emitChatEvent(controller, chat, 'message.start');
    emitChatEvent(controller, chat, 'approval', {
      'request_id': 'approve-1',
      'command': 'ls',
    });
    expect(chat.needsUserInput, isTrue);
    expect(chat.listenState, ListenChatState.steerable);
  });

  test('the draft is the composer text', () async {
    await controller.updateDraft(chat, 'Typed before');
    expect(chat.voiceDraft, 'Typed before');
  });
}

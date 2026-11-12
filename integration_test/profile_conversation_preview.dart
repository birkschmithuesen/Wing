/// Authored UI preview only. No production connection or model calls.
/// Restore lib/main.dart after inspection.
library;

import '../test/support/composer_fixture.dart';

import 'package:wing/core/models/profile_session_key.dart';

import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'support/profile_fixture_root.dart';

import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import '../test/support/profile_browser_fixture.dart';

class ConversationPreviewFixture extends ProfileBrowserFixture {
  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => [
    {
      'id': 1,
      'role': 'user',
      'content': 'Show me a simple profile-scoped request.',
    },
    {
      'id': 2,
      'role': 'tool',
      'tool_name': 'Read gateway contract',
      'content': 'GET /api/sessions\nprofile is required\nRead-only request',
    },
    {
      'id': 3,
      'role': 'assistant',
      'content':
          '## Keep each request in its profile\n\n'
          'Pass the **selected profile** with every request.\n\n'
          '```dart\nfinal query = {\n  \'profile\': profile.name,\n  \'limit\': \'50\',\n};\n```\n\n'
          '- Changing profiles refreshes the list.\n'
          '- Work in other profiles keeps running.\n\n'
          'This is authored UI test content, not a live response.',
    },
  ];
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final fixture = ConversationPreviewFixture();
  final preferences = await SharedPreferences.getInstance();
  final appPreferences = AppPreferences(preferences);
  final controller = ProfileWorkspaceController(
    appPreferences: appPreferences,
    access: ConnectionAccess(
      connection: SavedConnection(
        id: 'conversation-preview',
        label: 'UI preview',
        host: 'unused',
        port: 1,
        apiKey: '',
      ),
      dashboardOAuth: null,
    ),
    connectionIdentity: 'authored-conversation-preview',
    preferences: preferences,
    gatewayFactory: fixture.gateway,
  );
  await controller.initialize();
  await controller.openSession(
    ProfileSessionKey(controller.current!.scope, 'preview'),
  );
  emitChatEvent(controller, controller.current!.chat!, 'session.title', {
    'session_id': controller.current!.chat!.key.sessionId,
    'title': 'Profile-scoped requests',
  });
  emitChatEvent(controller, controller.current!.chat!, 'message.start');
  emitChatEvent(controller, controller.current!.chat!, 'session.info', {
    'open_requests': [],
    'running': false,
  });
  runApp(
    ProfileFixtureRoot(
      controller: controller,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: wingTheme(Brightness.light),
        darkTheme: wingTheme(Brightness.dark),
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    ),
  );
}

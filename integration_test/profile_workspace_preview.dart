/// Authored UI preview only. This target never connects to Hermes and is never
/// imported by lib/main.dart. Restore the normal APK after visual inspection.
library;

import 'package:wing/core/models/chat_runtime.dart';
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
import '../test/support/profile_actions_fixture.dart';

class DesignPreviewFixture extends ProfileActionsFixture {
  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => [
    {
      'id': 1,
      'role': 'user',
      'content': 'How should we improve the workspace?',
    },
    {
      'id': 2,
      'role': 'tool',
      'tool_name': 'Read project',
      'content': 'Read-only inspection of the authored preview project.',
    },
    {
      'id': 3,
      'role': 'tool',
      'tool_name': 'Compare layouts',
      'content': 'Compare long titles and small-screen layouts.',
    },
    {
      'id': 4,
      'role': 'tool',
      'tool_name': 'Check accessibility',
      'content':
          'Check contrast and large text. This is preview data, not a test result.',
    },
    {
      'id': 5,
      'role': 'assistant',
      'content':
          '## Give the work more room\n\nKeep **answers in focus** and execution details one tap away.\n\n- Compact menus stay beside their chat.\n- Your accent follows you into the conversation.\n- Questions and approvals remain visible.\n\n```dart\nfinal scope = selectedProfile;\nawait gateway.sessions(profile: scope);\n```\n\nAuthored design preview. No gateway is connected.',
    },
  ];
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('Design preview: starting');
  final fixture = DesignPreviewFixture();
  final runtimes = WorkspaceRuntimeFixture();
  final preferences = await SharedPreferences.getInstance();
  final appPreferences = AppPreferences(preferences);
  final controller = ProfileWorkspaceController(
    appPreferences: appPreferences,
    access: ConnectionAccess(
      connection: SavedConnection(
        id: 'ui-preview',
        label: 'UI preview · Prestige',
        host: 'unused',
        port: 1,
        apiKey: '',
      ),
      dashboardOAuth: null,
    ),
    connectionIdentity: 'authored-ui-preview',
    preferences: preferences,
    gatewayFactory: fixture.gateway,
    runtimeFactory: runtimes.create,
  );
  await controller.initialize();
  debugPrint('Design preview: initialized');
  for (final (id, status) in [
    ('pinned', ChatExecution.completed),
    ('newest', ChatExecution.running),
    ('pin-two', null),
  ]) {
    final row = controller.current!.sessions.firstWhere(
      (row) => row['id'] == id,
    );
    final chat = await openFixtureChat(
      controller: controller,
      key: ProfileSessionKey(controller.current!.scope, id),
      title: row['title'] as String,
      select: false,
    );
    final runtime = runtimes.forChat(chat);
    if (status == null) {
      runtime.receiveApproval({
        'request_id': 'preview-input',
        'command': 'Review',
      });
    } else if (status == ChatExecution.running) {
      runtime.beginTurn(submitting: false);
    } else {
      runtime.completeTurn(failed: false, cancelled: false, error: null);
    }
  }
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

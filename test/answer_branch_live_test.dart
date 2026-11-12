import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/answer_versions.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Uses only disposable local QA conversations. No model requests.
void main() {
  const port = int.fromEnvironment('HERMES_TEST_PORT');
  test(
    'live fork preserves the chosen answer across hidden gateway rows',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        connectionIdentity: 'fork-qa-settings',
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'fork-qa',
            label: 'Fork QA',
            host: '127.0.0.1',
            port: port,
            dashboardPortOverride: port,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        preferences: preferences,
        appPreferences: appPreferences,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.switchProfile('android-qa-a');
      expect(controller.error, isNull);
      final resource = controller.current!;
      final parents = await resource.gateway.sessions();
      expect(
        parents.rows,
        isNotEmpty,
        reason: 'Requires an existing disposable QA session',
      );
      final seed = await resource.gateway.call('session.create', {
        'parent_session_id': parents.rows.first['id'],
        'title': 'Android fork boundary QA',
        'source': 'desktop',
        'messages': [
          {'role': 'user', 'content': 'First QA prompt'},
          {'role': 'assistant', 'content': 'First QA answer'},
          if (!const bool.fromEnvironment('FORK_QA_WITHOUT_HIDDEN'))
            {'role': 'user', 'content': '[System: model changed for QA]'},
          {'role': 'user', 'content': 'Second QA prompt'},
          {'role': 'assistant', 'content': 'Second QA answer'},
          {'role': 'user', 'content': 'Later QA prompt'},
          {'role': 'assistant', 'content': 'Later QA answer'},
        ],
      });
      for (var attempt = 0; attempt < 30; attempt++) {
        final resumed = await resource.gateway.call('session.resume', {
          'session_id': seed['stored_session_id'],
        });
        if (resumed['info']?['profile_name'] == resource.scope.profileName) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await controller.openSession(
        ProfileSessionKey(resource.scope, seed['stored_session_id'] as String),
      );
      final source = resource.chat!;
      expect(
        source.reading.messages
            .where((m) => !isHiddenAnswerMessage(m))
            .map(answerMessageText),
        [
          'First QA prompt',
          'First QA answer',
          'Second QA prompt',
          'Second QA answer',
          'Later QA prompt',
          'Later QA answer',
        ],
      );
      final child = (await controller.branchAnswer(
        source,
        source.reading.messages.indexWhere(
          (m) => answerMessageText(m) == 'Second QA answer',
        ),
      ))!;
      expect(
        child.reading.messages
            .where((m) => !isHiddenAnswerMessage(m))
            .map(answerMessageText),
        [
          'First QA prompt',
          'First QA answer',
          'Second QA prompt',
          'Second QA answer',
        ],
      );
      expect(
        source.reading.messages.where((m) => !isHiddenAnswerMessage(m)).length,
        6,
      );
    },
    skip: port == 0,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

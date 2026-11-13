import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const port = int.fromEnvironment('HERMES_TEST_PORT');
  test(
    'actual local browser prerequisite for vault acceptance',
    () async {
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final client = ProfileWorkspaceController(
        connectionIdentity: 'browser-prerequisite-qa',
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'browser-prerequisite-qa',
            label: 'Browser QA',
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
      ProfileChat? chat;
      var observedBrowser = false;
      String? browserResult;
      try {
        await client.initialize();
        expect(await client.switchProfile('android-qa-b'), isTrue);
        expect(client.error, isNull);
        final owned = await client.createChat(canDispatch: () => true);
        chat = owned;
        client.addListener(() {
          for (final tool in owned.runtime.toolActivities.where(
            (tool) => tool.name == 'browser_exec',
          )) {
            observedBrowser = true;
            if (tool.isTerminal) browserResult = tool.result;
          }
        });
        await client.updateDraft(
          owned,
          'Use browser_exec exactly once with code '
          '"new_tab(\'about:blank\'); print(page_info())" and timeout_s 20. '
          'Do not open any other URL, read a vault, or access files. '
          'After that tool result report success or its error and stop.',
        );
        await client.send(owned);
        final deadline = DateTime.now().add(const Duration(seconds: 55));
        while (owned.runtime.blocksTurnAdmission &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        // An unavailable runtime is a recorded prerequisite failure, not a UI pass.
        // ignore: avoid_print
        print(
          'BROWSER_PREREQUISITE ${jsonEncode({'session': owned.key.sessionId, 'tool_observed': observedBrowser, 'turn_status': owned.runtime.execution.name, 'tool_result': browserResult, 'turn_error': owned.runtime.error})}',
        );
        expect(
          observedBrowser,
          isTrue,
          reason: 'The probe must actually reach browser_exec',
        );
        expect(
          browserResult,
          isNotNull,
          reason: 'Need the actual tool outcome, not an assumed timeout',
        );
        final result = jsonDecode(browserResult!) as Map;
        expect(result['success'], isTrue);
        expect(result['exit_code'], 0);
        expect(owned.runtime.execution, ChatExecution.completed);
        expect(owned.runtime.error, isNull);
      } finally {
        try {
          if (chat?.runtime.blocksTurnAdmission == true) {
            await client.stop(chat!);
          }
        } finally {
          client.dispose();
          HttpOverrides.global = overrides;
        }
      }
    },
    skip: port == 0,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

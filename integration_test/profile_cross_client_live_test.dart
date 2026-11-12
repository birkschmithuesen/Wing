import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/models/chat_intelligence.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/backend_update.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/ws_client.dart';

/// Opt-in cross-client checks against a local, disposable Hermes profile.
///
/// The test changes only one supplied session's model, reasoning, and unread
/// state. It never submits a prompt. HERMES_TEST_SESSION must identify a
/// disposable synthetic session owned by android-qa-a.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const port = int.fromEnvironment('HERMES_TEST_PORT');
  const suppliedSession = String.fromEnvironment('HERMES_TEST_SESSION');
  const checkUpdateStatus = bool.fromEnvironment('CHECK_UPDATE_STATUS');

  SavedConnection connection() => SavedConnection(
    id: 'cross-client-live-qa',
    label: 'Cross-client live QA',
    host: '127.0.0.1',
    port: port,
    dashboardPortOverride: port,
    apiKey: '',
  );

  Future<ProfileWorkspaceController> controller(
    String identity,
    SharedPreferences preferences,
    AppPreferences appPreferences,
  ) async {
    final result = ProfileWorkspaceController(
      connectionIdentity: identity,
      access: ConnectionAccess(connection: connection(), dashboardOAuth: null),
      preferences: preferences,
      appPreferences: appPreferences,
    );
    // Register before the first read: failed initialization must also retire I/O.
    addTearDown(result.dispose);
    await result.initialize();
    await result.switchProfile('android-qa-a');
    expect(result.error, isNull);
    expect(result.current?.scope.profileName, 'android-qa-a');
    return result;
  }

  test(
    'another client sees session intelligence and read-state changes',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final first = await controller(
        'cross-client-a',
        preferences,
        appPreferences,
      );
      final second = await controller(
        'cross-client-b',
        preferences,
        appPreferences,
      );
      ProfileChat? firstChat;
      final sessionId = suppliedSession;
      ChatIntelligenceSelection? originalSelection;
      bool? originalUnread;
      try {
        firstChat = await first.openSession(
          ProfileSessionKey(first.current!.scope, sessionId),
        );
        expect(
          firstChat,
          isNotNull,
          reason: 'HERMES_TEST_SESSION must name an android-qa-a session',
        );

        final firstOptions = await first.loadIntelligence(firstChat!);
        final originalChoice = firstOptions.choices.where(
          (choice) =>
              choice.provider == firstChat!.provider &&
              choice.model == firstChat.model,
        );
        expect(
          originalChoice,
          isNotEmpty,
          reason: 'The server must expose the session model in model/options',
        );
        final originalReasoning = firstChat.reasoningEffort;
        expect(
          WsClient.validReasoningEfforts,
          contains(originalReasoning),
          reason: 'The server must expose a supported session reasoning value',
        );
        originalSelection = ChatIntelligenceSelection(
          choice: originalChoice.first,
          reasoningEffort: originalReasoning!,
          fastMode: first.current!.chat!.fastMode!,
        );
        final differentModels = firstOptions.choices.where(
          (choice) =>
              choice.provider == originalSelection!.choice.provider &&
              choice.model != originalSelection.choice.model,
        );
        expect(
          differentModels,
          isNotEmpty,
          reason:
              'D03 needs two advertised models under the current provider so '
              'the check does not depend on another provider credential',
        );
        final changedReasoning = originalReasoning == 'low' ? 'high' : 'low';
        expect(WsClient.validReasoningEfforts, contains(changedReasoning));
        final changed = ChatIntelligenceSelection(
          choice: differentModels.first,
          reasoningEffort: changedReasoning,
          fastMode: originalSelection.fastMode,
        );

        final originalRows = await first.current!.gateway.sessions();
        final originalRow = originalRows.rows.where(
          (row) => row['id'] == sessionId,
        );
        expect(originalRow, isNotEmpty);
        originalUnread = originalRow.first['unread'] == true;

        await first.setIntelligence(
          firstChat,
          changed,
          confirmModelChange: (message) async => throw StateError(message),
        );
        await first.current!.gateway.updateSession(sessionId, {
          'unread': true,
        }, canDispatch: () => true);

        await second.refresh();
        final secondRow = second.current!.sessions.firstWhere(
          (row) => row['id'] == sessionId,
        );
        expect(secondRow['unread'], true);
        final reopened = await second.openSession(
          ProfileSessionKey(second.current!.scope, sessionId),
        );
        expect(reopened, isNotNull);
        await second.loadIntelligence(reopened!);
        expect(reopened.provider, changed.choice.provider);
        expect(reopened.model, changed.choice.model);
        expect(reopened.reasoningEffort, changedReasoning);

        final observedByFirst = (await first.current!.gateway.sessions()).rows
            .firstWhere((row) => row['id'] == sessionId);
        expect(
          observedByFirst['unread'],
          false,
          reason:
              'Opening through the second client must acknowledge read state',
        );
      } finally {
        try {
          if (originalSelection != null && firstChat != null) {
            await first.openSession(firstChat.key);
            await first.setIntelligence(
              firstChat,
              originalSelection,
              confirmModelChange: (message) async => throw StateError(message),
            );
          }
        } finally {
          // A failed model restoration must not prevent read-state restoration.
          if (originalUnread != null) {
            await first.current!.gateway.updateSession(sessionId, {
              'unread': originalUnread,
            }, canDispatch: () => true);
          }
        }
      }
    },
    skip: port == 0
        ? 'Supply HERMES_TEST_PORT for the local Hermes dashboard.'
        : suppliedSession.isEmpty
        ? 'Supply HERMES_TEST_SESSION for an owned android-qa-a synthetic session.'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'backend update eligibility and status are readable without starting one',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final workspace = await controller(
        'update-read-only',
        preferences,
        appPreferences,
      );
      final checkJson = await workspace.current!.gateway.read(
        'hermes/update/check',
        {'force': 'true'},
      );
      final check = BackendUpdateCheck.fromJson(checkJson);
      expect(check.currentVersion, isNotNull);

      final statusJson = await workspace.current!.gateway.read(
        'actions/hermes-update/status',
      );
      expect(BackendUpdateStatus.fromJson(statusJson), isNotNull);
    },
    skip: port == 0
        ? 'Supply HERMES_TEST_PORT for the local Hermes dashboard.'
        : !checkUpdateStatus
        ? 'Set CHECK_UPDATE_STATUS=true to run the read-only D30 probe.'
        : false,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}

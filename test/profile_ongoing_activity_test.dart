import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/services/workspace_recents_session.dart';
import 'package:wing/core/services/bots_session.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/profile_live_activity.dart';
import 'package:wing/core/screens/workspace_overview_content.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/widgets/profile_chat_indicator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;
import 'profile_live_activity_test.dart' show ActivityHost;

void main() {
  late Host host;
  late ProfileWorkspaceController controller;
  late ProfileChat chat;
  late AppPreferences appPreferences;
  late BotsSession bots;
  late WorkspaceRecentsSession recents;

  setUp(() async {
    bots = BotsSession((_) async => []);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    host = Host()..running = false;
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'ongoing-activity',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
    emitChatEvent(controller, chat, 'session.title', {
      'session_id': chat.key.sessionId,
      'title': 'Delegated research',
    });
    chat.reading.installSavedHistory([
      ...chat.reading.messages,
      {
        'role': 'user',
        'content': 'Research this',
        'timestamp': DateTime.now().millisecondsSinceEpoch / 1000,
      },
    ]);
    recents = WorkspaceRecentsSession(controller, bots, foreground: true);
  });

  tearDown(() {
    recents.dispose();
    bots.dispose();
    controller.dispose();
    appPreferences.dispose();
  });

  void startChild() => host.event('a', 'subagent.start', {
    'subagent_id': 'child',
    'goal': 'Research',
  });

  testWidgets('idle parent with active child appears in Recents', (
    tester,
  ) async {
    startChild();
    expect(chat.runtime.execution, ChatExecution.idle);
    expect(chat.subagents.single.isTerminal, isFalse);
    await controller.refreshActivity();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceActivityContent(
            visible: false,
            onOpenGroup: (_) async {},
            recents: recents,
            onOpen: (_, displayed) {},
          ),
        ),
      ),
    );
    expect(find.text('Delegated research'), findsOneWidget);
  });

  testWidgets('idle parent with active child uses the Wing pulse', (
    tester,
  ) async {
    startChild();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileChatIndicator(
            runtime: chat.runtime,
            subagents: chat.subagents,
            unconfirmedSubagentIds: chat.unconfirmedSubagentIds,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
  });

  for (final terminalStatus in [
    'completed',
    'failed',
    'timeout',
    'cancelled',
  ]) {
    testWidgets('last child $terminalStatus clears ongoing indicators', (
      tester,
    ) async {
      emitChatEvent(controller, chat, 'message.start');
      emitChatEvent(controller, chat, 'session.info', {
        'open_requests': [],
        'running': false,
      });
      startChild();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: controller,
              builder: (context, _) => Column(
                children: [
                  ProfileChatIndicator(
                    runtime: chat.runtime,
                    subagents: chat.subagents,
                    unconfirmedSubagentIds: chat.unconfirmedSubagentIds,
                  ),
                  Expanded(
                    child: WorkspaceActivityContent(
                      visible: false,
                      onOpenGroup: (_) async {},
                      recents: recents,
                      onOpen: (_, displayed) {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Delegated research'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ProfileChatIndicator),
          matching: find.byType(StudioLoading),
        ),
        findsOneWidget,
      );
      expect(chat.runtime.blocksTurnAdmission, isFalse);

      host.event('a', 'subagent.complete', {
        'subagent_id': 'child',
        'status': terminalStatus,
      });
      await tester.pump();
      await tester.pump();
      expect(find.text('Delegated research'), findsOneWidget);
      expect(find.text('Last 24 hours'), findsNothing);
      expect(find.text('Read'), findsOneWidget);
      expect(find.text('Ongoing'), findsNothing);
      expect(find.byType(StudioLoading), findsNothing);
      expect(chat.runtime.execution, ChatExecution.completed);
    });
  }

  test('one completed child does not hide a remaining active child', () {
    startChild();
    host.event('a', 'subagent.start', {'subagent_id': 'second'});
    host.event('a', 'subagent.complete', {
      'subagent_id': 'child',
      'status': 'timeout',
    });
    expect(
      controller.liveActivity.single.state,
      ProfileLiveActivityState.running,
    );
  });

  testWidgets('input request retains priority over active children', (
    tester,
  ) async {
    startChild();
    host.event('a', 'clarify', {
      'request_id': 'folder-request',
      'question': 'Which folder?',
    });
    expect(
      controller.liveActivity.single.state,
      ProfileLiveActivityState.needsInput,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileChatIndicator(
            runtime: chat.runtime,
            subagents: chat.subagents,
            unconfirmedSubagentIds: chat.unconfirmedSubagentIds,
          ),
        ),
      ),
    );
    expect(find.byTooltip('Input needed'), findsOneWidget);
    expect(find.byType(StudioLoading), findsNothing);
  });

  test('main turn appears before the server snapshot catches up', () async {
    chat.composer.editText('Start research');
    await controller.send(chat);
    await controller.refreshActivity();
    expect(
      controller.liveActivity.single.state,
      ProfileLiveActivityState.running,
    );
  });

  test('same chat IDs in different profiles retain their owners', () async {
    startChild();
    await controller.switchProfile('b');
    final other = await controller.openSession(
      ProfileSessionKey(controller.current!.scope, chat.key.sessionId),
    );
    expect(other!.key.sessionId, chat.key.sessionId);
    host.event('b', 'subagent.start', {'subagent_id': 'child'});
    expect(
      controller.liveActivity.map((item) => item.workspace.profileName),
      unorderedEquals(['a', 'b']),
    );
    host.event('a', 'subagent.complete', {
      'subagent_id': 'child',
      'status': 'completed',
    });
    expect(controller.liveActivity.single.workspace.profileName, 'b');
  });

  test('local and server activity merge into one row', () async {
    controller.dispose();
    final snapshotHost = ActivityHost();
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'ongoing-activity',
      preferences: await SharedPreferences.getInstance(),
      appPreferences: appPreferences,
      gatewayFactory: snapshotHost.gateway,
    );
    await controller.initialize();
    final local = await controller.createChat(canDispatch: () => true);
    emitChatEvent(controller, local, 'message.start');
    snapshotHost.live.add({
      'id': local.runtime.runtimeId,
      'session_key': local.key.sessionId,
      'status': 'working',
      'side_tasks_running': 2,
    });
    await controller.refreshActivity();
    expect(controller.liveActivity, hasLength(1));
    expect(controller.liveActivity.single.sideTasksRunning, 2);
  });
}

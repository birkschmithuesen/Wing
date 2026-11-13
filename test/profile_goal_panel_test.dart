import 'package:wing/core/services/bots_session.dart';
import 'dart:async';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/services/profile_supervision_session.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/widgets/profile_goal_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_actions_fixture.dart';

class _GoalFixture extends ProfileActionsFixture {
  Completer<void>? heldMetadata;

  final requests = <(String, Map<String, dynamic>)>[];
  bool hasGoal = true;
  bool failAction = false;
  final subgoals = <String>['Implement', 'Verify'];

  Map<String, dynamic> get control => {
    'goal': hasGoal
        ? {
            'title': 'Ship the release',
            'status': 'active',
            'turns_used': 2,
            'max_turns': 8,
            'contract': {
              'outcome': 'A useful release',
              'verification': 'Run checks',
              'constraints': 'Keep scope small',
              'boundaries': 'No unrelated edits',
              'stop_when': 'Checks pass',
            },
            'subgoals': subgoals,
            'gates': const [],
          }
        : null,
    'revision': 'goal-revision',
    'updated_at': 1,
  };

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      get: base.read,
      rpc: (method, params) async {
        requests.add((method, params));
        if (method == 'session.control.read') await heldMetadata?.future;
        if (method == 'session.control.read') return {'control': control};
        if (method == 'session.control') {
          if (failAction) throw StateError('Action rejected');
          final args = params['args'] as Map<String, dynamic>;
          if (params['action'] == 'subgoal.add') {
            subgoals.add(args['text'] as String);
          } else if (params['action'] == 'subgoal.remove') {
            subgoals.removeAt((args['index'] as int) - 1);
          } else if (params['action'] == 'subgoal.clear') {
            subgoals.clear();
          }
          return {
            'control': control,
            'dispatch': {
              'type': 'exec',
              'output': '✓ Goal updated.',
              'notice': null,
              'message': null,
              'display': null,
            },
          };
        }
        return base.call(method, params);
      },
    );
  }
}

void main() {
  late _GoalFixture fixture;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;
  late ProfileSupervisionSession supervision;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fixture = _GoalFixture();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'goal-panel',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
    supervision = ProfileSupervisionSession(controller: controller, chat: chat);
  });

  tearDown(() {
    supervision.dispose();
    controller.dispose();
    appPreferences.dispose();
  });

  Future<void> showPanel(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              ProfileGoalPanel(session: supervision, initiallyExpanded: true),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('automatic metadata read keeps the usable conversation quiet', (
    tester,
  ) async {
    fixture.heldMetadata = Completer<void>();
    addTearDown(() {
      if (!fixture.heldMetadata!.isCompleted) fixture.heldMetadata!.complete();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const TextField(
                decoration: InputDecoration(hintText: 'Draft remains editable'),
              ),
              ProfileGoalPanel(session: supervision),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(StudioLoading), findsNothing);
    await tester.enterText(find.byType(TextField), 'Keep writing');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text ??
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
      'Keep writing',
    );
    fixture.heldMetadata!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders server goal details and sends pause action', (
    tester,
  ) async {
    await showPanel(tester);

    expect(find.text('Ship the release'), findsOneWidget);
    expect(find.text('Run checks'), findsOneWidget);
    expect(find.text('Implement'), findsOneWidget);
    expect(find.byTooltip('Copy Criterion 1'), findsNothing);
    expect(find.byTooltip('Open Criterion 1'), findsNothing);
    expect(find.byTooltip('Remove criterion 1'), findsOneWidget);
    expect(find.byTooltip('Copy Objective'), findsOneWidget);
    expect(find.byTooltip('Open Objective'), findsNothing);
    await tester.ensureVisible(find.byTooltip('Pause'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(
      fixture.requests.any(
        (request) =>
            request.$1 == 'session.control' &&
            request.$2['action'] == 'goal.pause',
      ),
      isTrue,
    );
  });

  testWidgets('renders an explicit empty server goal state', (tester) async {
    fixture.hasGoal = false;
    await showPanel(tester);
    expect(
      find.text('Hermes has no active goal for this chat.'),
      findsOneWidget,
    );
  });

  testWidgets('adds a trimmed criterion through the scoped control action', (
    tester,
  ) async {
    await showPanel(tester);
    await tester.ensureVisible(find.byTooltip('Add criterion'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add criterion').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('goal-criterion-draft')),
      '  Release is verified  ',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Add criterion').last);
    await tester.pumpAndSettle();

    final request = fixture.requests.lastWhere(
      (request) => request.$1 == 'session.control',
    );
    expect(request.$2['action'], 'subgoal.add');
    expect(request.$2['args'], {'text': 'Release is verified'});
    expect(request.$2['session_id'], 'runtime');
    expect(find.text('Release is verified'), findsOneWidget);
  });

  testWidgets('retains the add draft when the server rejects it', (
    tester,
  ) async {
    fixture.failAction = true;
    await showPanel(tester);
    await tester.ensureVisible(find.byTooltip('Add criterion'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add criterion').last);
    await tester.pumpAndSettle();
    final draft = find.byKey(const ValueKey('goal-criterion-draft'));
    await tester.enterText(draft, 'Keep this criterion');
    await tester.pump();
    await tester.tap(find.byTooltip('Add criterion').last);
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(draft).controller!.text,
      'Keep this criterion',
    );
    expect(
      find.text('Criterion could not be added. Review it and try again.'),
      findsOneWidget,
    );
    expect(
      fixture.requests.where(
        (request) =>
            request.$1 == 'session.control' &&
            request.$2['action'] == 'subgoal.add',
      ),
      hasLength(1),
    );
  });

  testWidgets('confirms one-based criterion removal', (tester) async {
    await showPanel(tester);
    await tester.ensureVisible(find.byTooltip('Remove criterion 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove criterion 2'));
    await tester.pumpAndSettle();
    expect(find.text('Remove criterion 2?'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Verify'), findsOneWidget);

    await tester.ensureVisible(find.byTooltip('Remove criterion 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove criterion 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove criterion'));
    await tester.pumpAndSettle();
    final remove = fixture.requests.lastWhere(
      (request) =>
          request.$1 == 'session.control' &&
          request.$2['action'] == 'subgoal.remove',
    );
    expect(remove.$2['args'], {'index': 2});
    expect(find.text('Verify'), findsNothing);
  });

  testWidgets('confirms clearing all criteria', (tester) async {
    await showPanel(tester);
    await tester.ensureVisible(find.byTooltip('Clear criteria'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Clear criteria').last);
    await tester.pumpAndSettle();
    expect(find.text('Clear all criteria?'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear criteria').last);
    await tester.pumpAndSettle();
    expect(fixture.subgoals, isEmpty);
    expect(find.text('Criteria (0)'), findsOneWidget);
    final clear = fixture.requests.lastWhere(
      (request) =>
          request.$1 == 'session.control' &&
          request.$2['action'] == 'subgoal.clear',
    );
    expect(clear.$2['args'], isEmpty);
  });

  testWidgets('does not remove a criterion changed during confirmation', (
    tester,
  ) async {
    await showPanel(tester);

    await tester.ensureVisible(find.byTooltip('Remove criterion 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove criterion 1'));
    await tester.pumpAndSettle();
    fixture.subgoals[0] = 'Changed by server';
    await controller.refreshSessionControl(chat);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove criterion'));
    await tester.pumpAndSettle();

    expect(find.text('Criteria changed'), findsOneWidget);
    expect(find.textContaining('Review the refreshed list'), findsOneWidget);
    expect(
      fixture.requests.where(
        (request) =>
            request.$1 == 'session.control' &&
            request.$2['action'] == 'subgoal.remove',
      ),
      isEmpty,
    );
    await tester.tap(find.byTooltip('Close criteria notice'));
    await tester.pumpAndSettle();
  });

  testWidgets('does not clear criteria changed during confirmation', (
    tester,
  ) async {
    await showPanel(tester);
    await tester.ensureVisible(find.byTooltip('Clear criteria'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Clear criteria').last);
    await tester.pumpAndSettle();
    fixture.subgoals.add('Added by server');
    await controller.refreshSessionControl(chat);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Clear criteria').last);
    await tester.pumpAndSettle();

    expect(find.text('Criteria changed'), findsOneWidget);
    expect(
      fixture.requests.where(
        (request) =>
            request.$1 == 'session.control' &&
            request.$2['action'] == 'subgoal.clear',
      ),
      isEmpty,
    );
  });

  testWidgets('add dialog keeps its draft when the parent panel is disposed', (
    tester,
  ) async {
    var showGoalPanel = true;
    late StateSetter updateHost;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            updateHost = setState;
            return Scaffold(
              body: showGoalPanel
                  ? ListView(
                      children: [
                        ProfileGoalPanel(
                          session: supervision,
                          initiallyExpanded: true,
                        ),
                      ],
                    )
                  : const SizedBox.shrink(),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.ensureVisible(find.byTooltip('Add criterion'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add criterion').last);
    await tester.pumpAndSettle();
    final draft = find.byKey(const ValueKey('goal-criterion-draft'));
    await tester.enterText(draft, 'Keep this local draft');

    updateHost(() => showGoalPanel = false);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      tester.widget<TextField>(draft).controller!.text,
      'Keep this local draft',
    );

    await tester.tap(find.byTooltip('Add criterion').last);
    await tester.pump();
    expect(
      fixture.requests.where(
        (request) =>
            request.$1 == 'session.control' &&
            request.$2['action'] == 'subgoal.add',
      ),
      isEmpty,
    );
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('conversation goal panel opens server goal details', (
    tester,
  ) async {
    await supervision.refreshWork();
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Goal'), findsNothing);
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(find.text('Work'), findsOneWidget);
    await tester.ensureVisible(find.text('Goal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Goal'));
    await tester.pumpAndSettle();
    expect(find.text('Ship the release'), findsOneWidget);
    expect(find.byTooltip('Pause'), findsOneWidget);
  });

  testWidgets('keeps goal actions usable on a narrow large-text phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: ListView(
            children: [
              ProfileGoalPanel(session: supervision, initiallyExpanded: true),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    final reads = fixture.requests
        .where((r) => r.$1 == 'session.control.read')
        .length;
    await tester.ensureVisible(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(
      fixture.requests.where((r) => r.$1 == 'session.control.read').length,
      reads + 1,
    );
    await tester.ensureVisible(find.byTooltip('Add criterion'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Add criterion'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add criterion').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('goal-criterion-draft')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

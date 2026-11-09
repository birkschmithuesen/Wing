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
import 'support/composer_fixture.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/widgets/profile_background_work_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_actions_fixture.dart';

class _BackgroundFixture extends ProfileActionsFixture {
  Completer<void>? heldMetadata;

  final requests = <(String, Map<String, dynamic>)>[];
  bool running = true;
  bool recurring = true;
  bool rejectStop = false;
  String loopStatus = 'active';
  String heartbeatStatus = 'active';
  bool heartbeatPresent = true;
  bool exitCodeSupplied = true;
  String runningOutput = 'waiting for work\n';

  List<Map<String, dynamic>> get processes => [
    if (running)
      {
        'session_id': 'proc-running',
        'command': 'dart run worker.dart',
        'cwd': '/workspace',
        'output_tail': runningOutput,
        'status': 'running',
        'uptime_seconds': 125,
        'pid': 4321,
        'detached': true,
        'notify_on_complete': true,
      },
    {
      'session_id': 'proc-exited',
      'command': 'dart test',
      'output_tail': 'All tests passed.\n',
      'status': 'exited',
      if (exitCodeSupplied) 'exit_code': 0,
      'uptime_seconds': 9,
    },
  ];

  Map<String, dynamic> get control => {
    'goal': null,
    'loop': !recurring
        ? null
        : {
            'prompt': 'Check the release queue',
            'status': loopStatus,
            'mode': 'interval',
            'interval_seconds': 300,
            'current_delay': 300,
            'times': 6,
            'until': '',
            'max_ticks': 0,
            'ticks_fired': 3,
            'created_at': 1,
            'last_fired_at': 2,
            'next_due_at': 1893456000,
            'awaiting_response': true,
            'deferred_by_goal': true,
          },
    'heartbeat': recurring && heartbeatPresent
        ? {
            'prompt': 'Report deployment health',
            'status': heartbeatStatus,
            'interval_seconds': 900,
            'created_at': 1,
            'last_fired_at': 2,
            'fire_count': 4,
          }
        : null,
    'revision': 'background-revision',
    'updated_at': 3,
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
        if (method == 'session.control.read' || method == 'process.list') {
          await heldMetadata?.future;
        }
        if (method == 'process.list') return {'processes': processes};
        if (method == 'process.kill') {
          if (rejectStop) {
            return {'status': 'error', 'process_id': params['process_id']};
          }
          running = false;
          return {'status': 'killed', 'session_id': params['process_id']};
        }
        if (method == 'session.control.read') return {'control': control};
        if (method == 'session.control') {
          if (params['action'] == 'loop.pause') loopStatus = 'paused';
          if (params['action'] == 'heartbeat.pause') {
            heartbeatStatus = 'paused';
          }
          if (params['action'] == 'heartbeat.clear') heartbeatPresent = false;
          return {
            'control': control,
            'dispatch': {
              'type': 'exec',
              'output': 'Background work updated.',
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
  late _BackgroundFixture fixture;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;
  late ProfileSupervisionSession supervision;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fixture = _BackgroundFixture();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'background-work-panel',
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

  Future<void> showPanel(
    WidgetTester tester, {
    Size size = const Size(800, 900),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    emitChatEvent(controller, chat, 'message.start');
    await supervision.refreshProcesses();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: ListView(
            children: [
              ProfileBackgroundWorkPanel(
                session: supervision,
                initiallyExpanded: true,
              ),
              ProfileProcessPanel(session: supervision),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
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
              ProfileBackgroundWorkPanel(session: supervision),
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

  testWidgets('stops only the selected running process after server ACK', (
    tester,
  ) async {
    await showPanel(tester);
    await tester.tap(find.text('dart run worker.dart'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Stop process'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stop process'));
    await tester.pumpAndSettle();

    final stop = fixture.requests.singleWhere(
      (request) => request.$1 == 'process.kill',
    );
    expect(stop.$2['process_id'], 'proc-running');
    expect(stop.$2['session_id'], 'runtime');
    expect(find.text('dart run worker.dart'), findsNothing);
    expect(find.text('dart test'), findsOneWidget);
  });

  testWidgets('keeps a process when the server rejects stopping it', (
    tester,
  ) async {
    fixture.rejectStop = true;
    await showPanel(tester);

    await tester.tap(find.text('dart run worker.dart'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Stop process'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stop process'));
    await tester.pumpAndSettle();
    expect(find.text('dart run worker.dart'), findsWidgets);
    expect(
      find.text('The server did not confirm that the process stopped.'),
      findsOneWidget,
    );

    expect(
      fixture.requests.where((request) => request.$1 == 'process.kill'),
      hasLength(1),
    );
  });

  testWidgets('dismissing an exited process does not stop running work', (
    tester,
  ) async {
    await showPanel(tester);
    await tester.tap(find.text('dart test'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('dart test'), findsNothing);
    expect(
      fixture.requests.where((request) => request.$1 == 'process.kill'),
      isEmpty,
    );
  });

  testWidgets('process text actions serve command and output, not metadata', (
    tester,
  ) async {
    await showPanel(tester);
    await tester.tap(find.text('dart run worker.dart'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Copy Command'), findsOneWidget);
    expect(find.byTooltip('Copy Recent output'), findsOneWidget);
    expect(find.byTooltip('Open Command'), findsNothing);
    expect(find.byTooltip('Open Recent output'), findsNothing);
    expect(find.byTooltip('Copy PID'), findsNothing);
    expect(find.byTooltip('Stop process'), findsOneWidget);
    expect(
      find.text('Latest received output; not a complete transcript'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an exited process without an exit code stays unqualified', (
    tester,
  ) async {
    fixture.exitCodeSupplied = false;
    await showPanel(tester);
    await tester.tap(find.text('dart test'));
    await tester.pumpAndSettle();
    expect(find.text('Exited'), findsWidgets);
    expect(find.text('Completed'), findsNothing);
    expect(find.text('Process exited; exit code not supplied'), findsOneWidget);
    expect(find.byTooltip('Dismiss'), findsOneWidget);
    expect(find.byTooltip('Stop process'), findsNothing);
  });

  testWidgets('an empty process receipt has no text action toolbar', (
    tester,
  ) async {
    fixture.runningOutput = '';
    await showPanel(tester);
    await tester.tap(find.text('dart run worker.dart'));
    await tester.pumpAndSettle();
    expect(find.text('Latest received output is empty'), findsOneWidget);
    expect(find.text('Empty text'), findsNothing);
    expect(find.byTooltip('Copy Recent output'), findsNothing);
    expect(find.byTooltip('Open Recent output'), findsNothing);
    expect(find.byTooltip('Stop process'), findsOneWidget);
  });

  testWidgets('keeps recurring controls usable on a narrow large-text phone', (
    tester,
  ) async {
    await showPanel(tester, size: const Size(320, 640), textScale: 1.8);
    expect(tester.takeException(), isNull);
    expect(chat.sessionControlError, isNull);
    expect(chat.sessionControl, isNotNull);
    expect(find.text('3/6 runs'), findsOneWidget);
    expect(find.text('Waiting for the current response'), findsOneWidget);
    expect(find.text('Deferred while the goal is active'), findsOneWidget);

    await tester.ensureVisible(find.byTooltip('Pause loop'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Pause loop'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Pause loop'));
    await tester.pumpAndSettle();
    expect(
      fixture.requests.any(
        (request) =>
            request.$1 == 'session.control' &&
            request.$2['action'] == 'loop.pause',
      ),
      isTrue,
    );

    await tester.ensureVisible(find.byTooltip('Clear heartbeat'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Clear heartbeat'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Clear heartbeat'));
    await tester.pumpAndSettle();
    expect(find.text('Clear heartbeat?'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear heartbeat').last);
    await tester.pumpAndSettle();
    expect(
      fixture.requests.any(
        (request) =>
            request.$1 == 'session.control' &&
            request.$2['action'] == 'heartbeat.clear',
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'conversation discovers processes without recurring work or tools',
    (tester) async {
      fixture.recurring = false;
      expect(chat.processes, isEmpty);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => []),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(chat.processes, hasLength(2));
      await tester.tap(find.text('Background 1'));
      await tester.pumpAndSettle();
      expect(find.text('dart run worker.dart'), findsOneWidget);
      expect(find.text('1 running'), findsOneWidget);
      expect(find.text('dart test'), findsNothing);
      expect(find.text('Background work'), findsNothing);
      await tester.tap(find.text('dart run worker.dart'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Stop process'));
      await tester.tap(find.byTooltip('Stop process'));
      await tester.pumpAndSettle();
      expect(chat.processes.where((process) => process.isRunning), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

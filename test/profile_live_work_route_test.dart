import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/screens/profile_transcript.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/profile_execution_activity.dart';
import 'package:wing/core/widgets/profile_activity_tabs.dart';
import 'package:wing/core/widgets/profile_live_work_dock.dart';
import 'package:wing/core/widgets/profile_subagent_panel.dart';
import 'package:wing/core/widgets/profile_tool_call.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/widgets/profile_live_execution.dart';
import 'package:wing/core/widgets/activity_time.dart';
import 'package:wing/core/widgets/transcript_latest_button.dart';

import 'helpers/pump_markdown_widget.dart';
import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;

class _LiveWorkHost extends Host {
  Completer<Map<String, dynamic>>? pendingRoster;
  int rosterReads = 0;
  List<Map<String, dynamic>> processes = [];
  Completer<Map<String, dynamic>>? pendingProcesses;
  bool processReadFails = false;

  final agents = [
    for (var i = 0; i < 2; i++)
      {
        'subagent_id': 'agent-$i',
        'goal': i == 0
            ? 'Inspect source mappings'
            : 'Research metric definitions',
        'status': 'running',
      },
  ];

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    late final ProfileGateway gateway;
    gateway = ProfileGateway(
      scope: scope,
      discover: base.discover,
      connect: () async {
        if (gateway.onEvent != null) gateways[scope.profileName] = gateway;
        await base.connect();
      },
      close: base.close,
      get: base.read,
      rpc: (method, params) {
        if (method == 'process.list') {
          calls.add((scope.profileName, method, params));
          if (processReadFails) return Future.error(StateError('offline'));
          return pendingProcesses?.future ??
              Future.value({'processes': processes});
        }
        if (method == 'process.kill') {
          calls.add((scope.profileName, method, params));
          processes = [
            for (final row in processes)
              if (row['session_id'] == params['process_id'])
                {...row, 'status': 'exited', 'exit_code': 0}
              else
                row,
          ];
          return Future.value({
            'status': 'killed',
            'session_id': params['process_id'],
          });
        }
        if (method == 'subagent.list') {
          rosterReads++;
          return pendingRoster?.future ?? Future.value({'subagents': agents});
        }
        return base.call(method, params);
      },
    );
    return gateway;
  }
}

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'completed tasks leave the composer and stay in their Activity ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          final app = AppPreferences(prefs);
          final host = Host()
            ..historyMessages = [
              {'id': 1, 'role': 'user', 'content': 'Finish four tasks'},
            ];
          final controller = ProfileWorkspaceController(
            connectionIdentity: 'completed-task-handoff',
            access: ConnectionAccess(
              connection: identityTestConnection(),
              dashboardOAuth: null,
            ),
            preferences: prefs,
            appPreferences: app,
            gatewayFactory: host.gateway,
          );
          addTearDown(() {
            controller.dispose();
            app.dispose();
          });
          await controller.initialize();
          final chat = await controller.createChat(canDispatch: () => true);
          host.event('a', 'message.start');
          final snapshot = {
            'revision': 4,
            'todos': [
              for (var i = 0; i < 4; i++)
                {
                  'id': 'task-$i',
                  'content': 'Finished task $i',
                  'status': 'completed',
                },
            ],
          };
          host.event('a', 'todo.updated', snapshot);
          final frame = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: RepaintBoundary(key: frame, child: child!),
              ),
              home: ProfileWorkspaceScreen(
                createBotsSession: () => BotsSession((_) async => const []),
                controller: controller,
              ),
            ),
          );
          Future<void> settle() async {
            await tester.pump(const Duration(milliseconds: 300));
            await tester.settleMarkdown();
          }

          await settle();
          expect(find.text('Tasks 4/4'), findsOneWidget);
          await tester.tap(find.text('Tasks 4/4'));
          await settle();
          expect(find.byType(ProfileTodoPanel), findsOneWidget);
          await tester.binding.handlePopRoute();
          await settle();
          await tester.enterText(
            find.byKey(const Key('profile-message-composer')),
            'Keep draft',
          );
          host.historyMessages!.addAll([
            {
              'id': 2,
              'role': 'tool',
              'tool_call_id': 'tasks',
              'tool_name': 'todo_list',
              'content': jsonEncode(snapshot),
            },
            {'id': 3, 'role': 'assistant', 'content': 'All done'},
          ]);
          final held = Completer<void>();
          host.heldHistoryDelay = held;
          host.heldHistoryStarted = Completer<void>();
          addTearDown(() {
            if (!held.isCompleted) held.complete();
          });
          await tester.tap(find.text('Tasks 4/4'));
          await settle();
          expect(find.byType(ProfileTodoPanel), findsOneWidget);
          host.event('a', 'message.complete', {'text': 'All done'});
          await settle();
          expect(host.heldHistoryStarted!.isCompleted, isTrue);
          expect(chat.runtime.executionActive, isFalse);
          expect(find.byType(ProfileLiveWorkDock), findsNothing);
          expect(find.byType(ProfileTodoPanel), findsNothing);
          expect(find.text('Keep draft'), findsOneWidget);
          held.complete();
          host.heldHistoryDelay = null;
          await settle();
          await controller.refreshHistory(chat);
          await settle();
          expect(chat.reading.historyError, isNull);
          final activity = find.byType(ProfileToolActivitySection);
          await tester.scrollUntilVisible(
            activity,
            120,
            scrollable: find
                .descendant(
                  of: find.byType(ProfileTranscript),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pump();
          await tester.tap(
            find
                .descendant(
                  of: activity,
                  matching: find.byIcon(Icons.keyboard_arrow_right_rounded),
                )
                .first,
          );
          await settle();
          expect(find.text('Tasks 4'), findsOneWidget);
          await Scrollable.ensureVisible(
            tester.element(find.text('Tasks 4')),
            alignment: .5,
          );
          await settle();
          await tester.tap(find.text('Tasks 4'));
          await settle();
          await Scrollable.ensureVisible(
            tester.element(find.text('Finished task 0')),
            alignment: .3,
          );
          await settle();
          expect(find.text('Finished task 0'), findsOneWidget);
          if (const bool.fromEnvironment('CAPTURE_LIVE_WORK_DOCK')) {
            await tester.runAsync(() async {
              final bitmap =
                  await (frame.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await bitmap.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final dir = Directory('build/design-previews/completed-tasks')
                ..createSync(recursive: true);
              await File(
                '${dir.path}/${brightness.name}-$scale.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              bitmap.dispose();
            });
          }
          for (var round = 0; round < 3; round++) {
            host.event('a', 'message.start');
            host.event('a', 'todo.updated', snapshot);
            await settle();
            expect(find.byType(ProfileLiveWorkDock), findsNothing);
            host.event('a', 'message.complete', {
              'text': 'Later answer $round',
            });
            await settle();
          }
          expect(find.text('Keep draft'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
  const capture = bool.fromEnvironment('CAPTURE_LIVE_WORK_DOCK');
  setUpAll(() async {
    if (!capture) return;
    for (final font in {
      'Roboto': 'build/studio-roboto.ttf',
      'monospace': 'build/studio-mono.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
    }.entries) {
      await (FontLoader(
            font.key,
          )..addFont(File(font.value).readAsBytes().then(ByteData.sublistView)))
          .load();
    }
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'background dock discovers updates and controls processes ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          final app = AppPreferences(prefs);
          final host = _LiveWorkHost()
            ..processes = [
              {
                'session_id': 'process-1',
                'command':
                    'python3 /workspace/research_hotels.py --city Newcastle',
                'status': 'running',
                'output_tail': 'Comparing hotel availability',
                'uptime_seconds': 12,
              },
            ];
          final controller = ProfileWorkspaceController(
            connectionIdentity: 'background-dock',
            access: ConnectionAccess(
              connection: identityTestConnection(),
              dashboardOAuth: null,
            ),
            preferences: prefs,
            appPreferences: app,
            gatewayFactory: host.gateway,
          );
          addTearDown(() {
            controller.dispose();
            app.dispose();
          });
          await controller.initialize();
          final chat = await controller.createChat(canDispatch: () => true);
          expect(chat.processes, isEmpty);
          host.event('a', 'message.start');
          host.event('a', 'todo.updated', {
            'revision': 1,
            'todos': [
              {
                'id': 'plan-1',
                'content': 'Compare hotel prices',
                'status': 'in_progress',
              },
            ],
          });
          await controller.refreshSubagents(chat);
          final frame = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: frame, child: child!),
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () => BotsSession((_) async => []),
              ),
            ),
          );
          Future<void> settle() async {
            await tester.pump(const Duration(milliseconds: 350));
            await tester.settleMarkdown();
            await tester.pump(const Duration(milliseconds: 350));
            await tester.pump(const Duration(milliseconds: 16));
            await tester.pump(const Duration(milliseconds: 16));
          }

          Future<void> picture(String state) async {
            if (!capture) return;
            await tester.runAsync(() async {
              final image =
                  await (frame.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final dir = Directory(
                'build/design-previews/background-processes',
              )..createSync(recursive: true);
              await File(
                '${dir.path}/${brightness.name}-$scale-$state.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }

          Finder tab(int id, bool overlay) =>
              find.byKey(ValueKey(('live-work-tab', id, overlay)));
          await settle();
          expect(chat.processes, hasLength(1));
          expect(tab(0, false), findsOneWidget);
          expect(tab(1, false), findsOneWidget);
          expect(tab(2, false), findsOneWidget);
          final draft = find.byType(TextField).last;
          await tester.enterText(draft, 'Keep my hotel notes');
          FocusManager.instance.primaryFocus?.unfocus();
          await settle();
          final composer = tester.getRect(draft);
          await picture('closed');
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await settle();
          await tester.ensureVisible(tab(2, false));
          await tester.tap(tab(2, false));
          await settle();
          expect(
            tester.getRect(find.byKey(const ValueKey('live-work-panel'))).top,
            greaterThanOrEqualTo(0),
          );
          final panelOpacity = find
              .descendant(
                of: find.byKey(const ValueKey('live-work-panel')),
                matching: find.byType(Opacity),
              )
              .first;
          expect(tester.widget<Opacity>(panelOpacity).opacity, 1);
          await picture('keyboard');
          await tester.ensureVisible(tab(2, true));
          await tester.tap(tab(2, true));
          await settle();
          tester.view.resetViewInsets();
          await settle();
          await tester.ensureVisible(tab(2, false));
          await tester.tap(tab(2, false));
          await settle();
          expect(tester.getRect(draft), composer);
          expect(find.text('1 running'), findsOneWidget);
          await tester.ensureVisible(tab(2, true));
          await tester.tap(tab(2, true));
          await settle();
          final held = host.pendingProcesses =
              Completer<Map<String, dynamic>>();
          await tester.ensureVisible(tab(2, false));
          await tester.tap(tab(2, false));
          await tester.pump();
          expect(
            find.descendant(
              of: tab(2, true),
              matching: find.byType(CircularProgressIndicator),
            ),
            findsOneWidget,
          );
          expect(
            tester.getRect(tab(2, true)).right,
            lessThanOrEqualTo(tester.view.physicalSize.width),
          );
          await tester.pump(const Duration(milliseconds: 350));
          await picture('pending');
          held.completeError(StateError('Temporary process read failure'));
          await settle();
          expect(
            find.text('Background processes could not be refreshed. Retry.'),
            findsOneWidget,
          );
          await picture('failed');
          host.pendingProcesses = null;
          await tester.ensureVisible(tab(2, true));
          await tester.tap(tab(2, true));
          await settle();
          await tester.ensureVisible(tab(2, false));
          await tester.tap(tab(2, false));
          await settle();
          expect(chat.processesError, isNull);
          expect(find.text('1 running'), findsOneWidget);

          final command = host.processes.single['command'] as String;
          await tester.tap(find.text(command));
          await settle();
          await picture('open');
          // Source readers inside the process disclosure must not share the
          // expansion boolean's PageStorage identity with a scroll offset.
          expect(tester.takeException(), isNull);
          host.processes = [
            {
              ...host.processes.single,
              'output_tail': 'Found three available hotels',
            },
          ];
          await tester.pump(const Duration(seconds: 5));
          await settle();
          expect(
            chat.processes.single.outputTail,
            'Found three available hotels',
          );
          await tester.tap(find.byKey(const ValueKey('live-work-handle')));
          await settle();
          await tester.ensureVisible(find.byTooltip('Stop process'));
          await settle();
          await picture('details');
          await tester.tap(find.byTooltip('Stop process'));
          await settle();
          expect(chat.processes.single.isRunning, isFalse);
          expect(find.byTooltip('Dismiss'), findsOneWidget);
          host.event('a', 'message.complete', {'text': 'Research finished.'});
          await settle();
          expect(tab(2, true), findsNothing);
          expect(tab(2, false), findsNothing);
          expect(find.text('Keep my hotel notes'), findsOneWidget);
          host.event('a', 'message.start');
          await controller.refreshProcesses(chat);
          await settle();
          expect(tab(2, false), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets('saved partial history preserves readable live reasoning', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final app = AppPreferences(prefs);
    final host = _LiveWorkHost()
      ..historyMessages = [
        {'id': 1, 'role': 'user', 'content': 'Find local lunch in Bangkok.'},
      ];
    final controller = ProfileWorkspaceController(
      connectionIdentity: 'partial-live-activity',
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      preferences: prefs,
      appPreferences: app,
      gatewayFactory: host.gateway,
    );
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    await controller.initialize();
    final chat = await controller.createChat(canDispatch: () => true);
    host.event('a', 'message.start');
    host.event('a', 'tool.complete', {
      'tool_id': 'one',
      'name': 'web_search',
      'result': 'First search result',
    });
    host.event('a', 'reasoning.available', {'text': 'Later live reasoning'});
    host.event('a', 'tool.start', {'tool_id': 'two', 'name': 'web_extract'});
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: ProfileWorkspaceScreen(
          createBotsSession: () => BotsSession((_) async => const []),
          controller: controller,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.settleMarkdown();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ProfileActivitySection), findsNothing);
    expect(find.text('Later live reasoning'), findsOneWidget);
    expect(find.text('Timeline'), findsNothing);
    await tester.openLiveActivity();
    expect(
      find.text('Later live reasoning', findRichText: true),
      findsOneWidget,
    );
    final currentTool = tester.element(
      find.byWidgetPredicate(
        (widget) => widget is ProfileToolCall && widget.call.callId == 'two',
      ),
    );
    host.historyMessages = [
      {'id': 1, 'role': 'user', 'content': 'Find local lunch in Bangkok.'},
      {
        'id': 2,
        'role': 'assistant',
        'content': '',
        'reasoning': 'Earlier saved reasoning',
      },
      {
        'id': 3,
        'role': 'assistant',
        'content': '',
        'reasoning': 'Later live reasoning',
        'tool_calls': [
          {
            'id': 'two',
            'function': {'name': 'web_extract', 'arguments': '{}'},
          },
        ],
      },
    ];
    await controller.refreshHistory(chat);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.settleMarkdown();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ProfileActivitySection), findsNWidgets(2));
    expect(find.text('1 tool'), findsNWidgets(2));
    expect(find.byType(ProfileReasoningDisclosure), findsWidgets);
    await tester.openLiveActivity();
    expect(
      find.text('Later live reasoning', findRichText: true),
      findsOneWidget,
    );
    expect(find.byType(ProfileReasoningDisclosure), findsWidgets);
    expect(
      find.text('Earlier saved reasoning', findRichText: true),
      findsOneWidget,
    );
    expect(chat.reading.messages.any((row) => row['id'] == 3), isTrue);
    expect(
      tester.element(
        find.byWidgetPredicate(
          (widget) => widget is ProfileToolCall && widget.call.callId == 'two',
        ),
      ),
      same(currentTool),
    );
    expect(chat.reading.messages.where((row) => row['id'] == 2), hasLength(1));
    final persistence = Completer<void>();
    host.heldHistoryStarted = Completer<void>();
    host.heldHistoryDelay = persistence;
    host.heldHistoryFailure = StateError(
      'Saved history temporarily unavailable',
    );
    addTearDown(() {
      if (!persistence.isCompleted) persistence.complete();
    });
    host.event('a', 'message.complete', {
      'text': 'Final answer before persistence',
    });
    await tester.pump(const Duration(milliseconds: 300));
    await tester.settleMarkdown();
    expect(host.heldHistoryStarted!.isCompleted, isTrue);
    tester
        .widget<ScrollView>(find.byKey(const ValueKey('profile-transcript')))
        .controller!
        .jumpTo(0);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.settleMarkdown();
    expect(
      find.byType(ProfileActivitySection, skipOffstage: false),
      findsOneWidget,
      reason: 'Received final answer must not split saved and retained work',
    );
    persistence.complete();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.settleMarkdown();
    expect(
      find.byType(ProfileActivitySection, skipOffstage: false),
      findsOneWidget,
    );

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'streaming Activity durations production route ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          final app = AppPreferences(prefs);
          final host = _LiveWorkHost();
          final controller = ProfileWorkspaceController(
            connectionIdentity: 'timed-activity-render',
            access: ConnectionAccess(
              connection: identityTestConnection(),
              dashboardOAuth: null,
            ),
            preferences: prefs,
            appPreferences: app,
            gatewayFactory: host.gateway,
          );
          addTearDown(() {
            controller.dispose();
            app.dispose();
          });
          await controller.initialize();
          final chat = await controller.createChat(canDispatch: () => true);
          host.historyMessages = [
            {
              'id': 1,
              'role': 'user',
              'content': 'Check the fees.',
              'timestamp': DateTime.now().millisecondsSinceEpoch / 1000 - 84,
            },
          ];
          await controller.refreshHistory(chat);
          host.event('a', 'message.start');
          host.event('a', 'tool.complete', {
            'tool_id': 'first',
            'name': 'web_search',
            'result': 'Official fee details.',
            'duration_s': .2,
          });
          host.event('a', 'reasoning.available', {
            'text': 'Confirming fee details.',
          });
          host.event('a', 'tool.start', {
            'tool_id': 'current',
            'name': 'web_search',
          });
          final frame = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: RepaintBoundary(key: frame, child: child!),
              ),
              home: ProfileWorkspaceScreen(
                createBotsSession: () => BotsSession((_) async => const []),
                controller: controller,
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.settleMarkdown();
          await tester.openLiveActivity(tools: false);
          final intervals = tester
              .widgetList<ActivityTime>(
                find.descendant(
                  of: find.byType(ProfileActivitySection),
                  matching: find.byType(ActivityTime),
                ),
              )
              .toList();
          expect(intervals, hasLength(2));
          expect(intervals.last.durationSeconds, closeTo(84, 2));
          expect(intervals.first.durationSeconds, isNull);
          expect(find.text('· 1m 24s'), findsOneWidget);
          expect(find.byType(ProfileToolCall), findsNothing);
          for (final time
              in find
                  .descendant(
                    of: find.byType(ProfileActivitySection),
                    matching: find.byType(ActivityTime),
                  )
                  .evaluate()) {
            final bounds = tester.getRect(
              find.byElementPredicate((element) => element == time),
            );
            final section = find
                .ancestor(
                  of: find.byElementPredicate((element) => element == time),
                  matching: find.byType(ProfileActivitySection),
                )
                .first;
            final chevron = find
                .descendant(
                  of: section,
                  matching: find.byIcon(Icons.keyboard_arrow_right_rounded),
                )
                .first;
            expect(
              tester.getCenter(chevron).dy,
              closeTo(bounds.center.dy, .1),
              reason:
                  'The disclosure chevron stays beside the duration when metadata wraps.',
            );
            expect(bounds.left, greaterThanOrEqualTo(0));
            expect(bounds.right, lessThanOrEqualTo(scale == 1 ? 390 : 320));
          }
          if (capture) {
            await tester.runAsync(() async {
              final bitmap =
                  await (frame.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage(pixelRatio: 1);
              try {
                final bytes = await bitmap.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final target = File(
                  'build/design-previews/live-work-native/route-${brightness.name}-$scale-timed-activity.png',
                );
                await target.parent.create(recursive: true);
                await target.writeAsBytes(bytes!.buffer.asUint8List());
              } finally {
                bitmap.dispose();
              }
            });
          }
          final sections = find.descendant(
            of: find.byType(ProfileLiveExecution),
            matching: find.byType(ProfileActivitySection),
          );
          for (final element in sections.evaluate().toList()) {
            final section = find.byElementPredicate(
              (candidate) => candidate == element,
            );
            final header = find
                .descendant(of: section, matching: find.byType(ListTile))
                .first;
            await Scrollable.ensureVisible(
              tester.element(header),
              alignment: .5,
            );
            await tester.pump(const Duration(milliseconds: 300));
            expect(
              header.hitTestable(at: const Alignment(-.9, 0)),
              findsOneWidget,
            );
            await tester.tapAt(
              tester.getRect(header).centerLeft + const Offset(12, 0),
            );
            await tester.pump(const Duration(milliseconds: 300));
            await tester.settleMarkdown();
            expect(find.byType(ProfileToolCall), findsOneWidget);
            await Scrollable.ensureVisible(
              tester.element(header),
              alignment: .5,
            );
            await tester.pump(const Duration(milliseconds: 300));
            expect(
              header.hitTestable(at: const Alignment(-.9, 0)),
              findsOneWidget,
            );
            await tester.tapAt(
              tester.getRect(header).centerLeft + const Offset(12, 0),
            );
            await tester.pump(const Duration(milliseconds: 300));
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
      testWidgets('live work production route ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final app = AppPreferences(prefs);
        final host = _LiveWorkHost()
          ..todoState = {
            'revision': 4,
            'todos': [
              for (var i = 0; i < 7; i++)
                {
                  'id': 'task-$i',
                  'content': [
                    'Read retained health data',
                    'Confirm source units',
                    'Map sleep metrics',
                    'Research definitions for the remaining metrics',
                    'Build the health domain model',
                    'Validate mappings',
                    'Report findings',
                  ][i],
                  'status': i < 3
                      ? 'completed'
                      : i == 3
                      ? 'in_progress'
                      : i == 6
                      ? 'cancelled'
                      : 'pending',
                },
            ],
          };
        final controller = ProfileWorkspaceController(
          connectionIdentity: 'live-work-render',
          access: ConnectionAccess(
            connection: identityTestConnection(),
            dashboardOAuth: null,
          ),
          preferences: prefs,
          appPreferences: app,
          gatewayFactory: host.gateway,
        );
        addTearDown(() {
          controller.dispose();
          app.dispose();
        });
        await controller.initialize();
        final chat = await controller.createChat(canDispatch: () => true);
        await controller.refreshSubagents(chat);
        host.event('a', 'message.start');
        host.event('a', 'tool.complete', {
          'tool_id': 'retained',
          'name': 'read_file',
          'args': {'path': 'health/metrics.md'},
          'result': '## Health metrics\n\nRetained source units.',
          'duration_s': .195,
        });
        host.event('a', 'reasoning.delta', {
          'text':
              'I’m mapping the **health domain** from the retained data.\n\n'
              'The sleep pipeline stays as existing work. Next I’ll verify the remaining units.',
        });
        host.event('a', 'tool.start', {
          'tool_id': 'research',
          'name': 'web_search',
          'args': {'query': 'health metric definitions'},
        });
        host.event('a', 'todo.updated', {'revision': 5, 'todos': []});
        final frame = GlobalKey();
        final keyboard = ValueNotifier<double>(0);
        addTearDown(keyboard.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => ValueListenableBuilder<double>(
              valueListenable: keyboard,
              builder: (_, inset, _) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                  viewInsets: EdgeInsets.only(bottom: inset),
                ),
                child: RepaintBoundary(key: frame, child: child!),
              ),
            ),
            home: ProfileWorkspaceScreen(
              createBotsSession: () => BotsSession((_) async => const []),
              controller: controller,
            ),
          ),
        );
        Future<void> settle() async {
          await tester.pump(const Duration(milliseconds: 300));
          await tester.settleMarkdown();
          await tester.pump();
        }

        Future<void> picture(String state) async {
          if (!capture) return;
          await tester.runAsync(() async {
            final bitmap =
                await (frame.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            try {
              final bytes = await bitmap.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final dir = Directory('build/design-previews/live-work-native')
                ..createSync(recursive: true);
              await File(
                '${dir.path}/route-${brightness.name}-$scale-$state.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              bitmap.dispose();
            }
          });
        }

        Finder tab(int i, {bool overlay = true}) =>
            find.byKey(ValueKey(('live-work-tab', i, overlay)));
        await settle();
        expect(find.text('Timeline'), findsNothing);
        await tester.openLiveActivity();
        await settle();
        final sharedTranscript = tester.widget<ProfileTranscript>(
          find.byType(ProfileTranscript),
        );
        expect(
          sharedTranscript.activity?.runtime.runtimeId,
          chat.runtime.runtimeId,
        );
        expect(sharedTranscript.activity?.live, isTrue);
        expect(find.byType(ProfileLiveWorkDock), findsOneWidget);
        expect(find.text('Tasks 3/7'), findsNothing);
        expect(find.text('2 subagents'), findsOneWidget);
        expect(find.byType(ProfileReasoningDisclosure), findsWidgets);
        // Both tool runs stay visible around the received reasoning.
        expect(find.byType(ProfileToolCall), findsNWidgets(2));
        await tester.enterText(
          find.byKey(const Key('profile-message-composer')),
          'Keep my draft',
        );
        await settle();
        expect(chat.composer.observation.displayedText, 'Keep my draft');
        final composer = find.byKey(const ValueKey('conversation-composer'));
        final rect = tester.getRect(composer);
        await picture('agents-only-folded');
        expect(tab(1, overlay: false), findsNothing);
        await tester.fling(
          tab(0, overlay: false),
          const Offset(40, -100),
          1000,
        );
        await settle();
        expect(
          tester.getSize(find.byKey(const ValueKey('live-work-panel'))).height,
          lessThanOrEqualTo(320),
        );
        await picture('agents-zone-compact');
        await tester.fling(tab(0), const Offset(40, -100), 1000);
        await settle();
        expect(
          tester.getRect(find.byKey(const ValueKey('live-work-panel'))).top,
          closeTo(8, 1),
        );
        expect(tester.getRect(composer), rect);
        await picture('agents-zone-expanded');
        await tester.tap(tab(0));
        await settle();
        await tester.tap(tab(0, overlay: false));
        await settle();
        await picture('agents-only-open');
        final fittedAgents = tester.getSize(find.byType(PageView)).height;
        expect(fittedAgents, lessThanOrEqualTo(320));
        host.event('a', 'todo.updated', {
          'revision': 6,
          'todos': host.todoState!['todos'],
        });
        await settle();
        expect(find.text('Tasks 3/7'), findsWidgets);
        expect(tester.getRect(composer), rect);
        expect(
          tester.widget<PageView>(find.byType(PageView)).controller!.page,
          0,
        );
        expect(tester.getSize(find.byType(PageView)).height, fittedAgents);
        await picture('second-tab-arrived');
        await tester.tap(tab(0));
        await settle();
        await picture('folded');
        await tester.fling(
          tab(1, overlay: false),
          const Offset(-40, -100),
          1000,
        );
        await settle();
        expect(
          tester.getSize(find.byKey(const ValueKey('live-work-panel'))).height,
          lessThanOrEqualTo(320),
        );
        await picture('tasks-zone-compact');
        await tester.fling(tab(1), const Offset(-40, -100), 1000);
        await settle();
        expect(
          tester.getRect(find.byKey(const ValueKey('live-work-panel'))).top,
          closeTo(8, 1),
        );
        expect(tester.getRect(composer), rect);
        await picture('tasks-zone-expanded');
        await tester.tap(tab(1));
        await settle();
        await tester.tap(tab(1, overlay: false));
        await settle();
        expect(tester.getRect(composer), rect);
        expect(
          find.text('Research definitions for the remaining metrics'),
          findsOneWidget,
        );
        await picture('tasks');
        final drawer = find.byKey(const ValueKey('live-work-panel'));
        final handle = find.byKey(const ValueKey('live-work-handle'));
        final compact = tester.getRect(drawer);
        await tester.fling(handle, const Offset(0, 70), 1000);
        await settle();
        expect(find.byType(PageView), findsNothing);
        expect(tester.getRect(composer), rect);
        await picture('tasks-swipe-closed');
        await tester.tap(tab(1, overlay: false));
        await settle();
        expect(tester.getRect(drawer), compact);
        await tester.fling(find.byType(PageView), const Offset(50, -100), 1000);
        await settle();
        expect(tester.getRect(drawer).top, closeTo(8, 1));
        expect(tester.getRect(drawer).bottom, compact.bottom);
        expect(tester.getRect(composer), rect);
        final taskSummary = tester.getRect(find.byType(ProfileTodoSummary));
        await tester.drag(find.byType(PageView), const Offset(25, -100));
        await settle();
        expect(tester.getRect(find.byType(ProfileTodoSummary)), taskSummary);
        await picture('tasks-expanded');
        await tester.tap(tab(0));
        await settle();
        expect(tester.getRect(composer), rect);
        expect(find.text('Inspect source mappings'), findsOneWidget);
        expect(tester.getRect(drawer).top, closeTo(8, 1));
        expect(find.text('0 of 2 completed · 2 running'), findsOneWidget);
        await picture('subagents-expanded');
        await tester.fling(
          find.text('0 of 2 completed · 2 running'),
          const Offset(50, 100),
          1000,
        );
        await settle();
        expect(find.byType(PageView), findsNothing);
        expect(tester.getRect(composer), rect);
        await picture('subagents-swipe-closed');
        await tester.tap(tab(0, overlay: false));
        await settle();
        expect(tester.getSize(drawer).height, lessThanOrEqualTo(320));
        await picture('subagents');

        void expectNoReadButtons() {
          final panel = find.byType(ProfileSubagentPanel);
          expect(panel, findsOneWidget);
          for (final label in ['Refresh', 'Retry']) {
            expect(
              find.descendant(of: panel, matching: find.byTooltip(label)),
              findsNothing,
            );
          }
        }

        expectNoReadButtons();
        final beforeRetry = host.rosterReads;
        await tester.tap(tab(0));
        await settle();
        host.pendingRoster = Completer<Map<String, dynamic>>();
        await tester.tap(tab(0, overlay: false));
        await tester.pump();
        expect(host.rosterReads, beforeRetry + 1);
        expect(find.byType(CircularProgressIndicator), findsWidgets);
        await settle();
        expect(find.byType(CircularProgressIndicator), findsWidgets);
        expect(find.text('Inspect source mappings'), findsOneWidget);
        expect(tester.getRect(composer), rect);
        expectNoReadButtons();
        await picture('roster-held');
        host.pendingRoster!.completeError(StateError('Roster unavailable'));
        await settle();
        expect(chat.subagentsError, isNotNull);
        expect(
          find.text('${chat.subagentsError!} Reopen to retry.'),
          findsOneWidget,
        );
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expectNoReadButtons();
        await picture('roster-failed');
        // The same tab closes the drawer. Reopening is the retry control.
        await tester.tap(tab(0));
        await settle();
        expect(find.byType(PageView), findsNothing);
        host.pendingRoster = Completer<Map<String, dynamic>>();
        await tester.tap(tab(0, overlay: false));
        await tester.pump();
        expect(host.rosterReads, beforeRetry + 2);
        expect(chat.subagentsError, isNull);
        expect(find.byType(CircularProgressIndicator), findsWidgets);
        expectNoReadButtons();
        host.pendingRoster!.complete({'subagents': host.agents});
        await settle();
        host.pendingRoster = null;
        expect(chat.subagentsError, isNull);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('Inspect source mappings'), findsOneWidget);
        expect(chat.composer.observation.displayedText, 'Keep my draft');
        expect(tester.getRect(composer), rect);
        expectNoReadButtons();
        await picture('roster-recovered');
        keyboard.value = 260;
        await settle();
        expect(tester.getRect(composer).bottom, lessThanOrEqualTo(844 - 260));
        expect(tester.getRect(drawer).top, greaterThanOrEqualTo(8));
        expect(
          tester.getRect(find.byType(PageView)).top,
          closeTo(tester.getRect(handle).bottom, .1),
        );
        await picture('keyboard');
        await tester.tap(handle);
        await settle();
        expect(tester.getRect(drawer).top, closeTo(8, 1));
        expect(
          tester.getRect(drawer).bottom,
          lessThan(tester.getRect(composer).top),
        );
        await picture('keyboard-expanded');
        await tester.binding.handlePopRoute();
        await settle();
        expect(find.byType(PageView), findsNothing);
        expect(find.byType(ProfileLiveWorkDock), findsOneWidget);
        expect(find.text('Keep my draft'), findsOneWidget);
        keyboard.value = 0;
        await settle();
        await tester.openLiveActivity();
        await settle();
        // The transcript is lazy: inspect retention while the tool is visible,
        // rather than expecting an offscreen row to remain mounted.
        await tester.scrollUntilVisible(
          find.byType(ProfileToolCall).last,
          120,
          scrollable: find
              .descendant(
                of: find.byType(ProfileTranscript),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await settle();
        final liveTool = tester.element(find.byType(ProfileToolCall).last);
        host.event('a', 'message.delta', {'text': 'The first answer text.'});
        await settle();
        expect(
          tester.element(find.byType(ProfileToolCall).last),
          same(liveTool),
        );
        // The shorter direct Timeline may already be at the newest edge.
        final latest = find.byType(TranscriptLatestButton);
        if (latest.evaluate().isNotEmpty) {
          await tester.tap(latest);
          await settle();
        }
        expect(
          find.text('The first answer text.', findRichText: true),
          findsOneWidget,
        );
        keyboard.value = 0;
        for (final agent in host.agents) {
          agent['status'] = 'completed';
        }
        host.historyMessages = [
          {'id': 1, 'role': 'user', 'content': 'Map the health metrics.'},
          {
            'id': 2,
            'role': 'tool',
            'tool_call_id': 'retained',
            'tool_name': 'read_file',
            'args': {'path': 'health/metrics.md'},
            'content': 'Retained source units.',
          },
          {'id': 3, 'role': 'assistant', 'content': 'The mapping is underway.'},
          {
            'id': 4,
            'role': 'user',
            'display_kind': 'async_delegation_complete',
            'display_metadata': {
              'task_count': 1,
              'display_text':
                  'Subagent Task Completed: Inspect source mappings',
            },
            'content': 'Verified the health mappings.',
          },
          {
            'id': 5,
            'role': 'tool',
            'tool_call_id': 'research',
            'tool_name': 'web_search',
            'args': {'query': 'health metric definitions'},
            'content': 'Checked the metric definitions.',
          },
          {'id': 6, 'role': 'assistant', 'content': 'The saved final answer.'},
        ];
        // A completion receipt can save while its parent is still streaming.
        // That must not move or duplicate the canonical agent into Activity.
        final finalAnswer = host.historyMessages!.removeLast();
        await controller.refreshHistory(chat);
        await settle();
        expect(chat.runtime.executionActive, isTrue);
        expect(chat.reading.messages.any((row) => row['id'] == 4), isTrue);
        // At enlarged text the retained Activity row can sit above the viewport
        // even at the newest edge. Scroll back to its disclosure, rather than
        // assuming that a jump-to-latest control must exist.
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('live-activity')),
          120,
          scrollable: find
              .descendant(
                of: find.byType(ProfileTranscript),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await settle();
        await tester.openLiveActivity();
        await settle();
        final liveTabs = find.descendant(
          of: find.byType(ProfileLiveExecution),
          matching: find.byType(ProfileActivityTabs),
        );
        expect(liveTabs, findsNothing);
        expect(
          find.text('Subagent Task Completed: Inspect source mappings'),
          findsNothing,
        );
        await picture('current-receipt-timeline');
        await tester.tap(tab(0, overlay: false));
        await settle();
        expect(find.text('Inspect source mappings'), findsOneWidget);
        expect(chat.subagents.every((agent) => agent.isTerminal), isTrue);
        await picture('current-receipt-drawer');
        host.historyMessages!.add(finalAnswer);
        host.event('a', 'message.complete', {
          'text': 'The saved final answer.',
        });
        await tester.pump();
        expect(chat.runtime.executionActive, isFalse);
        expect(tab(0), findsNothing);
        expect(tab(0, overlay: false), findsNothing);
        await settle();
        expect(find.byType(ProfileSubagentPanel), findsNothing);
        expect(tab(1), findsOneWidget);
        await picture('turn-ended-drawer');
        await tester.binding.handlePopRoute();
        await settle();
        for (var i = 0; i < 8; i++) {
          await settle();
          if (!chat.runtime.executionActive) break;
        }
        expect(chat.runtime.executionActive, isFalse);
        for (final agent in host.agents) {
          host.event('a', 'subagent.complete', {
            'subagent_id': agent['subagent_id'],
            'status': 'completed',
          });
        }
        await settle();
        expect(chat.subagents, hasLength(2));
        expect(chat.subagents.every((agent) => agent.isTerminal), isTrue);
        expect(chat.reading.streamingMessage, isNull);
        expect(find.byType(ProfileLiveWorkDock), findsOneWidget);
        expect(tab(0, overlay: false), findsNothing);
        expect(tab(1, overlay: false), findsOneWidget);
        expect(find.byType(ProfileLiveExecution), findsNothing);
        expect(find.text('Keep my draft'), findsOneWidget);
        expect(
          find.text('Subagent Task Completed: Inspect source mappings'),
          findsNothing,
        );
        final saved = find.byWidgetPredicate(
          (widget) =>
              widget is ProfileToolActivitySection &&
              widget.section.containsMessage(4),
        );
        expect(chat.reading.messages.any((row) => row['id'] == 4), isTrue);
        final savedTitle = find.descendant(
          of: saved,
          matching: find.text('Activity · 1 tool'),
        );
        // The live-history handoff retains the current reading position. Start
        // from the newest answer before browsing back to its saved Activity;
        // that row may not yet be built on the newer side of the old anchor.
        final latestAnswer = find.byKey(const ValueKey('jump-to-latest'));
        if (latestAnswer.evaluate().isNotEmpty) {
          expect(latestAnswer.hitTestable(), findsOneWidget);
          await tester.tap(latestAnswer);
          await settle();
        }
        // Navigate through the actual viewport. Whole-row ensureVisible can
        // place a lazily resized row's header outside a short enlarged viewport.
        for (var i = 0; i < 20; i++) {
          if (savedTitle.evaluate().isNotEmpty) {
            await tester.ensureVisible(savedTitle);
            await settle();
          }
          if (savedTitle
              .hitTestable(at: Alignment.centerLeft)
              .evaluate()
              .isNotEmpty) {
            break;
          }
          await tester.drag(
            find.byType(ProfileTranscript),
            const Offset(0, 120),
          );
          await settle();
        }
        expect(
          savedTitle.hitTestable(at: Alignment.centerLeft),
          findsOneWidget,
        );
        await picture('saved-folded');
        final savedTitleRect = tester.getRect(savedTitle);
        await tester.tapAt(
          Offset(savedTitleRect.left + 4, savedTitleRect.center.dy),
        );
        await settle();
        expect(
          find.descendant(of: saved, matching: find.text('Timeline')),
          findsOneWidget,
        );
        expect(
          find.text('Subagent Task Completed: Inspect source mappings'),
          findsNothing,
        );
        final agents = find.descendant(
          of: saved,
          matching: find.text('Agents'),
        );
        await tester.ensureVisible(agents);
        await settle();
        // Anchored expansion can retain the header while large tabs extend
        // below the viewport. Scroll the actual tab into reach before tapping.
        for (
          var i = 0;
          i < 10 && agents.hitTestable().evaluate().isEmpty;
          i++
        ) {
          final viewport = tester.getRect(find.byType(ProfileTranscript));
          final movement = (viewport.center.dy - tester.getCenter(agents).dy)
              .clamp(-150.0, 150.0);
          await tester.drag(
            find.byType(ProfileTranscript),
            Offset(0, movement),
          );
          await settle();
        }
        expect(agents.hitTestable(), findsOneWidget);
        await tester.tap(agents);
        await settle();
        expect(
          find.descendant(
            of: saved,
            matching: find.text(
              'Subagent Task Completed: Inspect source mappings',
            ),
          ),
          findsOneWidget,
        );
        final result = find.descendant(
          of: saved,
          matching: find.text('View result'),
        );
        await tester.ensureVisible(result);
        await settle();
        await tester.tap(
          find.descendant(
            of: find.byKey(
              const ValueKey<(String, Object?)>(('transcript-notice', 4)),
            ),
            matching: find.byIcon(Icons.expand_more),
          ),
        );
        await settle();
        final output = find.text(
          'Verified the health mappings.',
          findRichText: true,
        );
        expect(output, findsOneWidget);
        await tester.ensureVisible(output);
        await settle();
        await picture('turn-ended-saved-agents');
        await picture('saved-agents');
        // Keep reading the previous Activity instead of following the newest
        // edge when the next turn adds rows to the lazy transcript.
        await tester.drag(find.byType(ProfileTranscript), const Offset(0, 240));
        await settle();
        expect(output, findsOneWidget);
        // Start another answer while the previous Activity remains open on
        // Agents. Its completed children must no longer occupy the live dock.
        host.historyMessages!.add({
          'id': 7,
          'role': 'user',
          'content': 'Now find massage venues.',
        });
        await controller.refreshHistory(chat);
        host.event('a', 'message.start');
        host.event('a', 'message.delta', {'text': 'Checking nearby venues.'});
        await settle();
        expect(chat.runtime.executionActive, isTrue);
        expect(tab(0, overlay: false), findsNothing);
        expect(tab(1, overlay: false), findsOneWidget);
        expect(find.text('2 subagents'), findsNothing);
        expect(output, findsOneWidget);
        await tester.ensureVisible(output);
        await settle();
        await picture('next-round-previous-agents');
        keyboard.value = 260;
        await settle();
        final newest = find.byKey(const ValueKey('jump-to-latest'));
        if (newest.evaluate().isNotEmpty) {
          await tester.tap(newest);
          await settle();
        }
        expect(tab(0, overlay: false), findsNothing);
        expect(
          find.text('Checking nearby venues.', findRichText: true),
          findsOneWidget,
        );
        await picture('next-round-keyboard');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
      testWidgets(
        'reasoning handoff production route ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          final app = AppPreferences(prefs);
          final host = _LiveWorkHost()
            ..historyMessages = [
              {
                'id': 1,
                'role': 'user',
                'content': 'Find hotels within the travel policy.',
              },
            ];
          final controller = ProfileWorkspaceController(
            connectionIdentity: 'reasoning-handoff-render',
            access: ConnectionAccess(
              connection: identityTestConnection(),
              dashboardOAuth: null,
            ),
            preferences: prefs,
            appPreferences: app,
            gatewayFactory: host.gateway,
          );
          addTearDown(() {
            controller.dispose();
            app.dispose();
          });
          await controller.initialize();
          final chat = await controller.createChat(canDispatch: () => true);
          host.event('a', 'message.start');
          host.event('a', 'tool.complete', {
            'tool_id': 'policy',
            'name': 'read_file',
            'args': {'path': 'business-trip-policy.md'},
            'result': 'Use the official booking pages.',
          });
          final frame = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: RepaintBoundary(key: frame, child: child!),
              ),
              home: ProfileWorkspaceScreen(
                createBotsSession: () => BotsSession((_) async => const []),
                controller: controller,
              ),
            ),
          );
          Future<void> settle() async {
            await tester.pump(const Duration(milliseconds: 300));
            await tester.settleMarkdown();
            await tester.pump(const Duration(milliseconds: 300));
          }

          Future<void> picture(String state) async {
            if (!capture) return;
            await tester.runAsync(() async {
              final bitmap =
                  await (frame.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage();
              try {
                final bytes = await bitmap.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final dir = Directory('build/design-previews/live-work-native')
                  ..createSync(recursive: true);
                await File(
                  '${dir.path}/handoff-${brightness.name}-$scale-$state.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
              } finally {
                bitmap.dispose();
              }
            });
          }

          await settle();
          expect(find.text('Timeline'), findsNothing);
          expect(find.text('1 tool'), findsOneWidget);
          expect(find.byType(ProfileToolCall), findsNothing);
          await picture('tools-collapsed');
          await tester.openLiveActivity();
          await settle();
          expect(find.text('Timeline'), findsNothing);
          await tester.enterText(
            find.byKey(const Key('profile-message-composer')),
            'Keep my draft',
          );
          await settle();
          final composer = find.byKey(const ValueKey('conversation-composer'));
          final bounds = tester.getRect(composer);
          await picture('tools-only');
          const heading = 'Searching for Tokyo hotels';
          final headingLabel = find.byWidgetPredicate(
            (widget) => widget is Text && widget.data == heading,
          );
          const reasoningBody = 'Check the official booking pages for Gotanda.';
          host.event('a', 'reasoning.delta', {
            'text': '**$heading**\n\n$reasoningBody',
          });
          await settle();
          await tester.openLiveActivity();
          await settle();
          expect(find.text('Thinking'), findsNothing);
          expect(headingLabel, findsOneWidget);
          expect(tester.getRect(composer), bounds);
          await picture('thinking');
          final activityToggle = find.byKey(
            const ValueKey('live-activity-toggle'),
          );
          await tester.ensureVisible(activityToggle);
          await settle();
          final collapse = find.descendant(
            of: activityToggle,
            matching: find.byIcon(Icons.expand_less),
          );
          expect(collapse.hitTestable(), findsOneWidget);
          await tester.tap(collapse);
          await settle();
          expect(find.text(heading), findsOneWidget);
          await picture('reasoning-collapsed');
          await tester.openLiveActivity(tools: false);
          await settle();
          host.event('a', 'tool.start', {
            'tool_id': 'booking',
            'name': 'web_search',
            'args': {'query': 'Tokyo Gotanda official booking'},
          });
          await settle();
          expect(chat.runtime.executionActive, isTrue);
          expect(find.text('Thinking'), findsNothing);
          expect(headingLabel, findsOneWidget);
          expect(find.text('Reasoning'), findsOneWidget);
          expect(find.byType(ProfileActivitySection), findsNWidgets(2));
          expect(find.byType(ProfileToolCall), findsOneWidget);
          // Opening the earlier run preserves its header. Move through the
          // viewport to inspect the reasoning and the next collapsed run.
          expect(find.text(reasoningBody, findRichText: true), findsNothing);
          await tester.ensureVisible(headingLabel);
          await settle();
          final latest = find.byKey(const ValueKey('jump-to-latest'));
          if (latest.evaluate().isNotEmpty) {
            await tester.tap(latest);
            await settle();
          }
          await picture('tool-handoff-collapsed');
          await tester.openLiveActivity();
          expect(find.text('Timeline'), findsNothing);
          expect(find.byType(ProfileToolCall), findsNWidgets(2));
          expect(tester.getRect(composer), bounds);
          expect(chat.composer.observation.displayedText, 'Keep my draft');
          expect(find.text(reasoningBody, findRichText: true), findsNothing);
          await tester.ensureVisible(headingLabel);
          await settle();
          await picture('tool-handoff-readable');
          host.event('a', 'tool.complete', {
            'tool_id': 'booking',
            'name': 'web_search',
            'result': 'Received booking search results.',
          });
          for (var i = 0; i < 11; i++) {
            host.event('a', 'tool.complete', {
              'tool_id': 'lunch-source-$i',
              'name': 'web_search',
              'args': {'query': 'Local Bangkok lunch source $i'},
              'result': 'Received source $i.',
              'duration_s': 32,
            });
          }
          host.event('a', 'reasoning.available', {
            'text': 'Check the restaurant menu and opening hours.',
          });
          for (final entry in {
            'lunch-query': 'web_search',
            'hours-query': 'web_search',
            'lunch-page': 'web_extract',
            'menu-image': 'vision_analyze',
          }.entries) {
            host.event('a', 'tool.complete', {
              'tool_id': entry.key,
              'name': entry.value,
              'args': {'query': 'Bangkok local lunch ${entry.key}'},
              'result': 'Received ${entry.key}.',
              'duration_s': 32,
            });
          }
          await settle();
          expect(find.byType(ProfileActivitySection), findsNWidgets(3));
          await tester.openLiveActivity();
          expect(headingLabel, findsOneWidget);
          expect(
            find.text(
              'Check the restaurant menu and opening hours.',
              findRichText: true,
            ),
            findsOneWidget,
          );
          expect(find.text('Timeline'), findsNothing);
          expect(find.byType(ProfileToolCall), findsNWidgets(17));
          expect(tester.getRect(composer), bounds);
          expect(find.text(reasoningBody, findRichText: true), findsNothing);
          await tester.ensureVisible(headingLabel);
          await settle();
          await picture('multiple-cycles-readable');
          host.historyMessages = [
            {
              'id': 1,
              'role': 'user',
              'content': 'Find hotels within the travel policy.',
            },
            {
              'id': 2,
              'role': 'assistant',
              'content': '',
              'reasoning': 'Saved planning before the first tool.',
            },
            {
              'id': 3,
              'role': 'tool',
              'tool_call_id': 'policy',
              'tool_name': 'read_file',
              'content': 'Use the official booking pages.',
            },
          ];
          await controller.refreshHistory(chat);
          await settle();
          expect(find.byType(ProfileActivitySection), findsNWidgets(3));
          expect(find.text('12 tools'), findsOneWidget);
          expect(find.text('4 tools'), findsOneWidget);
          expect(headingLabel, findsOneWidget);
          expect(
            find.text(
              'Check the restaurant menu and opening hours.',
              findRichText: true,
            ),
            findsOneWidget,
          );
          expect(chat.reading.messages.any((row) => row['id'] == 3), isTrue);
          expect(tester.getRect(composer), bounds);
          expect(find.text(reasoningBody, findRichText: true), findsNothing);
          await tester.ensureVisible(headingLabel);
          await settle();
          await picture('history-refreshed-readable');
          // Saved current-turn reasoning stays title-only while streaming.
          // Receipt persistence does not restore an expandable body.
          expect(find.byType(ProfileReasoningDisclosure), findsWidgets);
          await tester.openLiveActivity();
          await settle();
          expect(find.text('Timeline'), findsNothing);
          final savedReasoning = find.text(
            'Saved planning before the first tool.',
            findRichText: true,
          );
          expect(savedReasoning, findsOneWidget);
          await tester.ensureVisible(savedReasoning);
          await settle();
          await picture('reasoning');
          await Scrollable.ensureVisible(
            tester.element(headingLabel),
            alignment: .5,
          );
          await settle();
          await settle();
          await picture('live-reasoning');
          expect(headingLabel, findsOneWidget);
          expect(chat.runtime.executionActive, isTrue);
          expect(tester.getRect(composer), bounds);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}

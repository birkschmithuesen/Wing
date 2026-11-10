import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/studio_error.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/widgets/source_code_text.dart';
import 'package:wing/core/widgets/subagent_timeline.dart';
import 'package:wing/core/services/profile_supervision_session.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/activity_time.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/widgets/profile_subagent_panel.dart';
import 'package:wing/core/widgets/profile_live_work_dock.dart';
import 'package:wing/core/widgets/profile_live_execution.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_actions_fixture.dart';
import 'support/composer_fixture.dart' show emitChatEvent;
import 'helpers/pump_markdown_widget.dart';

class _SubagentFixture extends ProfileActionsFixture {
  List<Map<String, dynamic>>? childMessages;
  final childEvents = <Map<String, dynamic>>[];
  int listCalls = 0;
  int tailCalls = 0;
  int tailFailures = 0;
  Completer<void>? tailGate;
  Completer<void>? steerGate;
  bool acceptSteer = false;
  bool failSteer = false;
  bool findInterrupt = false;
  bool failInterrupt = false;
  bool emptyList = false;
  bool tailAvailable = true;
  double? startedAt;
  List<Map<String, dynamic>>? rows;
  final requests = <(String, Map<String, dynamic>)>[];

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      get: (path, query) async {
        if (path == 'sessions/child-session/messages') {
          return {
            'session_id': 'child-session',
            'messages':
                childMessages?.reversed.toList() ??
                [
                  {
                    'id': 101,
                    'role': 'assistant',
                    'content': 'Child saved evidence',
                  },
                ],
            'pagination': {
              'offset': int.parse(query['offset']!),
              'limit': int.parse(query['limit']!),
              'returned': childMessages?.length ?? 1,
              'order': 'latest',
            },
          };
        }
        return base.read(path, query);
      },
      rpc: (method, params) async {
        requests.add((method, params));
        if (method == 'session.resume' &&
            params['session_id'] == 'child-session') {
          expect(params['display_projection'], isTrue);
          expect(params.containsKey('lazy'), isFalse);
          expect(params.containsKey('omit_messages'), isFalse);
          return {
            'session_id': 'child-session',
            'stored_session_id': 'child-session',
            'replay_epoch': 'child-epoch',
            'last_sequence': childEvents.length,
            'running': true,
          };
        }
        if (method == 'session.events.since' &&
            params['session_id'] == 'child-session') {
          expect(params['replay_epoch'], 'child-epoch');
          return {
            'replay_epoch': 'child-epoch',
            'events': [
              for (final event in childEvents)
                if ((event['seq'] as int) > (params['last_sequence'] as int))
                  event,
            ],
            'latest_seq': childEvents.fold<int>(
              0,
              (latest, event) =>
                  (event['seq'] as int) > latest ? event['seq'] as int : latest,
            ),
            'truncated': false,
            'snapshot_required': false,
          };
        }
        switch (method) {
          case 'subagent.list':
            listCalls += 1;
            return {
              'subagents':
                  rows ??
                  [
                    if (!emptyList)
                      {
                        'subagent_id': 'child-1',
                        'goal': 'Inspect the release',
                        'status': 'running',
                        'model': 'test-model',
                        'last_tool': 'read_file',
                        'accepting_steer': true,
                        'started_at': startedAt,
                        'tool_count': 3,
                      },
                  ],
              'delegations': const [],
            };
          case 'subagent.tail':
            tailCalls += 1;
            await tailGate?.future;
            if (tailCalls <= tailFailures) {
              throw StateError('tail unavailable');
            }
            return {
              'subagent_id': 'child-1',
              'available': tailAvailable,
              'text': tailAvailable ? 'latest child output' : '',
              'truncated': false,
              'snapshot_required': false,
            };
          case 'subagent.steer':
            if (failSteer) throw StateError('Steering transport failed');
            if (steerGate case final gate?) await gate.future;
            return {
              'status': acceptSteer ? 'queued' : 'rejected',
              'subagent_id': 'child-1',
            };
          case 'subagent.interrupt':
            if (failInterrupt) throw StateError('Interrupt transport failed');
            return {'found': findInterrupt, 'subagent_id': 'child-1'};
          default:
            return base.call(method, params);
        }
      },
    );
  }
}

void main() {
  const review = bool.fromEnvironment('CAPTURE_SUBAGENT_FIXES');
  const frame = ValueKey('subagent-fixes-render');
  setUpAll(() async {
    if (!review) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'monospace': 'build/studio-mono.ttf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(entry.value).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  Future<void> capture(WidgetTester tester, String name) async {
    if (!review) return;
    await tester.settleMarkdown();
    await tester.runAsync(() async {
      final image = await tester
          .renderObject<RenderRepaintBoundary>(find.byKey(frame))
          .toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final folder = Directory('build/design-previews/subagent-fixes/site')
        ..createSync(recursive: true);
      await File(
        '${folder.path}/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> until(
    WidgetTester tester,
    bool Function() ready,
    String outcome,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    do {
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull, reason: outcome);
      if (ready()) return;
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    } while (DateTime.now().isBefore(deadline));
    fail('Timed out waiting for $outcome');
  }

  late _SubagentFixture fixture;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;
  late ProfileSupervisionSession supervision;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fixture = _SubagentFixture();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'subagent-panel',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
    emitChatEvent(controller, chat, 'message.start', {});
    supervision = ProfileSupervisionSession(controller: controller, chat: chat);
  });

  tearDown(() {
    supervision.dispose();
    controller.dispose();
    appPreferences.dispose();
  });

  Future<void> showPanel(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double scale = 1.8,
    bool motion = false,
    Size size = const Size(320, 640),
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: frame,
        child: MaterialApp(
          theme: wingTheme(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: !motion,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: ListView(
              children: [
                ProfileSubagentPanel(
                  session: supervision,
                  initiallyExpanded: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    if (!motion) await tester.pumpAndSettle();
  }

  Future<void> openDetails(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double scale = 1.8,
    Size size = const Size(320, 640),
  }) async {
    await showPanel(tester, brightness: brightness, scale: scale, size: size);
    await tester.ensureVisible(find.text('Inspect the release'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inspect the release'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets(
    'normal chat opens child timeline without selecting or controlling it',
    (tester) async {
      await showPanel(tester, scale: 1);
      final selected = controller.current!.chat;
      emitChatEvent(controller, chat, 'subagent.start', {
        'subagent_id': 'child-1',
        'child_session_id': 'child-session',
        'goal': 'Inspect the release',
      });
      await tester.pump();
      await tester.tap(find.text('Inspect the release'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(find.byType(SubagentTimeline), findsOneWidget);
      final child = tester
          .widget<SubagentTimeline>(find.byType(SubagentTimeline))
          .session;
      expect(child.messages.single['content'], 'Child saved evidence');
      expect(child.historyError, isNull);
      expect(child.liveError, isNull);
      expect(controller.current!.chat, same(selected));
      await tester.tap(find.text('Task').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final steerField = find.byType(TextField);
      await tester.ensureVisible(steerField);
      await tester.showKeyboard(steerField);
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(steerField);
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Steer'), findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding();
      tester.testTextInput.hide();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(fixture.tailCalls, 0);
      expect(
        fixture.requests.where(
          (call) => call.$1 == 'prompt.submit' || call.$1 == 'session.close',
        ),
        isEmpty,
      );
      await tester.tap(find.byTooltip('Close subagent activity'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(SubagentTimeline), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('child completion retains one Activity for saved and live tools', (
    tester,
  ) async {
    fixture.childMessages = [
      {'id': 1, 'role': 'user', 'content': 'Inspect the release'},
      {
        'id': 2,
        'role': 'assistant',
        'content': '',
        'reasoning': '**Check saved evidence**',
        'tool_calls': [
          for (var i = 0; i < 11; i++)
            {
              'id': 'call-$i',
              'function': {'name': 'read_file', 'arguments': '{}'},
            },
        ],
      },
      for (var i = 0; i < 11; i++)
        {
          'id': i + 3,
          'role': 'tool',
          'tool_call_id': 'call-$i',
          'content': 'Evidence $i',
        },
    ];
    fixture.childEvents.addAll([
      {'session_id': 'child-session', 'seq': 1, 'type': 'message.start'},
      {
        'session_id': 'child-session',
        'seq': 2,
        'type': 'tool.start',
        'payload': {
          'tool_id': 'submirror:child-session:1',
          'name': 'read_file',
          'preview': 'current.txt',
        },
      },
    ]);
    await showPanel(tester, scale: 1);
    emitChatEvent(controller, chat, 'subagent.start', {
      'subagent_id': 'child-1',
      'child_session_id': 'child-session',
      'goal': 'Inspect the release',
    });
    await tester.pump();
    await tester.tap(find.text('Inspect the release'));
    await until(
      tester,
      () => find.text('12 tools').evaluate().isNotEmpty,
      'the child timeline with saved and live tools',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('live-activity-toggle')),
        matching: find.text('12 tools'),
      ),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data)
          .whereType<String>()
          .join(' | '),
    );
    expect(find.byType(ProfileLiveExecution), findsOneWidget);
    await tester.openLiveActivity();
    expect(find.byType(ProfileActivitySection), findsOneWidget);
    fixture.childEvents.add({
      'session_id': 'child-session',
      'seq': 3,
      'type': 'message.complete',
      'payload': {'text': 'Final reply awaiting persistence'},
    });
    await tester.tap(find.byTooltip('Refresh subagent activity'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('live-activity-toggle')),
        matching: find.text('12 tools'),
      ),
      findsOneWidget,
      reason:
          'Saved work and the retained final replay must stay in one reply Activity',
    );
    expect(find.byType(ProfileLiveExecution), findsOneWidget);
    await tester.openLiveActivity();
    expect(find.byType(ProfileActivitySection), findsOneWidget);
    await tester.tap(find.byTooltip('Close subagent activity'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('child timeline keeps its visible Running pulse', (tester) async {
    await showPanel(tester, scale: 1, motion: true);
    emitChatEvent(controller, chat, 'subagent.start', {
      'subagent_id': 'child-1',
      'child_session_id': 'child-session',
      'goal': 'Inspect the release',
    });
    await tester.pump();
    await tester.tap(find.text('Inspect the release'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(SubagentTimeline), findsOneWidget);
    final sheet = find.ancestor(
      of: find.byType(SubagentTimeline),
      matching: find.byType(StudioLoadingFrame),
    );
    expect(sheet, findsOneWidget);
    final pulse = find.descendant(
      of: sheet,
      matching: find.byWidgetPredicate(
        (widget) => widget is StudioLoading && widget.label == 'Running',
      ),
    );
    void expectVisibleWork() {
      expect(pulse, findsOneWidget);
      final bounds = tester.getRect(pulse);
      final viewport =
          Offset.zero &
          (tester.view.physicalSize / tester.view.devicePixelRatio);
      expect(bounds.isEmpty, isFalse);
      expect(viewport.intersect(bounds), bounds);
      final paint = find.descendant(
        of: pulse,
        matching: find.byType(CustomPaint),
      );
      expect(paint, findsOneWidget);
      expect(tester.getSize(paint).isEmpty, isFalse);
    }

    final taskHeader = find.descendant(
      of: sheet,
      matching: find.ancestor(
        of: find.text('Task'),
        matching: find.byType(ListTile),
      ),
    );
    expect(taskHeader, findsOneWidget);
    expectVisibleWork();
    await tester.tap(taskHeader);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expectVisibleWork();
    await tester.tap(taskHeader);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expectVisibleWork();
    await tester.tap(find.byTooltip('Close subagent activity'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'timeline steering stays visible and reports pending/rejection ${brightness.name} $scale',
        (tester) async {
          fixture.childMessages = [
            {'id': 1, 'role': 'user', 'content': 'Check source evidence'},
            {
              'id': 2,
              'role': 'assistant',
              'content': '',
              'reasoning':
                  '**Fixing database issues**\n\nCheck the retained parent and child rows before changing the query.',
              'tool_calls': [
                {
                  'id': 'saved',
                  'function': {
                    'name': 'read_file',
                    'arguments': '{"path":"evidence.py"}',
                  },
                },
              ],
            },
            {
              'id': 3,
              'role': 'tool',
              'tool_call_id': 'saved',
              'content': 'Saved source evidence',
            },
          ];
          await showPanel(
            tester,
            brightness: brightness,
            scale: scale,
            size: scale == 1 ? const Size(390, 844) : const Size(320, 640),
          );
          emitChatEvent(controller, chat, 'subagent.start', {
            'subagent_id': 'child-1',
            'child_session_id': 'child-session',
            'goal': 'Inspect the release',
          });
          await tester.pump();
          await tester.tap(find.text('Inspect the release'));
          final field = find.byType(TextField);
          final steer = find.byTooltip('Steer');
          await until(
            tester,
            () =>
                field.hitTestable().evaluate().isNotEmpty &&
                steer.hitTestable().evaluate().isNotEmpty,
            'the child steering editor and action',
          );
          expect(field.hitTestable(), findsOneWidget);
          expect(steer.hitTestable(), findsOneWidget);
          expect(find.byTooltip('Interrupt'), findsOneWidget);
          await tester.openLiveActivity(tools: false);
          final reasoning = find.text('Fixing database issues');
          await tester.ensureVisible(reasoning);
          await tester.pump(const Duration(milliseconds: 300));
          expect(reasoning, findsOneWidget);
          expect(
            find.ancestor(of: reasoning, matching: find.byType(ExpansionTile)),
            findsNothing,
          );
          expect(
            find.byWidgetPredicate(
              (w) =>
                  w is MarkdownMessageContent &&
                  w.data.startsWith('**Fixing database issues**'),
            ),
            findsNothing,
          );
          expect(
            tester
                .getRect(reasoning)
                .overlaps(tester.getRect(find.byType(SubagentTimeline))),
            isTrue,
            reason:
                'Reasoning ${tester.getRect(reasoning)}; viewport ${tester.getRect(find.byType(SubagentTimeline))}',
          );
          await capture(tester, 'reasoning-${brightness.name}-$scale');
          await tester.enterText(field, 'Check the retained child rows');
          tester.view.viewInsets = const FakeViewPadding(bottom: 260);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(steer.hitTestable(), findsOneWidget);
          final gate = Completer<void>();
          fixture.steerGate = gate;
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          await tester.tap(steer);
          await tester.pump();
          expect(
            find.descendant(
              of: steer,
              matching: find.byType(CircularProgressIndicator),
            ),
            findsOneWidget,
          );
          expect(tester.widget<TextField>(field).enabled, isFalse);
          final dispatches = fixture.requests
              .where((c) => c.$1 == 'subagent.steer')
              .length;
          await tester.tap(steer);
          await tester.pump();
          expect(
            fixture.requests.where((c) => c.$1 == 'subagent.steer'),
            hasLength(dispatches),
          );
          final request = fixture.requests.lastWhere(
            (c) => c.$1 == 'subagent.steer',
          );
          expect(request.$2['session_id'], chat.runtime.runtimeId);
          expect(request.$2['subagent_id'], 'child-1');
          expect(request.$2['text'], 'Check the retained child rows');
          await capture(tester, 'steering-pending-${brightness.name}-$scale');
          gate.complete();
          await until(
            tester,
            () => find.text('Steer rejected').evaluate().isNotEmpty,
            'the rejected steering result',
          );
          expect(
            find.descendant(
              of: find.byType(StudioError),
              matching: find.text('Steer rejected'),
            ),
            findsOneWidget,
          );
          expect(
            tester.widget<TextField>(field).controller!.text,
            'Check the retained child rows',
          );
          expect(steer.hitTestable(), findsOneWidget);
          final rejected = find.text('Steer rejected');
          final feedbackViewport = find
              .ancestor(
                of: rejected,
                matching: find.byType(SingleChildScrollView),
              )
              .last;
          final viewportRect = tester.getRect(feedbackViewport);
          final messageRect = tester.getRect(rejected);
          if (messageRect.bottom > viewportRect.bottom) {
            // Larger fallback glyphs may wrap beyond the bounded viewport.
            await tester.drag(feedbackViewport, const Offset(0, -120));
            await tester.pumpAndSettle();
            expect(
              tester.getRect(rejected).bottom,
              lessThanOrEqualTo(viewportRect.bottom),
            );
          } else {
            expect(viewportRect.intersect(messageRect), messageRect);
          }
          await capture(tester, 'steering-rejected-${brightness.name}-$scale');
          fixture.steerGate = null;
          fixture.failSteer = true;
          await tester.tap(steer);
          await until(
            tester,
            () => find.text('Steering failed').evaluate().isNotEmpty,
            'the failed steering result',
          );
          expect(find.text('Steering failed'), findsOneWidget);
          expect(
            tester.widget<TextField>(field).controller!.text,
            'Check the retained child rows',
          );
          fixture.failSteer = false;
          fixture.acceptSteer = true;
          await tester.tap(steer);
          await until(
            tester,
            () =>
                find.text('Steering queued.').evaluate().isNotEmpty &&
                tester.widget<TextField>(field).controller!.text.isEmpty,
            'accepted steering to clear the submitted draft',
          );
          expect(tester.widget<TextField>(field).controller!.text, isEmpty);
          expect(find.text('Steering queued.'), findsOneWidget);
          await capture(tester, 'steering-queued-${brightness.name}-$scale');
          // A newer draft must survive acceptance of the captured submission.
          await tester.enterText(field, 'Original guidance');
          final acceptedGate = Completer<void>();
          fixture.steerGate = acceptedGate;
          addTearDown(() {
            if (!acceptedGate.isCompleted) acceptedGate.complete();
          });
          await tester.tap(steer);
          await tester.pump();
          tester.widget<TextField>(field).controller!.text = 'Newer guidance';
          acceptedGate.complete();
          await until(
            tester,
            () => tester.widget<TextField>(field).enabled != false,
            'the held steering submission to finish',
          );
          expect(
            tester.widget<TextField>(field).controller!.text,
            'Newer guidance',
          );

          tester.view.viewInsets = const FakeViewPadding();
          tester.testTextInput.hide();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          fixture.failInterrupt = true;
          await tester.tap(find.byTooltip('Interrupt'));
          final interruptError = find.descendant(
            of: find.byType(StudioError),
            matching: find.text('Interrupt failed'),
          );
          await until(
            tester,
            () => interruptError.evaluate().isNotEmpty,
            'the failed interrupt result',
          );
          expect(find.byTooltip('Interrupt').hitTestable(), findsOneWidget);
          await capture(tester, 'interrupt-error-${brightness.name}-$scale');
          expect(tester.takeException(), isNull);
          await tester.tap(find.byTooltip('Close subagent activity'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'agent timing is backend-derived and stops on completion or uncertainty',
    (tester) async {
      fixture.startedAt = DateTime.now().millisecondsSinceEpoch / 1000 - 40;
      await showPanel(tester);
      expect(find.text('Reading file'), findsOneWidget);
      expect(find.text('test-model · 3 tool calls'), findsOneWidget);
      var time = tester.widget<ActivityTime>(find.byType(ActivityTime));
      expect(time.backendStartedAt, fixture.startedAt);
      emitChatEvent(controller, chat, 'subagent.complete', {
        'subagent_id': 'child-1',
        'status': 'completed',
        'summary': 'Inspection finished',
        'duration_seconds': 42.5,
      });
      await tester.pump();
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Inspection finished'), findsOneWidget);
      time = tester.widget<ActivityTime>(find.byType(ActivityTime));
      expect(time.backendStartedAt, isNull);
      expect(time.durationSeconds, 42.5);
      expect(find.text('43 s'), findsOneWidget);
      emitChatEvent(controller, chat, 'subagent.start', {
        'subagent_id': 'uncertain',
        'goal': 'Check another source',
        'started_at': fixture.startedAt,
      });
      fixture.emptyList = true;
      await supervision.refreshSubagents();
      await tester.pump();
      expect(find.text('Last seen running'), findsOneWidget);
      expect(
        tester
            .widgetList<ActivityTime>(find.byType(ActivityTime))
            .every((w) => w.backendStartedAt == null),
        isTrue,
      );
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'agent states and metadata remain readable ${brightness.name} $scale',
        (tester) async {
          const longGoal =
              'Inspect the release candidate and verify the Android transport settings. Keep every original instruction in the task body.';
          const heading =
              'Inspect the release candidate and verify the Android transport settings';
          fixture.rows = [
            {
              'subagent_id': 'child-1',
              'goal': longGoal,
              'status': 'running',
              'last_tool': 'read_file',
              'model': 'test-model',
              'accepting_steer': true,
            },
            {
              'subagent_id': 'queued',
              'goal': 'Compare suppliers',
              'status': 'queued',
              'started_at': 1000,
            },
          ];
          for (final status in ['completed', 'failed', 'interrupted']) {
            emitChatEvent(controller, chat, 'subagent.complete', {
              'subagent_id': status,
              'goal': 'Research $status',
              'status': status,
              'summary': 'Result for $status',
              'duration_seconds': 1.25,
            });
          }
          await showPanel(tester, brightness: brightness, scale: scale);
          final title = tester.widget<Text>(find.text(heading));
          expect(title.maxLines, 2);
          expect(title.overflow, TextOverflow.ellipsis);
          expect(find.text(longGoal), findsNothing);
          for (final label in [
            'Running',
            'Queued',
            'Completed',
            'Failed',
            'Interrupted',
          ]) {
            expect(find.text(label), findsOneWidget);
          }
          final queuedRow = find.byKey(
            ValueKey(('subagent', chat.key, 'queued')),
          );
          final queuedTime = tester.widget<ActivityTime>(
            find.descendant(of: queuedRow, matching: find.byType(ActivityTime)),
          );
          expect(queuedTime.backendStartedAt, isNull);
          expect(queuedTime.durationSeconds, isNull);
          await tester.ensureVisible(find.text(heading));
          await tester.pumpAndSettle();
          await tester.tap(find.text(heading));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.text(longGoal), findsOneWidget);
          expect(find.byTooltip('Copy Task'), findsOneWidget);
          Navigator.of(tester.element(find.text(longGoal))).pop();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'a terminal tool name is activity context, not a reported result',
    (tester) async {
      fixture.rows = [
        {
          'subagent_id': 'child-1',
          'goal': 'Inspect the release',
          'status': 'completed',
          'last_tool': 'read_file',
        },
      ];
      await openDetails(tester);
      await tester.pumpAndSettle();
      expect(find.text('Reported result'), findsNothing);
      expect(find.textContaining('Last activity:'), findsOneWidget);
      expect(find.byTooltip('Copy Current activity'), findsNothing);
      expect(find.byTooltip('Steer'), findsNothing);
      expect(find.byTooltip('Interrupt'), findsNothing);
      Navigator.of(tester.element(find.text('Task'))).pop();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('backend metadata remains passive beside existing controls', (
    tester,
  ) async {
    await openDetails(tester);
    await tester.ensureVisible(find.byTooltip('Expand Raw details'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Expand Raw details'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Copy Raw details'), findsNothing);
    expect(find.byTooltip('Open Raw details'), findsNothing);
    expect(find.byTooltip('Wrap Raw details'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SourceCodeText &&
            widget.text.contains('Agent ID: child-1'),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Copy Task'), findsOneWidget);
    expect(find.byTooltip('Copy Live output'), findsOneWidget);
    Navigator.of(tester.element(find.text('Raw details'))).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('refresh retains two live event children beside a failed child', (
    tester,
  ) async {
    fixture.emptyList = true;
    emitChatEvent(controller, chat, 'subagent.complete', {
      'subagent_id': 'failed',
      'goal': 'Timed out research',
      'status': 'timeout',
    });
    emitChatEvent(controller, chat, 'subagent.start', {
      'subagent_id': 'one',
      'goal': 'Research one',
    });
    emitChatEvent(controller, chat, 'subagent.start', {
      'subagent_id': 'two',
      'goal': 'Research two',
    });
    await showPanel(tester);
    expect(chat.subagents.map((item) => item.id), ['failed', 'one', 'two']);
    expect(find.text('Research one'), findsOneWidget);
    expect(find.text('Research two'), findsOneWidget);
    expect(find.text('1 finished'), findsNothing);
  });

  testWidgets(
    'detail shows received activity when the server has no transcript',
    (tester) async {
      fixture.tailAvailable = false;
      emitChatEvent(controller, chat, 'subagent.start', {
        'subagent_id': 'child-1',
        'goal': 'Inspect the release',
      });
      emitChatEvent(controller, chat, 'subagent.tool', {
        'subagent_id': 'child-1',
        'tool_name': 'read_file',
        'tool_preview': 'Checking android/app/build.gradle.kts',
      });
      await openDetails(tester);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Recent activity'),
        160,
        scrollable: find
            .descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Recent activity'), findsOneWidget);
      expect(find.byTooltip('Copy Live output'), findsNothing);
      expect(find.byTooltip('Open Live output'), findsNothing);
      expect(find.byTooltip('Copy Current activity'), findsNothing);
      expect(find.byTooltip('Refresh live output'), findsOneWidget);
      expect(find.byTooltip('Copy Recent activity'), findsNothing);
      expect(
        find.textContaining('Checking android/app/build.gradle.kts').last,
        findsOneWidget,
      );
      Navigator.of(tester.element(find.text('Live output'))).pop();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'an unavailable tail refresh preserves the output already received',
    (tester) async {
      await openDetails(tester);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byWidgetPredicate(
          (widget) =>
              widget is SourceCodeText && widget.text == 'latest child output',
        ),
        160,
        scrollable: find
            .descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SourceCodeText && widget.text == 'latest child output',
        ),
        findsOneWidget,
      );
      fixture.tailAvailable = false;
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SourceCodeText && widget.text == 'latest child output',
        ),
        findsOneWidget,
      );
      fixture.tailFailures = fixture.tailCalls + 1;
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('Could not refresh live output.'), findsNothing);
      expect(find.text('Showing the last received output.'), findsOneWidget);

      final refresh = find.byTooltip('Refresh live output');
      await tester.ensureVisible(refresh);
      await tester.pumpAndSettle();
      final gate = Completer<void>();
      fixture.tailGate = gate;
      fixture.tailFailures = fixture.tailCalls + 1;
      await tester.tap(refresh);
      await tester.pump();
      expect(
        find.descendant(
          of: refresh,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(StudioError),
          matching: find.text('Could not refresh live output.'),
        ),
        findsOneWidget,
      );
      expect(find.text('Showing the last received output.'), findsOneWidget);
      Navigator.of(tester.element(find.text('Live output'))).pop();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('shows live tail and keeps rejected steering text', (
    tester,
  ) async {
    await openDetails(tester);

    expect(fixture.tailCalls, 1);
    await tester.scrollUntilVisible(
      find.byWidgetPredicate(
        (widget) =>
            widget is SourceCodeText && widget.text == 'latest child output',
      ),
      160,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SourceCodeText && widget.text == 'latest child output',
      ),
      findsOneWidget,
    );
    expect(find.byType(SourceCodeText), findsWidgets);
    expect(find.byTooltip('Steer'), findsOneWidget);
    expect(find.byTooltip('Interrupt'), findsOneWidget);

    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byType(TextField),
      -160,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.enterText(find.byType(TextField), 'Check the Android path');
    final steerButton = find.byTooltip('Steer');
    await tester.ensureVisible(steerButton);
    await tester.pumpAndSettle();
    await tester.tap(steerButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Steer rejected'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byType(TextField),
      -160,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Check the Android path',
    );
    expect(chat.subagents.single.status.name, 'running');
    final steer = fixture.requests.lastWhere(
      (call) => call.$1 == 'subagent.steer',
    );
    expect(steer.$2['session_id'], chat.runtime.runtimeId);
    expect(steer.$2['subagent_id'], 'child-1');
    expect(steer.$2['text'], 'Check the Android path');

    Navigator.of(tester.element(find.byType(TextField))).pop();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'populated event roster refreshes authoritative steering capability',
    (tester) async {
      emitChatEvent(controller, chat, 'subagent.start', {
        'subagent_id': 'child-1',
        'goal': 'Inspect the release',
        'status': 'running',
        'model': 'test-model',
      });
      expect(chat.subagents.single.acceptingSteer, isFalse);

      await showPanel(tester);

      expect(fixture.listCalls, 1);
      expect(chat.subagents.single.acceptingSteer, isTrue);
      await tester.ensureVisible(find.text('Inspect the release'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inspect the release'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byTooltip('Steer'), findsOneWidget);

      Navigator.of(tester.element(find.byTooltip('Steer'))).pop();
      await tester.pumpAndSettle();
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'tail polling stops after three failures and Retry restarts it ${brightness.name} $scale',
        (tester) async {
          fixture.tailFailures = 3;
          await openDetails(
            tester,
            brightness: brightness,
            scale: scale,
            size: scale == 1 ? const Size(390, 844) : const Size(320, 640),
          );
          await tester.pump(const Duration(seconds: 2));
          await tester.pump(const Duration(seconds: 2));

          expect(fixture.tailCalls, 3);
          await tester.scrollUntilVisible(
            find.text('Could not refresh live output.'),
            160,
            scrollable: find
                .descendant(
                  of: find.byType(ListView).last,
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(
            find.descendant(
              of: find.byType(StudioError),
              matching: find.text('Could not refresh live output.'),
            ),
            findsOneWidget,
          );
          await tester.ensureVisible(find.byType(StudioError));
          await tester.pump();
          await capture(tester, 'tail-error-${brightness.name}-$scale');
          expect(find.byTooltip('Retry'), findsOneWidget);
          await tester.pump(const Duration(seconds: 4));
          expect(fixture.tailCalls, 3);

          await tester.ensureVisible(find.byTooltip('Retry'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Retry'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          await tester.scrollUntilVisible(
            find.byWidgetPredicate(
              (widget) =>
                  widget is SourceCodeText &&
                  widget.text == 'latest child output',
            ),
            160,
            scrollable: find
                .descendant(
                  of: find.byType(ListView).last,
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget is SourceCodeText &&
                  widget.text == 'latest child output',
            ),
            findsOneWidget,
          );

          Navigator.of(tester.element(find.text('Live output'))).pop();
          await tester.pumpAndSettle();
        },
      );
    }
  }

  for (final status in ['running', 'completed']) {
    testWidgets(
      'settled conversation ${status == 'completed' ? 'retires completed' : 'keeps running'} subagents in the bottom dock',
      (tester) async {
        fixture.rows = [
          {
            'subagent_id': 'child-1',
            'goal': 'Inspect the release',
            'status': status,
          },
        ];
        await controller.refreshSubagents(chat);
        chat.reading.installSavedHistory([
          {'id': 1, 'role': 'user', 'content': 'Inspect the release'},
          {
            'id': 2,
            'role': 'assistant',
            'content': 'The inspection is finished.',
          },
        ]);
        emitChatEvent(controller, chat, 'message.complete', {});
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: ProfileWorkspaceScreen(
              createBotsSession: () => BotsSession((_) async => const []),
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(chat.runtime.executionActive, isFalse);
        expect(chat.reading.streamingMessage, isNull);
        if (status == 'completed') {
          expect(find.byType(ProfileLiveWorkDock), findsNothing);
          expect(find.byType(ProfileSubagentPanel), findsNothing);
          expect(tester.takeException(), isNull);
          return;
        }
        expect(find.byType(ProfileLiveWorkDock), findsOneWidget);
        expect(find.byType(ProfileLiveExecution), findsNothing);
        expect(find.text('Activity'), findsNothing);
        expect(find.byType(ProfileSubagentPanel), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey(('live-work-tab', 0, false))),
        );
        await tester.pump();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey(('activity-tab', 'agents'))),
          findsNothing,
        );
        expect(find.byType(ProfileSubagentPanel), findsOneWidget);
        expect(find.text('Running'), findsOneWidget);
        final agent = find.byKey(ValueKey(('subagent', chat.key, 'child-1')));
        await tester.ensureVisible(agent);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: agent,
            matching: find.byIcon(Icons.chevron_right),
          ),
        );
        await tester.pumpAndSettle();
        await tester.settleMarkdown();
        expect(find.text('Task'), findsOneWidget);
        expect(find.byTooltip('Copy Task'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        emitChatEvent(controller, chat, 'message.start', {});
        emitChatEvent(controller, chat, 'message.delta', {
          'text': 'The next answer is streaming.',
        });
        await tester.pump();
        await tester.settleMarkdown();
        await tester.pump(const Duration(milliseconds: 300));
        expect(chat.runtime.executionActive, isTrue);
        expect(find.byType(ProfileLiveWorkDock), findsOneWidget);
        expect(find.byType(ProfileSubagentPanel), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('live work Subagents opens this chat subagent roster', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    emitChatEvent(controller, chat, 'message.start', {});
    emitChatEvent(controller, chat, 'subagent.start', {
      'subagent_id': 'child-1',
      'goal': 'Inspect the release',
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          createBotsSession: () => BotsSession((_) async => const []),
          controller: controller,
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Inspect the release'), findsNothing);

    await tester.tap(find.byKey(const ValueKey(('live-work-tab', 0, false))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.ensureVisible(find.text('Inspect the release').last);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Inspect the release'), findsOneWidget);
    expect(fixture.listCalls, 1);
  });
}

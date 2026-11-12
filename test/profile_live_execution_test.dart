import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/models/transcript_message.dart';
import 'package:wing/core/widgets/compact_activity_row.dart';
import 'package:wing/core/widgets/source_code_text.dart';
import 'support/process_batch_fixture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/models/gateway_activity.dart';
import 'package:wing/core/models/transcript_timeline.dart';
import 'package:wing/core/services/chat_runtime.dart' as execution;
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/profile_execution_activity.dart';
import 'package:wing/core/widgets/profile_activity_tabs.dart';
import 'package:wing/core/widgets/profile_live_execution.dart';
import 'package:wing/core/widgets/activity_time.dart';
import 'package:wing/core/widgets/anchored_expansion_tile.dart';
import 'package:wing/core/widgets/profile_tool_call.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/widgets/tool_activity_details.dart';

import 'helpers/pump_markdown_widget.dart';

void main() {
  Finder runLabel(String label) => find.descendant(
    of: find.byType(ProfileActivitySection),
    matching: find.text(label),
  );

  testWidgets('live Activity retains a saved process completion output', (
    tester,
  ) async {
    final saved = TranscriptTimeline.project([
      {
        'id': 1,
        'role': 'user',
        'display_kind': 'process_complete',
        'content':
            '[IMPORTANT: Background process proc_test completed normally '
            '(exit code 0).\nCommand: check\nOutput:\nProcess result\n]',
        'display_metadata': {'display_text': 'Background check finished'},
      },
    ], presentationId: (row) => row['id'] as int).sections.single;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileLiveExecution(
            entries: const [],
            savedActivity: saved,
            running: false,
          ),
        ),
      ),
    );
    expect(find.text('Background check finished'), findsNothing);
    await tester.tap(find.text('Activity').first);
    await tester.pumpAndSettle();
    // The outer live disclosure contains the existing execution-run disclosure.
    await tester.tap(find.text('Activity').last);
    await tester.pumpAndSettle();
    expect(find.text('Background check finished'), findsOneWidget);
    await tester.tap(find.text('Process update'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SourceCodeText &&
            widget.text == 'Command: check\nOutput:\nProcess result',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final sample in <String, Map<String, dynamic>>{
    'completed': {
      'content':
          '[IMPORTANT: Background process proc_a completed normally (exit code 0).\nCommand: check\nOutput:\ndone\n]',
    },
    'failed': {
      'content':
          '[IMPORTANT: Background process proc_a exited (exit code 1).\nCommand: check\nOutput:\nfailed\n]',
    },
    'watch match': {
      'content':
          '[IMPORTANT: Background process proc_a matched watch pattern "DevTools listening".\nCommand: check\nOutput:\nlistening\n]',
    },
    'batch': {'content': processBatchEnvelope},
    'missing body': {'content': '', 'display_kind': 'process_complete'},
  }.entries) {
    testWidgets('process row keeps ${sample.key} details and focus', (
      tester,
    ) async {
      final row = {'id': 8, 'role': 'user', ...sample.value};
      final message = TranscriptMessage.fromRow(row);
      final timeline = TranscriptTimeline.project([
        row,
      ], presentationId: (_) => 8);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProfileActivityTimeline(
                groups: timeline.sections.single.groups,
                expandedMessageId: 8,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CompactActivityRow), findsOneWidget);
      expect(find.byType(ActivityDetailsCard), findsOneWidget);
      expect(find.text('Process update'), findsOneWidget);
      expect(find.text('Update'), findsOneWidget);
      expect(find.byTooltip('Copy Update'), findsOneWidget);
      expect(find.text(message.text), findsWidgets);
      expect(find.byTooltip('Stop process'), findsNothing);
      final output = message.noticeResult;
      if (output == null) {
        expect(find.text('Output'), findsNothing);
      } else {
        expect(
          find.byWidgetPredicate(
            (widget) => widget is SourceCodeText && widget.text == output,
          ),
          findsOneWidget,
        );
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.ensureVisible(find.byTooltip('Copy Output'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Copy Output'));
        await tester.pumpAndSettle();
        expect(copied, output);
        if (sample.key == 'batch') {
          final open = find.byTooltip('Open Output');
          expect(open, findsOneWidget);
          await tester.ensureVisible(open);
          await tester.pumpAndSettle();
          await tester.tap(open);
          await tester.pumpAndSettle();
          expect(
            find.byWidgetPredicate(
              (widget) => widget is SourceCodeText && widget.text == output,
            ),
            findsOneWidget,
          );
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(find.text('Process update'), findsOneWidget);
        }
      }
      expect(tester.takeException(), isNull);
    });
  }

  test('reasoning keeps its first posting time through deltas and sealing', () {
    final runtime = execution.ChatRuntime(runtimeId: 'timed-reasoning');
    runtime.beginTurn(submitting: false);
    final first = DateTime.fromMillisecondsSinceEpoch(1000000);
    runtime.observeReasoning('reasoning.delta', {
      'text': 'First',
    }, receivedAt: first);
    runtime.observeReasoning('reasoning.delta', {
      'text': ' chunk',
    }, receivedAt: first.add(const Duration(seconds: 8)));
    runtime.observeReasoning('reasoning.available', {
      'text': 'Summary',
    }, receivedAt: first.add(const Duration(seconds: 9)));
    expect(
      (runtime.observation.activityEntries.single as ChatReasoningEntry)
          .postedAt,
      first,
    );
    runtime.observeTool('tool.start', {'tool_id': 'next', 'name': 'terminal'});
    final next = first.add(const Duration(seconds: 20));
    runtime.observeReasoning('reasoning.delta', {
      'text': 'Next',
    }, receivedAt: next);
    runtime.finishSegment();
    final entries = runtime.observation.activityEntries
        .whereType<ChatReasoningEntry>();
    expect(entries.map((entry) => entry.postedAt), [first, next]);
    expect(entries.every((entry) => !entry.running), isTrue);
  });

  testWidgets(
    'interval counter ticks alone, freezes and resumes from wall time',
    (tester) async {
      final start = DateTime(2026, 10, 20, 12);
      var now = start.add(const Duration(seconds: 3));
      var parentBuilds = 0;
      Future<void> show({DateTime? end, bool enabled = true}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TickerMode(
                enabled: enabled,
                child: Builder(
                  builder: (_) {
                    parentBuilds++;
                    return ActivityTime.interval(
                      start: start,
                      end: end,
                      wallClock: () => now,
                    );
                  },
                ),
              ),
            ),
          ),
        );
      }

      await show();
      final builds = parentBuilds;
      expect(find.text('· 3.0 s'), findsOneWidget);
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('· 5.0 s'), findsOneWidget);
      expect(parentBuilds, builds);
      await show(enabled: false);
      now = now.add(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 30));
      expect(find.text('· 5.0 s'), findsOneWidget);
      await show();
      expect(find.text('· 35 s'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = now.add(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 10));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('· 45 s'), findsOneWidget);
      await show(end: start.add(const Duration(seconds: 7)));
      now = now.add(const Duration(minutes: 1));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('· 7.0 s'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets(
    'history commentary does not replay reasoning or move open Activity',
    (tester) async {
      final runtime = execution.ChatRuntime(runtimeId: 'history-commentary');
      runtime.beginTurn(submitting: false);
      for (var i = 0; i < 5; i++) {
        runtime.observeTool('tool.complete', {
          'tool_id': 'earlier-$i',
          'name': 'read_file',
          'result': 'Earlier result $i',
        });
      }
      runtime.observeReasoning('reasoning.delta', {
        'text': 'Checking updates.',
      });
      runtime.observeTool('tool.start', {
        'tool_id': 'current',
        'name': 'terminal',
      });
      const commentary = 'I will compare current upstream.';
      final saved = <Map<String, dynamic>>[
        {'id': 1, 'role': 'user', 'content': 'Check upstream.'},
        {
          'id': 2,
          'role': 'assistant',
          'content': '',
          'reasoning': 'Checking updates.\n\n$commentary',
          'reasoning_content': 'Checking updates.\n\n$commentary',
          'display_reasoning': 'Checking updates.',
          'display_commentary': [commentary],
          'tool_calls': [
            {
              'id': 'current',
              'function': {'name': 'terminal', 'arguments': '{}'},
            },
          ],
        },
      ];
      Future<ChatTranscriptProjection> show(
        List<Map<String, dynamic>> rows,
      ) async {
        final projection = ChatTranscriptProjection(
          savedRows: rows,
          streamingMessage: null,
          runtime: runtime.observation,
          presentationId: (row) => row['id']!,
          liveAnswering: true,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(Brightness.dark),
            home: Scaffold(
              body: SingleChildScrollView(
                child: ProfileLiveExecution(
                  entries: projection.activity,
                  savedActivity: projection.timeline.adjacentLiveActivity,
                ),
              ),
            ),
          ),
        );
        await tester.settleMarkdown();
        return projection;
      }

      await show([saved.first]);
      await tester.openLiveActivity(tools: false);
      await tester.ensureVisible(runLabel('5 tools'));
      await tester.pumpAndSettle();
      await tester.tap(runLabel('5 tools'));
      await tester.pumpAndSettle();
      final originalRun = tester.element(
        find.byType(ProfileActivitySection).last,
      );
      final originalTool = tester.element(find.byType(ProfileToolCall).first);
      final projection = await show(saved);
      expect(
        find.byType(ProfileReasoningDisclosure),
        findsOneWidget,
        reason: 'History must not replay raw reasoning beside its live copy.',
      );
      expect(
        tester.element(find.byType(ProfileActivitySection).last),
        same(originalRun),
      );
      expect(
        tester.element(find.byType(ProfileToolCall).first),
        same(originalTool),
      );
      expect(
        tester.getTopLeft(runLabel('5 tools')).dy,
        greaterThan(
          tester.getTopLeft(find.byType(ProfileReasoningDisclosure)).dy,
        ),
      );
      expect(find.text('Timeline'), findsNothing);
      expect(runLabel('1 tool'), findsOneWidget);
      expect(projection.rows.map((row) => row['id']), [1]);
      expect(saved[1]['reasoning'], 'Checking updates.\n\n$commentary');
      expect(
        runtime.observation.activityEntries
            .whereType<ChatReasoningEntry>()
            .single
            .text,
        'Checking updates.',
      );
      await tester.tap(runLabel('5 tools'));
      await tester.pumpAndSettle();
      expect(find.text('Timeline'), findsNothing);
      await tester.tap(runLabel('5 tools'));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileToolCall), findsNWidgets(5));
    },
  );
  test('reasoning overlap requires exact call ownership and received text', () {
    final runtime = execution.ChatRuntime(runtimeId: 'reasoning-scope');
    runtime.beginTurn(submitting: false);
    runtime.observeReasoning('reasoning.delta', {'text': 'Streamed plan'});
    runtime.observeReasoning('reasoning.available', {'text': 'Saved summary'});
    runtime.observeTool('tool.start', {
      'tool_id': 'current',
      'name': 'read_file',
    });
    final matched = <String, dynamic>{
      'id': 1,
      'role': 'assistant',
      'content': '',
      'reasoning': 'Saved summary',
      'tool_calls': [
        {
          'id': 'current',
          'function': {'name': 'read_file', 'arguments': '{}'},
        },
      ],
    };
    final distinct = [
      {...matched, 'id': 2, 'reasoning': 'Unobserved saved reasoning'},
      {...matched, 'id': 3, 'content': 'A saved answer'},
      {...matched, 'id': 4, 'tool_calls': <Object>[]},
      {
        ...matched,
        'id': 5,
        'tool_calls': [
          {'id': 'earlier-turn'},
        ],
      },
      {
        ...matched,
        'id': 6,
        'tool_calls': [
          {'id': 'current'},
          {'id': 'unobserved'},
        ],
      },
    ];
    final projection = ChatTranscriptProjection(
      savedRows: [matched, ...distinct],
      streamingMessage: null,
      runtime: runtime.observation,
      presentationId: (row) => row['id']!,
      liveAnswering: true,
    );
    expect(projection.rows.map((row) => row['id']), [2, 3, 4, 5, 6]);
    expect(projection.activity, hasLength(2));
  });
  test('live history refresh does not replay reasoning before its tools', () {
    final runtime = execution.ChatRuntime(runtimeId: 'reasoning-receipts');
    runtime.beginTurn(submitting: false);
    final rows = <Map<String, dynamic>>[
      {'id': 1, 'role': 'user', 'content': 'Check both sources.'},
    ];
    for (var i = 0; i < 2; i++) {
      runtime.observeReasoning('reasoning.available', {'text': 'Plan $i'});
      runtime.observeTool('tool.complete', {
        'tool_id': 'call-$i',
        'name': 'read_file',
        'result': 'Result $i',
      });
      rows.addAll([
        {
          'id': 2 + i * 2,
          'role': 'assistant',
          'content': '',
          'reasoning': 'Plan $i',
          'tool_calls': [
            {
              'id': 'call-$i',
              'function': {'name': 'read_file', 'arguments': '{}'},
            },
          ],
        },
        {
          'id': 3 + i * 2,
          'role': 'tool',
          'tool_call_id': 'call-$i',
          'content': 'Result $i',
        },
      ]);
    }
    ChatTranscriptProjection project(bool live) => ChatTranscriptProjection(
      savedRows: rows,
      streamingMessage: null,
      runtime: runtime.observation,
      presentationId: (row) => row['id']!,
      liveAnswering: live,
    );
    final live = project(true);
    expect(live.rows.map((row) => row['id']), [1]);
    expect(live.activity, hasLength(4));
    expect(
      live.timeline.sections.where((section) => section.isActivity),
      isEmpty,
    );
    expect(rows, hasLength(5));
    final saved = project(false);
    expect(saved.rows, hasLength(5));
    expect(saved.timeline.sections.last.toolCount, 2);
  });
  test('live Activity association respects conversation boundaries', () {
    final work = <Map<String, dynamic>>[
      {'id': 1, 'role': 'user', 'content': 'Find local lunch.'},
      {
        'id': 2,
        'role': 'assistant',
        'content': '',
        'reasoning': 'Earlier reasoning',
      },
    ];
    TranscriptTimeline project(List<Map<String, dynamic>> rows, {int? live}) =>
        TranscriptTimeline.project(
          rows,
          presentationId: (row) => row['id']!,
          liveMessageIndex: live,
        );
    final pending = project(work);
    expect(pending.adjacentLiveActivity, same(pending.sections.last));
    final streaming = project([
      ...work,
      {'id': 3, 'role': 'assistant', 'content': 'Current answer'},
    ], live: 2);
    expect(
      streaming.adjacentLiveActivity,
      same(streaming.sections[streaming.sections.length - 2]),
    );
    expect(
      project([
        ...work,
        {'id': 3, 'role': 'user', 'content': 'A later question'},
        {'id': 4, 'role': 'assistant', 'content': 'A later answer'},
      ], live: 3).adjacentLiveActivity,
      isNull,
    );
    expect(
      project([
        ...work,
        {'id': 3, 'role': 'assistant', 'content': 'A saved answer'},
        {'id': 4, 'role': 'assistant', 'content': 'Another live answer'},
      ], live: 3).adjacentLiveActivity,
      isNull,
    );
    expect(
      project([
        ...work,
        {'id': 3, 'role': 'system', 'content': 'review: Memory updated'},
      ]).adjacentLiveActivity,
      isNull,
    );
    expect(work, hasLength(2));
  });
  ChatToolEntry tool(String id) => ChatToolEntry(
    GatewayToolActivity(
      toolId: id,
      name: 'read_file',
      phase: GatewayToolActivityPhase.completed,
      arguments: '{"path":"$id.md"}',
      result: '## Received $id\n\nExact received text.',
      durationSeconds: .4,
    ),
  );
  test(
    'history reconciliation retains live ordering until the turn retires',
    () {
      final runtime = execution.ChatRuntime(runtimeId: 'live');
      runtime.beginTurn(submitting: false);
      runtime.observeTool('tool.start', {
        'tool_id': 'one',
        'name': 'read_file',
      });
      runtime.observeTool('tool.complete', {
        'tool_id': 'one',
        'name': 'read_file',
        'result': 'Original output',
      });
      runtime.observeReasoning('reasoning.available', {
        'text': 'Original reasoning',
      });
      runtime.reconcileHistoricalActivity();
      expect(runtime.observation.activityEntries, hasLength(2));
      expect(
        (runtime.observation.activityEntries.first as ChatToolEntry)
            .activity
            .result,
        'Original output',
      );
      runtime.observeExecutionSnapshot({'running': false});
      runtime.reconcileHistoricalActivity();
      expect(runtime.observation.activityEntries, isEmpty);
    },
  );
  ChatReasoningEntry reasoning(String id, String text, {DateTime? at}) =>
      ChatReasoningEntry(
        identity: id,
        text: text,
        source: 'reasoning.available',
        postedAt: at,
      );
  Future<void> show(
    WidgetTester tester,
    List<ChatActivityEntry> entries, {
    TranscriptTimelineSection? saved,
    bool running = true,
    DateTime? startedAt,
    DateTime? endedAt,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ProfileLiveExecution(
                entries: entries,
                savedActivity: saved,
                running: running,
                startedAt: startedAt,
                endedAt: endedAt,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    final toggle = find.byKey(const ValueKey('live-activity-toggle'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
  }

  Finder call(String id) => find.byWidgetPredicate(
    (w) => w is ProfileToolCall && w.call.callId == id,
  );

  testWidgets('compact live header is lazy and shows latest heading once', (
    tester,
  ) async {
    await show(tester, [
      reasoning('one', '## First update\n\nEarlier body.'),
      tool('one'),
      reasoning('two', '**Latest update**\n\nFull reasoning body.'),
      tool('two'),
    ]);
    expect(find.text('Latest update'), findsOneWidget);
    expect(find.text('2 tools'), findsOneWidget);
    expect(
      find.byType(ProfileReasoningDisclosure, skipOffstage: false),
      findsNothing,
    );
    expect(find.byType(ProfileToolCall, skipOffstage: false), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('live-activity'))).height,
      lessThan(80),
    );
    await open(tester);
    expect(find.text('Reasoning'), findsOneWidget);
    expect(find.text('Latest update'), findsOneWidget);
    expect(find.text('First update'), findsOneWidget);
    expect(find.byType(ProfileToolCall, skipOffstage: false), findsNothing);
    expect(find.text('Timeline'), findsNothing);
    final rows = tester.widgetList<ProfileActivitySection>(
      find.byType(ProfileActivitySection),
    );
    expect(rows, hasLength(2));
    final headers = runLabel('1 tool');
    expect(
      tester.getTopLeft(headers.first).dy,
      lessThan(tester.getTopLeft(find.text('Latest update')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Latest update')).dy,
      lessThan(tester.getTopLeft(headers.last).dy),
    );
    expect(
      tester.getTopLeft(headers.last).dy,
      lessThan(tester.getTopLeft(find.text('First update')).dy),
    );
    await tester.tap(find.text('Latest update'));
    await tester.pumpAndSettle();
    await tester.settleMarkdown();
    expect(find.text('Full reasoning body.', findRichText: true), findsNothing);
    expect(find.text('Raw details'), findsNothing);
    expect(find.byType(ActivityDetailsCard), findsNothing);
    await open(tester);
    expect(find.text('Latest update'), findsOneWidget);
  });

  testWidgets('title-only reasoning restores full details after streaming', (
    tester,
  ) async {
    final entries = [
      reasoning(
        'one',
        '## Preparing isolated browser launch\n\nExact reasoning body.',
      ),
      tool('one'),
    ];
    await show(tester, entries);
    await open(tester);
    final row = find.byType(ProfileReasoningDisclosure);
    expect(find.text('Reasoning'), findsOneWidget);
    expect(find.text('Preparing isolated browser launch'), findsOneWidget);
    expect(find.text('Activity'), findsNothing);
    expect(find.text('Activity · 1 tool'), findsNothing);
    expect(
      find.descendant(of: row, matching: find.byType(AnchoredExpansionTile)),
      findsNothing,
    );
    expect(find.text('Raw details'), findsNothing);
    await tester.tap(find.text('Preparing isolated browser launch'));
    await tester.pumpAndSettle();
    expect(
      find.text('Exact reasoning body.', findRichText: true),
      findsNothing,
    );

    await show(tester, entries, running: false);
    expect(find.text('Activity'), findsOneWidget);
    await open(tester);
    expect(find.text('Activity · 1 tool'), findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.byType(AnchoredExpansionTile)),
      findsOneWidget,
    );
    await tester.tap(find.text('Preparing isolated browser launch'));
    await tester.pumpAndSettle();
    await tester.settleMarkdown();
    expect(
      find.text('Exact reasoning body.', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Raw details'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late tool completion stays below a later reasoning block', (
    tester,
  ) async {
    final runtime = execution.ChatRuntime(runtimeId: 'late-result');
    runtime.beginTurn(submitting: false);
    runtime.observeReasoning('reasoning.delta', {'text': 'First thought'});
    runtime.observeTool('tool.start', {
      'tool_id': 'slow',
      'name': 'read_file',
      'arguments': {'path': 'slow.md'},
    });
    runtime.observeReasoning('reasoning.delta', {'text': 'Next thought'});
    await show(tester, runtime.observation.activityEntries);
    await tester.openLiveActivity();
    final old = tester.element(call('slow'));
    expect(
      tester.getTopLeft(find.text('Next thought')).dy,
      lessThan(tester.getTopLeft(runLabel('1 tool')).dy),
    );
    runtime.observeTool('tool.complete', {
      'tool_id': 'slow',
      'name': 'read_file',
      'result': 'Late result',
    });
    await show(tester, runtime.observation.activityEntries);
    expect(tester.element(call('slow')), same(old));
    expect(
      tester.getTopLeft(find.text('Next thought')).dy,
      lessThan(tester.getTopLeft(runLabel('1 tool')).dy),
    );
    expect(tester.widget<ProfileToolCall>(call('slow')).call.result, isNotNull);
  });

  testWidgets('new groups preserve nested tool and outer disclosure state', (
    tester,
  ) async {
    final initial = [reasoning('one', 'First heading'), tool('one')];
    await show(tester, initial);
    await tester.openLiveActivity();
    await tester.tap(find.text('Read file'));
    await tester.pumpAndSettle();
    await tester.settleMarkdown();
    final old = tester.element(call('one'));
    expect(find.byType(ToolActivityDetailsView), findsOneWidget);
    await show(tester, [
      ...initial,
      reasoning('two', 'Second heading'),
      tool('two'),
    ]);
    expect(tester.element(call('one')), same(old));
    expect(find.byType(ToolActivityDetailsView), findsOneWidget);
    expect(call('two'), findsNothing, reason: 'New tool runs start collapsed.');
    await open(tester);
    await open(tester);
    expect(tester.element(call('one')), same(old));
    expect(find.byType(ToolActivityDetailsView), findsOneWidget);
    await tester.openLiveActivity();
    expect(call('two'), findsOneWidget);
  });

  testWidgets('duplicate heading text retains separate event identities', (
    tester,
  ) async {
    await show(tester, [
      reasoning('one', 'Same heading'),
      tool('one'),
      reasoning('two', 'Same heading'),
    ]);
    expect(find.text('Same heading'), findsOneWidget);
    await open(tester);
    expect(find.text('Same heading'), findsNWidgets(2));
    expect(find.byType(ProfileReasoningDisclosure), findsNWidgets(2));
  });

  testWidgets(
    'saved native runs merge and reverse without rebuilding open calls',
    (tester) async {
      TranscriptTimelineSection saved(List<int> ids) =>
          TranscriptTimeline.project([
            for (final id in ids)
              {
                'id': id,
                'role': 'tool',
                'tool_call_id': 'saved-$id',
                'tool_name': 'read_file',
                'content': 'Result $id',
              },
          ], presentationId: (row) => row['id']!).sections.single;
      await show(tester, [tool('native')], saved: saved([2]));
      await tester.openLiveActivity();
      final old = tester.element(call('native'));
      expect(
        tester
            .widgetList<ProfileToolCall>(find.byType(ProfileToolCall))
            .map((w) => w.call.callId),
        ['native', 'saved-2'],
      );
      await show(tester, [tool('native')], saved: saved([1, 2]));
      expect(tester.element(call('native')), same(old));
      expect(
        tester
            .widgetList<ProfileToolCall>(find.byType(ProfileToolCall))
            .map((w) => w.call.callId),
        ['native', 'saved-2', 'saved-1'],
      );
      expect(runLabel('3 tools'), findsOneWidget);
    },
  );

  testWidgets('saved reasoning keeps its position beside native reasoning', (
    tester,
  ) async {
    final saved = TranscriptTimeline.project([
      {
        'id': 1,
        'role': 'tool',
        'tool_call_id': 'old',
        'tool_name': 'read_file',
        'content': 'Old result',
      },
      {
        'id': 2,
        'role': 'assistant',
        'content': '',
        'reasoning': 'Saved heading',
      },
      {
        'id': 3,
        'role': 'tool',
        'tool_call_id': 'joined',
        'tool_name': 'read_file',
        'content': 'Joined result',
      },
    ], presentationId: (row) => row['id']!).sections.single;
    await show(tester, [
      tool('native'),
      reasoning('last', 'Native heading'),
    ], saved: saved);
    await open(tester);
    expect(
      tester.getTopLeft(find.text('Native heading')).dy,
      lessThan(tester.getTopLeft(runLabel('2 tools')).dy),
    );
    expect(
      tester.getTopLeft(runLabel('2 tools')).dy,
      lessThan(tester.getTopLeft(find.text('Saved heading')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Saved heading')).dy,
      lessThan(tester.getTopLeft(runLabel('1 tool')).dy),
    );
  });

  testWidgets(
    'run durations keep chronological boundaries in reversed display',
    (tester) async {
      final start = DateTime.fromMillisecondsSinceEpoch(1000000);
      final entries = [
        tool('first'),
        reasoning('r1', 'First', at: start.add(const Duration(seconds: 12))),
        tool('second'),
        reasoning('r2', 'Second', at: start.add(const Duration(seconds: 31))),
        tool('last'),
      ];
      await show(tester, entries, startedAt: start);
      await open(tester);
      expect(
        tester
            .widgetList<ActivityTime>(find.byType(ActivityTime))
            .map((t) => t.durationSeconds),
        [null, null, 19, null, 12],
      );
      await show(
        tester,
        entries,
        startedAt: start,
        endedAt: start.add(const Duration(seconds: 40)),
        running: false,
      );
      expect(find.byType(ProfileActivitySection), findsNothing);
      await open(tester);
      expect(find.text('· 9.0 s'), findsOneWidget);
      expect(find.text('· 19 s'), findsOneWidget);
      expect(find.text('· 12 s'), findsOneWidget);
    },
  );

  testWidgets('unknown reversed and zero time boundaries remain qualified', (
    tester,
  ) async {
    final start = DateTime.fromMillisecondsSinceEpoch(1000000);
    final entries = [
      tool('first'),
      reasoning('one', 'Boundary', at: start),
      tool('last'),
    ];
    await show(tester, entries);
    await open(tester);
    expect(find.text('· 0 ms'), findsNothing);
    await show(
      tester,
      entries,
      startedAt: start.add(const Duration(seconds: 1)),
    );
    expect(find.text('· 0 ms'), findsNothing);
    await show(tester, entries, startedAt: start);
    expect(find.text('· 0 ms'), findsOneWidget);
  });

  testWidgets(
    'empty reasoning does not split tools and many tools remain reachable',
    (tester) async {
      await show(tester, [
        for (var i = 0; i < 12; i++) tool('old-$i'),
        reasoning('empty', '  \n '),
        reasoning('boundary', 'Check three more'),
        for (var i = 0; i < 3; i++) tool('new-$i'),
      ]);
      expect(find.text('15 tools'), findsOneWidget);
      await tester.openLiveActivity();
      expect(find.byType(ProfileToolCall), findsNWidgets(15));
      expect(
        tester
            .widgetList<ProfileToolCall>(find.byType(ProfileToolCall))
            .map((w) => w.call.callId),
        ['new-2', 'new-1', 'new-0', for (var i = 11; i >= 0; i--) 'old-$i'],
      );
      expect(find.byType(ProfileActivitySection), findsNWidgets(2));
    },
  );

  testWidgets(
    'current saved completion notices do not reconstruct dock categories',
    (tester) async {
      final notice = TranscriptTimeline.project([
        {
          'id': 1,
          'role': 'user',
          'display_kind': 'async_delegation_complete',
          'content': 'Agent result',
          'display_content': 'Subagent Task Completed',
        },
      ], presentationId: (row) => row['id']!).sections.single;
      await show(tester, [], saved: notice);
      expect(find.byKey(const ValueKey('live-activity-toggle')), findsNothing);
      await show(tester, [tool('call')], saved: notice);
      await tester.openLiveActivity();
      expect(find.text('Agent result'), findsNothing);
      expect(find.text('Agents'), findsNothing);
      expect(find.byType(ProfileActivityTabs), findsNothing);
      expect(call('call'), findsOneWidget);
    },
  );

  testWidgets('older reading position survives prepended reasoning and tools', (
    tester,
  ) async {
    final entries = <ChatActivityEntry>[
      for (var i = 0; i < 12; i++) ...[
        reasoning('r$i', 'Heading $i'),
        tool('t$i'),
      ],
    ];
    await show(tester, entries);
    await open(tester);
    final scroller = find.descendant(
      of: find.byKey(const ValueKey('live-activity')),
      matching: find.byType(SingleChildScrollView),
    );
    await tester.drag(scroller, const Offset(0, -240));
    await tester.pumpAndSettle();
    final heading = find.text('Heading 8');
    final before = tester.getTopLeft(heading).dy;
    await show(tester, [
      ...entries,
      reasoning('new', 'New heading'),
      tool('new'),
    ]);
    expect(tester.getTopLeft(heading).dy, closeTo(before, 1));
    expect(tester.takeException(), isNull);
  });
  testWidgets('open details stay anchored even before the reader scrolls', (
    tester,
  ) async {
    final entries = <ChatActivityEntry>[
      reasoning('first', 'First heading'),
      tool('first'),
      for (var i = 0; i < 8; i++) tool('extra-$i'),
    ];
    await show(tester, entries);
    await tester.openLiveActivity();
    final header = runLabel('9 tools');
    final before = tester.getTopLeft(header).dy;
    await show(tester, [
      ...entries,
      reasoning('next', 'Next heading'),
      tool('next'),
    ]);
    expect(tester.getTopLeft(header.last).dy, closeTo(before, 1));
    expect(call('first'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

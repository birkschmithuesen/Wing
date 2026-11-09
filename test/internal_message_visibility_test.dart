import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/models/transcript_timeline.dart';
import 'package:wing/core/models/reading_snapshot_message.dart';
import 'package:wing/core/services/chat_reading_session.dart';
import 'package:wing/core/models/transcript_message.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/answer_versions.dart';
import 'package:wing/core/models/transcript_notice.dart';
import 'package:wing/core/models/skill_invocation.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/widgets/chat_find_sheet.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/pump_markdown_widget.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_history_fixture.dart';
import 'support/process_batch_fixture.dart';
import 'task_snapshot_visibility_test.dart' show snapshot, snapshotHeader;

const _envelope =
    '[ASYNC DELEGATION BATCH COMPLETE — deleg_be8ac8e4]\n'
    'A background fan-out unit you dispatched earlier has finished.\n'
    'Private instructions for the agent.\nRole: leaf  Model: gpt-5.6-terra\n\n'
    '--- ✓ TASK 1/2: private goal  (status=completed) ---\n'
    'First useful result\n'
    'Full live transcript (complete tool/assistant trace): /private/path\n\n'
    '--- ✓ TASK 2/2: private goal\nprivate continuation  (status=completed) ---\n'
    'Second useful result';

Map<String, dynamic> _notice() => {
  'id': 3,
  'role': 'user',
  'content': _envelope,
  'display_kind': 'async_delegation_complete',
  'display_metadata': {'task_count': 3},
};

const _processEnvelope =
    '[IMPORTANT: Background process proc_0c3ef9a5dfb0 completed normally (exit code 0).\nCommand: env -u ANTHROPIC_API_KEY claude --print\nOutput:\n]';
const _processHeartbeat =
    '[Background process proc_7d2ae4ca6501 heartbeat #9 — still running after '
    '18m (next in 120s; you will also be told when it exits).\n'
    'Command: python monthly_pilot.py audit\n'
    'Output since last heartbeat:\n{"batch_id": 64, "status": "parsed"}]';
const _agentEnvelope =
    'Message from 🤖 Hermes (@hermes): Private agent instructions';
const _skillEnvelope =
    '[IMPORTANT: The user has invoked the "work" skill, indicating they want you to follow its instructions.\nThe full skill content is loaded below.]\nPrivate skill body\nThe user has provided the following instruction alongside the skill invocation: fix the leak\n\n[Runtime note: private]';
const _continuationHeader =
    '[STILL IN PROGRESS — this is the active request, restated after the '
    'compaction boundary because it was not finished yet. Continue it; '
    'do not start over.]';
const _continuationEnvelope =
    '$_continuationHeader\nPlease diagnose the browser/vault failure on this VM.';
const _rawDelegationEnvelope =
    '[ASYNC DELEGATION BATCH COMPLETE — deleg_22411d56]\n'
    'A background fan-out unit you dispatched earlier — 2 subagent(s) — '
    'has finished; its consolidated results are below. Any other units from the sa';

// Stock process_registry_notifications.py::_format_batch_delegation at
// ef35e8b9e1a8bc7f0efb50e4f2d68f1ec052f6a8; matches the reported bubble.
const _batchDelegationEnvelope =
    '[ASYNC DELEGATION BATCH COMPLETE — deleg_441d6ba6]\n'
    'A background fan-out unit you dispatched earlier — 3 subagent(s) — '
    'has finished; its consolidated results are below. Any other units from the '
    'same delegate_task call report separately as they finish. You may have '
    'moved on since dispatching — act on these or re-dispatch if things have '
    'changed. If you are still waiting on siblings, end your turn after acting '
    'on this one.\n\n'
    'Dispatched: 2026-10-30 15:07:46 (5m ago)\n'
    'Role: leaf   Total duration: 300s\n\n'
    '--- ✓ TASK 1/3: Check retailers  (status=completed) ---\n'
    'Retailer results for the parent agent';

Map<String, dynamic> _batchNotice() => {
  'id': 14,
  'role': 'user',
  'content': _batchDelegationEnvelope,
  'display_kind': 'async_delegation_complete',
  'display_metadata': {
    'display_text': 'Subagent Tasks Completed: retailer checks',
  },
};

class _NoticeHistory extends ProfileHistoryFixture {
  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => [
    {'id': 1, 'role': 'user', 'content': 'Compare the options'},
    {'id': 2, 'role': 'assistant', 'content': 'Nothing is booked.'},
    _notice(),
    {
      'id': 4,
      'role': 'user',
      'content': 'Private hidden instructions',
      'display_kind': 'hidden',
    },
    {'id': 5, 'role': 'user', 'content': _processEnvelope},
    {'id': 6, 'role': 'user', 'content': _agentEnvelope},
    {'id': 7, 'role': 'assistant', 'content': 'Private agent reply'},
    {'id': 8, 'role': 'user', 'content': _skillEnvelope},
    {'id': 9, 'role': 'user', 'content': processBatchEnvelope},
    {'id': 10, 'role': 'user', 'content': snapshot},
    {'id': 11, 'role': 'user', 'content': _continuationEnvelope},
    {
      'id': 12,
      'role': 'user',
      'content': _rawDelegationEnvelope,
      'display_kind': 'async_delegation_complete',
      'display_metadata': {
        'display_text': 'Subagent Tasks Completed: audit (2 tasks)',
      },
    },
    {
      'id': 13,
      'role': 'user',
      'content': _processHeartbeat,
      'display_kind': 'hidden',
    },
    _batchNotice(),
  ];
}

void main() {
  const capture = bool.fromEnvironment('STUDIO_REVIEW');
  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'Ahem': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            Future.value(
              ByteData.sublistView(File(entry.value).readAsBytesSync()),
            ),
          ))
          .load();
    }
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'delegation batch stays out of phone messages ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          const frame = ValueKey('delegation-review');
          await tester.pumpWidget(
            RepaintBoundary(
              key: frame,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final row in [
                          {
                            'role': 'user',
                            'content': 'Find a reliable retailer.',
                          },
                          _batchNotice(),
                          {
                            'role': 'assistant',
                            'content': 'I am comparing the offers.',
                          },
                        ])
                          ProfileMessage(
                            message: TranscriptMessage.fromRow(row),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.settleMarkdown();
          expect(find.textContaining('deleg_441d6ba6'), findsNothing);
          expect(find.textContaining('Retailer results'), findsNothing);
          expect(find.text('Find a reliable retailer.'), findsOneWidget);
          expect(
            find.textContaining('I am comparing the offers.'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          if (capture) {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(frame),
            );
            await tester.runAsync(() async {
              final image = await boundary.toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final directory = Directory(
                'build/design-previews/delegation-exception',
              )..createSync(recursive: true);
              await File(
                '${directory.path}/${brightness.name}-$scale.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
        },
      );
    }
  }

  test('typed delegation batch preserves metadata and raw history', () {
    for (final fields in <Map<String, dynamic>>[
      {'content': _batchDelegationEnvelope},
      {'text': _batchDelegationEnvelope},
      {'content': _batchDelegationEnvelope.replaceAll('\n', '\r\n')},
      {'content': '  $_batchDelegationEnvelope\n'},
      {'content': 'wire payload', 'display_content': _batchDelegationEnvelope},
      {
        'content': [
          {'type': 'text', 'text': _batchDelegationEnvelope},
        ],
      },
      {
        'content': _batchDelegationEnvelope.replaceFirst(
          '3 subagent(s)',
          "group 'retailers' (3 subagent(s))",
        ),
      },
    ]) {
      final row = {..._batchNotice(), ...fields};
      for (final projected in [
        row,
        answerHistoryRows([row]).single,
        projectReadingSnapshotMessage(row),
      ]) {
        expect(isHiddenAnswerMessage(projected), isFalse, reason: '$fields');
        expect(isHumanAnswerPrompt(projected), isFalse);
        expect(
          TranscriptMessage.fromRow(projected).kind,
          TranscriptMessageKind.notice,
        );
        expect(projected['id'], 14);
        expect(answerMessageText(projected), answerMessageText(row));
        expect(isAnswerPrompt(projected), isFalse);
      }
    }
  });

  test('delegation text alone has no classification authority', () {
    for (final text in [
      _batchDelegationEnvelope,
      'Explain this:\n$_batchDelegationEnvelope',
      '```\n$_batchDelegationEnvelope\n```',
      '> $_batchDelegationEnvelope',
      _rawDelegationEnvelope,
      '[ASYNC DELEGATION BATCH COMPLETE — deleg_441d6ba6]',
      _batchDelegationEnvelope.replaceFirst(
        'A background fan-out',
        'My fan-out',
      ),
    ]) {
      expect(
        isHiddenAnswerMessage({'role': 'user', 'content': text}),
        isFalse,
        reason: text,
      );
    }
    for (final row in [
      {'role': 'assistant', 'content': _batchDelegationEnvelope},
      {
        'role': 'user',
        'content': _batchDelegationEnvelope,
        'display_content': 'Visible server projection',
      },
      {
        'role': 'user',
        'content': _batchDelegationEnvelope,
        'display_content': '',
      },
      {
        'role': 'user',
        'content': _batchDelegationEnvelope,
        'display_kind': 'steer',
      },
      {..._notice(), 'content': _batchDelegationEnvelope},
    ]) {
      expect(isHiddenAnswerMessage(row), isFalse);
    }
  });

  test('saved subagent completion belongs to Activity, never a prose row', () {
    final timeline = TranscriptTimeline.project([
      {'id': 1, 'role': 'assistant', 'content': 'The change is underway.'},
      _notice(),
      {'id': 4, 'role': 'tool', 'tool_name': 'read_file', 'content': 'Checked'},
      {'id': 5, 'role': 'assistant', 'content': 'Updated and deployed.'},
    ], presentationId: (row) => row['id']!);
    final completion = timeline.sections.singleWhere(
      (s) => s.containsMessage(3),
    );
    expect(completion.isActivity, isTrue);
    expect(completion.toolCount, 1);
    expect(completion.messages.map((e) => e.id), [3, 4]);
    expect(
      completion.messages.first.message.noticeResult,
      'First useful result\n\nSecond useful result',
    );
  });
  test('bot delivery projects sender, authored Markdown and timestamp', () {
    final row = {
      'id': 42,
      'role': 'user',
      'content':
          'Message from 🤖 Pace (@pace): **Please** create the issue.\n\n- HTTPS\n- Backups',
      'timestamp': 1791680800.125,
    };
    final message = TranscriptMessage.fromRow(row);
    expect(message.kind, TranscriptMessageKind.botMessage);
    expect(message.sender, 'Pace');
    expect(message.senderHandle, 'pace');
    expect(
      message.copyText,
      '**Please** create the issue.\n\n- HTTPS\n- Backups',
    );
    expect(message.timestamp!.millisecondsSinceEpoch, 1791680800125);
    expect(message.noticeResult, isNull);
    expect(isHumanAnswerPrompt(row), isFalse);
  });

  test('delivery runner receipts describe completion and preserve failures', () {
    for (final exit in [0, 1]) {
      final envelope =
          '[IMPORTANT: Background process proc_example completed normally (exit code $exit).\n'
          'Command: /usr/bin/python3 /home/user/hermes/tools/bot_mode_dm.py --run-delivery query-file /tmp/dm.txt\n'
          'Output:\n${exit == 0 ? 'Response delivered' : 'Delivery failed: connection refused'}]';
      for (final typed in [false, true]) {
        final row = {
          'id': 1,
          'role': 'user',
          'content': envelope,
          if (typed) 'display_kind': 'process_complete',
          if (typed) 'display_metadata': {'display_text': 'Process completed'},
        };
        final message = TranscriptMessage.fromRow(row);
        expect(
          message.text,
          exit == 0
              ? 'Bot delivery process finished'
              : 'Bot delivery process failed',
        );
        expect(
          message.noticeResult,
          contains(exit == 0 ? 'Response delivered' : 'connection refused'),
        );
        expect(message.noticeResult, contains('Command: /usr/bin/python3'));
      }
    }
    final ordinary = _processEnvelope.replaceFirst(
      'Output:\n',
      'Output:\nbot_mode_dm.py --run-delivery\n',
    );
    expect(
      TranscriptMessage.fromRow({'role': 'user', 'content': ordinary}).text,
      startsWith('Background process proc_'),
    );
    final echo = _processEnvelope.replaceFirst(
      'env -u ANTHROPIC_API_KEY claude --print',
      'echo bot_mode_dm.py --run-delivery',
    );
    expect(
      TranscriptMessage.fromRow({'role': 'user', 'content': echo}).text,
      startsWith('Background process proc_'),
    );
  });
  test('process heartbeats are hidden without changing stored history', () {
    for (final fields in <Map<String, dynamic>>[
      {'content': _processHeartbeat},
      {'text': _processHeartbeat},
      {'content': _processHeartbeat.replaceAll('\n', '\r\n')},
      {'content': '  $_processHeartbeat\n'},
      {'content': 'wire payload', 'display_content': _processHeartbeat},
      {
        'content': [
          {'type': 'text', 'text': _processHeartbeat},
        ],
      },
      {
        'content': _processHeartbeat.replaceFirst(
          '120s;',
          '120s when there is new output;',
        ),
      },
      {
        'content': _processHeartbeat.replaceFirst(
          'Command:',
          'Handed off to you by a subagent before it finished. Purpose: audit\n'
              'Command:',
        ),
      },
    ]) {
      final row = {
        'id': 13,
        'role': 'user',
        'display_kind': 'hidden',
        ...fields,
      };
      expect(isHiddenAnswerMessage(row), isTrue, reason: '$fields');
      expect(isHumanAnswerPrompt(row), isFalse);
      final stored = answerHistoryRows([row]).single;
      expect(isHiddenAnswerMessage(stored), isTrue);
      expect(stored['id'], 13);
      expect(isAnswerPrompt(row), isFalse);
      expect(answerMessageText(stored), answerMessageText(row));
    }
  });

  test('process heartbeat quotes and ordinary discussion stay visible', () {
    for (final text in [
      'Explain this:\n$_processHeartbeat',
      '```\n$_processHeartbeat\n```',
      '> $_processHeartbeat',
      '[Background process monitoring is useful]',
      '[Background process proc_example heartbeat #1]',
      _processHeartbeat.substring(0, _processHeartbeat.length - 1),
    ]) {
      expect(
        isHiddenAnswerMessage({'role': 'user', 'content': text}),
        isFalse,
        reason: text,
      );
    }
    expect(
      isHiddenAnswerMessage({
        'role': 'assistant',
        'content': _processHeartbeat,
      }),
      isFalse,
    );
    expect(
      isHiddenAnswerMessage({
        'role': 'user',
        'content': _processHeartbeat,
        'display_content': 'User-facing server projection',
      }),
      isFalse,
    );
  });

  testWidgets('process heartbeat never renders a chat bubble', (tester) async {
    const row = {
      'role': 'user',
      'content': _processHeartbeat,
      'display_kind': 'hidden',
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileMessage(message: TranscriptMessage.fromRow(row)),
        ),
      ),
    );
    expect(find.textContaining('heartbeat #9'), findsNothing);
    expect(find.byTooltip('Copy message'), findsNothing);
    final sections = TranscriptTimeline.project([
      {'id': 1, 'role': 'tool', 'content': 'first'},
      row,
      {'id': 2, 'role': 'tool', 'content': 'second'},
    ], presentationId: (_) => Object()).sections;
    expect(sections, hasLength(1));
    expect(sections.single.messages.map((row) => row.message.id), [1, 2]);
  });

  test('technical envelopes are hidden across message encodings', () {
    for (final fields in <Map<String, dynamic>>[
      {'content': _continuationEnvelope},
      {'text': _continuationEnvelope},
      {'content': _continuationEnvelope.replaceAll('\n', '\r\n')},
      {'content': '  $_continuationEnvelope\n'},
      {'content': 'wire payload', 'display_content': _continuationEnvelope},
      {
        'content': [
          {'type': 'text', 'text': _continuationEnvelope},
        ],
      },
    ]) {
      final row = {'role': 'user', ...fields};
      expect(isHiddenAnswerMessage(row), isTrue, reason: '$fields');
      expect(isHumanAnswerPrompt(row), isFalse);
      expect(isHiddenAnswerMessage(answerHistoryRows([row]).single), isTrue);
      // Filtering must not change the stored history's rewind ordinals.
      expect(isAnswerPrompt(row), isTrue);
    }
  });

  test('untyped heartbeat and delegation wording has no display authority', () {
    for (final text in [_processHeartbeat, _rawDelegationEnvelope]) {
      final row = {'role': 'user', 'content': text};
      expect(isHiddenAnswerMessage(row), isFalse);
      expect(
        TranscriptMessage.fromRow(row).kind,
        TranscriptMessageKind.dialogue,
      );
      expect(answerMessageDisplayText(row), text);
    }
    final typed = {
      ..._notice(),
      'content': _rawDelegationEnvelope,
      'display_metadata': {'display_text': 'Subagent Task Failed: audit'},
    };
    expect(isHiddenAnswerMessage(typed), isFalse);
    expect(transcriptNoticeText(typed), 'Subagent Task Failed: audit');
  });

  test('quoted and ordinary progress messages remain visible', () {
    for (final text in [
      'Explain this:\n$_continuationEnvelope',
      '```\n$_continuationEnvelope\n```',
      '> $_continuationEnvelope',
      '[STILL IN PROGRESS] Please continue my request.',
      '[STILL IN PROGRESS — this is the active request',
      _continuationHeader,
    ]) {
      final row = {'role': 'user', 'content': text};
      expect(isHiddenAnswerMessage(row), isFalse, reason: text);
      expect(isHumanAnswerPrompt(row), isTrue);
      expect(answerMessageDisplayText(row), text);
    }
    expect(
      isHiddenAnswerMessage({
        'role': 'assistant',
        'content': _continuationEnvelope,
      }),
      isFalse,
    );
    expect(
      isHiddenAnswerMessage({
        'role': 'user',
        'content': _continuationEnvelope,
        'display_content': 'Server-projected user text',
      }),
      isFalse,
    );
  });

  testWidgets('continuation reminder never renders a chat bubble', (
    tester,
  ) async {
    const row = {'role': 'user', 'content': _continuationEnvelope};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileMessage(message: TranscriptMessage.fromRow(row)),
        ),
      ),
    );
    expect(find.textContaining(_continuationHeader), findsNothing);
    expect(find.byTooltip('Copy message'), findsNothing);
    expect(answerMessageText(row), _continuationEnvelope);
    final sections = TranscriptTimeline.project([
      {'id': 1, 'role': 'tool', 'content': 'first'},
      row,
      {'id': 2, 'role': 'tool', 'content': 'second'},
    ], presentationId: (_) => Object()).sections;
    expect(sections, hasLength(1));
    expect(sections.single.messages.map((row) => row.message.id), [1, 2]);
  });

  for (final width in [360.0, 900.0]) {
    testWidgets('producer batch renders one compact notice at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProfileMessage(
                message: TranscriptMessage.fromRow({
                  'role': 'user',
                  'content': processBatchEnvelope,
                }),
              ),
            ),
          ),
        ),
      );
      expect(find.text(processBatchEnvelope), findsNothing);
      expect(find.byTooltip('Copy message'), findsNothing);
      expect(find.text('16 background processes completed'), findsOneWidget);
      expect(find.textContaining('Action needed'), findsNothing);
      await tester.tap(find.text('Output'));
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      expect(
        find.textContaining('Action needed: check failed'),
        findsOneWidget,
      );
      expect(find.textContaining('[IMPORTANT:'), findsNothing);
      expect(find.textContaining('Treat these results'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('process completion never exposes its delivery envelope', (
    tester,
  ) async {
    const envelope =
        '[IMPORTANT: Background process proc_0c3ef9a5dfb0 '
        'completed normally (exit code 0).\n'
        'Command: env -u ANTHROPIC_API_KEY claude --print\nOutput:\n]';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileMessage(
            message: TranscriptMessage.fromRow({
              'role': 'user',
              'content': envelope,
            }),
          ),
        ),
      ),
    );
    expect(find.text(envelope), findsNothing);
    expect(find.byTooltip('Copy message'), findsNothing);
  });
  for (final width in [360.0, 900.0]) {
    testWidgets('typed delegation is a notice at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final row = _notice();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProfileMessage(message: TranscriptMessage.fromRow(row)),
          ),
        ),
      );
      expect(find.text(_envelope), findsNothing);
      expect(find.byTooltip('Copy message'), findsNothing);
      expect(isAnswerPrompt(row), isFalse);
      expect(find.text('3 background agents finished'), findsOneWidget);
      expect(find.text('First useful result'), findsNothing);
      await tester.tap(find.text('View result'));
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      expect(find.textContaining('First useful result'), findsOneWidget);
      expect(find.textContaining('Private instructions'), findsNothing);
      expect(find.textContaining('private goal'), findsNothing);
      expect(find.textContaining('Full live transcript'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'saved history and refresh preserve notices and hide scaffolding',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final host = _NoticeHistory();
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'notice-history',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final chat = await openFixtureChat(
        controller: controller,
        key: ProfileSessionKey(controller.current!.scope, 'chat-0'),
        title: 'Notice history',
      );

      await controller.refreshHistory(chat);
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => const []),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var refresh = 0; refresh < 2; refresh++) {
        final timeline = TranscriptTimeline.project(
          chat.reading.messages,
          presentationId: chat.reading.messagePresentationId,
        );
        for (final id in [3, 5, 9, 12]) {
          expect(
            timeline.sections
                .singleWhere((s) => s.containsMessage(id))
                .isActivity,
            isTrue,
          );
        }
        await tester.settleMarkdown();
        expect(find.text(_envelope), findsNothing);
        expect(find.text('Private hidden instructions'), findsNothing);
        expect(find.text('3 background agents finished'), findsNothing);
        expect(find.byKey(const ValueKey('edit-message-3')), findsNothing);
        expect(find.byKey(const ValueKey('edit-message-1')), findsOneWidget);
        expect(find.byKey(const ValueKey('edit-message-5')), findsNothing);
        expect(find.byKey(const ValueKey('edit-message-6')), findsNothing);
        expect(find.byKey(const ValueKey('answer-actions-7')), findsNothing);
        expect(find.text('Private agent reply'), findsOneWidget);
        expect(find.text('Replied to Hermes'), findsNothing);
        expect(find.text('Private agent instructions'), findsOneWidget);
        expect(find.text('Hermes'), findsWidgets);
        expect(
          find.byKey(
            const ValueKey<(String, Object?)>(('bot-message-bubble', 6)),
          ),
          findsOneWidget,
        );
        expect(find.text(_processEnvelope), findsNothing);
        expect(find.text(_agentEnvelope), findsNothing);
        expect(find.text(_skillEnvelope), findsNothing);
        expect(find.text('/work fix the leak'), findsOneWidget);
        expect(find.text(processBatchEnvelope), findsNothing);
        expect(find.text('16 background processes completed'), findsNothing);
        expect(find.byKey(const ValueKey('edit-message-9')), findsNothing);
        expect(find.textContaining(snapshotHeader), findsNothing);
        expect(find.byKey(const ValueKey('edit-message-10')), findsNothing);
        expect(find.textContaining(_continuationHeader), findsNothing);
        expect(find.byKey(const ValueKey('edit-message-11')), findsNothing);
        expect(find.textContaining('deleg_22411d56'), findsNothing);
        expect(find.byKey(const ValueKey('edit-message-12')), findsNothing);
        expect(find.textContaining('heartbeat #9'), findsNothing);
        expect(find.byKey(const ValueKey('edit-message-13')), findsNothing);
        expect(find.textContaining('deleg_441d6ba6'), findsNothing);
        expect(find.textContaining('Retailer results'), findsNothing);
        expect(find.byKey(const ValueKey('edit-message-14')), findsNothing);
        // Retain server history and IDs for paging/rewind; filter only the view.
        expect(chat.reading.messages.map((row) => row['id']), [
          1,
          2,
          3,
          4,
          5,
          6,
          7,
          8,
          9,
          10,
          11,
          12,
          13,
          14,
        ]);
        await controller.refreshHistory(chat);
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets('Find in chat uses typed display text, not internal payloads', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _findSheet(
          loadHistory: (_) async => ProfileHistoryPage(
            'chat',
            _NoticeHistory().historyRows('default', 'chat'),
            0,
            500,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Private hidden');
    await tester.pump();
    expect(find.textContaining('Private instructions'), findsNothing);
    expect(find.text('Private hidden instructions'), findsNothing);
    expect(find.text('View in chat'), findsNothing);
    await tester.enterText(find.byType(TextField), 'deleg_22411d56');
    await tester.pump();
    expect(find.text('View in chat'), findsNothing);
    await tester.enterText(
      find.byType(TextField),
      'end your turn after acting',
    );
    await tester.pump();
    expect(find.text('View in chat'), findsNothing);
    await tester.enterText(find.byType(TextField), 'Quiesce processing');
    await tester.pump();
    expect(find.textContaining(snapshotHeader), findsNothing);
    expect(find.text('View in chat'), findsNothing);
    await tester.enterText(find.byType(TextField), 'browser/vault failure');
    await tester.pump();
    expect(find.textContaining(_continuationHeader), findsNothing);
    expect(find.text('View in chat'), findsNothing);
    await tester.enterText(find.byType(TextField), 'First useful result');
    await tester.pump();
    expect(find.textContaining('First useful result'), findsWidgets);
    expect(find.text('1 matching message'), findsOneWidget);
    expect(find.text('system'), findsOneWidget);
  });

  for (final width in [360.0, 900.0]) {
    for (final envelope in [_processEnvelope, _agentEnvelope]) {
      testWidgets('delivery at $width: ${envelope.substring(0, 30)}', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final row = {'role': 'user', 'content': envelope};
        final delivery = transcriptUserDelivery(row)!;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ProfileMessage(message: TranscriptMessage.fromRow(row)),
            ),
          ),
        );
        expect(find.text(envelope), findsNothing);
        expect(isHumanAnswerPrompt(row), isFalse);
        if (delivery.kind == 'agent_message') {
          expect(find.text(delivery.sender!), findsOneWidget);
          await tester.settleMarkdown();
          expect(find.text(delivery.detail), findsOneWidget);
          expect(find.byTooltip('Copy message'), findsOneWidget);
        } else {
          expect(find.text(delivery.headline), findsOneWidget);
          expect(find.text(delivery.detail), findsNothing);
          expect(find.byTooltip('Copy message'), findsNothing);
          await tester.tap(find.text('Output'));
          await tester.pumpAndSettle();
          expect(find.text(delivery.detail), findsOneWidget);
        }
        expect(find.text(envelope), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  test(
    'process receipts group with Activity without changing history or timing',
    () {
      for (final receipt in <Map<String, dynamic>>[
        {'role': 'user', 'content': _processEnvelope},
        {'role': 'user', 'content': processBatchEnvelope},
        {
          'role': 'user',
          'content': _processEnvelope,
          'display_kind': 'process_complete',
        },
        {
          'role': 'user',
          'content': _processEnvelope.replaceFirst(
            'exit code 0',
            'exit code 1',
          ),
          'display_kind': 'process_complete',
        },
        {'role': 'user', 'content': '', 'display_kind': 'process_complete'},
      ]) {
        final rows = <Map<String, dynamic>>[
          {'id': 1, 'role': 'user', 'content': 'Run it', 'timestamp': 100},
          {
            'id': 2,
            'role': 'assistant',
            'content': 'Started',
            'timestamp': 110,
          },
          {'id': 3, ...receipt, 'timestamp': 200},
          {
            'id': 4,
            'role': 'tool',
            'tool_name': 'terminal',
            'content': 'Checked',
          },
          {'id': 5, 'role': 'assistant', 'content': 'Done', 'timestamp': 210},
        ];
        final timeline = TranscriptTimeline.project(
          rows,
          presentationId: (row) => row['id'] as int,
        );
        final section = timeline.sections.singleWhere(
          (s) => s.containsMessage(3),
        );
        expect(section.isActivity, isTrue);
        expect(section.messages.map((m) => m.id), [3, 4]);
        expect(section.toolCount, 1);
        expect(section.replyDuration, isNull);
        expect(timeline.entries.map((m) => m.id), [1, 2, 3, 4, 5]);
        expect(
          timeline
              .nearby(3)!
              .sections
              .any((s) => s.isActivity && s.containsMessage(3)),
          isTrue,
        );
      }
      final quote = {
        'role': 'user',
        'content': 'Explain this:\n$_processEnvelope',
      };
      expect(
        TranscriptTimeline.project([
          quote,
        ], presentationId: (_) => 1).sections.single.isActivity,
        isFalse,
      );
    },
  );

  test('Desktop envelope matching preserves ordinary technical discussion', () {
    for (final text in [
      'Why did this happen?\n$_processEnvelope',
      '```\n$_processEnvelope\n```',
      '[IMPORTANT: Background process unfinished',
      '[IMPORTANT: read the docs]',
      'I got a Message from 🤖 Hermes: earlier',
      'can you explain what Message from means?',
    ]) {
      final row = {'role': 'user', 'content': text};
      expect(transcriptNoticeKind(row), isNull);
      expect(isHumanAnswerPrompt(row), isTrue);
      expect(answerMessageDisplayText(row), text);
    }
    for (final text in [_processEnvelope, _agentEnvelope]) {
      expect(
        transcriptNoticeKind({'role': 'assistant', 'content': text}),
        isNull,
      );
    }
    expect(
      transcriptNoticeResult({
        'role': 'user',
        'text': _processEnvelope.replaceAll('\n', '\r\n'),
      }),
      'Command: env -u ANTHROPIC_API_KEY claude --print\r\nOutput:',
    );
    expect(
      transcriptUserDelivery({
        'role': 'user',
        'content': 'wire payload',
        'display_content': _agentEnvelope,
      })?.headline,
      'Message from Hermes',
    );
    expect(
      transcriptNoticeResult({
        'role': 'user',
        'content': '[IMPORTANT: Background process 1 finished]',
      }),
      isNull,
    );
    for (final text in [
      'Message from Turquoise: ready',
      'Message from 🤖 Dev: line one\nline two',
    ]) {
      expect(
        transcriptNoticeKind({'role': 'user', 'content': text}),
        'agent_message',
      );
    }
  });

  test('skill scaffold matches Desktop single and bundle projection', () {
    expect(skillInvocationText(_skillEnvelope), '/work fix the leak');
    expect(
      skillInvocationText(
        _skillEnvelope.replaceFirst('fix the leak', 'fix\n\nthe leak'),
      ),
      '/work fix the leak',
    );
    expect(
      skillInvocationText(
        '[IMPORTANT: The user has invoked the "work" skill.\nThe full skill content is loaded below.]\nPrivate body',
      ),
      '/work',
    );
    expect(
      skillInvocationText(
        '[IMPORTANT: The user has invoked the "/clean /work" stacked skill bundle, loading 2 skills together.]\n\nUser instruction: ship it\n\n[Loaded as part of the stacked skill invocation "clean".]\nPrivate body',
      ),
      '/clean /work ship it',
    );
    expect(skillInvocationText('[IMPORTANT: read the docs]'), isNull);
    expect(
      answerMessageDisplayText({
        'role': 'assistant',
        'content': _skillEnvelope,
      }),
      _skillEnvelope,
    );
  });

  test('bot replies stay dialogue with human replay boundaries intact', () {
    final messages = <Map<String, dynamic>>[
      {'role': 'user', 'content': _agentEnvelope},
      {'role': 'system', 'content': 'status'},
      {'role': 'assistant', 'content': 'Reply'},
      {'role': 'assistant', 'content': 'Another answer'},
      {'role': 'user', 'content': 'Human prompt'},
      {'role': 'assistant', 'content': 'Human answer'},
    ];
    final timeline = TranscriptTimeline.project(
      messages,
      presentationId: (row) => row,
    );
    expect(timeline.entries[0].message.kind, TranscriptMessageKind.botMessage);
    for (final index in [2, 3, 5]) {
      expect(
        timeline.entries[index].message.kind,
        TranscriptMessageKind.dialogue,
      );
    }
    // Untyped deliveries retain their durable ordinal for existing history APIs.
    expect(AnswerTarget.at(messages, 5)!.userOrdinal, 1);
  });

  testWidgets('system status is compact and strips the slash protocol marker', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileMessage(
            message: TranscriptMessage.fromRow({
              'role': 'system',
              'content': 'slash:/model\nModel changed',
            }),
          ),
        ),
      ),
    );
    expect(find.text('/model · Model changed'), findsOneWidget);
    expect(find.text('System'), findsNothing);
    expect(find.byTooltip('Copy message'), findsNothing);
  });

  testWidgets('search projects deliveries and skills without their wrappers', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _findSheet(
          loadHistory: (_) async => ProfileHistoryPage(
            'chat',
            _NoticeHistory().historyRows('default', 'chat'),
            0,
            500,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final query in [
      'IMPORTANT',
      'Private skill body',
      'Runtime note',
      '(@hermes)',
      'Treat these results as one batch',
      'heartbeat #9',
      'monthly_pilot.py',
    ]) {
      await tester.enterText(find.byType(TextField), query);
      await tester.pump();
      expect(find.text('View in chat'), findsNothing);
    }
    await tester.enterText(
      find.byType(TextField),
      'Private agent instructions',
    );
    await tester.pump();
    expect(find.text('1 matching message'), findsOneWidget);
    expect(find.text('Hermes'), findsOneWidget);
    await tester.enterText(
      find.byType(TextField),
      'Action needed: check failed',
    );
    await tester.pump();
    expect(find.text('1 matching message'), findsOneWidget);
    expect(find.textContaining('Treat these results'), findsNothing);
  });

  test('hidden rows do not split tool groups or become prompts', () {
    final hidden = {
      'id': 2,
      'role': 'user',
      'content': 'private',
      'display_kind': 'hidden',
    };
    final sections = TranscriptTimeline.project([
      {'id': 1, 'role': 'tool', 'content': 'first'},
      hidden,
      {'id': 3, 'role': 'tool', 'content': 'second'},
    ], presentationId: (_) => Object()).sections;
    expect(sections, hasLength(1));
    expect(sections.single.messages.map((row) => row.message.id), [1, 3]);
    expect(isAnswerPrompt(hidden), isFalse);
  });

  for (final metadata in [
    null,
    '{invalid',
    '[]',
    '{"task_count":1}',
    5,
    {'task_count': 'three'},
  ]) {
    test('malformed metadata $metadata cannot invent a task count', () {
      expect(
        transcriptNoticeText({..._notice(), 'display_metadata': metadata}),
        'Background agent work finished',
      );
    });
  }
  test('typed single-task metadata uses the singular completion label', () {
    expect(
      transcriptNoticeText({
        ..._notice(),
        'display_metadata': {'task_count': 1},
      }),
      '1 background agent finished',
    );
  });
  for (final entry in {
    'model_switch': 'Model changed',
    'personality_switch': 'Personality changed',
    'auto_continue': 'Resumed interrupted turn',
  }.entries) {
    test('${entry.key} projects its user-facing status', () {
      expect(
        transcriptNoticeText({'display_kind': entry.key, 'content': 'private'}),
        entry.value,
      );
    });
  }

  test('single, batch, cron and malformed results use producer boundaries', () {
    expect(
      transcriptNoticeResult(_notice()),
      'First useful result\n\nSecond useful result',
    );
    for (final separator in ['\n', '\r\n']) {
      final prefix =
          '[ASYNC DELEGATION COMPLETE — task]${separator}Private preamble$separator--- RESULT ---$separator';
      expect(
        transcriptNoticeResult({
          ..._notice(),
          'content': '${prefix}Useful report',
        }),
        'Useful report',
      );
      expect(
        transcriptNoticeResult({
          ..._notice(),
          'content':
              '${prefix}Cron job probe\nPrivate details\n--- JOB OUTPUT ---\nUseful report',
        }),
        'Useful report',
      );
    }
    expect(
      transcriptNoticeResult({
        ..._notice(),
        'content': '[ASYNC DELEGATION COMPLETE — task]\nPrivate preamble',
      }),
      isNull,
    );
    expect(
      transcriptNoticeResult({
        ..._notice(),
        'content': 'Already unwrapped report',
      }),
      'Already unwrapped report',
    );
    expect(
      transcriptNoticeResult({
        ..._notice(),
        'content': '',
        'display_content': 'Projected report',
      }),
      'Projected report',
    );
  });

  test(
    'technical discussion, quoted envelopes and assistant text stay visible',
    () {
      for (final text in [
        _envelope,
        'Why does this appear?\n$_envelope',
        '```text\n$_envelope\n```',
        'Why does this appear?\n$_rawDelegationEnvelope',
        '```text\n$_rawDelegationEnvelope\n```',
        '> $_rawDelegationEnvelope',
        '[ASYNC DELEGATION BATCH COMPLETE — deleg_22411d56]',
        '[ASYNC DELEGATION COMPLETE]',
        'The model_switch event is useful to debug.',
      ]) {
        final row = {'role': 'user', 'content': text};
        expect(transcriptNoticeKind(row), isNull);
        expect(isAnswerPrompt(row), isTrue);
        expect(isHiddenAnswerMessage(row), isFalse);
        final message = TranscriptTimeline.project(
          [row],
          presentationId: (_) => Object(),
        ).sections.single.messages.single.message;
        expect(message.role, 'user');
        expect(message.kind, TranscriptMessageKind.dialogue);
        expect(message.text, text);
      }
      expect(
        transcriptNoticeKind({'role': 'assistant', 'content': _envelope}),
        isNull,
      );
      expect(
        isHiddenAnswerMessage({
          'role': 'assistant',
          'content': _rawDelegationEnvelope,
        }),
        isFalse,
      );
    },
  );

  test('regeneration targets the human prompt before a typed notice', () {
    final target = AnswerTarget.at([
      {'role': 'user', 'content': 'Compare the options'},
      _notice(),
      {'role': 'assistant', 'content': 'Here is the comparison'},
    ], 2)!;
    expect(target.userOrdinal, 0);
    expect(target.prompt, 'Compare the options');
  });
}

Widget _findSheet({
  required Future<ProfileHistoryPage> Function(int) loadHistory,
}) => ChatFindSheet(
  createSession: () => ChatReadingSession(_FindSource(loadHistory)),
);

final class _FindSource extends ChangeNotifier implements ChatReadingSource {
  _FindSource(this.loadHistory);
  final Future<ProfileHistoryPage> Function(int) loadHistory;
  @override
  bool get current => true;
  @override
  Future<ProfileHistoryPage> load(int offset) => loadHistory(offset);
  @override
  bool show(ProfileHistoryPage page, int rowId) => true;
}

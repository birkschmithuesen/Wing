import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/transcript_timeline.dart';
import 'package:wing/core/models/reading_snapshot_message.dart';
import 'package:wing/core/presentation/tool_activity_details.dart';
import 'package:wing/core/presentation/tool_call_presentation.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/widgets/tool_activity_details.dart';

import 'helpers/pump_markdown_widget.dart';

const _message =
    'Created and read back issue **#620** in the verified canonical repository '
    '**Tarkil-Org/homelab-infra**.\n\nDeploy self-hosted Health Hub MCP for Android Health Connect ingestion '
    'https://gitea.hollinger.asia/Tarkil-Org/homelab-infra/issues/620\n\n'
    'The issue includes deployment requirements, security, backups and integration validation. '
    'No service was deployed, and no personal health data or secrets were included.';
const _reply =
    'Default (@hermes) confirmed it created and verified issue **#620** '
    'in the canonical private homelab-infra repository.\n\nThe issue is open and includes '
    'deployment requirements, security, backups and integration validation. No service '
    'was deployed, and no personal health data or secrets were included.';
final _queuedAt =
    DateTime.utc(2026, 10, 10, 19, 48, 6).millisecondsSinceEpoch / 1000;
final _receivedAt = _queuedAt + 26;

List<Map<String, dynamic>> _rows() => [
  {
    'id': 1,
    'role': 'user',
    'content': 'Can you create the issue and let Pace know?',
    'timestamp': _queuedAt - 70,
  },
  {
    'id': 2,
    'role': 'assistant',
    'content': 'I’ll create it, verify the issue, and send Pace the result.',
  },
  for (var i = 0; i < 3; i++)
    {
      'id': 3 + i,
      'role': 'tool',
      'tool_name': 'terminal',
      'tool_call_id': 'terminal-$i',
      'args': jsonEncode({
        'command':
            'curl -fsS https://gitea.hollinger.asia/api/v1/repos/Tarkil-Org/homelab-infra/issues${i == 0 ? '' : '/620'}',
      }),
      'duration_s': 8 - i,
      'content': jsonEncode({
        'exit_code': 0,
        'output': i == 0 ? 'No matching issue found.' : 'Issue #620: open',
      }),
    },
  {
    'id': 6,
    'role': 'assistant',
    'content': '',
    'tool_calls': [
      {
        'id': 'send-pace',
        'function': {
          'name': 'message_agent',
          'arguments': jsonEncode({'target': 'pace', 'message': _message}),
        },
      },
    ],
  },
  {
    'id': 7,
    'role': 'tool',
    'tool_call_id': 'send-pace',
    'content': jsonEncode({
      'status': 'queued',
      'to': '@pace',
      'process_id': 'proc_delivery',
      'delivery_id': 'delivery-1',
      'queued_at': _queuedAt,
      'reply_delivery': 'notification',
      'detail':
          'Message queued for @pace; this acknowledges hand-off, not a delivery receipt.',
    }),
  },
  {
    'id': 8,
    'role': 'assistant',
    'content':
        'Created issue **#620** in the private '
        '**Tarkil-Org/homelab-infra** repository. The result was queued to Pace.',
    'timestamp': _queuedAt + 1,
  },
];
String _envelope(
  String output, {
  String process = 'proc_delivery',
  int? exit = 0,
  String? command,
}) =>
    '[IMPORTANT: Background process $process ${exit == 0 ? 'completed normally' : 'exited'} (exit code ${exit ?? '?'}).\n'
    'Command: ${command ?? '/usr/bin/python3 /home/hermes/tools/bot_mode_dm.py --run-delivery query-file /tmp/dm.txt hermes -p pace chat --query-file /tmp/dm.txt'}\n'
    'Output:\n$output]';
Map<String, dynamic> _notice(String content, {Object? time, int id = 9}) => {
  'id': id,
  'role': 'user',
  'content': content,
  'display_kind': 'process_complete',
  'timestamp': time ?? _receivedAt,
};
String _settled([String reply = _reply]) => jsonEncode({
  'status': 'settled',
  'delivery_id': 'delivery-1',
  'reply': reply,
});
TranscriptTimeline _timeline(List<Map<String, dynamic>> rows) =>
    TranscriptTimeline.project(rows, presentationId: (r) => r['id']!);
ToolCallPresentation _call(TranscriptTimeline timeline) =>
    ToolCallPresentation.saved(
      timeline.entries.firstWhere((e) => e.id == 7).tool!,
    );

void main() {
  test('queue timestamps and delivery modes preserve partial observations', () {
    for (final mode in ['notification', 'poll', null]) {
      final details = ToolActivityDetails.project(
        name: 'message_agent',
        input: {'target': 'pace', 'message': ''},
        output: {
          'status': 'queued',
          'to': '@pace',
          'reply_delivery': mode,
          'queued_at': 'invalid',
        },
      );
      expect(details.request.single.showEmpty, isTrue);
      expect(details.request.single.copyText, '');
      expect(details.response.single.timestamp, isNull);
      expect(
        details.response.single.text.contains('will arrive separately'),
        mode == 'notification',
      );
      if (mode == 'poll') {
        expect(
          details.response.single.text,
          contains('cannot receive completion notifications'),
        );
      }
    }
  });
  test(
    'folded receipt leaves the original reply interval intact across an internal followup',
    () {
      final timeline = _timeline([
        ..._rows(),
        _notice(_envelope(_settled())),
        {
          'id': 10,
          'role': 'assistant',
          'content': 'Pace has processed the result.',
          'timestamp': _receivedAt + 30,
        },
      ]);
      expect(
        timeline.sections.firstWhere((s) => s.isActivity).replyDuration,
        const Duration(seconds: 71),
      );
      expect(timeline.entries.last.branchAnswer, isFalse);
    },
  );
  test(
    'delayed completion appends without replacing the message, queue or assistant answer',
    () {
      final rows = _rows();
      final original = jsonEncode(rows);
      final before = _call(_timeline(rows));
      final after = _timeline([...rows, _notice(_envelope(_settled()))]);
      final call = _call(after);
      expect(call.arguments, before.arguments);
      expect(call.result, before.result);
      expect(call.activityDetails.request.single.text, _message);
      expect(call.activityDetails.response.single.label, 'Queued');
      expect(
        call.activityDetails.response.single.timestamp!.millisecondsSinceEpoch /
            1000,
        _queuedAt,
      );
      expect(call.exchangeReceipts.single.label, 'Exchange complete');
      expect(call.exchangeReceipts.single.text, _reply);
      expect(
        call.exchangeReceipts.single.timestamp!.millisecondsSinceEpoch / 1000,
        _receivedAt,
      );
      expect(after.entries.last.suppressed, isTrue);
      expect(after.sections.last.messages.last.id, 8);
      expect(jsonEncode(rows), original);
      expect(() => call.exchangeReceipts.clear(), throwsUnsupportedError);
      // Find retains the full-history join even when its selected neighborhood
      // does not itself include the completion.
      expect(_call(after.nearby(7)!).exchangeReceipts.single.text, _reply);
    },
  );

  test(
    'saved snapshots and source-only calls retain the same exchange after reopening',
    () {
      final rows = _rows();
      // Stock history's assistant call supplies the tool identity/arguments.
      expect(_call(_timeline(rows)).subtitle, 'To @pace');
      // Passive snapshots retain the enriched saved tool reading fields.
      final tool = _timeline(rows).entries.firstWhere((e) => e.id == 7).tool!;
      rows[6] = {...rows[6], 'tool_name': tool.name, 'args': tool.arguments};
      rows.add(_notice(_envelope(_settled())));
      final restored =
          jsonDecode(
                jsonEncode(rows.map(captureReadingSnapshotMessage).toList()),
              )
              as List;
      final timeline = _timeline(
        restored.map((r) => projectReadingSnapshotMessage(r as Map)).toList(),
      );
      expect(_call(timeline).exchangeReceipts.single.text, _reply);
      expect(timeline.entries.last.suppressed, isTrue);
    },
  );

  test(
    'duplicates are retired once and multiple observations append in producer order',
    () {
      final pending = _envelope(
        jsonEncode({
          'status': 'claimed',
          'delivery_id': 'delivery-1',
          'detail': 'Delivery remains pending. Do not resend.',
        }),
      );
      final settled = _envelope(_settled());
      final timeline = _timeline([
        ..._rows(),
        _notice(pending),
        _notice(pending, id: 10),
        _notice(settled, id: 11),
      ]);
      expect(_call(timeline).exchangeReceipts.map((r) => r.label), [
        'Exchange pending',
        'Exchange complete',
      ]);
      expect(timeline.entries.skip(8), hasLength(3));
      expect(timeline.entries.skip(8).every((e) => e.suppressed), isTrue);
    },
  );

  test(
    'pending, uncertain and failed runner outcomes never claim exchange completion',
    () {
      for (final sample in [
        (
          jsonEncode({'status': 'queued', 'delivery_id': 'delivery-1'}),
          0,
          'Exchange pending',
        ),
        (
          jsonEncode({'status': 'claimed', 'delivery_id': 'delivery-1'}),
          0,
          'Exchange pending',
        ),
        (
          jsonEncode({
            'status': 'ambiguous',
            'delivery_id': 'delivery-1',
            'error': 'Do not resend.',
          }),
          1,
          'Exchange outcome unknown',
        ),
        (
          jsonEncode({
            'error': 'Target Bot Chat is busy.',
            'reason': 'target_busy',
          }),
          1,
          'Exchange failed',
        ),
        (
          jsonEncode({
            'status': 'failed',
            'delivery_id': 'delivery-1',
            'error': 'Target failed',
          }),
          1,
          'Exchange failed',
        ),
        (
          jsonEncode({
            'status': 'cancelled',
            'delivery_id': 'delivery-1',
            'error': 'Owner offline',
          }),
          1,
          'Exchange failed',
        ),
        ('Delivery failed', -15, 'Exchange failed'),
        ('Outcome not available', null, 'Exchange outcome unknown'),
      ]) {
        final receipt = _call(
          _timeline([
            ..._rows(),
            _notice(_envelope(sample.$1, exit: sample.$2)),
          ]),
        ).exchangeReceipts.single;
        expect(receipt.label, sample.$3);
        expect(receipt.raw, contains(sample.$1));
      }
    },
  );

  test(
    'exact identity and producer role are required; unmatched evidence remains visible',
    () {
      for (final notice in [
        _notice(_envelope(_settled(), process: 'proc_other')),
        _notice(
          _envelope(
            jsonEncode({
              'status': 'settled',
              'delivery_id': 'different',
              'reply': _reply,
            }),
          ),
        ),
        _notice(_envelope(_settled(), command: 'echo something unrelated')),
        {..._notice(_envelope(_settled())), 'role': 'assistant'},
        {..._notice(_envelope(_settled())), 'display_kind': 'steer'},
        _notice('[IMPORTANT: Background process incomplete'),
      ]) {
        final timeline = _timeline([..._rows(), notice]);
        expect(_call(timeline).exchangeReceipts, isEmpty);
        expect(timeline.entries.last.suppressed, isFalse);
      }
      final orphan = _timeline([_notice(_envelope(_settled()))]);
      expect(orphan.entries.single.suppressed, isFalse);
      final rows = _rows();
      rows.insert(7, {...rows[6], 'id': 70});
      expect(
        _call(
          _timeline([...rows, _notice(_envelope(_settled()))]),
        ).exchangeReceipts,
        isEmpty,
      );
    },
  );

  test(
    'mixed completion batches fold the matching bot and retain unrelated processes',
    () {
      final bot = _envelope(_settled());
      final other = _envelope(
        'Ordinary process output',
        process: 'proc_other',
        command: 'sleep 1',
      );
      final batch =
          '[IMPORTANT: 2 background processes completed.]\n\n$bot\n\n$other';
      final timeline = _timeline([..._rows(), _notice(batch)]);
      expect(_call(timeline).exchangeReceipts.single.text, _reply);
      expect(timeline.entries.last.suppressed, isFalse);
      expect(
        timeline.entries.last.message.noticeResult,
        contains('Ordinary process output'),
      );
      expect(
        timeline.entries.last.message.noticeResult,
        isNot(contains(_reply)),
      );
    },
  );

  test(
    'empty replies and absent/invalid timestamps do not invent received facts',
    () {
      final timeline = _timeline([
        ..._rows(),
        _notice(_envelope(_settled('')), time: 'not a timestamp'),
      ]);
      final receipt = _call(timeline).exchangeReceipts.single;
      expect(receipt.label, 'Exchange complete');
      expect(receipt.text, 'The exchange completed without a reply.');
      expect(receipt.timestamp, isNull);
    },
  );
  test('authored JSON replies remain exact visible text', () {
    final plain = _call(
      _timeline([
        ..._rows(),
        _notice(_envelope('{"source":"an authored JSON reply"}')),
      ]),
    );
    expect(
      plain.exchangeReceipts.single.text,
      '{"source":"an authored JSON reply"}',
    );
  });

  test('relay heading is omitted and authored whitespace survives copying', () {
    const reply = '  Reply with indentation\n\n';
    final plain = _call(_timeline([..._rows(), _notice(_envelope(reply))]));
    expect(plain.exchangeReceipts.single.text, reply);
    final relay = _call(
      _timeline([
        ..._rows(),
        _notice(
          _envelope(
            'Reply from @pace:\n$reply',
            command:
                'python3 /home/hermes/tools/bot_mode_dm.py --wait-reply /tmp/reply.json @pace 120',
          ),
        ),
      ]),
    );
    expect(relay.exchangeReceipts.single.text, reply);
    expect(relay.exchangeReceipts.single.raw, contains('Reply from @pace:'));
  });

  test('batch parsing preserves each exact envelope and reply line endings', () {
    final bot = _envelope('Reply with\r\noriginal line endings\r\n');
    final other = _envelope(
      'other output',
      process: 'proc_other',
      command: 'sleep 1',
    );
    final timeline = _timeline([
      ..._rows(),
      _notice(
        '[IMPORTANT: 2 background processes completed.]\r\n\r\n$bot\r\n\r\n$other',
      ),
    ]);
    final receipt = _call(timeline).exchangeReceipts.single;
    expect(receipt.raw, bot);
    expect(receipt.text, 'Reply with\r\noriginal line endings\r\n');
  });

  const capture = bool.fromEnvironment('CAPTURE_BOT_EXCHANGE');
  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'monospace': 'build/studio-mono.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(entry.value).readAsBytes().then((b) => b.buffer.asByteData()),
          ))
          .load();
    }
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('real activity appends one receipt ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 920);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final key = GlobalKey();
        var rows = _rows();
        late StateSetter update;
        await tester.pumpMarkdownWidget(
          MaterialApp(
            theme: wingTheme(Brightness.light),
            darkTheme: wingTheme(Brightness.dark),
            themeMode: brightness == Brightness.dark
                ? ThemeMode.dark
                : ThemeMode.light,
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                final timeline = _timeline(rows);
                return MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: Scaffold(
                    body: RepaintBoundary(
                      key: key,
                      child: ColoredBox(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                ProfileMessage(
                                  message: timeline.entries.first.message,
                                ),
                                ProfileMessage(
                                  message: timeline.entries[1].message,
                                ),
                                ProfileToolActivitySection(
                                  section: timeline.sections.firstWhere(
                                    (s) => s.isActivity,
                                  ),
                                ),
                                ProfileMessage(
                                  message: timeline.entries
                                      .firstWhere((e) => e.id == 8)
                                      .message,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.textContaining('Activity · 4 tools'));
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('Activity · 4 tools'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Message agent'));
        await tester.tap(find.text('Message agent'));
        await tester.pumpAndSettle();
        await tester.settleMarkdown();
        expect(find.byIcon(Icons.forum_outlined), findsOneWidget);
        expect(find.text('Queued'), findsOneWidget);
        expect(find.text('Exchange complete'), findsNothing);
        expect(find.byTooltip('Copy Message'), findsOneWidget);
        expect(find.byTooltip('Copy Queued'), findsOneWidget);
        final originalMessage = _call(
          _timeline(rows),
        ).activityDetails.request.single.text;
        update(() => rows = [...rows, _notice(_envelope(_settled()))]);
        await tester.pump();
        await tester.settleMarkdown();
        await tester.pumpAndSettle();
        expect(find.text('Queued'), findsOneWidget);
        expect(find.text('Exchange complete'), findsOneWidget);
        expect(find.byTooltip('Copy Exchange complete'), findsOneWidget);
        expect(find.text('Completed'), findsNothing);
        expect(find.text('Bot delivery process finished'), findsNothing);
        expect(
          _call(_timeline(rows)).activityDetails.request.single.text,
          originalMessage,
        );
        expect(tester.takeException(), isNull);
        final receipts = tester
            .widgetList<ActivityDetailSection>(
              find.byType(ActivityDetailSection),
            )
            .where((s) => s.block.label == 'Exchange complete');
        expect(receipts.single.block.copyText, _reply);
        await tester.ensureVisible(find.text('Exchange complete'));
        await tester.pumpAndSettle();
        if (capture) {
          await tester.runAsync(() async {
            final image =
                await (key.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
              'build/design-previews/bot-exchange-production/${brightness.name}-${scale.toInt()}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
        // Raw evidence remains selectable and exact, rather than replacing the
        // original queued output with the later notification.
        await tester.ensureVisible(find.text('Raw details'));
        await tester.tap(find.text('Raw details'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widgetList<ActivityDetailSection>(
                find.byType(ActivityDetailSection),
              )
              .any(
                (s) =>
                    s.block.label == 'Delivery notification' &&
                    s.block.text == _envelope(_settled()),
              ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Raw details'));
        await tester.pumpAndSettle();
        for (final sample in [
          ('short', _settled('Done.'), 0, 'Exchange complete'),
          ('empty', _settled(''), 0, 'Exchange complete'),
          (
            'pending',
            jsonEncode({
              'status': 'claimed',
              'delivery_id': 'delivery-1',
              'detail': 'The delivery is still pending. Do not resend.',
            }),
            0,
            'Exchange pending',
          ),
          (
            'failed',
            jsonEncode({
              'status': 'failed',
              'delivery_id': 'delivery-1',
              'error':
                  'Pace could not process this message. The target runtime stopped.',
            }),
            1,
            'Exchange failed',
          ),
          (
            'unknown',
            jsonEncode({
              'status': 'ambiguous',
              'delivery_id': 'delivery-1',
              'error': 'The delivery outcome is unknown. Do not resend.',
            }),
            1,
            'Exchange outcome unknown',
          ),
        ]) {
          update(
            () => rows = [
              ..._rows(),
              _notice(_envelope(sample.$2, exit: sample.$3)),
            ],
          );
          await tester.pump();
          await tester.settleMarkdown();
          await tester.pumpAndSettle();
          expect(find.text(sample.$4), findsOneWidget);
          await tester.ensureVisible(find.text(sample.$4));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (capture) {
            await tester.runAsync(() async {
              final image =
                  await (key.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                'build/design-previews/bot-exchange-production/${brightness.name}-${scale.toInt()}-${sample.$1}.png',
              ).writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            });
          }
        }
      });
    }
  }
}

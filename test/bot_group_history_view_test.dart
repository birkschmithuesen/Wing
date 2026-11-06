import 'package:wing/core/widgets/profile_live_work_dock.dart';
import 'package:wing/core/widgets/profile_live_execution.dart';
import 'package:wing/core/widgets/profile_execution_activity.dart';
import 'package:wing/core/widgets/profile_activity_status.dart';
import 'package:wing/core/widgets/profile_subagent_panel.dart';
import 'package:wing/core/widgets/subagent_timeline.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/bots_preferences.dart';
import 'package:wing/core/models/voice_processing_settings.dart';
import 'package:wing/core/services/bot_group_read_state.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/bots/bot_group_screen.dart';
import 'package:wing/core/screens/bots/bot_group_history_screen.dart';
import 'package:wing/core/screens/profile_transcript.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/services/bot_group_session.dart';
import 'package:wing/core/services/bot_group_history_session.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'dart:async';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/background_markdown_content.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'support/bots_fixture.dart';
import 'helpers/pump_markdown_widget.dart';

const _capture = bool.fromEnvironment('CAPTURE_BOT_GROUPS');

Future<void> _settle(WidgetTester tester) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    // Resume placement waits for background Markdown. Give that real worker
    // time before expecting frame animations to settle.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    if (!tester
            .stateList<BackgroundMarkdownContentState>(
              find.byType(BackgroundMarkdownContent, skipOffstage: false),
            )
            .any((state) => state.pending) &&
        !tester.binding.hasScheduledFrame) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  fail('Working history Markdown did not settle');
}

Future<void> _render(WidgetTester tester, GlobalKey frame, String name) async {
  if (!_capture) return;
  await tester.runAsync(() async {
    final boundary =
        frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/design-previews/bot-groups/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  late BotsPreferences groupPreferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    groupPreferences = await BotsPreferences.load();
  });
  setUpAll(() async {
    if (!_capture) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'monospace': 'build/studio-mono.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            Future.value(
              ByteData.sublistView(await File(entry.value).readAsBytes()),
            ),
          ))
          .load();
    }
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('history renders messages before backfill and folds live replay '
          '${brightness.name} $scale', (tester) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        Future<void> entryFrames() async {
          for (var i = 0; i < 16; i++) {
            await tester.pump(const Duration(milliseconds: 30));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
        }

        final fixture = BotsFixture();
        final group = (await readFixtureGroups(
          fixture.repository,
          groupMessages: null,
        )).single;
        fixture.workerRows['atlas'] = [
          {
            'id': 'atlas-root',
            'resolved_id': 'atlas-tip',
            'title': 'Group: room-1',
            'source': 'bot_room',
          },
        ];
        final older = Completer<ProfileHistoryPage>();
        final replay = Completer<void>();
        addTearDown(() {
          if (!older.isCompleted) {
            older.completeError(StateError('Retired history'));
          }
          if (!replay.isCompleted) replay.complete();
        });
        fixture.historyHook = (_, id, offset) async => offset == 0
            ? ProfileHistoryPage(
                id,
                [
                  {
                    'id': 101,
                    'role': 'user',
                    'content': 'The conversation is already readable.',
                  },
                  for (var id = 102; id <= 120; id++)
                    {'id': id, 'role': 'tool', 'content': 'Saved tool receipt'},
                ],
                0,
                20,
              )
            : older.future;
        final events = <Map<String, dynamic>>[];
        void event(String type, Map<String, dynamic> payload) => events.add({
          'type': type,
          'payload': stockWorkerReply(events, type, payload),
          'session_id': 'atlas-live',
          'seq': events.length + 1,
        });
        event('message.start', {});
        event('reasoning.delta', {'text': '**Live reasoning stays split.**'});
        for (var id = 0; id < 80; id++) {
          event('tool.complete', {
            'tool_id': 'call-$id',
            'name': 'read_file',
            'args': {'path': 'file-$id.txt'},
            'result': 'Read complete',
          });
        }
        var replayStarted = false;
        fixture.readHook = (_, method, params) async {
          if (method == 'session.active_list') {
            return {
              'sessions': [
                {
                  'id': 'atlas-live',
                  'session_key': 'atlas-tip',
                  'title': 'Group: room-1',
                  'status': 'working',
                },
              ],
            };
          }
          if (method == 'session.resume') {
            return BotsFixture.passiveSnapshot(
              params,
              epoch: 'entry-test',
              sequence: events.length,
            );
          }
          if (method == 'session.events.since') {
            expect(params['replay_epoch'], 'entry-test');
            replayStarted = true;
            await replay.future;
            return {
              'events': events
                  .where(
                    (e) => (e['seq'] as int) > (params['last_sequence'] as int),
                  )
                  .toList(),
              'latest_seq': events.length,
              'truncated': false,
              'snapshot_required': false,
              'replay_epoch': 'entry-test',
              'open_requests': [],
            };
          }
          return null;
        };
        final frame = GlobalKey();
        late BotGroupHistorySession session;
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
            home: BotGroupHistoryScreen(
              appearanceForMember: (_) => null,
              createSession: () =>
                  session = BotGroupHistorySession(fixture.repository, group),
            ),
          ),
        );
        await entryFrames();
        expect(older.isCompleted, isFalse);
        expect(
          replayStarted,
          isTrue,
          reason:
              'Live hydration starts after the first readable frame, independently of older history.',
        );
        expect(
          find.textContaining(
            'The conversation is already readable.',
            findRichText: true,
          ),
          findsWidgets,
        );
        expect(find.byType(ProfileExecutionActivity), findsNothing);
        await _render(
          tester,
          frame,
          'history-entry-backfill-${brightness.name}-$scale',
        );
        older.complete(ProfileHistoryPage('atlas-tip', const [], 20, 20));
        await entryFrames();
        expect(replayStarted, isTrue);
        expect(
          find.textContaining(
            'The conversation is already readable.',
            findRichText: true,
          ),
          findsWidgets,
        );
        await _render(
          tester,
          frame,
          'history-entry-live-held-${brightness.name}-$scale',
        );
        replay.complete();
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 30));
        }
        await tester.settleMarkdown();
        expect(session.runtime.activityEntries, hasLength(81));
        expect(
          find.text('Live reasoning stays split.', findRichText: true),
          findsOneWidget,
        );
        expect(find.text('Activity · 19 tools'), findsOneWidget);
        expect(find.text('Activity · 80 tools'), findsOneWidget);
        expect(find.text('Timeline'), findsNothing);
        expect(
          find.byType(ProfileExecutionActivity, skipOffstage: false),
          findsNothing,
          reason:
              'Closed activity must not construct or lay out the 80 replayed tool rows.',
        );
        final retainedAnswer = find.textContaining(
          'The conversation is already readable.',
          findRichText: true,
        );
        // Live prose can push the earlier answer beyond a small lazy viewport.
        // Read it through the real scroll before returning to the live tail.
        await tester.scrollUntilVisible(
          retainedAnswer,
          200,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('profile-transcript')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.settleMarkdown();
        expect(retainedAnswer, findsWidgets);
        final latest = find.byKey(const ValueKey('jump-to-latest'));
        if (latest.evaluate().isNotEmpty) {
          await tester.tap(latest);
          await entryFrames();
          await tester.settleMarkdown();
        }
        await _render(
          tester,
          frame,
          'history-entry-live-collapsed-${brightness.name}-$scale',
        );
        final section = find.ancestor(
          of: find.text('Activity · 80 tools'),
          matching: find.byType(ProfileActivitySection),
        );
        await tester.ensureVisible(find.text('Activity · 80 tools'));
        await entryFrames();
        expect(find.text('Activity · 80 tools').hitTestable(), findsOneWidget);
        await tester.tap(find.text('Activity · 80 tools'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.descendant(of: section, matching: find.text('Timeline')),
          findsWidgets,
        );
        expect(find.byType(ProfileExecutionActivity), findsWidgets);
        await tester.ensureVisible(find.text('Activity · 80 tools'));
        await tester.pump();
        await tester.tap(find.text('Activity · 80 tools'));
        await tester.pump(const Duration(milliseconds: 300));
        event('tool.complete', {
          'tool_id': 'later',
          'name': 'read_file',
          'result': 'Later receipt',
        });
        await session.refreshLive();
        await tester.pump(const Duration(milliseconds: 30));
        expect(find.text('Activity · 81 tools'), findsOneWidget);
        expect(find.text('Timeline'), findsNothing);
        expect(fixture.commands, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('fresh tool-only tail still shows recent messages '
          '${brightness.name} $scale', (tester) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = BotsFixture();
        final group = (await readFixtureGroups(
          fixture.repository,
          groupMessages: null,
        )).single;
        fixture.workerRows['atlas'] = [
          {
            'id': 'atlas-root',
            'resolved_id': 'atlas-tip',
            'title': 'Group: room-1',
            'source': 'bot_room',
          },
        ];
        fixture.workerMessages['atlas'] = [
          for (var id = 1; id <= 25; id++)
            {
              'id': id,
              'role': 'assistant',
              'content': 'Atlas saved answer $id',
              'timestamp': 1791756000.0 + id,
            },
          for (var id = 26; id <= 45; id++)
            id.isEven
                ? {'id': id, 'role': 'assistant', 'content': ''}
                : {
                    'id': id,
                    'role': 'tool',
                    'content': 'Tool output $id',
                    'tool_name': 'terminal',
                  },
        ];
        final frame = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: scale == 2,
              ),
              child: RepaintBoundary(key: frame, child: child!),
            ),
            home: BotGroupHistoryScreen(
              appearanceForMember: (_) => null,
              createSession: () =>
                  BotGroupHistorySession(fixture.repository, group),
            ),
          ),
        );
        await _settle(tester);
        final latest = find.textContaining(
          'Atlas saved answer 25',
          findRichText: true,
        );
        expect(latest, findsWidgets);
        final viewport = tester.getRect(find.byType(ProfileTranscript));
        expect(tester.getRect(latest.first).overlaps(viewport), isTrue);
        expect(find.text('Activity · 10 tools'), findsOneWidget);
        expect(find.byType(StudioLoading), findsNothing);
        expect(fixture.historyReads.map((read) => read.$3), [0, 20]);
        expect(fixture.commands, isEmpty);
        expect(tester.takeException(), isNull);
        await _render(
          tester,
          frame,
          'history-tool-tail-${brightness.name}-$scale',
        );
        final backfill = Completer<ProfileHistoryPage>();
        addTearDown(() {
          if (!backfill.isCompleted) {
            backfill.completeError(StateError('Retired backfill'));
          }
        });
        fixture.historyHook = (_, id, offset) async {
          if (offset == 20) return backfill.future;
          return ProfileHistoryPage(
            id,
            fixture.workerMessages['atlas']!.sublist(25),
            offset,
            20,
          );
        };
        await tester.tap(find.byTooltip('Refresh working history'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(fixture.historyReads.last.$3, 20);
        expect(
          find.bySemanticsLabel('Refreshing working history'),
          findsOneWidget,
        );
        expect(find.byType(StudioLoading), findsOneWidget);
        expect(latest, findsWidgets);
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.refresh),
              )
              .onPressed,
          isNull,
        );
        backfill.completeError(StateError('Offline backfill'));
        await _settle(tester);
        expect(find.byType(StudioLoading), findsNothing);
        expect(latest, findsWidgets);
        expect(
          find.text('Working history could not load. Refresh to try again.'),
          findsOneWidget,
        );
        fixture.historyHook = null;
        await tester.tap(find.byTooltip('Refresh working history'));
        await _settle(tester);
        expect(latest, findsWidgets);
        expect(find.byType(StudioLoading), findsNothing);
        expect(
          find.text('Working history could not load. Refresh to try again.'),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets(
        'working history shares live chat activity ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          Future<void> liveFrames() async {
            for (var i = 0; i < 12; i++) {
              await tester.pump(const Duration(milliseconds: 50));
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
            }
          }

          final fixture = BotsFixture();
          final group = (await readFixtureGroups(
            fixture.repository,
            groupMessages: null,
          )).single;
          fixture.workerRows['atlas'] = [
            {
              'id': 'atlas-root',
              'resolved_id': 'atlas-tip',
              'title': 'Group: room-1',
              'source': 'bot_room',
            },
          ];
          fixture.workerMessages['atlas'] = [
            {
              'id': 1,
              'role': 'user',
              'content': 'Build the shared work viewer',
              'timestamp': 1791756000.0,
            },
          ];
          final events = <Map<String, dynamic>>[];
          void event(String type, Map<String, dynamic> payload) => events.add({
            'type': type,
            'payload': stockWorkerReply(events, type, payload),
            'session_id': 'atlas-live',
            'seq': events.length + 1,
          });
          event('message.start', {});
          event('reasoning.delta', {
            'text':
                '**Inspecting the work**\n\nReasoning stays visible while the bot streams.',
          });
          event('todo.updated', {
            'revision': 1,
            'todos': [
              {
                'id': '1',
                'content': 'Inspect the transcript',
                'status': 'in_progress',
              },
              {'id': '2', 'content': 'Verify the result', 'status': 'pending'},
            ],
          });
          event('subagent.start', {
            'subagent_id': 'child-1',
            'child_session_id': 'child-session',
            'goal': 'Check received events',
            'status': 'running',
          });
          final childMount = Completer<void>();
          addTearDown(() {
            if (!childMount.isCompleted) childMount.complete();
          });
          var failChildReplay = false;
          var childReads = 0;
          fixture.historyHook = (profile, id, offset) async {
            if (id == 'child-session') {
              return ProfileHistoryPage(
                id,
                [
                  {
                    'id': 100,
                    'role': 'user',
                    'content': 'Check received events',
                  },
                  {
                    'id': 101,
                    'role': 'assistant',
                    'content': 'Inspecting the child transcript.',
                  },
                ],
                offset,
                20,
                isComplete: true,
              );
            }
            return ProfileHistoryPage(
              id,
              fixture.workerMessages[profile] ?? [],
              offset,
              20,
            );
          };
          final childEvents = [
            {
              'seq': 1,
              'session_id': 'child-session',
              'type': 'message.start',
              'payload': <String, dynamic>{},
            },
            {
              'seq': 2,
              'session_id': 'child-session',
              'type': 'reasoning.delta',
              'payload': {'text': 'Checking child tool events'},
            },
            {
              'seq': 3,
              'session_id': 'child-session',
              'type': 'tool.start',
              'payload': {
                'tool_id': 'submirror:child:1',
                'name': 'terminal',
                'args': <String, dynamic>{},
                'preview': 'pytest -q tests/events',
              },
            },
          ];
          var working = true;
          fixture.readHook = (profile, method, params) async {
            if (method == 'session.resume' &&
                params['session_id'] == 'child-session') {
              expect(params, {
                'session_id': 'child-session',
                'display_projection': true,
              });
              await childMount.future;
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
              childReads++;
              if (failChildReplay) throw StateError('Child disconnected');
              return {
                'replay_epoch': 'child-epoch',
                'events': childEvents,
                'latest_seq': childEvents.length,
                'truncated': false,
                'snapshot_required': false,
                'open_requests': [],
              };
            }
            return switch (method) {
              'session.active_list' => {
                'sessions': [
                  {
                    'id': 'atlas-live',
                    'session_key': 'atlas-tip',
                    'title': 'Group: room-1',
                    'status': working ? 'working' : 'idle',
                  },
                ],
              },
              'session.events.since' => {
                'events': events
                    .where(
                      (e) =>
                          (e['seq'] as int) > (params['last_sequence'] as int),
                    )
                    .toList(),
                'latest_seq': events.length,
                'truncated': false,
                'snapshot_required': false,
                'replay_epoch': 'test',
                'open_requests': [],
              },
              _ => null,
            };
          };
          late BotGroupHistorySession session;
          final frame = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: scale == 2,
                ),
                child: RepaintBoundary(key: frame, child: child!),
              ),
              home: BotGroupHistoryScreen(
                appearanceForMember: (_) => null,
                createSession: () =>
                    session = BotGroupHistorySession(fixture.repository, group),
              ),
            ),
          );
          // Bound pumps keep live Wing animation running.
          for (var i = 0; i < 12; i++) {
            await tester.pump(const Duration(milliseconds: 50));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          final sharedTranscript = tester.widget<ProfileTranscript>(
            find.byType(ProfileTranscript),
          );
          expect(sharedTranscript.activity?.inspection, same(session));
          expect(sharedTranscript.activity?.live, isTrue);
          expect(find.byType(ProfileLiveExecution), findsOneWidget);
          expect(find.byType(ProfileLiveWorkDock), findsOneWidget);
          expect(
            tester
                .widget<ProfileActivityStatus>(
                  find.byType(ProfileActivityStatus),
                )
                .label,
            'Thinking… · 1 subagent active',
          );
          expect(find.byType(ProfileActivitySection), findsNothing);
          expect(find.text('Thinking'), findsOneWidget);
          await tester.settleMarkdown();
          final refreshGate = Completer<void>();
          addTearDown(() {
            if (!refreshGate.isCompleted) refreshGate.complete();
          });
          final liveRead = fixture.readHook!;
          fixture.readHook = (profile, method, params) async {
            if (method == 'session.list') await refreshGate.future;
            return liveRead(profile, method, params);
          };
          await tester.tap(find.byTooltip('Refresh working history'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          final headerPulse = find.descendant(
            of: find.byType(StudioLoadingSlot),
            matching: find.byType(StudioLoading),
          );
          expect(headerPulse, findsOneWidget);
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(find.byIcon(Icons.refresh), findsOneWidget);
          expect(
            tester.widget<StudioLoading>(headerPulse).label,
            'Refreshing working history',
          );
          await _render(
            tester,
            frame,
            'history-working-refresh-${brightness.name}-$scale',
          );
          refreshGate.complete();
          for (var i = 0; i < 12; i++) {
            await tester.pump(const Duration(milliseconds: 50));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          expect(headerPulse, findsNothing);
          expect(find.byType(StudioLoading), findsOneWidget);
          fixture.readHook = liveRead;
          expect(
            find.textContaining('Inspecting the work', findRichText: true),
            findsWidgets,
          );
          expect(find.byType(StudioWorkingIndicator), findsWidgets);
          await liveFrames();
          final reasoning = find
              .textContaining(
                'Reasoning stays visible while the bot streams.',
                findRichText: true,
              )
              .first;
          await tester.ensureVisible(reasoning);
          await liveFrames();
          final viewport = tester.getRect(find.byType(ProfileTranscript));
          expect(
            tester.getRect(reasoning).overlaps(viewport),
            isTrue,
            reason:
                'Live reasoning must be readable without opening a disclosure.',
          );
          await _render(
            tester,
            frame,
            'history-live-${brightness.name}-$scale',
          );
          await tester.tap(
            find.byKey(const ValueKey(('live-work-tab', 1, false))),
          );
          await tester.pump(const Duration(milliseconds: 300));
          for (var i = 0; i < 10; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 30));
          }
          expect(
            find.textContaining('Inspect the transcript', findRichText: true),
            findsWidgets,
          );
          await liveFrames();
          await _render(
            tester,
            frame,
            'history-live-tasks-${brightness.name}-$scale',
          );
          await tester.tap(
            find.byKey(const ValueKey(('live-work-tab', 0, true))),
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(ProfileSubagentPanel), findsOneWidget);
          expect(find.text('Check received events'), findsOneWidget);
          await liveFrames();
          await _render(
            tester,
            frame,
            'history-live-agents-${brightness.name}-$scale',
          );
          await tester.binding.handlePopRoute();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(PageView), findsNothing);
          expect(find.byType(BotGroupHistoryScreen), findsOneWidget);
          await tester.tap(
            find.byKey(const ValueKey(('live-work-tab', 0, false))),
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.text('Check received events').hitTestable());
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('Subagent activity'), findsOneWidget);
          expect(find.byType(ProfileTranscript), findsNWidgets(2));
          await liveFrames();
          expect(find.byTooltip('Loading subagent activity'), findsOneWidget);
          await _render(
            tester,
            frame,
            'subagent-opening-${brightness.name}-$scale',
          );
          childMount.complete();
          await liveFrames();
          expect(find.text('Task'), findsOneWidget);
          expect(find.byTooltip('Interrupt'), findsNothing);
          expect(find.byTooltip('Steer'), findsNothing);
          expect(find.byType(TextField), findsNothing);
          expect(childReads, greaterThan(0));
          final childView = find.byType(SubagentTimeline);
          final childSession = tester
              .widget<SubagentTimeline>(childView)
              .session;
          expect(
            childSession.runtime.toolActivities.single.context,
            'pytest -q tests/events',
          );
          final childActivity = find.descendant(
            of: childView,
            matching: find.text('Activity · 1 tool'),
          );
          await tester.ensureVisible(childActivity);
          await tester.tap(childActivity);
          await liveFrames();
          expect(
            find.descendant(
              of: childView,
              matching: find.byType(ProfileExecutionActivity),
            ),
            findsWidgets,
          );
          await _render(
            tester,
            frame,
            'subagent-timeline-${brightness.name}-$scale',
          );
          final toolTitle = find.descendant(
            of: childView,
            matching: find.text('Running command'),
          );
          await tester.ensureVisible(toolTitle);
          await liveFrames();
          await tester.tap(toolTitle.hitTestable());
          await liveFrames();
          await _render(
            tester,
            frame,
            'subagent-tool-${brightness.name}-$scale',
          );
          failChildReplay = true;
          await tester.tap(find.byTooltip('Refresh subagent activity'));
          await liveFrames();
          expect(
            find.text(
              'Subagent activity could not refresh. Retry to continue.',
            ),
            findsWidgets,
          );
          await _render(
            tester,
            frame,
            'subagent-failed-${brightness.name}-$scale',
          );
          failChildReplay = false;
          await tester.tap(find.byTooltip('Retry subagent activity'));
          await liveFrames();
          expect(
            find.text(
              'Subagent activity could not refresh. Retry to continue.',
            ),
            findsNothing,
          );
          expect(session.reader.historySessionId, 'atlas-tip');
          final readsBeforeClose = childReads;
          Navigator.of(tester.element(find.text('Task'))).pop();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump(const Duration(seconds: 4));
          expect(childReads, readsBeforeClose);
          await tester.binding.handlePopRoute();
          await tester.pump(const Duration(milliseconds: 300));
          event('tool.start', {
            'tool_id': 'read-1',
            'name': 'read_file',
            'args': {'path': 'README.md'},
          });
          event('reasoning.delta', {'text': 'A separate reasoning segment.'});
          await session.refreshLive();
          await tester.pump(const Duration(milliseconds: 100));
          expect(session.runtime.activityEntries, hasLength(3));
          await liveFrames();
          await _render(
            tester,
            frame,
            'history-live-split-${brightness.name}-$scale',
          );
          event('tool.complete', {
            'tool_id': 'read-1',
            'name': 'read_file',
            'result': 'Read complete',
          });
          event('message.complete', {'text': 'The shared result is ready.'});
          working = false;
          fixture.workerMessages['atlas'] = [
            ...fixture.workerMessages['atlas']!,
            {
              'id': 2,
              'role': 'assistant',
              'content': 'The shared result is ready.',
              'timestamp': 1791756001.0,
            },
          ];
          await session.refreshLive();
          await liveFrames();
          expect(
            tester
                .widget<ProfileActivityStatus>(
                  find.byType(ProfileActivityStatus),
                )
                .label,
            'Waiting for 1 subagent…',
          );
          expect(find.byType(ProfileLiveWorkDock), findsOneWidget);
          expect(
            find.byKey(const ValueKey(('activity-tab', 'tasks'))),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey(('activity-tab', 'agents'))),
            findsNothing,
          );
          await tester.tap(
            find.byKey(const ValueKey(('live-work-tab', 1, false))),
          );
          await liveFrames();
          expect(
            find.textContaining('Inspect the transcript', findRichText: true),
            findsWidgets,
          );
          await _render(
            tester,
            frame,
            'history-waiting-dock-${brightness.name}-$scale',
          );
          await tester.binding.handlePopRoute();
          await liveFrames();
          event('subagent.complete', {
            'subagent_id': 'child-1',
            'status': 'completed',
            'summary': 'Events verified',
          });
          await session.refreshLive();
          await _settle(tester);
          final latest = find.byKey(const ValueKey('jump-to-latest'));
          if (latest.evaluate().isNotEmpty) {
            await tester.tap(latest);
            await _settle(tester);
          }
          expect(find.byType(ProfileLiveWorkDock), findsOneWidget);
          expect(
            find.byKey(const ValueKey(('activity-tab', 'tasks'))),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey(('activity-tab', 'agents'))),
            findsNothing,
          );
          expect(
            find.textContaining(
              'The shared result is ready.',
              findRichText: true,
            ),
            findsWidgets,
          );
          expect(fixture.commands, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );

      testWidgets('long working history opens at the tail and refresh settles '
          '${brightness.name} $scale', (tester) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = BotsFixture();
        final group = (await readFixtureGroups(
          fixture.repository,
          groupMessages: null,
        )).single;
        for (final member in group.members) {
          fixture.workerRows[member.profile] = [
            {
              'id': '${member.profile}-root',
              'resolved_id': '${member.profile}-tip',
              'title': 'Group: room-1',
              'source': 'bot_room',
            },
          ];
          fixture.workerMessages[member.profile] = [
            for (var id = 1; id <= 200; id++)
              {
                'id': id,
                'role': 'assistant',
                'content': '${member.name} saved $id',
                'timestamp': 1791756000.0 + id,
              },
          ];
        }
        late BotGroupHistorySession session;
        final frame = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            debugShowCheckedModeBanner: false,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: scale == 2,
              ),
              child: RepaintBoundary(key: frame, child: child!),
            ),
            home: BotGroupHistoryScreen(
              appearanceForMember: (_) => null,
              createSession: () =>
                  session = BotGroupHistorySession(fixture.repository, group),
            ),
          ),
        );
        await _settle(tester);
        expect(session.reader.messages, hasLength(20));
        expect(session.reader.messages.first['id'], 181);
        expect(fixture.historyReads.single, ('atlas', 'atlas-tip', 0));
        expect(
          find.textContaining('Atlas saved 200', findRichText: true),
          findsWidgets,
        );
        expect(find.text('Atlas saved 1', findRichText: true), findsNothing);
        expect(
          find.byType(ProfileMessage).evaluate().length,
          lessThan(session.reader.messages.length),
          reason: 'Offscreen history remains lazily built.',
        );
        final memberBounds = tester.getRect(
          find.widgetWithText(ChoiceChip, 'Mira'),
        );
        final transcriptBounds = tester.getRect(find.byType(ProfileTranscript));
        final registry = Completer<void>();
        final page = Completer<ProfileHistoryPage>();
        addTearDown(() {
          if (!registry.isCompleted) registry.complete();
          if (!page.isCompleted) {
            page.completeError(StateError('Retired test read'));
          }
        });
        var registryReads = 0;
        fixture.readHook = (_, method, _) async {
          if (method == 'session.list') {
            registryReads++;
            await registry.future;
          }
          return null;
        };
        fixture.historyHook = (_, _, _) => page.future;
        await tester.tap(find.byTooltip('Refresh working history'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(StudioLoading), findsOneWidget);
        expect(
          find.bySemanticsLabel('Refreshing working history'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.refresh),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester.getRect(find.widgetWithText(ChoiceChip, 'Mira')),
          memberBounds,
        );
        expect(
          tester.getRect(find.byType(ProfileTranscript)),
          transcriptBounds,
        );
        expect(
          find.textContaining('Atlas saved 200', findRichText: true),
          findsWidgets,
        );
        expect(registryReads, 1);
        await _render(
          tester,
          frame,
          'history-populated-refresh-${brightness.name}-$scale',
        );
        registry.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(fixture.historyReads.length, 2);
        expect(find.byType(StudioLoading), findsOneWidget);
        page.completeError(StateError('Offline'));
        await _settle(tester);
        expect(find.byType(StudioLoading), findsNothing);
        expect(session.reader.historyError, isNotNull);
        expect(session.reader.messages.last['id'], 200);
        expect(
          find.text('Working history could not load. Refresh to try again.'),
          findsOneWidget,
        );
        await _render(
          tester,
          frame,
          'history-populated-failed-${brightness.name}-$scale',
        );
        if (scale == 2) {
          await tester.pump(const Duration(seconds: 5));
          await _settle(tester);
        }
        fixture.readHook = null;
        fixture.historyHook = null;
        await tester.tap(find.byTooltip('Refresh working history'));
        await _settle(tester);
        expect(session.reader.historyError, isNull);
        expect(find.byType(StudioLoading), findsNothing);
        expect(
          find.text('Working history could not load. Refresh to try again.'),
          findsNothing,
        );
        final scroll = tester
            .widget<ListView>(find.byKey(const ValueKey('profile-transcript')))
            .controller!;
        scroll.jumpTo(120);
        await _settle(tester);
        final savedPosition = session.reader.readingPosition.resume!;
        await tester.tap(find.widgetWithText(ChoiceChip, 'Mira'));
        await _settle(tester);
        final reads = fixture.historyReads.length;
        await tester.tap(find.widgetWithText(ChoiceChip, 'Atlas'));
        await _settle(tester);
        expect(fixture.historyReads.length, reads);
        expect(session.reader.messages.last['id'], 200);
        expect(
          session.reader.readingPosition.resume?.messageId,
          savedPosition.messageId,
        );
        expect(
          session.reader.readingPosition.resume?.fraction,
          closeTo(savedPosition.fraction, .01),
        );
        expect(
          find.textContaining(
            'Atlas saved ${savedPosition.messageId}',
            findRichText: true,
          ),
          findsWidgets,
        );
        expect(fixture.commands, isEmpty);
        expect(tester.takeException(), isNull);
        await _render(
          tester,
          frame,
          'history-cached-${brightness.name}-$scale',
        );
        await tester.pumpWidget(const SizedBox());
      });

      for (final absentWorker in [true, false]) {
        testWidgets('empty working history refresh keeps visible feedback '
            '${absentWorker ? 'absent worker' : 'empty page'} '
            '${brightness.name} $scale', (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = BotsFixture();
          final group = (await readFixtureGroups(
            fixture.repository,
            groupMessages: null,
          )).single;
          final worker = {
            'id': 'atlas-root',
            'resolved_id': 'atlas-tip',
            'title': 'Group: room-1',
            'source': 'bot_room',
          };
          if (!absentWorker) fixture.workerRows['atlas'] = [worker];
          final initial = Completer<void>();
          final refreshed = Completer<void>();
          addTearDown(() {
            if (!initial.isCompleted) initial.complete();
            if (!refreshed.isCompleted) refreshed.complete();
          });
          var reads = 0;
          fixture.readHook = (profile, method, _) async {
            if (profile == 'atlas' && method == 'session.list') {
              reads++;
              await (reads == 1 ? initial.future : refreshed.future);
            }
            return null;
          };
          final frame = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              debugShowCheckedModeBanner: false,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: frame, child: child!),
              ),
              home: BotGroupHistoryScreen(
                appearanceForMember: (_) => null,
                createSession: () =>
                    BotGroupHistorySession(fixture.repository, group),
              ),
            ),
          );
          await tester.pump();
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(
            find.bySemanticsLabel('Loading working history'),
            findsOneWidget,
          );
          initial.complete();
          await _settle(tester);
          final empty = find.text('No working history is available for Atlas.');
          expect(empty, findsOneWidget);
          final emptyBounds = tester.getRect(empty);
          final memberBounds = tester.getRect(
            find.widgetWithText(ChoiceChip, 'Mira'),
          );
          fixture.workerRows['atlas'] = [worker];
          fixture.workerMessages['atlas'] = [
            {
              'id': 1,
              'role': 'assistant',
              'content': 'Refresh loaded new working history.',
              'timestamp': 1791756000.0,
            },
          ];
          await tester.tap(find.byTooltip('Refresh working history'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          expect(reads, 2);
          expect(empty, findsOneWidget);
          expect(tester.getRect(empty), emptyBounds);
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(
            find.bySemanticsLabel('Refreshing working history'),
            findsOneWidget,
          );
          final member = find.widgetWithText(ChoiceChip, 'Mira');
          expect(tester.widget<ChoiceChip>(member).onSelected, isNotNull);
          expect(tester.getRect(member), memberBounds);
          await _render(
            tester,
            frame,
            'history-empty-refresh-${absentWorker ? 'absent' : 'page'}-'
            '${brightness.name}-$scale',
          );
          refreshed.complete();
          await _settle(tester);
          expect(empty, findsNothing);
          expect(
            find.textContaining(
              'Refresh loaded new working history.',
              findRichText: true,
            ),
            findsWidgets,
          );
          expect(fixture.commands, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }

      testWidgets(
        'group overflow opens passive history ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final fixture = BotsFixture();
          var groupReads = 0;
          fixture.readHook = (_, method, _) async {
            if (method == 'groups.state') groupReads++;
            return null;
          };
          fixture.workerRows['atlas'] = [
            {
              'id': 'atlas-root',
              'resolved_id': 'atlas-tip',
              'title': 'Group: room-1',
              'source': 'bot_room',
            },
          ];
          fixture.workerMessages['atlas'] = [
            {
              'id': 1,
              'role': 'user',
              'content': 'Check the sources for our shared plan.',
              'timestamp': 1791756000.0,
            },
            {
              'id': 2,
              'role': 'assistant',
              'reasoning_content':
                  'Inspect the delivered sources before drawing a conclusion.',
              'content':
                  '**Source review**\n\n- Read the project mission\n- Checked the evidence\n\nThe proposed changes are ready for discussion.',
              'timestamp': 1791756060.0,
            },
          ];
          final group = (await readFixtureGroups(
            fixture.repository,
            groupMessages: null,
          )).single;
          final appearances = await fixture.repository.bots();
          final frame = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              debugShowCheckedModeBanner: false,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: frame, child: child!),
              ),
              home: BotGroupScreen(
                stopVoicePlayback: () async {},
                voiceInputSettings: () =>
                    const LocalVoiceInputSettings(language: ''),
                createSession: () => BotGroupSession(
                  fixture.repository,
                  group,
                  reads: BotGroupReadState(),
                  preferences: groupPreferences,
                  groupMessages: null,
                  appearances: FixedGroupAppearances(appearances),
                ),
              ),
            ),
          );
          await _settle(tester);
          expect(tester.takeException(), isNull, reason: 'Initial group');
          await tester.enterText(find.byType(TextField), 'My group draft');
          await tester.tap(find.byTooltip('Group options'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'Group menu');
          await _render(
            tester,
            frame,
            'history-menu-${brightness.name}-$scale',
          );
          await tester.tap(find.text('Bot working histories'));
          await _settle(tester);
          expect(tester.takeException(), isNull, reason: 'Read-only history');
          expect(find.byType(BotGroupHistoryScreen), findsOneWidget);
          expect(find.byType(ProfileTranscript), findsOneWidget);
          final transcript = tester
              .widget<ListView>(
                find.byKey(const ValueKey('profile-transcript')),
              )
              .controller!;
          transcript.jumpTo(transcript.position.maxScrollExtent);
          await _settle(tester);
          for (
            var step = 0;
            step < 20 &&
                find.byType(ProfileToolActivitySection).evaluate().isEmpty &&
                transcript.offset > 0;
            step++
          ) {
            transcript.jumpTo(
              (transcript.offset - 200).clamp(
                0,
                transcript.position.maxScrollExtent,
              ),
            );
            await _settle(tester);
          }
          expect(find.byType(ProfileToolActivitySection), findsWidgets);
          transcript.jumpTo(0);
          await _settle(tester);
          final shared = tester.widget<ProfileTranscript>(
            find.byType(ProfileTranscript),
          );
          expect(shared.notificationReading, isNull);
          expect(shared.onAnswerRead, isNull);
          expect(shared.openingContent, isNull);
          expect(find.byType(TextField), findsNothing);
          expect(
            find.text('Read only · This bot’s internal conversation'),
            findsOneWidget,
          );
          expect(fixture.historyReads.single, ('atlas', 'atlas-tip', 0));
          expect(
            find.textContaining('Source review', findRichText: true),
            findsWidgets,
          );
          expect(fixture.commands, isEmpty);
          if (scale == 1) {
            final avatar = tester.getRect(
              find.byKey(
                const ValueKey<(String, Object?)>((
                  'bot-message-avatar-frame',
                  2,
                )),
              ),
            );
            final activity = tester.getRect(
              find.byType(ProfileToolActivitySection).first,
            );
            expect(avatar.top, greaterThanOrEqualTo(activity.bottom));
          }
          await _render(tester, frame, 'history-${brightness.name}-$scale');
          final readsBeforeResume = groupReads;
          for (final state in [
            AppLifecycleState.inactive,
            AppLifecycleState.hidden,
            AppLifecycleState.paused,
            AppLifecycleState.hidden,
            AppLifecycleState.inactive,
            AppLifecycleState.resumed,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
          }
          await tester.pump(const Duration(seconds: 4));
          await _settle(tester);
          expect(
            groupReads,
            readsBeforeResume,
            reason: 'Covered group polling stays paused',
          );
          await tester.tap(find.widgetWithText(ChoiceChip, 'Mira'));
          await _settle(tester);
          expect(tester.takeException(), isNull, reason: 'Absent history');
          expect(
            find.text('No working history is available for Mira.'),
            findsOneWidget,
          );
          await _render(
            tester,
            frame,
            'history-empty-${brightness.name}-$scale',
          );
          fixture.readHook = (profile, method, params) async {
            if (method == 'session.list') throw StateError('Offline');
            return null;
          };
          await tester.tap(find.byTooltip('Refresh working history'));
          await _settle(tester);
          expect(tester.takeException(), isNull, reason: 'Failed history');
          expect(
            find.text('Working history could not load. Refresh to try again.'),
            findsOneWidget,
          );
          await _render(
            tester,
            frame,
            'history-error-${brightness.name}-$scale',
          );
          fixture.readHook = null;
          await tester.tap(find.byTooltip('Refresh working history'));
          await _settle(tester);
          expect(
            find.text('Working history could not load. Refresh to try again.'),
            findsNothing,
          );
          await tester.pageBack();
          await _settle(tester);
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            'My group draft',
          );
          expect(fixture.commands, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}

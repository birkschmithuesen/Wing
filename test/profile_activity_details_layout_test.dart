import 'package:wing/core/widgets/studio_loading.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show SemanticsAction;

import 'package:wing/core/services/profile_supervision_session.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/gateway_todo.dart';
import 'package:wing/core/models/transcript_timeline.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/profile_execution_activity.dart';
import 'package:wing/core/widgets/activity_time.dart';
import 'package:wing/core/widgets/compact_activity_row.dart';
import 'package:wing/core/widgets/profile_subagent_panel.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/widgets/profile_activity_tabs.dart';
import 'package:wing/core/widgets/profile_transcript_disclosure.dart';
import 'package:wing/core/widgets/profile_saved_agents.dart';
import 'helpers/pump_markdown_widget.dart';
import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_actions_fixture.dart';
import 'support/composer_fixture.dart' show emitChatEvent;

void main({Future<void> Function(WidgetTester, String)? capture}) {
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('activity rows fit their content in $brightness at $scale', (
        tester,
      ) async {
        if (tester.binding is AutomatedTestWidgetsFlutterBinding) {
          tester.view.physicalSize = const Size(360, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
        }
        const wrappedLabelText =
            'Search Japanese booking sites and compare private-room prices';
        const goal =
            'Search native Japanese accommodation websites, apply the '
            'travel dates, compare the cheapest private rooms and save verified '
            'evidence with total prices and cancellation rules.';
        final rows = <Map<String, dynamic>>[
          for (var index = 0; index < 10; index++)
            {
              'id': index + 1,
              'role': 'tool',
              'tool_name': switch (index) {
                0 => 'skill_view',
                3 => 'booking_search',
                4 => 'desktop_preview',
                5 => 'tool_get',
                6 => 'search_files',
                7 => 'read_file',
                8 => 'web_extract',
                _ => 'browser_exec',
              },
              'args': switch (index) {
                0 => {'name': 'business-trip-policy-research'},
                1 => {
                  'code':
                      'open("https://example.org/rentals/conditions/mileage")',
                },
                4 => {'action': 'open', 'url': 'https://example.org/map'},
                5 => {
                  'names': ['desktop_preview', 'drive_preview'],
                },
                6 => {'pattern': 'mileage', 'path': 'trip/sources.json'},
                7 => {'path': 'trip/items.json'},
                8 => {
                  'urls': ['https://example.org/rentals/conditions'],
                },
                9 => {
                  'code':
                      '# Inspect the permitted travel area\nprint(get_state())',
                },
                _ => null,
              },
              'content': index == 2 ? '{"exit_code":1}' : 'Page read',
              if (index == 2 || index == 3) 'duration_s': 23,
              if (index != 2 && index != 3 && index != 9)
                'duration_s': (index + 1) * 0.012,
              if (index == 3)
                'labels': [
                  {'text': wrappedLabelText, 'name': 'booking_search'},
                ],
            },
          {
            'id': 11,
            'role': 'tool',
            'tool_name': 'delegate_task',
            'content': jsonEncode({
              'status': 'dispatched',
              'goals': [goal, 'Empty output', 'Read saved findings'],
              'inline_results': [
                {
                  'task_index': 1,
                  'status': 'completed',
                  'summary': '  ',
                  'error': '',
                },
                {
                  'task_index': 2,
                  'status': 'completed',
                  'summary': 'Verified findings',
                  'duration_seconds': 12,
                  'model': 'test-model',
                  'api_calls': 3,
                },
              ],
            }),
          },
        ];
        final timeline = TranscriptTimeline.project(
          rows,
          presentationId: (row) => row['id']!,
        );
        Future<void> show(Widget child) => tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: child,
              ),
            ),
          ),
        );
        await show(
          ProfileToolActivitySection(section: timeline.sections.single),
        );
        await tester.tap(
          find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
        );
        await tester.pumpAndSettle();
        final toolRows = [
          for (var index = 0; index < rows.length; index++)
            find.byKey(ValueKey<(String, Object?)>(('saved-tool', index + 1))),
        ];
        _expectDenseRows(tester, toolRows, 'timeline');
        final wrappedLabel = find.text(wrappedLabelText);
        expect(wrappedLabel, findsOneWidget);
        expect(
          tester.getSize(wrappedLabel).height,
          tester.getSize(find.text('Ran browser code').first).height,
        );
        final headers = tester.widgetList<CompactActivityRow>(
          find.byType(CompactActivityRow),
        );
        expect(headers, hasLength(rows.length));
        for (final header in headers) {
          expect(header.lines, hasLength(1));
          expect(
            tester.getRect(find.byWidget(header.icon)).center.dy,
            closeTo(tester.getRect(find.byWidget(header.title)).center.dy, 0.5),
          );
          expect(
            find.descendant(
              of: find.byWidget(header),
              matching: find.byType(StudioLoading),
            ),
            findsNothing,
          );
          final texts = [
            for (final line in [header.title, ...header.lines])
              tester.widget<Text>(
                find.descendant(
                  of: find.byWidget(line),
                  matching: find.byType(Text),
                  matchRoot: true,
                ),
              ),
          ];
          expect(texts.every((text) => text.maxLines == 1), isTrue);
          expect(texts.last.data!.trim(), isNotEmpty);
        }
        final heights = toolRows
            .map((row) => tester.getSize(row).height)
            .toList();
        expect(
          heights.every((height) => (height - heights.first).abs() < 0.01),
          isTrue,
        );
        if (capture != null) {
          await capture(tester, 'compact-tools-${brightness.name}-$scale');
        }
        await tester.tap(find.text('Read skill'));
        await tester.pumpAndSettle();
        expect(find.text('Raw details'), findsOneWidget);
        await tester.ensureVisible(find.text('Agents 3'));
        await tester.tap(find.text('Agents 3'));
        await tester.pumpAndSettle();
        final agentPanel = find.byType(ProfileSavedAgents);
        final agentRows = find.descendant(
          of: agentPanel,
          matching: find.byType(CompactActivityRow),
        );
        _expectDenseRows(tester, [
          for (final element in agentRows.evaluate())
            find.byWidget(element.widget),
        ], 'agents');
        // Each delivered task is inspectable, including tasks without output.
        expect(
          find.descendant(of: agentPanel, matching: find.byType(ExpansionTile)),
          findsNWidgets(3),
        );
        expect(
          find.descendant(
            of: agentPanel,
            matching: find.byIcon(Icons.expand_more),
          ),
          findsNWidgets(3),
        );
        final goalHeading = goal.substring(0, goal.length - 1);
        expect(find.text(goalHeading), findsOneWidget);
        final semantics = tester.ensureSemantics();
        expect(
          tester
              .getSemantics(find.text(goalHeading))
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue,
        );
        semantics.dispose();
        if (capture != null) {
          await capture(tester, 'compact-agents-${brightness.name}-$scale');
        }
        await tester.ensureVisible(find.text('Read saved findings'));
        await tester.tap(find.text('Read saved findings'));
        await tester.pumpAndSettle();
        await tester.settleMarkdown();
        expect(
          find.text('Verified findings', findRichText: true),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final scale in [1.0, 2.0, 3.0]) {
    testWidgets('nested activity headers fit a phone at text scale $scale', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = ProfileActionsFixture();
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'compact-details',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: fixture.gateway,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final chat = await controller.createChat(canDispatch: () => true);
      final supervision = ProfileSupervisionSession(
        controller: controller,
        chat: chat,
      );
      addTearDown(supervision.dispose);
      // Completed children belong to the live panel only during this answer.
      emitChatEvent(controller, chat, 'message.start');
      emitChatEvent(controller, chat, 'subagent.start', {
        'subagent_id': 'one',
        'goal': 'Compare the available stays',
      });
      emitChatEvent(controller, chat, 'subagent.complete', {
        'subagent_id': 'two',
        'goal': 'Check privacy',
        'status': 'completed',
      });
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ProfileActivitySection(
                  label: 'Activity',
                  initiallyExpanded: true,
                  detailsBuilder: (_) => ProfileActivityTabs(
                    tabs: [
                      ProfileActivityTab(
                        id: 'timeline',
                        label: 'Timeline',
                        child: Column(
                          children: [
                            const ProfileTodoPanel(
                              todos: [
                                GatewayTodo(
                                  id: 'task-1',
                                  content:
                                      'Check the full list of available properties and compare privacy.',
                                  status: GatewayTodoStatus.completed,
                                ),
                                GatewayTodo(
                                  id: 'task-2',
                                  content: 'Review alternatives',
                                  status: GatewayTodoStatus.pending,
                                ),
                              ],
                            ),
                            ProfileSubagentPanel(
                              session: supervision,
                              createResources: controller.traceResources,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 of 2 completed · 1 running'), findsOneWidget);
      if (scale == 1) {
        expect(
          tester
              .getSize(find.byKey(const ValueKey(('activity-tab', 'timeline'))))
              .height,
          lessThanOrEqualTo(32),
        );
        expect(
          tester.getTopLeft(find.text('Tasks 1/2')).dx,
          tester.getTopLeft(find.text('Subagents')).dx,
        );
      }
      await tester.tap(find.text('Tasks 1/2'));
      await tester.pumpAndSettle();
      expect(find.text('Review alternatives'), findsOneWidget);
      await tester.tap(find.text('Tasks 1/2'));
      await tester.pumpAndSettle();
      expect(find.text('Review alternatives'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('metadata changes keep category icon and expansion callbacks', (
    tester,
  ) async {
    final changes = <bool>[];
    var loading = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ProfileTranscriptDisclosure(
                label: 'Subagents',
                icon: Icons.account_tree_outlined,
                summary: Text(loading ? '1 active' : '0 active'),
                onExpansionChanged: changes.add,
                children: const [Text('Agent details')],
              );
            },
          ),
        ),
      ),
    );
    final before = tester.getTopLeft(find.text('Subagents'));
    expect(find.byType(StudioLoading), findsNothing);
    expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget);
    update(() => loading = false);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Subagents')), before);
    expect(find.byType(StudioLoading), findsNothing);
    await tester.tap(find.text('Subagents'));
    await tester.pumpAndSettle();
    expect(find.text('Agent details'), findsOneWidget);
    await tester.tap(find.text('Subagents'));
    await tester.pumpAndSettle();
    expect(changes, [true, false]);
    expect(find.text('Agent details'), findsNothing);
  });
}

// Timing occupies a parallel column: adding its height to the text budget would
// accidentally allow a timed row to grow padding without failing this check.
void _expectDenseRows(WidgetTester tester, List<Finder> rows, String page) {
  final rects = <Rect>[];
  for (final row in rows) {
    final text = find.descendant(of: row, matching: find.byType(Text));
    final mainText = text.evaluate().where((element) {
      var timing = false;
      element.visitAncestorElements((ancestor) {
        if (ancestor.widget is ActivityTime) timing = true;
        return !timing;
      });
      return !timing;
    }).toList();
    final rect = tester.getRect(row);
    var bottom = rect.top;
    for (final element in mainText) {
      final textRect = tester.getRect(find.byWidget(element.widget));
      expect(
        textRect.top,
        closeTo(bottom, 0.1),
        reason: 'No gaps between header text lines',
      );
      bottom = textRect.bottom;
    }
    final timing = find.descendant(
      of: row,
      matching: find.byType(ActivityTime),
    );
    final timingText = find.descendant(of: timing, matching: find.byType(Text));
    final timingHeight = timingText.evaluate().fold<double>(
      0,
      (sum, element) =>
          sum + tester.getSize(find.byWidget(element.widget)).height,
    );
    expect(
      tester.getSize(timing).height,
      closeTo(timingHeight, 0.1),
      reason: 'Duration labels have zero vertical padding',
    );
    if (timingText.evaluate().isNotEmpty) {
      expect(
        tester.getRect(timingText.first).center.dy,
        closeTo(
          tester.getRect(find.byWidget(mainText.first.widget)).top +
              MediaQuery.textScalerOf(
                    mainText.first,
                  ).scale((mainText.first.widget as Text).style!.fontSize!) *
                  (mainText.first.widget as Text).style!.height! /
                  2,
          0.5,
        ),
      );
    }
    final contentHeight = math.max(
      16.0,
      math.max(bottom - rect.top, timingHeight),
    );
    expect(
      rect.height,
      closeTo(contentHeight, 0.1),
      reason: 'Header must have zero vertical padding and no minimum height',
    );
    if (rects.isNotEmpty) {
      expect(
        rect.top,
        closeTo(rects.last.bottom, 0.1),
        reason: 'No gaps between activity rows',
      );
    }
    rects.add(rect);
  }
  final body = tester.getRect(find.byKey(ValueKey(('activity-page', page))));
  expect(
    rects.first.top,
    closeTo(body.top, 0.1),
    reason: 'No padding before activity rows',
  );
  expect(
    rects.last.bottom,
    closeTo(body.bottom, 0.1),
    reason: 'No padding after activity rows',
  );
}

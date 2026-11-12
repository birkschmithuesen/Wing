import 'helpers/pump_markdown_widget.dart';
import 'package:wing/core/models/transcript_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/widgets/profile_activity_tabs.dart';
import 'package:wing/core/widgets/profile_execution_activity.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/widgets/anchored_expansion_tile.dart';
import 'package:wing/core/utils/expansion_scroll_controller.dart';

void main() {
  for (final scale in [1.0, 2.0, 3.0]) {
    testWidgets('tabs retain timeline expansion at phone scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late StateSetter update;
      var completed = 1;
      var showTasks = true;
      var activations = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: Scaffold(
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: ProfileActivitySection(
                      label: 'Activity',
                      initiallyExpanded: true,
                      detailsBuilder: (_) => ProfileActivityTabs(
                        tabs: [
                          ProfileActivityTab(
                            id: 'timeline',
                            label: 'Timeline',
                            child: Column(
                              children: [
                                ProfileToolActivity(
                                  results: [
                                    TranscriptToolResult.fromRow({
                                      'id': 1,
                                      'role': 'tool',
                                      'tool_name': 'skill_view',
                                      'content': 'Saved tool detail',
                                    }),
                                  ],
                                ),
                                const ProfileReasoningDisclosure(
                                  text: 'Reasoning details',
                                  running: true,
                                ),
                              ],
                            ),
                          ),
                          if (showTasks)
                            ProfileActivityTab(
                              id: 'tasks',
                              label: 'Tasks $completed/4',
                              child: const Text('Task details'),
                            ),
                          ProfileActivityTab(
                            id: 'agents',
                            label: 'Agents 1/2',
                            child: const Text('Agent details'),
                            onSelected: () => activations++,
                          ),
                        ],
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
      await tester.settleMarkdown();
      await tester.tap(find.text('Read skill'));
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      expect(find.text('Saved tool detail'), findsOneWidget);
      await tester.tap(find.text('Tasks 1/4'));
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      expect(find.text('Task details'), findsOneWidget);
      expect(find.text('Saved tool detail'), findsNothing);
      expect(find.text('Thinking'), findsNothing);
      update(() => completed = 2);
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      expect(find.text('Task details'), findsOneWidget);
      await tester.tap(find.text('Agents 1/2'));
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      expect(activations, 1);
      expect(find.text('Agent details'), findsOneWidget);
      await tester.tap(find.text('Timeline'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Thinking'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thinking'));
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      expect(
        find.text('Reasoning details', findRichText: true),
        findsNWidgets(2),
      );
      await tester.ensureVisible(find.text('Timeline'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Timeline'));
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      expect(find.text('Saved tool detail'), findsOneWidget);
      expect(
        find.text('Reasoning details', findRichText: true),
        findsNWidgets(2),
      );
      await tester.tap(find.text('Tasks 2/4'));
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      update(() => showTasks = false);
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      expect(find.text('Saved tool detail'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'switching category preserves its position in reversed transcript',
    (tester) async {
      final scroll = ExpansionScrollController(
        preserveViewportPosition: () => true,
      );
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotificationListener<ExpansionAnchorNotification>(
              onNotification: (event) {
                scroll.anchorExpansion(
                  event.anchor,
                  allowBottomGap: event.allowBottomGap,
                );
                return true;
              },
              child: ListView(
                reverse: true,
                controller: scroll,
                children: [
                  const SizedBox(height: 40),
                  ProfileActivityTabs(
                    tabs: [
                      ProfileActivityTab(
                        id: 'tools',
                        label: 'Tools',
                        child: const SizedBox(height: 60),
                      ),
                      ProfileActivityTab(
                        id: 'tasks',
                        label: 'Tasks',
                        child: const SizedBox(height: 300),
                      ),
                    ],
                  ),
                  const SizedBox(height: 700),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      final before = tester.getTopLeft(find.text('Tasks')).dy;
      await tester.tap(find.text('Tasks'));
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      expect(tester.getTopLeft(find.text('Tasks')).dy, closeTo(before, 1));
      await tester.tap(find.text('Tools'));
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      expect(tester.getTopLeft(find.text('Tasks')).dy, closeTo(before, 1));
      expect(tester.takeException(), isNull);
    },
  );
}

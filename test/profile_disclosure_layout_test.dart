import 'package:wing/core/models/transcript_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';
import 'package:wing/core/widgets/profile_execution_activity.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'helpers/pump_markdown_widget.dart';

void main() {
  const activityKey = ValueKey('saved-activity');
  const reasoningKey = ValueKey('saved-reasoning');
  final reasoningHeader = find
      .descendant(
        of: find.byKey(reasoningKey),
        matching: find.text('Reasoning'),
      )
      .first;

  Future<void> show(WidgetTester tester, double scale) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: profileWorkspaceTheme(wingTheme(Brightness.dark)),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ProfileToolActivitySection(
                  key: activityKey,
                  section: TranscriptTimeline.project([
                    {
                      'id': 1,
                      'role': 'tool',
                      'tool_name': 'first_tool',
                      'content': 'First result',
                    },
                    {
                      'id': 2,
                      'role': 'tool',
                      'tool_name': 'second_tool',
                      'content': 'Second result',
                    },
                  ], presentationId: (_) => Object()).sections.single,
                ),
                const ProfileReasoningDisclosure(
                  key: reasoningKey,
                  text: 'Checked the available options.',
                ),
                const Text('The follow-up is running.'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final scale in [1.0, 2.0, 3.0]) {
    testWidgets(
      'collapsed disclosures leave the answer visible at scale $scale',
      (tester) async {
        await show(tester, scale);
        expect(find.text('First result'), findsNothing);
        expect(find.text('Second result'), findsNothing);
        expect(
          find.text('The follow-up is running.').hitTestable(),
          findsOneWidget,
        );
        expect(reasoningHeader.hitTestable(), findsOneWidget);
        expect(find.text('Activity · 2 tools').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  final reasoningBody = find.descendant(
    of: find.byKey(reasoningKey),
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is SelectableText &&
          (widget.data ?? widget.textSpan?.toPlainText()) ==
              'Checked the available options.',
    ),
  );

  for (final scale in [1.0, 2.0, 3.0]) {
    testWidgets('disclosures remain readable and expandable at scale $scale', (
      tester,
    ) async {
      await show(tester, scale);
      expect(find.text('Activity · 2 tools'), findsOneWidget);
      expect(find.text('First result'), findsNothing);
      expect(find.text('Checked the available options.'), findsOneWidget);
      expect(reasoningBody, findsNothing);
      expect(find.byTooltip('Copy Reasoning'), findsNothing);
      await tester.tap(
        find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('First tool'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Second tool'));
      await tester.tap(find.text('Second tool'));
      await tester.pumpAndSettle();
      expect(find.text('First result'), findsOneWidget);
      expect(find.text('Second result'), findsOneWidget);
      await tester.ensureVisible(reasoningHeader);
      await tester.tap(reasoningHeader);
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      expect(reasoningBody, findsOneWidget);
      expect(find.byTooltip('Copy Reasoning'), findsOneWidget);
      await tester.tap(reasoningHeader);
      await tester.pumpAndSettle();
      expect(find.text('Checked the available options.'), findsOneWidget);
      expect(reasoningBody, findsNothing);
      expect(find.byTooltip('Copy Reasoning'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}

import 'package:wing/core/models/transcript_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/theme/wing_icons.dart';
import 'package:wing/core/widgets/answer_actions.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'helpers/pump_markdown_widget.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('notice actions stay aligned ${brightness.name} at $scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
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
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ProfileMessage(
                    message: TranscriptMessage.fromRow(const {
                      'role': 'user',
                      'display_kind': 'async_delegation_complete',
                      'display_metadata': {'task_count': 2},
                      'content':
                          'Background result with enough detail to span several lines when expanded.',
                    }),
                    actions: AnswerActions(
                      onBranch: () {},
                      onRegenerate: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final arrow = find.byIcon(Icons.expand_more);
        final branch = find.byIcon(WingIcons.fork);
        final retry = find.byIcon(Icons.refresh);
        final headerCenter = tester.getCenter(arrow).dy;
        void expectAligned() {
          final center = tester.getCenter(arrow).dy;
          expect(tester.getCenter(branch).dy, closeTo(center, .01));
          expect(tester.getCenter(retry).dy, closeTo(center, .01));
          // ExpansionTile removes its one-pixel collapsed border on opening.
          // The controls must stay in the header, not follow the result body.
          expect(center, closeTo(headerCenter, 1));
          expect(tester.takeException(), isNull);
        }

        expectAligned();
        for (final tooltip in [
          'Branch in new session',
          'Regenerate response',
        ]) {
          final size = tester.getSize(find.byTooltip(tooltip));
          expect(size.width, greaterThanOrEqualTo(48));
          expect(size.height, greaterThanOrEqualTo(48));
        }
        await tester.tap(find.text('View result'));
        await tester.pumpAndSettle();
        await tester.settleMarkdown();
        expectAligned();
        expect(
          find.text(
            'Background result with enough detail to span several lines when expanded.',
          ),
          findsOneWidget,
        );
      });
    }
  }
}

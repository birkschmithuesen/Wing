import 'package:wing/core/models/transcript_message.dart';
import 'helpers/pump_markdown_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/widgets/markdown_code_block.dart';
import 'package:wing/core/widgets/adaptive_markdown_table.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/theme/wing_theme.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final grid in [true, false]) {
        testWidgets(
          'table keeps explicit ${grid ? 'grid' : 'rows'} during message updates '
          '${brightness.name} $scale',
          (tester) async {
            tester.view.physicalSize = const Size(390, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            const small = '| A | B |\n| --- | --- |\n| a | b |';
            const wide =
                '$small\n'
                '| A longer value arriving in the chat | Another long value |';
            var source = grid ? small : wide;
            var streaming = true;
            var nextMessage = false;
            late StateSetter update;
            await tester.pumpMarkdownWidget(
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
                    child: StatefulBuilder(
                      builder: (context, setState) {
                        update = setState;
                        return Column(
                          children: [
                            MarkdownMessageContent(
                              data: source,
                              streaming: streaming,
                            ),
                            if (nextMessage)
                              const MarkdownMessageContent(data: 'Next reply.'),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
            final label = grid ? 'Read as table' : 'Read as stacked rows';
            await tester.tap(find.byTooltip(label));
            await tester.pump();
            final tableState = tester.state(find.byType(AdaptiveMarkdownTable));
            void expectSelection() {
              expect(
                tester.state(find.byType(AdaptiveMarkdownTable)),
                same(tableState),
              );
              expect(
                tester
                    .widget<IconButton>(
                      find.widgetWithIcon(
                        IconButton,
                        grid
                            ? Icons.table_chart_outlined
                            : Icons.view_agenda_outlined,
                      ),
                    )
                    .isSelected,
                isTrue,
              );
              expect(find.byType(Table), grid ? findsOneWidget : findsNothing);
              expect(tester.takeException(), isNull);
            }

            expectSelection();
            // New content changes whether the table fits. It must not
            // override an explicit selection in either direction.
            update(() => source = grid ? wide : small);
            await tester.pump();
            await tester.settleMarkdown();
            expectSelection();
            update(() {
              streaming = false;
              nextMessage = true;
            });
            await tester.pump();
            await tester.settleMarkdown();
            expectSelection();
            // The most recent explicit choice also survives later updates.
            final otherLabel = grid ? 'Read as stacked rows' : 'Read as table';
            await tester.tap(find.byTooltip(otherLabel));
            await tester.pump();
            update(() => source = grid ? small : wide);
            await tester.pump();
            await tester.settleMarkdown();
            expect(
              tester
                  .widget<IconButton>(
                    find.widgetWithIcon(
                      IconButton,
                      grid
                          ? Icons.view_agenda_outlined
                          : Icons.table_chart_outlined,
                    ),
                  )
                  .isSelected,
              isTrue,
            );
            expect(find.byType(Table), grid ? findsNothing : findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets(
    'saved user attachments display the prompt without expanded context',
    (tester) async {
      await tester.pumpMarkdownWidget(
        MaterialApp(
          home: Scaffold(
            body: ProfileMessage(
              message: TranscriptMessage.fromRow({
                'role': 'user',
                'content':
                    '@file:notes.txt\n\nRead the marker.\n\n'
                    '--- Attached Context ---\n\n'
                    '📄 @file:notes.txt\n```\nPRIVATE FILE BODY\n```',
              }),
            ),
          ),
        ),
      );
      expect(find.text('Read the marker.'), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.text('TXT'), findsOneWidget);
      expect(find.textContaining('PRIVATE FILE BODY'), findsNothing);
    },
  );

  test(
    'fences preserve embedded shorter fences and unfinished streamed code',
    () {
      final segments = splitMarkdownCodeBlocks(
        'Before\n````markdown\n```dart\nvalue\n```\n````\nAfter\n~~~sh\necho hello',
      );
      final blocks = segments.whereType<MarkdownCodeBlock>().toList();
      expect(blocks, hasLength(2));
      expect(blocks.first.code, '```dart\nvalue\n```\n');
      expect(blocks.first.language, 'markdown');
      expect(blocks.last.code, 'echo hello');
      expect(blocks.last.language, 'sh');
      expect(segments.whereType<String>().join(), 'Before\n\nAfter\n');
      expect(
        splitMarkdownCodeBlocks('inline ``` stays prose').single,
        isA<String>(),
      );
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'wide tables default to horizontally scrolling grids at text scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(320, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpMarkdownWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                padding: const EdgeInsets.only(bottom: 34),
              ),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: EdgeInsets.all(16),
                child: ProfileMessage(
                  message: TranscriptMessage.fromRow({
                    'role': 'assistant',
                    'content':
                        '| Project | Owner | Status | Next step |\n'
                        '| --- | --- | --- | --- |\n'
                        '| Quarterly planning | Product team | In review | Approve the proposal |\n\n'
                        '```text\nA very long line that should scroll horizontally without forcing the conversation wider.\n```',
                  }),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(Table), findsOneWidget);
        expect(find.byTooltip('Read as stacked rows'), findsOneWidget);
        final horizontal = tester
            .stateList<ScrollableState>(find.byType(Scrollable))
            .where((state) => state.axisDirection == AxisDirection.right)
            .toList();
        expect(
          horizontal.where((state) => state.position.maxScrollExtent > 0),
          hasLength(1),
        );
        final markdown = find.bySubtype<MarkdownBody>();
        final table = find.descendant(
          of: markdown,
          matching: find.byType(Table),
        );
        final tableScrollbar = find.descendant(
          of: markdown,
          matching: find.byType(Scrollbar),
        );
        final painters = tester
            .widgetList<CustomPaint>(
              find.descendant(
                of: tableScrollbar,
                matching: find.byType(CustomPaint),
              ),
            )
            .map((widget) => widget.foregroundPainter)
            .whereType<ScrollbarPainter>();
        expect(painters, hasLength(1));
        final painter = painters.single;
        final gutter =
            tester.getBottomLeft(tableScrollbar).dy -
            tester.getBottomLeft(table).dy;
        final thumbInset =
            painter.padding.resolve(TextDirection.ltr).bottom +
            painter.crossAxisMargin;
        // Include a phone navigation inset above: the thumb must still fit
        // entirely below the table, even at a large text size.
        expect(thumbInset + painter.thickness, lessThan(gutter));
        final tableScroll = horizontal.firstWhere(
          (state) => state.position.maxScrollExtent > 0,
        );
        await tester.dragFrom(
          tester.getBottomLeft(tableScrollbar) + const Offset(180, -6),
          const Offset(-120, 0),
        );
        await tester.pumpAndSettle();
        expect(tableScroll.position.pixels, greaterThan(0));
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byTooltip('Scroll horizontally'));
        await tester.tap(find.byTooltip('Scroll horizontally'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Wrap lines'), findsOneWidget);
        expect(
          tester
              .stateList<ScrollableState>(find.byType(Scrollable))
              .where(
                (state) =>
                    state.axisDirection == AxisDirection.right &&
                    state.position.maxScrollExtent > 0,
              ),
          hasLength(2),
        );
        expect(
          tester.getSize(find.byTooltip('Copy code')).height,
          greaterThanOrEqualTo(48),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

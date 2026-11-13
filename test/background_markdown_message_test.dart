import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/performance_instrumentation.dart';
import 'package:wing/core/widgets/background_markdown_content.dart';
import 'package:wing/core/widgets/block_reusing_markdown_body.dart';
import 'package:wing/core/widgets/markdown_code_block.dart';
import 'package:wing/core/widgets/source_code_block.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';

import 'helpers/pump_markdown_widget.dart';

Widget _host(String source, {required bool streaming}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: MarkdownMessageContent(data: source, streaming: streaming),
    ),
  ),
);

void main() {
  testWidgets('one message parser publishes mixed prose and fenced code', (
    tester,
  ) async {
    const source = 'Before **bold**.\n\n```dart\nprint("one");\n```\n\nAfter.';
    await tester.pumpMarkdownWidget(_host(source, streaming: true));
    expect(find.byType(BackgroundMarkdownContent), findsOneWidget);
    expect(find.byType(BlockReusingMarkdownBody), findsNWidgets(2));
    expect(find.byType(MarkdownCodeBlock), findsOneWidget);
    final state = tester.state<BackgroundMarkdownContentState>(
      find.byType(BackgroundMarkdownContent),
    );
    expect(state.renderedSource, source);
    expect(state.pending, isFalse);
    expect(state.parsesCompleted, PerformanceInstrumentation.enabled ? 1 : 0);
    expect(
      tester
          .widgetList<BlockReusingMarkdownBody>(
            find.byType(BlockReusingMarkdownBody),
          )
          .map((body) => body.data.trim()),
      ['Before **bold**.', 'After.'],
    );
    final code = tester.widget<MarkdownCodeBlock>(
      find.byType(MarkdownCodeBlock),
    );
    expect(code.code, 'print("one");\n');
    expect(code.language, 'dart');
    expect(code.previewEnabled, isFalse);
    expect(find.text('Before bold.', findRichText: true), findsOneWidget);
    expect(find.text('After.', findRichText: true), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'completion reuses parsed source and only enables closed previews',
    (tester) async {
      const closed = 'Before.\n\n```svg\n<svg></svg>\n```\n\nAfter.';
      await tester.pumpMarkdownWidget(_host(closed, streaming: true));
      final parser = tester.state<BackgroundMarkdownContentState>(
        find.byType(BackgroundMarkdownContent),
      );
      await tester.tap(find.byTooltip('Scroll horizontally'));
      await tester.pump();
      final codeState = tester.state(find.byType(SourceCodeBlock));
      final parses = parser.parsesCompleted;
      final acceptedNodes = tester
          .widgetList<BlockReusingMarkdownBody>(
            find.byType(BlockReusingMarkdownBody),
          )
          .map((body) => body.parsedNodes)
          .toList();
      expect(
        tester
            .widget<MarkdownCodeBlock>(find.byType(MarkdownCodeBlock))
            .previewEnabled,
        isFalse,
      );
      await tester.pumpMarkdownWidget(_host(closed, streaming: false));
      expect(
        tester.state(find.byType(BackgroundMarkdownContent)),
        same(parser),
      );
      expect(parser.parsesCompleted, parses);
      final completedBodies = tester
          .widgetList<BlockReusingMarkdownBody>(
            find.byType(BlockReusingMarkdownBody),
          )
          .toList();
      expect(completedBodies, hasLength(acceptedNodes.length));
      for (var index = 0; index < acceptedNodes.length; index++) {
        expect(completedBodies[index].parsedNodes, same(acceptedNodes[index]));
      }
      expect(parser.pending, isFalse);
      expect(tester.state(find.byType(SourceCodeBlock)), same(codeState));
      expect(find.byTooltip('Wrap lines'), findsOneWidget);
      expect(
        tester
            .widget<MarkdownCodeBlock>(find.byType(MarkdownCodeBlock))
            .previewEnabled,
        isTrue,
      );

      const unclosed = 'Replacement.\n\n```svg\n<svg></svg>';
      await tester.pumpMarkdownWidget(_host(unclosed, streaming: false));
      expect(parser.renderedSource, unclosed);
      expect(
        parser.parsesCompleted,
        PerformanceInstrumentation.enabled ? parses + 1 : 0,
      );
      expect(find.text('Before.', findRichText: true), findsNothing);
      expect(find.text('Replacement.', findRichText: true), findsOneWidget);
      expect(
        tester
            .widget<MarkdownCodeBlock>(find.byType(MarkdownCodeBlock))
            .previewEnabled,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}

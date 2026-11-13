import 'package:wing/core/widgets/source_code_text.dart';
import 'helpers/pump_markdown_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/chat_output.dart';
import 'package:wing/core/widgets/deliverable_attachment.dart';
import 'package:wing/core/widgets/source_code_block.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';

Widget _host(
  MarkdownMessageContent content, {
  bool dark = false,
  double width = 390,
  double scale = 1,
  ScrollController? scrollController,
}) => MaterialApp(
  themeAnimationDuration: Duration.zero,
  theme: dark ? ThemeData.dark() : ThemeData.light(),
  home: MediaQuery(
    data: MediaQueryData(
      size: Size(width, 800),
      textScaler: TextScaler.linear(scale),
    ),
    child: Scaffold(
      body: SingleChildScrollView(
        controller: scrollController,
        child: SizedBox(width: width, child: content),
      ),
    ),
  ),
);

void main() {
  testWidgets('a growing fence keeps exact source through closing and edits', (
    tester,
  ) async {
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

    for (final fixture in [
      ('Lead\n````markdown\n```dart\nvalue', '```dart\nvalue'),
      (
        'Lead\n````markdown\n```dart\nvalue\n```\n````\nTail',
        '```dart\nvalue\n```\n',
      ),
      (
        'Lead\n````markdown\n```dart\nchanged\n```\n````\nLonger tail',
        '```dart\nchanged\n```\n',
      ),
    ]) {
      await tester.pumpMarkdownWidget(
        _host(MarkdownMessageContent(data: fixture.$1, streaming: true)),
      );
      expect(find.byType(SourceCodeBlock), findsOneWidget);
      expect(
        tester.widget<SourceCodeBlock>(find.byType(SourceCodeBlock)).code,
        fixture.$2,
      );
      await tester.tap(find.byTooltip('Copy code'));
      await tester.pump();
      expect(copied, fixture.$2);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    }
    expect(find.text('Longer tail', findRichText: true), findsOneWidget);
  });

  testWidgets('completion enables previews only for a closed diagram fence', (
    tester,
  ) async {
    const open = 'Lead\n```mermaid\ngraph TD\nA --> B';
    await tester.pumpMarkdownWidget(
      _host(const MarkdownMessageContent(data: open, streaming: true)),
    );
    expect(find.byTooltip('Open diagram'), findsNothing);
    const closed = '$open\n```\nTail';
    await tester.pumpMarkdownWidget(
      _host(const MarkdownMessageContent(data: closed, streaming: true)),
    );
    expect(find.byTooltip('Open diagram'), findsNothing);
    await tester.pumpMarkdownWidget(
      _host(const MarkdownMessageContent(data: closed)),
    );
    expect(find.byTooltip('Open diagram'), findsOneWidget);
    expect(
      tester.widget<SourceCodeBlock>(find.byType(SourceCodeBlock)).code,
      'graph TD\nA --> B\n',
    );
    await tester.pumpMarkdownWidget(
      _host(const MarkdownMessageContent(data: open)),
    );
    expect(find.byTooltip('Open diagram'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('code wrap choice survives growth after its closed fence', (
    tester,
  ) async {
    const prefix = 'Lead\n```text\nA long code line\n```\n';
    await tester.pumpMarkdownWidget(
      _host(
        const MarkdownMessageContent(data: '${prefix}Tail', streaming: true),
      ),
    );
    await tester.tap(find.byTooltip('Scroll horizontally'));
    await tester.pump();
    for (final tail in ['Tail grows', 'Tail grows\n\nA second paragraph']) {
      await tester.pumpMarkdownWidget(
        _host(MarkdownMessageContent(data: '$prefix$tail', streaming: true)),
      );
      expect(find.byTooltip('Wrap lines'), findsOneWidget);
      expect(find.byTooltip('Scroll horizontally'), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('reused segments use current file actions and remove them', (
    tester,
  ) async {
    final calls = <String>[];
    const prefix = '[Report](/srv/report.md)\n\n```text\ncode\n```\n';
    MarkdownMessageContent content(
      String owner,
      String tail, {
      bool enabled = true,
      bool deliverables = true,
    }) => MarkdownMessageContent(
      data: '$prefix$tail',
      streaming: true,
      deliverables: deliverables,
      onOpenRemoteFile: enabled
          ? (ChatOutput output) async => calls.add('$owner open ${output.path}')
          : null,
      onDownloadRemoteFile: enabled
          ? (_) async {
              calls.add('$owner download');
              return false;
            }
          : null,
    );
    await tester.pumpMarkdownWidget(_host(content('old', 'Tail')));
    await tester.pumpMarkdownWidget(_host(content('new', 'Growing tail')));
    await tester.tap(find.byTooltip('Open preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    expect(calls, ['new open /srv/report.md', 'new download']);
    await tester.pumpMarkdownWidget(
      _host(content('disabled', 'Tail', enabled: false)),
    );
    final attachment = tester.widget<DeliverableAttachment>(
      find.byType(DeliverableAttachment),
    );
    expect(attachment.onOpen, isNull);
    expect(attachment.onDownload, isNull);
    await tester.pumpMarkdownWidget(
      _host(content('ordinary link', 'Tail', deliverables: false)),
    );
    expect(find.byType(DeliverableAttachment), findsNothing);
    await tester.tap(find.text('Report', findRichText: true));
    await tester.pumpAndSettle();
    expect(calls.last, 'ordinary link open /srv/report.md');
    expect(tester.takeException(), isNull);
  });

  testWidgets('theme and enlarged text update previously completed segments', (
    tester,
  ) async {
    const prefix = 'Completed paragraph.\n\n```text\ncode\n```\n';
    await tester.pumpMarkdownWidget(
      _host(
        const MarkdownMessageContent(data: '${prefix}Tail', streaming: true),
      ),
    );
    final prose = find.byWidgetPredicate(
      (widget) =>
          widget is SelectableText &&
          widget.textSpan?.toPlainText() == 'Completed paragraph.',
    );
    final lightColor = tester
        .widget<SelectableText>(prose)
        .textSpan!
        .style!
        .color;
    final normalHeight = tester.getSize(prose).height;
    await tester.pumpMarkdownWidget(
      _host(
        const MarkdownMessageContent(
          data: '${prefix}Growing tail',
          streaming: true,
        ),
        dark: true,
        width: 320,
        scale: 2,
      ),
    );
    expect(
      tester.widget<SelectableText>(prose).textSpan!.style!.color,
      isNot(lightColor),
    );
    expect(tester.getSize(prose).height, greaterThan(normalHeight));
    final codeText = tester.widget<SourceCodeText>(
      find.descendant(
        of: find.byType(SourceCodeBlock),
        matching: find.byType(SourceCodeText),
      ),
    );
    expect(codeText.style.color, ThemeData.dark().colorScheme.onSurface);
    expect(tester.takeException(), isNull);
  });

  testWidgets('document heading links remain attached across fenced updates', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final source =
        '[Jump](#target)\n\n```text\ncode\n```\n\n'
        '${List.filled(30, 'Paragraph with enough room to scroll.').join('\n\n')}'
        '\n\n# Target\n\nDetails';
    var fileReads = 0;
    for (final tail in ['', '\n\nMore details']) {
      await tester.pumpMarkdownWidget(
        _host(
          MarkdownMessageContent(
            data: '$source$tail',
            documentPath: '/srv/report.md',
            onOpenRemoteFile: (_) async => fileReads++,
          ),
          scrollController: scroll,
        ),
      );
      scroll.jumpTo(0);
      await tester.pump();
      await tester.tap(find.text('Jump', findRichText: true));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      expect(fileReads, 0);
      expect(
        find.text('This heading is not in the available preview.'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('removed segments and an empty message release their content', (
    tester,
  ) async {
    var opens = 0;
    MarkdownMessageContent content(String data) => MarkdownMessageContent(
      data: data,
      deliverables: true,
      onOpenRemoteFile: (_) async {
        opens++;
      },
    );
    await tester.pumpMarkdownWidget(
      _host(
        content('[Report](/srv/report.md)\n\n```text\nold code\n```\nTail'),
      ),
    );
    await tester.tap(find.byTooltip('Open preview'));
    await tester.pumpAndSettle();
    expect(opens, 1);
    await tester.pumpMarkdownWidget(_host(content('Replacement paragraph.')));
    expect(find.byType(DeliverableAttachment), findsNothing);
    expect(find.byType(SourceCodeBlock), findsNothing);
    expect(find.text('Tail', findRichText: true), findsNothing);
    expect(
      find.text('Replacement paragraph.', findRichText: true),
      findsOneWidget,
    );
    await tester.pumpMarkdownWidget(_host(content('')));
    expect(find.byType(SelectableText), findsNothing);
    expect(find.byType(DeliverableAttachment), findsNothing);
    expect(find.byType(SourceCodeBlock), findsNothing);
    await tester.pumpMarkdownWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}

import 'helpers/pump_markdown_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/widgets/block_reusing_markdown_body.dart';
import 'package:wing/core/widgets/source_code_block.dart';
import 'package:wing/core/widgets/source_code_text.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';

void main() {
  testWidgets('stream growth leaves closed code and prose segments unbuilt', (
    tester,
  ) async {
    const initial = '''Selected **prefix**.

```dart
final first = 1;
```

Closed paragraph.

```python
second = 2
```

Growing tail''';
    final source = ValueNotifier(initial);
    addTearDown(source.dispose);
    await tester.pumpMarkdownWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 390,
              child: ValueListenableBuilder<String>(
                valueListenable: source,
                builder: (_, data, _) =>
                    MarkdownMessageContent(data: data, streaming: true),
              ),
            ),
          ),
        ),
      ),
    );
    // Local code state and an actual nonempty text selection must survive the
    // optimization, rather than just preserving the final visible strings.
    await tester.tap(find.byTooltip('Scroll horizontally').first);
    await tester.pump();
    final prefix = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .firstWhere(
          (text) => text.textSpan?.toPlainText() == 'Selected prefix.',
        );
    final prefixElement = tester.element(find.byWidget(prefix));
    final editable = tester.state<EditableTextState>(
      find.descendant(
        of: find.byWidget(prefix),
        matching: find.byType(EditableText),
      ),
    );
    const selection = TextSelection(baseOffset: 9, extentOffset: 15);
    editable.userUpdateTextEditingValue(
      editable.widget.controller.value.copyWith(selection: selection),
      SelectionChangedCause.longPress,
    );
    await tester.pump();
    expect(selection.textInside(editable.widget.controller.text), 'prefix');

    final code = tester
        .widgetList<SourceCodeBlock>(find.byType(SourceCodeBlock))
        .toList();
    final elements = [
      for (final widget in code) tester.element(find.byWidget(widget)),
    ];
    final fixedProse = tester
        .widgetList<BlockReusingMarkdownBody>(
          find.byType(BlockReusingMarkdownBody),
        )
        .where((body) => !body.data.contains('Growing'))
        .toList();
    final fixedData = fixedProse.map((body) => body.data).toSet();
    var codeBuilds = 0;
    var closedProseBuilds = 0;
    final original = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is SourceCodeBlock) codeBuilds++;
      if (element.widget case BlockReusingMarkdownBody(
        data: final data,
      ) when fixedData.contains(data)) {
        closedProseBuilds++;
      }
      original?.call(element, builtOnce);
    };
    addTearDown(() => debugOnRebuildDirtyWidget = original);
    for (var update = 0; update < 12; update++) {
      source.value += ' synthetic$update';
      await tester.pump(const Duration(milliseconds: 100));
      await tester.settleMarkdown();
    }
    debugPrint(
      'Closed segments across 12 updates: '
      '$codeBuilds code builds, $closedProseBuilds prose builds',
    );
    expect(
      codeBuilds,
      0,
      reason: 'A growing prose tail must not rebuild unchanged fenced code.',
    );
    expect(
      closedProseBuilds,
      0,
      reason: 'Completed prose segments must remain outside stream rebuilds.',
    );
    final after = tester
        .widgetList<SourceCodeBlock>(find.byType(SourceCodeBlock))
        .toList();
    for (var index = 0; index < code.length; index++) {
      expect(after[index], same(code[index]));
      expect(
        tester.element(find.byWidget(after[index])),
        same(elements[index]),
      );
    }
    for (final body in fixedProse) {
      expect(find.byWidget(body), findsOneWidget);
    }
    expect(
      tester
          .widget<SourceCodeText>(
            find.descendant(
              of: find.byWidget(after.first),
              matching: find.byType(SourceCodeText),
            ),
          )
          .wrap,
      isFalse,
      reason: 'The first code block must retain its selected horizontal mode.',
    );
    expect(tester.element(find.byWidget(prefix)), same(prefixElement));
    expect(editable.mounted, isTrue);
    expect(editable.widget.controller.selection, selection);
    expect(
      editable.widget.controller.selection.textInside(
        editable.widget.controller.text,
      ),
      'prefix',
    );
    expect(
      tester
          .widgetList<BlockReusingMarkdownBody>(
            find.byType(BlockReusingMarkdownBody),
          )
          .last
          .data,
      endsWith('synthetic11'),
    );
    expect(tester.takeException(), isNull);
  });
}

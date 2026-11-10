import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:wing/core/widgets/block_reusing_markdown_body.dart';
import 'package:wing/core/widgets/deliverable_attachment.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';

import 'helpers/pump_markdown_widget.dart';

Widget _host(Widget child, {bool dark = false, double scale = 1}) =>
    MaterialApp(
      themeAnimationDuration: Duration.zero,
      theme: dark ? ThemeData.dark() : ThemeData.light(),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(390, 800),
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(width: 390, child: child),
          ),
        ),
      ),
    );

List<SelectableText> _texts(WidgetTester tester) =>
    tester.widgetList<SelectableText>(find.byType(SelectableText)).toList();

EditableTextState _editable(WidgetTester tester, SelectableText text) =>
    tester.state<EditableTextState>(
      find.descendant(
        of: find.byWidget(text),
        matching: find.byType(EditableText),
      ),
    );

Future<void> _select(
  WidgetTester tester,
  EditableTextState editable,
  TextSelection selection,
) async {
  editable.userUpdateTextEditingValue(
    editable.widget.controller.value.copyWith(selection: selection),
    SelectionChangedCause.longPress,
  );
  await tester.pump();
  expect(editable.widget.controller.selection, selection);
}

List<TextSpan> _spans(SelectableText text) {
  final spans = <TextSpan>[text.textSpan!];
  text.textSpan!.visitChildren((span) {
    if (span is TextSpan) spans.add(span);
    return true;
  });
  return spans;
}

List<Object> _rendered(WidgetTester tester) => _texts(tester)
    .map(
      (text) => [
        text.textSpan?.toPlainText() ?? text.data,
        text.textSpan?.style.toString(),
        text.textScaler?.scale(10),
        tester.getRect(find.byWidget(text)).toString(),
      ],
    )
    .toList();

class _CustomParagraphBuilder extends MarkdownElementBuilder {
  _CustomParagraphBuilder(this.onTap);

  final VoidCallback onTap;

  @override
  Widget visitText(md.Text text, TextStyle? preferredStyle) =>
      Text(text.text, style: preferredStyle);

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => SelectableText.rich(
    TextSpan(text: 'Custom ${element.textContent}', style: preferredStyle),
    key: const ValueKey('custom-paragraph'),
    maxLines: 3,
    onTap: onTap,
  );
}

class _CustomInlineBuilder extends MarkdownElementBuilder {
  _CustomInlineBuilder(this.child);

  final Widget child;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => child;
}

class _StockDelegate implements MarkdownBuilderDelegate {
  _StockDelegate(this.context);

  @override
  final BuildContext context;

  @override
  GestureRecognizer createLink(String text, String? href, String title) =>
      TapGestureRecognizer();

  @override
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code) =>
      TextSpan(text: code, style: styleSheet.code);
}

void main() {
  for (final (kind, prefix) in [
    ('paragraph', ''),
    ('heading', '### '),
    ('list', '- '),
    ('numbered list', '1. '),
    ('quote', '> '),
    ('quoted list', '> - '),
  ]) {
    testWidgets('growing $kind retains text state and selection', (
      tester,
    ) async {
      const fixed = 'Completed paragraph stays fixed.';
      const start = 'Growing paragraph';
      final sourceStart = '$prefix$start';
      await tester.pumpMarkdownWidget(
        _host(
          MarkdownMessageContent(
            data: '$fixed\n\n$sourceStart',
            streaming: true,
          ),
        ),
      );
      expect(find.byType(BlockReusingMarkdownBody), findsOneWidget);
      final before = _texts(tester);
      expect(before, hasLength(2));
      final fixedState = tester.state(find.byWidget(before.first));
      final growingState = tester.state(find.byWidget(before.last));
      final fixedEditable = _editable(tester, before.first);
      final growingEditable = _editable(tester, before.last);
      const selection = TextSelection(baseOffset: 0, extentOffset: 7);
      await _select(tester, growingEditable, selection);

      for (var update = 1; update <= 4; update++) {
        final growing = '$start${' more words' * update}';
        await tester.pumpMarkdownWidget(
          _host(
            MarkdownMessageContent(
              data: '$fixed\n\n$prefix$growing',
              streaming: update != 4,
            ),
          ),
        );
        final after = _texts(tester);
        expect(after, hasLength(2));
        expect(after.first, same(before.first));
        expect(tester.state(find.byWidget(after.first)), same(fixedState));
        expect(tester.state(find.byWidget(after.last)), same(growingState));
        expect(_editable(tester, after.first), same(fixedEditable));
        expect(_editable(tester, after.last), same(growingEditable));
        expect(growingEditable.widget.controller.text, growing);
        expect(growingEditable.widget.controller.selection, selection);
        expect(selection.textInside(growing), 'Growing');
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('$kind appends do not repeat native editable initialization', (
      tester,
    ) async {
      final calls = <String, int>{};
      void record(MethodCall call) =>
          calls.update(call.method, (count) => count + 1, ifAbsent: () => 1);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        record(call);
        if (call.method == 'Clipboard.hasStrings') return {'value': false};
        if (call.method == 'LiveText.isLiveTextInputAvailable') return false;
        return null;
      });
      messenger.setMockMethodCallHandler(SystemChannels.processText, (
        call,
      ) async {
        record(call);
        return <String, String>{};
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        messenger.setMockMethodCallHandler(SystemChannels.processText, null);
      });

      await tester.pumpMarkdownWidget(
        _host(
          MarkdownMessageContent(
            data: 'Fixed paragraph.\n\n${prefix}Growing paragraph',
            streaming: true,
          ),
        ),
      );
      await tester.pump();
      const initializationMethods = [
        'Clipboard.hasStrings',
        'LiveText.isLiveTextInputAvailable',
        'ProcessText.queryTextActions',
      ];
      final baseline = {
        for (final method in initializationMethods) method: calls[method] ?? 0,
      };
      // Ensure the mocks observe the native initialization being regressed.
      for (final count in baseline.values) {
        expect(count, greaterThan(0));
      }
      for (var update = 1; update <= 4; update++) {
        await tester.pumpMarkdownWidget(
          _host(
            MarkdownMessageContent(
              data:
                  'Fixed paragraph.\n\n${prefix}Growing paragraph${' more' * update}',
              streaming: true,
            ),
          ),
        );
        await tester.pump();
        expect({
          for (final method in initializationMethods)
            method: calls[method] ?? 0,
        }, baseline);
        expect(tester.takeException(), isNull);
      }
    });
  }

  for (final (kind, prefix) in [
    ('paragraphs', ''),
    ('headings', '### '),
    ('list items', '- '),
    ('quotes', '> '),
  ]) {
    testWidgets('equal-text $kind retain distinct state and current links', (
      tester,
    ) async {
      final key = GlobalKey();
      final calls = <String>[];
      Widget content(String source, String owner) => _host(
        BlockReusingMarkdownBody(
          key: key,
          data: source,
          selectable: true,
          onTapLink: (_, href, _) => calls.add('$owner $href'),
        ),
      );
      await tester.pumpMarkdownWidget(
        content(
          '$prefix[Repeat](https://example.test/first)\n\n'
              '$prefix[Repeat](https://example.test/second)',
          'old',
        ),
      );
      final before = _texts(tester);
      expect(before, hasLength(2));
      expect(before.map((text) => text.textSpan!.toPlainText()), [
        'Repeat',
        'Repeat',
      ]);
      final firstState = tester.state(find.byWidget(before.first));
      final secondState = tester.state(find.byWidget(before.last));
      expect(firstState, isNot(same(secondState)));
      final firstEditable = _editable(tester, before.first);
      final secondEditable = _editable(tester, before.last);

      await tester.pumpMarkdownWidget(
        content(
          '$prefix[Repeat](https://example.test/updated) **bold** `code`\n\n'
              '$prefix[Repeat](https://example.test/second)',
          'new',
        ),
      );
      final after = _texts(tester);
      expect(after, hasLength(2));
      expect(tester.state(find.byWidget(after.first)), same(firstState));
      expect(tester.state(find.byWidget(after.last)), same(secondState));
      expect(_editable(tester, after.first), same(firstEditable));
      expect(_editable(tester, after.last), same(secondEditable));
      // List items share one AST block, so their widgets update together;
      // their mounted controls above must still survive independently.
      if (kind != 'list items') expect(after.last, same(before.last));
      expect(after.first.textSpan!.toPlainText(), 'Repeat bold code');
      expect(firstEditable.widget.controller.text, 'Repeat bold code');
      expect(
        _spans(
          after.first,
        ).any((span) => span.style?.fontWeight == FontWeight.bold),
        isTrue,
      );
      for (final text in after) {
        final links = _spans(text)
            .map((span) => span.recognizer)
            .whereType<TapGestureRecognizer>()
            .toSet()
            .toList();
        expect(links, hasLength(1));
        final editable = _editable(tester, text).renderEditable;
        await tester.tapAt(
          editable.localToGlobal(
            editable.getLocalRectForCaret(const TextPosition(offset: 3)).center,
          ),
        );
        await tester.pump();
      }
      expect(calls, [
        'new https://example.test/updated',
        'new https://example.test/second',
      ]);
      await tester.pumpMarkdownWidget(const SizedBox());
      expect(firstEditable.mounted, isFalse);
      expect(secondEditable.mounted, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  final transformations = <String, (String, String)>{
    'heading': ('Heading', 'Heading\n---'),
    'list': ('A paragraph', '- A paragraph\n- Another item'),
    'table': ('| A | B |', '| A | B |\n| --- | --- |\n| a | **b** |'),
  };
  for (final fixture in transformations.entries) {
    final reference = fixture.key == 'table' ? 'fresh adaptive table' : 'stock';
    testWidgets(
      'selected paragraph becoming ${fixture.key} matches $reference',
      (tester) async {
        final key = GlobalKey();
        await tester.pumpMarkdownWidget(
          _host(
            BlockReusingMarkdownBody(
              key: key,
              data: fixture.value.$1,
              selectable: true,
            ),
          ),
        );
        final before = _texts(tester).single;
        final oldState = tester.state(find.byWidget(before));
        await _select(
          tester,
          _editable(tester, before),
          TextSelection(
            baseOffset: 0,
            extentOffset: before.textSpan!.toPlainText().length,
          ),
        );
        await tester.pumpMarkdownWidget(
          _host(
            BlockReusingMarkdownBody(
              key: key,
              data: fixture.value.$2,
              selectable: true,
            ),
          ),
        );
        expect(oldState.mounted, isFalse);
        if (fixture.key == 'table') {
          expect(find.byType(Table), findsOneWidget);
          expect(
            _texts(tester).map((text) => text.textSpan!.toPlainText()).toList(),
            ['A', 'B', 'a', 'b'],
          );
        }
        for (final text in _texts(tester)) {
          final value = _editable(tester, text).widget.controller.value;
          if (value.selection.isValid) {
            expect(value.selection.start, greaterThanOrEqualTo(0));
            expect(value.selection.end, lessThanOrEqualTo(value.text.length));
          }
        }
        final rendered = _rendered(tester);
        await tester.pumpMarkdownWidget(
          _host(
            fixture.key == 'table'
                ? BlockReusingMarkdownBody(
                    data: fixture.value.$2,
                    selectable: true,
                  )
                : MarkdownBody(data: fixture.value.$2, selectable: true),
          ),
        );
        expect(_rendered(tester), rendered);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('growing prose honors refreshed theme and enlarged text', (
    tester,
  ) async {
    final key = GlobalKey();
    for (final dark in [false, true]) {
      await tester.pumpMarkdownWidget(
        _host(
          BlockReusingMarkdownBody(key: key, data: 'Start', selectable: true),
          dark: !dark,
        ),
      );
      const source = 'Start with **bold** and [link](https://example.test).';
      await tester.pumpMarkdownWidget(
        _host(
          BlockReusingMarkdownBody(key: key, data: source, selectable: true),
          dark: dark,
          scale: 2,
        ),
      );
      final rendered = _rendered(tester);
      expect(_texts(tester).single.textScaler!.scale(10), 20);
      await tester.pumpMarkdownWidget(
        _host(
          const MarkdownBody(data: source, selectable: true),
          dark: dark,
          scale: 2,
        ),
      );
      expect(_rendered(tester), rendered);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('rewriting and removing selected prose leaves no stale range', (
    tester,
  ) async {
    final key = GlobalKey();
    Widget content(String source) => _host(
      BlockReusingMarkdownBody(key: key, data: source, selectable: true),
    );
    const source = 'A selected paragraph with a long ending.';
    await tester.pumpMarkdownWidget(content(source));
    await _select(
      tester,
      _editable(tester, _texts(tester).single),
      TextSelection(baseOffset: 2, extentOffset: source.length),
    );
    await tester.pumpMarkdownWidget(content('Tiny'));
    final editable = _editable(tester, _texts(tester).single);
    expect(editable.widget.controller.text, 'Tiny');
    expect(editable.widget.controller.selection.isValid, isFalse);
    await tester.pumpMarkdownWidget(content(''));
    expect(find.byType(SelectableText), findsNothing);
    expect(editable.mounted, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final (tag, prefix) in [
    ('p', ''),
    ('h3', '### '),
    ('li', '- '),
    ('p', '> '),
  ]) {
    testWidgets(
      'custom $tag builder in $prefix keeps its key and interaction',
      (tester) async {
        var taps = 0;
        final builder = _CustomParagraphBuilder(() => taps++);
        final builders = <String, MarkdownElementBuilder>{tag: builder};
        final key = GlobalKey();
        for (final source in ['Paragraph', 'Paragraph grows']) {
          await tester.pumpMarkdownWidget(
            _host(
              BlockReusingMarkdownBody(
                key: key,
                data: '$prefix$source',
                selectable: true,
                builders: builders,
                fitContent: false,
              ),
            ),
          );
          final text = _texts(tester).single;
          expect(text.key, const ValueKey('custom-paragraph'));
          expect(text.textSpan!.toPlainText(), 'Custom $source');
          expect(text.maxLines, 3);
          await tester.tap(find.byWidget(text));
          await tester.pump();
          expect(tester.takeException(), isNull);
          final rendered = _rendered(tester);
          await tester.pumpMarkdownWidget(
            _host(
              MarkdownBody(
                data: '$prefix$source',
                selectable: true,
                builders: builders,
                fitContent: false,
              ),
            ),
          );
          expect(_rendered(tester), rendered);
        }
        expect(taps, 2);
      },
    );
  }

  testWidgets(
    'growing inline deliverable keeps rendering and current actions',
    (tester) async {
      final calls = <String>[];
      Widget content(String source, String owner) => _host(
        MarkdownMessageContent(
          data: source,
          streaming: true,
          deliverables: true,
          onOpenRemoteFile: (output) async {
            calls.add('$owner open ${output.path}');
          },
          onDownloadRemoteFile: (output) async {
            calls.add('$owner download ${output.path}');
            return false;
          },
        ),
      );
      await tester.pumpMarkdownWidget(
        content('Read [Report](/srv/report.md) now.', 'old'),
      );
      expect(find.byType(DeliverableAttachment), findsOneWidget);
      await tester.pumpMarkdownWidget(
        content('Read [Report](/srv/report.md) now. More follows.', 'new'),
      );
      expect(find.byType(DeliverableAttachment), findsOneWidget);
      expect(
        _texts(tester).map((text) => text.textSpan!.toPlainText()).join(),
        contains('More follows.'),
      );
      await tester.tap(find.byTooltip('Open preview'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Download'));
      await tester.pumpAndSettle();
      expect(calls, ['new open /srv/report.md', 'new download /srv/report.md']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('focus loss during append does not restore a cleared selection', (
    tester,
  ) async {
    final key = GlobalKey();
    final otherFocus = FocusNode();
    addTearDown(otherFocus.dispose);
    Widget content(String source) => _host(
      Column(
        children: [
          BlockReusingMarkdownBody(key: key, data: source, selectable: true),
          Focus(focusNode: otherFocus, child: const SizedBox()),
        ],
      ),
    );
    await tester.pumpMarkdownWidget(content('Selected paragraph'));
    final editable = _editable(tester, _texts(tester).single);
    editable.widget.focusNode.requestFocus();
    await tester.pump();
    expect(editable.widget.focusNode.hasFocus, isTrue);
    await _select(
      tester,
      editable,
      const TextSelection(baseOffset: 0, extentOffset: 8),
    );
    // Run after the append rebuild but before deferred selection restoration.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      otherFocus.requestFocus();
      FocusManager.instance.applyFocusChangesIfNeeded();
    });
    await tester.pumpMarkdownWidget(content('Selected paragraph grows'));
    expect(otherFocus.hasFocus, isTrue);
    expect(_editable(tester, _texts(tester).single), same(editable));
    expect(editable.widget.controller.text, 'Selected paragraph grows');
    expect(editable.widget.controller.selection.isValid, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opaque inline selectable keeps its custom properties', (
    tester,
  ) async {
    var taps = 0;
    final custom = SelectableText.rich(
      const TextSpan(text: 'custom', children: []),
      key: UniqueKey(),
      maxLines: 3,
      onTap: () => taps++,
    );
    final builders = <String, MarkdownElementBuilder>{
      'custom': _CustomInlineBuilder(custom),
    };
    final nodes = <md.Node>[
      md.Element('p', [md.Element('custom', [])]),
    ];
    await tester.pumpMarkdownWidget(
      _host(
        BlockReusingMarkdownBody(
          data: '',
          parsedNodes: nodes,
          selectable: true,
          builders: builders,
        ),
      ),
    );
    expect(_texts(tester).single, same(custom));
    expect(_texts(tester).single.maxLines, 3);
    final rendered = _rendered(tester);
    await tester.tap(find.byWidget(custom));
    await tester.pump();
    await tester.pumpMarkdownWidget(
      _host(
        Builder(
          builder: (context) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: MarkdownBuilder(
              delegate: _StockDelegate(context),
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
              selectable: true,
              imageDirectory: null,
              sizedImageBuilder: null,
              checkboxBuilder: null,
              bulletBuilder: null,
              builders: builders,
              paddingBuilders: {},
              listItemCrossAxisAlignment:
                  MarkdownListItemCrossAxisAlignment.baseline,
            ).build(nodes),
          ),
        ),
      ),
    );
    expect(_texts(tester).single, same(custom));
    expect(_rendered(tester), rendered);
    await tester.tap(find.byWidget(custom));
    await tester.pump();
    expect(taps, 2);
    expect(tester.takeException(), isNull);
  });
}

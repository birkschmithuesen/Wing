import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:wing/core/presentation/source_highlighting.dart';
import 'package:wing/core/presentation/source_language.dart';
import 'package:wing/core/presentation/tool_activity_details.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/markdown_code_block.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';
import 'package:wing/core/widgets/source_code_block.dart';
import 'package:wing/core/widgets/source_code_text.dart';
import 'package:wing/core/widgets/tool_activity_details.dart';

import 'helpers/pump_markdown_widget.dart';

const python =
    '# Keep indentation and Unicode: café 🦋\n'
    'def greet(name):\n'
    '    return f"Hello, {name}!"\n'
    'print(greet("Wing"))\n';
const shell =
    '# Quote the original filename\n'
    'for file in *.py; do\n'
    '  python3 "\$file" --limit 42\n'
    'done\n';

List<SourceToken> tokens(
  String text,
  String? language, {
  bool numbered = false,
}) => highlightSource(SourceHighlightRequest(text, language, numbered));

String selected(CodeEditor editor) => editor.controller!.text;

TextSpan renderedSpan(WidgetTester tester, [Finder? finder]) {
  final target = finder ?? find.byType(CodeEditor).first;
  final editor = tester.widget<CodeEditor>(target);
  final controller = editor.controller!;
  return TextSpan(
    children: [
      for (var i = 0; i < controller.codeLines.length; ++i) ...[
        if (i > 0) const TextSpan(text: '\n'),
        ...controller
            .buildTextSpan(
              context: tester.element(target),
              index: i,
              textSpan: TextSpan(text: controller.codeLines[i].text),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            )
            .children!,
      ],
    ],
  );
}

Future<void> settleSource(WidgetTester tester) async {
  for (var attempt = 0; attempt < 500; ++attempt) {
    final views = tester.widgetList<SourceCodeText>(
      find.byType(SourceCodeText),
    );
    final pending = views.any((view) {
      if (!view.highlightingEnabled ||
          !sourceHighlightEligible(
            SourceHighlightRequest(
              view.text,
              view.language,
              view.numberedLines,
            ),
          )) {
        return false;
      }
      final finder = find.descendant(
        of: find.byWidget(view),
        matching: find.byType(CodeEditor),
      );
      final span = renderedSpan(tester, finder);
      return !span.children!.any(
        (span) => (span as TextSpan).style?.color != null,
      );
    });
    if (!pending) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  fail('Source did not publish its latest highlighted snapshot.');
}

void main() {
  test('display segments preserve complete Unicode grapheme clusters', () {
    const cluster = '👨‍👩‍👧‍👦';
    final document = SourceDocument.literal(
      '${'a' * 10}$cluster'
      'éé\n',
    );
    final lines = document.displayLines(segmentLength: 12);
    expect(lines.map((line) => document.text.substring(line.start, line.end)), [
      'a' * 10,
      cluster,
      'éé',
      '',
    ]);
  });

  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_SOURCE')) return;
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
      'monospace': 'DejaVuSansMono.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(
              'build/tool-fonts/${entry.value}',
            ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
          ))
          .load();
    }
  });

  for (final sample in <(String, String)>[
    ('python', python),
    ('bash', shell),
    ('sh', shell),
    ('shell', shell),
    ('json', '{"ready": true, "count": 42}'),
    ('html', '<div class="result">Wing</div>'),
    ('tsx', 'const view = <div title="Wing">{42}</div>;'),
    ('yaml', 'ready: true\nname: Wing\n'),
  ]) {
    test('${sample.$1} colors known source without changing a character', () {
      final result = tokens(sample.$2, sample.$1);
      expect(result.map((token) => token.text).join(), sample.$2);
      expect(result.where((token) => token.scope != null), isNotEmpty);
    });
  }

  test('unlabelled, unsupported and explicit text never guess a language', () {
    for (final language in [null, 'text', 'not-a-language']) {
      final result = tokens(python, language);
      expect(result, [(text: python, scope: null)]);
    }
  });

  test(
    'large and dense source retains bytes and syntax without admission caps',
    () {
      for (final sample in [
        (python * 400, 'python'),
        (
          '[${List.generate(2000, (i) => '{"id":$i,"name":"Wing"}').join(',')}]',
          'json',
        ),
        (List.generate(3002, (i) => '$i|x=42').join('\n'), 'python'),
      ]) {
        final request = SourceHighlightRequest(sample.$1, sample.$2, false);
        expect(sourceHighlightEligible(request), isTrue);
        final result = highlightSource(request);
        expect(result.map((token) => token.text).join(), sample.$1);
        expect(result.where((token) => token.scope != null), isNotEmpty);
      }
      expect(
        sourceHighlightEligible(
          const SourceHighlightRequest(python, null, false),
        ),
        isFalse,
      );
    },
  );

  testWidgets(
    'large document selections retain offscreen bytes after scrolling',
    (tester) async {
      final source = List.generate(
        3002,
        (i) => '$i|{"id": $i, "ready": true}',
      ).join('\n');
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: Scaffold(
            body: SourceCodeText(
              text: source,
              language: 'json',
              numberedLines: true,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ),
        ),
      );
      await settleSource(tester);
      final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
      expect(editor.readOnly, isTrue);
      final controller = editor.controller!;
      controller.selectAll();
      expect(controller.selectedText, source);
      controller.selection = const CodeLineSelection(
        baseIndex: 10,
        baseOffset: 3,
        extentIndex: 2999,
        extentOffset: 7,
      );
      final lines = source.split('\n');
      expect(
        controller.selectedText,
        [
          lines[10].substring(3),
          ...lines.sublist(11, 2999),
          lines[2999].substring(0, 7),
        ].join('\n'),
      );
      final scroll = editor.scrollController!.verticalScroller;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      expect(scroll.offset, scroll.position.maxScrollExtent);
      expect(scroll.offset, greaterThan(0));
      expect(
        controller.selectedText.startsWith(lines[10].substring(3)),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'long wrapped JSON segments copy and rewrap without invented newlines',
    (tester) async {
      final source =
          '{"unicode": "${'café 👨‍👩‍👧‍👦 🦋 ' * 1200}", "ready": true}\r\n';
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
      Widget app(bool wrap) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: SourceCodeText(
              key: const ValueKey('source'),
              text: source,
              language: 'json',
              wrap: wrap,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(true));
      await settleSource(tester);
      final semanticsHandle = tester.ensureSemantics();
      try {
        var editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
        final controller = editor.controller!;
        expect(controller.codeLines.length, greaterThan(10));
        controller.selectAll();
        expect(controller.selectedText, source);
        await controller.copy();
        expect(copied, source);
        await tester.pump();
        final semantics = tester.getSemantics(
          find.bySemanticsLabel('Source text'),
        );
        expect(semantics.getSemanticsData().value, source);
        expect(
          semantics.getSemanticsData().textSelection,
          TextSelection(baseOffset: 0, extentOffset: source.length),
        );
        semantics.owner!.performAction(
          semantics.id,
          ui.SemanticsAction.setSelection,
          {'base': 200, 'extent': 1100},
        );
        expect(controller.selectedText, source.substring(200, 1100));
        controller.selection = const CodeLineSelection(
          baseIndex: 1,
          baseOffset: 3,
          extentIndex: 3,
          extentOffset: 7,
        );
        final selection = controller.selectedText;
        expect(selection.contains('\n'), isFalse);
        await tester.pumpWidget(app(false));
        editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
        expect(editor.controller, same(controller));
        expect(controller.selectedText, selection);
        expect(controller.codeLines.length, 2);
        expect(
          controller
              .buildTextSpan(
                context: tester.element(find.byType(CodeEditor)),
                index: 0,
                textSpan: const TextSpan(),
                style: const TextStyle(),
              )
              .toPlainText(),
          source.substring(0, source.length - 1),
        );
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      } finally {
        semanticsHandle.dispose();
      }
    },
  );

  testWidgets('long chat fences use a wrapped lazy viewport by default', (
    tester,
  ) async {
    final source = '[${'{"ready":true,"count":42},' * 2000}{"ready":false}]';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownCodeBlock(
            code: source,
            language: 'json',
            highlightingEnabled: false,
          ),
        ),
      ),
    );
    final view = tester.widget<SourceCodeText>(find.byType(SourceCodeText));
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    expect(view.wrap, isTrue);
    expect(editor.wordWrap, isTrue);
    expect(editor.controller!.codeLines.length, greaterThan(10));
    expect(editor.controller!.text, source);
    editor.controller!.selectAll();
    expect(editor.controller!.selectedText, source);
    expect(tester.takeException(), isNull);
  });

  testWidgets('live fences stay literal until the response completes', (
    tester,
  ) async {
    Widget app(String code, {required bool streaming, bool closed = true}) =>
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: Scaffold(
            body: SingleChildScrollView(
              child: MarkdownMessageContent(
                data: '```python\n$code${closed ? '\n```' : ''}',
                streaming: streaming,
              ),
            ),
          ),
        );
    for (final code in ['print("first")', python, '$python# latest']) {
      await tester.pumpMarkdownWidget(app(code, streaming: true));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      final view = tester.widget<SourceCodeText>(find.byType(SourceCodeText));
      expect(view.highlightingEnabled, isFalse);
      expect(
        renderedSpan(
          tester,
        ).children!.where((span) => (span as TextSpan).style?.color != null),
        isEmpty,
      );
      expect(selected(tester.widget(find.byType(CodeEditor))), view.text);
      expect(find.byTooltip('Copy code'), findsOneWidget);
      expect(find.byTooltip('Scroll horizontally'), findsOneWidget);
    }
    final before = tester.state(find.byType(SourceCodeText));
    final originalEditor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    final sourceController = originalEditor.controller!;
    sourceController.selectAll();
    final originalEditorValue = sourceController.value;
    final originalSelection = sourceController.selectedText;
    await tester.pumpMarkdownWidget(app('$python# latest', streaming: false));
    expect(
      tester.widget<CodeEditor>(find.byType(CodeEditor)),
      same(originalEditor),
      reason: 'Final highlighting does not rebuild an unchanged editor view.',
    );
    expect(
      sourceController.value,
      same(originalEditorValue),
      reason: 'Enabling final highlighting must not replace unchanged text.',
    );
    await settleSource(tester);
    expect(tester.state(find.byType(SourceCodeText)), same(before));
    expect(sourceController.selectedText, originalSelection);
    expect(sourceController.value, same(originalEditorValue));
    expect(renderedSpan(tester).children, isNotEmpty);
    await tester.pumpMarkdownWidget(
      app(python, streaming: false, closed: false),
    );
    expect(
      tester
          .widget<SourceCodeText>(find.byType(SourceCodeText))
          .highlightingEnabled,
      isFalse,
    );
    expect(
      renderedSpan(
        tester,
      ).children!.where((span) => (span as TextSpan).style?.color != null),
      isEmpty,
    );
    for (final streaming in [true, false]) {
      final blocks = splitMarkdownCodeBlocks(
        '```python\n$python```',
        streaming: streaming,
      );
      expect(
        (blocks.single as MarkdownCodeBlock).highlightingEnabled,
        !streaming,
      );
    }
  });

  testWidgets('unchanged syntax spans survive parent and wrap rebuilds', (
    tester,
  ) async {
    Widget app() => MaterialApp(
      theme: wingTheme(Brightness.dark),
      home: const Scaffold(
        body: SingleChildScrollView(
          child: SourceCodeBlock(
            code: python,
            language: 'python',
            headerAction: null,
          ),
        ),
      ),
    );
    await tester.pumpWidget(app());
    await settleSource(tester);
    final original = renderedSpan(tester);
    final state = tester.state(find.byType(SourceCodeText));
    await tester.pumpWidget(app());
    expect(renderedSpan(tester), equals(original));
    await tester.tap(find.byTooltip('Scroll horizontally'));
    await tester.pump();
    expect(tester.state(find.byType(SourceCodeText)), same(state));
    expect(renderedSpan(tester), equals(original));
    expect(tester.takeException(), isNull);
  });

  test(
    'receipt line numbers retain exact bytes and multiline grammar context',
    () {
      const receipt =
          '40|def f():\n41|    message = """first\n'
          '42|second"""\n43|    return message\n';
      final result = tokens(receipt, 'python', numbered: true);
      expect(result.map((token) => token.text).join(), receipt);
      expect(
        result
            .where((token) => token.scope == 'wing-line-number')
            .map((token) => token.text),
        ['40|', '41|', '42|', '43|'],
      );
      expect(
        result
            .where((token) => token.scope == 'string')
            .map((token) => token.text)
            .join(),
        contains('first\nsecond'),
      );
      for (final literal in ['', '1|', 'bad|\tvalue\r\n3|🦋\n', '1|\n2|\n']) {
        expect(
          tokens(
            literal,
            'python',
            numbered: true,
          ).map((token) => token.text).join(),
          literal,
        );
      }
    },
  );

  for (final name in ['execute_code', 'browser_exec']) {
    test(
      '$name highlights submitted code and keeps console output literal',
      () {
        final details = ToolActivityDetails.project(
          name: name,
          input: {'code': python},
          output: {'output': 'def is printed text', 'exit_code': 0},
        );
        expect(details.request.first.language, 'python');
        expect(details.request.first.copyText, python);
        final output = details.response.where(
          (b) => b.role == ToolDetailRole.output,
        );
        expect(output, isNotEmpty);
        expect(output.map((b) => b.language), everyElement(isNull));
        expect(output.map((b) => b.copyText), contains('def is printed text'));
      },
    );
  }
  test('terminal highlights the command and keeps its output literal', () {
    final terminal = ToolActivityDetails.project(
      name: 'terminal',
      input: {'command': shell},
      output: {'output': 'ready\n', 'exit_code': 0},
    );
    expect(terminal.request.single.language, 'bash');
    expect(terminal.response.single.language, isNull);
    expect(terminal.response.single.copyText, 'ready\n');
  });
  for (final entry in {
    'a.py': 'python',
    'a.sh': 'bash',
    'a.json': 'json',
    'a.txt': null,
  }.entries) {
    test(
      'read_file preserves partial ${entry.key} source and its language',
      () {
        final read = ToolActivityDetails.project(
          name: 'read_file',
          input: {'path': entry.key},
          output: {
            'content': '1|print("Wing")',
            'total_lines': 5,
            'truncated': true,
          },
        );
        expect(read.response.first.language, entry.value);
        expect(read.response.first.copyText, '1|print("Wing")');
        expect(read.metadata, contains('Partial file returned'));
      },
    );
    test('write_file derives ${entry.key} language from the destination', () {
      final write = ToolActivityDetails.project(
        name: 'write_file',
        input: {'path': entry.key, 'content': python},
        output: null,
      );
      expect(write.request.single.language, entry.value);
      expect(write.request.single.copyText, python);
    });
    test('patch separates ${entry.key} source from its resulting diff', () {
      final patch = ToolActivityDetails.project(
        name: 'patch',
        input: {
          'path': entry.key,
          'old_string': 'before',
          'new_string': 'after',
        },
        output: {'diff': '-before\n+after'},
      );
      expect(patch.request, isNotEmpty);
      expect(patch.request.map((b) => b.language), everyElement(entry.value));
      expect(patch.response.single.format, ToolDetailFormat.diff);
      expect(patch.response.single.copyText, '-before\n+after');
    });
  }
  test('source language accepts Windows paths and uppercase extensions', () {
    expect(sourceLanguageForPath(r'C:\work\demo.PY'), 'python');
  });
  test('extracted documents remain literal despite a source extension', () {
    final extracted = ToolActivityDetails.project(
      name: 'read_file',
      input: {'path': 'document.py'},
      output: {
        'content': '1|plain extracted prose',
        'extracted_document': true,
      },
    );
    expect(extracted.response.first.language, isNull);
    expect(extracted.response.first.copyText, '1|plain extracted prose');
  });

  test('source palette is readable on both Studio content surfaces', () {
    for (final brightness in Brightness.values) {
      final colors = WingTokens.forBrightness(brightness);
      for (final scope in [
        'keyword',
        'string',
        'number',
        'title',
        'variable',
        'comment',
      ]) {
        final foreground = colors.sourceColor(scope)!.computeLuminance();
        for (final background in [colors.surface, colors.raised]) {
          final back = background.computeLuminance();
          final contrast = foreground > back
              ? (foreground + 0.05) / (back + 0.05)
              : (back + 0.05) / (foreground + 0.05);
          expect(
            contrast,
            greaterThanOrEqualTo(4.5),
            reason: '$brightness $scope',
          );
        }
      }
    }
  });

  for (final intent in [
    'replacement',
    'theme change',
    'wrap and copy',
    'large source copy',
    'retirement',
  ]) {
    testWidgets('source $intent preserves the document', (tester) async {
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
      Widget app(String text, Brightness brightness) => MaterialApp(
        theme: wingTheme(brightness),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SourceCodeBlock(
              code: text,
              language: 'python',
              headerAction: null,
            ),
          ),
        ),
      );

      switch (intent) {
        case 'replacement':
          await tester.pumpWidget(app('print("old")', Brightness.dark));
          await tester.pumpWidget(app('print("new")', Brightness.dark));
          await tester.pumpWidget(app(python, Brightness.dark));
          await settleSource(tester);
          expect(selected(tester.widget(find.byType(CodeEditor))), python);
          expect(
            renderedSpan(tester).children!.where(
              (span) => (span as TextSpan).style?.color != null,
            ),
            isNotEmpty,
          );
        case 'theme change':
          await tester.pumpWidget(app(python, Brightness.dark));
          await settleSource(tester);
          final darkSpan = renderedSpan(tester);
          await tester.pumpWidget(app(python, Brightness.light));
          // Existing highlights remain visible while the theme transition and
          // replacement worker result settle. Wait for the changed palette,
          // not merely for any already-highlighted text.
          final darkColors = darkSpan.children!
              .map((span) => (span as TextSpan).style?.color)
              .toList();
          for (var attempt = 0; attempt < 100; attempt++) {
            await tester.pump(const Duration(milliseconds: 16));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            final colors = renderedSpan(
              tester,
            ).children!.map((span) => (span as TextSpan).style?.color);
            if (colors.any((color) => color != null) &&
                !equals(darkColors).matches(colors, {})) {
              break;
            }
          }
          final lightSpan = renderedSpan(tester);
          expect(lightSpan.toPlainText(), python);
          expect(
            lightSpan.children!.where(
              (span) => (span as TextSpan).style?.color != null,
            ),
            isNotEmpty,
          );
          expect(
            lightSpan.children!.map((span) => (span as TextSpan).style?.color),
            isNot(
              darkSpan.children!.map((span) => (span as TextSpan).style?.color),
            ),
          );
        case 'wrap and copy':
          await tester.pumpWidget(app(python, Brightness.dark));
          await settleSource(tester);
          await tester.tap(find.byTooltip('Scroll horizontally'));
          await tester.pump();
          await settleSource(tester);
          expect(selected(tester.widget(find.byType(CodeEditor))), python);
          await tester.tap(find.byTooltip('Copy code'));
          await tester.pump();
          expect(copied, python);
        case 'large source copy':
          final source = python * 400;
          await tester.pumpWidget(app(source, Brightness.light));
          await settleSource(tester);
          expect(selected(tester.widget(find.byType(CodeEditor))), source);
          expect(
            renderedSpan(tester).children!.where(
              (span) => (span as TextSpan).style?.color != null,
            ),
            isNotEmpty,
          );
          await tester.tap(find.byTooltip('Copy code'));
          await tester.pump();
          expect(copied, source);
        case 'retirement':
          await tester.pumpWidget(app('print("pending")', Brightness.light));
          expect(find.byType(CodeEditor), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 150)),
          );
          await tester.pump();
          expect(find.byType(CodeEditor), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('source viewer wrap and copy in $brightness at $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();
        try {
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
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          for (final block in [
            ToolDetailBlock(
              label: 'Code',
              text: '$python${'print("${'long ' * 30}")\n' * 10}',
              copyable: true,
              format: ToolDetailFormat.source,
              language: 'python',
            ),
            ToolDetailBlock(
              label: 'Command',
              text: shell * 8,
              copyable: true,
              format: ToolDetailFormat.source,
              language: 'bash',
            ),
            ToolDetailBlock(
              label: 'Result',
              text: '40|def f():\n41|    return "café 🦋"\n' * 12,
              copyable: true,
              format: ToolDetailFormat.source,
              language: 'python',
              numberedLines: true,
            ),
          ]) {
            final boundary = GlobalKey();
            await tester.pumpWidget(
              MaterialApp(
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: RepaintBoundary(key: boundary, child: child!),
                ),
                home: Scaffold(
                  body: SingleChildScrollView(
                    child: ActivityDetailsCard(
                      children: [ActivityDetailSection(block: block)],
                    ),
                  ),
                ),
              ),
            );
            await settleSource(tester);
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip('Open ${block.label}'));
            await tester.pumpAndSettle();
            await settleSource(tester);
            final state = tester.state(find.byType(SourceCodeText));
            final span = renderedSpan(tester);
            final horizontal = find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.right,
            );
            final wrappedWidth = tester
                .getSize(find.byType(SourceCodeText))
                .width;
            for (final wrap in [true, false, true]) {
              final label = wrap
                  ? 'Scroll ${block.label} horizontally'
                  : 'Wrap ${block.label}';
              expect(find.byTooltip(label), findsOneWidget);
              expect(
                tester
                    .getSemantics(find.byTooltip(label))
                    .getSemanticsData()
                    .tooltip,
                label,
              );
              expect(find.text(label), findsNothing);
              expect(
                tester.widget<CodeEditor>(find.byType(CodeEditor)).wordWrap,
                wrap,
              );
              expect(tester.state(find.byType(SourceCodeText)), same(state));
              expect(renderedSpan(tester), equals(span));
              expect(
                selected(tester.widget(find.byType(CodeEditor))),
                block.text,
              );
              expect(
                tester.getCenter(find.byTooltip(label)).dx,
                lessThan(
                  tester.getCenter(find.byTooltip('Copy ${block.label}')).dx,
                ),
              );
              if (!wrap && block.label == 'Code') {
                expect(
                  tester.getSize(find.byType(SourceCodeText)).width,
                  wrappedWidth,
                );
                final position = tester
                    .state<ScrollableState>(horizontal)
                    .position;
                expect(position.maxScrollExtent, greaterThan(0));
                await tester.drag(horizontal, const Offset(-100, 0));
                await tester.pumpAndSettle();
              }
              if (const bool.fromEnvironment('CAPTURE_SOURCE')) {
                await tester.runAsync(() async {
                  final render =
                      boundary.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary;
                  final image = await render.toImage();
                  final bytes = await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  final file = File(
                    'build/source-highlighting-review/viewer-${block.label}-${brightness.name}-${scale.toInt()}-$wrap.png',
                  );
                  await file.parent.create(recursive: true);
                  await file.writeAsBytes(bytes!.buffer.asUint8List());
                  image.dispose();
                });
              }
              await tester.tap(find.byTooltip('Copy ${block.label}'));
              await tester.pump();
              expect(copied, block.copyText);
              await tester.pump(const Duration(seconds: 2));
              await tester.tap(find.byTooltip(label));
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
            }
            await tester.pageBack();
            await tester.pumpAndSettle();
            await tester.pumpWidget(const SizedBox());
          }
        } finally {
          semantics.dispose();
        }
      });
      for (final family in ['chat', 'execution', 'file']) {
        testWidgets('$family source in $brightness at $scale', (tester) async {
          final width = scale == 1 ? 390.0 : 320.0;
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final boundary = GlobalKey();
          final scroll = ScrollController();
          addTearDown(scroll.dispose);
          final blocks = family == 'execution'
              ? ToolActivityDetails.project(
                  name: 'terminal',
                  input: {'command': shell},
                  output: {'output': 'processed 4 files\n', 'exit_code': 0},
                )
              : ToolActivityDetails.project(
                  name: 'read_file',
                  input: {'path': '/work/very-long-project-name/main.py'},
                  output: {
                    'content':
                        '40|def f():\n41|    text = """first\n42|second"""\n43|    return text\n',
                    'truncated': true,
                    'total_lines': 200,
                  },
                );
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
                body: RepaintBoundary(
                  key: boundary,
                  child: SingleChildScrollView(
                    controller: scroll,
                    padding: const EdgeInsets.all(8),
                    child: family == 'chat'
                        ? Column(
                            children: [
                              const SourceCodeBlock(
                                code: python,
                                language: 'python',
                                headerAction: null,
                              ),
                              const SourceCodeBlock(
                                code: shell,
                                language: 'shell',
                                headerAction: null,
                              ),
                              const SourceCodeBlock(
                                code: '{"ready": true, "count": 42}',
                                language: 'json',
                                headerAction: null,
                              ),
                            ],
                          )
                        : ActivityDetailsCard(
                            children: [
                              for (final block in [
                                ...blocks.request,
                                ...blocks.response,
                              ])
                                ActivityDetailSection(block: block),
                              if (family == 'execution')
                                ActivityDetailSection(
                                  block: ToolActivityDetails.project(
                                    name: 'execute_code',
                                    input: {'code': python},
                                    output: null,
                                  ).request.single,
                                ),
                              ActivityDetailSection(
                                block: ToolDetailBlock(
                                  label: 'Long received output',
                                  text: List.generate(
                                    25,
                                    (i) => 'line $i: def is console text',
                                  ).join('\n'),
                                  format: ToolDetailFormat.source,
                                  copyable: true,
                                ),
                              ),
                              if (family == 'file')
                                const ActivityDetailStatus(
                                  warning: true,
                                  label: 'Partial file returned',
                                ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          );
          await settleSource(tester);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byType(SourceCodeText), findsWidgets);
          for (final element in tester.widgetList<SourceCodeText>(
            find.byType(SourceCodeText),
          )) {
            final rendered = tester.widget<CodeEditor>(
              find.descendant(
                of: find.byWidget(element),
                matching: find.byType(CodeEditor),
              ),
            );
            expect(selected(rendered), element.text);
          }
          if (const bool.fromEnvironment('CAPTURE_SOURCE')) {
            await tester.runAsync(() async {
              final render =
                  boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await render.toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final destination = File(
                'build/source-highlighting-review/$family-${brightness.name}-${scale.toInt()}.png',
              );
              await destination.parent.create(recursive: true);
              await destination.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
}

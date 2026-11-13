import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:wing/core/widgets/source_code_text.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';
import 'package:wing/core/widgets/selection_viewport.dart';

import 'helpers/pump_markdown_widget.dart';
import '../tools/architecture/dart_sdk.dart';

final _text = List.generate(
  40,
  (i) => 'line $i: café 🦋 exact text',
).join('\n');

/// Marks standard Material handles without replacing their gestures or menu.
class _MarkedMaterialHandles extends MaterialTextSelectionControls
    with TextSelectionHandleControls {
  @override
  Widget buildHandle(
    BuildContext context,
    TextSelectionHandleType type,
    double textLineHeight, [
    VoidCallback? onTap,
  ]) => KeyedSubtree(
    key: ValueKey(('native-selection-handle', type)),
    child: super.buildHandle(context, type, textLineHeight, onTap),
  );
}

Future<void> _tapSelectionAction(WidgetTester tester, String label) async {
  final action = find.text(label).hitTestable();
  if (action.evaluate().isEmpty) {
    await tester.tap(
      find
          .descendant(
            of: find.byType(TextSelectionToolbar),
            matching: find.byTooltip('More'),
          )
          .hitTestable(),
    );
    await tester.pumpAndSettle();
  }
  expect(action, findsOneWidget);
  await tester.tap(action);
  await tester.pumpAndSettle();
}

Finder _nativeHandles() => find.byWidgetPredicate(
  (widget) =>
      widget.key ==
          const ValueKey((
            'native-selection-handle',
            TextSelectionHandleType.left,
          )) ||
      widget.key ==
          const ValueKey((
            'native-selection-handle',
            TextSelectionHandleType.right,
          )),
);

void _checkLinks(
  WidgetTester tester,
  EditableTextState state,
  LayerLink start,
  LayerLink end,
  Rect viewport,
) {
  final render = state.renderEditable;
  final points = render.getEndpointsForSelection(render.selection!);
  for (final entry in [(points.first, start), (points.last, end)]) {
    final visible = viewport
        .inflate(.5)
        .contains(render.localToGlobal(entry.$1.point));
    expect(
      entry.$2.leader != null,
      visible,
      reason:
          'A handle must publish a leader only for a visible selection endpoint',
    );
  }
}

Widget _host(
  Widget body, {
  Brightness brightness = Brightness.dark,
  double scale = 1,
}) => MaterialApp(
  theme: wingTheme(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(body: Center(child: body)),
);

void main() {
  String? copied;
  setUp(() {
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': copied};
          if (call.method == 'Clipboard.hasStrings') {
            return {'value': copied?.isNotEmpty ?? false};
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('clipped handles retire and restore without losing native copy', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 180,
                child: SingleChildScrollView(
                  controller: scroll,
                  child: Column(
                    children: [
                      const SizedBox(height: 60),
                      SelectionViewport(
                        child: SelectableText(
                          'Preserved',
                          selectionControls: _MarkedMaterialHandles(),
                        ),
                      ),
                      const SizedBox(height: 500),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.longPress(find.text('Preserved'));
      await tester.pumpAndSettle();
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      final selected = editable.widget.controller.selection;
      expect(selected.textInside(editable.widget.controller.text), 'Preserved');
      final handles = _nativeHandles();
      expect(handles.hitTestable(), findsNWidgets(2));

      // Move the enclosing paint clip; the selected text remains mounted.
      scroll.jumpTo(160);
      await tester.pumpAndSettle();
      expect(find.byType(EditableText), findsOneWidget);
      expect(handles.hitTestable(), findsNothing);
      expect(editable.widget.controller.selection, selected);

      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(handles.hitTestable(), findsNWidgets(2));
      expect(editable.widget.controller.selection, selected);
      await tester.longPress(find.text('Preserved'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(copied, 'Preserved');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
    expect(tester.takeException(), isNull);
  });

  test(
    'all native text selection enters the shared viewport owner',
    () async {
      final root = Directory.current.absolute.path;
      final owner = '$root/lib/core/widgets/selection_viewport.dart';
      final directory = Directory('$root/build/selection-coverage')
        ..createSync(recursive: true);
      final fixture = File('${directory.path}/coverage.dart');
      fixture.writeAsStringSync("""
import 'package:flutter/material.dart' as m;
import 'package:wing/core/widgets/selection_viewport.dart' as scope;
typedef Alias = m.SelectableText;
class HiddenInput extends m.TextField { const HiddenInput() : super(); }
class SelectableText extends m.StatelessWidget {
  const SelectableText();
  @override m.Widget build(m.BuildContext context) => const m.SizedBox();
}
m.Widget bad() => m.SelectableText('bad');
m.Widget badAlias() => Alias('bad alias');
m.Widget badSubclass() => const HiddenInput();
final constructor = m.SelectableText.new;
m.Widget badTearOff() => constructor('bad tear-off');
m.Widget good() => scope.viewportSelection(m.SelectableText('good'));
m.Widget goodAlias() => scope.viewportSelection(Alias('good alias'));
m.Widget goodSubclass() => scope.viewportSelection(const HiddenInput());
m.Widget goodTearOff() => scope.viewportSelection(constructor('good tear-off'));
m.Widget unrelated() => const SelectableText();
""");
      final contexts = AnalysisContextCollection(
        includedPaths: ['$root/lib', fixture.path],
        sdkPath: dartSdkPath(root),
      );
      try {
        final result =
            await contexts
                    .contextFor(fixture.path)
                    .currentSession
                    .getResolvedUnit(fixture.path)
                as ResolvedUnitResult;
        final proof = _ViewportCoverage(owner);
        result.unit.accept(proof);
        expect(
          proof.missing,
          [
            "m.SelectableText('bad')",
            "Alias('bad alias')",
            'const HiddenInput()',
            "constructor('bad tear-off')",
          ],
          reason:
              'Reject raw, aliased, inherited and torn-off native constructors while accepting the shared owner and unrelated types',
        );
        var count = 0;
        final files =
            Directory('$root/lib')
                .listSync(recursive: true)
                .whereType<File>()
                .where(
                  (file) => file.path.endsWith('.dart') && file.path != owner,
                )
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path));
        for (final file in files) {
          final result = await contexts
              .contextFor(file.path)
              .currentSession
              .getResolvedUnit(file.path);
          expect(result, isA<ResolvedUnitResult>(), reason: file.path);
          final coverage = _ViewportCoverage(
            owner,
            codeOwner:
                file.path == '$root/lib/core/widgets/source_code_text.dart',
          );
          (result as ResolvedUnitResult).unit.accept(coverage);
          expect(
            coverage.missing,
            isEmpty,
            reason:
                '${file.path}: native selection must enter the shared owner',
          );
          count += coverage.count;
        }
        expect(count, isPositive);
        // This count is evidence of the resolved production census, not a fixed
        // allowlist that could hide newly added controls.
        // ignore: avoid_print
        print('Viewport coverage verified $count native selection sites.');
      } finally {
        await contexts.dispose();
        fixture.deleteSync();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final kind in ['plain', 'rich', 'editable', 'form']) {
        testWidgets(
          '$kind selection survives reader clipping: $brightness/$scale',
          (tester) async {
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final scroll = ScrollController();
            addTearDown(scroll.dispose);
            final controller = TextEditingController(text: _text);
            addTearDown(controller.dispose);
            final key = GlobalKey();
            final reader = GlobalKey();
            final Widget text = switch (kind) {
              'plain' => SelectableText(_text, key: key),
              'rich' => SelectableText.rich(
                TextSpan(
                  children: [
                    TextSpan(text: _text.substring(0, 20)),
                    TextSpan(
                      text: _text.substring(20),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                key: key,
              ),
              'editable' => TextField(
                key: key,
                controller: controller,
                maxLines: null,
              ),
              _ => TextFormField(
                key: key,
                controller: controller,
                maxLines: null,
              ),
            };
            await tester.pumpWidget(
              _host(
                SizedBox(
                  key: reader,
                  width: 300,
                  height: 160,
                  child: SingleChildScrollView(
                    controller: scroll,
                    child: viewportSelection(text),
                  ),
                ),
                brightness: brightness,
                scale: scale,
              ),
            );
            await tester.pumpAndSettle();
            final state = tester.state<EditableTextState>(
              find.byType(EditableText),
            );
            final start = state.renderEditable.startHandleLayerLink;
            final end = state.renderEditable.endHandleLayerLink;
            scroll.jumpTo(100);
            await tester.pumpAndSettle();
            await tester.longPressAt(tester.getRect(find.byKey(reader)).center);
            await tester.pumpAndSettle();
            await _tapSelectionAction(tester, 'Select all');
            for (final offset in [
              100.0,
              0.0,
              scroll.position.maxScrollExtent,
            ]) {
              scroll.jumpTo(offset.clamp(0.0, scroll.position.maxScrollExtent));
              await tester.pumpAndSettle();
              _checkLinks(
                tester,
                state,
                start,
                end,
                tester.getRect(find.byKey(reader)),
              );
              expect(
                state.widget.controller.selection,
                TextSelection(baseOffset: 0, extentOffset: _text.length),
              );
            }
            await tester.pumpWidget(const SizedBox());
            await tester.pump();
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('viewport selection preserves native IME composition', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(viewportSelection(TextField(controller: controller))),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    const value = TextEditingValue(
      text: 'typing café',
      selection: TextSelection.collapsed(offset: 11),
      composing: TextRange(start: 7, end: 11),
    );
    tester.testTextInput.updateEditingValue(value);
    await tester.pump();
    expect(controller.value, value);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('nested clips retire hidden handle hit targets', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final outer = ScrollController();
    final inner = ScrollController();
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);
    const viewportKey = ValueKey('outer-reader');
    const innerKey = ValueKey('inner-reader');
    await tester.pumpWidget(
      _host(
        SizedBox(
          key: viewportKey,
          width: 300,
          height: 160,
          child: SingleChildScrollView(
            controller: outer,
            child: Column(
              children: [
                const SizedBox(height: 80),
                SizedBox(
                  key: innerKey,
                  height: 120,
                  child: SingleChildScrollView(
                    controller: inner,
                    child: viewportSelection(
                      SelectableText(
                        _text,
                        selectionControls: _MarkedMaterialHandles(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 80),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    outer.jumpTo(60);
    inner.jumpTo(100);
    await tester.pumpAndSettle();
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    final start = state.renderEditable.startHandleLayerLink;
    final end = state.renderEditable.endHandleLayerLink;
    final visible = tester
        .getRect(find.byKey(viewportKey))
        .intersect(tester.getRect(find.byKey(innerKey)));
    await tester.longPressAt(visible.center);
    await tester.pumpAndSettle();
    await _tapSelectionAction(tester, 'Select all');
    outer.jumpTo(60);
    inner.jumpTo(100);
    await tester.pumpAndSettle();
    _checkLinks(
      tester,
      state,
      start,
      end,
      tester
          .getRect(find.byKey(viewportKey))
          .intersect(tester.getRect(find.byKey(innerKey))),
    );
    expect(start.leader, isNull);
    expect(end.leader, isNull);
    expect(_nativeHandles().hitTestable(), findsNothing);
    outer.jumpTo(0);
    inner.jumpTo(0);
    await tester.pumpAndSettle();
    _checkLinks(
      tester,
      state,
      start,
      end,
      tester
          .getRect(find.byKey(viewportKey))
          .intersect(tester.getRect(find.byKey(innerKey))),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('horizontal clips track selected text endpoints', (tester) async {
    const viewportKey = ValueKey('horizontal-reader');
    final horizontal = ScrollController();
    addTearDown(horizontal.dispose);
    await tester.pumpWidget(
      _host(
        SizedBox(
          key: viewportKey,
          width: 200,
          height: 60,
          child: SingleChildScrollView(
            controller: horizontal,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: 2400,
              child: viewportSelection(
                const SelectableText(
                  'A horizontal source line with exact characters',
                  maxLines: 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final horizontalState = tester.state<EditableTextState>(
      find.byType(EditableText),
    );
    final hStart = horizontalState.renderEditable.startHandleLayerLink;
    final hEnd = horizontalState.renderEditable.endHandleLayerLink;
    await tester.longPressAt(tester.getRect(find.byKey(viewportKey)).center);
    await tester.pumpAndSettle();
    await _tapSelectionAction(tester, 'Select all');
    horizontal.jumpTo(20);
    await tester.pumpAndSettle();
    _checkLinks(
      tester,
      horizontalState,
      hStart,
      hEnd,
      tester.getRect(find.byKey(viewportKey)),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'selection areas below a clip keep exact text and hide escaped anchors',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      const reader = ValueKey('area-reader');
      String? selected;
      await tester.pumpWidget(
        _host(
          SizedBox(
            key: reader,
            width: 300,
            height: 160,
            child: SingleChildScrollView(
              controller: scroll,
              child: viewportSelection(
                SelectionArea(
                  onSelectionChanged: (content) =>
                      selected = content?.plainText,
                  child: Text(_text),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      scroll.jumpTo(100);
      await tester.pumpAndSettle();
      await tester.longPressAt(tester.getRect(find.byKey(reader)).center);
      await tester.pumpAndSettle();
      final region = tester.state<SelectableRegionState>(
        find.byType(SelectableRegion),
      );
      final start = region.selectionOverlay!.startHandleLayerLink;
      final end = region.selectionOverlay!.endHandleLayerLink;
      await _tapSelectionAction(tester, 'Select all');
      scroll.jumpTo(100);
      await tester.pumpAndSettle();
      expect(selected, _text);
      expect(start.leader, isNull);
      expect(end.leader, isNull);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('selection area restores handles and copy after reparenting', (
    tester,
  ) async {
    var moved = false;
    String? selected;
    late StateSetter rebuild;
    final reader = SelectionViewport(
      key: GlobalKey(),
      child: SelectionArea(
        selectionControls: _MarkedMaterialHandles(),
        onSelectionChanged: (content) => selected = content?.plainText,
        child: const Align(
          alignment: Alignment.centerLeft,
          child: Text('Preserved'),
        ),
      ),
    );
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 300,
                  height: 160,
                  child: moved ? const SizedBox() : reader,
                ),
                SizedBox(
                  width: 300,
                  height: 160,
                  child: moved ? reader : const SizedBox(),
                ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Preserved'));
    await tester.pumpAndSettle();
    expect(selected, 'Preserved');
    expect(_nativeHandles().hitTestable(), findsNWidgets(2));

    rebuild(() => moved = true);
    await tester.pumpAndSettle();
    expect(selected, 'Preserved');
    expect(_nativeHandles().hitTestable(), findsNWidgets(2));
    await _tapSelectionAction(tester, 'Copy');
    expect(copied, 'Preserved');
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('code reader copies offscreen text through its selection menu', (
    tester,
  ) async {
    const reader = ValueKey('code-reader');
    await tester.pumpWidget(
      _host(
        SizedBox(
          key: reader,
          width: 300,
          height: 80,
          child: SingleChildScrollView(
            child: SourceCodeText(
              text: _text,
              language: null,
              highlightingEnabled: false,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPressAt(tester.getRect(find.byKey(reader)).center);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Select all').hitTestable());
    await tester.pumpAndSettle();
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    expect(editor.controller!.selectedText, _text);
    await tester.tap(find.byTooltip('Copy selection').hitTestable());
    await tester.pumpAndSettle();
    expect(copied, _text);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('generated reader updates every native text descendant', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    const reader = ValueKey('generated-reader');
    await tester.pumpWidget(
      _host(
        SizedBox(
          key: reader,
          width: 300,
          height: 160,
          child: SingleChildScrollView(
            controller: scroll,
            child: viewportSelection(
              Column(
                children: [
                  const SelectableText('First generated cell'),
                  SelectableText(_text),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    scroll.jumpTo(100);
    await tester.pumpAndSettle();
    final state = tester.state<EditableTextState>(
      find.byType(EditableText).last,
    );
    final start = state.renderEditable.startHandleLayerLink;
    final end = state.renderEditable.endHandleLayerLink;
    await tester.longPressAt(tester.getRect(find.byKey(reader)).center);
    await tester.pumpAndSettle();
    await _tapSelectionAction(tester, 'Select all');
    scroll.jumpTo(100);
    await tester.pumpAndSettle();
    expect(
      state.widget.controller.selection.textInside(
        state.widget.controller.text,
      ),
      _text,
    );
    _checkLinks(tester, state, start, end, tester.getRect(find.byKey(reader)));
    expect(start.leader, isNull);
    expect(end.leader, isNull);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    _checkLinks(tester, state, start, end, tester.getRect(find.byKey(reader)));
    expect(start.leader, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('generated Markdown paragraphs lists and tables use the boundary', (
    tester,
  ) async {
    await tester.pumpMarkdownWidget(
      _host(
        const SingleChildScrollView(
          child: MarkdownMessageContent(
            data: '''# Heading

Paragraph with **bold** and a [link](https://example.com).

- First list item
- Second list item

> Quoted text

| Column | Value |
| --- | --- |
| Cell | More text |
''',
          ),
        ),
      ),
    );
    final texts = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .toList();
    final renderedText = texts
        .map((text) => text.data ?? text.textSpan!.toPlainText())
        .join('\n');
    for (final content in [
      'Heading',
      'Paragraph with',
      'First list item',
      'Second list item',
      'Quoted text',
      'Column',
      'More text',
    ]) {
      expect(renderedText, contains(content));
    }
    for (final text in texts) {
      expect(
        find.ancestor(
          of: find.byWidget(text),
          matching: find.byType(SelectionViewport),
        ),
        findsWidgets,
        reason:
            'Stock Markdown must not bypass viewport-aware text selection: ${text.textSpan?.toPlainText()}',
      );
    }
    await tester.pumpWidget(const SizedBox());
  });
}

class _ViewportCoverage extends RecursiveAstVisitor<void> {
  _ViewportCoverage(this.owner, {this.codeOwner = false});
  final String owner;
  final bool codeOwner;
  final missing = <String>[];
  var count = 0;
  static const native = {
    'SelectableText',
    'SelectionArea',
    'TextField',
    'TextFormField',
    'EditableText',
    'CupertinoTextField',
    'SearchBar',
  };

  void check(Expression node) {
    final type = node.staticType;
    if (type is! InterfaceType) return;
    final kinds = [type, ...type.element.allSupertypes];
    final candidates = kinds.where(
      (kind) =>
          (kind.element.library.uri.toString().startsWith('package:flutter/') &&
              native.contains(kind.element.name)) ||
          (kind.element.library.uri.toString().startsWith(
                'package:re_editor/',
              ) &&
              kind.element.name == 'CodeEditor'),
    );
    if (candidates.isEmpty) return;
    final kind = candidates.first.element.name;
    if (codeOwner && kind == 'CodeEditor') return;
    count++;
    AstNode expression = node;
    while (expression.parent is ParenthesizedExpression ||
        expression.parent is ConditionalExpression) {
      expression = expression.parent!;
    }
    final arguments = expression.parent;
    final call = arguments?.parent;
    if (arguments is ArgumentList &&
        call is MethodInvocation &&
        call.methodName.name == 'viewportSelection' &&
        call.methodName.element?.library?.firstFragment.source.fullName ==
            owner) {
      return;
    }
    missing.add(node.toSource());
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    check(node);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    check(node);
    super.visitFunctionExpressionInvocation(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    check(node);
    super.visitMethodInvocation(node);
  }
}

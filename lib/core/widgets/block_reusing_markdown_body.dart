import 'selection_viewport.dart';
import 'adaptive_markdown_table.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'dart:convert';

import 'package:flutter/cupertino.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../services/completion_diagnostics.dart';
import 'retained_markdown_paragraph.dart';
import 'bot_mention_scope.dart';

/// Retains unchanged top-level prose blocks while a message grows.
///
/// Every update still parses the complete Markdown document, so a late link
/// reference or a new setext/table/list line can change an earlier block. Only
/// blocks with an identical resolved AST keep their widgets and recognizers.
class BlockReusingMarkdownBody extends MarkdownBody {
  const BlockReusingMarkdownBody({
    super.key,
    required super.data,
    super.selectable,
    super.styleSheet,
    super.styleSheetTheme,
    super.syntaxHighlighter,
    super.onSelectionChanged,
    super.onTapLink,
    super.onTapText,
    super.imageDirectory,
    super.blockSyntaxes,
    super.inlineSyntaxes,
    super.extensionSet,
    super.sizedImageBuilder,
    super.checkboxBuilder,
    super.bulletBuilder,
    super.builders,
    super.paddingBuilders,
    super.listItemCrossAxisAlignment,
    super.shrinkWrap,
    super.fitContent,
    super.softLineBreak,
    this.parsedNodes,
  });

  /// Background preparation supplies resolved nodes; widget work stays here.
  final List<md.Node>? parsedNodes;

  @override
  State<MarkdownWidget> createState() => _BlockReusingMarkdownBodyState();
}

class _BlockReusingMarkdownBodyState extends State<MarkdownWidget> {
  List<_RenderedBlock> _blocks = [];
  Widget? _content;
  bool _refreshBlocks = true;
  Object? _renderingInputs;
  Map<String, String>? _mentionNames;

  @override
  void initState() {
    super.initState();
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.event('markdown.blocks.init');
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final inputs = (
      Theme.of(context),
      CupertinoTheme.of(context),
      MediaQuery.sizeOf(context),
      MediaQuery.textScalerOf(context),
      Directionality.of(context),
    );
    final names = BotMentionScope.of(context)?.names;
    // Reparenting a completed answer rechecks dependencies. Keep its rendered
    // blocks when the actual environment is unchanged.
    if (_renderingInputs == inputs && mapEquals(_mentionNames, names)) return;
    _renderingInputs = inputs;
    _mentionNames = names;
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.event('markdown.blocks.dependencies');
    }
    // Match the stock renderer's theme/text-scale dependencies. Viewport width
    // also matters for the message's inline attachment and image builders.
    _content = null;
    _refreshBlocks = true;
  }

  @override
  void didUpdateWidget(covariant MarkdownWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data != oldWidget.data ||
        (widget as BlockReusingMarkdownBody).parsedNodes !=
            (oldWidget as BlockReusingMarkdownBody).parsedNodes) {
      _content = null;
      if (CompletionDiagnostics.enabled) {
        CompletionDiagnostics.event('markdown.blocks.invalidate');
      }
    }
    if (widget.selectable != oldWidget.selectable ||
        widget.styleSheet != oldWidget.styleSheet ||
        widget.styleSheetTheme != oldWidget.styleSheetTheme ||
        widget.syntaxHighlighter != oldWidget.syntaxHighlighter ||
        widget.onSelectionChanged != oldWidget.onSelectionChanged ||
        widget.onTapText != oldWidget.onTapText ||
        widget.imageDirectory != oldWidget.imageDirectory ||
        widget.blockSyntaxes != oldWidget.blockSyntaxes ||
        widget.inlineSyntaxes != oldWidget.inlineSyntaxes ||
        widget.extensionSet != oldWidget.extensionSet ||
        widget.sizedImageBuilder != oldWidget.sizedImageBuilder ||
        widget.checkboxBuilder != oldWidget.checkboxBuilder ||
        widget.bulletBuilder != oldWidget.bulletBuilder ||
        widget.builders != oldWidget.builders ||
        widget.paddingBuilders != oldWidget.paddingBuilders ||
        widget.listItemCrossAxisAlignment !=
            oldWidget.listItemCrossAxisAlignment ||
        widget.fitContent != oldWidget.fitContent ||
        widget.softLineBreak != oldWidget.softLineBreak ||
        (widget as MarkdownBody).shrinkWrap !=
            (oldWidget as MarkdownBody).shrinkWrap ||
        (widget.onTapLink == null) != (oldWidget.onTapLink == null)) {
      _content = null;
      _refreshBlocks = true;
    }
  }

  @override
  void dispose() {
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.event(
        'markdown.blocks.dispose',
        values: {'blocks': _blocks.length},
      );
    }
    for (final block in _blocks) {
      block.delegate.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_content != null) {
      if (CompletionDiagnostics.enabled) {
        CompletionDiagnostics.event('markdown.blocks.cached');
      }
      return _content!;
    }
    final buildStart = CompletionDiagnostics.enabled
        ? CompletionDiagnostics.start()
        : 0;
    MediaQuery.sizeOf(context);
    final cupertino =
        widget.styleSheetTheme == MarkdownStyleSheetBaseTheme.cupertino ||
        (widget.styleSheetTheme == MarkdownStyleSheetBaseTheme.platform &&
            (Theme.of(context).platform == TargetPlatform.iOS ||
                Theme.of(context).platform == TargetPlatform.macOS));
    final fallback = cupertino
        ? MarkdownStyleSheet.fromCupertinoTheme(CupertinoTheme.of(context))
        : MarkdownStyleSheet.fromTheme(Theme.of(context));
    final style = fallback
        .copyWith(textScaler: MediaQuery.textScalerOf(context))
        .merge(widget.styleSheet);
    final parsed =
        (widget as BlockReusingMarkdownBody).parsedNodes ??
        md.Document(
          blockSyntaxes: widget.blockSyntaxes,
          inlineSyntaxes: widget.inlineSyntaxes,
          extensionSet: widget.extensionSet ?? md.ExtensionSet.gitHubFlavored,
          encodeHtml: false,
        ).parseLines(const LineSplitter().convert(widget.data));
    final nodes = BotMentionScope.of(context)?.prose(parsed) ?? parsed;
    final next = <_RenderedBlock>[];
    // Heading padding builders mutate the AST and manage document scroll keys.
    // Keep their existing full-render behavior until their anchors are assigned
    // independently of renderer traversal.
    final refresh = _refreshBlocks || widget.paddingBuilders.isNotEmpty;
    var signatureUs = 0;
    var constructionUs = 0;
    var builderUs = 0;
    var reused = 0;
    var rendered = 0;
    for (var index = 0; index < nodes.length; index++) {
      final node = nodes[index];
      final signatureStart = CompletionDiagnostics.enabled
          ? CompletionDiagnostics.start()
          : 0;
      final signature = jsonEncode(_astValue(node));
      if (CompletionDiagnostics.enabled) {
        signatureUs += CompletionDiagnostics.start() - signatureStart;
      }
      final previous = index < _blocks.length ? _blocks[index] : null;
      if (!refresh && previous?.signature == signature) {
        next.add(previous!);
        if (CompletionDiagnostics.enabled) reused++;
        continue;
      }
      previous?.delegate.dispose();
      final delegate = _BlockDelegate(this);
      final constructionStart = CompletionDiagnostics.enabled
          ? CompletionDiagnostics.start()
          : 0;
      final builder = MarkdownBuilder(
        delegate: delegate,
        selectable: widget.selectable,
        styleSheet: style,
        imageDirectory: widget.imageDirectory,
        sizedImageBuilder: widget.sizedImageBuilder,
        checkboxBuilder: widget.checkboxBuilder,
        bulletBuilder: widget.bulletBuilder,
        builders: {
          ...widget.builders,
          _adaptiveTableTag: _AdaptiveTableBuilder((cell, heading) {
            final align = switch (cell.attributes['align']) {
              'right' => WrapAlignment.end,
              'center' => WrapAlignment.center,
              _ => WrapAlignment.start,
            };
            return BlockReusingMarkdownBody(
              data: '',
              parsedNodes: [md.Element('p', cell.children ?? [])],
              selectable: widget.selectable,
              styleSheet: style.copyWith(
                p: heading
                    ? style.p?.copyWith(fontWeight: FontWeight.w600)
                    : style.p,
                textAlign: align,
              ),
              onTapLink: widget.onTapLink,
              onSelectionChanged: widget.onSelectionChanged,
              onTapText: widget.onTapText,
              sizedImageBuilder: widget.sizedImageBuilder,
              builders: widget.builders,
              fitContent: false,
            );
          }),
        },
        paddingBuilders: widget.paddingBuilders,
        fitContent: widget.fitContent,
        listItemCrossAxisAlignment: widget.listItemCrossAxisAlignment,
        onSelectionChanged: widget.onSelectionChanged,
        onTapText: widget.onTapText,
        softLineBreak: widget.softLineBreak,
      );
      if (CompletionDiagnostics.enabled) {
        constructionUs += CompletionDiagnostics.start() - constructionStart;
      }
      final builderStart = CompletionDiagnostics.enabled
          ? CompletionDiagnostics.start()
          : 0;
      final built = builder.build([_adaptTables(node)]);
      final children =
          widget.selectable &&
              node is md.Element &&
              _retainedTextTags.contains(node.tag) &&
              !_hasCustomTextBlock(node, widget.builders)
          ? [
              for (final (position, child) in retainMarkdownText(built).indexed)
                // A grammar change (for example prose becoming a heading)
                // starts a new control lifetime even if both use a Column.
                KeyedSubtree(
                  key: ValueKey((index, node.tag, position)),
                  // Opaque nested blocks (such as stock code fences) still
                  // need the enclosing selection boundary. Retained inline
                  // controls own their nested boundaries independently.
                  child: viewportSelection(child),
                ),
            ]
          : [for (final child in built) viewportSelection(child)];
      if (CompletionDiagnostics.enabled) {
        builderUs += CompletionDiagnostics.start() - builderStart;
        rendered++;
      }
      next.add(_RenderedBlock(signature, children, delegate));
    }
    for (var index = next.length; index < _blocks.length; index++) {
      _blocks[index].delegate.dispose();
    }
    _blocks = next;
    _refreshBlocks = false;
    final children = <Widget>[];
    for (final block in _blocks) {
      if (block.children.isEmpty) continue;
      if (children.isNotEmpty) {
        children.add(SizedBox(height: style.blockSpacing));
      }
      children.addAll(block.children);
    }
    // Keep this parent even with a single block: adding a second block must
    // retain the first block's mounted selectable text and attachment state.
    final result = _content = Column(
      mainAxisSize: (widget as MarkdownBody).shrinkWrap
          ? MainAxisSize.min
          : MainAxisSize.max,
      crossAxisAlignment: widget.fitContent
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.stretch,
      children: children,
    );
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.finish(
        'markdown.blocks.build',
        buildStart,
        values: {
          'blocks': nodes.length,
          'rendered': rendered,
          'reused': reused,
          'signatureUs': signatureUs,
          'builderConstructionUs': constructionUs,
          'builderBuildUs': builderUs,
          'suppliedAst':
              (widget as BlockReusingMarkdownBody).parsedNodes != null ? 1 : 0,
          'refresh': refresh ? 1 : 0,
        },
      );
    }
    return result;
  }
}

Object _astValue(md.Node node) {
  if (node is md.Text) return ['text', node.text];
  final element = node as md.Element;
  final keys = element.attributes.keys.toList()..sort();
  return [
    element.tag,
    {for (final key in keys) key: element.attributes[key]},
    element.children?.map(_astValue).toList(),
  ];
}

class _RenderedBlock {
  _RenderedBlock(this.signature, this.children, this.delegate);
  final String signature;
  final List<Widget> children;
  final _BlockDelegate delegate;
}

class _BlockDelegate implements MarkdownBuilderDelegate {
  _BlockDelegate(this.owner);
  final _BlockReusingMarkdownBodyState owner;
  final _recognizers = <GestureRecognizer>[];

  @override
  BuildContext get context => owner.context;

  @override
  GestureRecognizer createLink(String text, String? href, String title) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () => owner.widget.onTapLink?.call(text, href, title);
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code) {
    code = code.replaceAll(RegExp(r'\n$'), '');
    return owner.widget.syntaxHighlighter?.format(code) ??
        TextSpan(style: styleSheet.code, text: code);
  }

  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }
}

const _adaptiveTableTag = 'wing-adaptive-table';

// Adapt a copy at the renderer boundary; worker snapshots and signatures retain
// their original table semantics. Nested tables in lists/quotes use the same UI.
md.Node _adaptTables(md.Node node) {
  if (node is! md.Element) return node;
  if (node.tag == 'table') return _TableElement(node);
  return md.Element(node.tag, node.children?.map(_adaptTables).toList())
    ..attributes.addAll(node.attributes);
}

class _TableElement extends md.Element {
  _TableElement(this.table) : super(_adaptiveTableTag, []);
  final md.Element table;
}

class _AdaptiveTableBuilder extends MarkdownElementBuilder {
  _AdaptiveTableBuilder(this.cellBuilder);
  final Widget Function(md.Element, bool) cellBuilder;

  @override
  bool isBlockElement() => true;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => AdaptiveMarkdownTable(
    table: (element as _TableElement).table,
    cellBuilder: cellBuilder,
  );
}

// Only these stock blocks use the layout containers understood by the retained
// text adapter. A custom block anywhere inside keeps its own control lifetime.
const _retainedTextTags = {
  'p',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'ul',
  'ol',
  'li',
  'blockquote',
};

bool _hasCustomTextBlock(
  md.Node node,
  Map<String, MarkdownElementBuilder> builders,
) =>
    node is md.Element &&
    ((builders[node.tag]?.isBlockElement() ?? false) ||
        (_retainedTextTags.contains(node.tag) &&
            builders.containsKey(node.tag)) ||
        (node.children?.any((child) => _hasCustomTextBlock(child, builders)) ??
            false));

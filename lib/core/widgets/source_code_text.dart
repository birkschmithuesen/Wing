import 'selection_viewport.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';

import '../presentation/source_highlighting.dart';
import '../services/completion_diagnostics.dart';
import '../theme/wing_theme.dart';

/// A read-only viewport over exact source, shared by chat and Activity viewers.
/// Parsing retains full grammar context; only visible display ranges get spans.
class SourceCodeText extends StatefulWidget {
  const SourceCodeText({
    super.key,
    required this.text,
    required this.language,
    required this.style,
    this.numberedLines = false,
    this.highlightingEnabled = true,
    this.wrap = true,
    this.maxHeight = 160,
    this.onOverflowChanged,
  });

  final String text;
  final String? language;
  final TextStyle style;
  final bool numberedLines;
  final bool highlightingEnabled;
  final bool wrap;
  final double maxHeight;
  final ValueChanged<bool>? onOverflowChanged;

  @override
  State<SourceCodeText> createState() => _SourceCodeTextState();
}

class _SourceCodeTextState extends State<SourceCodeText> {
  Timer? _debounce;
  late SourceDocument _document;
  late _SourceController _controller;
  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  late final _scroll = CodeScrollController(
    verticalScroller: _vertical,
    horizontalScroller: _horizontal,
  );
  int? _segmentLength;
  var _revision = 0;
  var _busy = false;
  var _ready = true;
  bool? _overflow;
  bool _refreshing = false;
  CodeIndicatorValueNotifier? _viewport;
  (TextStyle, bool)? _editorInputs;
  Widget? _editorView;

  @override
  void initState() {
    super.initState();
    _document = SourceDocument.literal(widget.text);
    _controller = _SourceController(_document);
    _prepare();
  }

  @override
  void didUpdateWidget(covariant SourceCodeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text == widget.text &&
        oldWidget.language == widget.language &&
        oldWidget.numberedLines == widget.numberedLines &&
        oldWidget.highlightingEnabled == widget.highlightingEnabled) {
      return;
    }
    ++_revision;
    // Presentation changes (including final highlighting) keep the editor's
    // line vector and selection. Replace visible text only when it changes.
    if (oldWidget.text != widget.text) {
      _document = SourceDocument.literal(widget.text);
      _controller.setDocument(_document, _segmentLength, replaceText: true);
    } else if (!widget.highlightingEnabled ||
        oldWidget.language != widget.language ||
        oldWidget.numberedLines != widget.numberedLines) {
      _document = SourceDocument.literal(widget.text);
      _controller.setDocument(_document, _segmentLength);
      _refreshViewport();
    }
    _ready = false;
    _debounce?.cancel();
    if (!widget.highlightingEnabled || !sourceHighlightEligible(_request)) {
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 80), () {
      _ready = true;
      _prepare();
    });
  }

  SourceHighlightRequest get _request => SourceHighlightRequest(
    widget.text,
    widget.language,
    widget.numberedLines,
  );

  Future<void> _prepare() async {
    if (_busy ||
        !_ready ||
        !mounted ||
        !widget.highlightingEnabled ||
        !sourceHighlightEligible(_request)) {
      return;
    }
    _busy = true;
    final revision = _revision;
    try {
      final document = await compute(
        prepareSourceDocument,
        _request,
        debugLabel: 'wing-source-highlight',
      );
      if (mounted && revision == _revision) {
        _document = document;
        _controller.setDocument(document, _segmentLength);
        _refreshViewport();
      }
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Wing source highlighting',
        ),
      );
    } finally {
      _busy = false;
      if (mounted && revision != _revision && _ready) _prepare();
    }
  }

  void _refreshViewport() {
    if (_refreshing ||
        (_vertical.hasClients &&
            _vertical.position.isScrollingNotifier.value) ||
        (_horizontal.hasClients &&
            _horizontal.position.isScrollingNotifier.value)) {
      return;
    }
    _refreshing = true;
    try {
      final paragraphs = _viewport?.value?.paragraphs;
      final anchor = paragraphs == null || paragraphs.isEmpty
          ? null
          : paragraphs.first;
      if (anchor == null || !_vertical.hasClients) {
        _controller.forceRepaint();
        return;
      }
      // The editor estimates unvisited wrapped heights. Keep the same visible
      // source range when retiring cached paragraphs or publishing colors.
      final top = anchor.index * anchor.paragraph.preferredLineHeight;
      _vertical.jumpTo(top);
      _controller.forceRepaint();
      _vertical.jumpTo(
        (top - anchor.offset.dy).clamp(0.0, _vertical.position.maxScrollExtent),
      );
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    ++_revision;
    _debounce?.cancel();
    _controller.dispose();
    _scroll.dispose();
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  Widget _accessible(Widget child) => _SourceSemantics(
    controller: _controller,
    child: ExcludeSemantics(child: child),
  );

  Widget _editor(TextStyle style) {
    final inputs = (style, widget.wrap);
    if (_editorInputs == inputs) return _editorView!;
    _editorInputs = inputs;
    // Highlighting only changes the controller's paint spans. Keep unchanged
    // editor configuration out of the completion rebuild; real style/wrap
    // changes still refresh it, and text changes notify through the controller.
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.event('source.editor.build');
    }
    return _editorView = CodeEditor(
      controller: _controller,
      indicatorBuilder: (_, _, _, notifier) {
        _viewport = notifier;
        return const SizedBox.shrink();
      },
      scrollController: _scroll,
      readOnly: true,
      showCursorWhenReadOnly: false,
      wordWrap: widget.wrap,
      chunkAnalyzer: const NonCodeChunkAnalyzer(),
      padding: EdgeInsets.zero,
      margin: EdgeInsets.zero,
      style: CodeEditorStyle(
        fontSize: style.fontSize,
        fontFamily: style.fontFamily,
        fontFamilyFallback: style.fontFamilyFallback,
        fontHeight: style.height,
        textColor: style.color,
        backgroundColor: Colors.transparent,
        cursorLineColor: Colors.transparent,
      ),
      toolbarController: MobileSelectionToolbarController(
        builder:
            ({
              required context,
              required anchors,
              required controller,
              required onDismiss,
              required onRefresh,
            }) => AdaptiveTextSelectionToolbar(
              anchors: anchors,
              children: [
                StudioButtonPress(
                  child: IconButton(
                    tooltip: 'Copy selection',
                    icon: const Icon(Icons.copy_outlined),
                    onPressed: () {
                      controller.copy();
                      onDismiss();
                    },
                  ),
                ),
                StudioButtonPress(
                  child: IconButton(
                    tooltip: 'Select all',
                    icon: const Icon(Icons.select_all),
                    onPressed: () {
                      controller.selectAll();
                      onRefresh();
                    },
                  ),
                ),
              ],
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final colors = WingTokens.of(context);
      final style = widget.style.copyWith(
        fontSize: MediaQuery.textScalerOf(
          context,
        ).scale(widget.style.fontSize ?? 14),
      );
      // Measure one glyph, never the document, to size the reading viewport.
      final glyph = TextPainter(
        text: TextSpan(text: '0', style: style),
        textDirection: Directionality.of(context),
      )..layout();
      final lineHeight = glyph.preferredLineHeight;
      final columns = math.max(1, (bounds.maxWidth / glyph.width).floor());
      glyph.dispose();
      final maxHeight = math.min(widget.maxHeight, bounds.maxHeight);
      final rows = math.max(1, (maxHeight / lineHeight).ceil());
      final segmentLength = widget.wrap ? math.max(2, columns * rows) : null;
      if (_segmentLength != segmentLength) {
        _segmentLength = segmentLength;
        _controller.setDocument(_document, segmentLength, resegment: true);
      }
      _controller.colors = colors;
      var displayedRows = 0;
      var hasRemainingLines = false;
      for (var i = 0; i < _document.lineStarts.length; ++i) {
        final start = _document.lineStarts[i];
        final end = i + 1 < _document.lineStarts.length
            ? _document.lineStarts[i + 1] - 1
            : widget.text.length;
        displayedRows += widget.wrap
            ? math.max(1, ((end - start) / columns).ceil())
            : 1;
        if (displayedRows * lineHeight >= maxHeight) {
          hasRemainingLines = i + 1 < _document.lineStarts.length;
          break;
        }
      }
      final naturalHeight = math.max(lineHeight, displayedRows * lineHeight);
      final overflow = naturalHeight > maxHeight || hasRemainingLines;
      if (_overflow != overflow) {
        _overflow = overflow;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _overflow == overflow) {
            widget.onOverflowChanged?.call(overflow);
          }
        });
      }
      return SizedBox(
        height: math.min(naturalHeight, maxHeight),
        child: NotificationListener<ScrollEndNotification>(
          onNotification: (_) {
            if (_refreshing) return false;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _controller.clearSpans();
                _refreshViewport();
              }
            });
            return false;
          },
          child: SelectionViewport.code(
            controller: _controller,
            codeRender: () => _controller.selectionRender,
            child: _accessible(_editor(style)),
          ),
        ),
      );
    },
  );
}

/// Document selection is independent of which paragraphs happen to be drawn.
/// Display-only breaks in a long wrapped line never enter the clipboard.
class _SourceController extends CodeLineEditingControllerDelegate {
  GlobalKey? _selectionEditor;

  @override
  void bindEditor(GlobalKey key) {
    _selectionEditor = key;
    super.bindEditor(key);
  }

  RenderBox? get selectionRender =>
      _selectionEditor?.currentContext?.findRenderObject() as RenderBox?;

  factory _SourceController(SourceDocument document) =>
      _SourceController._(document, document.displayLines());

  _SourceController._(this.document, this.lines)
    : super(
        delegate: CodeLineEditingController(
          codeLines: _sourceLines(document, lines),
        ),
      );

  // Read-only source needs one indexed line vector. The editor's incremental
  // CodeLines.of builder recalculates segment line counts after every append.
  static CodeLines _sourceLines(
    SourceDocument document,
    List<SourceDisplayLine> lines,
  ) => CodeLines([
    CodeLineSegment.of(
      codeLines: [
        for (final line in lines)
          CodeLine(document.text.substring(line.start, line.end)),
      ],
    ),
  ]);

  SourceDocument document;
  List<SourceDisplayLine> lines;
  WingTokens? colors;
  final _spans = <int, TextSpan>{};
  TextStyle? _style;
  Brightness? _brightness;
  Color? _muted;

  void clearSpans() => _spans.clear();

  int sourceOffset(CodeLinePosition position) =>
      lines[position.index].start + position.offset;

  void setDocument(
    SourceDocument next,
    int? segmentLength, {
    bool replaceText = false,
    bool resegment = false,
  }) {
    final base = sourceOffset(selection.base);
    final extent = sourceOffset(selection.extent);
    document = next;
    clearSpans();
    if (!replaceText && !resegment) return;
    lines = next.displayLines(segmentLength: segmentLength);
    final a = displayPosition(replaceText ? 0 : base);
    final b = displayPosition(replaceText ? 0 : extent);
    value = CodeLineEditingValue(
      codeLines: _sourceLines(next, lines),
      selection: CodeLineSelection(
        baseIndex: a.index,
        baseOffset: a.offset,
        extentIndex: b.index,
        extentOffset: b.offset,
      ),
    );
  }

  CodeLinePosition displayPosition(int offset) {
    var low = 0;
    var high = lines.length;
    while (low + 1 < high) {
      final mid = (low + high) ~/ 2;
      if (lines[mid].start <= offset) {
        low = mid;
      } else {
        high = mid;
      }
    }
    return CodeLinePosition(
      index: low,
      offset: math.min(
        offset - lines[low].start,
        lines[low].end - lines[low].start,
      ),
    );
  }

  @override
  String get text => document.text;

  @override
  String get selectedText {
    final a = sourceOffset(selection.base);
    final b = sourceOffset(selection.extent);
    return document.text.substring(math.min(a, b), math.max(a, b));
  }

  @override
  Future<void> copy() => selection.isCollapsed
      ? Future.value()
      : Clipboard.setData(ClipboardData(text: selectedText));

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    required int index,
    required TextSpan textSpan,
    required TextStyle style,
  }) {
    if (_style != style ||
        _brightness != colors?.brightness ||
        _muted != colors?.muted) {
      clearSpans();
      _style = style;
      _brightness = colors?.brightness;
      _muted = colors?.muted;
    }
    return _spans.putIfAbsent(
      index,
      () => TextSpan(
        style: style,
        children: [
          for (final token in document.rangeTokens(
            lines[index].start,
            lines[index].end,
          ))
            TextSpan(
              text: token.text,
              style: TextStyle(color: colors?.sourceColor(token.scope)),
            ),
        ],
      ),
    );
  }
}

/// Semantics follow document selection without rebuilding the native viewport.
class _SourceSemantics extends SingleChildRenderObjectWidget {
  const _SourceSemantics({required this.controller, required super.child});
  final _SourceController controller;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _SourceSemanticsRender(controller);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _SourceSemanticsRender renderObject,
  ) {
    renderObject.controller = controller;
  }
}

class _SourceSemanticsRender extends RenderProxyBox {
  _SourceSemanticsRender(this._controller);
  _SourceController _controller;
  set controller(_SourceController value) {
    if (_controller == value) return;
    if (attached) _controller.removeListener(markNeedsSemanticsUpdate);
    _controller = value;
    if (attached) _controller.addListener(markNeedsSemanticsUpdate);
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _controller.addListener(markNeedsSemanticsUpdate);
  }

  @override
  void detach() {
    _controller.removeListener(markNeedsSemanticsUpdate);
    super.detach();
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..isSemanticBoundary = true
      ..textDirection = TextDirection.ltr
      ..label = 'Source text'
      ..value = _controller.text
      ..isTextField = true
      ..isReadOnly = true
      ..textSelection = TextSelection(
        baseOffset: _controller.sourceOffset(_controller.selection.base),
        extentOffset: _controller.sourceOffset(_controller.selection.extent),
      )
      ..onSetSelection = (selection) {
        final base = _controller.displayPosition(
          selection.baseOffset.clamp(0, _controller.text.length),
        );
        final extent = _controller.displayPosition(
          selection.extentOffset.clamp(0, _controller.text.length),
        );
        _controller.selection = CodeLineSelection(
          baseIndex: base.index,
          baseOffset: base.offset,
          extentIndex: extent.index,
          extentOffset: extent.offset,
        );
      };
    if (!_controller.selection.isCollapsed) {
      config.onCopy = () {
        _controller.copy();
      };
    }
  }
}

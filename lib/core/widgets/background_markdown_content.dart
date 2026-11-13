import 'package:flutter/widgets.dart';

import '../utils/expansion_scroll_controller.dart';

import '../services/markdown_parse_worker.dart';
import '../services/markdown_segments.dart';
import '../services/completion_diagnostics.dart';
import '../services/performance_instrumentation.dart';
import 'studio_error.dart';

/// Captures a transcript's reading position immediately before async growth.
class MarkdownContentWillChange extends Notification {
  MarkdownContentWillChange(this.source);
  final BuildContext source;
}

/// Keeps the last completed snapshot visible while a newer one parses.
/// A single in-flight snapshot and the latest source bound work during a burst.
class BackgroundMarkdownContent extends StatefulWidget {
  const BackgroundMarkdownContent({
    super.key,
    required this.data,
    required this.deliverables,
    required this.builder,
    this.streaming = false,
    this.parse,
  });

  final String data;
  final bool deliverables;
  final bool streaming;
  final Widget Function(String source, List<MarkdownSegment> segments) builder;
  final Future<MarkdownParseResult> Function(String source)? parse;

  @override
  State<BackgroundMarkdownContent> createState() =>
      BackgroundMarkdownContentState();
}

class BackgroundMarkdownContentState extends State<BackgroundMarkdownContent>
    with WidgetsBindingObserver {
  static int _nextOwner = 0;
  // A streaming row can become a new saved row in the same frame. Seed it from
  // an already displayed matching snapshot rather than collapsing to zero
  // height. Only mounted states participate; no history cache survives disposal.
  static final _displayed = <BackgroundMarkdownContentState>{};
  int _owner = ++_nextOwner;
  int _epoch = 0;
  bool _busy = false;
  bool _foreground = true;
  bool _failed = false;
  MarkdownParseWorker? _worker;
  TranscriptAnchorBox? _loadingRow;
  String? _renderedSource;
  List<MarkdownSegment>? _segments;

  String? get renderedSource => _renderedSource;
  bool get pending => !_failed && (_busy || _renderedSource != widget.data);
  int parsesCompleted = 0;
  int updatesCoalesced = 0;
  int totalParserMicros = 0;
  int totalCacheHits = 0;
  int totalFenceMicros = 0;
  int totalRequestMicros = 0;
  int maxRequestMicros = 0;
  int maxPendingCharacters = 0;

  @override
  void initState() {
    super.initState();
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.event(
        'markdown.background.init',
        values: {'streaming': widget.streaming ? 1 : 0},
      );
    }
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    if (widget.parse == null) {
      BackgroundMarkdownContentState? previous;
      for (final state in _displayed) {
        final source = state._renderedSource;
        if (state._foreground &&
            state.widget.parse == null &&
            state.widget.deliverables == widget.deliverables &&
            source != null &&
            source.isNotEmpty &&
            widget.data.startsWith(source) &&
            (previous == null ||
                source.length > previous._renderedSource!.length)) {
          previous = state;
        }
      }
      if (previous != null) {
        _renderedSource = previous._renderedSource;
        final copyStart = CompletionDiagnostics.enabled
            ? CompletionDiagnostics.start()
            : 0;
        _segments = copyMarkdownSegments(previous._segments!);
        if (CompletionDiagnostics.enabled) {
          CompletionDiagnostics.finish(
            'markdown.ast.copy',
            copyStart,
            values: {'segments': _segments!.length},
          );
        }
      }
    }
    if (widget.streaming) _displayed.add(this);
    _request();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.event('markdown.background.dependencies');
    }
  }

  @override
  void didUpdateWidget(covariant BackgroundMarkdownContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.streaming) {
      _displayed.add(this);
    } else {
      _displayed.remove(this);
    }
    final changedConfiguration =
        widget.deliverables != oldWidget.deliverables ||
        widget.parse != oldWidget.parse;
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.event(
        'markdown.background.update',
        values: {
          'dataChanged': widget.data != oldWidget.data ? 1 : 0,
          'configurationChanged': changedConfiguration ? 1 : 0,
          'streamingChanged': widget.streaming != oldWidget.streaming ? 1 : 0,
        },
      );
    }
    if (changedConfiguration || !widget.data.startsWith(oldWidget.data)) {
      _reset();
      // Nodes from another grammar cannot be rendered by the new builders.
      if (changedConfiguration || widget.data.isEmpty) {
        _segments = null;
        _renderedSource = null;
      }
    } else if (PerformanceInstrumentation.enabled &&
        _busy &&
        widget.data != oldWidget.data) {
      updatesCoalesced++;
    }
    if (PerformanceInstrumentation.enabled) {
      final lag = widget.data.length - (_renderedSource?.length ?? 0);
      if (lag > maxPendingCharacters) maxPendingCharacters = lag;
    }
    _failed = false;
    _request();
  }

  void _reset() {
    _epoch++;
    _worker?.release(_owner);
    _worker = null;
    _owner = ++_nextOwner;
    _busy = false;
  }

  void _request() {
    if (!mounted ||
        !_foreground ||
        _busy ||
        _failed ||
        widget.data == _renderedSource) {
      return;
    }
    final source = widget.data;
    final epoch = _epoch;
    final requestWatch = PerformanceInstrumentation.enabled
        ? (Stopwatch()..start())
        : null;
    if (PerformanceInstrumentation.enabled) {
      final lag = source.length - (_renderedSource?.length ?? 0);
      if (lag > maxPendingCharacters) maxPendingCharacters = lag;
    }
    _busy = true;
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.event('markdown.background.parse.request');
    }
    final parse = widget.parse;
    final future = Future<MarkdownParseResult>.sync(
      () => parse != null
          ? parse(source)
          : (_worker ??= MarkdownParseWorker.shared).parse(
              owner: _owner,
              source: source,
              deliverables: widget.deliverables,
            ),
    );
    future
        .then(
          (result) {
            if (!mounted || !_foreground || epoch != _epoch) return;
            final requestMicros = PerformanceInstrumentation.enabled
                ? requestWatch!.elapsedMicroseconds
                : 0;
            if (CompletionDiagnostics.enabled) {
              CompletionDiagnostics.event(
                'markdown.background.parse.result',
                values: {
                  'parseUs': result.parseMicros,
                  'fenceUs': result.fenceMicros,
                  'requestWallUs': requestMicros,
                  'cacheHits': result.cacheHits,
                  'inlineParses': result.inlineParses,
                  'segments': result.segments.length,
                },
              );
            }
            MarkdownContentWillChange(context).dispatch(context);
            setState(() {
              // Accept newer completed progress even if another update is pending.
              // Otherwise a fast stream could starve rendering until it completes.
              _renderedSource = source;
              _segments = result.segments;
              if (PerformanceInstrumentation.enabled) {
                parsesCompleted++;
                totalParserMicros += result.parseMicros;
                totalCacheHits += result.cacheHits;
                totalFenceMicros += result.fenceMicros;
                totalRequestMicros += requestMicros;
                if (requestMicros > maxRequestMicros) {
                  maxRequestMicros = requestMicros;
                }
              }
            });
          },
          onError: (Object error, StackTrace stack) {
            if (mounted && epoch == _epoch && _foreground) {
              MarkdownContentWillChange(context).dispatch(context);
              setState(() {
                _reset();
                _failed = true;
              });
            }
          },
        )
        .whenComplete(() {
          if (!mounted || epoch != _epoch) return;
          _busy = false;
          _request();
        });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _reset();
    } else {
      _failed = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _foreground) _request();
      });
      WidgetsBinding.instance.scheduleFrame();
    }
  }

  Rect? _contentBounds() {
    if (!mounted || _failed || _renderedSource != widget.data) return null;
    final content = context.findRenderObject();
    if (content is! RenderBox || !content.attached || !content.hasSize) {
      return null;
    }
    return content.localToGlobal(Offset.zero) & content.size;
  }

  @override
  Widget build(BuildContext context) {
    final row = context.findAncestorRenderObjectOfType<TranscriptAnchorBox>();
    if (!identical(row, _loadingRow)) {
      _loadingRow?.setContentPending(this, false);
      _loadingRow?.setContentBounds(this, null);
      _loadingRow = row;
    }
    _loadingRow?.setContentPending(this, _segments == null && !_failed);
    _loadingRow?.setContentBounds(this, _contentBounds);
    final child = _segments == null
        ? const SizedBox.shrink()
        : widget.builder(_renderedSource!, _segments!);
    return _failed
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              child,
              const Flexible(
                child: SingleChildScrollView(
                  primary: false,
                  child: StudioError('Could not display this message.'),
                ),
              ),
            ],
          )
        : child;
  }

  @override
  void deactivate() {
    // Release before the parent lays out a replacement child. Disposal happens
    // after layout; a reparented state acquires its new row on the next build.
    _loadingRow?.setContentPending(this, false);
    _loadingRow?.setContentBounds(this, null);
    _loadingRow = null;
    super.deactivate();
  }

  @override
  void dispose() {
    if (CompletionDiagnostics.enabled) {
      CompletionDiagnostics.event('markdown.background.dispose');
    }
    _displayed.remove(this);
    WidgetsBinding.instance.removeObserver(this);
    _reset();
    super.dispose();
  }
}

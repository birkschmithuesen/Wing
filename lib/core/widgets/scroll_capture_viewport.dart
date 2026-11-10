import 'dart:async';
import 'package:flutter/material.dart';
import '../services/scroll_capture_bridge.dart';
import 'background_markdown_content.dart';

/// Exposes only the scrolling transcript to Android 12+ long screenshots.
/// Chrome, composer and IME stay outside the target; capture restores reading.
class ScrollCaptureViewport extends StatefulWidget {
  const ScrollCaptureViewport({
    super.key,
    required this.controller,
    required this.child,
    required this.onCaptureChanged,
  });
  final ScrollController controller;
  final Widget child;
  final ValueChanged<bool> onCaptureChanged;
  @override
  State<ScrollCaptureViewport> createState() => _ScrollCaptureViewportState();
}

class _ScrollCaptureViewportState extends State<ScrollCaptureViewport> {
  final _viewport = GlobalKey();
  late final _bridge = ScrollCaptureBridge(_handle);
  double? _original;
  bool _scheduled = false;
  Map<String, Object>? _lastBounds;

  void _publish() {
    if (_scheduled || !_bridge.supported) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final metrics = _metrics();
      if (metrics == null) return;
      // Android registers the viewport rectangle. Offset and extent are read
      // through its metrics/start callbacks when a capture actually requests
      // them; streaming growth must not reinstall the same native target.
      final bounds = {
        for (final key in const ['left', 'top', 'right', 'bottom'])
          key: metrics[key]!,
      };
      if (!_bridge.isCurrent || !_sameBounds(bounds)) {
        _lastBounds = bounds;
        unawaited(_bridge.update(bounds));
      }
    });
  }

  bool _sameBounds(Map<String, Object> data) =>
      _lastBounds != null &&
      data.entries.every((entry) => _lastBounds![entry.key] == entry.value);

  // Android capture addresses the physical distance from the transcript top.
  // Flutter's reversed list instead measures pixels from its bottom.
  bool get _reversed =>
      widget.controller.position.axisDirection == AxisDirection.up;
  double _captureOffset(double pixels) => _reversed
      ? widget.controller.position.maxScrollExtent - pixels
      : pixels - widget.controller.position.minScrollExtent;

  double _scrollOffset(double offset) => _reversed
      ? widget.controller.position.maxScrollExtent - offset
      : widget.controller.position.minScrollExtent + offset;

  Map<String, Object>? _metrics() {
    if (!mounted ||
        !widget.controller.hasClients ||
        ModalRoute.of(context)?.isCurrent == false) {
      return null;
    }
    final box = _viewport.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final origin = box.localToGlobal(Offset.zero) * ratio;
    final size = box.size * ratio;
    final scroll = widget.controller.position;
    return {
      'left': origin.dx,
      'top': origin.dy,
      'right': origin.dx + size.width,
      'bottom': origin.dy + size.height,
      'offset': _captureOffset(scroll.pixels) * ratio,
      'min': 0.0,
      'max': (scroll.maxScrollExtent - scroll.minScrollExtent) * ratio,
      'ratio': ratio,
    };
  }

  bool _contentPending() {
    var pending = false;
    void visit(Element element) {
      if (element is StatefulElement &&
          element.state is BackgroundMarkdownContentState) {
        pending |= (element.state as BackgroundMarkdownContentState).pending;
      }
      element.visitChildElements(visit);
    }

    final context = _viewport.currentContext;
    if (context is Element) visit(context);
    return pending;
  }

  Future<Object?> _handle(String method, Map<Object?, Object?> args) async {
    if (method == 'end') {
      _restore();
      return null;
    }
    if (_metrics() == null) return null;
    switch (method) {
      case 'metrics':
        return _metrics();
      case 'start':
        _original ??= widget.controller.offset;
        widget.onCaptureChanged(true);
        return _metrics();
      case 'scroll':
        if (_original == null) return null;
        final offset = args['offset'];
        if (offset is! num || !offset.isFinite) return null;
        final ratio = MediaQuery.devicePixelRatioOf(context);
        final position = widget.controller.position;
        widget.controller.jumpTo(
          _scrollOffset(
            offset / ratio,
          ).clamp(position.minScrollExtent, position.maxScrollExtent),
        );
        // Wait for rasterizable geometry, including lazy layout/Markdown growth.
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return null;
        final deadline = Stopwatch()..start();
        while (_contentPending()) {
          if (deadline.elapsedMilliseconds > 1000) return null;
          await Future<void>.delayed(const Duration(milliseconds: 16));
          if (!mounted || _original == null) return null;
          WidgetsBinding.instance.scheduleFrame();
          await WidgetsBinding.instance.endOfFrame;
        }
        WidgetsBinding.instance.scheduleFrame();
        await WidgetsBinding.instance.endOfFrame;
        return _metrics();
    }
    return null;
  }

  void _restore() {
    final original = _original;
    _original = null;
    if (original == null) return;
    if (widget.controller.hasClients) {
      final position = widget.controller.position;
      widget.controller.jumpTo(
        original.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    }
    widget.onCaptureChanged(false);
  }

  @override
  void dispose() {
    if (_original != null) widget.onCaptureChanged(false);
    _original = null;
    unawaited(_bridge.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _publish();
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _publish();
        return false;
      },
      child: SizedBox.expand(key: _viewport, child: widget.child),
    );
  }
}

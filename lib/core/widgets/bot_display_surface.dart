import 'studio_error.dart';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/bot_display.dart';
import 'bot_display_viewport.dart';

/// Pixel decoding, viewport transforms and touch gestures are presentation only.
class BotDisplaySurface extends StatefulWidget {
  const BotDisplaySurface({
    super.key,
    required this.frame,
    required this.viewport,
    required this.canInput,
    required this.keyboardInset,
    required this.barInset,
  });
  final BotDisplayFrame frame;
  final bool canInput;
  final BotDisplayViewport viewport;
  final double keyboardInset, barInset;
  @override
  State<BotDisplaySurface> createState() => _BotDisplaySurfaceState();
}

class _BotDisplaySurfaceState extends State<BotDisplaySurface> {
  ui.Image? _image;
  BotDisplayFrame? _pending;
  bool _decoding = false;
  bool _decodeFailed = false;
  final _touches = <int, Offset>{};
  Timer? _hold;
  Offset _start = Offset.zero, _last = Offset.zero;
  Offset? _tapPosition;
  Duration? _tapTime;
  bool _moved = false, _multi = false, _secondTap = false;
  bool _drag = false, _rightClick = false, _pairScheduled = false;
  Offset _pairStart = Offset.zero, _pairLast = Offset.zero;
  double _distanceStart = 0, _distanceLast = 0, _wheel = 0;
  String? _pairAction;

  void _cancel() {
    _hold?.cancel();
    widget.viewport.release();
    _touches.clear();
    _drag = false;
    _tapTime = null;
  }

  void _down(PointerDownEvent e) {
    final v = widget.viewport;
    _touches[e.pointer] = e.localPosition;
    if (_touches.length == 1) {
      _start = _last = e.localPosition;
      _moved = _multi = _drag = _rightClick = false;
      _secondTap =
          _tapTime != null &&
          e.timeStamp - _tapTime! < const Duration(milliseconds: 330) &&
          (_tapPosition! - _start).distance < 24;
      _hold = Timer(Duration(milliseconds: _secondTap ? 280 : 550), () {
        if (_touches.length != 1 || _moved || !widget.canInput) return;
        if (v.pointAt(_start)) {
          if (_secondTap) {
            _drag = true;
            v.drag(true);
          } else {
            _rightClick = true;
            v.click(4);
          }
        }
      });
    } else {
      _hold?.cancel();
      v.release();
      _drag = false;
      _multi = true;
      _tapTime = null;
      if (_touches.length == 2) {
        final points = _touches.values.toList();
        _pairStart = _pairLast = (points[0] + points[1]) / 2;
        _distanceStart = _distanceLast = (points[0] - points[1]).distance;
        _pairAction = null;
        _wheel = 0;
        v.pointAt(_pairStart);
      }
    }
  }

  void _pairUpdate() {
    if (_touches.length != 2) return;
    final points = _touches.values.toList();
    final center = (points[0] + points[1]) / 2;
    final distance = (points[0] - points[1]).distance;
    final v = widget.viewport;
    // Accumulate from the gesture start: slow swipes must classify too. Both
    // touch updates in a frame are sampled together to avoid false pinch starts.
    _pairAction ??= (distance - _distanceStart).abs() > 10
        ? 'zoom'
        : (center - _pairStart).distance > 9
        ? 'scroll'
        : null;
    if (_pairAction == 'zoom') {
      if (_distanceLast > 0) v.zoom(distance / _distanceLast, focal: _pairLast);
      v.pan(center - _pairLast);
    } else if (_pairAction == 'scroll') {
      _wheel += center.dy - _pairLast.dy;
      while (_wheel.abs() >= 18) {
        v.click(_wheel > 0 ? 8 : 16);
        _wheel -= _wheel > 0 ? 18 : -18;
      }
    } else {
      return;
    }
    _pairLast = center;
    _distanceLast = distance;
  }

  void _move(PointerMoveEvent e) {
    if (!_touches.containsKey(e.pointer)) return;
    _touches[e.pointer] = e.localPosition;
    final v = widget.viewport;
    if (_multi) {
      if (!_pairScheduled) {
        _pairScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _pairScheduled = false;
          if (mounted) _pairUpdate();
        });
        WidgetsBinding.instance.scheduleFrame();
      }
      return;
    }
    if (!_moved && (e.localPosition - _start).distance > 7) {
      _moved = true;
      _hold?.cancel();
      if (_secondTap && !_rightClick && widget.canInput && v.pointAt(_start)) {
        _drag = true;
        v.drag(true);
      }
    }
    if (_drag) {
      if (v.pointAt(e.localPosition)) v.send(1);
    } else if (_moved && !_rightClick) {
      v.pan(e.localPosition - _last);
    }
    _last = e.localPosition;
  }

  void _up(PointerUpEvent e) {
    _hold?.cancel();
    if (_multi) _pairUpdate();
    _touches.remove(e.pointer);
    final v = widget.viewport;
    if (_multi) return;
    if (_drag) {
      v.release();
    } else if (!_moved &&
        !_rightClick &&
        widget.canInput &&
        v.pointAt(e.localPosition)) {
      v.click(1);
      _tapTime = _secondTap ? null : e.timeStamp;
      _tapPosition = e.localPosition;
    } else {
      _tapTime = null;
    }
    _drag = false;
  }

  @override
  void initState() {
    super.initState();
    _queue();
  }

  @override
  void didUpdateWidget(BotDisplaySurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.frame, oldWidget.frame)) _queue();
    widget.viewport.setInput(widget.canInput);
    if (oldWidget.canInput && !widget.canInput) _cancel();
  }

  void _queue() {
    _pending = widget.frame;
    if (!_decoding) unawaited(_decode());
  }

  Future<void> _decode() async {
    _decoding = true;
    while (_pending != null && mounted) {
      final frame = _pending!;
      _pending = null;
      ui.ImmutableBuffer? buffer;
      ui.ImageDescriptor? descriptor;
      ui.Codec? codec;
      ui.Image? image;
      try {
        buffer = await ui.ImmutableBuffer.fromUint8List(frame.pixels);
        descriptor = ui.ImageDescriptor.raw(
          buffer,
          width: frame.width,
          height: frame.height,
          pixelFormat: ui.PixelFormat.rgba8888,
        );
        codec = await descriptor.instantiateCodec();
        image = (await codec.getNextFrame()).image;
        if (!mounted) {
          image.dispose();
          break;
        }
        final old = _image;
        setState(() {
          _image = image;
          _decodeFailed = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          old?.dispose();
        });
      } catch (_) {
        image?.dispose();
        if (mounted) {
          final old = _image;
          setState(() {
            _image = null;
            _decodeFailed = true;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            old?.dispose();
          });
        }
      } finally {
        codec?.dispose();
        descriptor?.dispose();
        buffer?.dispose();
      }
    }
    _decoding = false;
  }

  @override
  void dispose() {
    _cancel();
    _pending = null;
    _image?.dispose();
    widget.viewport.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final v = widget.viewport;
      v.setInput(widget.canInput);
      final base = Size(
        bounds.maxWidth,
        (bounds.maxHeight - widget.barInset).clamp(1, double.infinity),
      );
      final usable = Size(
        base.width,
        (base.height - widget.keyboardInset).clamp(1, double.infinity),
      );
      v.layout(
        Size(widget.frame.width.toDouble(), widget.frame.height.toDouble()),
        base,
        usable,
        keyboard: widget.keyboardInset > 0,
      );
      return Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: usable.width,
          height: usable.height,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: v,
              builder: (context, _) => Semantics(
                label:
                    'Bot desktop. Tap to click. One finger moves the view; two fingers scroll the computer. Pinch to zoom. Hold to right-click; double-tap and hold to drag.',
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _down,
                  onPointerMove: _move,
                  onPointerUp: _up,
                  onPointerCancel: (_) => _cancel(),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: ColoredBox(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerLowest,
                        ),
                      ),
                      if (_decodeFailed)
                        const Center(
                          child: StudioError(
                            'Screen frame could not be displayed.',
                            icon: Icons.monitor_outlined,
                          ),
                        ),
                      if (_image != null)
                        Transform.translate(
                          offset: v.offset,
                          child: Transform.scale(
                            scale: v.scale,
                            alignment: Alignment.topLeft,
                            child: OverflowBox(
                              alignment: Alignment.topLeft,
                              minWidth: v.desktop.width,
                              maxWidth: v.desktop.width,
                              minHeight: v.desktop.height,
                              maxHeight: v.desktop.height,
                              child: RawImage(
                                image: _image,
                                fit: BoxFit.fill,
                                filterQuality: FilterQuality.medium,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

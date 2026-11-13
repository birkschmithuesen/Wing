import 'package:flutter/scheduler.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Explicit transcript admission; controls/messages can revoke it in a subtree.
class ConversationGestureBoundary extends SingleChildRenderObjectWidget {
  const ConversationGestureBoundary({
    super.key,
    required super.child,
    this.blocked = false,
  });
  final bool blocked;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ConversationGestureBoundary(blocked);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderProxyBox renderObject,
  ) => (renderObject as _ConversationGestureBoundary).blocked = blocked;
}

class _ConversationGestureBoundary extends RenderProxyBox {
  _ConversationGestureBoundary(this.blocked);
  bool blocked;
  @override
  bool hitTestSelf(Offset position) => true;
}

bool admitsConversationGesture(PointerDownEvent event) {
  final result = HitTestResult();
  GestureBinding.instance.hitTestInView(result, event.position, event.viewId);
  var admitted = false;
  for (final hit in result.path) {
    final target = hit.target;
    if (target is _ConversationGestureBoundary) {
      if (target.blocked) return false;
      admitted = true;
    }
    if (target is RenderSemanticsAnnotations &&
        (target.properties.button == true || target.properties.link == true)) {
      return false;
    }
    if (target is RenderEditable &&
        (!target.readOnly || target.selection?.isCollapsed == false)) {
      return false;
    }
    if (target is RenderImage) return false;
  }
  return admitted;
}

enum ConversationGestureKind { slide, pinch }

final class ConversationGestureSample {
  const ConversationGestureSample(
    this.kind,
    this.delta,
    this.scale,
    this.timeStamp,
  );
  final ConversationGestureKind kind;
  final Offset delta;
  final double scale;
  final Duration timeStamp;
}

/// Participates in Flutter's arena: normal one-finger scrolling wins before a
/// second contact; excluded controls never enter this arena.
class ConversationGestureRecognizer extends OneSequenceGestureRecognizer {
  bool Function(PointerDownEvent) admits = (_) => false;
  bool allowSlide = false;
  void Function(ConversationGestureSample)? onStart;
  void Function(ConversationGestureSample)? onUpdate;
  void Function()? onEnd;
  void Function()? onCancel;
  final _contacts = <int, Offset>{};
  Offset _anchor = Offset.zero;
  double _span = 0;
  Duration _timeStamp = Duration.zero;
  ConversationGestureKind? _kind;
  bool _claimed = false, _started = false;
  int _frameGeneration = 0;
  bool _framePending = false;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      admits(event) && super.isPointerAllowed(event);

  Offset get _center =>
      _contacts.values.fold(Offset.zero, (a, b) => a + b) /
      _contacts.length.toDouble();
  double get _currentSpan => _contacts.length < 2
      ? _span
      : (_contacts.values.first - _contacts.values.last).distance;
  ConversationGestureSample get _sample => ConversationGestureSample(
    _kind!,
    _center - _anchor,
    _span > 0 ? _currentSpan / _span : 1,
    _timeStamp,
  );

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _timeStamp = event.timeStamp;
    startTrackingPointer(event.pointer, event.transform);
    _contacts[event.pointer] = event.position;
    if (_contacts.length > 2) {
      _cancel();
      return;
    }
    if (_contacts.length == 1) {
      _anchor = event.position;
      _kind = null;
    } else {
      if (_started) {
        _cancel();
        return;
      }
      _anchor = _center;
      _span = _currentSpan;
      // Two contacts on admitted blank transcript reserve the expert gesture
      // before either finger's vertical movement can claim ordinary scrolling.
      _claimed = true;
      resolve(GestureDisposition.accepted);
    }
  }

  void _claim(ConversationGestureKind kind) {
    _kind = kind;
    _claimed = true;
    resolve(GestureDisposition.accepted);
    acceptGesture(_contacts.keys.first);
  }

  @override
  void acceptGesture(int pointer) {
    if (!_claimed || _kind == null || _started || _contacts.isEmpty) return;
    _started = true;
    onStart?.call(_sample);
  }

  @override
  void rejectGesture(int pointer) {
    if (_started) onCancel?.call();
    _clear();
  }

  @override
  void handleEvent(PointerEvent event) {
    if (!_contacts.containsKey(event.pointer)) return;
    if (event is PointerMoveEvent) {
      _timeStamp = event.timeStamp;
      _contacts[event.pointer] = event.position;
      if (_contacts.length == 2) {
        if (!_framePending) {
          _framePending = true;
          final generation = _frameGeneration;
          SchedulerBinding.instance.scheduleFrameCallback((_) {
            if (generation != _frameGeneration) return;
            _framePending = false;
            _processMovement();
          });
        }
      } else {
        _processMovement();
      }
    } else if (event is PointerUpEvent) {
      if (_framePending) {
        _framePending = false;
        _processMovement();
      }
      if (_started) {
        onEnd?.call();
      }
      resolve(
        _claimed ? GestureDisposition.accepted : GestureDisposition.rejected,
      );
      _clear();
    } else if (event is PointerCancelEvent) {
      _cancel();
    }
  }

  void _processMovement() {
    if (_contacts.isEmpty) return;
    final delta = _center - _anchor;
    if (_contacts.length == 2) {
      if (_kind == null) {
        final contraction = _span - _currentSpan;
        final shrink = _span > 0 ? contraction / _span : 0.0;
        // A pinch must converge substantially more than its midpoint travels.
        // Uneven swipes and separately delivered finger moves can narrow the
        // span without both fingers intentionally moving inward.
        if (shrink > .24 &&
            contraction > 32 &&
            contraction > delta.distance * 2) {
          _claim(ConversationGestureKind.pinch);
        } else if (allowSlide && delta.dx.abs() > kTouchSlop) {
          // Two contacts establish swipe intent. Only left/right displacement
          // matters; vertical travel and uneven finger spacing impose no limit.
          _claim(ConversationGestureKind.slide);
        }
      }
      // Keep the admitted kind until lift; later finger drift cannot turn a
      // conversation swipe into a persistent stack.
    } else if (!_claimed && delta.distance > kTouchSlop) {
      resolve(GestureDisposition.rejected);
      _clear();
      return;
    }
    if (_started && _contacts.isNotEmpty) {
      onUpdate?.call(_sample);
    }
  }

  void _cancel() {
    if (_started) onCancel?.call();
    resolve(GestureDisposition.rejected);
    _clear();
  }

  void _clear() {
    ++_frameGeneration;
    _framePending = false;
    final ids = _contacts.keys.toList();
    _contacts.clear();
    _kind = null;
    _claimed = _started = false;
    _span = 0;
    for (final id in ids) {
      stopTrackingPointer(id);
    }
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}
  @override
  String get debugDescription => 'recent conversation swipe or pinch';
}

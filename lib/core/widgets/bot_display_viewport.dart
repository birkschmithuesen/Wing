import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Presentation coordinates only; commands remain gated by the screen session.
class BotDisplayViewport extends ChangeNotifier {
  BotDisplayViewport({required this.onPointer});
  final void Function(int x, int y, int buttons) onPointer;
  Size desktop = Size.zero, baseSize = Size.zero, size = Size.zero;
  Offset _offset = Offset.zero, _keyboardShift = Offset.zero;
  Offset pointer = Offset.zero;
  double scale = 1;
  bool _keyboard = false, _fit = true, _anchor = false, canInput = false;
  bool _keyboardNavigated = false;
  int buttons = 0;
  Offset get offset => _offset + _keyboardShift;
  Offset toRemote(Offset local) => (local - offset) / scale;
  Offset toLocal(Offset remote) => offset + remote * scale;
  double _fitScale(Size target) =>
      math.min(target.width / desktop.width, target.height / desktop.height);
  Offset _bounded(Offset value) => Offset(
    desktop.width * scale <= size.width
        ? (size.width - desktop.width * scale) / 2
        : value.dx.clamp(size.width - desktop.width * scale, 0),
    desktop.height * scale <= size.height
        ? (size.height - desktop.height * scale) / 2
        : value.dy.clamp(size.height - desktop.height * scale, 0),
  );
  void layout(Size remote, Size base, Size usable, {required bool keyboard}) {
    if (remote == desktop &&
        base == baseSize &&
        usable == size &&
        keyboard == _keyboard) {
      return;
    }
    final reset = desktop != remote || desktop.isEmpty;
    if (reset || !keyboard || !_keyboard) _keyboardNavigated = false;
    final baseChanged = base != baseSize;
    final center = desktop.isEmpty
        ? Offset.zero
        : toRemote(size.center(Offset.zero));
    desktop = remote;
    baseSize = base;
    size = usable;
    if (reset) {
      scale = _fitScale(base);
      pointer = remote.center(Offset.zero);
      _anchor = false;
      _fit = true;
      _offset = (base.center(Offset.zero) - pointer * scale);
    } else if (baseChanged) {
      if (_fit && !keyboard && !_keyboard) scale = _fitScale(base);
      _offset = base.center(Offset.zero) - center * scale;
    }
    if (keyboard) {
      var total = _keyboardNavigated ? offset : _offset;
      if (_anchor && !_keyboardNavigated) {
        final local = _offset + pointer * scale;
        final margin = math.min(28.0, size.shortestSide / 4);
        total += Offset(
          local.dx.clamp(margin, size.width - margin) - local.dx,
          local.dy.clamp(margin, size.height - margin) - local.dy,
        );
      }
      _keyboardShift = _bounded(total) - _offset;
    } else {
      _keyboardShift = Offset.zero;
      _offset = _bounded(_offset);
    }
    _keyboard = keyboard;
  }

  void setInput(bool enabled) {
    if (!enabled && canInput) release();
    canInput = enabled;
  }

  void zoom(double factor, {Offset? focal}) {
    if (desktop.isEmpty) return;
    _keyboardNavigated = _keyboard;
    final focus =
        focal ?? (_anchor ? toLocal(pointer) : size.center(Offset.zero));
    final anchor = toRemote(focus);
    scale = (scale * factor).clamp(
      _fitScale(size),
      math.max(_fitScale(baseSize) * 8, 2),
    );
    _offset = _bounded(focus - anchor * scale) - _keyboardShift;
    _fit = false;
    notifyListeners();
  }

  void pan(Offset delta) {
    _keyboardNavigated = _keyboard;
    _offset = _bounded(offset + delta) - _keyboardShift;
    _fit = false;
    notifyListeners();
  }

  bool pointAt(Offset local) {
    final remote = toRemote(local);
    if (remote.dx < 0 ||
        remote.dy < 0 ||
        remote.dx >= desktop.width ||
        remote.dy >= desktop.height) {
      return false;
    }
    pointer = remote;
    _anchor = true;
    return true;
  }

  void send(int mask) {
    if (!canInput || desktop.isEmpty) return;
    onPointer(
      pointer.dx.round().clamp(0, desktop.width.toInt() - 1),
      pointer.dy.round().clamp(0, desktop.height.toInt() - 1),
      mask,
    );
  }

  void click(int mask) {
    if (!canInput) return;
    send(mask);
    send(buttons);
  }

  void drag(bool held) {
    if (!canInput) return;
    buttons = held ? 1 : 0;
    send(buttons);
    notifyListeners();
  }

  void release() {
    if (buttons != 0) {
      buttons = 0;
      send(0);
    }
  }
}

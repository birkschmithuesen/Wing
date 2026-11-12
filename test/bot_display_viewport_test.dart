import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/widgets/bot_display_viewport.dart';

void main() {
  late BotDisplayViewport v;
  late List<(int, int, int)> input;
  setUp(() {
    input = [];
    v = BotDisplayViewport(
      onPointer: (x, y, buttons) => input.add((x, y, buttons)),
    );
    v.layout(
      const Size(1440, 900),
      const Size(720, 400),
      const Size(720, 400),
      keyboard: false,
    );
  });
  tearDown(() => v.dispose());
  test(
    'keyboard keeps scale and reveals bottom working point; manual movement survives dismissal',
    () {
      v.zoom(2);
      v.pointAt(const Offset(360, 350));
      final scale = v.scale, before = v.offset;
      v.layout(v.desktop, v.baseSize, const Size(720, 240), keyboard: true);
      expect(v.scale, scale);
      expect(v.toLocal(v.pointer).dy, lessThanOrEqualTo(212));
      expect(v.toLocal(v.pointer).dy, greaterThanOrEqualTo(28));
      final auto = v.offset - before;
      v.pan(const Offset(-20, 15));
      final manual = v.offset - before - auto;
      v.layout(v.desktop, v.baseSize, const Size(720, 400), keyboard: false);
      expect(v.scale, scale);
      expect(v.offset, before + manual);
      expect(input, isEmpty);
    },
  );
  test('keyboard resize respects deliberate pan away from input anchor', () {
    v.zoom(3);
    v.pointAt(const Offset(360, 350));
    v.layout(v.desktop, v.baseSize, const Size(720, 240), keyboard: true);
    v.pan(const Offset(0, 100));
    final before = v.offset;
    v.layout(v.desktop, v.baseSize, const Size(720, 220), keyboard: true);
    expect(v.offset, before);
    expect(input, isEmpty);
  });
  test(
    'zoom preserves focal desktop point and direct mapping uses one inverse transform',
    () {
      const focal = Offset(300, 180);
      final remote = v.toRemote(focal);
      v.zoom(2, focal: focal);
      expect((v.toRemote(focal) - remote).distance, lessThan(.001));
      v.setInput(true);
      expect(v.pointAt(focal), true);
      v.click(1);
      expect(input, [
        (remote.dx.round(), remote.dy.round(), 1),
        (remote.dx.round(), remote.dy.round(), 0),
      ]);
      expect(v.pointAt(const Offset(-3000, 0)), false);
    },
  );
  test('direct pointer releases held drag on input loss', () {
    v.zoom(3);
    v.setInput(true);
    v.drag(true);
    v.pointAt(v.toLocal(const Offset(1439, 899)));
    v.send(1);
    expect(input.last, (1439, 899, 1));
    v.setInput(false);
    expect(input.last, (1439, 899, 0));
    final count = input.length;
    v.pointAt(const Offset(20, 20));
    v.send(1);
    v.click(1);
    expect(input.length, count);
  });
  test(
    'rotation retains magnification and selected desktop point without emitting input',
    () {
      v.zoom(2);
      final center = v.toRemote(v.size.center(Offset.zero));
      final scale = v.scale;
      v.layout(
        v.desktop,
        const Size(390, 720),
        const Size(390, 720),
        keyboard: false,
      );
      expect(v.scale, scale);
      expect(
        (v.toRemote(v.size.center(Offset.zero)) - center).distance,
        lessThan(.001),
      );
      expect(input, isEmpty);
    },
  );
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/wing_bg_watch.dart';

class _ManualTimer implements Timer {
  _ManualTimer(this.callback);
  final void Function(Timer) callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  void fire() {
    if (isActive) {
      tick++;
      callback(this);
    }
  }

  @override
  void cancel() {
    isActive = false;
  }
}

void main() {
  late _ManualTimer timer;
  late List<String> logs;
  late WingBgWatch watch;

  setUp(() {
    logs = [];
    watch = WingBgWatch(
      scheduleTimer: (duration, callback) => timer = _ManualTimer(callback),
      log: logs.add,
    );
  });

  test('wake-ups while foreground are never counted or reported', () {
    for (var i = 0; i < 200; i++) {
      watch.recordWakeup('Noisy');
    }
    expect(logs, isEmpty);
  });

  test('a component under the threshold stays quiet', () {
    watch.setForeground(false);
    for (var i = 0; i < WingBgWatch.wakeupThreshold; i++) {
      watch.recordWakeup('Quiet');
    }
    timer.fire();
    expect(logs, isEmpty);
  });

  test('a component over the threshold is logged once per report window', () {
    watch.setForeground(false);
    for (var i = 0; i < WingBgWatch.wakeupThreshold + 5; i++) {
      watch.recordWakeup('Noisy');
    }
    timer.fire();
    expect(logs, hasLength(1));
    expect(logs.single, contains('WingBgWatch'));
    expect(logs.single, contains('Noisy=${WingBgWatch.wakeupThreshold + 5}'));
  });

  test('each report window starts a fresh count', () {
    watch.setForeground(false);
    for (var i = 0; i < WingBgWatch.wakeupThreshold + 1; i++) {
      watch.recordWakeup('Noisy');
    }
    timer.fire();
    expect(logs, hasLength(1));
    timer.fire();
    expect(logs, hasLength(1), reason: 'no new wake-ups, no new log line');
  });

  test('going foreground clears counters without logging', () {
    watch.setForeground(false);
    for (var i = 0; i < WingBgWatch.wakeupThreshold + 1; i++) {
      watch.recordWakeup('Noisy');
    }
    watch.setForeground(true);
    expect(logs, isEmpty);
    expect(timer.isActive, false);
  });

  test('multiple offenders are all named in one line', () {
    watch.setForeground(false);
    for (var i = 0; i < WingBgWatch.wakeupThreshold + 10; i++) {
      watch.recordWakeup('A');
    }
    for (var i = 0; i < WingBgWatch.wakeupThreshold + 1; i++) {
      watch.recordWakeup('B');
    }
    timer.fire();
    expect(logs.single, contains('A=${WingBgWatch.wakeupThreshold + 10}'));
    expect(logs.single, contains('B=${WingBgWatch.wakeupThreshold + 1}'));
  });
}

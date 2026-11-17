import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/wing_bg_watch.dart';

void main() {
  late DateTime now;
  late List<String> logs;
  late WingBgWatch watch;

  setUp(() {
    now = DateTime(2026, 11, 17);
    logs = [];
    watch = WingBgWatch(now: () => now, log: logs.add);
  });

  test('wake-ups while foreground are never counted or reported', () {
    for (var i = 0; i < 200; i++) {
      watch.recordWakeup('Noisy');
    }
    now = now.add(const Duration(minutes: 2));
    watch.recordWakeup('Noisy');
    expect(logs, isEmpty);
  });

  test('a component under the threshold stays quiet', () {
    watch.setForeground(false);
    for (var i = 0; i < WingBgWatch.wakeupThreshold; i++) {
      watch.recordWakeup('Quiet');
    }
    now = now.add(const Duration(minutes: 1));
    watch.recordWakeup('Quiet');
    expect(logs, isEmpty);
  });

  test('a component over the threshold is logged once the window rolls over', () {
    watch.setForeground(false);
    for (var i = 0; i < WingBgWatch.wakeupThreshold + 5; i++) {
      watch.recordWakeup('Noisy');
    }
    expect(logs, isEmpty, reason: 'the window has not elapsed yet');
    now = now.add(const Duration(minutes: 1));
    watch.recordWakeup('Noisy');
    expect(logs, hasLength(1));
    expect(logs.single, contains('WingBgWatch'));
    expect(logs.single, contains('Noisy=${WingBgWatch.wakeupThreshold + 5}'));
  });

  test('each report window starts a fresh count', () {
    watch.setForeground(false);
    for (var i = 0; i < WingBgWatch.wakeupThreshold + 1; i++) {
      watch.recordWakeup('Noisy');
    }
    now = now.add(const Duration(minutes: 1));
    watch.recordWakeup('Noisy');
    expect(logs, hasLength(1));
    now = now.add(const Duration(minutes: 1));
    watch.recordWakeup('Noisy');
    expect(
      logs,
      hasLength(1),
      reason: 'only one wake-up in the new window, no new log line',
    );
  });

  test('going foreground clears counters without logging', () {
    watch.setForeground(false);
    for (var i = 0; i < WingBgWatch.wakeupThreshold + 1; i++) {
      watch.recordWakeup('Noisy');
    }
    watch.setForeground(true);
    expect(logs, isEmpty);
    watch.setForeground(false);
    now = now.add(const Duration(minutes: 1));
    watch.recordWakeup('Noisy');
    expect(
      logs,
      isEmpty,
      reason: 'the cleared count has not reached the threshold again',
    );
  });

  test('multiple offenders in the same window are all named in one line', () {
    watch.setForeground(false);
    for (var i = 0; i < WingBgWatch.wakeupThreshold + 10; i++) {
      watch.recordWakeup('A');
    }
    for (var i = 0; i < WingBgWatch.wakeupThreshold + 1; i++) {
      watch.recordWakeup('B');
    }
    now = now.add(const Duration(minutes: 1));
    // The window check runs before this call's own increment, so trigger the
    // flush on a component that already cleared the bar in the loops above.
    watch.recordWakeup('A');
    expect(logs.single, contains('A=${WingBgWatch.wakeupThreshold + 10}'));
    expect(logs.single, contains('B=${WingBgWatch.wakeupThreshold + 1}'));
  });
}

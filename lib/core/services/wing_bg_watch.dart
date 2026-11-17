import 'package:flutter/foundation.dart';

/// Counts main-isolate timer/poll wake-ups per component while the app is
/// not in the foreground, and logs one `WingBgWatch` line per minute
/// (component => count) when any component exceeds [wakeupThreshold].
///
/// This is a diagnostic net, not an enforcement mechanism: components are
/// still required to stop their own timers on pause. Release builds are
/// unsymbolized, so this is the cheapest way to catch a future regression
/// that slips past code review.
///
/// Deliberately has no Timer of its own: every background-eligible
/// component already ticks on its own schedule, so the report window is
/// just checked and rolled on each [recordWakeup] call. A self-scheduling
/// Timer here would otherwise sit pending forever in any widget test that
/// pauses the app without resuming it before the test ends.
class WingBgWatch {
  WingBgWatch({
    Duration reportInterval = const Duration(minutes: 1),
    DateTime Function()? now,
    void Function(String)? log,
  }) : // The named default is an injectable public seam.
       // ignore: prefer_initializing_formals
       _reportInterval = reportInterval,
       _now = now ?? DateTime.now,
       _log = log ?? debugPrint;

  /// Shared instance wired to app lifecycle in `main.dart` and called from
  /// every background-eligible timer/poll callback.
  static final WingBgWatch instance = WingBgWatch();

  /// Wake-ups per minute, per component, above which a line is logged.
  static const wakeupThreshold = 60;

  final Duration _reportInterval;
  final DateTime Function() _now;
  final void Function(String) _log;
  final Map<String, int> _counts = {};
  DateTime? _windowStart;
  bool _foreground = true;

  /// Call from the app's single `didChangeAppLifecycleState`. Going
  /// foreground clears counters without logging: nothing was wrong, the
  /// window just ended early.
  void setForeground(bool foreground) {
    _foreground = foreground;
    if (foreground) {
      _counts.clear();
      _windowStart = null;
    }
  }

  /// Call once per actual timer/poll callback invocation, from every
  /// component that still runs while backgrounded (event-driven sockets,
  /// and voice/car-mode sessions that are the agreed exceptions, don't
  /// need to call this).
  void recordWakeup(String component) {
    if (_foreground) return;
    final now = _now();
    final windowStart = _windowStart ??= now;
    if (now.difference(windowStart) >= _reportInterval) {
      _flush();
      _windowStart = now;
    }
    _counts[component] = (_counts[component] ?? 0) + 1;
  }

  void _flush() {
    final offenders = _counts.entries
        .where((entry) => entry.value > wakeupThreshold)
        .toList();
    offenders.sort((a, b) => b.value.compareTo(a.value));
    if (offenders.isNotEmpty) {
      _log(
        'WingBgWatch ${offenders.map((e) => '${e.key}=${e.value}').join(', ')}',
      );
    }
    _counts.clear();
  }
}

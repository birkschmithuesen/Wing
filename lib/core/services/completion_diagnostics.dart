import 'dart:developer' as developer;

import 'performance_instrumentation.dart';

/// Opt-in performance measurements. Never records message data.
class CompletionDiagnostics {
  static const enabled = PerformanceInstrumentation.enabled;
  static const _capacity = 4096;
  static final _events = List<Map<String, Object?>?>.filled(_capacity, null);
  static final _totals = <String, Map<String, int>>{};
  static int _written = 0;

  static int start() => enabled ? developer.Timeline.now : 0;

  static void finish(
    String name,
    int start, {
    Map<String, num> values = const {},
  }) {
    if (!enabled) return;
    final now = developer.Timeline.now;
    _record(name, now, now - start, values);
  }

  static void event(String name, {Map<String, num> values = const {}}) {
    if (!enabled) return;
    _record(name, developer.Timeline.now, 0, values);
  }

  static void _record(
    String name,
    int timeUs,
    int durationUs,
    Map<String, num> values,
  ) {
    _events[_written++ % _capacity] = {
      'name': name,
      'timeUs': timeUs,
      'durationUs': durationUs,
      if (values.isNotEmpty) 'values': Map<String, num>.of(values),
    };
    final total = _totals.putIfAbsent(
      name,
      () => {'count': 0, 'totalUs': 0, 'maxUs': 0},
    );
    total['count'] = total['count']! + 1;
    total['totalUs'] = total['totalUs']! + durationUs;
    if (durationUs > total['maxUs']!) total['maxUs'] = durationUs;
  }

  static Map<String, Object?> snapshot() {
    if (!enabled) return {'enabled': false};
    final retained = _written < _capacity ? _written : _capacity;
    return {
      'enabled': true,
      'capacity': _capacity,
      'written': _written,
      'dropped': _written - retained,
      'events': [
        for (var i = _written - retained; i < _written; i++)
          Map<String, Object?>.of(_events[i % _capacity]!),
      ],
      'totals': {
        for (final entry in _totals.entries)
          entry.key: Map<String, int>.of(entry.value),
      },
    };
  }

  static void reset() {
    if (!enabled) return;
    _events.fillRange(0, _capacity, null);
    _totals.clear();
    _written = 0;
  }
}

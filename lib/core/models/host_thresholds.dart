import 'host_resources.dart';

/// Load is normalized by logical CPU count: 1 means one runnable unit per CPU.
/// The other metrics use percent (0..100). These are client alert policies,
/// separate from the backend's resource-pressure classification.
enum HostMetric {
  cpuPercent,
  memoryUsedPercent,
  diskUsedPercent,
  loadOneMinutePerCpu,
  loadFiveMinutesPerCpu,
  loadFifteenMinutesPerCpu,
}

class HostThreshold {
  HostThreshold(this.metric, this.limit) {
    if (!limit.isFinite || limit < 0) {
      throw ArgumentError.value(
        limit,
        'limit',
        'Must be finite and nonnegative',
      );
    }
    if (metric.index <= HostMetric.diskUsedPercent.index && limit > 100) {
      throw ArgumentError.value(limit, 'limit', 'Percent must be at most 100');
    }
  }
  final HostMetric metric;
  final double limit;
}

enum HostThresholdStatus { above, within, unknown }

class HostThresholdResult {
  const HostThresholdResult(this.threshold, this.status, this.value);
  final HostThreshold threshold;
  final HostThresholdStatus status;
  final double? value;
}

/// Stateless evaluation; callers choose thresholds, freshness and delivery.
/// Missing, stale, future-dated or failed readings return unknown, never clear
/// an incident as healthy. Equality is within the limit; only > raises above.
class HostThresholdPolicy {
  HostThresholdPolicy(
    Iterable<HostThreshold> thresholds, {
    this.maxAge = const Duration(seconds: 30),
  }) : thresholds = List.unmodifiable(thresholds) {
    if (maxAge <= Duration.zero) throw ArgumentError.value(maxAge, 'maxAge');
    if (this.thresholds.map((t) => t.metric).toSet().length !=
        this.thresholds.length) {
      throw ArgumentError('A metric can have only one threshold in a policy');
    }
  }
  final List<HostThreshold> thresholds;
  final Duration maxAge;

  List<HostThresholdResult> evaluate(
    HostReading<HostSystemStats> reading, {
    required DateTime now,
  }) => List.unmodifiable(
    thresholds.map((threshold) {
      final value = reading.isCurrent(now, maxAge)
          ? _value(reading.value!, threshold.metric)
          : null;
      return HostThresholdResult(
        threshold,
        value == null || !value.isFinite || value < 0
            ? HostThresholdStatus.unknown
            : value > threshold.limit
            ? HostThresholdStatus.above
            : HostThresholdStatus.within,
        value,
      );
    }),
  );

  double? _value(HostSystemStats stats, HostMetric metric) {
    if (metric == HostMetric.cpuPercent) return stats.cpuPercent;
    if (metric == HostMetric.memoryUsedPercent) {
      return stats.memory?.usedPercent;
    }
    if (metric == HostMetric.diskUsedPercent) return stats.disk?.usedPercent;
    final cpus = stats.logicalCpus;
    final load = stats.load;
    if (cpus == null || cpus <= 0 || load == null) return null;
    return switch (metric) {
      HostMetric.loadOneMinutePerCpu => load.oneMinute / cpus,
      HostMetric.loadFiveMinutesPerCpu => load.fiveMinutes / cpus,
      HostMetric.loadFifteenMinutesPerCpu => load.fifteenMinutes / cpus,
      _ => null,
    };
  }
}

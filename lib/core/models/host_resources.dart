/// Immutable host observations. Byte counts are binary bytes; load averages
/// describe runnable work, not a CPU percentage. Uptime is host boot uptime.
class HostSystemStats {
  const HostSystemStats({
    required this.hostname,
    required this.os,
    required this.osRelease,
    required this.architecture,
    required this.pythonVersion,
    required this.pythonImplementation,
    required this.hermesVersion,
    required this.hasPsutil,
    this.logicalCpus,
    this.cpuPercent,
    this.load,
    this.uptime,
    this.memory,
    this.disk,
    this.process,
  });

  final String hostname, os, osRelease, architecture;
  final String pythonVersion, pythonImplementation, hermesVersion;
  final bool hasPsutil;
  final int? logicalCpus;
  final double? cpuPercent;
  final HostLoadAverage? load;
  final Duration? uptime;
  final HostMemoryStats? memory;
  final HostDiskStats? disk;
  final HostProcessStats? process;
}

class HostLoadAverage {
  const HostLoadAverage(this.oneMinute, this.fiveMinutes, this.fifteenMinutes);
  final double oneMinute, fiveMinutes, fifteenMinutes;
}

class HostMemoryStats {
  const HostMemoryStats({
    required this.totalBytes,
    required this.usedBytes,
    required this.availableBytes,
    required this.usedPercent,
  });
  final int totalBytes, usedBytes, availableBytes;
  final double usedPercent;
}

class HostDiskStats {
  const HostDiskStats({
    required this.totalBytes,
    required this.usedBytes,
    required this.freeBytes,
    required this.usedPercent,
  });
  final int totalBytes, usedBytes, freeBytes;
  final double usedPercent;
}

/// The serving API process only, not the total of every Hermes process.
class HostProcessStats {
  const HostProcessStats({
    required this.residentBytes,
    required this.startedAt,
    required this.threads,
  });
  final int residentBytes, threads;
  final DateTime startedAt;
}

enum HostPressure { ok, elevated, critical, unknown }

class HostPressureStatus {
  const HostPressureStatus({
    required this.memory,
    required this.disk,
    this.memorySampledAt,
    this.previousBootUnclean = false,
    this.previousBootSuspectedOom = false,
  });
  final HostPressure memory, disk;
  final DateTime? memorySampledAt;
  final bool previousBootUnclean, previousBootSuspectedOom;

  // Current upstream tolerates 150 seconds between gateway heartbeats.
  HostPressure memoryAt(DateTime now) {
    final at = memorySampledAt;
    if (at == null ||
        now.isBefore(at) ||
        now.difference(at) > const Duration(seconds: 150)) {
      return HostPressure.unknown;
    }
    return memory;
  }
}

/// A failed refresh retains the previous value and receipt time. An error or
/// stale/future timestamp prevents that retained value from being current.
class HostReading<T> {
  const HostReading({this.value, this.readAt, this.error});
  final T? value;
  final DateTime? readAt;
  final String? error;

  bool isCurrent(DateTime now, Duration maxAge) =>
      value != null &&
      error == null &&
      readAt != null &&
      !now.isBefore(readAt!) &&
      now.difference(readAt!) < maxAge;
}

class HostResourcesState {
  const HostResourcesState({
    this.stats = const HostReading<HostSystemStats>(),
    this.pressure = const HostReading<HostPressureStatus>(),
    this.refreshing = false,
    this.attemptedAt,
  });
  final HostReading<HostSystemStats> stats;
  final HostReading<HostPressureStatus> pressure;
  final bool refreshing;
  final DateTime? attemptedAt;

  HostResourcesState copyWith({
    HostReading<HostSystemStats>? stats,
    HostReading<HostPressureStatus>? pressure,
    bool? refreshing,
    DateTime? attemptedAt,
  }) => HostResourcesState(
    stats: stats ?? this.stats,
    pressure: pressure ?? this.pressure,
    refreshing: refreshing ?? this.refreshing,
    attemptedAt: attemptedAt ?? this.attemptedAt,
  );
}

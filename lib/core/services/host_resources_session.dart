import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/host_resources.dart';
import 'administration_repository.dart';

/// Shared, connection-owned stock host data. Concurrent refreshes coalesce;
/// endpoint outcomes are independent and failed reads retain their last value.
/// Polling exists only while at least one active consumer holds a watch.
class HostResourcesSession extends ChangeNotifier {
  HostResourcesSession(
    AdministrationRepository server, {
    DateTime Function()? now,
  }) : _server = server,
       _now = now ?? DateTime.now {
    _server.retain();
  }
  final AdministrationRepository _server;
  final DateTime Function() _now;
  String get connectionId => _server.connectionId;
  String get connectionIdentity => _server.connectionIdentity;
  String get scopeLabel => _server.connectionLabel;
  HostResourcesState _state = const HostResourcesState();
  HostResourcesState get state => _state;
  final _watches = <HostResourcesWatch>{};
  Timer? _timer;
  Future<void>? _refresh;
  bool _disposed = false;
  int _notificationDepth = 0;

  HostResourcesWatch watch({
    Duration interval = const Duration(seconds: 15),
    bool active = true,
  }) {
    if (_disposed) throw StateError('Host resources are closed');
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval');
    }
    final previouslyActive = _interval != null;
    final watch = HostResourcesWatch._(this, interval, active);
    _watches.add(watch);
    _reconcile(previouslyActive);
    return watch;
  }

  Duration? get _interval {
    Duration? shortest;
    for (final watch in _watches) {
      if (watch._active && (shortest == null || watch.interval < shortest)) {
        shortest = watch.interval;
      }
    }
    return shortest;
  }

  void _reconcile(bool previouslyActive) {
    _timer?.cancel();
    _timer = null;
    if (_disposed || _interval == null) return;
    if (!previouslyActive) {
      unawaited(refresh());
    } else {
      _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    final interval = _interval;
    if (!_disposed && _refresh == null && interval != null) {
      _timer = Timer(interval, () => unawaited(refresh()));
    }
  }

  Future<void> refresh() {
    if (_disposed) return Future.value();
    if (_refresh case final pending?) return pending;
    final completer = Completer<void>();
    _refresh = completer.future;
    _timer?.cancel();
    _timer = null;
    unawaited(_read(completer));
    return completer.future;
  }

  Future<void> _read(Completer<void> completer) async {
    _server.retain();
    try {
      _publish(_state.copyWith(refreshing: true, attemptedAt: _now()));
      if (_disposed) return;
      await Future.wait([_readStats(), _readPressure()]);
      if (!_disposed) _publish(_state.copyWith(refreshing: false));
    } finally {
      _server.release();
      _refresh = null;
      completer.complete();
      _schedule();
    }
  }

  Future<void> _readStats() async {
    final reading = await _readEndpoint(
      'system/stats',
      _decodeStats,
      _state.stats,
    );
    if (!_disposed) _publish(_state.copyWith(stats: reading));
  }

  Future<void> _readPressure() async {
    final reading = await _readEndpoint(
      'status',
      _decodePressure,
      _state.pressure,
    );
    if (!_disposed) _publish(_state.copyWith(pressure: reading));
  }

  Future<HostReading<T>> _readEndpoint<T>(
    String endpoint,
    T Function(Map<String, dynamic>) decode,
    HostReading<T> previous,
  ) async {
    if (_disposed) return previous;
    try {
      final response = await _server.read(endpoint);
      if (_disposed) return previous;
      return HostReading(value: decode(response), readAt: _now());
    } catch (error) {
      return HostReading(
        value: previous.value,
        readAt: previous.readAt,
        error: error is FormatException
            ? 'The server returned invalid host data.'
            : administrationError(error),
      );
    }
  }

  void _publish(HostResourcesState state) {
    if (_disposed) return;
    _state = state;
    _notificationDepth++;
    try {
      notifyListeners();
    } finally {
      _notificationDepth--;
      if (_disposed && _notificationDepth == 0) super.dispose();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    for (final watch in _watches) {
      watch._owner = null;
    }
    _watches.clear();
    _server.release();
    if (_notificationDepth == 0) super.dispose();
  }
}

/// Each surface declares its own demand; another active consumer keeps the
/// shared poll alive. Closing a watch does not retire the connection's data.
class HostResourcesWatch {
  HostResourcesWatch._(this._owner, this.interval, this._active);
  HostResourcesSession? _owner;
  final Duration interval;
  bool _active;

  void setActive(bool active) {
    final owner = _owner;
    if (owner == null || _active == active) return;
    final previouslyActive = owner._interval != null;
    _active = active;
    owner._reconcile(previouslyActive);
  }

  void close() {
    final owner = _owner;
    if (owner == null) return;
    final previouslyActive = owner._interval != null;
    _owner = null;
    owner._watches.remove(this);
    owner._reconcile(previouslyActive);
  }
}

// Decoding lives with the I/O owner. Views and alert policies see typed values.
double? _number(Object? value) =>
    value is num && value.isFinite && value >= 0 ? value.toDouble() : null;
int? _integer(Object? value) => value is int && value >= 0 ? value : null;
double? _percent(Object? value) {
  final number = _number(value);
  return number != null && number <= 100 ? number : null;
}

String _text(Map value, String key) {
  final text = value[key];
  if (text is! String) throw FormatException('Missing host identity: $key');
  return text;
}

HostSystemStats _decodeStats(Map<String, dynamic> value) {
  if (value['psutil'] is! bool) {
    throw const FormatException('Missing psutil flag');
  }
  final cpus = _integer(value['cpu_count']);
  final seconds = _integer(value['uptime_seconds']);
  final load = value['load_avg'];
  final loads = load is List && load.length == 3
      ? load.map(_number).toList()
      : null;
  return HostSystemStats(
    hostname: _text(value, 'hostname'),
    os: _text(value, 'os'),
    osRelease: _text(value, 'os_release'),
    architecture: _text(value, 'arch'),
    pythonVersion: _text(value, 'python_version'),
    pythonImplementation: _text(value, 'python_impl'),
    hermesVersion: _text(value, 'hermes_version'),
    hasPsutil: value['psutil'] as bool,
    logicalCpus: cpus != null && cpus > 0 ? cpus : null,
    cpuPercent: _percent(value['cpu_percent']),
    uptime: seconds == null ? null : Duration(seconds: seconds),
    load: loads != null && loads.every((n) => n != null)
        ? HostLoadAverage(loads[0]!, loads[1]!, loads[2]!)
        : null,
    memory: _memory(value['memory']),
    disk: _disk(value['disk']),
    process: _process(value['process']),
  );
}

(int, int, int, double)? _capacity(Object? value, String remainingKey) {
  if (value is! Map) return null;
  final total = _integer(value['total']);
  final used = _integer(value['used']);
  final remaining = _integer(value[remainingKey]);
  final percent = _percent(value['percent']);
  if (total == null ||
      total == 0 ||
      used == null ||
      remaining == null ||
      percent == null ||
      used > total ||
      remaining > total) {
    return null;
  }
  return (total, used, remaining, percent);
}

HostMemoryStats? _memory(Object? value) {
  final c = _capacity(value, 'available');
  return c == null
      ? null
      : HostMemoryStats(
          totalBytes: c.$1,
          usedBytes: c.$2,
          availableBytes: c.$3,
          usedPercent: c.$4,
        );
}

HostDiskStats? _disk(Object? value) {
  final c = _capacity(value, 'free');
  return c == null
      ? null
      : HostDiskStats(
          totalBytes: c.$1,
          usedBytes: c.$2,
          freeBytes: c.$3,
          usedPercent: c.$4,
        );
}

HostProcessStats? _process(Object? value) {
  if (value is! Map) return null;
  final rss = _integer(value['rss']);
  final created = _integer(value['create_time']);
  final threads = _integer(value['num_threads']);
  if (rss == null ||
      created == null ||
      threads == null ||
      created > 8640000000000) {
    return null;
  }
  return HostProcessStats(
    residentBytes: rss,
    startedAt: DateTime.fromMillisecondsSinceEpoch(created * 1000, isUtc: true),
    threads: threads,
  );
}

HostPressure _pressure(Object? value) => switch (value) {
  'ok' => HostPressure.ok,
  'elevated' => HostPressure.elevated,
  'critical' => HostPressure.critical,
  _ => HostPressure.unknown,
};
HostPressureStatus _decodePressure(Map<String, dynamic> value) {
  final memory = value['memory'], disk = value['disk'];
  if (memory is! Map || disk is! Map) {
    throw const FormatException('Missing host pressure observations');
  }
  return HostPressureStatus(
    memory: _pressure(memory['pressure']),
    disk: _pressure(disk['pressure']),
    memorySampledAt: memory['sampled_at'] is String
        ? DateTime.tryParse(memory['sampled_at'] as String)
        : null,
    previousBootUnclean: memory['last_boot_unclean'] == true,
    previousBootSuspectedOom: memory['last_boot_suspected_oom'] == true,
  );
}

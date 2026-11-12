import 'dart:async';
import 'package:wing/core/services/administration_repository.dart';

// Stock /api/system/stats and /api/status shape verified at upstream 05eecbcd.
Map<String, dynamic> hostStatsPayload() => {
  'hostname': 'hermes-nas',
  'os': 'Linux',
  'os_release': '6.8.0',
  'arch': 'x86_64',
  'python_version': '3.12.3',
  'python_impl': 'CPython',
  'hermes_version': '0.14.0',
  'psutil': true,
  'cpu_count': 8,
  'cpu_percent': 12.0,
  'load_avg': [0.60, 0.72, 0.61],
  'uptime_seconds': 1750800,
  'memory': {
    'total': 34359738368,
    'used': 13099650253,
    'available': 19971597926,
    'percent': 38.1,
  },
  'disk': {
    'total': 536870912000,
    'used': 327491256320,
    'free': 209379655680,
    'percent': 61.0,
  },
  'process': {
    'pid': 2147,
    'rss': 448790528,
    'create_time': 1791335520,
    'num_threads': 24,
  },
};
Map<String, dynamic> hostPressurePayload({DateTime? now}) => {
  'memory': {
    'pressure': 'ok',
    'sampled_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
    'last_boot_unclean': false,
    'last_boot_suspected_oom': false,
  },
  'disk': {'pressure': 'ok'},
};

class HostResourcesFixture {
  HostResourcesFixture({this.identity = 'endpoint'});
  final String identity;
  final requests = <(String, String, Map<String, String>)>[];
  Map<String, dynamic> stats = hostStatsPayload();
  Map<String, dynamic> pressure = hostPressurePayload();
  Object? statsError, pressureError;
  Completer<void>? statsGate, pressureGate;
  int closed = 0;
  late final server = AdministrationRepository(
    connectionId: 'server',
    connectionIdentity: identity,
    connectionLabel: 'Home server',
    settingsWrite: (_, _, _, _) async => throw StateError('Unexpected write'),
    ownedMutation: (_, _, _, _, _, _) async =>
        throw StateError('Unexpected mutation'),
    gateway: (_) => throw StateError('Unexpected profile access'),
    close: () => closed++,
    request: (method, path, query, body) async {
      requests.add((method, path, Map.of(query)));
      if (method != 'GET' || body != null || query.isNotEmpty) {
        throw StateError('Unexpected scope/write');
      }
      if (path == 'system/stats') {
        if (statsGate case final gate?) await gate.future;
        if (statsError case final error?) throw error;
        return stats;
      }
      if (path == 'status') {
        if (pressureGate case final gate?) await gate.future;
        if (pressureError case final error?) throw error;
        return pressure;
      }
      throw StateError('Unexpected $path');
    },
  );
}

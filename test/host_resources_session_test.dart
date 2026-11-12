import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/host_resources.dart';
import 'package:wing/core/services/host_resources_session.dart';
import 'support/host_resources_fixture.dart';

void main() {
  late HostResourcesFixture fixture;
  late HostResourcesSession resources;
  late DateTime now;
  setUp(() {
    now = DateTime.utc(2026, 10, 7, 6, 32);
    fixture = HostResourcesFixture();
    resources = HostResourcesSession(fixture.server, now: () => now);
  });
  tearDown(() {
    resources.dispose();
    fixture.server.close();
  });

  test('coalesces reads, captures connection, and copies typed data', () async {
    fixture.statsGate = Completer();
    fixture.pressureGate = Completer();
    final first = resources.refresh(), second = resources.refresh();
    expect(identical(first, second), isTrue);
    expect(resources.state.refreshing, isTrue);
    expect(fixture.requests.map((r) => r.$2), ['system/stats', 'status']);
    fixture.statsGate!.complete();
    fixture.pressureGate!.complete();
    await first;
    final stats = resources.state.stats.value!;
    expect(resources.connectionId, 'server');
    expect(resources.connectionIdentity, 'endpoint');
    expect(stats.hostname, 'hermes-nas');
    expect(stats.logicalCpus, 8);
    expect(stats.cpuPercent, 12);
    expect(stats.uptime!.inDays, 20);
    expect(stats.load!.fiveMinutes, .72);
    expect(stats.process!.residentBytes, 448790528);
    fixture.stats['cpu_percent'] = 99;
    (fixture.stats['memory'] as Map)['used'] = 0;
    (fixture.stats['load_avg'] as List)[0] = 99.0;
    expect(stats.cpuPercent, 12);
    expect(stats.memory!.usedBytes, 13099650253);
    expect(stats.load!.oneMinute, .6);
    expect(resources.state.stats.readAt, now);
    expect(resources.state.refreshing, isFalse);
    expect(
      fixture.requests.every((r) => r.$1 == 'GET' && r.$3.isEmpty),
      isTrue,
    );
  });

  test(
    'endpoint failures retain timestamps and do not suppress other data',
    () async {
      await resources.refresh();
      final first = resources.state;
      now = now.add(const Duration(seconds: 20));
      fixture.statsError = StateError('offline');
      fixture.pressure['disk'] = {'pressure': 'critical'};
      await resources.refresh();
      expect(resources.state.stats.value, same(first.stats.value));
      expect(resources.state.stats.readAt, first.stats.readAt);
      expect(resources.state.stats.error, isNotNull);
      expect(
        resources.state.stats.isCurrent(now, const Duration(seconds: 30)),
        isFalse,
      );
      expect(resources.state.pressure.value!.disk, HostPressure.critical);
      expect(resources.state.pressure.readAt, now);
      fixture.statsError = null;
      fixture.pressureError = StateError('pressure unavailable');
      fixture.stats['cpu_percent'] = 42;
      await resources.refresh();
      expect(resources.state.stats.error, isNull);
      expect(resources.state.stats.value!.cpuPercent, 42);
      expect(resources.state.pressure.error, isNotNull);
      expect(resources.state.pressure.value!.disk, HostPressure.critical);
    },
  );

  test(
    'optional stock metrics stay unknown and malformed probes stay local',
    () async {
      fixture.stats['psutil'] = false;
      for (final key in [
        'cpu_percent',
        'memory',
        'disk',
        'process',
        'uptime_seconds',
      ]) {
        fixture.stats.remove(key);
      }
      await resources.refresh();
      expect(resources.state.stats.error, isNull);
      expect(resources.state.stats.value!.cpuPercent, isNull);
      expect(resources.state.stats.value!.memory, isNull);
      expect(resources.state.stats.value!.disk, isNull);
      expect(resources.state.stats.value!.load!.oneMinute, .6);
      fixture.stats = hostStatsPayload();
      fixture.stats['cpu_percent'] = double.nan;
      fixture.stats['memory'] = {'total': -1};
      fixture.stats['load_avg'] = [1, 'unknown', 3];
      await resources.refresh();
      expect(resources.state.stats.error, isNull);
      expect(resources.state.stats.value!.cpuPercent, isNull);
      expect(resources.state.stats.value!.memory, isNull);
      expect(resources.state.stats.value!.load, isNull);
      expect(resources.state.stats.value!.disk!.usedPercent, 61);
    },
  );

  test(
    'invalid identity is a failed observation, not invented host data',
    () async {
      fixture.stats = {'psutil': false};
      await resources.refresh();
      expect(resources.state.stats.value, isNull);
      expect(
        resources.state.stats.error,
        'The server returned invalid host data.',
      );
      expect(resources.state.pressure.error, isNull);
    },
  );

  testWidgets('multiple watches share polling and pause independently', (
    tester,
  ) async {
    final first = resources.watch(interval: const Duration(seconds: 10));
    final second = resources.watch(interval: const Duration(seconds: 15));
    await tester.pump();
    expect(fixture.requests, hasLength(2));
    await tester.pump(const Duration(seconds: 10));
    expect(fixture.requests, hasLength(4));
    first.setActive(false);
    await tester.pump(const Duration(seconds: 15));
    expect(fixture.requests, hasLength(6));
    second.setActive(false);
    await tester.pump(const Duration(minutes: 2));
    expect(fixture.requests, hasLength(6));
    second.setActive(true);
    await tester.pump();
    expect(fixture.requests, hasLength(8));
    first.close();
    second.close();
    await tester.pump(const Duration(minutes: 2));
    expect(fixture.requests, hasLength(8));
    expect(resources.state.stats.value, isNotNull);
  });

  test('disposing during notification prevents dispatch', () async {
    resources.addListener(resources.dispose);
    await resources.refresh();
    expect(fixture.requests, isEmpty);
    fixture.server.close();
    expect(fixture.closed, 1);
  });

  test(
    'late completion cannot publish after retirement; I/O retains connection',
    () async {
      fixture.statsGate = Completer();
      fixture.pressureGate = Completer();
      var changes = 0;
      resources.addListener(() => changes++);
      final pending = resources.refresh();
      resources.dispose();
      fixture.server.close();
      expect(fixture.closed, 0);
      final before = changes;
      fixture.statsGate!.complete();
      fixture.pressureGate!.complete();
      await pending;
      expect(changes, before);
      expect(resources.state.stats.value, isNull);
      expect(fixture.closed, 1);
    },
  );

  test('different connection identities have separate observations', () async {
    await resources.refresh();
    final other = HostResourcesFixture(identity: 'new-endpoint');
    final session = HostResourcesSession(other.server);
    expect(session.connectionIdentity, 'new-endpoint');
    expect(session.state.stats.value, isNull);
    session.dispose();
    other.server.close();
  });
}

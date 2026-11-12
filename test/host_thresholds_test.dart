import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/host_resources.dart';
import 'package:wing/core/models/host_thresholds.dart';
import 'package:wing/core/services/host_resources_session.dart';
import 'support/host_resources_fixture.dart';

void main() {
  final now = DateTime.utc(2026, 10, 7);
  test(
    'evaluates CPU, RAM, disk and load with independent caller limits',
    () async {
      final fixture = HostResourcesFixture();
      fixture.stats['cpu_percent'] = 82;
      fixture.stats['load_avg'] = [12, 8, 4];
      final session = HostResourcesSession(fixture.server, now: () => now);
      await session.refresh();
      final limits = [80.0, 40.0, 60.0, 1.0, 1.0, .6];
      final policy = HostThresholdPolicy([
        for (var i = 0; i < HostMetric.values.length; i++)
          HostThreshold(HostMetric.values[i], limits[i]),
      ]);
      final results = policy.evaluate(session.state.stats, now: now);
      expect(results.map((r) => r.status), [
        HostThresholdStatus.above,
        HostThresholdStatus.within,
        HostThresholdStatus.above,
        HostThresholdStatus.above,
        HostThresholdStatus.within,
        HostThresholdStatus.within,
      ]);
      expect(results.map((r) => r.value), [82, 38.1, 61, 1.5, 1, .5]);
      expect(() => results.clear(), throwsUnsupportedError);
      expect(() => policy.thresholds.clear(), throwsUnsupportedError);
      session.dispose();
      fixture.server.close();
    },
  );

  test(
    'missing, failed, stale and future readings cannot clear an alert',
    () async {
      final fixture = HostResourcesFixture();
      final session = HostResourcesSession(fixture.server, now: () => now);
      await session.refresh();
      final stats = session.state.stats.value!;
      final policy = HostThresholdPolicy([
        HostThreshold(HostMetric.cpuPercent, 10),
      ]);
      for (final reading in [
        const HostReading<HostSystemStats>(),
        HostReading(value: stats, readAt: now, error: 'offline'),
        HostReading(
          value: stats,
          readAt: now.subtract(const Duration(seconds: 30)),
        ),
        HostReading(value: stats, readAt: now.add(const Duration(seconds: 1))),
      ]) {
        expect(
          policy.evaluate(reading, now: now).single.status,
          HostThresholdStatus.unknown,
        );
      }
      fixture.stats.remove('cpu_percent');
      fixture.stats['cpu_count'] = null;
      await session.refresh();
      final loadPolicy = HostThresholdPolicy([
        HostThreshold(HostMetric.loadOneMinutePerCpu, 1),
      ]);
      expect(
        policy.evaluate(session.state.stats, now: now).single.status,
        HostThresholdStatus.unknown,
      );
      expect(
        loadPolicy.evaluate(session.state.stats, now: now).single.status,
        HostThresholdStatus.unknown,
      );
      fixture.stats['cpu_percent'] = 0;
      await session.refresh();
      expect(
        policy.evaluate(session.state.stats, now: now).single.status,
        HostThresholdStatus.within,
      );
      session.dispose();
      fixture.server.close();
    },
  );

  test('validates policy and threshold units', () {
    for (final limit in [double.nan, double.infinity, -1.0, 101.0]) {
      expect(
        () => HostThreshold(HostMetric.cpuPercent, limit),
        throwsArgumentError,
      );
    }
    expect(
      () => HostThresholdPolicy([], maxAge: Duration.zero),
      throwsArgumentError,
    );
    expect(
      () => HostThresholdPolicy([
        HostThreshold(HostMetric.diskUsedPercent, 80),
        HostThreshold(HostMetric.diskUsedPercent, 90),
      ]),
      throwsArgumentError,
    );
    expect(HostThreshold(HostMetric.loadOneMinutePerCpu, 2).limit, 2);
  });

  test('backend heartbeat pressure expires separately from host read time', () {
    final pressure = HostPressureStatus(
      memory: HostPressure.critical,
      disk: HostPressure.ok,
      memorySampledAt: now,
    );
    expect(
      pressure.memoryAt(now.add(const Duration(seconds: 150))),
      HostPressure.critical,
    );
    expect(
      pressure.memoryAt(now.add(const Duration(seconds: 151))),
      HostPressure.unknown,
    );
    expect(
      pressure.memoryAt(now.subtract(const Duration(seconds: 1))),
      HostPressure.unknown,
    );
  });
}

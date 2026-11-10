import '../models/host_thresholds.dart';
import '../models/health_alert.dart';

String healthAlertActionLabel(HealthAlert alert) => switch (alert.destination) {
  'Connection details' => 'Open connection details',
  'MCP connectors' =>
    alert.connectorNames.length == 1
        ? 'Open connector ${alert.connectorNames.single}'
        : 'Open MCP connectors',
  'Access and connectors' => 'Open profile access',
  'Models and reasoning' => 'Open models and reasoning',
  'Skills and tools' => 'Open skills and tools',
  'Scheduled tasks' => 'Open scheduled tasks',
  _ => 'Open Hermes health',
};

String? healthAlertTriggerSummary(HealthAlert alert) {
  final trigger = alert.trigger;
  if (trigger == null) return null;
  final value = trigger.usedPercent;
  final usage = value == null
      ? 'Usage unavailable'
      : '${healthAlertPercentage(value)}% used';
  return trigger.criticalPressure
      ? '$usage · critical pressure reported'
      : '$usage · above ${healthAlertPercentage(trigger.warningAbovePercent)}% for ${trigger.alertMinutes} min';
}

String healthAlertMetricLabel(HostMetric metric) => switch (metric) {
  HostMetric.memoryUsedPercent => 'Memory usage',
  HostMetric.diskUsedPercent => 'Disk usage',
  _ => 'CPU usage',
};

String healthAlertRuleSummary(HostMetric metric, HealthAlertRule rule) {
  if (!rule.enabled) {
    return rule.nativeCriticalEnabled
        ? 'Native critical alerts only'
        : 'Not watched';
  }
  final warning =
      'Above ${healthAlertPercentage(rule.warnAbove)}% for ${rule.alertMinutes} min';
  return healthAlertNativeCriticalLabel(metric) == null
      ? warning
      : '$warning · native critical ${rule.nativeCriticalEnabled ? 'on' : 'off'}';
}

String? healthAlertNativeCriticalLabel(HostMetric metric) => switch (metric) {
  HostMetric.memoryUsedPercent ||
  HostMetric.diskUsedPercent => 'Native Hermes critical pressure alert',
  _ => null,
};

String healthAlertNativeCriticalDetail(HostMetric metric) => switch (metric) {
  HostMetric.memoryUsedPercent =>
    'Below 5% available RAM or 64 MiB free. Alerts immediately.',
  HostMetric.diskUsedPercent =>
    'Below 256 MiB free, or at least 95% used with under 1 GiB free. Alerts immediately.',
  _ => throw ArgumentError.value(metric, 'metric', 'No native pressure signal'),
};

/// Preserve editable precision while omitting the redundant decimal for integers.
String healthAlertPercentage(double value) => value == value.truncateToDouble()
    ? value.toInt().toString()
    : value.toString();

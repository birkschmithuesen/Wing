import 'package:flutter/material.dart';

import '../../models/health_alert.dart';
import '../../presentation/health_alert_presentation.dart';
import '../../theme/wing_theme.dart';
import '../../widgets/health_alerts/health_alert_dialog.dart';
import '../../widgets/health_alerts/health_alerts_scope.dart';
import '../health_alert_settings_screen.dart';
import 'admin_widgets.dart';

class AdminHealthAlerts extends StatelessWidget {
  const AdminHealthAlerts({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = HealthAlertsScope.maybeOf(context);
    if (scope == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'Alerts',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              StudioButtonPress(
                child: IconButton(
                  tooltip: 'Alert settings',
                  icon: const Icon(Icons.tune),
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => HealthAlertSettingsScreen(
                        session: scope.alerts.settings,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ListenableBuilder(
            listenable: scope.alerts,
            builder: (context, _) {
              final alerts = scope.alerts.alerts;
              final now = scope.alerts.now;
              return AdminGroup(
                children: [
                  if (alerts.isEmpty)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                      leading: Icon(
                        Icons.check_circle_outline,
                        color: WingTokens.of(context).success,
                        size: 22,
                      ),
                      title: const Text('No current alerts'),
                    ),
                  for (final alert in alerts)
                    _alertRow(context, scope, alert, now),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _alertRow(
    BuildContext context,
    HealthAlertsScope scope,
    HealthAlert alert,
    DateTime now,
  ) {
    final silenced = healthAlertSilencedLabel(context, alert, now);
    final critical = alert.severity == HealthAlertSeverity.critical;
    final tokens = WingTokens.of(context);
    return AdminRow(
      key: ValueKey((alert.id, alert.occurrence)),
      title: alert.title,
      subtitle:
          '${silenced ?? (critical ? 'Critical' : 'Warning')} · ${healthAlertScopeLabel(alert)}',
      icon: switch (silenced) {
        null => Icons.warning_amber_rounded,
        _ when alert.acknowledged => Icons.check_circle_outline,
        _ => Icons.snooze_outlined,
      },
      iconColor: silenced != null
          ? Theme.of(context).colorScheme.onSurfaceVariant
          : critical
          ? tokens.danger
          : tokens.warning,
      onTap: () => showHealthAlertDetails(context, scope, alert),
    );
  }
}

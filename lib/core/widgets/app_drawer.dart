import '../services/connection_access.dart';
import 'drawer_versions.dart';
import 'health_alerts/health_alert_dialog.dart';
import 'health_alerts/health_alerts_scope.dart';
import '../services/versions_controller.dart';
import '../services/server_connection_status.dart';
import 'package:flutter/material.dart';
import '../theme/wing_theme.dart';
import 'playful_portrait.dart';
import 'wing_wordmark.dart';

enum AppDestination {
  chats('Chats', Icons.chat_bubble_outline),
  activity('Recents', Icons.history),
  bots('Bots', Icons.smart_toy_outlined),
  connections('Hermes instances', Icons.dns_outlined),
  settings('App settings', Icons.tune_outlined),
  administration('Hermes administration', Icons.manage_accounts_outlined),
  health('Hermes health', Icons.health_and_safety_outlined),
  analytics('Hermes analytics', Icons.bar_chart_outlined);

  const AppDestination(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Navigation only. Selecting a destination never writes backend configuration.
class AppDrawer extends StatelessWidget {
  const AppDrawer({
    super.key,
    required this.selected,
    required this.onSelected,
    this.access,
    this.versionsControllerFactory,
    this.connectionStatus,
    this.hasConnection = true,
  });

  final AppDestination selected;
  final ValueChanged<AppDestination> onSelected;
  final ConnectionAccess? access;
  final VersionsControllerFactory? versionsControllerFactory;
  final ServerConnectionStatus? connectionStatus;
  final bool hasConnection;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final largeText = MediaQuery.textScalerOf(context).scale(16) > 24;
    final alerts = HealthAlertsScope.maybeOf(context);
    return Drawer(
      backgroundColor: colors.surfaceContainerLow,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 20, 12, 4),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - 24,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                        child: Row(
                          children: [
                            PlayfulPortrait(size: largeText ? 64 : 96),
                            const SizedBox(width: 20),
                            Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: WingWordmark(
                                  width: largeText ? 176 : 144,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      for (final destination in AppDestination.values) ...[
                        if (destination == AppDestination.connections ||
                            destination == AppDestination.administration)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Divider(),
                          ),
                        _DrawerTile(
                          tileKey: ValueKey('nav-${destination.name}'),
                          label: destination.label,
                          icon: destination.icon,
                          largeText: largeText,
                          selected: selected == destination,
                          enabled:
                              hasConnection ||
                              destination == AppDestination.connections ||
                              destination == AppDestination.settings,
                          onTap: () {
                            Navigator.of(context).pop();
                            onSelected(destination);
                          },
                        ),
                        if (destination == AppDestination.health &&
                            alerts != null)
                          _DrawerTile(
                            tileKey: const ValueKey('nav-alerts'),
                            label: 'Alerts',
                            icon: Icons.warning_amber_rounded,
                            largeText: largeText,
                            onTap: () {
                              Navigator.of(context).pop();
                              showHealthAlerts(
                                context,
                                alerts,
                                includeSilenced: true,
                              );
                            },
                          ),
                      ],
                    ],
                  ),
                  DrawerVersions(
                    access: access,
                    connectionStatus: connectionStatus,
                    controllerFactory: versionsControllerFactory,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DrawerTile extends StatelessWidget {
  const _DrawerTile({
    required this.tileKey,
    required this.label,
    required this.icon,
    required this.largeText,
    required this.onTap,
    this.selected = false,
    this.enabled = true,
  });

  final Key tileKey;
  final String label;
  final IconData icon;
  final bool largeText, selected, enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => StudioButtonPress(
    child: ListTile(
      key: tileKey,
      shape: RoundedRectangleBorder(borderRadius: WingRadius.control),
      selected: selected,
      selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
      leading: largeText ? null : Icon(icon),
      title: largeText
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [Icon(icon), const SizedBox(height: 4), Text(label)],
            )
          : Text(label),
      enabled: enabled,
      onTap: onTap,
    ),
  );
}

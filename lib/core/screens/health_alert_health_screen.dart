import '../models/scheduled_task.dart';
import 'package:flutter/material.dart';
import '../models/profile_session_key.dart';
import '../models/health_alert.dart';
import '../services/scheduled_tasks_controller.dart';
import '../services/profile_workspace_controller.dart';
import '../widgets/server_connection_label.dart';
import '../widgets/wing_app_bar.dart';
import 'administration/administration_content.dart';
import 'administration/admin_connector_routes.dart';
import 'administration/admin_defaults_page.dart';
import 'administration/admin_providers_page.dart';
import 'administration/admin_scheduled_tasks_page.dart';

/// A reversible drill-down above the user's current route/editor. Borrows the
/// same workspace and Health owners; Back releases only this route's lease.
class HealthAlertHealthScreen extends StatefulWidget {
  const HealthAlertHealthScreen({
    super.key,
    required this.controller,
    required this.alert,
    required this.onOpenSession,
    required this.onConnections,
    this.onInvestigate,
  });
  final ProfileWorkspaceController controller;
  final HealthAlert alert;
  final Future<void> Function(ProfileSessionKey) onOpenSession;
  final VoidCallback onConnections;
  final ValueChanged<ScheduledTaskInvestigationRequest>? onInvestigate;
  @override
  State<HealthAlertHealthScreen> createState() =>
      _HealthAlertHealthScreenState();
}

class _HealthAlertHealthScreenState extends State<HealthAlertHealthScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.setRouteMounted(this, true);
  }

  @override
  void dispose() {
    widget.controller.setRouteMounted(this, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ServerConnectionScope(
    status: widget.controller.connectionStatus,
    icon: widget.controller.connection.icon,
    child: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => _destination(context),
    ),
  );

  Widget _destination(BuildContext context) {
    final alert = widget.alert;
    if (alert.profileName case final name?) {
      final profile = widget.controller.administration().profile(name);
      switch (alert.destination) {
        case 'MCP connectors':
          return profileConnectorIssuePage(profile, alert.connectorNames);
        case 'Access and connectors':
          return AdminProvidersPage(profile: profile);
        case 'Models and reasoning':
          return AdminDefaultsPage(profile: profile);
        case 'Skills and tools':
          return profileCapabilitiesPage(context, profile);
        case 'Scheduled tasks':
          return AdminScheduledTasksPage(
            profile: profile,
            onInvestigate: widget.onInvestigate == null
                ? null
                : (request) {
                    final root = ModalRoute.of(context);
                    Navigator.of(context).popUntil((route) => route == root);
                    widget.onInvestigate!(request);
                  },
            acquireController: () => ScheduledTasksController.acquire(
              profile,
              widget.controller.preferences,
            ),
            onOpenSession: widget.onOpenSession,
          );
      }
    }
    return Scaffold(
      appBar: WingAppBar(
        context: context,
        title: const Text('Hermes health'),
        contextRow: Align(
          alignment: Alignment.centerLeft,
          child: ServerConnectionLabel(
            label: widget.controller.connection.label,
            icon: widget.controller.connection.icon,
            suffix: widget.controller.current?.scope.profileName,
            status: widget.controller.connectionStatus,
          ),
        ),
      ),
      body: HermesHealthContent(
        controller: widget.controller,
        onOpenMenu: () => Navigator.of(context).maybePop(),
        onConnections: widget.onConnections,
        onOpenSession: widget.onOpenSession,
        onInvestigate: widget.onInvestigate,
      ),
    );
  }
}

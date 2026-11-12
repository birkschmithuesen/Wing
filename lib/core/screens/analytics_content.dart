import 'package:flutter/material.dart';

import '../services/administration_repository.dart';
import '../services/usage_analytics.dart';
import '../services/usage_analytics_session.dart';
import '../services/profile_workspace_controller.dart';
import '../widgets/workspace_picker.dart';
import 'administration/admin_usage_dashboard.dart';
import 'administration/admin_widgets.dart';

/// Analytics defaults to all discovered profiles; selection stays local to
/// analytics without changing the conversation workspace or starting checks.
class HermesAnalyticsContent extends StatefulWidget {
  const HermesAnalyticsContent({
    super.key,
    required this.controller,
    this.profileName,
    this.repository,
  });

  final ProfileWorkspaceController controller;
  final String? profileName;
  final AdministrationRepository? repository;

  @override
  State<HermesAnalyticsContent> createState() => _HermesAnalyticsContentState();
}

class _HermesAnalyticsContentState extends State<HermesAnalyticsContent> {
  late final _server = widget.repository ?? widget.controller.administration();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final name = widget.profileName;
      final profiles = widget.controller.discovery?.profiles ?? const [];
      if (profiles.isEmpty ||
          name != null && widget.controller.discovery?.named(name) == null) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: const [
            AdminNotice('Choose an available profile to view analytics.'),
          ],
        );
      }
      final names = name == null
          ? (profiles.map((profile) => profile.name).toList()..sort())
          : [name];
      return UsageDashboard(
        key: ValueKey((_server.connectionIdentity, names.join('\u0000'))),
        createSession: () => UsageAnalyticsSession(
          UsageAnalyticsReader(_server.usageAnalytics, names),
        ),
      );
    },
  );
}

/// Profile-scoped entry from administration search.
class AnalyticsPage extends StatelessWidget {
  const AnalyticsPage({super.key, required this.profile});
  final ProfileAdministration profile;

  @override
  Widget build(BuildContext context) => AdminPage(
    title: 'Hermes analytics',
    scope: profile.label,
    pickerMode: WorkspacePickerMode.profiles,
    child: UsageDashboard(
      key: ValueKey(profile.scope),
      createSession: () => UsageAnalyticsSession(
        UsageAnalyticsReader(profile.server.usageAnalytics, [profile.name]),
      ),
    ),
  );
}

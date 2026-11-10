import '../../widgets/studio_error.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import '../../widgets/health_alerts/health_alert_settings_entry.dart';
import '../../models/profile_session_key.dart';
import '../../models/health_finding.dart';
import 'package:flutter/material.dart';
import '../../services/administration_repository.dart';
import '../../services/administration_health.dart';
import '../../services/profile_workspace_controller.dart';
import '../../theme/wing_theme.dart';
import '../../widgets/profile_diagnostics_panel.dart';
import '../../services/profile_diagnostics_controller.dart';
import 'admin_widgets.dart';
import 'admin_runtime_health.dart';
import 'admin_host_health.dart';
import '../../services/host_resources_session.dart';
import 'admin_health_section.dart';
import 'admin_providers_page.dart';
import 'admin_connector_routes.dart';

Color administrationHealthColor(
  BuildContext context,
  AdministrationHealthStatus status,
) {
  final tokens = WingTokens.of(context);
  return switch (status) {
    AdministrationHealthStatus.healthy => tokens.success,
    AdministrationHealthStatus.warning => tokens.warning,
    AdministrationHealthStatus.failure => tokens.danger,
    AdministrationHealthStatus.unknown => Theme.of(context).colorScheme.outline,
  };
}

StudioErrorSeverity? _findingSeverity(AdministrationHealthFinding finding) {
  if (finding.readFailed ||
      finding.status == AdministrationHealthStatus.failure) {
    return StudioErrorSeverity.error;
  }
  return finding.status == AdministrationHealthStatus.warning
      ? StudioErrorSeverity.noResult
      : null;
}

class AdminHealthContent extends StatelessWidget {
  final AdministrationHealth health;
  final HostResourcesSession hostResources;
  final String? persistenceError;
  final ProfileAdministration? profile;
  final ProfileDiagnosticsController? Function() accessChecks;
  final VoidCallback? onConnections;
  final Future<void> Function() onRefresh;
  final Future<void> Function()? onCheckProfile;
  final Future<void> Function(
    Future<void> Function(ProfileAdministration profile) openEditor,
  )?
  onReviewAccess;
  final bool checkingProfile;
  final DateTime? profileCheckedAt;
  final Future<void> Function(String destination) onOpenDestination;
  final ProfileWorkspaceController? chatController;
  final Future<void> Function(ProfileSessionKey)? onOpenSession;
  const AdminHealthContent({
    super.key,
    required this.health,
    required this.hostResources,
    this.persistenceError,
    required this.profile,
    required this.onRefresh,
    required this.onOpenDestination,
    this.onCheckProfile,
    this.checkingProfile = false,
    this.profileCheckedAt,
    required this.accessChecks,
    required this.onReviewAccess,
    this.onConnections,
    this.chatController,
    this.onOpenSession,
  });

  @override
  Widget build(BuildContext context) {
    final findings = health.profileFindings;
    return StudioRefresh(
      available: true,
      label: 'Refreshing health',
      onRefresh: onRefresh,
      child: ListView(
        key: const PageStorageKey('administration-health-findings'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          if (persistenceError case final message?) AdminNotice.error(message),
          const HealthAlertSettingsEntry(),
          const HealthAlertsEntry(),
          AdminHostHealth(resources: hostResources),
          const SizedBox(height: 16),
          AdminRuntimeHealth(
            health: health,
            chatController: chatController,
            onOpenSession: onOpenSession,
          ),
          const SizedBox(height: 16),
          AdminHealthSectionHeading(
            title: 'Profile',
            checkedAt: profileCheckedAt,
            checking: checkingProfile,
            incomplete: health.profileCheckIncomplete,
            refresh: StudioButtonPress(
              child: IconButton(
                tooltip: 'Refresh profile status',
                onPressed: profile == null || checkingProfile
                    ? null
                    : onCheckProfile,
                icon: const Icon(Icons.refresh),
              ),
            ),
          ),
          if (profile == null)
            const AdminNotice('Select an available profile to view its health.')
          else ...[
            AdminGroup(
              children: [
                if (accessChecks() case final checks?
                    when onReviewAccess != null)
                  ProfileModelAccessRow(
                    controller: checks,
                    modelObservation: health.modelAccess,
                    refreshing: health.modelAccess.loading,
                    onRetry: () => onCheckProfile?.call(),
                    onManageConnections: onConnections,
                    onFixAccess: () => _fixAccess(context),
                  )
                else
                  const AdminNotice(
                    'Model access is unavailable for this profile.',
                  ),
                for (final (title, source, icon) in [
                  ('Tool setup', 'Tool setup', Icons.handyman_outlined),
                  (
                    'Connectors',
                    'Connector settings',
                    Icons.extension_outlined,
                  ),
                  ('Scheduled tasks', 'Scheduled tasks', Icons.schedule),
                ])
                  _row(
                    context,
                    title,
                    findings.where((f) => f.title == source).firstOrNull,
                    icon,
                    () => _detail(context, title, source),
                  ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: StudioButtonPress(
                child: IconButton(
                  tooltip: 'What’s checked?',
                  onPressed: () => showHealthCheckExplanation(context),
                  icon: const Icon(Icons.info_outline, size: 18),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String title,
    AdministrationHealthFinding? finding,
    IconData icon,
    VoidCallback onTap,
  ) {
    final severity = finding == null ? null : _findingSeverity(finding);
    final healthy = finding?.status == AdministrationHealthStatus.healthy;
    final tile = StudioButtonPress(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        minTileHeight: 64,
        minVerticalPadding: severity == null ? 8 : 12,
        leading: severity != null
            ? null
            : Icon(
                icon,
                color: finding == null
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : administrationHealthColor(context, finding.status),
                size: 22,
              ),
        title: severity != null
            ? StudioError(
                title,
                detail: finding!.detail,
                framed: false,
                severity: severity,
              )
            : Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: severity != null
            ? null
            : Text(
                finding?.detail ?? 'Not checked',
                style: Theme.of(context).textTheme.bodySmall,
              ),
        trailing: healthy ? null : const Icon(Icons.chevron_right, size: 20),
        onTap: healthy ? null : onTap,
      ),
    );
    return severity == null
        ? tile
        : StudioErrorFrame(severity: severity, child: tile);
  }

  Widget _observation(
    BuildContext context,
    AdministrationHealthFinding finding,
  ) {
    final severity = _findingSeverity(finding);
    return Padding(
      padding: severity == null ? const EdgeInsets.all(16) : EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (severity != null)
            StudioError(finding.detail, severity: severity)
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  switch (finding.status) {
                    AdministrationHealthStatus.healthy => Icons.info_outline,
                    AdministrationHealthStatus.unknown => Icons.help_outline,
                    _ => Icons.error_outline,
                  },
                  color: administrationHealthColor(context, finding.status),
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    finding.detail,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          if (finding.checkedAt case final at?) ...[
            const SizedBox(height: 8),
            Text(
              'Checked ${TimeOfDay.fromDateTime(at).format(context)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _detail(BuildContext context, String title, String source) =>
      adminPushProfile(
        context,
        profile!,
        (context, profile) => ListenableBuilder(
          listenable: health,
          builder: (context, _) {
            final finding = health.profileName == profile.name
                ? health.profileFindings
                      .where((f) => f.title == source)
                      .firstOrNull
                : null;
            return AdminPage(
              title: title,
              scope: profile.label,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (finding case final finding?)
                    if (_findingSeverity(finding) == null)
                      AdminGroup(children: [_observation(context, finding)])
                    else
                      _observation(context, finding)
                  else
                    const AdminNotice(
                      'Not checked. Return to Health and check this profile.',
                    ),
                  const SizedBox(height: 16),
                  if (finding?.destination case final destination?)
                    AdminGroup(
                      children: [
                        AdminRow(
                          title: switch (title) {
                            'Tool setup' => 'Skills and tools',
                            'Connectors' => 'Manage connectors',
                            _ => 'Manage scheduled tasks',
                          },
                          subtitle: 'Review configuration',
                          icon: Icons.tune,
                          onTap: () => title == 'Connectors'
                              ? adminPushProfile(
                                  context,
                                  profile,
                                  (context, profile) =>
                                      profileConnectorsPage(profile),
                                )
                              : onOpenDestination(destination),
                        ),
                      ],
                    ),
                ],
              ),
            );
          },
        ),
      );

  Future<void> _fixAccess(BuildContext context) =>
      onReviewAccess!((profile) async {
        await adminPushProfile(
          context,
          profile,
          (context, profile) => AdminProvidersPage(profile: profile),
        );
      });
}

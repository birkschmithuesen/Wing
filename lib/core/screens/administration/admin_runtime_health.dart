import '../../widgets/studio_error.dart';
import '../../services/administration_logs_session.dart';
import '../../models/profile_session_key.dart';
import 'package:flutter/material.dart';
import '../../models/administration_operation.dart';
import '../../services/doctor_finding_draft_session.dart';
import 'admin_logs_page.dart';
import '../../services/profile_workspace_controller.dart';
import '../../theme/wing_theme.dart';
import '../../services/administration_health.dart';
import 'admin_operations_page.dart';
import 'admin_widgets.dart';
import 'admin_health_section.dart';

/// Presents connection-owned observations retained across Health visits.
class AdminRuntimeHealth extends StatefulWidget {
  const AdminRuntimeHealth({
    super.key,
    required this.health,
    this.chatController,
    this.onOpenSession,
  });
  final AdministrationHealth health;
  final ProfileWorkspaceController? chatController;
  final Future<void> Function(ProfileSessionKey)? onOpenSession;
  @override
  State<AdminRuntimeHealth> createState() => _AdminRuntimeHealthState();
}

class _AdminRuntimeHealthState extends State<AdminRuntimeHealth> {
  AdministrationHealth get health => widget.health;
  Map<String, AdminDiagnosticObservation> get _observations =>
      health.diagnostics;

  @override
  void initState() {
    super.initState();
    health.addListener(_changed);
  }

  @override
  void didUpdateWidget(AdminRuntimeHealth oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.health != health) {
      oldWidget.health.removeListener(_changed);
      health.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    health.removeListener(_changed);
    super.dispose();
  }

  Future<void> _runAll() async {
    await health.runAllDiagnostics();
  }

  Future<void> _run(
    AdministrationDiagnostic kind,
    String scope, {
    required bool openResult,
  }) async {
    final controller = health;
    if (!await adminConfirm(
      context,
      kind.title,
      'Run this diagnostic on ${controller.server.connectionLabel}?',
      action: 'Run',

      actionIcon: Icons.play_arrow_outlined,
      destructive: false,
    )) {
      return;
    }
    if (!mounted) return;
    final started = await controller.startDiagnostic(kind);
    if (!mounted || !identical(controller, health)) return;
    if (started && openResult) await _result(kind, scope);
  }

  Future<void> _result(AdministrationDiagnostic kind, String scope) {
    final controller = health;
    final operation = controller.diagnosticOperation(kind.path)!;
    final chatController = widget.chatController;
    return adminPush(
      context,
      (context) => AdminActionPage(
        operation: operation,
        createDraftSession: chatController == null
            ? null
            : () => DoctorFindingDraftSession(operation, chatController),
        onOpenSession: widget.onOpenSession,
        onRunAgain: () async {
          Navigator.of(context).pop();
          await _run(kind, scope, openResult: true);
        },
        title: kind.title,
        scope: controller.diagnosticScope(kind.path) ?? scope,
      ),
    );
  }

  Widget _check(AdministrationDiagnostic kind, String scope) {
    final title = kind.title;
    final path = kind.path;
    final observation = _observations[path];
    final error = health.diagnosticStartError(path) ?? observation?.readError;
    final audit = observation?.audit;
    final diagnosis = observation?.diagnosis;
    final label = health.starting.contains(path)
        ? 'Starting…'
        : observation == null
        ? health.hasAttemptedDiagnostic(path)
              ? 'Start not confirmed'
              : 'Not run'
        : observation.readError != null
        ? 'Result refresh unavailable'
        : observation.summaryLabel;
    final warning =
        diagnosis?.hasIssues == true || audit?.hasVulnerabilities == true;
    final color =
        audit?.hasHighSeverity == true ||
            (audit == null && observation?.failed == true)
        ? WingTokens.of(context).danger
        : warning
        ? WingTokens.of(context).warning
        : null;
    return StudioButtonPress(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        minTileHeight: 64,
        minVerticalPadding: 8,
        leading: Icon(
          title == 'Doctor'
              ? Icons.medical_services_outlined
              : Icons.shield_outlined,
          color: color,
          size: 22,
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: error == null
            ? Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: color),
              )
            : StudioError(label, detail: error, framed: false),
        trailing: observation == null
            ? StudioButtonPress(
                child: TextButton(
                  onPressed: health.starting.contains(path)
                      ? null
                      : () => _run(kind, scope, openResult: false),
                  child: const Text('Run'),
                ),
              )
            : const Icon(Icons.chevron_right, size: 20),
        onTap: health.starting.contains(path)
            ? null
            : () => observation == null
                  ? _run(kind, scope, openResult: true)
                  : _result(kind, scope),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = health.server.connectionLabel;
    final canRunAll = health.canRunAllDiagnostics;
    final running = health.serverChecking;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdminHealthSectionHeading(
          title: 'Server',
          checkedAt: health.serverCheckIncomplete
              ? health.serverAttemptedAt
              : health.serverCheckedAt,
          checking: running,
          incomplete: health.serverCheckIncomplete,
          attempted: health.serverAttemptedAt != null,
          refresh: StudioButtonPress(
            child: IconButton(
              tooltip: 'Run all diagnostics',
              onPressed: canRunAll ? _runAll : null,
              icon: const Icon(Icons.refresh),
            ),
          ),
        ),
        AdminGroup(
          children: [
            _check(AdministrationDiagnostic.doctor, scope),
            _check(AdministrationDiagnostic.securityAudit, scope),
            AdminRow(
              title: 'Logs',
              subtitle: 'Recent server activity',
              icon: Icons.subject,
              onTap: () {
                final server = health.server;
                adminPush(
                  context,
                  (context) => AdminLogsPage(
                    createSession: () => AdministrationLogsSession(server),
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}

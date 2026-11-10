import '../../widgets/selection_viewport.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import '../../models/profile_session_key.dart';
import '../../models/administration_operation.dart';
import '../../services/administration_operation_session.dart';
import '../../services/doctor_finding_draft_session.dart';
import '../../theme/wing_theme.dart';
import '../../widgets/studio_error.dart';
import 'package:flutter/material.dart';
import 'admin_widgets.dart';
import 'admin_doctor_diagnosis.dart';
import 'admin_security_diagnosis.dart';

class AdminActionPage extends StatefulWidget {
  final Future<void> Function()? onRunAgain;
  final AdministrationOperationSession operation;
  final String title;
  final String scope;
  final DoctorFindingDraftSession Function()? createDraftSession;
  final Future<void> Function(ProfileSessionKey)? onOpenSession;
  const AdminActionPage({
    super.key,
    required this.operation,
    required this.title,
    required this.scope,

    this.onRunAgain,
    this.createDraftSession,
    this.onOpenSession,
  });
  @override
  State<AdminActionPage> createState() => _AdminActionPageState();
}

class _AdminActionPageState extends State<AdminActionPage> {
  DoctorFindingDraftSession? _draft;
  final _draftError = GlobalKey();
  @override
  void initState() {
    super.initState();
    widget.operation.addListener(_changed);
    _draft = widget.createDraftSession?.call();
    _draft?.addListener(_draftChanged);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(AdminActionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.operation, widget.operation)) {
      oldWidget.operation.removeListener(_changed);
      widget.operation.addListener(_changed);
      _draft?.removeListener(_draftChanged);
      _draft?.dispose();
      _draft = widget.createDraftSession?.call();
      _draft?.addListener(_draftChanged);
    }
  }

  void _draftChanged() => _changed();

  Future<void> _askHermes(int index) async {
    final navigate = widget.onOpenSession;
    final draft = _draft;
    if (navigate == null || draft == null) return;
    bool isRouteCurrent() =>
        mounted && ModalRoute.of(context)?.isCurrent != false;
    await draft.openFinding(
      index,
      navigate: navigate,
      isRouteCurrent: isRouteCurrent,
    );
    if (!mounted || !identical(_draft, draft) || draft.failedFinding == null) {
      return;
    }
    if (ModalRoute.of(context)?.isCurrent != false) {
      revealAdminNotice(context, _draftError);
    }
  }

  @override
  void dispose() {
    widget.operation.removeListener(_changed);
    _draft?.removeListener(_draftChanged);
    _draft?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.operation.state;
    final observation = state.observation;
    final isAudit = observation.securityAudit;
    final isDiagnostic = observation.diagnostic;
    final audit = observation.audit;
    final diagnosis = observation.diagnosis;
    final loading = state.loading;
    final openingFinding = _draft?.openingFinding != null;
    final draftNotice = _draft?.notice;
    final failedFinding = _draft?.failedFinding;
    final error = observation.readError;
    final checkedAt = observation.checkedAt;
    final hasSummary = diagnosis != null || audit != null;
    return AdminPage(
      title: widget.title,
      scope: widget.scope,
      actions: [
        if (isDiagnostic)
          StudioButtonPress(
            child: IconButton(
              tooltip: 'Run ${widget.title} again',
              onPressed: state.canRunAgain && _draft?.openingFinding == null
                  ? widget.onRunAgain
                  : null,
              icon: const Icon(Icons.play_arrow),
            ),
          ),
        if (!isDiagnostic || !observation.terminal)
          StudioButtonPress(
            child: IconButton(
              tooltip: 'Refresh result',
              onPressed: state.canRefresh ? widget.operation.refresh : null,
              icon: const Icon(Icons.refresh),
            ),
          ),
      ],
      child: StudioPageLoading(
        active: openingFinding,
        label: 'Opening chat',
        child: StudioLoadingRegion(
          available: hasSummary || checkedAt != null,
          busy: loading,
          label: 'Checking operation',
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (error != null) AdminNotice.error(error),
              if (draftNotice != null &&
                  (failedFinding == null || diagnosis == null))
                if (failedFinding != null)
                  AdminNotice.error(draftNotice, key: _draftError)
                else
                  AdminNotice(draftNotice),
              if (observation.classification ==
                  AdministrationOperationOutcome.failed)
                const StudioError('Failed')
              else if (!hasSummary && !(checkedAt == null && loading))
                Text(
                  observation.auditSummaryUnavailable
                      ? 'Audit summary unavailable'
                      : observation.outcome,
                ),
              if (!hasSummary &&
                  observation.classification ==
                      AdministrationOperationOutcome.completed) ...[
                const SizedBox(height: 8),
                Text(
                  'Review the findings below.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (checkedAt != null && !hasSummary) ...[
                const SizedBox(height: 8),
                Text(
                  '${observation.terminal ? 'Checked' : 'Last updated'} ${TimeOfDay.fromDateTime(checkedAt).format(context)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (diagnosis != null) ...[
                AdminDoctorDiagnosis(
                  diagnosis: diagnosis,
                  checkedAt: checkedAt,
                  openingFinding: _draft?.openingFinding,
                  findingError: draftNotice == null || failedFinding == null
                      ? null
                      : (
                          index: failedFinding,
                          notice: AdminNotice.error(
                            draftNotice,
                            key: _draftError,
                          ),
                        ),
                  onAskHermes:
                      _draft?.canAsk == true && widget.onOpenSession != null
                      ? _askHermes
                      : null,
                ),
                const SizedBox(height: WingSpacing.lg),
              ],
              if (audit != null) ...[
                AdminSecurityDiagnosis(report: audit, checkedAt: checkedAt),
                const SizedBox(height: WingSpacing.lg),
              ],
              const SizedBox(height: 12),
              AdminGroup(
                children: [
                  ExpansionTile(
                    key: ValueKey(hasSummary),
                    shape: const Border(),
                    collapsedShape: const Border(),
                    initiallyExpanded: !hasSummary && !isAudit,
                    title: const Text('Diagnostic output'),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: viewportSelection(
                          SelectableText(
                            observation.lines.isEmpty
                                ? 'No output yet.'
                                : observation.lines.join('\n'),
                            style: WingTokens.of(context).typography.mono,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (!isDiagnostic &&
                  widget.onRunAgain != null &&
                  state.canRunAgain) ...[
                const SizedBox(height: 16),
                StudioButtonPress(
                  child: OutlinedButton.icon(
                    onPressed: widget.onRunAgain,
                    icon: const Icon(Icons.play_arrow),
                    label: Text('Run ${widget.title} again'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

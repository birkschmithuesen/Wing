/// Immutable presentation of connection-owned profile administration.
class ProfilesManagementRow {
  const ProfilesManagementRow({
    required this.name,
    required this.title,
    required this.subtitle,
    required this.canClone,
    required this.canRename,
    required this.canDelete,
  });
  final String name, title, subtitle;
  final bool canClone, canRename, canDelete;
}

enum ProfilesManagementOutcomeKind {
  confirmed,
  confirmedRefreshFailed,
  deletedSettlementPending,
  notSent,
  uncertain,
  rejected,
}

class ProfilesManagementOutcome {
  const ProfilesManagementOutcome({
    required this.sequence,
    required this.kind,
    required this.target,
    required this.message,
    this.manualGuidance,
  });
  final int sequence;
  final ProfilesManagementOutcomeKind kind;
  final String target, message;
  final String? manualGuidance;

  bool get announcesSuccess =>
      kind == ProfilesManagementOutcomeKind.confirmed ||
      kind == ProfilesManagementOutcomeKind.confirmedRefreshFailed;

  ProfilesManagementOutcome get refreshFailed => ProfilesManagementOutcome(
    sequence: sequence,
    kind: kind == ProfilesManagementOutcomeKind.confirmed
        ? ProfilesManagementOutcomeKind.confirmedRefreshFailed
        : kind,
    target: target,
    message: message,
    manualGuidance: manualGuidance,
  );
}

class ProfilesManagementDraft {
  const ProfilesManagementDraft({
    required this.title,
    required this.initialName,
    required this.help,
    required this.needsName,
    required this.canContinue,
    required this.canSubmit,
    required this.canCancel,
    required this.needsConfirmation,
    required this.confirmationTitle,
    required this.confirmationDetail,
    required this.confirmationAction,
    this.validationError,
  });
  final String title, initialName, help;
  final bool needsName, canContinue, canSubmit, canCancel, needsConfirmation;
  final String confirmationTitle, confirmationDetail, confirmationAction;
  final String? validationError;
}

class ProfilesManagementState {
  ProfilesManagementState({
    required this.hasObservation,
    required this.scope,
    required List<ProfilesManagementRow> rows,
    required this.loading,
    required this.busy,
    required this.canCreate,
    required this.canOpen,
    required this.canRefresh,
    required List<ProfilesManagementOutcome> settlements,
    this.draft,
    this.error,
    this.outcome,
  }) : rows = List.unmodifiable(rows),
       settlements = List.unmodifiable(settlements);
  final String scope;
  final List<ProfilesManagementRow> rows;
  final List<ProfilesManagementOutcome> settlements;
  final bool loading, busy, canCreate, canOpen, canRefresh;
  final bool hasObservation;
  final ProfilesManagementDraft? draft;
  final String? error;
  final ProfilesManagementOutcome? outcome;
}

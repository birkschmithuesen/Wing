/// The one current device format is an exact, nonempty saved connection ID.
class WorkspaceEntryCodec {
  static const storageKey = 'last_connection_id';

  static String? connectionId(Object? raw) =>
      raw is String && raw.isNotEmpty ? raw : null;
}

enum WorkspaceEntryValidity { absent, valid, invalid, unverified }

enum WorkspaceEntrySaveOutcome {
  unchanged,
  saved,
  failedRestored,
  failedUnverified,
  retired,
}

class WorkspaceEntryFact {
  const WorkspaceEntryFact({
    required this.validity,
    required this.confirmedId,
    required this.requestedId,
    required this.busy,
    required this.error,
  });

  final WorkspaceEntryValidity validity;
  final String? confirmedId;
  final String? requestedId;
  final bool busy;
  final String? error;

  @override
  bool operator ==(Object other) =>
      other is WorkspaceEntryFact &&
      other.validity == validity &&
      other.confirmedId == confirmedId &&
      other.requestedId == requestedId &&
      other.busy == busy &&
      other.error == error;

  @override
  int get hashCode =>
      Object.hash(validity, confirmedId, requestedId, busy, error);
}

class WorkspaceEntrySettlement {
  const WorkspaceEntrySettlement(this.connectionId, this.outcome);
  final String connectionId;
  final WorkspaceEntrySaveOutcome outcome;
}

class WorkspaceEntryAdmission {
  const WorkspaceEntryAdmission({
    required this.queuedBehindEntry,
    required this.settled,
  });
  final bool queuedBehindEntry;
  final Future<WorkspaceEntrySettlement> settled;
}

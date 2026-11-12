part of 'profile_workspace_controller.dart';

/// Passive rendering facts. The workspace owns eligibility and asynchronous
/// command failure; presentation invokes only the supplied callbacks.
class DeletedDraftCleanupPresentation {
  const DeletedDraftCleanupPresentation.empty()
    : summary = null,
      entries = const [];

  DeletedDraftCleanupPresentation({
    required this.summary,
    required Iterable<DeletedDraftCleanupEntry> entries,
  }) : entries = List.unmodifiable(entries);

  final String? summary;
  final List<DeletedDraftCleanupEntry> entries;
}

class DeletedDraftCleanupEntry {
  DeletedDraftCleanupEntry({
    required this.key,
    required this.title,
    required this.profile,
    required this.identification,
    required this.detail,
    required this.error,
    required this.busy,
    required Iterable<DeletedDraftCleanupAction> actions,
  }) : actions = List.unmodifiable(actions);

  final ProfileSessionKey key;
  final String title;
  final String profile;
  final String identification;
  final String detail;
  final String? error;
  final bool busy;
  final List<DeletedDraftCleanupAction> actions;
}

class DeletedDraftCleanupAction {
  const DeletedDraftCleanupAction({required this.label, required this.invoke});
  final String label;
  final VoidCallback invoke;
}

typedef _DeletedDraftCleanupPublicationInput = ({
  DeletedDraftCleanupReceipt receipt,
  ProfileSessionKey key,
  String? title,
  SessionPresence? presence,
  String? error,
  bool busy,
  bool confirmed,
});

extension ProfileDeletedDraftRecovery on ProfileWorkspaceController {
  ValueListenable<DeletedDraftCleanupPresentation>
  get deletedDraftCleanupPresentation => _deletedDraftCleanupPresentation;

  void _publishDeletedDraftCleanupPresentation() {
    if (_closed) return;
    final snapshot = _deletedDrafts.receipts;
    var unchanged = true;
    var activeCount = 0;
    for (final receipt in snapshot) {
      if (receipt.phase == DeletedDraftCleanupPhase.completed) continue;
      activeCount++;
      final previous =
          _publishedDeletedDraftInputs[(receipt.profile, receipt.session)];
      if (previous == null || !identical(previous.receipt, receipt)) {
        unchanged = false;
        break;
      }
      final resource = _resources[previous.key.workspace];
      if (previous.title != resource?._chats[receipt.session]?.title ||
          previous.presence != _deletedDraftPresence[previous.key] ||
          previous.error != _deletedDraftRecoveryErrors[previous.key] ||
          previous.busy !=
              (resource?._mutatingSessions.contains(receipt.session) == true) ||
          previous.confirmed !=
              (receipt.confirmed ||
                  resource?._deletedSessions.contains(receipt.session) ==
                      true)) {
        unchanged = false;
        break;
      }
    }
    if (unchanged && activeCount == _publishedDeletedDraftInputs.length) return;
    final receipts =
        snapshot
            .where((r) => r.phase != DeletedDraftCleanupPhase.completed)
            .toList()
          ..sort((a, b) {
            final profile = a.profile.compareTo(b.profile);
            return profile != 0 ? profile : a.session.compareTo(b.session);
          });
    final active = {
      for (final receipt in receipts)
        ProfileSessionKey(
          WorkspaceScope(
            connectionId: connection.id,
            connectionIdentity: connectionIdentity,
            profileName: receipt.profile,
          ),
          receipt.session,
        ),
    };
    _deletedDraftPresence.removeWhere((key, _) => !active.contains(key));
    _deletedDraftRecoveryErrors.removeWhere((key, _) => !active.contains(key));
    final entries = <DeletedDraftCleanupEntry>[];
    final inputs = <(String, String), _DeletedDraftCleanupPublicationInput>{};
    for (final receipt in receipts) {
      final scope = WorkspaceScope(
        connectionId: connection.id,
        connectionIdentity: connectionIdentity,
        profileName: receipt.profile,
      );
      final key = ProfileSessionKey(scope, receipt.session);
      final resource = _resources[scope];
      final busy =
          resource?._mutatingSessions.contains(receipt.session) == true;
      final confirmed =
          receipt.confirmed ||
          resource?._deletedSessions.contains(receipt.session) == true;
      final presence = _deletedDraftPresence[key];
      final title = resource?._chats[receipt.session]?.title;
      inputs[(receipt.profile, receipt.session)] = (
        receipt: receipt,
        key: key,
        title: title,
        presence: presence,
        error: _deletedDraftRecoveryErrors[key],
        busy: busy,
        confirmed: confirmed,
      );
      final actions = <DeletedDraftCleanupAction>[];
      if (!busy) {
        if (confirmed) {
          actions.add(
            DeletedDraftCleanupAction(
              label: 'Retry cleanup',
              invoke: () => _invokeDeletedDraftAction(
                key,
                receipt,
                () => retryDeletedDraftCleanup(key),
              ),
            ),
          );
        } else {
          actions.add(
            DeletedDraftCleanupAction(
              label: 'Check chat',
              invoke: () => _invokeDeletedDraftAction(
                key,
                receipt,
                () => inspectDeletedDraftCleanup(key),
              ),
            ),
          );
          if (presence == SessionPresence.present) {
            actions.add(
              DeletedDraftCleanupAction(
                label: 'Keep chat',
                invoke: () => _invokeDeletedDraftAction(
                  key,
                  receipt,
                  () => keepPreparedSession(key),
                ),
              ),
            );
          }
        }
      }
      entries.add(
        DeletedDraftCleanupEntry(
          key: key,
          title: title == null || title.isEmpty
              ? 'Chat ${receipt.session.substring(0, math.min(12, receipt.session.length))}'
              : title,
          profile: receipt.profile,
          identification: 'Chat ${receipt.session}',
          detail: confirmed
              ? 'Chat deleted. Local draft cleanup is pending.'
              : presence == SessionPresence.present
              ? 'This chat still exists. Keep it to restore access and retained work.'
              : 'Deletion is unconfirmed. Local work is kept until the chat can be checked.',
          error: _deletedDraftRecoveryErrors[key],
          busy: busy,
          actions: actions,
        ),
      );
    }
    // Publish inputs first: a synchronous listener may request another update.
    // Exact receipt identity ensures replaced receipts refresh captured actions.
    _publishedDeletedDraftInputs = Map.unmodifiable(inputs);
    _deletedDraftCleanupPresentation.value = entries.isEmpty
        ? const DeletedDraftCleanupPresentation.empty()
        : DeletedDraftCleanupPresentation(
            summary:
                '${entries.length} ${entries.length == 1 ? 'chat needs' : 'chats need'} recovery',
            entries: entries,
          );
  }

  void _invokeDeletedDraftAction(
    ProfileSessionKey key,
    DeletedDraftCleanupReceipt captured,
    Future<void> Function() operation,
  ) {
    if (_closed) return;
    unawaited(() async {
      try {
        if (!identical(
          _deletedDrafts.receipt(key.workspace.profileName, key.sessionId),
          captured,
        )) {
          return;
        }
        await operation();
      } catch (_) {
        if (_closed) return;
        final confirmed =
            captured.confirmed ||
            _resources[key.workspace]?._deletedSessions.contains(
                  key.sessionId,
                ) ==
                true;
        _deletedDraftRecoveryErrors[key] = confirmed
            ? 'Local cleanup could not finish. Retry cleans only local copies.'
            : 'Recovery could not finish. Local work is kept; check the chat again.';
        _changed(saveReading: false);
      }
    }());
  }

  ProfileWorkspaceData _deletedDraftRecoveryOwner(ProfileSessionKey key) {
    if (_closed || !owns(key)) {
      throw StateError('This workspace is no longer available');
    }
    if (_deletedDrafts.receipt(key.workspace.profileName, key.sessionId) ==
        null) {
      throw StateError('This recovery decision is no longer available');
    }
    final resource = _resource(key.workspace.profileName);
    if (resource.scope != key.workspace ||
        resource._mutatingSessions.contains(key.sessionId)) {
      throw StateError('Chat recovery is already in progress');
    }
    return resource;
  }

  bool _deletedDraftRecoveryCurrent(
    ProfileWorkspaceData resource,
    ProfileSessionKey key,
    DeletedDraftCleanupReceipt captured,
  ) =>
      !_closed &&
      identical(_resources[key.workspace], resource) &&
      identical(
        _deletedDrafts.receipt(key.workspace.profileName, key.sessionId),
        captured,
      );

  /// Read-only verification; an absence result may resume local cleanup, never
  /// replay DELETE. A present result offers the explicit keep decision.
  Future<void> inspectDeletedDraftCleanup(ProfileSessionKey key) async {
    final resource = _deletedDraftRecoveryOwner(key);
    final captured = _deletedDrafts.receipt(
      key.workspace.profileName,
      key.sessionId,
    )!;
    if (captured.confirmed ||
        resource._deletedSessions.contains(key.sessionId)) {
      throw StateError('The deletion is confirmed; only local cleanup remains');
    }
    resource._mutatingSessions.add(key.sessionId);
    _deletedDraftRecoveryErrors.remove(key);
    _changed(saveReading: false);
    try {
      await _reconcileDeletedDraft(resource, key.sessionId);
      if (!_deletedDraftRecoveryCurrent(resource, key, captured)) return;
      if (resource._deletedSessions.contains(key.sessionId)) {
        await _cleanupDeletedDraft(resource, key.sessionId);
      }
    } finally {
      resource._mutatingSessions.remove(key.sessionId);
      _changed();
    }
  }

  Future<void> retryDeletedDraftCleanup(ProfileSessionKey key) async {
    final resource = _deletedDraftRecoveryOwner(key);
    if (!resource._deletedSessions.contains(key.sessionId)) {
      throw StateError('Deletion is unconfirmed. Check the chat first.');
    }
    resource._mutatingSessions.add(key.sessionId);
    _deletedDraftRecoveryErrors.remove(key);
    _changed(saveReading: false);
    try {
      await _cleanupDeletedDraft(resource, key.sessionId);
    } finally {
      resource._mutatingSessions.remove(key.sessionId);
      _changed();
    }
  }

  /// Explicit recovery of an existing chat. Fresh owned presence is checked
  /// again at invocation; a stale rendered Keep callback grants no authority.
  Future<void> keepPreparedSession(ProfileSessionKey key) async {
    final resource = _deletedDraftRecoveryOwner(key);
    final captured = _deletedDrafts.receipt(
      key.workspace.profileName,
      key.sessionId,
    )!;
    if (captured.confirmed ||
        resource._deletedSessions.contains(key.sessionId)) {
      throw StateError('A confirmed deletion cannot be restored');
    }
    resource._mutatingSessions.add(key.sessionId);
    _deletedDraftRecoveryErrors.remove(key);
    _changed(saveReading: false);
    try {
      final presence = await resource.gateway.verifyDeletedSession(
        key.sessionId,
      );
      if (!_deletedDraftRecoveryCurrent(resource, key, captured)) return;
      _deletedDraftPresence[key] = presence;
      if (presence != SessionPresence.present) {
        throw StateError(
          'The chat could not be verified as present. Work was kept.',
        );
      }
      await _deletedDrafts.retirePrepared(captured);
      if (_closed) return;
      resource._quarantinedSessions.remove(key.sessionId);
      _deletedDraftPresence.remove(key);
      _deletedDraftRecoveryErrors.remove(key);
      // Kept drafts/queues remain untouched. Explicit opening owns their later
      // hydration and paused recovery; this choice dispatches no prompt/resume.
    } finally {
      resource._mutatingSessions.remove(key.sessionId);
      _changed();
    }
  }
}

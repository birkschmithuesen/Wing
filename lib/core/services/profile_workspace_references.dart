part of 'profile_workspace_controller.dart';

extension _WorkspaceReferences on ProfileWorkspaceController {
  void _observeReferenceWorkspace(
    ProfileChat chat,
    Map info, {
    bool replace = false,
  }) {
    if (replace || info.containsKey('cwd')) {
      final cwd = info['cwd'];
      chat._cwd = cwd is String && cwd.startsWith('/') ? cwd : null;
    }
    // A changed cwd with no namespace (stock lazy info) retires the previous
    // local claim. Null cwd also clears it; never borrow a stale host workspace.
    if (replace ||
        info.containsKey('cwd') ||
        info.containsKey('terminal_backend')) {
      final backend = info['terminal_backend'];
      chat._terminalBackend = backend is String ? backend : null;
    }
  }

  ComposerReferencePreparation _referencePreparation(
    ProfileChat chat,
    void Function() requireCurrent,
  ) {
    final gateway = _owned(chat).gateway;
    return ComposerReferencePreparation(
      ComposerReferenceRepository(
        read: (endpoint, query) async {
          requireCurrent();
          final result = await gateway.read(endpoint, query);
          requireCurrent();
          return result;
        },
        call: (method, params) async {
          requireCurrent();
          final result = await gateway.call(method, params);
          requireCurrent();
          return result;
        },
      ),
    );
  }

  Future<MentionCompletion> _completeMention(
    ProfileChat chat,
    MentionQuery query, {
    required BotsSession bots,
    required bool Function() canRead,
    String? directory,
  }) async {
    final resource = _owned(chat), runtime = chat.runtime.runtimeId;
    void requireCurrent() {
      if (_closed ||
          !canRead() ||
          !identical(_owned(chat), resource) ||
          chat.runtime.runtimeId != runtime) {
        throw StateError('The reference completion owner changed.');
      }
    }

    final workspace = chat.key.workspace;
    WorkspaceScope scope(String profile) => WorkspaceScope(
      connectionId: workspace.connectionId,
      connectionIdentity: workspace.connectionIdentity,
      profileName: profile,
    );
    final cwd = await _referenceCwd(chat, requireCurrent);
    final completion = await _referencePreparation(chat, requireCurrent)
        .complete(
          query,
          cwd: cwd,
          directory: directory,
          currentAgent: chat.key.workspace.profileName,
          selected: chat.composer.observation.references,
          labelsForAgents: (profiles) async {
            final identities = await bots.identitiesForProfiles(
              profiles.map(scope),
              canRead: () =>
                  !_closed &&
                  canRead() &&
                  identical(_owned(chat), resource) &&
                  chat.runtime.runtimeId == runtime,
            );
            requireCurrent();
            return {
              for (final entry in identities.entries)
                entry.key.profileName: entry.value.title,
            };
          },
          requireCurrent: requireCurrent,
        );
    final profiles = completion.items
        .where((item) => item.reference.kind == ComposerReferenceKind.agent)
        .map((item) => scope(item.reference.target));
    if (profiles.isEmpty) return completion;
    final appearances = await bots.appearancesForProfiles(
      profiles,
      canRead: () =>
          !_closed &&
          canRead() &&
          identical(_owned(chat), resource) &&
          chat.runtime.runtimeId == runtime,
    );
    requireCurrent();
    return MentionCompletion(
      query: completion.query,
      directory: completion.directory,
      parent: completion.parent,
      warning: completion.warning,
      items: [
        for (final item in completion.items)
          MentionCandidate(
            reference: item.reference,
            label: item.label,
            detail: item.detail,
            appearance: item.reference.kind == ComposerReferenceKind.agent
                ? appearances[scope(item.reference.target)]
                : null,
          ),
      ],
    );
  }

  Future<String?> _referenceCwd(
    ProfileChat chat,
    void Function() requireCurrent,
  ) async {
    // Lazy sessions may not have a terminal namespace yet. Host browsing starts
    // at the managed files root until the session positively reports local.
    if (chat._terminalBackend != 'local') return null;
    if (chat._cwd != null) return chat._cwd;
    requireCurrent();
    final row = await _owned(
      chat,
    ).gateway.read('sessions/${Uri.encodeComponent(chat.key.sessionId)}');
    requireCurrent();
    final cwd = row['cwd'];
    if (cwd is! String || cwd.isEmpty) return null;
    ServerReferencePath.admit(cwd);
    chat._cwd = cwd;
    return cwd;
  }

  Future<String> _prepareReferences(
    ProfileChat chat,
    String text, {
    Iterable<ComposerReference> selected = const [],
  }) async {
    if (!RegExp(r'(?<![\w/])@(?:file:|folder:|[a-z0-9])').hasMatch(text)) {
      return text;
    }
    final resource = _commandOwner(chat), runtime = chat.runtime.runtimeId;
    void requireCurrent() {
      if (!identical(_commandOwner(chat), resource) ||
          chat.runtime.runtimeId != runtime) {
        throw StateError(
          'The conversation changed while preparing references.',
        );
      }
    }

    final hasPaths = composerReferenceSpans(
      text,
      selected: selected,
    ).any((span) => span.reference.kind != ComposerReferenceKind.agent);
    String? cwd;
    int? limit = chat.context?.max;
    if (hasPaths) {
      final needsCwd = composerReferenceSpans(text, selected: selected).any(
        (span) =>
            span.reference.kind != ComposerReferenceKind.agent &&
            !ServerReferencePath.pathContext.isAbsolute(span.reference.target),
      );
      if (needsCwd) cwd = await _referenceCwd(chat, requireCurrent);
      if (limit == null) {
        final usage = await resource.gateway.call('session.context_breakdown', {
          'session_id': runtime,
        });
        requireCurrent();
        limit = ContextOccupancy.fromJson(usage)?.max;
        if (limit == null) {
          final metadata = await resource.gateway.read('model/info');
          requireCurrent();
          final value = metadata['effective_context_length'];
          if (metadata['model'] == chat.model &&
              metadata['provider'] == chat.provider &&
              value is int &&
              value > 0) {
            limit = value;
          }
        }
      }
    }
    return _referencePreparation(chat, requireCurrent).prepare(
      text,
      selected: selected,
      cwd: cwd,
      contextLimit: limit,
      requireCurrent: requireCurrent,
    );
  }

  Iterable<ComposerReference> _savedReferences(Map<String, dynamic> row) =>
      (PreparedComposerMessage.fromContent(
                row['display_content'] ?? row['content'],
              ) ??
              PreparedComposerMessage.parse(steeringMessageText(row) ?? ''))
          ?.references ??
      const [];
}

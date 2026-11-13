part of 'profile_workspace_controller.dart';

const _recentPreviewMessageLimit = 6;

/// One globally ordered list, with distinct chat and room navigation targets.
class WorkspaceRecentItem {
  WorkspaceRecentItem.chat(ProfileRecentChat value, this.bot)
    : chat = value,
      group = null,
      unread = value.unread,
      messagePreview = value.messagePreview;
  WorkspaceRecentItem.group(BotGroup value, this.unread)
    : group = value,
      chat = null,
      bot = null,
      messagePreview = recentMessageExcerpt(value.preview);
  final ProfileRecentChat? chat;
  final BotRecord? bot;
  final BotGroup? group;
  final bool unread;
  final String messagePreview;
  double get lastMessage =>
      chat?.lastActive ??
      (group?.lastMessageAt?.millisecondsSinceEpoch ?? 0) / 1000;
  RecentConversationEntry get conversation => group == null
      ? RecentConversationEntry.chat(
          key: chat!.key,
          title: chat!.title,
          unread: unread,
        )
      : RecentConversationEntry.group(group!, unread: unread);
  String get identity =>
      group?.key ??
      '${chat!.key.workspace.connectionIdentity}/${chat!.key.workspace.profileName}/${chat!.key.sessionId}';
}

/// One membership/order projection for the destination and the pinch catalog.
List<WorkspaceRecentItem> workspaceRecentItems(
  ProfileWorkspaceController controller,
  BotsSession bots, {
  DateTime? now,
}) {
  final cutoff = (now ?? DateTime.now()).millisecondsSinceEpoch / 1000 - 86400;
  final result =
      [
        for (final chat in controller.recentChats(now: now))
          WorkspaceRecentItem.chat(chat, bots.cachedAppearance(chat.key)),
        for (final group in bots.observedGroups)
          if (group.working ||
              group.blocked ||
              (group.lastMessageAt?.millisecondsSinceEpoch ?? 0) / 1000 >=
                  cutoff)
            WorkspaceRecentItem.group(group, bots.groupReads.unread(group)),
      ]..sort((a, b) {
        final time = b.lastMessage.compareTo(a.lastMessage);
        return time != 0 ? time : a.identity.compareTo(b.identity);
      });
  return List.unmodifiable(result);
}

final class _WorkspaceRecentConversationSource
    implements RecentConversationSource {
  _WorkspaceRecentConversationSource(
    this.controller,
    this.recents,
    this.onOpenGroup, {
    required this.routeOrigin,
    required this.onOpenChat,
  }) {
    if (!identical(controller, recents.workspaceOwner)) {
      throw ArgumentError('Recents belongs to another workspace');
    }
  }
  final RecentConversationKey? routeOrigin;
  final Future<void> Function(RecentConversationKey)? onOpenChat;
  final Future<void> Function(BotGroup) onOpenGroup;
  BotGroup? _group(RecentConversationKey key) =>
      key.group == null ? null : bots.groupForKey(key.group!);
  final WorkspaceRecentsCache recents;
  BotsSession get bots => recents.bots;
  BotAvatarBorrower? _preparedAvatars;
  int _avatarPreparation = 0;
  bool _presentationVisible = false;
  final ProfileWorkspaceController controller;
  @override
  RecentConversationSnapshots get snapshots => recents.snapshots;

  @override
  Future<RecentConversationCatalog> loadRecents({required bool refresh}) async {
    setVisible(true);
    await recents.refresh(force: refresh);
    if (!current) throw StateError('Workspace is no longer available');
    return catalog;
  }

  @override
  RecentConversationCatalog get catalog => recents.catalog;

  @override
  void setVisible(bool visible) {
    recents.setVisible(this, visible);
    _presentationVisible = visible;
    if (!visible) {
      _avatarPreparation++;
      _preparedAvatars?.replaceDemand({});
    }
  }

  @override
  bool get current =>
      recents.current &&
      !controller._closed &&
      (routeOrigin == null || _group(routeOrigin!) != null);
  @override
  bool opensRoute(RecentConversationKey key) =>
      routeOrigin != null || key.group != null;
  @override
  RecentConversationKey? get selected => routeOrigin ?? _selectedChat;
  RecentConversationKey? get _selectedChat {
    final key = (controller.notificationChat ?? controller.current?.chat)?.key;
    return key == null ? null : RecentConversationKey.chat(key);
  }

  @override
  bool admits(RecentConversationKey target) =>
      current &&
      (target.group != null
          ? _group(target) != null
          : _admitsChat(target.chat!));
  bool _admitsChat(ProfileSessionKey key) =>
      controller.owns(key) &&
      !(controller._resources[key.workspace]?.blocksSession(key.sessionId) ??
          false);
  @override
  Object previewRevision(RecentConversationKey target) {
    if (target.group != null) {
      final group = _group(target);
      // Stock roster refreshes recreate immutable room objects. Invalidate
      // pixels on changed display facts, rather than fresh object identity.
      return (
        group?.name,
        group?.instance,
        group?.preview,
        group?.working,
        group?.blocked,
        group?.lastMessageSequence,
        group?.lastAnswerSequence,
        group?.latestSequence,
        group?.lastMessageAt,
        group?.iconColor,
        group?.iconRevision,
        jsonEncode([
          for (final member in group?.members ?? const <BotGroupMember>[])
            [member.id, member.profile, member.handle, member.name],
        ]),
      );
    }
    final key = target.chat!;
    final chat = controller._resources[key.workspace]?._chats[key.sessionId];
    final saved = controller._savedRecents
        .where((item) => item.key == key)
        .firstOrNull;
    // Canonical immutable row identity makes this cheap even for large chats.
    return (
      chat?.title ?? saved?.title,
      chat == null ? null : recents.readingRevision(chat.reading.messages),
      chat?.reading.streaming,
      chat?.composer.observation.displayedText,
      chat?.model,
      chat == null ? null : controller.chatProjectLabel(chat),
      saved?.lastActive,
      controller.connectionStatus.phase,
      _admitsChat(key),
    );
  }

  @override
  RecentConversationAppearance appearanceFor(RecentConversationKey key) {
    final group = _group(key);
    final bot = key.chat == null ? null : bots.cachedAppearance(key.chat!);
    final members = group == null
        ? const BotGroupAppearance.empty()
        : bots.appearanceForGroup(group);
    String token(BotRecord bot) => jsonEncode([
      bot.scope.connectionId,
      bot.scope.connectionIdentity,
      bot.scope.profileName,
      bot.title,
      bot.shape,
      bot.color,
      bot.metadata['imageKind'],
      bots.avatarContentVersion(bot.scope),
    ]);
    return RecentConversationAppearance(
      bot: bot,
      group: members,
      pixelRevisionOverride: group == null
          ? (bot == null ? '' : token(bot))
          : jsonEncode([
              for (final member in group.members)
                [
                  member.profile,
                  members.byHandle[member.handle] == null
                      ? null
                      : token(members.byHandle[member.handle]!),
                ],
            ]),
    );
  }

  @override
  Future<void> prepareAppearances(
    Iterable<RecentConversationKey> keys,
    bool Function() canRead,
  ) async {
    final preparation = ++_avatarPreparation;
    final demand = keys
        .map((key) => key.chat)
        .whereType<ProfileSessionKey>()
        .toSet();
    final profiles = <WorkspaceScope>{
      for (final key in keys)
        if (_group(key) case final group?)
          for (final member in group.members)
            WorkspaceScope(
              connectionId: group.scope.connectionId,
              connectionIdentity: group.scope.connectionIdentity,
              profileName: member.profile,
            ),
    };
    if (demand.isEmpty && profiles.isEmpty) {
      _preparedAvatars?.replaceDemand({});
      return;
    }
    if (!current || !canRead()) {
      _preparedAvatars?.replaceDemand({});
      return;
    }
    // Retire the old neighborhood before awaiting newly missing metadata.
    if (_presentationVisible) {
      (_preparedAvatars ??= bots.createAvatarBorrower()).replaceDemand({
        ...profiles,
        for (final key in demand)
          if (bots.cachedAppearance(key) case final bot?) bot.scope,
      });
    } else {
      _preparedAvatars?.replaceDemand({});
    }
    await Future.wait([
      bots.appearancesForConversations(
        demand,
        canRead: () => current && canRead(),
      ),
      bots.appearancesForProfiles(
        profiles,
        canRead: () => current && canRead(),
      ),
    ]);
    if (!current ||
        !canRead() ||
        !_presentationVisible ||
        preparation != _avatarPreparation) {
      return;
    }
    (_preparedAvatars ??= bots.createAvatarBorrower()).replaceDemand({
      ...profiles,
      for (final key in demand)
        if (bots.cachedAppearance(key) case final bot?) bot.scope,
    });
  }

  @override
  void addListener(VoidCallback listener) {
    controller.addListener(listener);
    recents.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    controller.removeListener(listener);
    recents.removeListener(listener);
    setVisible(false);
    _preparedAvatars?.dispose();
    _preparedAvatars = null;
  }

  @override
  RecentConversationPreview? cachedPreview(RecentConversationEntry entry) {
    if (!admits(entry.key) || entry.key.chat == null) return null;
    final resource = controller._resources[entry.key.chat!.workspace];
    final chat = resource?._chats[entry.key.chat!.sessionId];
    if (chat == null ||
        (chat.reading.historySessionId == null &&
            chat.reading.messages.isEmpty)) {
      return null;
    }
    final rows = chat.reading.messages;
    return _preview(
      entry,
      TranscriptReadingSnapshot(
        messages: rows.skip(
          math.max(0, rows.length - _recentPreviewMessageLimit),
        ),
        historySessionId: chat.reading.historySessionId,
      ),
      chat.composer.observation.displayedText,
    );
  }

  RecentConversationPreview _preview(
    RecentConversationEntry entry,
    TranscriptReadingSnapshot reading,
    String draft,
  ) {
    final resource = controller._resources[entry.key.chat!.workspace];
    final chat = resource?._chats[entry.key.chat!.sessionId];
    return RecentConversationPreview(
      entry: RecentConversationEntry.chat(
        key: entry.key.chat!,
        title: chat?.title ?? entry.title,
        unread: entry.unread,
      ),
      reading: reading,
      draft: draft,
      scopeLabel: chat == null
          ? entry.key.chat!.workspace.profileName
          : controller.chatProjectLabel(chat),
      modelLabel: chat?.model,
    );
  }

  @override
  Future<RecentConversationPreview> loadPreview(
    RecentConversationEntry entry,
    bool Function() canRead,
  ) async {
    if (!canRead() || !admits(entry.key)) {
      throw StateError('Conversation is unavailable');
    }
    if (entry.group != null) return _loadGroupPreview(entry, canRead);
    final cached = cachedPreview(entry);
    if (cached != null) return cached;
    final resource = controller._resource(
      entry.key.chat!.workspace.profileName,
    );
    final page = await resource.gateway.history(
      entry.key.chat!.sessionId,
      limit: _recentPreviewMessageLimit,
      inlineImages: false,
    );
    if (!canRead() ||
        !admits(entry.key) ||
        page.sessionId != entry.key.chat!.sessionId) {
      throw StateError('Conversation preview changed');
    }
    final draft = await controller.savedDraft(entry.key.chat!);
    if (!canRead() || !admits(entry.key)) {
      throw StateError('Conversation preview changed');
    }
    return _preview(
      entry,
      TranscriptReadingSnapshot(
        messages: page.rows,
        historySessionId: page.sessionId,
      ),
      draft?.text ?? '',
    );
  }

  Future<RecentConversationPreview> _loadGroupPreview(
    RecentConversationEntry entry,
    bool Function() canRead,
  ) async {
    final group = _group(entry.key)!;
    final session = bots.openGroup(group);
    try {
      final messages = await session.readRecentMessages(
        limit: _recentPreviewMessageLimit,
        canRead: canRead,
      );
      if (!canRead() || !admits(entry.key)) {
        throw StateError('Group preview unavailable');
      }
      return RecentConversationPreview(
        entry: entry,
        reading: TranscriptReadingSnapshot(
          messages: const [],
          historySessionId: null,
        ),
        draft: '',
        scopeLabel: 'Bot group',
        group: GroupConversationPreview(
          messages: [
            for (final event in messages)
              TranscriptMessage.discussion(group: group, event: event),
          ],
        ),
      );
    } finally {
      session.dispose();
    }
  }

  @override
  Future<void> open(
    RecentConversationKey target,
    bool Function() isCurrent,
  ) async {
    if (target.group != null) {
      if (!admits(target) || !isCurrent()) {
        throw StateError('Group is unavailable');
      }
      await onOpenGroup(_group(target)!);
      return;
    }
    final key = target.chat!;
    final previous = controller._current;
    final previousSession = previous?._selectedSession;
    final navigation = controller._navigationGeneration + 1;
    var openingFailed = false;
    try {
      if (controller._resources[key.workspace]?.offlineSnapshot == true ||
          controller.recovering) {
        await controller.openBrowserSession(key, isCurrentRequest: isCurrent);
      } else {
        final revealed = Completer<void>();
        final refresh = _openAndRefresh(key, isCurrent, revealed);
        // Cached reading releases the route transition while this owned
        // operation keeps checking the runtime and authoritative history.
        await Future.any([revealed.future, refresh]);
      }
      if (routeOrigin != null && isCurrent() && _selectedChat == target) {
        await onOpenChat!(target);
      }
    } catch (_) {
      openingFailed = true;
      rethrow;
    } finally {
      final failedSelection =
          controller._navigationGeneration == navigation &&
          (openingFailed || _selectedChat != RecentConversationKey.chat(key));
      final restore =
          failedSelection && (routeOrigin != null || previousSession != null);
      // Only a failed selection restores its captured owner. Leaving a
      // borrowed route is handled by the canonical workspace menu instead.
      if (restore &&
          isCurrent() &&
          (previous == null ||
              controller._resources[previous.scope] == previous) &&
          (previousSession == null ||
              (!previous!.blocksSession(previousSession) &&
                  previous._chats.containsKey(previousSession)))) {
        controller._current = previous;
        previous?._selectedSession = previousSession;
        controller._changed();
        if (previous != null) {
          controller.appPreferences.admitProfileSelection(
            controller.connectionIdentity,
            previous.scope.profileName,
          );
          await controller.appPreferences.settleProfileSelection(
            controller.connectionIdentity,
          );
        }
      }
    }
  }

  Future<void> _openAndRefresh(
    ProfileSessionKey key,
    bool Function() isCurrent,
    Completer<void> revealed,
  ) async {
    await controller.openSessionForReading(
      key,
      isCurrentRequest: isCurrent,
      onReadingAvailable: (_) {
        if (!revealed.isCompleted) revealed.complete();
      },
    );
  }
}

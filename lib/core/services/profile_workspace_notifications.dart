part of 'profile_workspace_controller.dart';

class ProfileInputNotification {
  final ProfileSessionKey key;
  final String title;
  final String connectionLabel;
  final List<NotificationInput> inputs;
  final bool alert;
  ProfileInputNotification(
    this.key,
    this.title,
    this.connectionLabel,
    Iterable<NotificationInput> inputs,
    this.alert,
  ) : inputs = List.unmodifiable(inputs);
}

extension ProfileNotificationState on ProfileWorkspaceController {
  Iterable<
    ({ProfileSessionKey? key, String payload, String title, String state})
  >
  get notificationMonitoringChats sync* {
    for (final group in _groupNotifications.monitoringGroups) {
      yield (
        key: null,
        payload: jsonEncode(
          GroupNotificationTarget(
            WorkspaceScope(
              connectionId: connection.id,
              connectionIdentity: connectionIdentity,
              profileName: 'default',
            ),
            group.roomId,
          ).toJson(),
        ),
        title: group.title,
        state: group.state,
      );
    }
    for (final chat in notificationChats) {
      if (chat.source == 'bot_room') {
        continue;
      }
      final String? state;
      if (chat.runtime.reconnecting && chat.runtime.blocksTurnAdmission) {
        state = 'reconnecting';
      } else if (chat.runtime.approval != null) {
        state = 'needs approval';
      } else if (chat.runtime.pendingQuestion != null ||
          chat.runtime.secureInput != null) {
        state = 'needs input';
      } else if (chat.runtime.blocksTurnAdmission ||
          chat.runtime.commandRunning ||
          chat.composer.observation.draining ||
          chat._subagents.any((s) => !s.isTerminal)) {
        state = 'working';
      } else {
        state = null;
      }
      if (state != null) {
        yield (
          key: chat.key,
          payload: jsonEncode(chat.key.toJson()),
          title: _monitoringChatTitle(chat),
          state: state,
        );
      }
    }
    for (final entry in _backgroundChats.entries) {
      if (_hasLoadedNotificationChat(entry.key, entry.value.sessionId)) {
        continue;
      }
      final state = _uncertainNotificationRuntimes.contains(entry.key)
          ? 'reconnecting'
          : 'working';
      final chat = _notificationSnapshot![entry.key]!.chat;
      if (chat.source == 'bot_room') {
        continue;
      } else {
        yield (
          key: chat.key,
          payload: jsonEncode(chat.key.toJson()),
          title: _monitoringChatTitle(chat),
          state: state,
        );
      }
    }
  }

  String _monitoringChatTitle(ProfileChat chat) {
    if (chat.source == 'desktop' && chat.title == 'Bot Chat') {
      return _discovery?.named(chat.key.workspace.profileName)?.label ??
          chat.key.workspace.profileName;
    }
    if (chat.title.isEmpty || chat.title == 'Hermes session') {
      final sessionId = chat.key.sessionId;
      // Date-prefixed session IDs share their leading characters.
      final shortId = sessionId.length <= 8
          ? sessionId
          : sessionId.substring(sessionId.length - 8);
      return 'Hermes session · $shortId';
    }
    return chat.title;
  }

  Iterable<ProfileChat> get notificationChats =>
      _resources.values.expand((r) => r._chats.values);
  ProfileChat? findNotificationChat(ProfileSessionKey key) =>
      _resources[key.workspace]?._chats[key.sessionId];

  bool _isBotExchangeReply(ProfileChat chat) {
    for (final message in chat.reading.messages.reversed) {
      if (message['role'] != 'user' || isHiddenAnswerMessage(message)) continue;
      final delivery = transcriptUserDelivery(message);
      if (delivery?.kind == 'agent_message') return true;
      // Completion notices and model changes do not replace the initiating
      // message. A later human prompt does: its own answer must still alert.
      if (transcriptNoticeKind(message) != null) continue;
      return false;
    }
    return false;
  }

  List<NotificationInput> _notificationInputs(ProfileChat chat) {
    final result = <NotificationInput>[];
    final observation = chat.runtime;
    for (final issued in observation.approvals) {
      final request = issued.request;
      result.add(
        NotificationInput(
          focus: NotificationFocus('approval', issued.requestId),
          content: ChatNotificationContent.approval(
            request.command,
            request.description,
          ),
          choices: request.choices.map((v) => v.wireValue).toList(),
          submitting:
              observation.approvalResponding &&
              identical(issued.correlation, observation.approval?.correlation),
          error: observation.decisionErrorRequestId == issued.requestId
              ? observation.decisionError
              : null,
        ),
      );
    }
    final question = observation.pendingQuestion;
    if (question != null) {
      final choices = question.choices.join(' · ');
      result.add(
        NotificationInput(
          focus: NotificationFocus('question', question.requestId),
          content: ChatNotificationContent.input(
            '${question.question}${choices.isEmpty ? '' : '\n$choices'}',
          ),
          count: observation.questions!.pendingCount,
        ),
      );
    }
    final secure = chat.runtime.secureInput;
    if (secure != null) {
      result.add(
        NotificationInput(
          focus: NotificationFocus('secure', secure.requestId),
          content: ChatNotificationContent.secureInput,
          submitting: chat.runtime.secureResponding,
        ),
      );
    }
    return result;
  }

  void _publishNotificationInputs(
    ProfileChat chat, {
    bool? alert,
    bool confirmedSnapshot = false,
  }) {
    if (chat.source == 'bot_room') return;
    final inputs = _notificationInputs(chat);
    final fingerprint = jsonEncode(inputs.map((v) => v.toJson()).toList());
    final savedInputs = _notificationInputsFor?.call(chat.key) ?? const [];
    final reconcileSaved =
        confirmedSnapshot &&
        savedInputs.isNotEmpty &&
        fingerprint != jsonEncode(savedInputs.map((v) => v.toJson()).toList());
    if (fingerprint == chat._notificationInputFingerprint && !reconcileSaved) {
      return;
    }
    final established = chat._notificationInputFingerprint != null;
    chat._notificationInputFingerprint = fingerprint;
    if (!established && inputs.isEmpty && !reconcileSaved) return;
    final quiet = chat._notificationInputsQuiet;
    chat._notificationInputsQuiet = false;
    final callback = onNotificationInputs;
    if (callback != null) {
      _trackNotificationWork(
        () => callback(
          ProfileInputNotification(
            chat._key,
            chat._title,
            connection.label,
            inputs,
            alert ?? (established && !quiet),
          ),
        ),
      );
    }
  }

  void _trackNotificationWork(Future<void> Function() callback) {
    _pendingNotifications++;
    unawaited(
      Future<void>.sync(callback).catchError((Object _) {}).whenComplete(() {
        _pendingNotifications--;
        if (!_closed) _changed();
      }),
    );
  }

  void notificationAnswerRead(ProfileChat chat, NotificationFocus target) {
    if (_closed ||
        !visible ||
        _current?.chat != chat ||
        chat.runtime.opening ||
        chat.runtime.offline ||
        chat.reading.historyLoading ||
        chat.reading.historyError != null ||
        chat.reading.notificationReadTarget?.identity != target.identity) {
      return;
    }
    if (!chat.reading.acknowledgeNotificationRead(target)) return;
    final callback = onNotificationRead;
    if (callback != null) {
      _trackNotificationWork(() => callback(chat._key, target.identity));
    }
  }

  /// The application captured the original scoped target before navigation.
  void revealNotification(ProfileSessionKey key, NotificationFocus? focus) {
    if (_closed || !owns(key)) return;
    final chat = findNotificationChat(key);
    if (chat == null) return;
    chat.reading.revealNotification(focus);
    chat.reading.restoreNotificationReadTarget(
      notificationResultFor?.call(key),
    );
  }

  /// Reconcile only notification-bearing chats. Caller owns watcher cadence.
  Future<void> reconcileNotificationRequests(
    Set<ProfileSessionKey> keys,
  ) async {
    Future<Map<String, dynamic>>? activeSnapshot;
    for (final key in keys) {
      if (_closed) return;
      if (!owns(key)) continue;
      final savedInputs = _notificationInputsFor?.call(key) ?? const [];
      var chat = findNotificationChat(key);
      if (chat != null &&
          (chat.runtime.opening ||
              chat.runtime.reconnecting ||
              chat.runtime.approvalResponding ||
              chat.runtime.secureResponding)) {
        continue;
      }
      if (savedInputs.isNotEmpty && (chat == null || chat.runtime.offline)) {
        try {
          chat = await loadNotificationApproval(key);
        } catch (_) {
          // An unavailable saved target does not establish remote resolution.
          continue;
        }
      }
      if (chat == null ||
          chat.runtime.offline ||
          chat.runtime.opening ||
          chat.runtime.reconnecting ||
          chat.runtime.approvalResponding ||
          chat.runtime.secureResponding) {
        continue;
      }
      if (chat.runtime.approval == null &&
          chat.runtime.questions == null &&
          chat.runtime.secureInput == null &&
          _notificationInputsFor?.call(key).isNotEmpty != true) {
        continue;
      }
      final resource = _owned(chat);
      final runtime = chat.runtime.runtimeId;
      final read = _captureResume(resource, chat, startRead: false);
      final before = jsonEncode(
        _notificationInputs(chat).map((v) => v.toJson()).toList(),
      );
      try {
        // The active-list mapping corroborates the runtime; an unknown runtime's
        // empty replay alone must never be interpreted as successful resolution.
        activeSnapshot ??= resource.gateway.call('session.active_list', {});
        final active = await activeSnapshot;
        final sessions = ProfileGateway.records(active['sessions']);
        if (!sessions.any(
          (row) => row['id'] == runtime && row['session_key'] == key.sessionId,
        )) {
          continue;
        }
        if (resource.gateway.canonical.session(runtime) == null) {
          await _recoverCanonicalSnapshot(chat);
          continue;
        }
        final cursor = resource.gateway.canonical.replay(runtime);
        final snapshot = await resource.gateway.call(
          'session.events.since',
          cursor,
        );
        if (snapshot['snapshot_required'] == true ||
            snapshot['truncated'] == true ||
            snapshot['replay_epoch'] != cursor['replay_epoch']) {
          await _recoverCanonicalSnapshot(chat);
          continue;
        }
        if (_closed ||
            !read.current() ||
            chat.runtime.runtimeId != runtime ||
            snapshot['open_requests'] is! List ||
            before !=
                jsonEncode(
                  _notificationInputs(chat).map((v) => v.toJson()).toList(),
                )) {
          continue;
        }
        for (final row in ProfileGateway.records(snapshot['events'])) {
          final event = WsClient.parseGatewayEvent(row);
          if (event != null && event.sessionId == runtime) {
            _event(resource, event);
          }
        }
        if (resource.gateway.canonical.needsSnapshot(runtime)) continue;
        chat._runtime.reconcileOpenRequests(snapshot['open_requests']);
        await _refreshApprovals(chat, notifyNew: true);
        _publishNotificationInputs(chat, confirmedSnapshot: true);
        _changed();
      } catch (_) {
        // Failure/absence of a valid snapshot leaves the notice and request intact.
      }
    }
  }
}

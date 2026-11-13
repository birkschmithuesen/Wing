part of 'chat_notification_coordinator.dart';

/// Issued by the application owner. The view only mounts/reuses a route; its
/// opening future and publication authority retain the exact native target.
final class NotificationChatRoute {
  final ProfileWorkspaceController controller;
  final ProfileWorkspaceController? previousController;
  final bool Function() _current;
  final void Function() _routeClosed;
  NotificationChatRoute._(
    this.controller,
    this.previousController,
    this._current,
    this._routeClosed,
  );
  bool get current => _current();
  void closed() => _routeClosed();
}

final class NotificationGroupRoute {
  NotificationGroupRoute._(this.controller, this.target, this._current);
  final ProfileWorkspaceController controller;
  final GroupNotificationTarget target;
  final bool Function() _current;
  bool get current => _current();
}

/// A captured review, not a reusable authorization. Closing its dialog retires
/// unsent decisions; the existing controller remains the physical ACK owner.
final class NotificationApprovalReviewIntent {
  final GatewayApprovalRequest request;
  final String choice;
  final ProfileWorkspaceController changes;
  final ProfileChat _chat;
  final String _requestId;
  final Object _correlation;
  final bool Function() _applicationCurrent;
  bool _closed = false;
  NotificationApprovalReviewIntent._(
    this.request,
    this.choice,
    this.changes,
    this._chat,
    this._requestId,
    this._correlation,
    this._applicationCurrent,
  );
  bool get pending =>
      !_closed &&
      _applicationCurrent() &&
      changes.owns(_chat.key) &&
      identical(changes.findNotificationChat(_chat.key), _chat) &&
      identical(_chat.runtime.approval?.correlation, _correlation);
  bool get offline => _chat.runtime.offline || _chat.runtime.reconnecting;
  Future<void> submit() {
    if (!pending) throw StateError('This approval is no longer pending.');
    return changes.approveNotification(
      _chat,
      choice,
      requestId: _requestId,
      command: request.command.trim(),
    );
  }

  void _retire() {
    _closed = true;
  }
}

/// Private application workflow. The containing coordinator remains the only
/// chat-notice journal and renderer; registry, ledger and runtime are borrowed.
final class _NotificationApplication {
  _NotificationApplication(
    this.notices, {
    required this.manager,
    required this.registry,
    required this.native,
    required this.deliveries,
    required this.ready,
    required this.monitoring,
    required this.showChat,
    required this.showGroup,
    required this.reviewApproval,
    required this.deferShare,
    required this.showOpenError,
    required this.beforeNavigation,
  });
  final ChatNotificationCoordinator notices;
  final ConnectionManager manager;
  final ProfileWorkspaceRegistry registry;
  final NativeNotificationSink native;
  final NotificationDeliveryLedger deliveries;
  final Future<void> ready;
  final BackgroundMonitoringService monitoring;
  final Future<void> Function(NotificationChatRoute) showChat;
  final Future<void> Function(NotificationGroupRoute) showGroup;
  final Future<void> Function(NotificationApprovalReviewIntent) reviewApproval;
  final void Function() deferShare;
  final void Function() showOpenError;
  final Future<void> Function() beforeNavigation;
  bool closed = false;
  Timer? _poll;
  bool _polling = false;
  final _initializedOwners = <ProfileWorkspaceController>{};
  int _openGeneration = 0;
  ProfileSessionKey? _pendingKey;
  NotificationFocus? _pendingFocus;
  Future<void>? _pendingOpen;
  ProfileWorkspaceController? _openingController;

  void activate() {
    registry.addListener(_activityChanged);
    monitoring.state.addListener(_monitoringChanged);
    notices.appPreferences.state.addListener(_preferencesChanged);
    unawaited(_restore().catchError((Object _) {}));
  }

  bool _current(int generation) => !closed && generation == _openGeneration;

  Future<void> openPayload(String payload) async {
    if (closed || payload.isEmpty) return;
    try {
      final value = jsonDecode(payload) as Map<String, dynamic>;
      if (value.containsKey('room')) {
        final target = GroupNotificationTarget.fromJson(value);
        final generation = ++_openGeneration;
        _openingController?.cancelNotificationOpen();
        _pendingKey = null;
        _pendingOpen = null;
        deferShare();
        await _openGroup(target, generation);
        return;
      }
    } catch (_) {
      _openGeneration++;
      _openingController?.cancelNotificationOpen();
      _pendingKey = null;
      _pendingFocus = null;
      _pendingOpen = null;
      showOpenError();
      return;
    }
    final ProfileSessionKey key;
    final NotificationFocus? focus;
    try {
      final value = jsonDecode(payload) as Map<String, dynamic>;
      key = ProfileSessionKey.fromJson(value);
      focus = value['focus'] is Map
          ? NotificationFocus.fromJson(
              Map<String, dynamic>.from(value['focus']),
            )
          : null;
    } catch (_) {
      _openGeneration++;
      _openingController?.cancelNotificationOpen();
      _pendingKey = null;
      _pendingOpen = null;
      showOpenError();
      return;
    }
    deferShare();
    if (_pendingKey == key && _pendingFocus == focus && _pendingOpen != null) {
      return _pendingOpen!;
    }
    final generation = ++_openGeneration;
    final opening = _openTarget(key, generation, focus);
    _pendingKey = key;
    _pendingFocus = focus;
    _pendingOpen = opening;
    try {
      await opening;
    } finally {
      if (identical(_pendingOpen, opening)) {
        _pendingKey = null;
        _pendingOpen = null;
      }
    }
  }

  Future<void> _openTarget(
    ProfileSessionKey key,
    int generation,
    NotificationFocus? focus,
  ) async {
    try {
      final connection = (await manager.loadConnectionsWithSecrets())
          .where((value) => value.id == key.workspace.connectionId)
          .firstOrNull;
      if (!_current(generation)) return;
      if (connection == null) {
        throw StateError('The original connection is unavailable');
      }
      final controller = await registry.forSession(connection, key);
      if (!_current(generation)) return;
      final previous = _openingController;
      if (previous != null && previous != controller) {
        previous.cancelNotificationOpen();
      }
      _openingController = controller;
      final opening = controller.openNotification(
        key,
        isCurrent: () => _current(generation),
      );
      controller.revealNotification(key, focus);
      final route = NotificationChatRoute._(
        controller,
        previous,
        () => _current(generation),
        () {
          if (!closed && identical(_openingController, controller)) {
            controller.cancelNotificationOpen();
          }
        },
      );
      // Observe opening before yielding to route composition, including a
      // synchronously rejected target. Neither future is an implicit retry.
      await Future.wait<void>([opening, showChat(route)]);
    } catch (_) {
      if (_current(generation)) showOpenError();
    }
  }

  Future<void> _openGroup(
    GroupNotificationTarget target,
    int generation,
  ) async {
    try {
      await ready;
      final connection = (await manager.loadConnectionsWithSecrets())
          .where((value) => value.id == target.scope.connectionId)
          .firstOrNull;
      if (!_current(generation)) return;
      if (connection == null) {
        throw StateError('The original connection is unavailable');
      }
      final owner = await registry.forConnection(connection);
      if (!_current(generation)) return;
      if (owner.connectionIdentity != target.scope.connectionIdentity) {
        throw StateError('The original connection settings have changed');
      }
      await showGroup(
        NotificationGroupRoute._(owner, target, () => _current(generation)),
      );
    } catch (_) {
      if (_current(generation)) showOpenError();
    }
  }

  Future<void> _restore() async {
    await ready;
    if (closed) return;
    final connections = await manager.loadConnectionsWithSecrets();
    final identities = <String, String>{};
    for (final connection in connections) {
      if (closed) return;
      identities[connection.id] = await registry.identities.resolve(connection);
    }
    if (closed) return;
    await notices.restore(
      owns: (chat) {
        try {
          final value = jsonDecode(chat) as Map<String, dynamic>;
          if (value.containsKey('room')) {
            final target = GroupNotificationTarget.fromJson(value);
            return identities[target.scope.connectionId] ==
                target.scope.connectionIdentity;
          }
          final key = ProfileSessionKey.fromJson(
            jsonDecode(chat) as Map<String, dynamic>,
          );
          return identities[key.workspace.connectionId] ==
              key.workspace.connectionIdentity;
        } catch (_) {
          return false;
        }
      },
    );
    await _reconcile();
  }

  Future<void> receive(ProfileNotification value) async {
    if (closed) return;
    if (value.content.category == ChatNotificationCategory.inputNeeded) {
      final owner = registry.controllers
          .where((owner) => owner.owns(value.key))
          .firstOrNull;
      final chat = owner?.findNotificationChat(value.key);
      if (chat != null &&
          (chat.runtime.approval != null ||
              chat.runtime.pendingQuestion != null ||
              chat.runtime.secureInput != null)) {
        return;
      }
    }
    await ready;
    if (closed) return;
    final eventId = value.eventId;
    if (eventId != null && !await deliveries.claim(eventId)) return;
    try {
      if (closed) {
        if (eventId != null) await deliveries.release(eventId);
        return;
      }
      await notices.result(
        chat: jsonEncode(value.key.toJson()),
        title: value.title,
        scope: '${value.connectionLabel} / ${value.key.workspace.profileName}',
        focus:
            value.focus ??
            NotificationFocus(
              'status',
              eventId ?? DateTime.now().microsecondsSinceEpoch.toString(),
            ),
        content: value.content,
        alert: value.alert,
      );
    } catch (_) {
      if (eventId != null) await deliveries.release(eventId);
      rethrow;
    }
  }

  Future<void> receiveInputs(ProfileInputNotification value) async {
    await ready;
    if (closed) return;
    await notices.inputs(
      chat: jsonEncode(value.key.toJson()),
      title: value.title,
      scope: '${value.connectionLabel} / ${value.key.workspace.profileName}',
      inputs: value.inputs,
      alert: value.alert,
    );
  }

  Future<void> interaction(NativeNotificationInteraction value) async {
    try {
      if (closed) return;
      if (value.dismissed) {
        if (value.chat != null && value.revision != null) {
          await notices.dismissed(value.chat!, value.revision!);
        }
        return;
      }
      if (value.payload.isEmpty) return;
      if (value.choice.isEmpty) {
        await beforeNavigation();
        if (!closed) await openPayload(value.payload);
        return;
      }
      final target = jsonDecode(value.payload) as Map<String, dynamic>;
      if (target.containsKey('room')) {
        await _groupDecision(target, value);
        return;
      }
      final key = ProfileSessionKey.fromJson(target);
      final focus = NotificationFocus.fromJson(
        Map<String, dynamic>.from(target['focus']),
      );
      if (focus.kind != 'approval' ||
          !{'once', 'session', 'always', 'deny'}.contains(value.choice)) {
        return;
      }
      final connection = (await manager.loadConnectionsWithSecrets())
          .where((connection) => connection.id == key.workspace.connectionId)
          .firstOrNull;
      if (closed) return;
      if (connection == null) {
        showOpenError();
        return;
      }
      final owner = await registry.forSession(connection, key);
      if (closed) return;
      ProfileChat? chat;
      try {
        chat = await owner.loadNotificationApproval(key);
      } catch (_) {
        if (!closed) {
          await native.actionStatus(
            'Approval could not be loaded. Reconnect and tap the notification again.',
          );
        }
        return;
      }
      if (closed || chat == null) return;
      final current = notices.inputFor(jsonEncode(key.toJson()));
      final issued = chat.runtime.approval;
      if ((current != null && current.focus.identity != focus.identity) ||
          issued == null ||
          issued.requestId != focus.id) {
        await native.actionStatus('This approval is no longer pending.');
        return;
      }
      final mustReview =
          value.choice != 'deny' &&
          (value.review ||
              !notices.appPreferences.current.notificationPreviewsAllowed ||
              value.choice == 'always' ||
              value.command != issued.request.command.trim());
      if (mustReview) {
        final review = NotificationApprovalReviewIntent._(
          issued.request,
          value.choice,
          owner,
          chat,
          focus.id,
          issued.correlation,
          () => !closed,
        );
        try {
          await reviewApproval(review);
        } finally {
          review._retire();
        }
      } else {
        await owner.approveNotification(
          chat,
          value.choice,
          requestId: focus.id,
          command: value.command!,
        );
      }
    } catch (_) {
      if (!closed && value.choice.isNotEmpty) {
        await native.actionStatus(
          'Decision not confirmed. Review or retry the notification.',
        );
      }
    } finally {
      await native.finishDirectAction(value);
    }
  }

  Future<void> _groupDecision(
    Map<String, dynamic> payload,
    NativeNotificationInteraction value,
  ) async {
    final target = GroupNotificationTarget.fromJson(payload);
    final focus = NotificationFocus.fromJson(
      Map<String, dynamic>.from(payload['focus']),
    );
    if (focus.kind != 'approval' || !{'once', 'deny'}.contains(value.choice)) {
      return;
    }
    await ready;
    final connection = (await manager.loadConnectionsWithSecrets())
        .where((c) => c.id == target.scope.connectionId)
        .firstOrNull;
    if (closed) return;
    if (connection == null) throw StateError('Original connection unavailable');
    final owner = await registry.forConnection(connection);
    if (closed) return;
    if (owner.connectionIdentity != target.scope.connectionIdentity) {
      throw StateError('Original connection changed');
    }
    if (value.review ||
        (value.choice != 'deny' &&
            !notices.appPreferences.current.notificationPreviewsAllowed)) {
      await beforeNavigation();
      if (!closed) await openPayload(value.payload);
      return;
    }
    await _groupDecisionState(target, focus, submitting: true);
    try {
      final confirmed = await owner.approveGroupNotification(
        target,
        focus.id,
        value.choice,
        value.command,
      );
      if (!closed && !confirmed) {
        await native.actionStatus('This approval is no longer pending.');
      }
    } catch (_) {
      await _groupDecisionState(
        target,
        focus,
        submitting: false,
        error: 'Decision not confirmed. Open the group to review.',
      );
      rethrow;
    } finally {
      await _groupDecisionState(target, focus, submitting: false);
    }
  }

  Future<void> _groupDecisionState(
    GroupNotificationTarget target,
    NotificationFocus focus, {
    required bool submitting,
    String? error,
  }) => notices._serialize(() async {
    if (closed) return;
    final chat = jsonEncode(target.toJson());
    final state = notices._chats[chat];
    if (state == null || !state.inputs.any((input) => input.focus == focus)) {
      return;
    }
    state.inputs = [
      for (final input in state.inputs)
        if (input.focus != focus)
          input
        else
          NotificationInput(
            focus: input.focus,
            content: input.content,
            choices: input.choices,
            count: input.count,
            submitting: submitting,
            error: error ?? (submitting ? null : input.error),
          ),
    ];
    await notices._render(chat, state, alert: false);
    await notices._write();
  });

  void _monitoringChanged() {
    if (closed) return;
    final active =
        monitoring.state.value == BackgroundMonitoringState.active ||
        monitoring.state.value == BackgroundMonitoringState.batteryRestricted;
    if (!active) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    _poll ??= Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_reconcile().catchError((Object _) {})),
    );
  }

  Future<void> _reconcile() async {
    if (closed || _polling) return;
    _polling = true;
    try {
      final keys = notices.chatsWithNotices
          .where((value) => !(jsonDecode(value) as Map).containsKey('room'))
          .map(
            (value) => ProfileSessionKey.fromJson(
              jsonDecode(value) as Map<String, dynamic>,
            ),
          )
          .toSet();
      for (final owner in registry.controllers.toList()) {
        if (closed) return;
        if (!owner.initialized) continue;
        await owner.reconcileNotificationRequests(
          keys.where(owner.owns).toSet(),
        );
      }
    } finally {
      _polling = false;
    }
  }

  void _activityChanged() {
    if (closed) return;
    final owners = registry.controllers.toList();
    _initializedOwners.retainAll(owners);
    var initialized = false;
    for (final owner in owners) {
      if (owner.initialized && _initializedOwners.add(owner)) {
        initialized = true;
      }
      for (final chat in owner.notificationChats) {
        chat.reading.restoreNotificationReadTarget(
          notices.resultFor(jsonEncode(chat.key.toJson())),
        );
      }
    }
    unawaited(syncMonitoring().catchError((Object _) {}));
    if (initialized) unawaited(_reconcile().catchError((Object _) {}));
  }

  void _preferencesChanged() {
    if (closed) return;
    unawaited(syncMonitoring().catchError((Object _) {}));
    unawaited(notices.refreshPreferences().catchError((Object _) {}));
  }

  Future<void> requestStartupPermission() async {
    if (closed || kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    const key = 'notification_permission_requested';
    if (notices.preferences.getBool(key) == true) return;
    try {
      await ready;
      if (closed) return;
      final enabled = await native.notificationsEnabled();
      if (closed) return;
      if (enabled != true) await native.requestPermission();
      if (closed) return;
      // Both acceptance and denial suppress future startup prompts. A platform
      // failure leaves the same existing key unacknowledged and retryable.
      await notices.preferences.setBool(key, true);
    } catch (_) {
      /* Permission setup cannot prevent startup. */
    }
  }

  Future<void> enable() async {
    await ready;
    if (closed) return;
    final granted = await native.requestPermission();
    if (closed) return;
    if (granted == false) {
      throw StateError('Notifications are disabled in Android settings.');
    }
    await native.show(
      const TurnNotification(
        id: 214600,
        title: 'Wing notification test',
        body: 'Local alerts are working on this device.',
        payload: '',
        channel: TurnNotificationService.turnChannel,
      ),
    );
    unawaited(syncMonitoring().catchError((Object _) {}));
  }

  Future<void> syncMonitoring() async {
    if (closed) return;
    await ready;
    if (!closed) await monitoring.sync();
  }

  Future<void> resumed() async {
    unawaited(syncMonitoring().catchError((Object _) {}));
    await _reconcile();
  }

  void close() {
    closed = true;
    _openGeneration++;
    _openingController?.cancelNotificationOpen();
    _poll?.cancel();
    _initializedOwners.clear();
    registry.removeListener(_activityChanged);
    monitoring.state.removeListener(_monitoringChanged);
    notices.appPreferences.state.removeListener(_preferencesChanged);
    native.close();
  }
}

import '../models/recent_conversation.dart';
import '../models/group_notification.dart';
import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_preferences.dart';
import '../models/chat_notification_content.dart';
import '../models/notification_focus.dart';
import '../models/notification_input.dart';
import 'turn_notification_service.dart';
import 'app_preferences.dart';

import 'package:flutter/foundation.dart';
import '../models/profile_session_key.dart';
import '../models/gateway_approval.dart';
import 'connection_manager.dart';
import 'profile_workspace_controller.dart';
import 'profile_workspace_registry.dart';
import 'native_notification_sink.dart';
import 'notification_delivery_ledger.dart';
import 'background_monitoring_service.dart';

part 'chat_notification_application.dart';

class _ChatNotice {
  String title;
  String scope;
  Map<String, dynamic>? result;
  // Observation, delivery and persistence are separate acknowledgments. A
  // failed first delivery must not become durable through another chat's write.
  Map<String, dynamic>? renderedResult;
  Map<String, dynamic>? persistedResult;
  bool resultAlerts = true;
  List<NotificationInput> inputs = [];
  String? dismissed;
  String? posted;
  String? rendered;
  _ChatNotice(this.title, this.scope);
  Map<String, dynamic> toJson() => {
    'title': title,
    'scope': scope,
    'result': renderedResult,
    'inputs': inputs.map((v) => v.toJson()).toList(),
    'dismissed': dismissed,
    'posted': posted,
    'rendered': rendered,
  };
}

typedef _NotificationPolicy = ({bool completed, bool attention, bool previews});

/// One durable state per scoped chat. Rendering and writes are serialized so a
/// delayed permission check or stale read callback cannot replace a newer state.
class ChatNotificationCoordinator {
  final _activity = ValueNotifier<ChatNoticeActivity?>(null);
  ValueListenable<ChatNoticeActivity?> get activity => _activity;
  int _activitySequence = 0;
  bool _activityClosed = false;

  void _publishActivity(
    String chat,
    NotificationFocus focus,
    ConversationActivityKind kind,
  ) {
    if (_activityClosed) return;
    final RecentConversationKey key;
    try {
      final target = Map<String, dynamic>.from(jsonDecode(chat) as Map);
      key = target.containsKey('room')
          ? RecentConversationKey.group(
              GroupNotificationTarget.fromJson(target).key,
            )
          : RecentConversationKey.chat(ProfileSessionKey.fromJson(target));
    } on FormatException {
      return;
    }
    _activity.value = ChatNoticeActivity(
      key: key,
      kind: kind,
      identity: focus.identity,
      sequence: ++_activitySequence,
    );
  }

  static const storageKey = 'chat_notification_state';
  final SharedPreferences preferences;
  final AppPreferences appPreferences;
  final TurnNotificationSink sink;
  final Map<String, _ChatNotice> _chats = {};
  Future<void> _tail = Future.value();
  _NotificationPolicy? _lastPreferencePolicy;
  _NotificationApplication? _application;
  ChatNotificationCoordinator(
    this.preferences,
    this.sink, {
    required this.appPreferences,
  }) {
    final state = appPreferences.current;
    if ([
      AppPreferenceField.completedNotifications,
      AppPreferenceField.attentionNotifications,
      AppPreferenceField.notificationPreviews,
    ].every(state.isFieldCurrent)) {
      _lastPreferencePolicy = _currentPreferencePolicy;
    }
    final stored = preferences.getString(storageKey);
    if (stored == null) return;
    try {
      for (final entry
          in (jsonDecode(stored) as Map<String, dynamic>).entries) {
        final data = Map<String, dynamic>.from(entry.value);
        final state = _ChatNotice(
          data['title'] as String,
          data['scope'] as String,
        );
        state.result = data['result'] == null
            ? null
            : Map<String, dynamic>.from(data['result']);
        state.renderedResult = state.result;
        state.persistedResult = state.result;
        state.inputs = (data['inputs'] as List)
            .map(
              (v) => NotificationInput.fromJson(Map<String, dynamic>.from(v)),
            )
            .toList();
        state.dismissed = data['dismissed'] as String?;
        state.posted = data['posted'] as String?;
        state.rendered = data['rendered'] as String?;
        _chats[entry.key] = state;
      }
    } on Object {
      // Invalid local state cannot be used to target a request.
      _chats.clear();
    }
  }

  Future<void> _write() async {
    final saved = await preferences.setString(
      storageKey,
      jsonEncode(_chats.map((key, value) => MapEntry(key, value.toJson()))),
    );
    if (!saved) throw StateError('Notification state was not saved');
    for (final state in _chats.values) {
      state.persistedResult = state.renderedResult;
    }
  }

  Future<void> _serialize(Future<void> Function() work) {
    final next = _tail.then((_) async {
      final policy = _currentPreferencePolicy;
      var stable = true;
      void observePolicy() {
        // A render can admit different facts after permission yields. Once
        // changed, an ABA return cannot acknowledge that operation as stable.
        if (_currentPreferencePolicy != policy) stable = false;
      }

      appPreferences.state.addListener(observePolicy);
      try {
        await work();
      } catch (_) {
        // Delivery may succeed without journal confirmation. Every operation
        // leaves a queued or explicit refresh eligible after an uncertain write.
        _lastPreferencePolicy = null;
        rethrow;
      } finally {
        if (!stable || _currentPreferencePolicy != policy) {
          _lastPreferencePolicy = null;
        }
        appPreferences.state.removeListener(observePolicy);
      }
    });
    _tail = next.catchError((Object _) {});
    return next;
  }

  NotificationFocus? resultFor(String chat) {
    final value = _chats[chat]?.result;
    return value == null
        ? null
        : NotificationFocus.fromJson(Map<String, dynamic>.from(value['focus']));
  }

  /// Application activation is mandatory before application commands. The
  /// independent journal interface remains usable by its direct consumers.
  void bindApplication({
    required ConnectionManager manager,
    required ProfileWorkspaceRegistry registry,
    required NativeNotificationSink native,
    required NotificationDeliveryLedger deliveries,
    required Future<void> ready,
    required BackgroundMonitoringService monitoring,
    required Future<void> Function(NotificationChatRoute) showChat,
    required Future<void> Function(NotificationGroupRoute) showGroup,
    required Future<void> Function(NotificationApprovalReviewIntent)
    reviewApproval,
    required void Function() deferShare,
    required void Function() showOpenError,
    required Future<void> Function() beforeNavigation,
  }) {
    if (_application != null) {
      throw StateError('Notification application already bound');
    }
    _application = _NotificationApplication(
      this,
      manager: manager,
      registry: registry,
      native: native,
      deliveries: deliveries,
      ready: ready,
      monitoring: monitoring,
      showChat: showChat,
      showGroup: showGroup,
      reviewApproval: reviewApproval,
      deferShare: deferShare,
      showOpenError: showOpenError,
      beforeNavigation: beforeNavigation,
    );
    _application!.activate();
  }

  _NotificationApplication get _activeApplication {
    final value = _application;
    if (value == null || value.closed) {
      throw StateError('Notification application is not active');
    }
    return value;
  }

  Future<void> openPayload(String payload) =>
      _activeApplication.openPayload(payload);
  Future<void> receiveInteraction(NativeNotificationInteraction value) =>
      _activeApplication.interaction(value);
  Future<void> receiveNotice(ProfileNotification value) =>
      _activeApplication.receive(value);
  Future<void> receiveInputs(ProfileInputNotification value) =>
      _activeApplication.receiveInputs(value);
  Future<void> receiveGroupAnswer(GroupAnswerNotification value) => result(
    chat: jsonEncode(value.target.toJson()),
    title: value.title,
    scope: '${value.instance} / Group',
    focus: NotificationFocus('answer', '${value.sequence}'),
    content: ChatNotificationContent.reply(value.text),
  );
  Future<void> receiveGroupInputs(GroupInputNotification value) {
    final chat = jsonEncode(value.target.toJson());
    return _serialize(() async {
      // An empty room-input poll cannot redraw or acknowledge a reply delivery.
      if (value.inputs.isEmpty && (_chats[chat]?.inputs.isEmpty ?? true)) {
        return;
      }
      await _replaceInputs(
        chat: chat,
        title: value.title,
        scope: '${value.instance} / Group',
        captured: value.inputs,
        alert: true,
      );
    });
  }

  Future<void> readGroupAnswer(GroupNotificationTarget target, int sequence) =>
      _serialize(() async {
        final chat = jsonEncode(target.toJson());
        final focus = resultFor(chat);
        final answerSequence = focus == null ? null : int.tryParse(focus.id);
        if (focus?.kind == 'answer' &&
            answerSequence != null &&
            answerSequence <= sequence) {
          final state = _chats[chat]!;
          state.result = null;
          await _render(chat, state, alert: false);
          await _write();
        }
      });

  Future<void> requestStartupPermission() =>
      _activeApplication.requestStartupPermission();
  Future<void> enableNotifications() => _activeApplication.enable();
  Future<void> applicationResumed() => _activeApplication.resumed();
  Future<void> syncMonitoring() => _activeApplication.syncMonitoring();
  void closeApplication() {
    _activeApplication.close();
    if (!_activityClosed) {
      _activityClosed = true;
      _activity.dispose();
    }
  }

  NotificationFocus? focusFor(ProfileSessionKey key) =>
      resultFor(jsonEncode(key.toJson()));
  List<NotificationInput> pendingInputsFor(ProfileSessionKey key) =>
      List.unmodifiable(_chats[jsonEncode(key.toJson())]?.inputs ?? const []);
  Future<void> readTarget(ProfileSessionKey key, String identity) =>
      read(jsonEncode(key.toJson()), identity);
  NotificationInput? inputFor(String chat) => _chats[chat]?.inputs.firstOrNull;
  bool hasNotice(String chat) => _chats[chat]?.posted != null;
  Iterable<String> get chatsWithNotices => _chats.entries
      .where((entry) => entry.value.posted != null)
      .map((entry) => entry.key);

  Future<void> result({
    required String chat,
    required String title,
    required String scope,
    required NotificationFocus focus,
    required ChatNotificationContent content,
    bool alert = true,
  }) => _serialize(() async {
    final state = _chats.putIfAbsent(chat, () => _ChatNotice(title, scope));
    state.title = title;
    state.scope = scope;
    final newlyObserved = state.result?['identity'] != focus.identity;
    if (!newlyObserved && identical(state.result, state.persistedResult)) {
      return;
    }
    if (newlyObserved) {
      state.resultAlerts = alert;
      state.result = {
        'identity': focus.identity,
        'focus': focus.toJson(),
        'content': content.toJson(),
      };
    }
    if (newlyObserved &&
        alert &&
        focus.kind == 'answer' &&
        content.category == ChatNotificationCategory.update) {
      _publishActivity(chat, focus, ConversationActivityKind.reply);
    }
    if (!identical(state.result, state.renderedResult)) {
      await _render(
        chat,
        state,
        alert: state.resultAlerts,
        admitBaseline: !state.resultAlerts,
      );
    }
    await _write();
  });

  Future<void> inputs({
    required String chat,
    required String title,
    required String scope,
    required List<NotificationInput> inputs,
    bool alert = true,
  }) {
    final captured = List<NotificationInput>.unmodifiable(inputs);
    return _serialize(
      () => _replaceInputs(
        chat: chat,
        title: title,
        scope: scope,
        captured: captured,
        alert: alert,
      ),
    );
  }

  Future<void> _replaceInputs({
    required String chat,
    required String title,
    required String scope,
    required List<NotificationInput> captured,
    required bool alert,
  }) async {
    final state = _chats.putIfAbsent(chat, () => _ChatNotice(title, scope));
    state.title = title;
    state.scope = scope;
    // Preserve first-seen order across request kinds, refreshes and restarts.
    final previousIdentities = state.inputs
        .map((input) => input.focus.identity)
        .toSet();
    final remaining = {
      for (final input in captured) input.focus.identity: input,
    };
    final ordered = <NotificationInput>[];
    for (final previous in state.inputs) {
      final fresh = remaining.remove(previous.focus.identity);
      if (fresh != null) ordered.add(fresh);
    }
    ordered.addAll(remaining.values);
    state.inputs = ordered;
    final newlyObserved = ordered
        .where((input) => !previousIdentities.contains(input.focus.identity))
        .firstOrNull;
    if (alert && newlyObserved != null) {
      _publishActivity(
        chat,
        newlyObserved.focus,
        ConversationActivityKind.inputNeeded,
      );
    }
    await _render(chat, state, alert: alert);
    await _write();
  }

  Future<void> read(String chat, String identity) => _serialize(() async {
    final state = _chats[chat];
    if (state == null || state.result?['identity'] != identity) return;
    state.result = null;
    await _render(chat, state, alert: false);
    await _write();
  });

  Future<void> dismissed(String chat, String revision) => _serialize(() async {
    final state = _chats[chat];
    if (state == null || state.posted != revision) return;
    state.dismissed = revision;
    state.posted = null;
    state.rendered = null;
    await _write();
  });

  /// Android removes notifications on force-stop. Persisted render equality is
  /// not evidence that the system still displays a slot in a new process.
  /// Only previously posted, still-owned notices qualify for a silent redraw.
  Future<void> restore({required bool Function(String chat) owns}) =>
      _serialize(() async {
        for (final entry in _chats.entries.toList()) {
          final state = entry.value;
          if (!owns(entry.key)) {
            if (state.posted != null) {
              await sink.cancel(
                TurnNotificationService.notificationIdFor(entry.key),
              );
            }
            _chats.remove(entry.key);
            continue;
          }
          if (state.posted == null) continue;
          state.rendered = null;
          await _render(entry.key, state, alert: false);
        }
        await _write();
      });

  _NotificationPolicy get _currentPreferencePolicy {
    final state = appPreferences.current;
    return (
      completed: state.completedNotificationsAllowed,
      attention: state.attentionNotificationsAllowed,
      previews: state.notificationPreviewsAllowed,
    );
  }

  Future<void> refreshPreferences() => _serialize(() async {
    // Unrelated settings observations do not invalidate native render equality.
    // Startup force-redraw is explicitly owned by restore(), not this signal.
    final policy = _currentPreferencePolicy;
    if (policy == _lastPreferencePolicy) return;
    for (final entry in _chats.entries) {
      entry.value.rendered = null;
      await _render(entry.key, entry.value, alert: false);
    }
    await _write();
    // Only a full refresh can acknowledge all chats. The serialized-operation
    // boundary revokes this acknowledgment if any policy changed during it.
    _lastPreferencePolicy = policy;
  });

  bool _categoryAllowed(ChatNotificationContent content) =>
      content.needsAttention
      ? appPreferences.current.attentionNotificationsAllowed
      : appPreferences.current.completedNotificationsAllowed;

  Future<void> _withdraw(String chat, _ChatNotice state) async {
    if (state.posted != null) {
      await sink.cancel(TurnNotificationService.notificationIdFor(chat));
    }
    state.posted = null;
    state.rendered = null;
  }

  Future<void> _render(
    String chat,
    _ChatNotice state, {
    required bool alert,
    bool admitBaseline = false,
  }) async {
    final acknowledged = await _renderNotice(chat, state, alert: alert);
    // A quiet baseline intentionally admits history. A quiet redraw that has
    // no existing native slot cannot confirm an earlier failed fresh delivery.
    if (acknowledged || admitBaseline) state.renderedResult = state.result;
  }

  Future<bool> _renderNotice(
    String chat,
    _ChatNotice state, {
    required bool alert,
  }) async {
    final first = state.inputs.firstOrNull;
    final result = state.result;
    if (first == null && result == null) {
      if (state.posted != null) {
        await sink.cancel(TurnNotificationService.notificationIdFor(chat));
      }
      state.posted = null;
      state.rendered = null;
      return true;
    }
    final content =
        first?.content ??
        ChatNotificationContent.fromJson(
          Map<String, dynamic>.from(result!['content']),
        );
    // Known-disabled categories can withdraw without a platform permission read.
    if (!_categoryAllowed(content)) {
      await _withdraw(chat, state);
      return true;
    }
    // The native permission read can yield to a confirmed preference change.
    // Capture dispatch facts only after it settles, before physical delivery.
    final permitted = await sink.notificationsEnabled() != false;
    if (!_categoryAllowed(content)) {
      await _withdraw(chat, state);
      return true;
    }
    if (!permitted) return true;
    final focus =
        first?.focus ??
        NotificationFocus.fromJson(Map<String, dynamic>.from(result!['focus']));
    final revision = first == null
        ? focus.identity
        : jsonEncode(
            state.inputs
                .map((v) => [v.focus.identity, v.count, v.content.preview])
                .toList(),
          );
    // Silent baselines may reconcile existing alerts but never post history.
    if (state.dismissed == revision) return true;
    if (!alert && state.posted == null) return false;
    final preview = appPreferences.current.notificationPreviewsAllowed;
    final counts = <String, int>{};
    for (final input in state.inputs) {
      counts.update(
        input.focus.kind,
        (n) => n + input.count,
        ifAbsent: () => input.count,
      );
    }
    final pending = counts.entries
        .map(
          (e) => switch (e.key) {
            'approval' => '${e.value} approval${e.value == 1 ? '' : 's'}',
            'question' => '${e.value} question${e.value == 1 ? '' : 's'}',
            _ => '${e.value} secure input${e.value == 1 ? '' : 's'}',
          },
        )
        .join(' · ');
    final payload = jsonEncode({
      ...jsonDecode(chat) as Map<String, dynamic>,
      'focus': focus.toJson(),
      'revision': revision,
    });
    final notification = TurnNotification.chat(
      payload: payload,
      chatIdentity: chat,
      title: state.title,
      scopeLabel: state.scope,
      content: content,
      showPreview: preview,
      focus: focus,
      revision: revision,
      choices: preview ? first?.choices ?? const [] : const [],
      pending: pending,
      submitting: first?.submitting ?? false,
      actionError: first?.error,
      alert: alert && state.posted != revision,
    );
    final rendered = jsonEncode(notification.toJson());
    if (state.rendered == rendered) return true;
    await sink.show(notification);
    state.posted = revision;
    state.rendered = rendered;
    return true;
  }
}

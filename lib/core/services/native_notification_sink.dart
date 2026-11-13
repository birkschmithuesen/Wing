import 'dart:async';
import 'package:flutter/services.dart';
import 'turn_notification_service.dart';

/// Android owns rendering, immutable action intents, unlock and dismissal.
/// The existing plugin continues to own the runtime permission dialog.
class NativeNotificationSink extends PluginTurnNotificationSink {
  static const channelName = 'com.tarkilhk.wing/chat_notifications';
  static const _channel = MethodChannel(channelName);
  final Future<void> Function(NativeNotificationInteraction) onInteraction;
  NativeNotificationSink({required this.onInteraction});
  Future<void>? _nativeInitialization;
  bool _closed = false;

  @override
  Future<void> initialize() async {
    if (_closed) throw StateError('Notification sink is closed');
    final pending = _nativeInitialization;
    if (pending != null) return pending;
    final attempt = _initializeNative();
    _nativeInitialization = attempt;
    try {
      await attempt;
    } catch (_) {
      _nativeInitialization = null;
      rethrow;
    }
  }

  Future<void> _dispatch(Map<String, dynamic> data) async {
    if (_closed) return;
    final interaction = NativeNotificationInteraction.fromJson(data);
    await onInteraction(interaction);
    if (interaction.id != null) {
      await _channel.invokeMethod<void>('acknowledge', interaction.id);
    }
  }

  Future<void> _initializeNative() async {
    await super.initialize();
    if (_closed) throw StateError('Notification sink is closed');
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'interaction') {
        await _dispatch(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
    final pending = await _channel.invokeListMethod<dynamic>('initialize');
    if (_closed) return;
    for (final item in pending ?? const []) {
      final interaction = Map<String, dynamic>.from(item as Map);
      if (interaction['dismiss'] == true) {
        // Startup restoration must observe queued swipe dismissals first.
        await _dispatch(interaction);
      } else {
        // Navigation/action handling may await startup readiness itself.
        unawaited(_dispatch(interaction));
      }
    }
  }

  @override
  Future<void> show(TurnNotification notification) async {
    await initialize();
    if (_closed) throw StateError('Notification offer was not dispatched');
    await _channel.invokeMethod<void>('show', notification.toJson());
  }

  @override
  Future<void> cancel(int id) => _channel.invokeMethod<void>('cancel', id);

  static Future<List<NativeNotificationChannel>> blockedChannels() async {
    final rows =
        await _channel.invokeListMethod<dynamic>('channels') ?? const [];
    return List.unmodifiable(
      rows
          .map(
            (row) => NativeNotificationChannel.fromJson(
              Map<String, dynamic>.from(row as Map),
            ),
          )
          .where((row) => row.blocked),
    );
  }

  static Future<void> openChannelSettings(NativeNotificationChannel value) =>
      _channel.invokeMethod<void>('openChannelSettings', value.id);

  Future<void> actionStatus(String message) async {
    try {
      await _channel.invokeMethod<void>('actionStatus', message);
    } catch (_) {
      // The controller retains the decision when the Android action host closes.
    }
  }

  Future<void> finishDirectAction(NativeNotificationInteraction value) async {
    if (!value.isDirectAction) return;
    try {
      await _channel.invokeMethod<void>(
        'finishDirectAction',
        value.notificationId,
      );
    } catch (_) {
      // The action may already have lost its Android host.
    }
  }

  void close() {
    _closed = true;
  }
}

/// Native wire interpretation stays with the platform adapter. No raw map is
/// retained by the application workflow or its views.
final class NativeNotificationInteraction {
  final String? id;
  final bool dismissed;
  final String? chat;
  final String? revision;
  final String payload;
  final String choice;
  final String? command;
  final bool review;
  final int? notificationId;
  const NativeNotificationInteraction._({
    required this.id,
    required this.dismissed,
    required this.chat,
    required this.revision,
    required this.payload,
    required this.choice,
    required this.command,
    required this.review,
    required this.notificationId,
  });
  bool get isDirectAction => choice.isNotEmpty && !review;

  factory NativeNotificationInteraction.fromJson(Map<String, dynamic> value) =>
      NativeNotificationInteraction._(
        id: value['interaction_id'] as String?,
        dismissed: value['dismiss'] == true,
        chat: value['chat'] as String?,
        revision: value['revision'] as String?,
        payload: value['payload'] as String? ?? '',
        choice: value['choice'] as String? ?? '',
        command: value['command'] as String?,
        review: value['review'] == true,
        notificationId: value['notification_id'] as int?,
      );
}

final class NativeNotificationChannel {
  final String id;
  final String name;
  final bool blocked;
  const NativeNotificationChannel._(this.id, this.name, this.blocked);
  factory NativeNotificationChannel.fromJson(Map<String, dynamic> value) =>
      NativeNotificationChannel._(
        value['id'] as String,
        value['name'] as String,
        value['blocked'] == true,
      );
}

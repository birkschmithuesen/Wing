import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'porter_wake_presentation.dart';

sealed class PorterBridgeEvent {
  const PorterBridgeEvent(this.connectionId);
  final String connectionId;

  static PorterBridgeEvent? fromMap(Map<Object?, Object?> raw) {
    final connection = raw['connection'];
    if (connection is! String) return null;
    return switch (raw['type']) {
      'push' when raw['bytes'] is Uint8List =>
        PorterPushEvent(connection, raw['bytes'] as Uint8List),
      'endpoint' when raw['url'] is String =>
        PorterEndpointEvent(connection, raw['url'] as String),
      'unregistered' => PorterUnregisteredEvent(connection),
      'failed' => PorterRegistrationFailedEvent(connection, '${raw['reason']}'),
      'interaction' when raw['notice_id'] is String && raw['action'] is String =>
        PorterInteractionEvent(
          connectionId: connection,
          noticeId: raw['notice_id'] as String,
          action: raw['action'] as String,
          value: raw['value'] as String?,
          openProfile: raw['open_profile'] as String? ?? 'pforte',
          neutral: raw['neutral'] == true,
        ),
      _ => null,
    };
  }
}

final class PorterPushEvent extends PorterBridgeEvent {
  const PorterPushEvent(super.connectionId, this.bytes);
  final Uint8List bytes;
}

final class PorterEndpointEvent extends PorterBridgeEvent {
  const PorterEndpointEvent(super.connectionId, this.url);
  final String url;
}

final class PorterUnregisteredEvent extends PorterBridgeEvent {
  const PorterUnregisteredEvent(super.connectionId);
}

final class PorterRegistrationFailedEvent extends PorterBridgeEvent {
  const PorterRegistrationFailedEvent(super.connectionId, this.reason);
  final String reason;
}

final class PorterInteractionEvent extends PorterBridgeEvent {
  const PorterInteractionEvent({
    required String connectionId,
    required this.noticeId,
    required this.action,
    this.value,
    required this.openProfile,
    required this.neutral,
  }) : super(connectionId);
  final String noticeId;
  final String action;
  final String? value;
  final String openProfile;
  final bool neutral;
}

abstract interface class PorterWakeBridge {
  Future<void> start(
    Future<bool> Function(PorterBridgeEvent event) onEvent, {
    required bool background,
  });
  Future<bool> register(String connectionId);
  Future<void> unregister(String connectionId);
  Future<void> show(PorterNotificationSpec spec);
  Future<void> cancel();
  Future<String?> deviceLabel();
  Future<void> finished();
}

class MethodChannelPorterWakeBridge implements PorterWakeBridge {
  static const channel = MethodChannel('com.tarkilhk.wing/porter_wake');

  @override
  Future<void> start(
    Future<bool> Function(PorterBridgeEvent event) onEvent, {
    required bool background,
  }) async {
    Future<bool> dispatch(Object? raw) async {
      final event = raw is Map ? PorterBridgeEvent.fromMap(raw) : null;
      if (event == null) return false;
      try {
        return await onEvent(event);
      } on Object catch (error) {
        debugPrint('porter_wake: event failed (${error.runtimeType})');
        return false;
      }
    }

    channel.setMethodCallHandler((call) async =>
        call.method == 'event' ? dispatch(call.arguments) : null);
    final queued = await channel.invokeListMethod<Object?>(
      'initialize',
      {'role': background ? 'background' : 'main'},
    );
    for (final raw in queued ?? const []) {
      await dispatch(raw);
    }
  }

  @override
  Future<bool> register(String connectionId) async =>
      await channel.invokeMethod<bool>('register', connectionId) ?? false;
  @override
  Future<void> unregister(String connectionId) =>
      channel.invokeMethod<void>('unregister', connectionId);
  @override
  Future<void> show(PorterNotificationSpec spec) =>
      channel.invokeMethod<void>('show', spec.toJson());
  @override
  Future<void> cancel() => channel.invokeMethod<void>('cancel');
  @override
  Future<String?> deviceLabel() => channel.invokeMethod<String>('deviceLabel');
  @override
  Future<void> finished() => channel.invokeMethod<void>('finished');
}

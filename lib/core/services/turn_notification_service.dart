import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/chat_notification_content.dart';
import '../models/notification_focus.dart';

/// The Android/iOS notification channel a [TurnNotification] belongs to.
///
/// Describing the channel as data keeps platform delivery testable.
class TurnNotificationChannel {
  final String id;
  final String name;
  final String description;

  const TurnNotificationChannel({
    required this.id,
    required this.name,
    required this.description,
  });
}

/// A notification Wing wants Android to post, described as plain data.
class TurnNotification {
  final int id;
  final String title;
  final String body;
  final String payload;
  final String? expandedBody;
  final String? scopeLabel;
  final TurnNotificationChannel channel;
  final NotificationFocus? focus;
  final String? chatIdentity;
  final String? revision;
  final String icon;
  final List<String> choices;
  final String pending;
  final bool submitting;
  final String? actionError;
  final bool alert;
  final bool showPreview;

  const TurnNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.payload,
    required this.channel,
    this.expandedBody,
    this.scopeLabel,
    this.focus,
    this.chatIdentity,
    this.revision,
    this.icon = 'ic_stat_wing',
    this.choices = const [],
    this.pending = '',
    this.submitting = false,
    this.actionError,
    this.alert = true,
    this.showPreview = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'expanded': expandedBody ?? body,
    'payload': payload,
    'scope': scopeLabel,
    'channel': channel.id,
    'chat': chatIdentity,
    'revision': revision,
    'kind': focus?.kind,
    'icon': icon,
    'choices': choices,
    'pending': pending,
    'submitting': submitting,
    'error': actionError,
    'alert': alert,
    'preview': showPreview,
  };

  factory TurnNotification.chat({
    required String payload,
    required String title,
    required String scopeLabel,
    required ChatNotificationContent content,
    required bool showPreview,
    String? chatIdentity,
    NotificationFocus? focus,
    String? revision,
    List<String> choices = const [],
    String pending = '',
    bool submitting = false,
    String? actionError,
    bool alert = true,
  }) {
    final cleanTitle = notificationPlainText(title);
    return TurnNotification(
      id: TurnNotificationService.notificationIdFor(chatIdentity ?? payload),
      title: cleanTitle.isEmpty
          ? 'Untitled chat'
          : notificationTextLimit(cleanTitle, 120),
      body: content.body(showPreview: showPreview),
      expandedBody: content.body(showPreview: showPreview, limit: 800),
      scopeLabel: notificationTextLimit(notificationPlainText(scopeLabel), 120),
      payload: payload,
      focus: focus,
      chatIdentity: chatIdentity,
      revision: revision,
      choices: choices,
      pending: pending,
      submitting: submitting,
      actionError: actionError,
      alert: alert,
      showPreview: showPreview,
      icon: switch (content.category) {
        ChatNotificationCategory.update => 'ic_stat_wing',
        ChatNotificationCategory.inputNeeded => 'ic_stat_wing_input',
        ChatNotificationCategory.stopped => 'ic_stat_wing_stopped',
      },
      channel: content.needsAttention
          ? TurnNotificationService.attentionChannel
          : TurnNotificationService.turnChannel,
    );
  }
}

/// The platform seam [TurnNotificationService] posts through.
///
/// The production implementation is [PluginTurnNotificationSink]; tests supply
/// a recording double so notification behaviour can be verified without a
/// platform channel.
abstract class TurnNotificationSink {
  Future<void> initialize();

  /// Asks the platform for permission to post notifications.
  ///
  /// Returns `true` when granted, `false` when denied, and `null` when the
  /// platform has no runtime gate (iOS, Android < 13) — in which case posting
  /// is already allowed.
  Future<bool?> requestPermission();

  /// Reports whether the platform currently permits visible notifications.
  /// `null` means the platform does not expose a status check.
  Future<bool?> notificationsEnabled() async => null;

  Future<void> show(TurnNotification notification);

  Future<void> cancel(int id);
}

/// Default sink backed by `flutter_local_notifications`.
class PluginTurnNotificationSink implements TurnNotificationSink {
  final FlutterLocalNotificationsPlugin _plugin;
  final void Function(String payload)? onOpen;
  Future<void>? _initialization;
  bool _initialized = false;

  PluginTurnNotificationSink({
    FlutterLocalNotificationsPlugin? plugin,
    this.onOpen,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    final pending = _initialization;
    if (pending != null) return pending;

    final attempt = _initializeOnce();
    _initialization = attempt;
    try {
      await attempt;
      _initialized = true;
    } finally {
      if (identical(_initialization, attempt)) _initialization = null;
    }
  }

  Future<void> _initializeOnce() async {
    const androidSettings = AndroidInitializationSettings('ic_stat_wing');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null) onOpen?.call(payload);
      },
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            'wing_turn_notifications',
            'Wing Turns',
            description: 'Notifications for completed background turns',
            importance: Importance.defaultImportance,
          ),
        );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          AndroidNotificationChannel(
            TurnNotificationService.attentionChannel.id,
            TurnNotificationService.attentionChannel.name,
            description: TurnNotificationService.attentionChannel.description,
            importance: Importance.high,
          ),
        );
    final launch = await _plugin.getNotificationAppLaunchDetails();
    final payload = launch?.notificationResponse?.payload;
    if (launch?.didNotificationLaunchApp == true && payload != null) {
      onOpen?.call(payload);
    }
  }

  @override
  Future<bool?> requestPermission() async {
    await initialize();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      return android.requestNotificationsPermission();
    }

    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (ios != null) {
      return ios.requestPermissions(alert: true, badge: true, sound: true);
    }

    // No platform implementation resolved: nothing gates posting here.
    return null;
  }

  @override
  Future<bool?> notificationsEnabled() async {
    await initialize();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return android?.areNotificationsEnabled();
  }

  @override
  Future<void> show(TurnNotification notification) async {
    await initialize();
    final needsAttention =
        notification.channel.id == TurnNotificationService.attentionChannel.id;
    final androidDetails = AndroidNotificationDetails(
      notification.channel.id,
      notification.channel.name,
      channelDescription: notification.channel.description,
      icon: notification.icon,
      importance: needsAttention
          ? Importance.high
          : Importance.defaultImportance,
      priority: needsAttention ? Priority.high : Priority.defaultPriority,
      autoCancel: false,
      onlyAlertOnce: !notification.alert,
      visibility: NotificationVisibility.private,
      subText: notification.scopeLabel,
      styleInformation: BigTextStyleInformation(
        notification.expandedBody ?? notification.body,
      ),
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _plugin.show(
      id: notification.id,
      title: notification.title,
      body: notification.body,
      notificationDetails: details,
      payload: notification.payload,
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);
}

/// Canonical notification channels and cross-process notification identifiers.
abstract final class TurnNotificationService {
  static const turnChannel = TurnNotificationChannel(
    id: 'wing_turn_notifications',
    name: 'Wing Turns',
    description: 'Notifications for completed background turns',
  );

  static const attentionChannel = TurnNotificationChannel(
    id: 'wing_attention_notifications',
    name: 'Wing Needs Your Attention',
    description:
        'Approvals, questions and failed turns that need your attention',
  );

  /// Stable, non-negative Android notification id derived from [turnId].
  ///
  /// Masking instead of negating keeps the id inside the 31-bit range Android
  /// accepts, and keeps one turn mapped to exactly one notification so a turn
  /// replaces its own notification instead of stacking duplicates.
  static int notificationIdFor(String turnId) {
    final bytes = sha256.convert(utf8.encode(turnId)).bytes;
    return ((bytes[0] & 0x7f) << 24) |
        (bytes[1] << 16) |
        (bytes[2] << 8) |
        bytes[3];
  }
}

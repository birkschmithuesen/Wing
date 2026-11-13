import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/native_notification_sink.dart';
import 'package:wing/main.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;

const _nativeNotifications = MethodChannel(NativeNotificationSink.channelName);

void main() {
  testWidgets(
    'disconnected notification Once reports an unconfirmed decision',
    (tester) => checkDisconnectedNotification(tester, review: false),
  );
}

Future<void> checkDisconnectedNotification(
  WidgetTester tester, {
  required bool review,
  bool hidePreviews = false,
  bool hidePreviewsAfterPosting = false,
}) async {
  final expectsReview = review || hidePreviews || hidePreviewsAfterPosting;
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pump();
  FlutterSecureStorage.setMockInitialValues({});
  SharedPreferences.setMockInitialValues({
    'notification_permission_requested': true,
    'microphone_permission_requested': true,
    AppPreferenceField.notificationPreviews.storageKey: !hidePreviews,
  });
  final preferences = await SharedPreferences.getInstance();
  final appPreferences = AppPreferences(preferences);
  addTearDown(appPreferences.dispose);
  final manager = await ConnectionManager.create(preferences);
  final connection = identityTestConnection();
  await manager.importConnections(
    [connection],
    replaceExisting: true,
    canCommit: () => true,
  );
  final shown = <Map<dynamic, dynamic>>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const plugin = MethodChannel('dexterous.com/flutter/local_notifications');
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  messenger.setMockMethodCallHandler(
    plugin,
    (call) async => switch (call.method) {
      'initialize' => true,
      'getNotificationAppLaunchDetails' => {'notificationLaunchedApp': false},
      'areNotificationsEnabled' => true,
      _ => null,
    },
  );
  messenger.setMockMethodCallHandler(_nativeNotifications, (call) async {
    if (call.method == 'show') shown.add(call.arguments as Map);
    return call.method == 'initialize' ? [] : null;
  });
  addTearDown(() {
    messenger.setMockMethodCallHandler(plugin, null);
    messenger.setMockMethodCallHandler(_nativeNotifications, null);
  });
  final host = Host()
    ..running = false
    ..pendingApprovals = [];
  final app = GlobalKey<WingAppState>();
  await tester.pumpWidget(
    WingApp(
      key: app,
      connManager: manager,
      appPreferences: appPreferences,
      gatewayFactory: (_, scope) => host.gateway(scope),
    ),
  );
  await tester.pumpAndSettle();
  final controller = await app.currentState!.profileController(connection);
  await controller.initialize();
  final chat = await controller.createChat(canDispatch: () => true);
  final request = <String, dynamic>{
    'request_id': 'background-once',
    'command': "print('WING-N06-ONCE')",
    'choices': ['once', 'deny'],
  };
  host.pendingApprovals!.add(request);
  host.event('a', 'approval', request);
  await tester.pumpAndSettle();
  final notice = shown.last;
  if (hidePreviewsAfterPosting) {
    await appPreferences.setNotificationPreviews(false);
  }
  expect(chat.runtime.approval?.requestId, 'background-once');
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  host.connectError = TimeoutException('Offline');
  host.gateways['a']!.onConnectionChanged!(false);
  var handled = false;
  unawaited(
    messenger
        .handlePlatformMessage(
          _nativeNotifications.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('interaction', {
              'payload': notice['payload'],
              'choice': 'once',
              'command': request['command'],
              'review': review,
            }),
          ),
          (_) {},
        )
        .then((_) => handled = true),
  );
  if (expectsReview) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final offlineStatus = find.text(
      'Offline—approval not sent. Reconnect to retry.',
    );
    for (
      var frame = 0;
      frame < 100 && offlineStatus.evaluate().isEmpty;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      find.byType(ProfileWorkspaceScreen),
      findsNothing,
      reason: 'Notification review must not stack a chat approval underneath',
    );
    expect(offlineStatus, findsOneWidget);
    expect(host.calls.where((c) => c.$2 == 'approval.respond'), isEmpty);
    await tester.tap(find.byTooltip('Cancel approval decision'));
  }
  for (var frame = 0; frame < 100 && !handled; frame++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(handled, isTrue);
  final decisions = host.calls
      .where((call) => call.$2 == 'approval.respond')
      .toList();
  expect(decisions, isEmpty);
  expect(chat.runtime.approval?.requestId, 'background-once');
  if (!expectsReview) {
    expect(chat.runtime.decisionErrorRequestId, 'background-once');
  }
  final reported = expectsReview || chat.runtime.decisionError != null;
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(const SizedBox.shrink());
  expect(
    reported,
    isTrue,
    reason:
        'A real notification tap must not silently vanish while the approval remains pending',
  );
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/chat_notification_content.dart';
import 'package:wing/core/services/turn_notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'action-required alerts use a high-importance Android channel',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'initialize') return true;
        if (call.method == 'getNotificationAppLaunchDetails') {
          return <String, Object?>{'notificationLaunchedApp': false};
        }
        return null;
      });
      await PluginTurnNotificationSink().show(
        TurnNotification.chat(
          payload: 'approval-chat',
          title: 'Review command',
          scopeLabel: 'Home / a',
          content: ChatNotificationContent.input('Review this action'),
          showPreview: true,
        ),
      );
      final details =
          (calls.singleWhere((c) => c.method == 'show').arguments
                  as Map)['platformSpecifics']
              as Map;
      expect(details['importance'], Importance.high.value);
      expect(details['priority'], Priority.high.value);
      expect(details['channelId'], 'wing_attention_notifications');
    },
  );

  test(
    'chat alerts keep their wing icon and individual tap payloads',
    () async {
      final posted = <Map<dynamic, dynamic>>[];
      final opened = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initialize') return true;
        if (call.method == 'getNotificationAppLaunchDetails') {
          return <String, Object?>{'notificationLaunchedApp': false};
        }
        if (call.method == 'show') {
          posted.add(call.arguments as Map<dynamic, dynamic>);
        }
        return null;
      });
      final sink = PluginTurnNotificationSink(onOpen: opened.add);
      for (final target in ['first-chat', 'second-chat']) {
        await sink.show(
          TurnNotification(
            id: TurnNotificationService.notificationIdFor(target),
            title: 'Finished working',
            body: 'Tap to open the chat.',
            expandedBody: 'Reply ready · A longer event-specific excerpt.',
            scopeLabel: 'Home / developer',
            payload: target,
            channel: TurnNotificationService.turnChannel,
          ),
        );
      }
      expect(posted.map((alert) => alert['id']).toSet(), hasLength(2));
      for (final alert in posted) {
        expect(alert['title'], 'Finished working');
        expect(alert['body'], 'Tap to open the chat.');
        expect((alert['platformSpecifics'] as Map)['icon'], 'ic_stat_wing');
        final android = alert['platformSpecifics'] as Map;
        expect(android['visibility'], NotificationVisibility.private.index);
        expect(android['subText'], 'Home / developer');
        expect(
          (android['styleInformation'] as Map)['bigText'],
          'Reply ready · A longer event-specific excerpt.',
        );
      }

      // Tap the older alert after the newer one has been posted, then the newer
      // alert. Each platform callback must retain its own original target.
      for (final alert in posted) {
        await messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('didReceiveNotificationResponse', {
              'notificationId': alert['id'],
              'notificationResponseType': 0,
              'payload': alert['payload'],
            }),
          ),
          (_) {},
        );
      }
      expect(opened, ['first-chat', 'second-chat']);
    },
  );

  test('cancelling one alert forwards its ID to the native plugin', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final sink = PluginTurnNotificationSink();

    await sink.cancel(42);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'cancel');
    expect(calls.single.arguments, {'id': 42, 'tag': null});
  });

  test(
    'show retries plugin initialization after a transient failure',
    () async {
      var initializeCalls = 0;
      final posted = <Map<dynamic, dynamic>>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'initialize':
            initializeCalls++;
            if (initializeCalls == 1) {
              throw PlatformException(code: 'temporarily-unavailable');
            }
            return true;
          case 'getNotificationAppLaunchDetails':
            return <String, Object?>{'notificationLaunchedApp': false};
          case 'show':
            posted.add(call.arguments as Map<dynamic, dynamic>);
            return null;
        }
        return null;
      });
      final sink = PluginTurnNotificationSink();

      await expectLater(sink.initialize(), throwsA(isA<PlatformException>()));
      await sink.show(
        const TurnNotification(
          id: 1,
          title: 'Ready',
          body: 'Done',
          payload: 'target',
          channel: TurnNotificationService.turnChannel,
        ),
      );

      expect(initializeCalls, 2);
      expect(posted, hasLength(1));
      expect(posted.single['payload'], 'target');
    },
  );

  test(
    'permission action retries initialization without requesting on startup',
    () async {
      var initializeCalls = 0;
      var permissionCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'initialize':
            initializeCalls++;
            if (initializeCalls == 1) {
              throw PlatformException(code: 'temporarily-unavailable');
            }
            return true;
          case 'getNotificationAppLaunchDetails':
            return <String, Object?>{'notificationLaunchedApp': false};
          case 'requestNotificationsPermission':
            permissionCalls++;
            return true;
        }
        return null;
      });
      final sink = PluginTurnNotificationSink();

      await expectLater(sink.initialize(), throwsA(isA<PlatformException>()));
      expect(permissionCalls, 0);
      expect(await sink.requestPermission(), isTrue);

      expect(initializeCalls, 2);
      expect(permissionCalls, 1);
    },
  );

  test('launch-detail failure leaves initialization retryable', () async {
    var initializeCalls = 0;
    var launchReads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'initialize':
          initializeCalls++;
          return true;
        case 'getNotificationAppLaunchDetails':
          launchReads++;
          if (launchReads == 1) {
            throw PlatformException(code: 'temporarily-unavailable');
          }
          return <String, Object?>{'notificationLaunchedApp': false};
      }
      return null;
    });
    final sink = PluginTurnNotificationSink();

    await expectLater(sink.initialize(), throwsA(isA<PlatformException>()));
    await sink.initialize();

    expect(initializeCalls, 2);
    expect(launchReads, 2);
  });

  test('concurrent callers share one plugin initialization attempt', () async {
    final gate = Completer<void>();
    var initializeCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'initialize':
          initializeCalls++;
          await gate.future;
          return true;
        case 'getNotificationAppLaunchDetails':
          return <String, Object?>{'notificationLaunchedApp': false};
      }
      return null;
    });
    final sink = PluginTurnNotificationSink();

    final first = sink.initialize();
    final second = sink.initialize();
    await Future<void>.delayed(Duration.zero);
    expect(initializeCalls, 1);
    gate.complete();
    await Future.wait([first, second]);
  });

  test('successful initialization reads a cold launch only once', () async {
    var initializeCalls = 0;
    var launchReads = 0;
    final opened = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'initialize':
          initializeCalls++;
          return true;
        case 'getNotificationAppLaunchDetails':
          launchReads++;
          return <String, Object?>{
            'notificationLaunchedApp': true,
            'notificationResponse': <String, Object?>{
              'notificationId': 1,
              'actionId': null,
              'input': null,
              'notificationResponseType': 0,
              'payload': 'cold-target',
            },
          };
        case 'show':
          return null;
      }
      return null;
    });
    final sink = PluginTurnNotificationSink(onOpen: opened.add);

    await sink.initialize();
    await sink.initialize();
    await sink.show(
      const TurnNotification(
        id: 1,
        title: 'Ready',
        body: 'Done',
        payload: 'target',
        channel: TurnNotificationService.turnChannel,
      ),
    );

    expect(initializeCalls, 1);
    expect(launchReads, 1);
    expect(opened, ['cold-target']);
  });
}

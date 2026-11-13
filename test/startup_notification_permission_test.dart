import 'package:wing/core/services/app_preferences.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/main.dart';
import 'package:wing/core/services/native_notification_sink.dart';
import 'package:wing/core/services/android_voice.dart';
import 'package:wing/core/services/microphone_permission.dart';
import 'package:wing/core/services/background_monitoring_service.dart';

import 'profile_connection_identity_test.dart' show MemoryIdentityStore;

const _nativeNotifications = MethodChannel(NativeNotificationSink.channelName);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late ConnectionManager manager;
  late List<String> calls;
  late bool enabled;
  late bool granted;
  late bool failRequest;
  late bool batteryUnrestricted;

  setUp(() async {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    SharedPreferences.setMockInitialValues({});
    manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
      credentialStore: MemoryIdentityStore(),
    );
    calls = [];
    enabled = false;
    granted = true;
    failRequest = false;
    batteryUnrestricted = true;
    messenger.setMockMethodCallHandler(BackgroundMonitoringService.channel, (
      call,
    ) async {
      if (call.method == 'batteryUnrestricted' ||
          call.method == 'openBatterySettings') {
        calls.add(call.method);
      }
      return call.method == 'batteryUnrestricted' ? batteryUnrestricted : null;
    });
    messenger.setMockMethodCallHandler(_nativeNotifications, (call) async {
      if (call.method == 'show') calls.add('show');
      return call.method == 'initialize' ? [] : null;
    });
    messenger.setMockMethodCallHandler(AndroidVoice.channel, (call) async {
      if (call.method == 'requestPermission') {
        calls.add('microphone');
        return granted;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'initialize':
          return true;
        case 'getNotificationAppLaunchDetails':
          return {'notificationLaunchedApp': false};
        case 'areNotificationsEnabled':
          return enabled;
        case 'requestNotificationsPermission':
          if (failRequest) throw PlatformException(code: 'unavailable');
          enabled = granted;
          return granted;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_nativeNotifications, null);
    messenger.setMockMethodCallHandler(AndroidVoice.channel, null);
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(
      BackgroundMonitoringService.channel,
      null,
    );
  });

  Future<void> launch(WidgetTester tester) async {
    final appPreferences = AppPreferences(manager.prefs);
    addTearDown(appPreferences.dispose);
    await tester.pumpWidget(
      WingApp(connManager: manager, appPreferences: appPreferences),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  testWidgets(
    'startup requests missing battery exemption without active chats',
    (tester) async {
      batteryUnrestricted = false;
      granted = false;
      await launch(tester);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(
        calls.where((call) => call == 'openBatterySettings'),
        hasLength(1),
      );
      expect(
        calls.indexOf('batteryUnrestricted'),
        greaterThan(calls.indexOf('microphone')),
      );
      expect(
        calls.indexOf('openBatterySettings'),
        greaterThan(calls.indexOf('batteryUnrestricted')),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        calls.where((call) => call == 'openBatterySettings'),
        hasLength(1),
      );
      await close(tester);
      await launch(tester);
      expect(
        calls.where((call) => call == 'openBatterySettings'),
        hasLength(2),
      );
      await close(tester);
      batteryUnrestricted = true;
      await launch(tester);
      expect(
        calls.where((call) => call == 'batteryUnrestricted'),
        hasLength(3),
      );
      expect(
        calls.where((call) => call == 'openBatterySettings'),
        hasLength(2),
      );
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'microphone follows notifications and is not requested again on restart',
    (tester) async {
      granted = false;
      await launch(tester);
      expect(calls.where((call) => call == 'microphone'), hasLength(1));
      expect(
        calls.indexOf('microphone'),
        greaterThan(calls.indexOf('requestNotificationsPermission')),
      );
      expect(manager.prefs.getBool(microphonePermissionRequestedKey), true);
      await close(tester);
      await launch(tester);
      expect(calls.where((call) => call == 'microphone'), hasLength(1));
      await close(tester);
    },
  );

  for (final allow in [true, false]) {
    testWidgets(
      'first launch requests permission once when ${allow ? 'allowed' : 'denied'}',
      (tester) async {
        granted = allow;
        await launch(tester);

        expect(find.byType(HomeScreen), findsOneWidget);
        expect(
          calls.where((method) => method == 'requestNotificationsPermission'),
          hasLength(1),
        );
        expect(calls, isNot(contains('show')));
        expect(tester.takeException(), isNull);

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        await close(tester);
        await launch(tester);
        expect(
          calls.where((method) => method == 'requestNotificationsPermission'),
          hasLength(1),
        );

        // The same action supplied to App settings remains usable after denial.
        granted = true;
        final action = tester
            .state<WingAppState>(find.byType(WingApp))
            .enableProfileNotifications();
        await tester.pumpAndSettle();
        await action;
        expect(calls, contains('show'));
        await close(tester);
      },
    );
  }

  testWidgets('already enabled notifications do not request permission', (
    tester,
  ) async {
    enabled = true;
    await launch(tester);
    expect(calls, isNot(contains('requestNotificationsPermission')));
    await close(tester);
    enabled =
        false; // Revoking in system settings must not trigger startup nags.
    await launch(tester);
    expect(calls, isNot(contains('requestNotificationsPermission')));
    await close(tester);
  });

  testWidgets('platform failure keeps startup usable and retries next launch', (
    tester,
  ) async {
    failRequest = true;
    await launch(tester);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
    failRequest = false;
    await launch(tester);
    expect(
      calls.where((method) => method == 'requestNotificationsPermission'),
      hasLength(2),
    );
    await close(tester);
  });

  testWidgets('waits for startup readiness and ignores a disposed app', (
    tester,
  ) async {
    final ready = Completer<void>();
    final appPreferences = AppPreferences(manager.prefs);
    addTearDown(appPreferences.dispose);
    await tester.pumpWidget(
      WingApp(
        connManager: manager,
        appPreferences: appPreferences,
        startupExternalNavigationReady: ready.future,
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    await close(tester);
    ready.complete();
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

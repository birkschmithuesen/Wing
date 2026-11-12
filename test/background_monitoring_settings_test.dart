import 'dart:async';

import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/voice_preferences_session.dart';
import 'package:wing/core/services/android_voice.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/app_settings_content.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import 'profile_notification_coverage_test.dart' show NotificationCoverageHost;
import 'package:wing/core/services/background_monitoring_service.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_error.dart';
import 'support/form_family_capture.dart';

void main() {
  setUpAll(loadFormFamilyFonts);
  testWidgets(
    'connected workspace settings expose monitoring and battery controls',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      PackageInfo.setMockInitialValues(
        appName: 'Wing',
        packageName: 'com.tarkilhk.wing',
        version: '1',
        buildNumber: '1',
        buildSignature: '',
      );
      final host = NotificationCoverageHost();
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'host',
            label: 'Host',
            host: 'localhost',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'monitoring-settings',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
      );
      await controller.initialize();
      addTearDown(controller.dispose);
      final state = ValueNotifier(BackgroundMonitoringState.batteryRestricted);
      addTearDown(state.dispose);
      var requests = 0;
      var retries = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            createBotsSession: () => BotsSession((_) async => const []),
            controller: controller,
            initialDestination: AppDestination.settings,
            enableNotifications: () async {},
            backgroundMonitoringState: state,
            retryBackgroundMonitoring: () async {
              retries++;
              state.value = BackgroundMonitoringState.active;
            },
            openMonitoringBatterySettings: () async => requests++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final battery = find.text('Allow background activity');
      await tester.scrollUntilVisible(battery, 350);
      await tester.pumpAndSettle();
      expect(find.text('Monitor in background'), findsNothing);
      await tester.tap(battery);
      await tester.pumpAndSettle();
      expect(requests, 1);
      state.value = BackgroundMonitoringState.disabled;
      await tester.pumpAndSettle();
      expect(find.text('Notifications may be delayed.'), findsNothing);
      state.value = BackgroundMonitoringState.permissionRequired;
      await tester.pumpAndSettle();
      expect(find.text('Enable notifications'), findsOneWidget);
      state.value = BackgroundMonitoringState.failed;
      await tester.pumpAndSettle();
      final retry = find.byTooltip('Retry background monitoring');
      await tester.ensureVisible(retry);
      await tester.pumpAndSettle();
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(retries, 1);
      expect(find.text('Background notifications paused.'), findsNothing);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('monitoring failure and retry ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(preferences);
        addTearDown(appPreferences.dispose);
        PackageInfo.setMockInitialValues(
          appName: 'Wing',
          packageName: 'com.tarkilhk.wing',
          version: '1',
          buildNumber: '1',
          buildSignature: '',
        );
        final state = ValueNotifier(BackgroundMonitoringState.failed);
        addTearDown(state.dispose);
        var held = Completer<void>();
        var retries = 0;
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: RepaintBoundary(key: formFamilyCapture, child: child!),
            ),
            home: Scaffold(
              appBar: AppBar(title: const Text('App settings')),
              body: AppSettingsContent(
                pluginServer: null,
                preferences: appPreferences,
                createVoiceSession: () => VoicePreferencesSession(
                  preferences: appPreferences,
                  device: AndroidVoice.instance,
                  hermesProfileLabel: null,
                  openHermesSettings: null,
                ),
                onChanged: () {},
                enableNotifications: () async {},
                backgroundMonitoringState: state,
                retryBackgroundMonitoring: () async {
                  retries++;
                  await held.future;
                },
              ),
            ),
          ),
        );
        final retry = find.byTooltip('Retry background monitoring');
        final notice = find.widgetWithText(
          StudioError,
          'Background notifications paused.',
        );
        final frame = find.ancestor(
          of: notice,
          matching: find.byType(StudioErrorFrame),
        );
        await tester.ensureVisible(frame);
        await tester.pumpAndSettle();
        expect(notice.hitTestable(), findsOneWidget);
        expect(retry.hitTestable(), findsOneWidget);
        final name = '${brightness.name}-$scale';
        await captureFormFamily(tester, 'error-screen-monitoring-$name');
        await tester.tap(retry);
        await tester.pump();
        expect(retries, 1);
        expect(
          find.bySemanticsLabel('Retrying background monitoring'),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel('Retrying background monitoring'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<IconButton>(
                find.ancestor(
                  of: find.bySemanticsLabel('Retrying background monitoring'),
                  matching: find.byType(IconButton),
                ),
              )
              .onPressed,
          isNull,
        );
        await captureFormFamily(
          tester,
          'error-screen-monitoring-pending-$name',
        );
        held.complete();
        await tester.pumpAndSettle();
        expect(notice, findsOneWidget);
        expect(
          find.bySemanticsLabel('Retrying background monitoring'),
          findsNothing,
        );
        held = Completer<void>();
        await tester.tap(retry);
        await tester.pump();
        expect(retries, 2);
        state.value = BackgroundMonitoringState.active;
        held.complete();
        await tester.pumpAndSettle();
        expect(notice, findsNothing);
        expect(retry, findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

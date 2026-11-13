import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/services/voice_preferences_session.dart';
import 'package:wing/core/services/android_voice.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:flutter/material.dart';
import 'package:wing/core/widgets/compact_switch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/app_settings_content.dart';

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Hermes',
      packageName: 'asia.hollinger.hermes',
      version: '2.9.0',
      buildNumber: '2158',
      buildSignature: '',
      installerStore: '',
    );
  });

  testWidgets('notification controls persist independently on this device', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    var permissionRequests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
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
            enableNotifications: () async {
              permissionRequests++;
            },
          ),
        ),
      ),
    );
    final completion = find.widgetWithText(
      CompactSwitchListTile,
      'Completed work',
    );
    // Scroll to the target, independent of the sections following it.
    await tester.scrollUntilVisible(completion, 300);
    await tester.pumpAndSettle();
    expect(completion.hitTestable(), findsOneWidget);
    await tester.tap(completion);
    await tester.pumpAndSettle();
    expect(
      preferences.getBool(AppPreferenceField.completedNotifications.storageKey),
      isFalse,
    );
    expect(
      tester
          .widget<CompactSwitchListTile>(
            find.widgetWithText(CompactSwitchListTile, 'Needs attention'),
          )
          .value,
      isTrue,
    );
    expect(permissionRequests, 0);
    final previews = find.widgetWithText(
      CompactSwitchListTile,
      'Show message previews',
    );
    await tester.scrollUntilVisible(previews, 250);
    await tester.pumpAndSettle();
    expect(previews.hitTestable(), findsOneWidget);
    expect(tester.widget<CompactSwitchListTile>(previews).value, isTrue);
    await tester.tap(previews);
    await tester.pumpAndSettle();
    expect(
      preferences.getBool(AppPreferenceField.notificationPreviews.storageKey),
      isFalse,
    );
    final permission = find.text('Test notification');
    await tester.scrollUntilVisible(permission, 250);
    await tester.pumpAndSettle();
    expect(permission.hitTestable(), findsOneWidget);
    await tester.tap(permission);
    await tester.pumpAndSettle();
    expect(permissionRequests, 1);
    expect(
      preferences.getBool(AppPreferenceField.completedNotifications.storageKey),
      isFalse,
    );
  });
}

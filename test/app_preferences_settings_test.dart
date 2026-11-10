import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/screens/app_settings_content.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/voice_preferences_session.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'support/voice_fixture.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/main.dart';
import 'profile_connection_identity_test.dart' show MemoryIdentityStore;

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Wing',
      packageName: 'com.tarkilhk.wing',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });
  testWidgets(
    'link preference shows pending save and keeps the confirmed choice on failure',
    (tester) async {
      SharedPreferences.resetStatic();
      final platform = _HeldLinkPreference();
      SharedPreferencesStorePlatform.instance = platform;
      final owner = AppPreferences(await SharedPreferences.getInstance());
      addTearDown(() {
        owner.dispose();
        SharedPreferences.setMockInitialValues({});
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(actions: const [StudioLoadingSlot()]),
            body: AppSettingsContent(
              pluginServer: null,
              preferences: owner,
              createVoiceSession: () => VoicePreferencesSession(
                preferences: owner,
                device: VoiceDeviceFixture(),
                hermesProfileLabel: null,
                openHermesSettings: null,
              ),
              onChanged: () {},
            ),
          ),
        ),
      );
      final choices = find.byKey(const ValueKey('link-destination'));
      Future<void> chooseBrowser() async {
        await tester.tap(choices);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open in external browser'));
      }

      await tester.ensureVisible(choices);
      await tester.pumpAndSettle();
      await chooseBrowser();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(StudioLoading), findsOneWidget);
      expect(
        tester.widget<PopupMenuButton<WebLinkDestination>>(choices).enabled,
        isFalse,
      );
      expect(
        tester
            .widget<PopupMenuButton<WebLinkDestination>>(choices)
            .initialValue,
        WebLinkDestination.wing,
      );
      expect(
        owner.current.preferredWebLinkDestination,
        WebLinkDestination.wing,
      );
      platform.reply.complete(false);
      await tester.pumpAndSettle();
      expect(find.byType(StudioLoading), findsNothing);
      expect(
        find.text('Could not save the setting. Please retry.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<PopupMenuButton<WebLinkDestination>>(choices)
            .initialValue,
        WebLinkDestination.wing,
      );
      await chooseBrowser();
      await tester.pumpAndSettle();
      expect(
        owner.current.preferredWebLinkDestination,
        WebLinkDestination.externalBrowser,
      );
    },
  );

  testWidgets(
    'unverified save exposes an explicit owner reload before repair',
    (tester) async {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = _UnconfirmedWrites();
      final prefs = await SharedPreferences.getInstance();
      final owner = AppPreferences(prefs);
      addTearDown(() {
        owner.dispose();
        SharedPreferences.setMockInitialValues({});
      });
      await expectLater(
        owner.setTheme(AppThemePreference.light),
        throwsA(isA<AppPreferenceSaveException>()),
      );
      expect(owner.current.unverified, {AppPreferenceField.theme});
      expect(owner.current.theme.choose, isNull);
      expect(owner.current.values.theme, AppThemePreference.dark);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppSettingsContent(
              pluginServer: null,
              preferences: owner,
              createVoiceSession: () => VoicePreferencesSession(
                preferences: owner,
                device: VoiceDeviceFixture(),
                hermesProfileLabel: null,
                openHermesSettings: null,
              ),
              onChanged: () {},
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('theme-dark')))
            .onSelected,
        isNull,
      );
      expect(find.text('Reload settings'), findsOneWidget);
      await tester.tap(find.text('Reload settings'));
      await tester.pumpAndSettle();
      expect(owner.current.unverified, isEmpty);
      expect(owner.current.storageVerified, isTrue);
      expect(owner.current.theme.selected, AppThemePreference.dark);
      expect(
        owner.current.theme.error,
        isNull,
        reason: 'a freshly verified setting must not demand another reload',
      );
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('theme-dark')))
            .onSelected,
        isNotNull,
      );
      expect(prefs.getString('theme_mode'), 'dark');
    },
  );
  testWidgets(
    'invalid appearance has no selected choices and repairs only chosen fields',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'theme_mode': 'wrong',
        'workspace_accent_v1': 'mint',
        'app_text_size_preference': 7,
        'plugin.cache': 'kept',
      });
      final prefs = await SharedPreferences.getInstance();
      final owner = AppPreferences(prefs);
      addTearDown(owner.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppSettingsContent(
              pluginServer: null,
              preferences: owner,
              createVoiceSession: () => VoicePreferencesSession(
                preferences: owner,
                device: VoiceDeviceFixture(),
                hermesProfileLabel: null,
                openHermesSettings: null,
              ),
              onChanged: () {},
            ),
          ),
        ),
      );
      for (final key in [
        'theme-system',
        'theme-light',
        'theme-dark',
        'accent-teal',
        'accent-iris',
        'accent-glacier',
        'accent-coral',
        'accent-gold',
      ]) {
        expect(
          tester.widget<ChoiceChip>(find.byKey(ValueKey(key))).selected,
          isFalse,
        );
      }
      expect(prefs.getString('workspace_accent_v1'), 'mint');
      await tester.tap(find.byKey(const ValueKey('theme-dark')));
      await tester.pumpAndSettle();
      expect(owner.current.theme.selected, AppThemePreference.dark);
      expect(prefs.getString('theme_mode'), 'dark');
      expect(prefs.get('app_text_size_preference'), 7);
      await tester.tap(find.byKey(const ValueKey('accent-teal')));
      await tester.pumpAndSettle();
      expect(prefs.getString('workspace_accent_v1'), 'teal');
      expect(owner.current.textSize.selected, isNull);
      expect(prefs.getString('plugin.cache'), 'kept');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'initial invalid framework appearance displays explicit repair and preserves saved value',
    (tester) async {
      SharedPreferences.setMockInitialValues({'theme_mode': 'wrong'});
      final prefs = await SharedPreferences.getInstance();
      final owner = AppPreferences(prefs);
      addTearDown(owner.dispose);
      final manager = await ConnectionManager.create(
        prefs,
        credentialStore: MemoryIdentityStore(),
      );
      await tester.pumpWidget(
        WingApp(connManager: manager, appPreferences: owner),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('app-preference-repair')),
        findsOneWidget,
      );
      expect(prefs.getString('theme_mode'), 'wrong');
      await tester.tap(find.byKey(const ValueKey('app-preference-repair')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('theme-system')))
            .selected,
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('theme-dark')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('app-preference-repair')), findsNothing);
      expect(owner.current.theme.selected, AppThemePreference.dark);
      expect(prefs.getString('theme_mode'), 'dark');
      expect(tester.takeException(), isNull);
    },
  );
}

class _UnconfirmedWrites extends InMemorySharedPreferencesStore {
  _UnconfirmedWrites() : super.withData({'flutter.theme_mode': 'dark'});
  @override
  Future<bool> setValue(String valueType, String key, Object value) =>
      Future.value(false);
}

class _HeldLinkPreference extends InMemorySharedPreferencesStore {
  _HeldLinkPreference() : super.withData({});

  final reply = Completer<bool>();

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key == 'flutter.web_link_destination' && !reply.isCompleted) {
      return reply.future;
    }
    return super.setValue(valueType, key, value);
  }
}

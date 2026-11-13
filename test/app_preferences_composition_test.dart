import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/screens/app_settings_content.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_manager.dart'
    show ConnectionManager, CredentialStore;
import 'package:wing/main.dart';
import 'package:wing/core/widgets/web_link_scope.dart';

class _Credentials implements CredentialStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  testWidgets(
    'the app shares injected preferences and retiring settings leaves the owner usable',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'theme_mode': 'light',
        'notification_permission_requested': true,
        'microphone_permission_requested': true,
      });
      PackageInfo.setMockInitialValues(
        appName: 'Wing',
        packageName: 'com.tarkilhk.wing',
        version: 'fixture',
        buildNumber: '1',
        buildSignature: '',
      );
      late AppPreferences owner;
      late ConnectionManager manager;
      await tester.runAsync(() async {
        final storage = await SharedPreferences.getInstance();
        owner = AppPreferences(storage);
        manager = await ConnectionManager.create(
          storage,
          credentialStore: _Credentials(),
        );
      });
      await tester.pumpWidget(
        WingApp(connManager: manager, appPreferences: owner),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.light,
      );

      final dark = owner.setTheme(AppThemePreference.dark);
      await tester.pumpAndSettle();
      await dark;
      // Public rendered app facts first: a second cached owner would remain light.
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      expect(
        tester.widget<HomeScreen>(find.byType(HomeScreen)).appPreferences,
        same(owner),
      );

      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(AppSettingsContent), findsOneWidget);
      expect(
        tester
            .widget<AppSettingsContent>(find.byType(AppSettingsContent))
            .preferences,
        same(owner),
      );
      final linkDestination = find.byKey(const ValueKey('link-destination'));
      await tester.ensureVisible(linkDestination);
      await tester.tap(linkDestination);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open in external browser'));
      await tester.pumpAndSettle();
      expect(
        WebLinkScope.destinationOf(tester.element(find.byType(HomeScreen))),
        WebLinkDestination.externalBrowser,
      );
      final storage = await SharedPreferences.getInstance();
      expect(storage.getString('web_link_destination'), 'externalBrowser');
      final reopened = AppPreferences(storage);
      addTearDown(reopened.dispose);
      expect(
        reopened.current.preferredWebLinkDestination,
        WebLinkDestination.externalBrowser,
      );

      // Remove the borrowing settings consumer through normal navigation while
      // retaining the owning app root. Disposing WingApp itself closes its owner.
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-connections')));
      await tester.pumpAndSettle();
      expect(find.byType(AppSettingsContent), findsNothing);
      final light = owner.setTheme(AppThemePreference.light);
      await tester.pumpAndSettle();
      await light;
      expect(owner.current.theme.selected, AppThemePreference.light);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.light,
      );
      expect(
        tester.widget<HomeScreen>(find.byType(HomeScreen)).appPreferences,
        same(owner),
      );
      expect(tester.takeException(), isNull);
      // Consumer-first root disposal remains the production lifetime contract.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}

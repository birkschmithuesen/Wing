import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/connection_setup_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/connection_setup_session.dart';
import 'package:wing/core/services/hermes_cloud.dart';
import 'package:wing/core/theme/wing_theme.dart';

import '../test/support/connection_probe_fixture.dart';

/// Only network verification is supplied. Metadata and credentials cross the
/// production Android preferences/secure-storage plugins, including a fresh read.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets(
    'setup saves credentials in Android secure storage and reopens them',
    (tester) async {
      final nonce = DateTime.now().microsecondsSinceEpoch.toString();
      final label = 'Secure setup $nonce';
      final password = 'synthetic-password-$nonce';
      final preferences = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(preferences);
      SavedConnection? saved;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await manager.initialize();
        for (final connection in manager.getConnections().where(
          (connection) => connection.label == label,
        )) {
          await manager.deleteConnection(connection.id);
        }
      });
      final probe = ConnectionProbeFixture();
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.light),
          home: ConnectionSetupScreen(
            createSession: () => ConnectionSetupSession(
              initialAccess: null,
              savedConnections: manager.getConnections,
              cloud: HermesCloud(),
              onSaveIcon: null,
              createProbe: (_) => probe,
              onSave: (candidate) async {
                final result = await manager.saveConnection(
                  candidate.label,
                  candidate.baseUrl,
                  candidate.port,
                  '',
                  icon: candidate.icon,
                  dashboardPrefix: candidate.dashboardPrefix,
                  dashboardProxied: candidate.dashboardProxied,
                  desktopGatewayUrl: candidate.desktopGatewayUrl,
                  dashboardPort: candidate.dashboardPort,
                  dashboardUsername: candidate.dashboardUsername,
                  dashboardPassword: candidate.dashboardPassword,
                  dashboardGrant: candidate.dashboardGrant,
                  cloudInstanceId: candidate.cloudInstanceId,
                  cloudOrganization: candidate.cloudOrganization,
                  gatewayHeaders: candidate.gatewayHeaders,
                );
                saved = result;
                return result;
              },
            ),
          ),
        ),
      );
      Future<void> tap(Finder control) async {
        void trace(String stage) => debugPrintSynchronously(
          '[secure-setup-native] ${control.describeMatch(Plurality.many)}: $stage',
        );
        trace('pre-settle started');
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 15),
        );
        trace('pre-settle completed');
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        do {
          trace('ensure-visible started');
          await tester.ensureVisible(control);
          trace('ensure-visible completed; frame started');
          await tester.pump(const Duration(milliseconds: 100));
          trace('frame completed');
        } while (control.hitTestable().evaluate().isEmpty &&
            DateTime.now().isBefore(deadline));
        expect(control.hitTestable(), findsOneWidget);
        trace('tap started');
        await tester.tap(control);
        trace('tap completed; post-settle started');
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 15),
        );
        trace('post-settle completed');
      }

      await tap(find.text('Use an address'));
      await tester.enterText(
        find.byKey(const Key('connection-address')),
        'https://setup-$nonce.invalid/agent/',
      );
      await tap(find.text('Next'));
      await tester.enterText(
        find.byKey(const Key('connection-username')),
        'qa-user',
      );
      debugPrintSynchronously('[secure-setup-native] password entry started');
      await tester.enterText(
        find.byKey(const Key('connection-password')),
        password,
      );
      debugPrintSynchronously('[secure-setup-native] password entry completed');
      await tap(find.text('Check connection'));
      expect(find.byKey(const Key('connection-username')), findsOneWidget);
      await tap(find.text('Next'));
      expect(find.text('Connection verified'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('connection-name')), label);
      await tap(find.byTooltip('Save and open'));
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (saved == null && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(saved, isNotNull, reason: 'The actual setup save must complete');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await preferences.reload();
      // A fresh wrapper prevents ConnectionManager's per-store snapshot from
      // satisfying this read without crossing the Android credential boundary.
      final reopened = await ConnectionManager.create(
        preferences,
        credentialStore: FlutterSecureCredentialStore(),
      );
      final restored = reopened.getConnections().singleWhere(
        (connection) => connection.id == saved!.id,
      );
      expect(restored.label, label);
      expect(restored.host, 'setup-$nonce.invalid');
      expect(restored.useHttps, isTrue);
      expect(restored.dashboardPrefix, '/agent');
      expect(restored.dashboardUsername, 'qa-user');
      expect(restored.dashboardPassword, password);
      expect(
        preferences
            .getKeys()
            .map((key) => preferences.get(key).toString())
            .join('\n'),
        isNot(contains(password)),
        reason:
            'Connection secrets must not be stored in ordinary Android preferences',
      );
    },
  );
}

import 'package:wing/core/services/shared_draft_session.dart';
import 'package:wing/core/services/workspace_entry_session.dart';
import 'package:wing/core/services/profile_workspace_registry.dart';
import 'package:wing/core/services/profile_connection_identity.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/backup_session.dart';
import 'package:wing/core/services/config_backup_service.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/models/composer_action.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/theme/app_preferences_rendering.dart';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/config_backup.dart';
import 'package:wing/core/services/config_backup_io.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/compact_switch.dart';
import 'package:wing/main.dart';

class _CheckedBackupIo extends ConfigBackupIo {
  _CheckedBackupIo(this.expectedFormat);
  final String expectedFormat;

  @override
  Future<String?> pickBackupFile() async {
    final contents = await super.pickBackupFile();
    expect(contents, isNotNull);
    expect(
      jsonDecode(contents!)['format'],
      expectedFormat,
      reason: 'Select the backup exported in this test iteration.',
    );
    return contents;
  }
}

// Run only on a disposable emulator. This uses real Android preferences,
// Keystore, sharing and document picking. When backup-qa-stage in the app's
// external files directory says share-*, save the shared JSON to Downloads.
// At pick-*, select that file in Android's document picker. A host UI driver
// can perform these native steps; Flutter's tester cannot tap other apps.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('CONFIG_BACKUP_NATIVE');
  if (enabled) SharedPreferences.setPrefix('backup_qa.');
  const expected = <String, Object>{
    'theme_mode': 'dark',
    'workspace_accent_v1': 'iris',
    'app_text_size_preference': 'large',
    'composer_running_action': 'queue',
    'completion_notifications': false,
    'attention_notifications': true,
    'notification_message_previews': false,
    'voice.input': 'local',
    'voice.output': 'hermes',
    'voice.android_language': 'en-US',
    'voice.android_voice': 'en-us-x-iom-local',
    'voice.android_rate': '1.2',
  };
  const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(storageNamespace: 'wing_backup_qa'),
  );

  File? stageFile;
  tearDownAll(() async {
    final stage = stageFile;
    if (stage != null && await stage.exists()) await stage.delete();
  });

  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (!done() && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(done(), isTrue, reason: 'Native backup/restore step timed out.');
    await tester.pumpAndSettle();
  }

  Future<void> navigate(WidgetTester tester, String destination) async {
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('nav-$destination')));
    await tester.pumpAndSettle();
  }

  for (final encrypted in [false, true]) {
    testWidgets(
      'native ${encrypted ? 'encrypted replace' : 'plain merge'} backup round trip',
      (tester) async {
        final prefs = await SharedPreferences.getInstance();
        File? ownedExport;
        Directory? exportDirectory;
        Set<String>? exportBaseline;
        Set<String>? exportStageBaseline;
        addTearDown(() async {
          await prefs.clear();
          await storage.deleteAll();
          expect(prefs.getKeys(), isEmpty);
          expect(await storage.readAll(), isEmpty);
          final exported = ownedExport;
          if (exported != null && await exported.exists()) {
            await exported.delete();
          }
          final directory = exportDirectory;
          final baseline = exportBaseline;
          if (directory != null && baseline != null) {
            for (final file
                in directory
                    .listSync(recursive: true, followLinks: false)
                    .whereType<File>()) {
              if (file.uri.pathSegments.last.startsWith('wing-config-') &&
                  !baseline.contains(file.path)) {
                await file.delete();
              }
            }
          }
          final stageBaseline = exportStageBaseline;
          if (directory != null && stageBaseline != null) {
            final ownedStages = directory
                .listSync(followLinks: false)
                .whereType<Directory>()
                .where(
                  (stage) =>
                      stage.uri.pathSegments
                          .where((part) => part.isNotEmpty)
                          .last
                          .startsWith('wing-backup-') &&
                      !stageBaseline.contains(stage.path),
                )
                .toList();
            for (final stage in ownedStages) {
              await stage.delete(recursive: true);
              expect(
                await stage.exists(),
                isFalse,
                reason: 'Owned export stage must be removed.',
              );
            }
          }
        });
        await prefs.clear();
        await storage.deleteAll();
        final manager = await ConnectionManager.create(
          prefs,
          credentialStore: FlutterSecureCredentialStore(storage: storage),
        );
        for (final entry in expected.entries) {
          switch (entry.value) {
            case final String value:
              await prefs.setString(entry.key, value);
            case final bool value:
              await prefs.setBool(entry.key, value);
            case final double value:
              await prefs.setDouble(entry.key, value);
          }
        }
        final appPreferences = AppPreferences(prefs);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          appPreferences.dispose();
        });
        await prefs.setBool('notification_permission_requested', true);
        final saved = await manager.saveConnection(
          'Backup QA instance',
          'https://backup-qa.invalid',
          8642,
          'qa-api-key',
          icon: ConnectionIcon.rocket,
          dashboardUsername: 'qa-user',
          dashboardPassword: 'qa-password',
          gatewayHeaders: {'X-QA': 'qa-header'},
        );
        final stage = File(
          '${(await getExternalStorageDirectory())!.path}/backup-qa-stage',
        );
        stageFile = stage;
        final label = encrypted ? 'encrypted' : 'plain';
        final passphrase = encrypted ? 'emulator-backup-passphrase' : '';
        final registry = ProfileWorkspaceRegistry(
          identities: ProfileConnectionIdentity(),
          create: (connection, identity) => ProfileWorkspaceController(
            access: manager.accessFor(connection),
            connectionIdentity: identity,
            preferences: prefs,
            appPreferences: appPreferences,
          ),
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          registry.dispose();
        });
        final home = GlobalKey<HomeScreenState>();
        Future<void> show() async {
          await tester.pumpWidget(
            ValueListenableBuilder<AppPreferencesState>(
              valueListenable: appPreferences.state,
              builder: (context, state, child) => MaterialApp(
                themeMode: state.values.theme!.themeMode,
                theme: profileWorkspaceTheme(
                  wingTheme(Brightness.light),
                  accent: state.values.accent!.appearance,
                ),
                darkTheme: profileWorkspaceTheme(
                  wingTheme(Brightness.dark),
                  accent: state.values.accent!.appearance,
                ),
                home: HomeScreen(
                  createSharedDraftSession: (entry) => SharedDraftSession(
                    connectionManager: manager,
                    entrySession: entry,
                    shareIntents: null,
                  ),
                  createEntrySession: () => WorkspaceEntrySession(
                    connectionManager: manager,
                    appPreferences: appPreferences,
                    registry: registry,
                    launchIntents: null,
                  ),
                  key: home,
                  connManager: manager,
                  appPreferences: appPreferences,
                  createBackupSession: () => BackupSession(
                    configuration: ConfigBackupService(
                      connectionManager: manager,
                      appPreferences: appPreferences,
                    ),
                    io: _CheckedBackupIo(
                      encrypted ? 'wing-config-encrypted' : 'wing-config',
                    ),
                  ),
                  enableProfileNotifications: () async {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        await show();
        await navigate(tester, 'settings');
        await tester.tap(find.byTooltip('Backup configuration'));
        await tester.pumpAndSettle();
        if (encrypted) {
          await tester.enterText(
            find.byKey(const Key('export_passphrase_field')),
            passphrase,
          );
          await tester.enterText(
            find.byKey(const Key('export_passphrase_confirm_field')),
            passphrase,
          );
        }
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        final cache = await getTemporaryDirectory();
        final previousExports = cache
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where(
              (file) => file.uri.pathSegments.last.startsWith('wing-config-'),
            )
            .map((file) => file.path)
            .toSet();
        exportDirectory = cache;
        exportBaseline = previousExports;
        exportStageBaseline = cache
            .listSync(followLinks: false)
            .whereType<Directory>()
            .map((directory) => directory.path)
            .toSet();
        await stage.writeAsString('share-$label', flush: true);
        await tester.tap(find.byKey(const Key('export_confirm_button')));
        await waitFor(
          tester,
          () => find.textContaining('Backup exported').evaluate().isNotEmpty,
        );
        final remainingStages = cache
            .listSync(followLinks: false)
            .whereType<Directory>()
            .where(
              (directory) =>
                  directory.uri.pathSegments
                      .where((part) => part.isNotEmpty)
                      .last
                      .startsWith('wing-backup-') &&
                  !exportStageBaseline!.contains(directory.path),
            );
        expect(
          remainingStages,
          isEmpty,
          reason: 'Wing must release its export stage after Android handoff.',
        );
        final exported = cache
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where(
              (file) =>
                  file.uri.pathSegments.last.startsWith('wing-config-') &&
                  !previousExports.contains(file.path),
            )
            .toList();
        expect(
          exported,
          hasLength(1),
          reason: 'One recipient-provider backup remains after Wing cleanup.',
        );
        ownedExport = exported.single;
        expect(ownedExport.parent.path, endsWith('/share_plus'));
        final contents = await ownedExport.readAsString();
        final decoded = await ConfigBackupCodec.decode(
          contents,
          passphrase: passphrase,
        );
        expect(decoded.preferences, expected);
        expect(decoded.connections.single.apiKey, 'qa-api-key');
        if (encrypted) expect(contents, isNot(contains('qa-api-key')));

        // Replace saved settings and remove the original to prove actual
        // restoration, including overwriting true and false preference values.
        await manager.deleteConnection(saved.id);
        await manager.saveConnection(
          'Local only',
          'local.invalid',
          8642,
          'local',
        );
        await appPreferences.setTheme(AppThemePreference.light);
        await appPreferences.setAccent(AppAccentPreference.coral);
        await appPreferences.setRunningAction(ComposerAction.stop);
        await appPreferences.setCompletedNotifications(true);
        await appPreferences.setAttentionNotifications(false);
        await appPreferences.setNotificationPreviews(true);
        await appPreferences.setTextSize(AppTextSizePreference.standard);
        // Re-enter settings with the changed values cached in its controls.
        await navigate(tester, 'connections');
        home.currentState!.refreshConnections();
        await show();
        await navigate(tester, 'settings');
        expect(
          tester
              .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Coral'))
              .selected,
          isTrue,
        );

        Future<void> restore(String attempt, String password) async {
          await stage.writeAsString('pick-$label$attempt', flush: true);
          await tester.tap(find.byTooltip('Restore configuration').hitTestable());
          await waitFor(
            tester,
            () => find
                .byKey(const Key('import_passphrase_field'))
                .evaluate()
                .isNotEmpty,
          );
          await tester.enterText(
            find.byKey(const Key('import_passphrase_field')),
            password,
          );
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          if (encrypted) {
            await tester.tap(find.byKey(const Key('import_mode_replace')));
            await tester.pumpAndSettle();
          }
          await tester.tap(find.byKey(const Key('import_confirm_button')));
        }

        if (encrypted) {
          await restore('-wrong', 'wrong-passphrase');
          await waitFor(
            tester,
            () => find.textContaining('Wrong passphrase').evaluate().isNotEmpty,
          );
          expect(manager.getConnections().single.label, 'Local only');
          expect(prefs.getString('workspace_accent_v1'), 'coral');
          await tester.tap(find.byTooltip('Close').hitTestable());
          await tester.pumpAndSettle();
          expect(find.textContaining('Wrong passphrase'), findsNothing);
        }
        await restore('', passphrase);
        await waitFor(
          tester,
          () => find.textContaining('settings restored').evaluate().isNotEmpty,
        );
        await prefs.reload();
        for (final entry in expected.entries) {
          expect(prefs.get(entry.key), entry.value, reason: entry.key);
        }
        final reopened = await ConnectionManager.create(
          prefs,
          credentialStore: FlutterSecureCredentialStore(storage: storage),
        );
        final connections = await reopened.loadConnectionsWithSecrets();
        expect(connections.length, encrypted ? 1 : 2);
        final restored = connections.singleWhere((c) => c.id == saved.id);
        expect(restored.apiKey, 'qa-api-key');
        expect(restored.dashboardPassword, 'qa-password');
        expect(restored.gatewayHeaders, {'X-QA': 'qa-header'});
        expect(restored.icon, ConnectionIcon.rocket);
        expect(
          tester
              .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Iris'))
              .selected,
          isTrue,
        );
        expect(
          tester
              .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Queue'))
              .selected,
          isTrue,
        );
        expect(
          Theme.of(tester.element(find.byType(HomeScreen))).brightness,
          Brightness.dark,
        );
        for (final entry in {
          'Completed work': false,
          'Needs attention': true,
          'Show message previews': false,
        }.entries) {
          expect(
            tester
                .widget<CompactSwitchListTile>(
                  find.widgetWithText(CompactSwitchListTile, entry.key),
                )
                .value,
            entry.value,
          );
        }
        expect(tester.takeException(), isNull);
        await stage.writeAsString('done-$label', flush: true);
      },
      skip: !enabled,
      timeout: const Timeout(Duration(minutes: 8)),
    );
  }
}

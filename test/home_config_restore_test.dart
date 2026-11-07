import 'support/canonical_gateway_fixture.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/shared_draft_session.dart';
import 'package:wing/core/services/workspace_entry_session.dart';
import 'package:wing/core/services/profile_workspace_registry.dart';
import 'package:wing/core/services/profile_connection_identity.dart';
import 'dart:async';
import 'dart:convert';
import 'package:wing/core/services/backup_session.dart';
import 'package:wing/core/services/config_backup_io.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/models/composer_action.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/screens/workspace_overview_content.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/attachment_draft_service.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/services/android_launch_intent_service.dart';
import 'package:wing/core/services/android_share_intent_service.dart';
import 'package:wing/core/services/config_backup_service.dart';
import 'package:wing/core/services/config_backup.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/main.dart';
import 'package:wing/core/widgets/connection_icon_picker.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryCredentialStore implements CredentialStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    final value = values[key];
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class _MissingFileService extends AttachmentDraftService {
  @override
  Future<AttachmentDraft> prepareGenericFile({
    required String sourcePath,
    required String displayName,
    String mediaType = 'application/octet-stream',
    required Iterable<AttachmentDraft> existingDrafts,
  }) async {
    throw const AttachmentDraftException(
      'The selected file is empty or unreadable.',
    );
  }
}

Future<({ConnectionManager manager, AppPreferences appPreferences})>
createHomeFixture() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final prefs = await SharedPreferences.getInstance();
  final appPreferences = AppPreferences(prefs);
  addTearDown(appPreferences.dispose);
  final manager = await ConnectionManager.create(
    prefs,
    credentialStore: _MemoryCredentialStore(),
  );
  return (manager: manager, appPreferences: appPreferences);
}

ProfileWorkspaceController profileController(
  SavedConnection connection,
  SharedPreferences prefs,
  AppPreferences appPreferences,
) {
  final controller = ProfileWorkspaceController(
    connectionIdentity: 'test-settings-${connection.id}',
    attachmentService: _MissingFileService(),
    access: ConnectionAccess(connection: connection, dashboardOAuth: null),
    preferences: prefs,
    appPreferences: appPreferences,
    gatewayFactory: (scope) => ProfileGateway(
      scope: scope,
      discover: () async => const ProfileDiscovery(
        profiles: [HermesProfile(name: 'default')],
        currentName: 'default',
        activeName: 'default',
      ),
      get: (path, query) async => switch (path) {
        'sessions' => {
          'sessions': <Map<String, dynamic>>[],
          'offset': int.parse(query['offset']!),
          'limit': int.parse(query['limit']!),
          'total': 0,
        },
        'model/info' => <String, dynamic>{},
        'model/options' => {'providers': <Object>[]},
        'logs' => {'file': 'gui', 'lines': <String>[]},
        'sessions/stored/messages' => {
          'session_id': 'stored',
          'messages': <Map<String, dynamic>>[],
          'pagination': {
            'offset': 0,
            'limit': int.parse(query['limit']!),
            'returned': 0,
            'order': 'latest',
          },
        },
        _ => throw StateError('Unexpected home fixture GET: $path'),
      },
      rpc: (method, _) async => switch (method) {
        'session.create' => {
          ...canonicalSnapshotFields,
          'session_id': 'runtime',
          'stored_session_id': 'stored',
          'info': {'profile_name': 'default'},
        },
        'projects.tree' => {'projects': <Map<String, dynamic>>[]},
        'session.active_list' => {'sessions': <Map<String, dynamic>>[]},
        'profiles.list' => {
          'bot_mode_protocol': true,
          'install_id': 'home-fixture',
          'profiles': <Map<String, dynamic>>[],
        },
        'commands.catalog' => {'pairs': <List<String>>[]},
        _ => throw StateError('Unexpected home fixture RPC: $method'),
      },
    ),
  );
  // Home constructs the production workspace route, which discovers Bots
  // through administration separately from the chat gateway above.
  final administration = AdministrationRepository(
    connectionId: connection.id,
    connectionIdentity: controller.connectionIdentity,
    connectionLabel: connection.label,
    request: (method, path, query, body) async => throw StateError(
      'Unexpected home administration request: $method $path',
    ),
    settingsWrite: (profile, patch, canDispatch, onDispatched) async =>
        throw StateError('Unexpected home administration settings write'),
    ownedMutation:
        (method, path, query, body, canDispatch, onDispatched) async =>
            throw StateError(
              'Unexpected home administration mutation: $method $path',
            ),
    gateway: (profile) => ProfileGateway(
      scope: WorkspaceScope(
        connectionId: connection.id,
        connectionIdentity: controller.connectionIdentity,
        profileName: profile,
      ),
      discover: () async => const ProfileDiscovery(
        profiles: [HermesProfile(name: 'default')],
        currentName: 'default',
        activeName: 'default',
      ),
      get: (path, query) async =>
          throw StateError('Unexpected home administration read: $path'),
      rpc: (method, params) async => switch (method) {
        'profiles.list' => {
          'bot_mode_protocol': true,
          'install_id': controller.connectionIdentity,
          'profiles': <Map<String, dynamic>>[],
        },
        'groups.list' => {'rooms': <Map<String, dynamic>>[]},
        _ => throw StateError('Unexpected home administration RPC: $method'),
      },
    ),
  );
  addTearDown(administration.close);
  controller.healthSession(repository: administration);
  return controller;
}

class _BackupPlatform extends ConfigBackupIo {
  String? pickedContents;
  String? deliveredContents;
  final delivery = Completer<String>();

  @override
  Future<String> appVersion() async => 'test';

  @override
  Future<String?> pickBackupFile() async => pickedContents;

  @override
  Future<String?> deliverExport(
    String contents, {
    required bool Function() canDispatch,
  }) async {
    if (!canDispatch()) return null;
    deliveredContents = contents;
    if (!delivery.isCompleted) delivery.complete(contents);
    return 'wing-config.json';
  }
}

BackupSession _backupSession(
  ConnectionManager manager,
  AppPreferences owner,
  ConfigBackupIo platform,
) => BackupSession(
  configuration: ConfigBackupService(
    connectionManager: manager,
    appPreferences: owner,
  ),
  io: platform,
);

String _backupContents(ConnectionManager manager) => jsonEncode(
  ConfigBackup(
    createdAt: DateTime.utc(2026),
    appVersion: 'test',
    connections: manager.getConnections(),
    preferences: const {},
  ).toJson(),
);

WorkspaceEntrySession Function() homeEntryFactory(
  WidgetTester tester,
  ConnectionManager manager,
  AppPreferences appPreferences, {
  required ProfileWorkspaceController Function(SavedConnection) create,
  required AndroidLaunchIntentService? launchIntents,
}) {
  final registry = ProfileWorkspaceRegistry(
    identities: ProfileConnectionIdentity(
      credentialStore: _MemoryCredentialStore(),
    ),
    create: (connection, identity) => create(connection),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    registry.dispose();
  });
  return () => WorkspaceEntrySession(
    connectionManager: manager,
    appPreferences: appPreferences,
    registry: registry,
    launchIntents: launchIntents,
  );
}

Future<void> pumpHome(
  WidgetTester tester,
  ConnectionManager manager, {
  required AppPreferences appPreferences,
  ConfigBackupIo? backupPlatform,
  AndroidShareIntentService? shareIntents,
  AndroidLaunchIntentService? launchIntents,
  ProfileWorkspaceController? workspaceController,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: wingTheme(Brightness.light),
      home: HomeScreen(
        createSharedDraftSession: (entry) => SharedDraftSession(
          connectionManager: manager,
          entrySession: entry,
          shareIntents: shareIntents,
        ),
        appPreferences: appPreferences,
        createEntrySession: homeEntryFactory(
          tester,
          manager,
          appPreferences,
          create: (conn) =>
              workspaceController ??
              profileController(conn, manager.prefs, appPreferences),
          launchIntents: launchIntents,
        ),
        connManager: manager,
        shareIntents: shareIntents,
        launchIntents: launchIntents,
        createBackupSession: () => _backupSession(
          manager,
          appPreferences,
          backupPlatform ?? _BackupPlatform(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Wing',
      packageName: 'com.tarkilhk.wing',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  testWidgets('connection icon edits appearance while the LED opens status', (
    tester,
  ) async {
    final fixture = await createHomeFixture();
    final manager = fixture.manager;
    final appPreferences = fixture.appPreferences;
    await manager.saveConnection('Claw', 'host', 8642, 'key');
    await pumpHome(tester, manager, appPreferences: appPreferences);
    final icon = find.byTooltip('Change connection icon');
    final led = find.byKey(const ValueKey('server-connection-led'));
    final iconRect = tester.getRect(find.byType(ConnectionIconButton));
    expect(iconRect.width, greaterThanOrEqualTo(48));
    expect(iconRect.height, greaterThanOrEqualTo(48));
    await tester.tap(icon);
    await tester.pumpAndSettle();
    expect(find.text('Instance icon'), findsOneWidget);
    expect(find.text('Server access'), findsNothing);
    expect(find.byType(ProfileWorkspaceScreen), findsNothing);
    await tester.tap(find.byKey(const ValueKey('connection-icon-home')));
    await tester.tap(find.byTooltip('Save connection icon'));
    await tester.pumpAndSettle();
    expect(manager.getConnections().single.icon, ConnectionIcon.home);
    await tester.tap(led);
    await tester.pumpAndSettle();
    expect(find.text('Server access'), findsOneWidget);
    expect(find.text('Instance icon'), findsNothing);
    expect(find.byType(ProfileWorkspaceScreen), findsNothing);
  });

  testWidgets('tapping an icon saves and reopens its selection without setup', (
    tester,
  ) async {
    final fixture = await createHomeFixture();
    final manager = fixture.manager;
    final appPreferences = fixture.appPreferences;
    final connection = await manager.saveConnection(
      'Claw',
      'host',
      8642,
      'key',
    );
    await pumpHome(tester, manager, appPreferences: appPreferences);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsNothing);
    expect(find.text('Edit instance'), findsOneWidget);
    expect(find.text('Remove instance'), findsOneWidget);
    await tester.tapAt(const Offset(10, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Change connection icon'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('connection-icon-rocket')));
    await tester.tap(find.byTooltip('Save connection icon'));
    await tester.pumpAndSettle();
    expect(manager.getConnections().single.icon, ConnectionIcon.rocket);
    expect(manager.getConnections().single.id, connection.id);
    expect(
      tester.widget<ConnectionIconBadge>(find.byType(ConnectionIconBadge)).icon,
      ConnectionIcon.rocket,
    );
    await tester.tap(find.byTooltip('Change connection icon'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('connection-icon-rocket')),
          )
          .isSelected,
      isTrue,
    );
    expect(find.text('Check connection'), findsNothing);
  });

  testWidgets('a device with no connections can still reach restore', (
    tester,
  ) async {
    final fixture = await createHomeFixture();
    final manager = fixture.manager;
    final appPreferences = fixture.appPreferences;
    await pumpHome(tester, manager, appPreferences: appPreferences);

    // The whole point of a config backup is the fresh install, where Settings
    // is unreachable because no connection exists yet.
    expect(manager.getConnections(), isEmpty);
    expect(find.byKey(const Key('home_restore_config_button')), findsOneWidget);
  });

  testWidgets('a saved connection opens Workspace as the primary surface', (
    tester,
  ) async {
    final fixture = await createHomeFixture();
    final manager = fixture.manager;
    final appPreferences = fixture.appPreferences;
    await manager.saveConnection('Miniserver', 'host', 8642, 'key');
    await pumpHome(tester, manager, appPreferences: appPreferences);

    await tester.tap(find.text('Miniserver'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(ProfileWorkspaceScreen), findsOneWidget);
    expect(find.byTooltip('New chat'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('workspace-new-chat')).hitTestable(),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('chat-filter-profile')), findsOneWidget);
    expect(find.byTooltip('Chat list options'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-group-by')), findsNothing);
  });

  testWidgets('a cold-start launcher shortcut opens a Quick Chat directly', (
    tester,
  ) async {
    const channel = MethodChannel(AndroidLaunchIntentService.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => 'quickChat');
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final launchIntents = AndroidLaunchIntentService();
    await launchIntents.initialize();
    addTearDown(launchIntents.dispose);
    final fixture = await createHomeFixture();
    final manager = fixture.manager;
    final appPreferences = fixture.appPreferences;
    await manager.saveConnection('Miniserver', 'host', 8642, 'key');

    await pumpHome(
      tester,
      manager,
      appPreferences: appPreferences,
      launchIntents: launchIntents,
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(ProfileWorkspaceScreen), findsOneWidget);
    expect(find.byKey(const Key('profile-message-composer')), findsOneWidget);
    expect(launchIntents.pendingAction.value, isNull);
  });

  for (final action in [
    AndroidLaunchAction.activity,
    AndroidLaunchAction.searchChats,
  ]) {
    testWidgets('${action.name} waits for a connection choice', (tester) async {
      final service = AndroidLaunchIntentService();
      service.pendingAction.value = action;
      addTearDown(service.dispose);
      final fixture = await createHomeFixture();
      final manager = fixture.manager;
      final appPreferences = fixture.appPreferences;
      await manager.saveConnection('First server', 'first', 8642, 'key');
      final chosen = await manager.saveConnection(
        'Chosen server',
        'chosen',
        8642,
        'key',
      );
      await pumpHome(
        tester,
        manager,
        appPreferences: appPreferences,
        launchIntents: service,
      );
      expect(find.byType(ProfileWorkspaceScreen), findsNothing);
      expect(service.pendingAction.value, action);
      await tester.tap(find.text('Chosen server'));
      await tester.pumpAndSettle();
      final screen = tester.widget<ProfileWorkspaceScreen>(
        find.byType(ProfileWorkspaceScreen),
      );
      expect(screen.controller.connection.id, chosen.id);
      expect(service.pendingAction.value, isNull);
      if (action == AndroidLaunchAction.activity) {
        expect(find.byType(WorkspaceActivityContent), findsOneWidget);
      } else {
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('workspace-search')))
              .focusNode!
              .hasFocus,
          isTrue,
        );
      }
    });

    for (final cold in [true, false]) {
      testWidgets(
        '${cold ? "cold" : "warm"} ${action.name} shortcut opens its destination',
        (tester) async {
          const channel = MethodChannel(AndroidLaunchIntentService.channelName);
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(
            channel,
            (_) async => cold ? action.name : null,
          );
          addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
          final service = AndroidLaunchIntentService();
          await service.initialize();
          addTearDown(service.dispose);
          final fixture = await createHomeFixture();
          final manager = fixture.manager;
          final appPreferences = fixture.appPreferences;
          final connection = await manager.saveConnection(
            'Miniserver',
            'host',
            8642,
            'key',
          );
          final controller = profileController(
            connection,
            manager.prefs,
            appPreferences,
          );
          await pumpHome(
            tester,
            manager,
            appPreferences: appPreferences,
            launchIntents: service,
            workspaceController: controller,
          );
          if (!cold) {
            await tester.tap(find.text('Miniserver'));
            await tester.pumpAndSettle();
            await controller.createChat(canDispatch: () => true);
            await tester.pumpAndSettle();
            await tester.enterText(
              find.byKey(const Key('profile-message-composer')),
              'Keep this draft',
            );
            await tester.pump();
            final chat = controller.current!.chat!;
            await messenger.handlePlatformMessage(
              channel.name,
              channel.codec.encodeMethodCall(
                MethodCall('launchAction', action.name),
              ),
              (_) {},
            );
            await tester.pumpAndSettle();
            expect(chat.composer.observation.displayedText, 'Keep this draft');
          }
          await tester.pumpAndSettle();
          expect(
            find.byType(ProfileWorkspaceScreen, skipOffstage: false),
            findsOneWidget,
          );
          expect(service.pendingAction.value, isNull);
          expect(controller.visible, action == AndroidLaunchAction.searchChats);
          if (action == AndroidLaunchAction.activity) {
            expect(find.byType(WorkspaceActivityContent), findsOneWidget);
          } else {
            final search = find.byKey(const ValueKey('workspace-search'));
            expect(search, findsOneWidget);
            expect(
              tester.widget<TextField>(search).focusNode!.hasFocus,
              isTrue,
            );
            expect(tester.testTextInput.isVisible, isTrue);
            expect(controller.current!.selectedProject, isNull);
            expect(controller.current!.archivedOnly, isFalse);
          }
        },
      );
    }
  }

  testWidgets(
    'a cold-start share is reviewed before its draft is acknowledged',
    (tester) async {
      const channel = MethodChannel(AndroidShareIntentService.channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getPendingShare') {
              return {
                'id': 'cold-start-text',
                'text': 'Summarize https://example.com/shared',
                'files': <Object>[],
              };
            }
            if (call.method == 'acknowledgeShare') return null;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final shareIntents = AndroidShareIntentService();
      await shareIntents.initialize();
      addTearDown(shareIntents.dispose);
      final fixture = await createHomeFixture();
      final manager = fixture.manager;
      final appPreferences = fixture.appPreferences;
      await manager.saveConnection('Miniserver', 'host', 8642, 'key');

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            createSharedDraftSession: (entry) => SharedDraftSession(
              connectionManager: manager,
              entrySession: entry,
              shareIntents: shareIntents,
            ),
            appPreferences: appPreferences,
            createEntrySession: homeEntryFactory(
              tester,
              manager,
              appPreferences,
              create: (conn) =>
                  profileController(conn, manager.prefs, appPreferences),
              launchIntents: null,
            ),
            connManager: manager,
            createBackupSession: () =>
                _backupSession(manager, appPreferences, _BackupPlatform()),
            shareIntents: shareIntents,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(ProfileWorkspaceScreen), findsNothing);
      expect(shareIntents.pendingShare.value, isNotNull);
      await tester.tap(find.byKey(const ValueKey('share-add-to-draft')));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileWorkspaceScreen), findsOneWidget);
      expect(find.byKey(const Key('profile-message-composer')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('profile-message-composer')),
            )
            .controller!
            .text,
        'Summarize https://example.com/shared',
      );
      expect(shareIntents.pendingShare.value, isNull);
    },
  );

  testWidgets('a failed file-only share stays in review and remains pending', (
    tester,
  ) async {
    const channel = MethodChannel(AndroidShareIntentService.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'getPendingShare'
              ? {
                  'id': 'cold-start-file',
                  'files': [
                    {
                      'path': '/cache/shared/report.pdf',
                      'name': 'report.pdf',
                      'mediaType': 'application/pdf',
                      'byteLength': 42,
                    },
                  ],
                }
              : null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final shareIntents = AndroidShareIntentService();
    await shareIntents.initialize();
    addTearDown(shareIntents.dispose);
    final fixture = await createHomeFixture();
    final manager = fixture.manager;
    final appPreferences = fixture.appPreferences;
    await manager.saveConnection('Miniserver', 'host', 8642, 'key');

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          createSharedDraftSession: (entry) => SharedDraftSession(
            connectionManager: manager,
            entrySession: entry,
            shareIntents: shareIntents,
          ),
          appPreferences: appPreferences,
          createEntrySession: homeEntryFactory(
            tester,
            manager,
            appPreferences,
            create: (conn) =>
                profileController(conn, manager.prefs, appPreferences),
            launchIntents: null,
          ),
          connManager: manager,
          createBackupSession: () =>
              _backupSession(manager, appPreferences, _BackupPlatform()),
          shareIntents: shareIntents,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(ProfileWorkspaceScreen), findsNothing);
    await tester.tap(find.byKey(const ValueKey('share-add-to-draft')));
    await tester.pumpAndSettle();
    expect(find.textContaining('empty or unreadable'), findsOneWidget);
    expect(shareIntents.pendingShare.value, isNotNull);
    expect(find.byKey(const ValueKey('share-add-to-draft')), findsOneWidget);
  });

  testWidgets('app settings restores configuration once connections exist', (
    tester,
  ) async {
    final fixture = await createHomeFixture();
    final manager = fixture.manager;
    final appPreferences = fixture.appPreferences;
    await manager.saveConnection('Miniserver', 'host', 8642, 'key');
    await pumpHome(
      tester,
      manager,
      appPreferences: appPreferences,
      backupPlatform: _BackupPlatform()
        ..pickedContents = _backupContents(manager),
    );

    expect(find.byTooltip('Restore configuration'), findsNothing);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Restore configuration'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('import_passphrase_field')), findsOneWidget);
  });

  testWidgets('connected settings displays restored preferences immediately', (
    tester,
  ) async {
    final fixture = await createHomeFixture();
    final manager = fixture.manager;
    final appPreferences = fixture.appPreferences;
    await manager.saveConnection('Work', 'localhost', 9119, '');
    await appPreferences.setAccent(AppAccentPreference.coral);
    await appPreferences.setRunningAction(ComposerAction.stop);
    final backup = ConfigBackup(
      createdAt: DateTime.utc(2026),
      appVersion: 'test',
      connections: manager.getConnections(),
      preferences: {
        'workspace_accent_v1': 'iris',
        'composer_running_action': 'queue',
      },
    );
    await pumpHome(
      tester,
      manager,
      appPreferences: appPreferences,
      backupPlatform: _BackupPlatform()
        ..pickedContents = jsonEncode(backup.toJson()),
    );
    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Coral'))
          .selected,
      isTrue,
    );
    await tester.tap(find.byTooltip('Restore configuration'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import_confirm_button')));
    await tester.pumpAndSettle();
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
  });

  testWidgets('tapping restore on an empty device opens the import sheet', (
    tester,
  ) async {
    final fixture = await createHomeFixture();
    final manager = fixture.manager;
    final appPreferences = fixture.appPreferences;
    await pumpHome(
      tester,
      manager,
      appPreferences: appPreferences,
      backupPlatform: _BackupPlatform()
        ..pickedContents = _backupContents(manager),
    );

    await tester.tap(find.byKey(const Key('home_restore_config_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('import_passphrase_field')), findsOneWidget);
    expect(find.byKey(const Key('import_mode_merge')), findsOneWidget);
  });

  testWidgets('a restored connection appears without restarting the app', (
    tester,
  ) async {
    final fixture = await createHomeFixture();
    final manager = fixture.manager;
    final appPreferences = fixture.appPreferences;
    final backup = ConfigBackup(
      createdAt: DateTime.utc(2026),
      appVersion: 'test',
      connections: [
        SavedConnection(
          id: 'restored-1',
          label: 'Miniserver',
          host: 'hermes.example.com',
          port: 8642,
          apiKey: 'test-restored-key',
          useHttps: true,
        ),
      ],
      preferences: const {},
    );
    await pumpHome(
      tester,
      manager,
      appPreferences: appPreferences,
      backupPlatform: _BackupPlatform()
        ..pickedContents = jsonEncode(backup.toJson()),
    );

    expect(find.text('Your agent, with you'), findsOneWidget);
    await tester.tap(find.byKey(const Key('home_restore_config_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import_confirm_button')));
    await tester.pumpAndSettle();

    expect(find.text('Your agent, with you'), findsNothing);
    expect(find.text('Miniserver'), findsOneWidget);
    expect(manager.getConnections().single.id, 'restored-1');
  });

  testWidgets('the import sheet offers merge and replace', (tester) async {
    final fixture = await createHomeFixture();
    final manager = fixture.manager;
    final appPreferences = fixture.appPreferences;
    await pumpHome(
      tester,
      manager,
      appPreferences: appPreferences,
      backupPlatform: _BackupPlatform()
        ..pickedContents = _backupContents(manager),
    );

    await tester.tap(find.byKey(const Key('home_restore_config_button')));
    await tester.pumpAndSettle();

    expect(find.text('Merge'), findsOneWidget);
    expect(find.text('Replace'), findsOneWidget);
  });

  testWidgets(
    'connection header validation survives collapsing advanced settings',
    (tester) async {
      final fixture = await createHomeFixture();
      final manager = fixture.manager;
      final appPreferences = fixture.appPreferences;
      await pumpHome(tester, manager, appPreferences: appPreferences);
      await tester.tap(find.text('Connect your agent'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use an address'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('connection-address')),
        'https://hermes.example.com',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('connection-primary')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('connection-primary')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Custom setup'));
      await tester.tap(find.text('Custom setup'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Access headers'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Add header'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add header'));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Header name'),
        'Authorization',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Value'),
        'do-not-send',
      );
      await tester.ensureVisible(find.text('Access headers'));
      await tester.tap(find.text('Access headers'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Use connection settings'));
      await tester.tap(find.byTooltip('Use connection settings'));
      await tester.pumpAndSettle();
      expect(find.textContaining('managed by Hermes'), findsOneWidget);
      expect(manager.getConnections(), isEmpty);
      expect(find.text('Access header credentials'), findsOneWidget);
    },
  );

  for (final connected in [false, true]) {
    testWidgets(
      'app settings exports a protected backup, connected=$connected',
      (tester) async {
        final fixture = await createHomeFixture();
        final manager = fixture.manager;
        final appPreferences = fixture.appPreferences;
        await manager.saveConnection('Work', 'localhost', 9119, '');
        final platform = _BackupPlatform();
        await pumpHome(
          tester,
          manager,
          appPreferences: appPreferences,
          backupPlatform: platform,
        );
        expect(find.byTooltip('Backup configuration'), findsNothing);
        expect(find.byTooltip('Restore configuration'), findsNothing);
        if (connected) {
          await tester.tap(find.text('Work'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('nav-settings')));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Backend updates'), findsNothing);
        await tester.tap(find.byTooltip('Backup configuration'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('export_passphrase_field')),
          'test-passphrase',
        );
        await tester.enterText(
          find.byKey(const Key('export_passphrase_confirm_field')),
          'test-passphrase',
        );
        await tester.tap(find.byKey(const Key('export_confirm_button')));
        await tester.pumpAndSettle();
        final exported = await tester.runAsync(() async {
          final contents = await platform.delivery.future.timeout(
            const Duration(seconds: 30),
          );
          expect(
            jsonDecode(contents)['format'],
            ConfigBackupCodec.envelopeFormat,
          );
          return ConfigBackupCodec.decode(
            contents,
            passphrase: 'test-passphrase',
          );
        });
        await tester.pumpAndSettle();
        expect(platform.deliveredContents, isNotNull);
        expect(
          exported!.connections.single.id,
          manager.getConnections().single.id,
        );
        expect(exported.connections.single.label, 'Work');
        expect(find.text('Backup exported — wing-config.json'), findsOneWidget);
      },
    );
  }

  testWidgets('a new connection never pre-fills a Desktop Gateway URL', (
    tester,
  ) async {
    // Regression: the form used to pre-fill a hardcoded example
    // (`http://192.168.1.193/desktop`). Saving it silently pointed the app at
    // a dead Desktop Gateway, which wedged Project/session loading.
    final fixture = await createHomeFixture();
    final manager = fixture.manager;
    final appPreferences = fixture.appPreferences;
    await pumpHome(tester, manager, appPreferences: appPreferences);

    await tester.tap(find.text('Connect your agent'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use an address'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('connection-address')),
      'https://hermes.example.com',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('connection-primary')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('connection-primary')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Custom setup'));
    await tester.tap(find.text('Custom setup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use a separate chat address'));
    await tester.pumpAndSettle();

    final field = find.byKey(const Key('connection-chat-address'));
    expect(field, findsOneWidget);
    final textField = tester.widget<TextFormField>(field);
    expect(textField.controller?.text, isEmpty);
  });
}

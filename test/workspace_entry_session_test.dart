import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/workspace_entry.dart';
import 'package:wing/core/services/android_launch_intent_service.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_connection_identity.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_workspace_registry.dart';
import 'package:wing/core/services/workspace_entry_session.dart';

import 'support/profile_browser_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesStorePlatform previousPlatform;
  late _EntryStorage platform;
  late _Credentials credentials;
  late ConnectionManager manager;
  late AppPreferences preferences;
  late ProfileWorkspaceRegistry registry;
  late WorkspaceEntrySession session;
  late AndroidLaunchIntentService launcher;
  final created = <ProfileWorkspaceController>[];

  setUp(() async {
    previousPlatform = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    platform = _EntryStorage();
    SharedPreferencesStorePlatform.instance = platform;
    final raw = await SharedPreferences.getInstance();
    credentials = _Credentials();
    manager = await ConnectionManager.create(raw, credentialStore: credentials);
    preferences = AppPreferences(raw);
    created.clear();
    registry = ProfileWorkspaceRegistry(
      identities: ProfileConnectionIdentity(credentialStore: _Credentials()),
      create: (connection, identity) {
        final controller = ProfileWorkspaceController(
          access: manager.accessFor(connection),
          connectionIdentity: identity,
          preferences: raw,
          appPreferences: preferences,
          gatewayFactory: ProfileBrowserFixture().gateway,
        );
        created.add(controller);
        return controller;
      },
    );
    launcher = AndroidLaunchIntentService();
    session = WorkspaceEntrySession(
      connectionManager: manager,
      appPreferences: preferences,
      registry: registry,
      launchIntents: launcher,
    );
  });
  tearDown(() {
    if (!platform.release.isCompleted) {
      platform.release.complete();
    }
    if (!credentials.release.isCompleted) {
      credentials.release.complete();
    }
    session.dispose();
    registry.dispose();
    launcher.dispose();
    preferences.dispose();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = previousPlatform;
  });

  test(
    'new manual entry stays available while an older remembered write is held',
    () async {
      final work = await manager.saveConnection('Work', 'localhost', 1, '');
      final personal = await manager.saveConnection(
        'Personal',
        'localhost',
        2,
        '',
      );
      platform.hold = work.id;
      final first = await session.prepare(work);
      expect(first, isNotNull);
      await platform.entered.future;
      expect(session.state.opening, isFalse);
      launcher.pendingAction.value = AndroidLaunchAction.searchChats;
      final second = await session.prepare(personal);
      expect(second, isNotNull);
      expect(second!.controller.connection.id, personal.id);
      expect(session.isCurrent(first!), isFalse);
      expect(session.isCurrent(second), isTrue);
      expect(platform.writes, [work.id]);
      expect(session.externalConnection()!.id, personal.id);
      expect(session.takeLaunchAction(second), AndroidLaunchAction.searchChats);
      expect(launcher.pendingAction.value, isNull);
      platform.release.complete();
      expect(
        (await preferences.settleWorkspaceEntry()).connectionId,
        personal.id,
      );
      expect(platform.writes, [work.id, personal.id]);
      await preferences.reload();
      expect(preferences.workspaceEntry.value.confirmedId, personal.id);
      expect(session.startupConnection(hasPendingShare: false), isNull);
      session.dispose();
      // Home borrows both authorities; consumer disposal does not close them.
      expect(await registry.forConnection(personal), same(second.controller));
      expect(
        (await preferences.admitWorkspaceEntry(work.id).settled).outcome,
        WorkspaceEntrySaveOutcome.saved,
      );
    },
  );

  test(
    'held secure read retired before admission constructs no workspace or choice',
    () async {
      final saved = await manager.saveConnection('Work', 'localhost', 1, '');
      credentials.holdReads = true;
      final entry = session.prepare(saved);
      await credentials.entered.future;
      session.dispose();
      credentials.release.complete();
      expect(await entry, isNull);
      expect(created, isEmpty);
      expect(platform.writes, isEmpty);
      expect(
        (await platform.getAll()).containsKey('flutter.last_connection_id'),
        isFalse,
      );
    },
  );

  test(
    'current secure saved authority replaces stale metadata and stale launcher handoff',
    () async {
      final captured = await manager.saveConnection(
        'Work',
        'localhost',
        1,
        'old',
      );
      await manager.updateConnection(
        captured.id,
        captured.label,
        Uri(
          scheme: captured.useHttps ? 'https' : 'http',
          host: captured.host,
        ).toString(),
        captured.port,
        'current',
        icon: captured.icon,
        gatewayPrefix: captured.gatewayPrefix,
        dashboardPrefix: captured.dashboardPrefix,
        dashboardProxied: captured.dashboardProxied,
        desktopGatewayUrl: captured.desktopGatewayUrl,
        dashboardPort: captured.dashboardPortOverride,
        dashboardUsername: captured.dashboardUsername,
        dashboardPassword: captured.dashboardPassword,
        cloudInstanceId: captured.cloudInstanceId,
        cloudOrganization: captured.cloudOrganization,
        dashboardGrant: captured.dashboardGrant,
        gatewayHeaders: captured.gatewayHeaders,
      );
      launcher.pendingAction.value = AndroidLaunchAction.activity;
      credentials.holdReads = true;
      final entry = session.prepare(captured);
      await credentials.entered.future;
      launcher.pendingAction.value = AndroidLaunchAction.searchChats;
      launcher.pendingAction.value = AndroidLaunchAction.activity;
      credentials.release.complete();
      final plan = await entry;
      expect(plan, isNotNull);
      expect(plan!.controller.connection.apiKey, 'current');
      expect(session.takeLaunchAction(plan), isNull);
      expect(launcher.pendingAction.value, AndroidLaunchAction.activity);
      final fresh = await session.prepare(captured);
      expect(session.takeLaunchAction(fresh!), AndroidLaunchAction.activity);
      expect(launcher.pendingAction.value, isNull);
      await preferences.settleWorkspaceEntry();
    },
  );

  test(
    'reentrant entry retirement rejects secure admission before any physical work',
    () async {
      final saved = await manager.saveConnection('Work', 'localhost', 1, '');
      session.addListener(() {
        if (session.state.opening) {
          session.dispose();
        }
      });
      expect(await session.prepare(saved), isNull);
      expect(created, isEmpty);
      expect(platform.writes, isEmpty);
    },
  );

  test(
    'startup and external choice use confirmed facts without guessing malformed presence',
    () async {
      final a = await manager.saveConnection('A', 'localhost', 1, '');
      final b = await manager.saveConnection('B', 'localhost', 2, '');
      expect(session.externalConnection(), isNull);
      await preferences.admitWorkspaceEntry(b.id).settled;
      expect(session.externalConnection()!.id, b.id);
      expect(session.sharedConnection(a.id)!.id, a.id);
      expect(session.startupConnection(hasPendingShare: false)!.id, b.id);
      expect(session.startupConnection(hasPendingShare: false), isNull);
      await platform.setValue('Int', 'flutter.last_connection_id', 7);
      await preferences.reload();
      expect(
        preferences.workspaceEntry.value.validity,
        WorkspaceEntryValidity.invalid,
      );
      expect(session.externalConnection(), isNull);
      expect((await session.prepare(a))!.controller.connection.id, a.id);
      await preferences.settleWorkspaceEntry();
      expect(preferences.workspaceEntry.value.confirmedId, a.id);
    },
  );
}

class _Credentials implements CredentialStore {
  final values = <String, String>{};
  bool holdReads = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<String?> read(String key) async {
    if (holdReads && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _EntryStorage extends InMemorySharedPreferencesStore {
  _EntryStorage() : super.empty();
  final writes = <Object>[];
  String? hold;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.last_connection_id') {
      writes.add(value);
      if (value == hold && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    }
    return super.setValue(valueType, key, value);
  }
}

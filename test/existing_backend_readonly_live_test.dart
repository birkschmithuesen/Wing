import 'package:wing/core/services/connection_access.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/backend_update.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/services/ws_client.dart';

import 'support/existing_backend_login.dart';

/// Opt in with WING_HERMES_URL and WING_HERMES_LOGIN_FILE (a private JSON file
/// containing username/password). Credentials stay out of compiled defines and
/// output. Uses normal password sign-in and single-use WebSocket tickets.
/// WING_HERMES_PROFILE selects existing saved chats for the reopening check.
/// Reads history through the production gateway; never prints its contents or
/// sends prompts, acknowledges reading, changes settings or updates the server.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final url = Platform.environment['WING_HERMES_URL'];
  final loginFile = Platform.environment['WING_HERMES_LOGIN_FILE'];
  final enabled = url != null && loginFile != null;
  late SavedConnection connection;
  late DashboardClient dashboard;
  late ProfileDiscovery discovery;
  HttpOverrides? overrides;

  setUpAll(() async {
    if (!enabled) return;
    overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    connection = await readExistingBackendConnection(
      url: url,
      loginFile: loginFile,
      id: 'existing-readonly',
    );
    dashboard = DashboardClient(
      host: connection.host,
      port: connection.dashboardPort,
      useHttps: connection.useHttps,
      pathPrefix: connection.dashboardPrefix ?? '',
      username: connection.dashboardUsername,
      password: connection.dashboardPassword,
    );
    addTearDown(dashboard.close);
    discovery = await ProfilesRepository(dashboard.apiGet).discover();
  });

  tearDownAll(() {
    if (enabled) HttpOverrides.global = overrides;
  });

  test(
    'existing server authenticates and exposes profile/version contracts',
    () async {
      expect(discovery.profiles.isNotEmpty, isTrue);
      expect(discovery.named('default') != null, isTrue);
      expect(discovery.named(discovery.currentName) != null, isTrue);
      final health = await dashboard.apiGet('status');
      final runtime = await dashboard.apiGet('health');
      expect(runtime['commit'] is String, isTrue);
      expect(health['version'] is String, isTrue);
      expect(health['gateway_running'] is bool, isTrue);
      final identity = await dashboard.apiGet('auth/me');
      expect(identity['provider'] == 'basic', isTrue);
      final version = BackendUpdateCheck.fromJson(
        await dashboard.apiGet('hermes/update/check'),
      );
      expect(version.currentVersion?.isNotEmpty == true, isTrue);
      // Retain public version and counts only, never profile names or auth data.
      // ignore: avoid_print
      print(
        'EXISTING_HERMES_READONLY ${jsonEncode({'version': health['version'], 'backend_commit': runtime['commit'], 'profile_count': discovery.profiles.length, 'runtime_identity_available': discovery.currentName != null, 'authenticated': true})}',
      );
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'existing saved chats reopen with canonical authority and readable history',
    () async {
      final profile = Platform.environment['WING_HERMES_PROFILE'];
      expect(
        profile != null && discovery.named(profile) != null,
        isTrue,
        reason:
            'Set WING_HERMES_PROFILE to an existing profile with saved chats.',
      );
      ProfileGateway openGateway() {
        final gateway = ProfileGateway.forConnection(
          ConnectionAccess(connection: connection, dashboardOAuth: null),
          WorkspaceScope(connectionId: connection.id, profileName: profile!),
        );
        addTearDown(gateway.close);
        return gateway;
      }

      final browser = openGateway();
      final listing = await browser.read('sessions', {'limit': '20'});
      final rows = ProfileGateway.records(listing['sessions'])
          .where(
            (row) => row['message_count'] is int && row['message_count'] > 0,
          )
          .take(3)
          .toList();
      expect(
        rows.isNotEmpty,
        isTrue,
        reason: 'An empty catalog does not prove that existing chats reopen.',
      );
      for (final row in rows) {
        expect(row['id'] is String, isTrue);
        // A fresh production socket for each chat also exercises ticket/profile
        // setup. Do not use a fixture that manufactures canonical authority.
        final gateway = openGateway();
        try {
          await gateway.connect();
          for (var attempt = 0; attempt < 2; attempt++) {
            final resumed = await gateway.resume(row['id'] as String);
            final runtime = resumed['session_id'];
            final stored = resumed['stored_session_id'];
            expect(runtime is String && stored is String, isTrue);
            expect(
              gateway.canonical.session(runtime as String) != null,
              isTrue,
            );
            final history = await gateway.history(stored as String);
            expect(
              history.rows.isNotEmpty,
              isTrue,
              reason: 'Reopening must retain readable saved history.',
            );
          }
        } on JsonRpcError catch (error) {
          fail(
            'Existing-chat reopening failed at ${error.method} '
            '(RPC ${error.code}). The deployed API does not satisfy this '
            'candidate; login/ping and fixture passes cannot certify delivery.',
          );
        } finally {
          gateway.close();
        }
      }
      // Counts only: no conversation IDs, profile names or transcript contents.
      // ignore: avoid_print
      print('EXISTING_HERMES_REOPEN ${jsonEncode({'reopened': rows.length})}');
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'requested saved conversation is readable independently of attachment',
    () async {
      final profile = Platform.environment['WING_HERMES_PROFILE'];
      final sessionId = Platform.environment['WING_HERMES_SESSION']!;
      expect(discovery.named(profile ?? ''), isNotNull);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(connection: connection, dashboardOAuth: null),
        connectionIdentity: 'existing-readonly',
        preferences: preferences,
        appPreferences: appPreferences,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      var revealed = false;
      final chat = await controller.openSessionForReading(
        ProfileSessionKey(
          WorkspaceScope(
            connectionId: connection.id,
            connectionIdentity: 'existing-readonly',
            profileName: profile!,
          ),
          sessionId,
        ),
        isCurrentRequest: () => true,
        onReadingAvailable: (chat) {
          expect(chat.reading.messages, isNotEmpty);
          expect(chat.runtime.offline, isTrue);
          revealed = true;
        },
      );
      expect(revealed, isTrue);
      expect(chat, isNotNull);
      expect(chat!.reading.messages, isNotEmpty);
      expect(chat.reading.historyError, isNull);
      expect(chat.refreshingConversation, isFalse);
      if (chat.runtime.offline) {
        expect(chat.runtime.openingError, isNotNull);
      }
      // Counts and attachment state only; never transcript or credentials.
      // ignore: avoid_print
      print(
        'EXISTING_HERMES_READING ${jsonEncode({'rows': chat.reading.messages.length, 'attached': !chat.runtime.offline})}',
      );
    },
    skip: !enabled || Platform.environment['WING_HERMES_SESSION'] == null,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'existing default profile exposes scoped administration read contracts',
    () async {
      final gateway = ProfileGateway.forConnection(
        ConnectionAccess(connection: connection, dashboardOAuth: null),
        WorkspaceScope(connectionId: connection.id, profileName: 'default'),
      );
      addTearDown(gateway.close);
      final model = await gateway.read('model/info');
      expect(model.containsKey('model'), isTrue);
      final schema = await gateway.read('config/schema');
      expect(schema['fields'] is Map, isTrue);
      for (final endpoint in ['skills', 'tools/toolsets']) {
        final catalog = await gateway.read(endpoint);
        expect(catalog['data'] is List, isTrue, reason: endpoint);
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'existing gateway authenticates a ticket with canonical session authority',
    () async {
      final credentials = await dashboard.gatewayCredentials();
      expect(credentials.token == null && credentials.ticket != null, isTrue);
      final socket = WsClient(dashboard.baseUrl, ticket: credentials.ticket);
      addTearDown(socket.close);
      await socket.connect();
      final ready = await socket.waitForGatewayReady();
      expect(
        ready['params']?['payload']?['session_authority'] == true,
        isTrue,
        reason:
            'This address must serve the canonical gateway. Stock standalone '
            'Dashboard can authenticate and answer ping without supporting '
            'Wing session operations; updating its version alone does not '
            'change that endpoint type.',
      );
      final ping = await socket.send('ping', {});
      expect(ping['error'] == null, isTrue);
      expect(ping['result'] is Map && ping['result']['pong'] == true, isTrue);
      final capabilities = await socket.send('gateway.capabilities', {});
      expect(capabilities['error'] == null, isTrue);
      expect(capabilities['result'] is Map, isTrue);
      expect(
        capabilities['result']['per_session_exclusive_submit'] is bool,
        isTrue,
      );
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

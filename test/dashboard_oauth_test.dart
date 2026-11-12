import 'package:wing/core/models/dashboard_oauth_grant.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/dashboard_oauth_session.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_connection_identity.dart';

class _Store implements CredentialStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

DashboardOAuthGrant _grant({bool expired = true}) => DashboardOAuthGrant(
  id: 'grant',
  baseUrl: 'https://agent.example/hermes',
  accessToken: 'old-access',
  refreshToken: 'old-refresh',
  expiresAt: expired
      ? DateTime.utc(2020)
      : DateTime.now().add(const Duration(hours: 1)),
);

DashboardOAuthSession _session({
  bool expired = true,
  http.Client Function()? client,
  Future<void> Function()? persist,
}) => DashboardOAuthSession(
  _grant(expired: expired),
  createClient: client,
  persist: persist,
);

/// Hold delivery of a real completed bearer at the public auth boundary.
/// This models retirement after token acquisition and before the HTTP caller
/// receives authentication; it never manufactures a second grant or refresh.
class _HeldBearerDelivery extends DashboardOAuthSession {
  _HeldBearerDelivery() : super(_grant(expired: false));
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<String> bearerFor(String destination) async {
    final bearer = await super.bearerFor(destination);
    started.complete();
    await release.future;
    return bearer;
  }
}

http.Response _tokens() => http.Response(
  jsonEncode({
    'provider': 'nous',
    'access_token': 'new-access',
    'refresh_token': 'new-refresh',
    'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
  }),
  200,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'parallel renewal exchanges one rotating grant and persists before use',
    () async {
      var exchanges = 0, saves = 0;
      var delivered = 0;
      final release = Completer<void>();
      final saving = Completer<void>();
      final saved = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        if (!saved.isCompleted) saved.complete();
      });
      final session = _session(
        client: () => MockClient((request) async {
          exchanges++;
          expect(
            request.url.toString(),
            'https://agent.example/hermes/auth/native/refresh',
          );
          expect(request.followRedirects, false);
          expect(jsonDecode(request.body), {
            'provider': 'nous',
            'refresh_token': 'old-refresh',
          });
          await release.future;
          return _tokens();
        }),
        persist: () async {
          saves++;
          saving.complete();
          await saved.future;
        },
      );
      final requests = List.generate(
        8,
        (_) => session.bearerFor('https://agent.example:443/hermes/').then((
          token,
        ) {
          delivered++;
          return token;
        }),
      );
      release.complete();
      await saving.future;
      expect(
        delivered,
        0,
        reason: 'Rotated tokens must be durable before use.',
      );
      saved.complete();
      expect(await Future.wait(requests), everyElement('new-access'));
      expect(exchanges, 1);
      expect(saves, 1);
    },
  );

  test(
    'failed secure save retries rotated tokens without replaying refresh',
    () async {
      var exchanges = 0, saves = 0;
      final session = _session(
        client: () => MockClient((_) async {
          exchanges++;
          return _tokens();
        }),
        persist: () async {
          if (++saves == 1) throw StateError('storage unavailable');
        },
      );
      await expectLater(
        session.bearerFor(session.currentGrant.baseUrl),
        throwsA(isA<CloudAccessException>()),
      );
      expect(session.currentGrant.refreshToken, 'new-refresh');
      expect(
        await session.bearerFor(session.currentGrant.baseUrl),
        'new-access',
      );
      expect(exchanges, 1);
      expect(saves, 2);
    },
  );

  for (final url in [
    'https://elsewhere.example/hermes',
    'https://agent.example/other',
  ]) {
    test('grant cannot be forwarded to $url', () async {
      final session = _session(expired: false);
      await expectLater(
        session.bearerFor(url),
        throwsA(isA<CloudAccessException>()),
      );
    });
  }

  test('insecure grant destination is rejected before renewal', () async {
    var requests = 0;
    final session = _session(
      client: () => MockClient((_) async {
        requests++;
        return _tokens();
      }),
    );
    await expectLater(
      session.bearerFor('http://agent.example/hermes'),
      throwsFormatException,
    );
    expect(requests, 0);
  });

  test(
    'OAuth dashboard uses bearer, then a single-use WebSocket ticket',
    () async {
      final client = DashboardClient(
        host: 'agent.example',
        port: 443,
        useHttps: true,
        pathPrefix: '/hermes',
        dashboardOAuth: _session(expired: false),
        httpClient: MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer old-access');
          expect(request.headers, isNot(contains('Cookie')));
          expect(request.headers, isNot(contains('X-Hermes-Session-Token')));
          expect(request.url.path, '/hermes/api/auth/ws-ticket');
          return http.Response('{"ticket":"single-use"}', 200);
        }),
      );
      addTearDown(client.close);
      expect(await client.gatewayCredentials(), (
        token: null,
        ticket: 'single-use',
      ));
    },
  );

  test(
    'late 401 from an old bearer does not invalidate an already renewed grant',
    () async {
      var exchanges = 0;
      final session = _session(
        expired: false,
        client: () => MockClient((_) async {
          exchanges++;
          return _tokens();
        }),
      );
      final lateResponse = Completer<void>();
      final client = DashboardClient(
        host: 'agent.example',
        port: 443,
        useHttps: true,
        pathPrefix: '/hermes',
        dashboardOAuth: session,
        httpClient: MockClient((request) async {
          if (request.headers['Authorization'] == 'Bearer old-access') {
            if (request.url.path.endsWith('/second')) await lateResponse.future;
            return http.Response('{}', 401, request: request);
          }
          expect(request.headers['Authorization'], 'Bearer new-access');
          return http.Response('{}', 200, request: request);
        }),
      );
      addTearDown(client.close);
      final first = client.apiGet('first');
      final second = client.apiGet('second');
      await first;
      lateResponse.complete();
      await second;
      expect(exchanges, 1);
    },
  );

  test(
    'restored Cloud without grant fails closed before any HTTP request',
    () async {
      final client = DashboardClient(
        host: 'agent.example',
        useHttps: true,
        requiresOAuth: true,
        httpClient: MockClient(
          (_) async =>
              throw StateError('Must never fetch SPA or password login'),
        ),
      );
      addTearDown(client.close);
      await expectLater(
        client.apiGet('profiles'),
        throwsA(isA<CloudAccessException>()),
      );
    },
  );

  test(
    'retiring a held refresh rejects its result without replacing the grant',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      var saves = 0;
      final session = _session(
        client: () => MockClient((_) async {
          started.complete();
          await release.future;
          return _tokens();
        }),
        persist: () async {
          saves++;
        },
      );
      final opening = session.currentGrant;
      final pending = session.bearerFor(opening.baseUrl);
      final rejected = expectLater(
        pending,
        throwsA(isA<CloudAccessException>()),
      );
      await started.future;
      session.retire();
      release.complete();
      await rejected;
      expect(identical(session.currentGrant, opening), isTrue);
      expect(saves, 0);
      await expectLater(session.bearerFor(opening.baseUrl), throwsStateError);
    },
  );

  test('access cannot pair a descriptor with a different sign-in owner', () {
    final grant = _grant(expired: false);
    final connection = SavedConnection(
      id: 'cloud',
      label: 'Cloud',
      host: 'agent.example',
      port: 443,
      apiKey: '',
      useHttps: true,
      dashboardGrant: grant,
    );
    expect(
      () => ConnectionAccess(connection: connection, dashboardOAuth: null),
      throwsStateError,
    );
    expect(
      () => ConnectionAccess(
        connection: connection,
        dashboardOAuth: DashboardOAuthSession(
          DashboardOAuthGrant(
            id: 'other',
            baseUrl: grant.baseUrl,
            accessToken: 'test-access',
            refreshToken: 'test-refresh',
            expiresAt: grant.expiresAt,
          ),
        ),
      ),
      throwsStateError,
    );
    expect(
      () => ConnectionAccess(
        connection: SavedConnection(
          id: 'local',
          label: 'Local',
          host: 'agent.example',
          port: 443,
          apiKey: '',
        ),
        dashboardOAuth: DashboardOAuthSession(grant),
      ),
      throwsStateError,
    );
  });

  test(
    'replacing connection authority retires already captured refresh owners',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = _Store();
      final manager = await ConnectionManager.create(
        prefs,
        credentialStore: store,
      );
      final saved = await manager.saveConnection(
        'Cloud',
        'https://agent.example',
        443,
        '',
        dashboardPrefix: '/hermes',
        cloudInstanceId: 'instance',
        dashboardGrant: _grant(expired: false),
      );
      final old = manager.accessFor(saved);
      await manager.updateConnection(
        saved.id,
        'Renamed',
        'https://agent.example',
        443,
        '',
        dashboardPrefix: '/hermes',
        dashboardGrant: saved.dashboardGrant,
      );
      expect(manager.accessFor(saved).dashboardOAuth, same(old.dashboardOAuth));
      await manager.updateConnection(
        saved.id,
        'Renamed',
        'https://other.example',
        443,
        '',
        dashboardPrefix: '/hermes',
        dashboardGrant: saved.dashboardGrant,
      );
      expect(() => manager.accessFor(saved), throwsStateError);
      await expectLater(
        old.dashboardOAuth!.bearerFor(_grant().baseUrl),
        throwsStateError,
      );
      expect(
        manager.accessFor(manager.getConnections().single).dashboardOAuth,
        isNot(same(old.dashboardOAuth)),
      );
    },
  );

  test(
    'retirement after bearer completion fences the actual owned HTTP send',
    () async {
      final session = _HeldBearerDelivery();
      var physicalWrites = 0;
      var dispatches = 0;
      final client = DashboardClient(
        host: 'agent.example',
        port: 443,
        useHttps: true,
        pathPrefix: '/hermes',
        dashboardOAuth: session,
        httpClient: MockClient((_) async {
          physicalWrites++;
          return http.Response('{}', 200);
        }),
      );
      addTearDown(client.close);
      final pending = client.apiWriteOwned(
        'POST',
        'model/set',
        body: {},
        canDispatch: () => true,
        onDispatched: () {
          dispatches++;
        },
      );
      var succeeded = false;
      Object? failure;
      final settled = pending.then<void>(
        (_) {
          succeeded = true;
        },
        onError: (Object error) {
          failure = error;
        },
      );
      await session.started.future;
      expect(physicalWrites, 0);
      expect(dispatches, 0);
      session.retire();
      session.release.complete();
      await settled;
      expect(physicalWrites, 0);
      expect(dispatches, 0);
      expect(failure, isA<DashboardRequestNotSentException>());
      expect(succeeded, isFalse);
    },
  );

  test(
    'secure grant is shared, survives reload and keeps ownership stable on rotation',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = _Store();
      final manager = await ConnectionManager.create(
        prefs,
        credentialStore: store,
        createOAuthSession: (grant) => DashboardOAuthSession(
          grant,
          createClient: () => MockClient((_) async => _tokens()),
        ),
      );
      final saved = await manager.saveConnection(
        'Research',
        'https://agent.example',
        443,
        '',
        dashboardPrefix: '/hermes',
        cloudInstanceId: 'instance',
        cloudOrganization: 'team',
        dashboardGrant: _grant(),
      );
      expect(
        prefs.getStringList('saved_connections')!.join(),
        isNot(contains('old-access')),
      );
      expect(
        prefs.getStringList('saved_connections')!.join(),
        isNot(contains('old-refresh')),
      );
      final hydrated = manager.getConnections().single;
      final session = manager.accessFor(hydrated).dashboardOAuth!;
      expect(identical(manager.accessFor(saved).dashboardOAuth, session), true);
      final identity = ProfileConnectionIdentity(credentialStore: store);
      final before = await identity.resolve(saved);
      expect(
        await manager
            .accessFor(hydrated)
            .dashboardOAuth!
            .bearerFor(session.currentGrant.baseUrl),
        'new-access',
      );
      expect(await identity.resolve(saved), before);
      // A descriptor remains an immutable opening snapshot after rotation.
      expect(saved.dashboardGrant!.accessToken, 'old-access');
      expect(session.currentGrant.accessToken, 'new-access');
      expect(
        manager.accessFor(saved).persistenceSnapshot.dashboardGrant,
        same(session.currentGrant),
      );
      final stored = store.values.values.firstWhere(
        (v) => v.contains('dashboard_oauth'),
      );
      expect(
        jsonDecode(stored)['dashboard_oauth']['refresh_token'],
        'new-refresh',
      );
      final loaded = await ConnectionManager.create(
        prefs,
        credentialStore: store,
      );
      expect(
        identical(
          loaded.accessFor(loaded.getConnections().single).dashboardOAuth,
          session,
        ),
        true,
      );
      await manager.deleteConnection(saved.id);
      expect(() => manager.accessFor(saved), throwsStateError);
      await expectLater(
        session.bearerFor(session.currentGrant.baseUrl),
        throwsStateError,
      );
      await expectLater(
        session.persist!(),
        throwsA(isA<CredentialStorageException>()),
      );
      expect(
        store.values.values.any((v) => v.contains('refresh_token')),
        false,
      );
    },
  );
}

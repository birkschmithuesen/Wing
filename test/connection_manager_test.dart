import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'support/gateway_application_requests.dart';
import 'support/loopback_http_fixtures.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/dashboard_authentication.dart';
import 'package:wing/core/services/ws_client.dart';

/// Case-insensitive request header lookup — package:http normalises header
/// names when sending, so tests should not assume a particular casing.
String? _header(http.BaseRequest request, String name) {
  final lower = name.toLowerCase();
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return null;
}

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

void main() {
  test(
    'session mutation preserves structured refusal without retrying the write',
    () async {
      var calls = 0;
      final client = DashboardClient(
        host: 'hermes.example',
        port: 443,
        useHttps: true,
        proxied: true,
        httpClient: MockClient((request) async {
          calls++;
          expect(request.method, 'PATCH');
          return http.Response(
            jsonEncode({
              'detail': {
                'code': 'owner_unavailable',
                'message': 'The session owner is restarting.',
                'generation': 7,
              },
            }),
            503,
          );
        }),
      );
      addTearDown(client.close);
      try {
        await client.apiPatch('sessions/exact', body: {'title': 'Keep draft'});
        fail('Expected a refusal');
      } on DashboardHttpException catch (error) {
        expect(error.statusCode, 503);
        expect(error.endpoint, 'sessions/exact');
        expect(error.serverCode, 'owner_unavailable');
        expect(error.serverMessage, 'The session owner is restarting.');
        expect((error.responseDetail as Map)['generation'], 7);
        expect(
          () => (error.responseDetail as Map)['code'] = 'changed',
          throwsUnsupportedError,
        );
        expect(error.toString(), contains('owner is restarting'));
      }
      expect(calls, 1);
    },
  );

  test(
    'HTTP failure displays stock string detail but never an HTML error body',
    () {
      final stock = DashboardHttpException.response(
        http.Response(
          '{"detail":"owner_unavailable: profile is not served"}',
          503,
        ),
        'sessions/one',
      );
      expect(stock.toString(), contains('profile is not served'));
      final proxy = DashboardHttpException.response(
        http.Response('<html>proxy debug data</html>', 502),
        'sessions/one',
      );
      expect(proxy.toString(), 'HTTP 502');
    },
  );
  group('SavedConnection', () {
    test('normalizes bare HTTP gateway hosts with fallback port', () {
      final normalized = SavedConnection.normalizeHostAndPort(
        '192.168.1.50',
        8642,
      );

      expect(normalized.host, '192.168.1.50');
      expect(normalized.port, 8642);
      expect(normalized.useHttps, isFalse);
    });

    test('normalizes HTTPS URLs without an explicit port to 443', () {
      final normalized = SavedConnection.normalizeHostAndPort(
        'https://hermes.example.com',
        8642,
      );

      expect(normalized.host, 'hermes.example.com');
      expect(normalized.port, 443);
      expect(normalized.useHttps, isTrue);
    });

    test('normalizes HTTPS URLs with a custom fallback port', () {
      final normalized = SavedConnection.normalizeHostAndPort(
        'https://hermes.example.com',
        8443,
      );

      expect(normalized.host, 'hermes.example.com');
      expect(normalized.port, 8443);
      expect(normalized.useHttps, isTrue);
    });

    test('serializes HTTPS flag in current credential-free metadata', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Remote',
        host: 'hermes.example.com',
        port: 443,
        apiKey: 'key',
        useHttps: true,
      );

      expect(SavedConnection.fromMap(conn.toMap()).useHttps, isTrue);
      expect(
        SavedConnection.fromMap({
          'id': '2',
          'label': 'Local',
          'host': '192.168.1.50',
          'port': 8642,
        }).useHttps,
        isFalse,
      );
    });

    test('uses dashboard port 9119 for local gateway connections', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Home',
        host: '192.168.1.50',
        port: 8642,
        apiKey: 'key',
      );

      expect(conn.dashboardPort, 9119);
      expect(
        DashboardClient(host: conn.host, port: conn.dashboardPort).baseUrl,
        'http://192.168.1.50:9119',
      );
    });

    test('uses the HTTPS proxy port for dashboard calls over HTTPS', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Remote',
        host: 'hermes.example.com',
        port: 443,
        apiKey: 'key',
        useHttps: true,
      );

      expect(conn.dashboardPort, 443);
      expect(
        DashboardClient(
          host: conn.host,
          port: conn.dashboardPort,
          useHttps: conn.useHttps,
        ).baseUrl,
        'https://hermes.example.com:443',
      );
    });

    test('explicit dashboard port override wins over topology default', () {
      final local = SavedConnection(
        id: '1',
        label: 'Home',
        host: '192.168.1.50',
        port: 8642,
        apiKey: 'key',
        dashboardPortOverride: 30433,
      );
      expect(local.dashboardPort, 30433);

      final https = SavedConnection(
        id: '2',
        label: 'Remote',
        host: 'hermes.example.com',
        port: 443,
        apiKey: 'key',
        useHttps: true,
        dashboardPortOverride: 8443,
      );
      expect(https.dashboardPort, 8443);
    });

    test('serializes dashboard metadata without plaintext credentials', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Home',
        host: '192.168.1.50',
        port: 8642,
        apiKey: 'key',
        dashboardPortOverride: 30433,
        dashboardUsername: 'misha',
        dashboardPassword: 'secret',
      );

      final map = conn.toMap();
      final restored = SavedConnection.fromMap(map);
      expect(map, isNot(contains('api_key')));
      expect(map, isNot(contains('dashboard_password')));
      expect(restored.dashboardPortOverride, 30433);
      expect(restored.dashboardUsername, 'misha');
      expect(restored.apiKey, isEmpty);
      expect(restored.dashboardPassword, isNull);
      expect(restored.dashboardPort, 30433);
    });

    test('current local metadata has no optional dashboard configuration', () {
      final restored = SavedConnection.fromMap({
        'id': '2',
        'label': 'Local',
        'host': '192.168.1.50',
        'port': 8642,
      });
      expect(restored.dashboardPortOverride, isNull);
      expect(restored.dashboardUsername, isNull);
      expect(restored.dashboardPassword, isNull);
      expect(restored.dashboardPort, 9119);
    });

    test('metadata normalises blank dashboard account name to null', () {
      final restored = SavedConnection.fromMap({
        'id': '3',
        'label': 'Blank',
        'host': '192.168.1.50',
        'port': 8642,
        'dashboard_username': '   ',
      });
      expect(restored.dashboardUsername, isNull);
      expect(restored.dashboardPassword, isNull);
    });

    test('metadata rejects every credential-bearing field', () {
      for (final field in [
        'api_key',
        'dashboard_password',
        'gateway_headers',
        'dashboard_oauth',
      ]) {
        expect(
          () => SavedConnection.fromMap({
            'id': 'private',
            'label': 'Private',
            'host': 'hermes.example',
            field: null,
          }),
          throwsFormatException,
        );
      }
    });

    test('copyWith preserves unset fields and clears via flags', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Home',
        host: '192.168.1.50',
        port: 8642,
        apiKey: 'key',
        gatewayPrefix: '/profile/peter',
        dashboardPrefix: '/dashboard',
        dashboardProxied: true,
        dashboardPortOverride: 30433,
        dashboardUsername: 'misha',
        dashboardPassword: 'secret',
      );

      final keyOnly = conn.copyWith(apiKey: 'new-key');
      expect(keyOnly.apiKey, 'new-key');
      expect(keyOnly.gatewayPrefix, '/profile/peter');
      expect(keyOnly.dashboardPrefix, '/dashboard');
      expect(keyOnly.dashboardProxied, isTrue);
      expect(keyOnly.dashboardPortOverride, 30433);
      expect(keyOnly.dashboardUsername, 'misha');
      expect(keyOnly.dashboardPassword, 'secret');

      final cleared = conn.copyWith(
        clearGatewayPrefix: true,
        clearDashboardPrefix: true,
        clearDashboardPort: true,
        clearDashboardUsername: true,
        clearDashboardPassword: true,
      );
      expect(cleared.gatewayPrefix, isNull);
      expect(cleared.dashboardPrefix, isNull);
      expect(cleared.dashboardProxied, isTrue);
      expect(cleared.dashboardPortOverride, isNull);
      expect(cleared.dashboardUsername, isNull);
      expect(cleared.dashboardPassword, isNull);
      // Identity and unrelated fields are retained.
      expect(cleared.id, '1');
      expect(cleared.apiKey, 'key');
    });

    test('validates and resolves authoritative gateway header edits', () {
      final existing = <String, String>{
        'X-Access-Client': 'mobile',
        'X-Access-Secret': 'private-secret',
      };

      expect(resolveGatewayHeaderUpdate(existing, null), existing);
      expect(
        resolveGatewayHeaderUpdate(existing, <String, String?>{
          'x-access-secret': null,
          'X-New-Proxy': 'new-secret',
        }),
        <String, String>{
          'X-Access-Secret': 'private-secret',
          'X-New-Proxy': 'new-secret',
        },
      );
      expect(
        () => resolveGatewayHeaderUpdate(existing, <String, String?>{
          'X-Missing': null,
        }),
        throwsFormatException,
      );
      for (final invalid in <Map<String, String>>[
        <String, String>{'Bad Header': 'value'},
        <String, String>{'X-Blank': '   '},
        <String, String>{'X-Line': 'first\r\nsecond'},
        <String, String>{'Authorization': 'secret'},
        <String, String>{'X-Test': 'one', 'x-test': 'two'},
      ]) {
        expect(() => validateGatewayHeaders(invalid), throwsFormatException);
      }
    });
  });

  group('DashboardClient', () {
    for (final passwordAuth in [false, true]) {
      test(
        'closing a ${passwordAuth ? 'password' : 'token'} requester does not strand another reader',
        () async {
          final authentication = DashboardAuthentication();
          final entered = Completer<void>();
          final release = Completer<void>();
          var logins = 0;
          final apiReaders = <String>[];
          DashboardClient reader(String name) => DashboardClient(
            host: 'fixture.local',
            username: passwordAuth ? 'fixture' : null,
            password: passwordAuth ? 'fixture' : null,
            authentication: authentication,
            httpClient: MockClient((request) async {
              if (request.url.path ==
                  (passwordAuth ? '/auth/password-login' : '/')) {
                logins++;
                if (logins == 1) {
                  entered.complete();
                  await release.future;
                }
                return http.Response(
                  passwordAuth
                      ? '{}'
                      : 'window.__HERMES_SESSION_TOKEN__="fixture";',
                  200,
                  headers: {'set-cookie': 'hermes_session_at=fixture; Path=/'},
                );
              }
              apiReaders.add(name);
              return http.Response('{}', 200);
            }),
          );
          final departing = reader('departing');
          final remaining = reader('remaining');
          addTearDown(departing.close);
          addTearDown(remaining.close);
          final departed = expectLater(
            departing.apiGet('health'),
            throwsA(isA<http.RequestAbortedException>()),
          );
          await entered.future;
          final active = remaining.apiGet('health');
          departing.close();
          release.complete();
          await departed;
          expect(await active, isEmpty);
          expect(logins, 2);
          expect(apiReaders, ['remaining']);
        },
      );
    }

    test(
      'shared sign-in never forwards a cookie to a different origin',
      () async {
        final authentication = DashboardAuthentication();
        final logins = <String, int>{};
        DashboardClient client(String host, String prefix) => DashboardClient(
          host: host,
          pathPrefix: prefix,
          username: 'fixture',
          password: 'fixture',
          authentication: authentication,
          httpClient: MockClient((request) async {
            final origin =
                '${request.url.host}${request.url.path.split('/api/').first}';
            if (request.url.path.endsWith('/auth/password-login')) {
              logins[origin] = (logins[origin] ?? 0) + 1;
              return http.Response(
                '{}',
                200,
                headers: {
                  'set-cookie':
                      'hermes_session_at=${request.url.host}${prefix.replaceAll('/', '_')}; Path=/',
                },
              );
            }
            expect(
              _header(request, 'cookie'),
              'hermes_session_at=$host${prefix.replaceAll('/', '_')}',
            );
            return http.Response('{}', 200);
          }),
        );
        final readers = [
          client('a.example', ''),
          client('b.example', ''),
          client('a.example', '/other'),
        ];
        addTearDown(() {
          for (final reader in readers) {
            reader.close();
          }
        });
        await Future.wait(readers.map((reader) => reader.apiGet('health')));
        expect(logins.values, everyElement(1));
        expect(logins, hasLength(3));
      },
    );

    test(
      'logs in and authenticates /api calls with the session cookie',
      () async {
        var loginCalls = 0;
        final client = DashboardClient(
          host: 'hermes.local',
          port: 30433,
          username: 'misha',
          password: 'secret',
          httpClient: MockClient((request) async {
            if (request.url.path == '/auth/password-login') {
              loginCalls++;
              expect(request.method, 'POST');
              expect(jsonDecode(request.body), {
                'provider': 'basic',
                'username': 'misha',
                'password': 'secret',
              });
              return http.Response(
                '{"ok":true}',
                200,
                headers: {
                  'set-cookie':
                      'hermes_session_at=TOK123; Path=/; HttpOnly; SameSite=Lax',
                },
              );
            }
            if (request.url.path == '/api/model/info') {
              // Cookie auth, not the insecure token header.
              expect(_header(request, 'cookie'), 'hermes_session_at=TOK123');
              expect(_header(request, 'x-hermes-session-token'), isNull);
              return http.Response('{"model":"hermes-agent"}', 200);
            }
            return http.Response('not found', 404);
          }),
        );

        final info = await client.apiGet('model/info');
        expect(info['model'], 'hermes-agent');

        // A second call reuses the cached cookie (no re-login).
        await client.apiGet('model/info');
        expect(loginCalls, 1);
        client.close();
      },
    );

    for (final prefix in ['', '__Host-', '__Secure-']) {
      test('Webapp login retains scoped cookies and binding ($prefix)', () async {
        final client = DashboardClient(
          host: 'hermes.local',
          port: 9120,
          username: 'qa',
          password: 'secret',
          httpClient: MockClient((request) async {
            if (request.url.path == '/auth/password-login') {
              return http.Response(
                '{}',
                200,
                headers: {
                  'set-cookie':
                      '${prefix}hermes_session_at_abc="TOKEN"; Path=/; HttpOnly, '
                      '${prefix}hermes_session_rt_abc=REFRESH; Expires=Wed, 21 Oct 2030 07:28:00 GMT; Path=/, '
                      '${prefix}hermes_session_provider_abc=basic; Path=/, '
                      '${prefix}hermes_webapp_signin_abc=BINDING; Path=/, unrelated=ignore; Path=/',
                },
              );
            }
            expect(
              _header(request, 'cookie'),
              '${prefix}hermes_session_at_abc="TOKEN"; ${prefix}hermes_session_rt_abc=REFRESH; '
              '${prefix}hermes_session_provider_abc=basic; ${prefix}hermes_webapp_signin_abc=BINDING',
            );
            return http.Response('{}', 200);
          }),
        );
        addTearDown(client.close);
        await client.apiGet('health');
      });
    }

    test('falls back to homepage token scrape when no credentials', () async {
      final client = DashboardClient(
        host: 'hermes.local',
        port: 9119,
        httpClient: MockClient((request) async {
          if (request.url.path == '/') {
            return http.Response(
              '<script>window.__HERMES_SESSION_TOKEN__="SPA_TOK";</script>',
              200,
            );
          }
          if (request.url.path == '/api/model/info') {
            expect(_header(request, 'x-hermes-session-token'), 'SPA_TOK');
            expect(_header(request, 'cookie'), isNull);
            return http.Response('{"model":"hermes-agent"}', 200);
          }
          return http.Response('not found', 404);
        }),
      );

      final info = await client.apiGet('model/info');
      expect(info['model'], 'hermes-agent');
      client.close();
    });

    test('re-authenticates once on a 401 from an /api call', () async {
      var apiCalls = 0;
      var loginCalls = 0;
      final client = DashboardClient(
        host: 'hermes.local',
        port: 30433,
        username: 'misha',
        password: 'secret',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/password-login') {
            loginCalls++;
            final cookie = 'hermes_session_at=TOK$loginCalls';
            return http.Response(
              '{"ok":true}',
              200,
              headers: {'set-cookie': '$cookie; Path=/'},
            );
          }
          if (request.url.path == '/api/model/info') {
            apiCalls++;
            // First attempt: stale cookie → 401. Retry: succeeds.
            if (apiCalls == 1) return http.Response('unauthorized', 401);
            expect(_header(request, 'cookie'), 'hermes_session_at=TOK2');
            return http.Response('{"model":"hermes-agent"}', 200);
          }
          return http.Response('not found', 404);
        }),
      );

      final info = await client.apiGet('model/info');
      expect(info['model'], 'hermes-agent');
      expect(apiCalls, 2);
      expect(loginCalls, 2);
      client.close();
    });

    test(
      'late stale-cookie failures across readers reuse the refreshed sign-in',
      () async {
        var logins = 0;
        final staleRequests = Completer<void>();
        final releaseLateFailure = Completer<void>();
        var requests = 0;
        final authentication = DashboardAuthentication();
        DashboardClient reader() => DashboardClient(
          host: 'hermes.local',
          port: 30433,
          username: 'fixture',
          password: 'fixture',
          authentication: authentication,
          httpClient: MockClient((request) async {
            if (request.url.path == '/auth/password-login') {
              logins++;
              return http.Response(
                '{}',
                200,
                headers: {
                  'set-cookie': 'hermes_session_at=session$logins; Path=/',
                },
              );
            }
            if (_header(request, 'cookie') == 'hermes_session_at=session1') {
              requests++;
              if (requests == 2) staleRequests.complete();
              await staleRequests.future;
              if (request.url.path.endsWith('/late')) {
                await releaseLateFailure.future;
              }
              return http.Response('', 401);
            }
            return http.Response('{}', 200);
          }),
        );
        final client = reader();
        final other = reader();
        addTearDown(client.close);
        addTearDown(other.close);
        final first = client.apiGet('first');
        final late = other.apiGet('late');
        await first;
        releaseLateFailure.complete();
        await late;
        expect(
          logins,
          2,
          reason: 'a delayed 401 must not discard fresh authentication',
        );
      },
    );

    test('surfaces invalid dashboard credentials', () async {
      final client = DashboardClient(
        host: 'hermes.local',
        port: 30433,
        username: 'misha',
        password: 'wrong',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/password-login') {
            return http.Response('{"detail":"Invalid credentials"}', 401);
          }
          return http.Response('not found', 404);
        }),
      );

      await expectLater(
        client.apiGet('model/info'),
        throwsA(
          isA<DashboardHttpException>()
              .having((error) => error.statusCode, 'status', 401)
              .having(
                (error) => error.endpoint,
                'endpoint',
                'auth/password-login',
              ),
        ),
      );
      client.close();
    });

    test(
      'mints a WebSocket ticket with the dashboard session cookie',
      () async {
        final client = DashboardClient(
          host: 'desktop.hermes.local',
          port: 443,
          useHttps: true,
          username: 'misha',
          password: 'secret',
          httpClient: MockClient((request) async {
            if (request.url.path == '/auth/password-login') {
              return http.Response(
                '{"ok":true}',
                200,
                headers: {'set-cookie': 'hermes_session_at=TOK123; Path=/'},
              );
            }
            if (request.url.path == '/api/auth/ws-ticket') {
              expect(request.method, 'POST');
              expect(_header(request, 'cookie'), 'hermes_session_at=TOK123');
              return http.Response('{"ticket":"ONE_TIME_TICKET"}', 200);
            }
            return http.Response('not found', 404);
          }),
        );

        await expectLater(
          client.mintWebSocketTicket(),
          completion('ONE_TIME_TICKET'),
        );
        client.close();
      },
    );
  });

  group('ConnectionManager', () {
    test(
      'password sign-in survives route closure and replaces changed credentials',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final store = _MemoryCredentialStore();
        final manager = await ConnectionManager.create(
          prefs,
          credentialStore: store,
        );
        final saved = await manager.saveConnection(
          'Fixture',
          'hermes.local',
          9119,
          '',
          dashboardUsername: 'fixture',
          dashboardPassword: 'first',
        );
        var logins = 0;
        final loginEntered = Completer<void>();
        final releaseLogin = Completer<void>();
        DashboardClient reader(ConnectionAccess access) => DashboardClient(
          host: access.connection.host,
          port: access.connection.dashboardPort,
          username: access.connection.dashboardUsername,
          password: access.connection.dashboardPassword,
          authentication: access.dashboardAuthentication,
          httpClient: MockClient((request) async {
            if (request.url.path == '/auth/password-login') {
              logins++;
              if (logins == 1) {
                loginEntered.complete();
                await releaseLogin.future;
              }
              final body = jsonDecode(request.body) as Map;
              return http.Response(
                '{}',
                200,
                headers: {
                  'set-cookie': 'hermes_session_at=${body['password']}; Path=/',
                },
              );
            }
            expect(
              _header(request, 'cookie'),
              'hermes_session_at=${access.connection.dashboardPassword}',
            );
            return http.Response('{}', 200);
          }),
        );
        final first = reader(manager.accessFor(saved));
        final concurrent = reader(manager.accessFor(saved));
        addTearDown(first.close);
        addTearDown(concurrent.close);
        final reads = [first.apiGet('health'), concurrent.apiGet('health')];
        await loginEntered.future;
        expect(logins, 1);
        releaseLogin.complete();
        await Future.wait(reads);
        first.close();
        concurrent.close();
        await manager.updateConnection(
          saved.id,
          'Renamed',
          'hermes.local',
          9119,
          '',
          dashboardUsername: 'fixture',
          dashboardPassword: 'first',
        );
        final anotherManager = await ConnectionManager.create(
          prefs,
          credentialStore: store,
        );
        final renamed = reader(
          anotherManager.accessFor(anotherManager.getConnections().single),
        );
        addTearDown(renamed.close);
        await renamed.apiGet('health');
        expect(
          logins,
          1,
          reason: 'Routes and label edits retain the saved sign-in.',
        );
        await manager.updateConnection(
          saved.id,
          'Renamed',
          'hermes.local',
          9119,
          '',
          dashboardUsername: 'fixture',
          dashboardPassword: 'second',
        );
        expect(() => manager.accessFor(saved), throwsStateError);
        final changed = reader(
          manager.accessFor(manager.getConnections().single),
        );
        addTearDown(changed.close);
        await changed.apiGet('health');
        expect(
          logins,
          2,
          reason: 'Replaced credentials need their own sign-in.',
        );
        await manager.deleteConnection(saved.id);
        expect(() => manager.accessFor(saved), throwsStateError);
      },
    );

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
    });

    test('saveConnection persists dashboard port and credentials', () async {
      final prefs = await SharedPreferences.getInstance();
      final mgr = await ConnectionManager.create(
        prefs,
        credentialStore: _MemoryCredentialStore(),
      );
      await mgr.saveConnection(
        'Home',
        '192.168.1.50',
        8642,
        'key',
        dashboardPort: 30433,
        dashboardUsername: 'misha',
        dashboardPassword: 'secret',
      );

      final conn = mgr.getConnections().single;
      expect(conn.dashboardPortOverride, 30433);
      expect(conn.dashboardUsername, 'misha');
      expect(conn.dashboardPassword, 'secret');
    });

    test('full connection edit sets then clears dashboard fields', () async {
      final prefs = await SharedPreferences.getInstance();
      final mgr = await ConnectionManager.create(
        prefs,
        credentialStore: _MemoryCredentialStore(),
      );
      await mgr.saveConnection('Home', '192.168.1.50', 8642, 'key');

      final captured = mgr.getConnections().single;
      await mgr.updateConnection(
        captured.id,
        captured.label,
        Uri(
          scheme: captured.useHttps ? 'https' : 'http',
          host: captured.host,
        ).toString(),
        captured.port,
        captured.apiKey,
        icon: captured.icon,
        gatewayPrefix: '/profile/peter',
        dashboardPrefix: '/dashboard',
        dashboardProxied: true,
        desktopGatewayUrl: captured.desktopGatewayUrl,
        dashboardPort: 30433,
        dashboardUsername: 'misha',
        dashboardPassword: 'secret',
        cloudInstanceId: captured.cloudInstanceId,
        cloudOrganization: captured.cloudOrganization,
        dashboardGrant: captured.dashboardGrant,
        gatewayHeaders: captured.gatewayHeaders,
      );
      var conn = mgr.getConnections().single;
      expect(conn.gatewayPrefix, '/profile/peter');
      expect(conn.dashboardPrefix, '/dashboard');
      expect(conn.dashboardProxied, isTrue);
      expect(conn.dashboardPortOverride, 30433);
      expect(conn.dashboardUsername, 'misha');
      expect(conn.dashboardPassword, 'secret');

      // Blank values clear the corresponding fields.
      await mgr.updateConnection(
        conn.id,
        conn.label,
        Uri(
          scheme: conn.useHttps ? 'https' : 'http',
          host: conn.host,
        ).toString(),
        conn.port,
        conn.apiKey,
        icon: conn.icon,
        gatewayPrefix: '',
        dashboardPrefix: '',
        dashboardProxied: false,
        desktopGatewayUrl: conn.desktopGatewayUrl,
        dashboardPort: null,
        dashboardUsername: '',
        dashboardPassword: '',
        cloudInstanceId: conn.cloudInstanceId,
        cloudOrganization: conn.cloudOrganization,
        dashboardGrant: conn.dashboardGrant,
        gatewayHeaders: conn.gatewayHeaders,
      );
      conn = mgr.getConnections().single;
      expect(conn.gatewayPrefix, isNull);
      expect(conn.dashboardPrefix, isNull);
      expect(conn.dashboardProxied, isFalse);
      expect(conn.dashboardPortOverride, isNull);
      expect(conn.dashboardUsername, isNull);
      expect(conn.dashboardPassword, isNull);
    });

    test('full connection key edit preserves dashboard credentials', () async {
      final prefs = await SharedPreferences.getInstance();
      final mgr = await ConnectionManager.create(
        prefs,
        credentialStore: _MemoryCredentialStore(),
      );
      await mgr.saveConnection(
        'Home',
        '192.168.1.50',
        8642,
        'key',
        dashboardPort: 30433,
        dashboardUsername: 'misha',
        dashboardPassword: 'secret',
      );

      final captured = mgr.getConnections().single;
      await mgr.updateConnection(
        captured.id,
        captured.label,
        Uri(
          scheme: captured.useHttps ? 'https' : 'http',
          host: captured.host,
        ).toString(),
        captured.port,
        'new-key',
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
      final conn = mgr.getConnections().single;
      expect(conn.apiKey, 'new-key');
      expect(conn.dashboardPortOverride, 30433);
      expect(conn.dashboardUsername, 'misha');
      expect(conn.dashboardPassword, 'secret');
    });

    test(
      'updateConnection edits host, port, key, and clears optional fields',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final mgr = await ConnectionManager.create(
          prefs,
          credentialStore: _MemoryCredentialStore(),
        );
        await mgr.saveConnection(
          'Home',
          '192.168.1.50',
          8642,
          'key',
          gatewayPrefix: '/old-gateway',
          dashboardPrefix: '/old-dashboard',
          dashboardProxied: true,
          dashboardPort: 30433,
          dashboardUsername: 'misha',
          dashboardPassword: 'secret',
        );
        final id = mgr.getConnections().single.id;

        await mgr.updateConnection(
          id,
          'Moved',
          'https://hermes.example.com',
          8642,
          'new-key',
          gatewayPrefix: '',
          dashboardPrefix: '',
          dashboardProxied: false,
          dashboardUsername: '',
          dashboardPassword: '',
        );

        final conn = mgr.getConnections().single;
        expect(conn.id, id);
        expect(conn.label, 'Moved');
        expect(conn.host, 'hermes.example.com');
        expect(conn.port, 443);
        expect(conn.useHttps, isTrue);
        expect(conn.apiKey, 'new-key');
        expect(conn.gatewayPrefix, isNull);
        expect(conn.dashboardPrefix, isNull);
        expect(conn.dashboardProxied, isFalse);
        expect(conn.dashboardPortOverride, isNull);
        expect(conn.dashboardUsername, isNull);
        expect(conn.dashboardPassword, isNull);
      },
    );
  });

  group('Path prefix support', () {
    test('joinBaseUrl without prefix returns baseUrl unchanged', () {
      expect(
        SavedConnection.joinBaseUrl('https://hermes.example.com:443', ''),
        'https://hermes.example.com:443',
      );
    });

    test('joinBaseUrl appends prefix between base and API path', () {
      expect(
        SavedConnection.joinBaseUrl(
          'https://hermes.example.com:443',
          '/profile/peter',
        ),
        'https://hermes.example.com:443/profile/peter',
      );
    });

    test('DashboardClient uses pathPrefix', () {
      final client = DashboardClient(
        host: 'hermes.example.com',
        port: 443,
        useHttps: true,
        pathPrefix: '/dashboard',
      );
      expect(client.baseUrl, 'https://hermes.example.com:443/dashboard');
      client.close();
    });

    test('DashboardClient proxied sends no auth headers', () async {
      final client = DashboardClient(
        host: 'hermes.example.com',
        port: 443,
        useHttps: true,
        pathPrefix: '/dashboard',
        proxied: true,
        httpClient: MockClient((request) async {
          expect(
            request.headers.containsKey('x-hermes-session-token'),
            isFalse,
          );
          expect(request.headers.containsKey('cookie'), isFalse);
          return http.Response('{"data": {}}', 200);
        }),
      );
      await client.apiGet('model/info');
      client.close();
    });

    test(
      'DashboardClient proxied ignores credentials, sends clean headers',
      () async {
        final client = DashboardClient(
          host: 'hermes.example.com',
          port: 443,
          useHttps: true,
          pathPrefix: '/dashboard',
          proxied: true,
          username: 'user',
          password: 'pass',
          httpClient: MockClient((request) async {
            expect(
              request.headers.containsKey('x-hermes-session-token'),
              isFalse,
            );
            expect(request.headers.containsKey('cookie'), isFalse);
            return http.Response('{"data": {}}', 200);
          }),
        );
        await client.apiGet('model/info');
        client.close();
      },
    );

    test('SavedConnection serializes gateway and dashboard prefixes', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Proxy',
        host: 'hermes.example.com',
        port: 443,
        apiKey: 'key',
        useHttps: true,
        gatewayPrefix: '/profile/peter',
        dashboardPrefix: '/dashboard',
        dashboardProxied: true,
      );
      final map = conn.toMap();
      expect(map['gateway_prefix'], '/profile/peter');
      expect(map['dashboard_prefix'], '/dashboard');
      expect(map['dashboard_proxied'], true);
    });

    test('SavedConnection preserves an optional Desktop gateway URL', () {
      final conn = SavedConnection(
        id: '1',
        label: 'ATLAS',
        host: 'hermes-api.example.lan',
        port: 443,
        apiKey: 'key',
        useHttps: true,
        desktopGatewayUrl: 'https://hermes-desktop.example.lan',
      );

      final restored = SavedConnection.fromMap(conn.toMap());
      expect(restored.desktopGatewayUrl, 'https://hermes-desktop.example.lan');
    });
  });

  group('Desktop gateway WebSocket URL', () {
    useRealHttpClientsForLoopbackFixtures();

    test('uses a ticket for a secured Desktop gateway', () {
      expect(
        WsClient.buildWebSocketUrl(
          'https://hermes-desktop.example.lan',
          ticket: 'one time+ticket',
        ),
        'wss://hermes-desktop.example.lan/api/ws?ticket=one+time%2Bticket',
      );
    });

    test('keeps legacy token support for insecure gateways', () {
      expect(
        WsClient.buildWebSocketUrl('http://hermes.local:9119', token: 'spa'),
        'ws://hermes.local:9119/api/ws?token=spa',
      );
    });

    test(
      'pins an immutable gateway.ready received before its waiter',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final applicationEvents = <StreamEvent>[];
        final readyFrame = <String, dynamic>{
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {
              'capabilities': ['turn.resume', 'turn.recover'],
              'limits': {
                'recovery': {'max_attempts': 2},
              },
            },
          },
        };
        final socketSubscription = server
            .transform(WebSocketTransformer())
            .listen((socket) {
              socket.add(jsonEncode(readyFrame));
            });
        final client = WsClient('http://127.0.0.1:${server.port}')
          ..onStreamEvent = applicationEvents.add;

        try {
          await client.connect();
          final frame = await client.waitForGatewayReady();

          expect(frame, readyFrame);
          expect(applicationEvents, isEmpty);
          expect(
            () => (frame['params'] as Map<String, dynamic>)['type'] = 'drift',
            throwsUnsupportedError,
          );
          final payload =
              (frame['params'] as Map<String, dynamic>)['payload']
                  as Map<String, dynamic>;
          final limits = payload['limits'] as Map<String, dynamic>;
          expect(
            () => (limits['recovery'] as Map<String, dynamic>)['max_attempts'] =
                99,
            throwsUnsupportedError,
          );
          expect(
            () => (payload['capabilities'] as List<dynamic>).add('unsafe'),
            throwsUnsupportedError,
          );
        } finally {
          client.close();
          await socketSubscription.cancel();
          await server.close(force: true);
        }
      },
    );

    test('delivers gateway.ready to a waiter registered first', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketSeen = Completer<WebSocket>();
      final socketSubscription = server
          .transform(WebSocketTransformer())
          .listen((socket) {
            socketSeen.complete(socket);
          });
      final client = WsClient('http://127.0.0.1:${server.port}');

      try {
        await client.connect();
        final readyFuture = client.waitForGatewayReady();
        final socket = await socketSeen.future;
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'generation': 1},
            },
          }),
        );

        final frame = await readyFuture.timeout(const Duration(seconds: 5));
        expect((frame['params'] as Map<String, dynamic>)['payload'], {
          'generation': 1,
        });
      } finally {
        client.close();
        await socketSubscription.cancel();
        await server.close(force: true);
      }
    });

    test('fails a gateway.ready waiter when the socket closes first', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketSeen = Completer<WebSocket>();
      final socketSubscription = server
          .transform(WebSocketTransformer())
          .listen((socket) {
            socketSeen.complete(socket);
          });
      final client = WsClient('http://127.0.0.1:${server.port}');

      try {
        await client.connect();
        final failed = expectLater(
          client.waitForGatewayReady(timeout: const Duration(seconds: 5)),
          throwsA(
            isA<JsonRpcError>()
                .having((error) => error.method, 'method', 'gateway.ready')
                .having((error) => error.reason, 'reason', 'connection_closed'),
          ),
        );
        final socket = await socketSeen.future;
        await socket.close(WebSocketStatus.goingAway, 'no ready');
        await failed;
      } finally {
        client.close();
        await socketSubscription.cancel();
        await server.close(force: true);
      }
    });

    test(
      'invalidates buffered frames from a closed socket across reconnect',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final firstSocketSeen = Completer<WebSocket>();
        final secondSocketSeen = Completer<WebSocket>();
        var connectionCount = 0;
        final socketSubscription = server
            .transform(WebSocketTransformer())
            .listen((socket) {
              connectionCount += 1;
              gatewayApplicationRequests(socket).listen((_) {});
              if (connectionCount == 1) {
                firstSocketSeen.complete(socket);
              } else {
                secondSocketSeen.complete(socket);
              }
            });
        final eventTexts = <String>[];
        final newEventSeen = Completer<void>();
        final connectionChanges = <bool>[];
        final client = WsClient('http://127.0.0.1:${server.port}')
          ..onStreamEvent = (event) {
            eventTexts.add(event.data['text'] as String);
            if (event.data['text'] == 'new' && !newEventSeen.isCompleted) {
              newEventSeen.complete();
            }
          }
          ..onConnectionChanged = connectionChanges.add;

        try {
          await client.connect();
          final firstSocket = await firstSocketSeen.future;
          firstSocket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'gateway.ready',
                'payload': {'generation': 1},
              },
            }),
          );
          firstSocket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'message.delta',
                'session_id': 'old-session',
                'payload': {'text': 'old'},
              },
            }),
          );
          client.close();

          await client.connect();
          final secondSocket = await secondSocketSeen.future;
          secondSocket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'gateway.ready',
                'payload': {'generation': 2},
              },
            }),
          );
          secondSocket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'message.delta',
                'session_id': 'new-session',
                'payload': {'text': 'new'},
              },
            }),
          );

          final ready = await client.waitForGatewayReady();
          await newEventSeen.future.timeout(const Duration(seconds: 5));
          expect(
            ((ready['params'] as Map<String, dynamic>)['payload']
                as Map<String, dynamic>)['generation'],
            2,
          );
          final greeting = await client.waitForGatewayReady();
          expect((greeting['params'] as Map<String, dynamic>)['payload'], {
            'generation': 2,
          });
          expect(eventTexts, ['new']);
          expect(connectionChanges, [true, false, true]);
        } finally {
          client.close();
          await socketSubscription.cancel();
          await server.close(force: true);
        }
      },
    );

    test('isolates throwing connected and disconnected observers', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSocketClosed = Completer<void>();
      final socketSubscription = server
          .transform(WebSocketTransformer())
          .listen((socket) {
            gatewayApplicationRequests(socket).listen(
              (_) {},
              onDone: () {
                if (!serverSocketClosed.isCompleted) {
                  serverSocketClosed.complete();
                }
              },
            );
          });
      final connectionChanges = <bool>[];
      final client = WsClient('http://127.0.0.1:${server.port}')
        ..onConnectionChanged = (connected) {
          connectionChanges.add(connected);
          throw StateError('synthetic connection observer failure');
        };

      try {
        await client.connect();
        expect(connectionChanges, [true]);
        expect(() => client.close(), returnsNormally);
        await serverSocketClosed.future.timeout(const Duration(seconds: 5));
        expect(connectionChanges, [true, false]);
      } finally {
        client.close();
        await socketSubscription.cancel();
        await server.close(force: true);
      }
    });

    test(
      'ignores an exact ready duplicate and closes on ready drift',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final applicationEvents = <StreamEvent>[];
        final connectionChanges = <bool>[];
        final disconnected = Completer<void>();
        final serverSocketClosed = Completer<void>();
        final socketSeen = Completer<WebSocket>();
        final firstFrame = <String, dynamic>{
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {
              'capabilities': ['turn.resume'],
            },
          },
        };
        final socketSubscription = server
            .transform(WebSocketTransformer())
            .listen((socket) {
              gatewayApplicationRequests(socket).listen(
                (_) {},
                onDone: () {
                  if (!serverSocketClosed.isCompleted) {
                    serverSocketClosed.complete();
                  }
                },
              );
              socket.add(jsonEncode(firstFrame));
              socket.add(jsonEncode(firstFrame));
              socketSeen.complete(socket);
            });
        final client = WsClient('http://127.0.0.1:${server.port}')
          ..onStreamEvent = applicationEvents.add
          ..onConnectionChanged = (connected) {
            connectionChanges.add(connected);
            if (!connected && !disconnected.isCompleted) {
              disconnected.complete();
              throw StateError('synthetic observer failure');
            }
          };

        try {
          await client.connect();
          expect(await client.waitForGatewayReady(), firstFrame);
          final socket = await socketSeen.future;
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'gateway.ready',
                'payload': {
                  'capabilities': ['turn.resume', 'unexpected'],
                },
              },
            }),
          );
          await disconnected.future.timeout(const Duration(seconds: 5));
          await serverSocketClosed.future.timeout(const Duration(seconds: 5));

          expect(applicationEvents, isEmpty);
          expect(connectionChanges, [true, false]);
          await expectLater(
            client.waitForGatewayReady(),
            throwsA(
              isA<JsonRpcError>().having(
                (error) => error.reason,
                'reason',
                'gateway_ready_drift',
              ),
            ),
          );
        } finally {
          client.close();
          await socketSubscription.cancel();
          await server.close(force: true);
        }
      },
    );

    test('unwraps a gateway event into its session payload', () {
      final event = WsClient.parseGatewayEvent({
        'type': 'message.delta',
        'sid': 'session-123',
        'payload': {'text': 'Hello'},
      });

      expect(event, isNotNull);
      expect(event!.type, 'message.delta');
      expect(event.data, {'text': 'Hello', 'session_id': 'session-123'});
    });

    test('unwraps the real gateway session_id event field', () {
      final event = WsClient.parseGatewayEvent({
        'type': 'message.delta',
        'session_id': 'gateway-session-123',
        'payload': {'text': 'Hello'},
      });

      expect(event, isNotNull);
      expect(event!.data, {
        'text': 'Hello',
        'session_id': 'gateway-session-123',
      });
    });

    test('snapshots the original immutable event envelope', () {
      final params = <String, dynamic>{
        'type': 'message.delta',
        'session_id': 'gateway-session-123',
        'turn_id': 'turn-456',
        'seq': 7,
        'message_id': 'message-789',
        'payload': {
          'text': 'Hello',
          'nested': {
            'parts': ['one', 'two'],
          },
        },
      };
      final event = WsClient.parseGatewayEvent(params);

      expect(event, isNotNull);
      expect(event!.sessionId, 'gateway-session-123');
      expect(event.envelope['turn_id'], 'turn-456');
      expect(event.envelope['seq'], 7);
      expect(event.envelope['message_id'], 'message-789');
      expect(event.envelope, params);

      (params['payload'] as Map<String, dynamic>)['text'] = 'mutated source';
      params['turn_id'] = 'mutated source';
      expect(event.data['text'], 'Hello');
      expect(event.envelope['turn_id'], 'turn-456');
      expect(
        () =>
            ((event.data['nested'] as Map<String, dynamic>)['parts']
                    as List<dynamic>)
                .add('three'),
        throwsUnsupportedError,
      );
      expect(() => event.envelope['seq'] = 8, throwsUnsupportedError);
    });

    test('ignores wrong-typed session routing identity', () {
      final event = WsClient.parseGatewayEvent({
        'type': 'message.delta',
        'session_id': 123,
        'sid': false,
        'turn_id': 456,
        'seq': '7',
        'message_id': 789,
        'payload': {'text': 'Hello'},
      });

      expect(event, isNotNull);
      expect(event!.sessionId, isNull);
      expect(event.data.containsKey('session_id'), isFalse);
    });

    test('rejects untrimmed control or overbound session routing identity', () {
      final invalidIds = <String>[
        ' leading',
        'trailing ',
        'line\nbreak',
        'delete\u007fcontrol',
        'c1\u0085control',
        List<String>.filled(257, 'x').join(),
      ];

      for (final invalidId in invalidIds) {
        final event = WsClient.parseGatewayEvent({
          'type': 'message.delta',
          'session_id': invalidId,
          'sid': false,
          'turn_id': invalidId,
          'seq': 1,
          'message_id': invalidId,
          'payload': {'text': 'Hello'},
        });

        expect(event, isNotNull, reason: invalidId);
        expect(event!.sessionId, isNull, reason: invalidId);
        expect(
          event.data.containsKey('session_id'),
          isFalse,
          reason: invalidId,
        );
      }

      final boundaryId = List<String>.filled(256, 'x').join();
      final boundaryEvent = WsClient.parseGatewayEvent({
        'type': 'message.delta',
        'session_id': boundaryId,
        'turn_id': boundaryId,
        'seq': 1,
        'message_id': boundaryId,
        'payload': const <String, dynamic>{},
      });
      expect(boundaryEvent?.sessionId, boundaryId);
    });

    test('preserves a gateway turn error event type', () {
      final event = WsClient.parseGatewayEvent({
        'type': 'turn.error',
        'sid': 'session-123',
        'payload': {'message': 'failed'},
      });

      expect(event?.type, 'turn.error');
    });

    test('preserves the real gateway message.complete event type', () {
      final event = WsClient.parseGatewayEvent({
        'type': 'message.complete',
        'sid': 'session-123',
        'payload': {'text': 'Done', 'status': 'complete'},
      });

      expect(event?.type, 'message.complete');
    });

    test('preserves the real gateway error event type', () {
      final event = WsClient.parseGatewayEvent({
        'type': 'error',
        'sid': 'session-123',
        'payload': {'message': 'failed'},
      });

      expect(event?.type, 'error');
    });

    test('omits bare custom provider from an early session model switch', () {
      expect(
        WsClient.buildSessionModelValue(
          provider: 'custom',
          model: 'wing-fixture',
        ),
        'wing-fixture --session',
      );
      expect(
        WsClient.buildSessionModelValue(
          provider: 'anthropic',
          model: 'claude-sonnet-4.6',
        ),
        'claude-sonnet-4.6 --provider anthropic --session',
      );
    });
  });
}

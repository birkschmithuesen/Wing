import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/services/versions_controller.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'profile admission holds REST browsing until its store is ready',
    () async {
      final fixture = await _ProfileAdmissionHost.start();
      addTearDown(fixture.close);
      final connectionChanges = <bool>[];
      fixture.gateway.onConnectionChanged = connectionChanges.add;
      final browsing = () async {
        await fixture.gateway.connect();
        return fixture.gateway.read('sessions');
      }();
      final request = await fixture.admission.future.timeout(
        const Duration(seconds: 2),
      );
      expect(request['params'], {'profile': 'fresh-profile', 'limit': 1});
      expect(fixture.sessionReads, 0);
      expect(connectionChanges, isEmpty);

      fixture.reply(request, result: {'sessions': []});
      expect(await browsing, {'sessions': []});
      expect(fixture.sessionReads, 1);
      expect(connectionChanges, [true]);
    },
  );

  test(
    'rejected profile admission closes the socket without admitting it',
    () async {
      final fixture = await _ProfileAdmissionHost.start();
      addTearDown(fixture.close);
      final connectionChanges = <bool>[];
      fixture.gateway.onConnectionChanged = connectionChanges.add;
      final rejected = expectLater(
        fixture.gateway.connect(),
        throwsA(
          isA<JsonRpcError>().having(
            (error) => error.message,
            'message',
            'Profile store unavailable',
          ),
        ),
      );
      final request = await fixture.admission.future.timeout(
        const Duration(seconds: 2),
      );
      fixture.reply(
        request,
        error: {'code': -32000, 'message': 'Profile store unavailable'},
      );
      await rejected;
      await fixture.socketClosed.future.timeout(const Duration(seconds: 2));
      expect(connectionChanges, isNot(contains(true)));
    },
  );

  test('closing a profile cancels its pending store admission', () async {
    final fixture = await _ProfileAdmissionHost.start();
    addTearDown(fixture.close);
    final status = ServerConnectionStatus('Fixture');
    addTearDown(status.dispose);
    fixture.gateway.connectionStatus = status;
    final rejected = expectLater(
      fixture.gateway.connect(),
      throwsA(
        isA<JsonRpcError>().having(
          (error) => error.reason,
          'reason',
          'connection_closed',
        ),
      ),
    );
    await fixture.admission.future.timeout(const Duration(seconds: 2));
    fixture.gateway.close();
    await rejected;
    await fixture.socketClosed.future.timeout(const Duration(seconds: 2));
    expect(status.hasLiveObservation('fresh-profile'), isFalse);
  });

  test(
    'disconnect retires pending admission and permits a fresh connection',
    () async {
      final fixture = await _ProfileAdmissionHost.start();
      addTearDown(fixture.close);
      final connectionChanges = <bool>[];
      fixture.gateway.onConnectionChanged = connectionChanges.add;
      final rejected = expectLater(
        fixture.gateway.connect(),
        throwsA(
          isA<JsonRpcError>().having(
            (error) => error.reason,
            'reason',
            'connection_closed',
          ),
        ),
      );
      await fixture.admission.future.timeout(const Duration(seconds: 2));
      fixture.gateway.disconnect();
      await rejected;
      await fixture.socketClosed.future.timeout(const Duration(seconds: 2));
      expect(connectionChanges, isNot(contains(true)));

      fixture.admission = Completer<Map<String, dynamic>>();
      fixture.socketClosed = Completer<void>();
      final reconnected = fixture.gateway.connect();
      final request = await fixture.admission.future.timeout(
        const Duration(seconds: 2),
      );
      fixture.reply(request, result: {'sessions': []});
      await reconnected;
      expect(connectionChanges, [true]);
    },
  );

  test(
    'a retired connect failure cannot mark a newer connection unavailable',
    () async {
      final retired = Completer<void>();
      var attempts = 0;
      final status = ServerConnectionStatus('Fixture');
      addTearDown(status.dispose);
      final gateway = ProfileGateway(
        scope: WorkspaceScope(connectionId: 'fixture', profileName: 'work'),
        get: (_, _) async => {},
        rpc: (_, _) async => {},
        discover: () async =>
            throw StateError('Discovery is not part of connection admission'),
        connect: () => ++attempts == 1 ? retired.future : Future<void>.value(),
      )..connectionStatus = status;
      addTearDown(gateway.close);
      final rejected = expectLater(
        gateway.connect(),
        throwsA(isA<JsonRpcError>()),
      );
      gateway.disconnect();
      await gateway.connect();
      retired.completeError(
        JsonRpcError(
          'session.list',
          'Retired socket closed',
          reason: 'connection_closed',
        ),
      );
      await rejected;
      expect(status.liveAvailable('work'), isTrue);
    },
  );

  test(
    'a retired RPC failure leaves the replacement connection usable',
    () async {
      final retired = Completer<Map<String, dynamic>>();
      final failure = JsonRpcError(
        'session.list',
        'Retired socket closed',
        reason: 'connection_closed',
      );
      var connected = false;
      var reads = 0;
      final status = ServerConnectionStatus('Fixture');
      addTearDown(status.dispose);
      final gateway = ProfileGateway(
        scope: WorkspaceScope(connectionId: 'fixture', profileName: 'work'),
        get: (_, _) async => {},
        rpc: (_, _) {
          if (!connected) throw StateError('Connection was disconnected');
          return reads++ == 0 ? retired.future : Future.value({'sessions': []});
        },
        discover: () async =>
            throw StateError('Discovery is not part of RPC recovery'),
        connect: () async {
          connected = true;
        },
        disconnect: () {
          connected = false;
        },
      )..connectionStatus = status;
      addTearDown(gateway.close);
      final interruptions = <bool>[];
      gateway.onConnectionChanged = interruptions.add;
      await gateway.connect();
      final rejected = expectLater(
        gateway.call('session.list'),
        throwsA(same(failure)),
      );
      gateway.disconnect();
      await gateway.connect();

      retired.completeError(failure);
      await rejected;
      expect(await gateway.call('session.list'), {'sessions': []});
      expect(status.liveAvailable('work'), isTrue);
      expect(interruptions, isEmpty);
    },
  );

  test('profile and Versions readers reuse one password sign-in', () async {
    SharedPreferences.setMockInitialValues({});
    var logins = 0;
    final host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    host.listen((request) async {
      await request.drain<void>();
      final response = request.response;
      response.headers.contentType = ContentType.json;
      if (request.uri.path == '/auth/password-login') {
        logins++;
        if (logins > 10) {
          response.statusCode = HttpStatus.tooManyRequests;
          response.write(jsonEncode({'detail': 'Too many login attempts.'}));
        } else {
          response.headers.add(
            'set-cookie',
            'hermes_session_at=fixture; Path=/',
          );
          response.write(jsonEncode({'ok': true}));
        }
      } else {
        expect(request.headers.value('cookie'), 'hermes_session_at=fixture');
        response.write(
          jsonEncode(
            request.uri.path == '/api/health'
                ? {'ok': true, 'version': '1.2.3'}
                : {
                    'current_version': '1.2.3',
                    'update_available': false,
                    'behind': 0,
                  },
          ),
        );
      }
      await response.close();
    });
    addTearDown(() => host.close(force: true));
    final access = ConnectionAccess(
      connection: SavedConnection(
        id: 'phone-sign-in',
        label: 'Fixture',
        host: '127.0.0.1',
        port: host.port,
        dashboardPortOverride: host.port,
        apiKey: '',
        dashboardUsername: 'fixture',
        dashboardPassword: 'fixture',
      ),
      dashboardOAuth: null,
    );
    final workspace = ProfileGatewayConnection(access);
    addTearDown(workspace.close);
    final chatGateway = workspace.create(
      WorkspaceScope(
        connectionId: access.connection.id,
        profileName: 'default',
      ),
    );
    addTearDown(chatGateway.close);
    await chatGateway.read('health');
    final administration = AdministrationRepository.forConnection(
      access,
      'fixture',
      connectionStatus: ServerConnectionStatus('Fixture'),
    );
    addTearDown(administration.close);
    await administration.read('health');
    for (final profile in [
      'default',
      'butler',
      'client-work',
      'memory-eval',
      'pace',
      'reminder-inbox',
      'sluice-processing',
    ]) {
      await administration.gateway(profile).read('health');
    }
    for (var opening = 0; opening < 3; opening++) {
      final versions = VersionsController.forConnection(access);
      try {
        await versions.refresh();
        expect(
          versions.server!.check,
          isNotNull,
          reason: 'Opening Versions must not exhaust the sign-in budget.',
        );
      } finally {
        versions.dispose();
      }
    }
    expect(logins, 1);
  });

  test(
    'dashboard sends headers through login with managed auth precedence',
    () async {
      final requests = <http.Request>[];
      final client = DashboardClient(
        host: 'gateway.example',
        useHttps: true,
        username: 'user',
        password: 'password',
        gatewayHeaders: const {
          'CF-Access-Client-Id': 'client-id',
          'CF-Access-Client-Secret': 'client-secret',
        },
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/auth/password-login')) {
            return _response(
              {},
              headers: {'set-cookie': 'hermes_session_at=session; Path=/'},
            );
          }
          if (request.url.path.endsWith('/api/auth/ws-ticket')) {
            return _response({'ticket': 'ticket'});
          }
          return _response({'profiles': <Object>[]});
        }),
      );
      addTearDown(client.close);

      await client.apiGet('profiles');
      expect(await client.mintWebSocketTicket(), 'ticket');

      expect(requests, hasLength(3));
      for (final request in requests) {
        expect(request.followRedirects, isFalse);
        expect(request.headers['cf-access-client-id'], 'client-id');
        expect(request.headers['cf-access-client-secret'], 'client-secret');
        expect(request.headers['content-type'], 'application/json');
      }
      expect(requests.first.headers, isNot(contains('cookie')));
      expect(requests[1].headers['cookie'], 'hermes_session_at=session');
      expect(requests.last.headers['cookie'], 'hermes_session_at=session');
    },
  );

  test(
    'dashboard sends headers through token fetch and proxied APIs',
    () async {
      final tokenRequests = <http.Request>[];
      final tokenClient = DashboardClient(
        host: 'gateway.example',
        useHttps: true,
        gatewayHeaders: const {'X-Access-Secret': 'secret'},
        httpClient: MockClient((request) async {
          tokenRequests.add(request);
          if (request.url.path == '/') {
            return http.Response(
              'window.__HERMES_SESSION_TOKEN__="session-token";',
              200,
            );
          }
          return _response({'profiles': <Object>[]});
        }),
      );
      addTearDown(tokenClient.close);
      await tokenClient.apiGet('profiles');

      expect(tokenRequests, hasLength(2));
      expect(tokenRequests.first.headers['x-access-secret'], 'secret');
      expect(
        tokenRequests.first.headers,
        isNot(contains('x-hermes-session-token')),
      );
      expect(
        tokenRequests.last.headers['x-hermes-session-token'],
        'session-token',
      );

      late http.Request proxiedRequest;
      final proxiedClient = DashboardClient(
        host: 'gateway.example',
        useHttps: true,
        proxied: true,
        gatewayHeaders: const {'X-Access-Secret': 'secret'},
        httpClient: MockClient((request) async {
          proxiedRequest = request;
          return _response({'profiles': <Object>[]});
        }),
      );
      addTearDown(proxiedClient.close);
      await proxiedClient.apiGet('profiles');

      expect(proxiedRequest.headers['x-access-secret'], 'secret');
      expect(proxiedRequest.headers, isNot(contains('cookie')));
      expect(proxiedRequest.headers, isNot(contains('x-hermes-session-token')));
    },
  );

  test('dashboard does not forward custom headers across a redirect', () async {
    var redirectedRequests = 0;
    final destination = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final destinationSub = destination.listen((request) async {
      redirectedRequests++;
      await request.response.close();
    });
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sourceSub = source.listen((request) async {
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${destination.port}/stolen',
        );
      await request.response.close();
    });
    addTearDown(() async {
      await source.close(force: true);
      await destination.close(force: true);
      await sourceSub.cancel();
      await destinationSub.cancel();
    });
    final client = DashboardClient(
      host: '127.0.0.1',
      port: source.port,
      proxied: true,
      gatewayHeaders: const {'X-Access-Secret': 'secret'},
    );
    addTearDown(client.close);

    await expectLater(
      client.apiGet('profiles'),
      throwsA(
        isA<DashboardHttpException>().having(
          (error) => error.statusCode,
          'statusCode',
          HttpStatus.found,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(redirectedRequests, 0);
  });

  test('websocket sends headers on its direct handshake', () async {
    final requestSeen = Completer<HttpRequest>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      requestSeen.complete(request);
      final socket = await WebSocketTransformer.upgrade(request);
      await socket.done;
    });
    addTearDown(() async {
      await server.close(force: true);
      await subscription.cancel();
    });
    final client = WsClient(
      'http://127.0.0.1:${server.port}',
      ticket: 'ticket',
      gatewayHeaders: const {'X-Access-Secret': 'secret'},
    );
    addTearDown(client.close);

    await client.connect();
    final request = await requestSeen.future;
    expect(request.uri.path, '/api/ws');
    expect(request.uri.queryParameters['ticket'], 'ticket');
    expect(request.headers.value('x-access-secret'), 'secret');
  });

  for (final customHeaders in [false, true]) {
    test(
      'websocket rejects redirects with ${customHeaders ? 'headers and a ticket' : 'a token'}',
      () async {
        var redirectedRequests = 0;
        final destination = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final destinationSub = destination.listen((request) async {
          redirectedRequests++;
          await request.response.close();
        });
        final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final sourceSub = source.listen((request) async {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(
              HttpHeaders.locationHeader,
              'http://127.0.0.1:${destination.port}/api/ws',
            );
          await request.response.close();
        });
        addTearDown(() async {
          await source.close(force: true);
          await destination.close(force: true);
          await sourceSub.cancel();
          await destinationSub.cancel();
        });
        final client = WsClient(
          'http://127.0.0.1:${source.port}',
          token: customHeaders ? null : 'synthetic-token',
          ticket: customHeaders ? 'synthetic-ticket' : null,
          gatewayHeaders: customHeaders
              ? const {'X-Access-Secret': 'secret'}
              : const {},
        );
        addTearDown(client.close);

        await expectLater(client.connect(), throwsA(anything));
        await Future<void>.delayed(Duration.zero);
        expect(redirectedRequests, 0);
      },
    );
  }
}

http.Response _response(
  Map<String, dynamic> body, {
  Map<String, String> headers = const {},
}) => http.Response(jsonEncode(body), 200, headers: headers);

/// Mirrors stock Hermes: a newly created profile has no REST-readable session
/// store until its gateway has completed the first profile-scoped session read.
class _ProfileAdmissionHost {
  final HttpServer server;
  var admission = Completer<Map<String, dynamic>>();
  var socketClosed = Completer<void>();
  late final ProfileGateway gateway;
  late final StreamSubscription<HttpRequest> subscription;
  WebSocket? socket;
  var storeReady = false;
  var sessionReads = 0;

  _ProfileAdmissionHost(this.server) {
    final connection = SavedConnection(
      id: 'profile-admission',
      label: 'Fixture',
      host: '127.0.0.1',
      port: server.port,
      dashboardPortOverride: server.port,
      apiKey: '',
    );
    gateway = ProfileGateway.forConnection(
      ConnectionAccess(connection: connection, dashboardOAuth: null),
      WorkspaceScope(connectionId: connection.id, profileName: 'fresh-profile'),
    );
    subscription = server.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final active = await WebSocketTransformer.upgrade(request);
        socket = active;
        active.listen((raw) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['method'] == 'client.capabilities') {
            active.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': {'canonical_clarify_batch': true},
              }),
            );
            return;
          }
          expect(frame['method'], 'session.list');
          admission.complete(frame);
        }, onDone: socketClosed.complete);
        active.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'session_authority': true},
            },
          }),
        );
      } else {
        if (request.uri.path == '/') {
          request.response.write('window.__HERMES_SESSION_TOKEN__="fixture";');
        } else {
          expect(request.uri.path, '/api/sessions');
          expect(request.uri.queryParameters['profile'], 'fresh-profile');
          sessionReads++;
          request.response.headers.contentType = ContentType.json;
          request.response.statusCode = storeReady ? 200 : 503;
          request.response.write(
            jsonEncode(
              storeReady
                  ? {'sessions': []}
                  : {'detail': 'Session store is not initialized'},
            ),
          );
        }
        await request.response.close();
      }
    });
  }

  static Future<_ProfileAdmissionHost> start() async => _ProfileAdmissionHost(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );

  void reply(
    Map<String, dynamic> request, {
    Map<String, dynamic>? result,
    Map<String, dynamic>? error,
  }) {
    storeReady = error == null;
    socket!.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': request['id'],
        if (error != null) 'error': error else 'result': result,
      }),
    );
  }

  Future<void> close() async {
    gateway.close();
    await socket?.close();
    await subscription.cancel();
    await server.close(force: true);
  }
}

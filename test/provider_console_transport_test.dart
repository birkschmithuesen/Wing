import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/provider_recovery.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/provider_console.dart';

const _headers = {'X-Access-Secret': 'synthetic-access-secret'};
const _credential = 'synthetic-gateway-credential';

void main() {
  for (final ticketAuth in [false, true]) {
    final credentialName = ticketAuth ? 'ticket' : 'token';

    test(
      'console directly authenticates with $credentialName and headers',
      () async {
        final requests = <HttpRequest>[];
        final commands = <Map<String, dynamic>>[];
        final sockets = <WebSocket>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final subscription = server.listen((request) async {
          requests.add(request);
          if (_respondToCredentials(request, ticketAuth)) return;
          final socket = await WebSocketTransformer.upgrade(request);
          sockets.add(socket);
          socket.add(jsonEncode({'type': 'ready', 'profile': 'personal'}));
          socket.listen((raw) {
            final frame = Map<String, dynamic>.from(
              jsonDecode(raw as String) as Map,
            );
            commands.add(frame);
            socket.add(
              jsonEncode({
                'type': 'output',
                'command': frame['line'],
                'data': 'Credential status',
              }),
            );
            socket.add(
              jsonEncode({
                'type': 'complete',
                'command': frame['line'],
                'status': 'ok',
              }),
            );
          });
        });
        final dashboard = DashboardClient(
          host: '127.0.0.1',
          port: server.port,
          proxied: ticketAuth,
          gatewayHeaders: _headers,
        );
        final console = ProviderConsole.dashboard(dashboard, _headers);
        addTearDown(() async {
          console.close();
          dashboard.close();
          for (final socket in sockets) {
            await socket.close();
          }
          await server.close(force: true);
          await subscription.cancel();
        });

        expect(
          await console.run(
            'personal',
            'auth list anthropic',
            canDispatch: () => true,
            onDispatched: () {},
          ),
          'Credential status',
        );
        expect(requests, hasLength(2));
        final credentialRequest = requests.first;
        expect(
          credentialRequest.uri.path,
          ticketAuth ? '/api/auth/ws-ticket' : '/',
        );
        expect(credentialRequest.method, ticketAuth ? 'POST' : 'GET');
        final handshake = requests.last;
        expect(handshake.uri.path, '/api/console');
        expect(handshake.uri.queryParameters, {
          'profile': 'personal',
          credentialName: _credential,
        });
        for (final request in requests) {
          expect(
            request.headers.value('x-access-secret'),
            _headers['X-Access-Secret'],
          );
        }
        expect(commands, [
          {'type': 'input', 'line': 'auth list anthropic'},
        ]);
      },
    );

    test(
      'console rejects a redirect without disclosing $credentialName or headers',
      () async {
        var destinationConnections = 0;
        final destinationHeaders = <String>[];
        final destinationSockets = <Socket>[];
        final destination = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final destinationSub = destination.listen((socket) {
          destinationConnections++;
          destinationSockets.add(socket);
          socket.listen((bytes) {
            destinationHeaders.add(utf8.decode(bytes));
            socket.destroy();
          });
        });
        final sourceRequests = <HttpRequest>[];
        final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final sourceSub = source.listen((request) async {
          sourceRequests.add(request);
          if (_respondToCredentials(request, ticketAuth)) return;
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(
              HttpHeaders.locationHeader,
              'http://127.0.0.1:${destination.port}/api/console?$credentialName=$_credential',
            );
          await request.response.close();
        });
        final dashboard = DashboardClient(
          host: '127.0.0.1',
          port: source.port,
          proxied: ticketAuth,
          gatewayHeaders: _headers,
        );
        final console = ProviderConsole.dashboard(dashboard, _headers);
        addTearDown(() async {
          console.close();
          dashboard.close();
          await source.close(force: true);
          await destination.close();
          for (final socket in destinationSockets) {
            socket.destroy();
          }
          await sourceSub.cancel();
          await destinationSub.cancel();
        });

        await expectLater(
          console.run(
            'personal',
            'auth list anthropic',
            canDispatch: () => true,
            onDispatched: () {},
          ),
          throwsA(isA<ProviderRecoveryFailure>()),
        );
        expect(sourceRequests, hasLength(2));
        final handshake = sourceRequests.last;
        expect(handshake.uri.path, '/api/console');
        expect(handshake.uri.queryParameters[credentialName], _credential);
        expect(
          handshake.headers.value('x-access-secret'),
          _headers['X-Access-Secret'],
        );
        expect(destinationConnections, 0);
        expect(destinationHeaders, isEmpty);
      },
    );
  }
}

bool _respondToCredentials(HttpRequest request, bool ticketAuth) {
  if (request.uri.path == '/') {
    request.response.write('window.__HERMES_SESSION_TOKEN__="$_credential";');
  } else if (request.uri.path == '/api/auth/ws-ticket') {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'ticket': _credential}));
  } else {
    return false;
  }
  expect(request.uri.path, ticketAuth ? '/api/auth/ws-ticket' : '/');
  unawaited(request.response.close());
  return true;
}

import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'support/gateway_application_requests.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/connection_setup_probe.dart';

void main() {
  for (final (cancelOpening, authority) in [
    (false, true),
    (true, true),
    (false, false),
  ]) {
    test(
      cancelOpening
          ? 'cancel closes a socket still waiting for gateway.ready'
          : !authority
          ? 'standalone dashboard cannot verify as a usable chat connection'
          : 'real HTTP and WebSocket probe accepts empty history without sending a message',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final opened = Completer<void>();
        final closed = Completer<void>();
        final paths = <String>[];
        final socketRequests = <Map<String, dynamic>>[];
        WebSocket? socket;
        final subscription = server.listen((request) async {
          paths.add(request.uri.path);
          if (request.uri.path == '/agent/api/ws') {
            expect(request.uri.queryParameters['ticket'], 'test-ticket');
            final active = await WebSocketTransformer.upgrade(request);
            socket = active;
            gatewayApplicationRequests(active).listen(
              (raw) {
                final frame = jsonDecode(raw as String) as Map<String, dynamic>;
                socketRequests.add({
                  'method': frame['method'],
                  'params': frame['params'],
                });
                active.add(
                  jsonEncode({
                    'jsonrpc': '2.0',
                    'id': frame['id'],
                    'result': {'sessions': []},
                  }),
                );
              },
              onDone: () {
                if (!closed.isCompleted) closed.complete();
              },
            );
            opened.complete();
            if (!cancelOpening) {
              active.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'method': 'event',
                  'params': {
                    'type': 'gateway.ready',
                    'payload': {if (authority) 'session_authority': true},
                  },
                }),
              );
            }
            return;
          }
          Object response;
          if (request.uri.path == '/agent/auth/password-login') {
            final body =
                jsonDecode(await utf8.decoder.bind(request).join()) as Map;
            expect(body['password'], ' exact password ');
            request.response.headers.add(
              'set-cookie',
              'hermes_session_at=test-session; Path=/',
            );
            response = <String, Object>{};
          } else {
            expect(
              request.headers.value('cookie'),
              'hermes_session_at=test-session',
            );
            response = switch (request.uri.path) {
              '/agent/api/profiles' => {
                'profiles': [
                  {'name': 'work'},
                ],
              },
              '/agent/api/profiles/active' => {
                'current': 'work',
                'active': 'work',
              },
              '/agent/api/auth/ws-ticket' => {'ticket': 'test-ticket'},
              '/agent/api/sessions' => {
                'sessions': <Object>[],
                'offset': int.parse(request.uri.queryParameters['offset']!),
                'limit': int.parse(request.uri.queryParameters['limit']!),
                'total': 0,
              },
              _ => throw StateError('Unexpected request ${request.uri.path}'),
            };
            if (request.uri.path == '/agent/api/sessions') {
              expect(request.uri.queryParameters['profile'], 'work');
            }
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(response));
          await request.response.close();
        });
        final probe = ConnectionSetupProbe();
        try {
          final checking = probe.check(
            ConnectionAccess(
              connection: SavedConnection(
                id: 'transport-test',
                label: 'test',
                host: '127.0.0.1',
                port: server.port,
                apiKey: '',
                dashboardPortOverride: server.port,
                dashboardPrefix: '/agent',
                dashboardUsername: 'alex',
                dashboardPassword: ' exact password ',
              ),
              dashboardOAuth: null,
            ),
          );
          await opened.future.timeout(const Duration(seconds: 5));
          if (cancelOpening) probe.cancel();
          await checking.timeout(const Duration(seconds: 5));
          await closed.future.timeout(const Duration(seconds: 5));
          expect(probe.verified, !cancelOpening && authority);
          if (!cancelOpening && !authority) {
            expect(probe.failedStage, ConnectionCheck.chat);
            expect(probe.error, contains('gateway'));
            expect(probe.error, contains('address'));
          }
          expect(
            socketRequests,
            cancelOpening || !authority
                ? isEmpty
                : [
                    {
                      'method': 'session.list',
                      'params': {'profile': 'work', 'limit': 1},
                    },
                  ],
          );
          expect(
            paths.contains('/agent/api/sessions'),
            !cancelOpening && authority,
          );
        } finally {
          probe.dispose();
          await socket?.close();
          await subscription.cancel();
          await server.close(force: true);
        }
      },
    );
  }
}

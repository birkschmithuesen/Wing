import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'support/gateway_application_requests.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/server_connection_status.dart';

void main() {
  test(
    'an interrupted administration socket does not mark working chat unavailable',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      var authority = false;
      final subscription = server.listen((request) async {
        if (request.uri.path == '/api/ws') {
          final socket = await WebSocketTransformer.upgrade(request);
          sockets.add(socket);
          gatewayApplicationRequests(socket).listen((message) {
            final rpc = jsonDecode(message as String) as Map;
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': rpc['id'],
                'result': rpc['method'] == 'session.list'
                    ? {'sessions': []}
                    : {'ok': true},
              }),
            );
          });
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'gateway.ready',
                'payload': {'session_authority': authority},
              },
            }),
          );
          return;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'ticket': 'test-ticket'}));
        await request.response.close();
      });
      final connection = SavedConnection(
        id: 'test',
        label: 'Claw',
        host: '127.0.0.1',
        port: server.port,
        dashboardPortOverride: server.port,
        dashboardProxied: true,
        apiKey: '',
      );
      final status = ServerConnectionStatus('Claw');
      final chat = ProfileGateway.forConnection(
        ConnectionAccess(connection: connection, dashboardOAuth: null),
        WorkspaceScope(
          connectionId: 'test',
          connectionIdentity: 'test',
          profileName: 'work',
        ),
      )..connectionStatus = status;
      final administration = AdministrationRepository.forConnection(
        ConnectionAccess(connection: connection, dashboardOAuth: null),
        'test',
        connectionStatus: status,
      );
      addTearDown(() async {
        administration.close();
        chat.close();
        status.dispose();
        for (final socket in sockets) {
          await socket.close();
        }
        await subscription.cancel();
        await server.close(force: true);
      });

      await expectLater(chat.connect(), throwsA(isA<JsonRpcError>()));
      status.accessAvailable();
      expect(status.phase, ServerConnectionPhase.disconnected);
      expect(status.problem, contains('Webapp address'));
      authority = true;
      await chat.connect();
      expect(status.chatEndpointUnsupported, isFalse);
      final auxiliary = administration.gateway('work');
      await auxiliary.connect();
      expect(status.phase, ServerConnectionPhase.connected);
      final interrupted = Completer<void>();
      auxiliary.onConnectionChanged = (connected) {
        if (!connected && !interrupted.isCompleted) interrupted.complete();
      };
      await sockets.last.close();
      await interrupted.future.timeout(const Duration(seconds: 5));
      expect(await chat.call('session.list'), {'sessions': []});
      expect(status.live, ConnectionAvailability.available);
      expect(status.phase, ServerConnectionPhase.connected);

      // A healthy administration socket must not hide a real chat interruption.
      await auxiliary.connect();
      final chatInterrupted = Completer<void>();
      chat.onConnectionChanged = (connected) {
        if (!connected && !chatInterrupted.isCompleted) {
          chatInterrupted.complete();
        }
      };
      await sockets[1].close();
      await chatInterrupted.future.timeout(const Duration(seconds: 5));
      expect(await auxiliary.call('tools.list'), {'ok': true});
      expect(status.live, ConnectionAvailability.unavailable);
      expect(status.phase, ServerConnectionPhase.limited);
      await chat.connect();
      expect(status.phase, ServerConnectionPhase.connected);

      // Closing administration must not erase the workspace's observation.
      administration.close();
      expect(status.phase, ServerConnectionPhase.connected);
    },
  );
}

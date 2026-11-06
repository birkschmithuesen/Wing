import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/ws_client.dart';

void main() {
  test(
    'unsupported server requests receive a terminal JSON-RPC error',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final reply = Completer<Map<String, dynamic>>();
      WebSocket? peer;
      final subscription = server.transform(WebSocketTransformer()).listen((
        socket,
      ) {
        peer = socket;
        socket.listen((raw) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['method'] == 'client.capabilities') {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': {'canonical_clarify_batch': true},
              }),
            );
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': 'srq-desktop-only',
                'method': 'fixture.desktop_only',
                'params': {'session_id': 'runtime'},
              }),
            );
          } else if (frame['id'] == 'srq-desktop-only') {
            reply.complete(frame);
          }
        });
      });
      final client = WsClient('http://127.0.0.1:${server.port}');
      addTearDown(() async {
        client.close();
        await peer?.close();
        await subscription.cancel();
        await server.close(force: true);
      });
      await client.connect();
      final frame = await reply.future.timeout(const Duration(seconds: 2));
      expect(frame['id'], 'srq-desktop-only');
      expect(frame['error']['code'], -32601);
      expect(frame, isNot(contains('result')));
    },
  );

  test(
    'every socket advertises request support before a turn can need approval',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final announcements = <Map<String, dynamic>>[];
      final subscription = server.transform(WebSocketTransformer()).listen((
        socket,
      ) {
        sockets.add(socket);
        var answersRequests = false;
        socket.listen((raw) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['method'] == 'client.capabilities') {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': {'canonical_clarify_batch': true},
              }),
            );
            announcements.add(frame);
            answersRequests = frame['params']['server_requests'] == true;
            return;
          }
          // Stock server_requests.send_async withdraws approvals without sending
          // them when this specific transport has not advertised support.
          if (answersRequests) {
            for (final id in ['one', 'two']) {
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': 'srq-$id',
                  'method': 'approval',
                  'params': {
                    'session_id': 'runtime',
                    'request_id': 'queue-$id',
                    'command': 'echo $id',
                    'choices': ['once', 'deny'],
                  },
                }),
              );
            }
          }
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {'requests_delivered': answersRequests},
            }),
          );
        });
      });
      final client = WsClient('http://127.0.0.1:${server.port}');
      addTearDown(() async {
        client.close();
        for (final socket in sockets) {
          await socket.close();
        }
        await subscription.cancel();
        await server.close(force: true);
      });
      for (var connection = 0; connection < 2; connection++) {
        final approvals = <StreamEvent>[];
        client.onStreamEvent = approvals.add;
        // An observer can submit immediately: negotiation must precede even it.
        final response = Completer<Map<String, dynamic>>();
        client.onConnectionChanged = (connected) {
          if (connected) {
            response.complete(
              client.send('prompt.submit', {
                'session_id': 'runtime',
                'text': 'fixture',
              }),
            );
          }
        };
        await client.connect();
        final result = await response.future;
        await client.capabilitiesReady;
        expect(client.canonicalClarifyBatch, isTrue);
        expect(
          result['result']['requests_delivered'],
          isTrue,
          reason: 'Hermes must not withdraw the approvals as unanswerable',
        );
        expect(approvals.map((e) => e.data['request_id']), [
          'queue-one',
          'queue-two',
        ]);
        expect(announcements, hasLength(connection + 1));
        expect(announcements.last['params'], {'server_requests': true});
        client.close();
      }
    },
  );
}

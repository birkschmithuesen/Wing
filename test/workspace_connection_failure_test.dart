import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/services/workspace_connection_failure.dart';

void main() {
  test('superseded snapshots retry only resume observations', () {
    for (final method in [
      'session.resume',
      'session.create',
      'prompt.submit',
    ]) {
      expect(
        isTemporaryWorkspaceFailure(
          JsonRpcError(method, 'Stale snapshot', reason: 'snapshot_superseded'),
        ),
        method == 'session.resume',
      );
    }
    expect(
      isTemporaryWorkspaceFailure(StateError('Unrelated failure')),
      isFalse,
    );
  });

  test(
    'resume retries distinguish server recovery from missing chats and writes',
    () {
      for (final method in ['session.resume', 'prompt.submit']) {
        for (final entry in [
          (5000, 'Failed to resume session'),
          (-32603, 'internal error'),
          (4009, 'session disconnect interrupt settling'),
          (4007, 'session no longer live; retry resume'),
        ]) {
          expect(
            isTemporaryWorkspaceFailure(
              JsonRpcError(method, entry.$2, code: entry.$1),
            ),
            method == 'session.resume',
          );
        }
      }
      for (final entry in [
        (4007, 'session not found'),
        (4009, 'session busy'),
        (4000, 'invalid params'),
        (4130, 'session too large'),
      ]) {
        expect(
          isTemporaryWorkspaceFailure(
            JsonRpcError('session.resume', entry.$2, code: entry.$1),
          ),
          isFalse,
        );
      }
    },
  );

  test('a real unanswered RPC is classified for connection recovery', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((_) {});
    });
    final client = WsClient(
      'http://127.0.0.1:${server.port}',
      token: 'local-test',
    );
    addTearDown(() async {
      client.close();
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    });
    await client.connect();
    await expectLater(
      client.send(
        'session.resume',
        {},
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(
        isA<JsonRpcError>()
            .having((error) => error.reason, 'reason', 'request_timeout')
            .having(isTemporaryWorkspaceFailure, 'recoverable', isTrue),
      ),
    );
  });
}

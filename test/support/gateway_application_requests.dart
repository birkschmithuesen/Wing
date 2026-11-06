import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Consume connection-level negotiation before scenario-specific RPC handlers.
/// The capability transport tests separately enforce delivery and ordering on
/// every connection; application-RPC counts should exclude this exchange.
Stream<dynamic> gatewayApplicationRequests(WebSocket socket) =>
    socket.where((raw) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      if (frame['method'] != 'client.capabilities') return true;
      expect(frame['params'], {'server_requests': true});
      expect(frame['id'], isA<int>());
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': frame['id'],
          'result': {'canonical_clarify_batch': true},
        }),
      );
      return false;
    });

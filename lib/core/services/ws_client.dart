// WebSocket client for the Hermes gateway JSON-RPC API (/api/ws).
// Supports both request-response calls AND server-pushed streaming events.
//
// Wire protocol: newline-delimited JSON-RPC 2.0, same as the TUI gateway.
// Requests settle through correlated responses; pushed events arrive separately.
import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/io.dart';

import '../models/connection.dart';
import '../models/gateway_sensitive_prompt.dart';
import 'authenticated_web_socket.dart';
import 'connection_diagnostics.dart';

Object? _deepFreezeJson(Object? value) {
  if (value is Map) {
    final copy = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is! String) continue;
      copy[entry.key as String] = _deepFreezeJson(entry.value);
    }
    return Map<String, dynamic>.unmodifiable(copy);
  }
  if (value is List) {
    return List<dynamic>.unmodifiable(value.map(_deepFreezeJson));
  }
  return value;
}

Map<String, dynamic> _deepFreezeJsonMap(Map<String, dynamic> value) {
  return _deepFreezeJson(value)! as Map<String, dynamic>;
}

Object? _canonicalJsonValue(Object? value) {
  if (value is Map) {
    final keys = value.keys.whereType<String>().toList()..sort();
    return <String, dynamic>{
      for (final key in keys) key: _canonicalJsonValue(value[key]),
    };
  }
  if (value is List) return value.map(_canonicalJsonValue).toList();
  return value;
}

String _canonicalJson(Object? value) => jsonEncode(_canonicalJsonValue(value));

/// A JSON-RPC error response from the gateway.
class JsonRpcError implements Exception {
  final String method;
  final String message;
  final int? code;
  final String? reason;
  final Map<String, dynamic> data;

  JsonRpcError(
    this.method,
    this.message, {
    this.code,
    this.reason,
    Map<String, dynamic>? data,
  }) : data = _deepFreezeJsonMap(data ?? const <String, dynamic>{});

  factory JsonRpcError.fromGateway(
    String method,
    Map<dynamic, dynamic> error, {
    required String fallbackMessage,
  }) {
    final rawData = error['data'];
    final data = rawData is Map
        ? <String, dynamic>{
            for (final entry in rawData.entries)
              if (entry.key is String) entry.key as String: entry.value,
          }
        : const <String, dynamic>{};
    return JsonRpcError(
      method,
      error['message'] is String ? error['message'] as String : fallbackMessage,
      code: error['code'] is int ? error['code'] as int : null,
      reason: data['reason'] is String ? data['reason'] as String : null,
      data: data,
    );
  }

  @override
  String toString() => 'JsonRpcError($method): $message';
}

/// Event types streamed from the gateway during a prompt submission.
class StreamEvent {
  final String type; // 'tool_call', 'tool_result', 'assistant', 'session', etc.
  final Map<String, dynamic> data;
  final String? sessionId;
  final Map<String, dynamic> envelope;

  StreamEvent({
    required this.type,
    required Map<String, dynamic> data,
    this.sessionId,
    Map<String, dynamic>? envelope,
  }) : data = _deepFreezeJsonMap(data),
       envelope = _deepFreezeJsonMap(envelope ?? const <String, dynamic>{});
}

typedef StreamCallback = void Function(StreamEvent event);
typedef ConnectionCallback = void Function(bool connected);

/// WebSocket client for the Hermes JSON-RPC gateway.
class WsClient {
  final String baseUrl;
  final Map<String, Object?> _diagnosticContext;
  final String? _token;
  final String? _ticket;
  final Map<String, String> _gatewayHeaders;
  IOWebSocketChannel? _channel;
  bool _connected = false;
  bool canonicalClarifyBatch = false;
  Future<void>? capabilitiesReady;
  int _nextId = 1;
  int _connectionGeneration = 0;

  /// Pending requests: id -> (completer, timer).
  final Map<int, _Pending> _pending = {};
  // Only correlation and completion live here; never retain a response value.
  final Map<String, _Pending> _serverResponses = {};

  Completer<Map<String, dynamic>>? _gatewayReadyCompleter;
  Map<String, dynamic>? _gatewayReadyFrame;
  String? _gatewayReadyCanonical;
  JsonRpcError? _gatewayReadyFailure;

  /// Global listener for all parsed gateway events.
  StreamCallback? onStreamEvent;
  ConnectionCallback? onConnectionChanged;

  factory WsClient(
    String baseUrl, {
    String? token,
    String? ticket,
    Map<String, String> gatewayHeaders = const {},
    Map<String, Object?> diagnosticContext = const {},
  }) {
    return WsClient._(
      baseUrl,
      token,
      ticket,
      validateGatewayHeaders(gatewayHeaders),
      Map<String, Object?>.unmodifiable(diagnosticContext),
    );
  }

  WsClient._(
    this.baseUrl,
    this._token,
    this._ticket,
    this._gatewayHeaders,
    this._diagnosticContext,
  );

  /// Connect to the WebSocket gateway.
  Future<void> connect() async {
    if (_connected) return;
    if (_channel != null) {
      throw StateError('A WebSocket connection is already in progress');
    }
    final generation = ++_connectionGeneration;
    logConnectionDiagnostic(
      'ws.connect_started',
      details: {..._diagnosticContext, 'generation': generation},
    );
    _gatewayReadyFrame = null;
    _gatewayReadyCanonical = null;
    _gatewayReadyFailure = null;
    final readyCompleter = Completer<Map<String, dynamic>>();
    _gatewayReadyCompleter = readyCompleter;
    // A transport can close before a caller starts waiting for gateway.ready.
    // Observe that error future immediately; the waiter still receives it.
    readyCompleter.future.ignore();
    final wsUrl = buildWebSocketUrl(baseUrl, token: _token, ticket: _ticket);
    final channel = connectAuthenticatedWebSocket(
      Uri.parse(wsUrl),
      headers: _gatewayHeaders,
    );
    _channel = channel;
    channel.stream.listen(
      (message) => _handleMessage(message, generation),
      onError: (Object error, StackTrace stack) {
        if (generation != _connectionGeneration) return;
        logConnectionDiagnostic(
          'ws.stream_failed',
          details: {..._diagnosticContext, 'generation': generation},
          error: error,
          stackTrace: stack,
        );
        _handleClosedConnection(generation);
      },
      onDone: () {
        if (generation != _connectionGeneration) return;
        logConnectionDiagnostic(
          'ws.remote_closed',
          details: {
            ..._diagnosticContext,
            'generation': generation,
            'close_code': channel.closeCode,
            'pending_requests': _pending.length,
            'gateway_ready': _gatewayReadyFrame != null,
          },
        );
        _handleClosedConnection(generation);
      },
    );
    try {
      await channel.ready.timeout(const Duration(seconds: 15));
      if (generation != _connectionGeneration || _channel != channel) {
        throw JsonRpcError(
          'connect',
          'Connection closed during WebSocket setup',
          reason: 'connection_closed',
        );
      }
      _connected = true;
      canonicalClarifyBatch = false;
      capabilitiesReady = send('client.capabilities', {'server_requests': true})
          .then((capabilities) {
            final error = capabilities['error'];
            if (error is Map) {
              throw JsonRpcError.fromGateway(
                'client.capabilities',
                error,
                fallbackMessage: 'Capability negotiation failed',
              );
            }
            final result = capabilities['result'];
            if (result is! Map) {
              throw const FormatException('Missing client capabilities result');
            }
            if (generation != _connectionGeneration) return;
            canonicalClarifyBatch = result['canonical_clarify_batch'] == true;
          });
      capabilitiesReady!.ignore();
      logConnectionDiagnostic(
        'ws.connected',
        details: {..._diagnosticContext, 'generation': generation},
      );
      try {
        onConnectionChanged?.call(true);
      } catch (_) {
        // Transport observers cannot turn a live socket into setup failure.
      }
    } catch (error, stack) {
      logConnectionDiagnostic(
        'ws.connect_failed',
        details: {..._diagnosticContext, 'generation': generation},
        error: error,
        stackTrace: stack,
      );
      _handleClosedConnection(generation);
      try {
        await channel.sink.close();
      } catch (_) {
        // Preserve the original setup failure after closing this exact socket.
      }
      rethrow;
    }
  }

  void _handleClosedConnection(int generation) {
    if (generation != _connectionGeneration) return;
    // Invalidate this socket before any completion or observer can enqueue
    // more work. Buffered callbacks from it now fail the generation guard.
    _connectionGeneration = generation + 1;
    final wasConnected = _connected || _channel != null;
    _connected = false;
    _channel = null;
    // Reject all pending request-response calls.
    for (final entry in [..._pending.values, ..._serverResponses.values]) {
      entry.timer?.cancel();
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(
          JsonRpcError(
            entry.method,
            'Desktop gateway connection closed',
            reason: 'connection_closed',
          ),
        );
      }
    }
    _pending.clear();
    _serverResponses.clear();
    final closeError =
        _gatewayReadyFailure ??
        JsonRpcError(
          'gateway.ready',
          'Connection closed before gateway.ready',
          reason: 'connection_closed',
        );
    _gatewayReadyFailure = closeError;
    _gatewayReadyFrame = null;
    _gatewayReadyCanonical = null;
    final ready = _gatewayReadyCompleter;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(closeError);
    }
    _gatewayReadyCompleter = null;
    if (wasConnected) {
      try {
        onConnectionChanged?.call(false);
      } catch (_) {
        // Observer failures cannot keep a rejected socket logically active.
      }
    }
  }

  /// Produces the gateway `/api/ws` URL. Secured Desktop gateways use a
  /// single-use ticket; insecure legacy gateways still use a session token.
  static String buildWebSocketUrl(
    String baseUrl, {
    String? token,
    String? ticket,
  }) {
    final socketBase = baseUrl
        .replaceFirst('http://', 'ws://')
        .replaceFirst('https://', 'wss://');
    final uri = Uri.parse('$socketBase/api/ws');
    final credential = ticket?.trim().isNotEmpty == true
        ? {'ticket': ticket!.trim()}
        : token?.trim().isNotEmpty == true
        ? {'token': token!.trim()}
        : const <String, String>{};
    return uri.replace(queryParameters: credential).toString();
  }

  /// Handle inbound messages.
  void _handleMessage(dynamic msg, int generation) {
    if (generation != _connectionGeneration) return;
    try {
      Map<String, dynamic> data;
      if (msg is String) {
        data = jsonDecode(msg) as Map<String, dynamic>;
      } else if (msg is Map<String, dynamic>) {
        data = msg;
      } else {
        return;
      }

      final id = data['id'];
      final method = data['method'] as String?;
      final params = data['params'];

      // Hermes asks the client directly using a server-owned string ID. These
      // frames are requests, not responses to our integer-ID RPC calls.
      if ((method == 'approval' ||
              method == 'clarify' ||
              GatewaySensitivePromptRequest.kindForMethod(method) != null) &&
          id is String &&
          id.isNotEmpty &&
          params is Map<String, dynamic>) {
        final sessionId = params['session_id'];
        if (sessionId is! String || sessionId.isEmpty) return;
        _dispatchEvent(
          StreamEvent(
            type: method!,
            sessionId: sessionId,
            data: {
              ...params,
              // Approval has both a queue-entry ID and a server-request ID.
              if (method == 'approval')
                'server_request_id': id
              else
                'request_id': id,
            },
          ),
        );
        return;
      }

      // Advertising request support also obliges us to reject methods without
      // an Android handler, so Hermes can settle them instead of waiting.
      if (id is String && method != null) {
        _channel?.sink.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'error': {
              'code': -32601,
              'message': 'Unsupported server request: $method',
            },
          }),
        );
        return;
      }

      // Server-pushed events have the JSON-RPC method `event` and carry their
      // actual type/session/payload inside params.
      if (method == 'event' && id == null && params is Map<String, dynamic>) {
        if (params['type'] == 'gateway.ready') {
          _handleGatewayReady(data, generation);
          return;
        }
        final event = parseGatewayEvent(params);
        if (event != null) {
          if (event.type == 'request.cancel') {
            final pending = _serverResponses.remove(event.data['id']);
            if (pending != null) {
              pending.timer?.cancel();
              if (event.data['reason'] == 'resolved') {
                pending.completer.complete({});
              } else {
                pending.completer.completeError(
                  JsonRpcError(
                    'server.response',
                    'The secure request ended before the response was confirmed',
                    reason: 'request_ended',
                  ),
                );
              }
            }
          }
          _dispatchEvent(event);
        }
        return;
      }

      // Correlated response to a pending request.
      if (id != null) {
        final pending = _pending[id];
        if (pending != null) {
          _pending.remove(id);
          pending.timer?.cancel();
          pending.completer.complete(data);
          return;
        }
      }
    } catch (_) {
      // Ignore parse errors
    }
  }

  void _handleGatewayReady(Map<String, dynamic> data, int generation) {
    if (generation != _connectionGeneration) return;
    final frame = _deepFreezeJsonMap(data);
    final canonical = _canonicalJson(frame);
    final pinned = _gatewayReadyCanonical;
    if (pinned == null) {
      logConnectionDiagnostic(
        'ws.gateway_ready',
        details: {
          ..._diagnosticContext,
          'generation': generation,
          'session_authority':
              frame['params']?['payload']?['session_authority'] == true,
        },
      );
      _gatewayReadyCanonical = canonical;
      _gatewayReadyFrame = frame;
      final ready = _gatewayReadyCompleter;
      if (ready != null && !ready.isCompleted) ready.complete(frame);
      return;
    }
    if (pinned == canonical) return;

    logConnectionDiagnostic(
      'ws.gateway_ready_drift',
      details: {..._diagnosticContext, 'generation': generation},
    );
    _gatewayReadyFailure = JsonRpcError(
      'gateway.ready',
      'Gateway ready frame changed on the active connection',
      reason: 'gateway_ready_drift',
    );
    final channel = _channel;
    _handleClosedConnection(generation);
    channel?.sink.close();
  }

  /// Dispatch a server-pushed event to registered listeners.
  static StreamEvent? parseGatewayEvent(Map<String, dynamic> params) {
    final rawType = params['type'];
    if (rawType is! String || rawType.isEmpty) return null;
    final payload = params['payload'];
    final data = payload is Map<String, dynamic>
        ? Map<String, dynamic>.from(payload)
        : <String, dynamic>{};
    final sessionCandidates = <Object?>[params['session_id'], params['sid']];
    String? sessionId;
    for (final candidate in sessionCandidates) {
      if (candidate is String &&
          candidate.isNotEmpty &&
          candidate.length <= 256 &&
          candidate.trim() == candidate &&
          !candidate.codeUnits.any(
            (unit) => unit < 32 || unit >= 127 && unit <= 159,
          )) {
        sessionId = candidate;
        break;
      }
    }
    if (sessionId != null && sessionId.isNotEmpty) {
      data['session_id'] = sessionId;
    }
    return StreamEvent(
      type: rawType,
      data: data,
      sessionId: sessionId,
      envelope: params,
    );
  }

  /// Wait for the capability-bearing greeting emitted by this exact socket.
  Future<Map<String, dynamic>> waitForGatewayReady({
    Duration timeout = const Duration(seconds: 15),
  }) {
    final failure = _gatewayReadyFailure;
    if (failure != null) return Future<Map<String, dynamic>>.error(failure);
    final frame = _gatewayReadyFrame;
    if (frame != null) return Future<Map<String, dynamic>>.value(frame);
    final ready = _gatewayReadyCompleter;
    if (ready == null) {
      throw StateError('connect must run before waiting for gateway.ready');
    }
    return ready.future.timeout(timeout);
  }

  void _dispatchEvent(StreamEvent event) {
    try {
      onStreamEvent?.call(event);
    } catch (_) {
      // Observer failures do not alter transport state.
    }
  }

  /// Send a JSON-RPC method call and wait for response.
  Future<Map<String, dynamic>> send(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!_connected || _channel == null) {
      throw JsonRpcError(
        method,
        'Connection unavailable',
        reason: 'connection_closed',
      );
    }

    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    final timer = Timer(timeout, () {
      logConnectionDiagnostic(
        'ws.rpc_timeout',
        details: {
          ..._diagnosticContext,
          'generation': _connectionGeneration,
          'rpc_method': method,
          'request_id': id,
          'timeout_ms': timeout.inMilliseconds,
        },
      );
      _pending.remove(id);
      if (!completer.isCompleted) {
        completer.completeError(
          JsonRpcError(method, 'Timeout', reason: 'request_timeout'),
        );
      }
    });

    _pending[id] = _Pending(method, completer, timer);
    _channel!.sink.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
        'id': id,
      }),
    );
    return completer.future;
  }

  /// Answer the original server request on this subscribed socket. A response
  /// frame has no RPC acknowledgement; the canonical owner confirms settlement
  /// with request.cancel reason=resolved. Never replay a secret after reconnect.
  Future<void> respondToRequest(
    String requestId,
    Map<String, dynamic> result, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final channel = _channel;
    if (!_connected || channel == null) {
      throw JsonRpcError(
        'server.response',
        'Connection unavailable',
        reason: 'connection_closed',
      );
    }
    if (_serverResponses.containsKey(requestId)) {
      throw StateError('A response is already being submitted.');
    }
    final completer = Completer<Map<String, dynamic>>();
    final timer = Timer(timeout, () {
      _serverResponses.remove(requestId);
      completer.completeError(
        JsonRpcError(
          'server.response',
          'Hermes did not confirm the response',
          reason: 'request_timeout',
        ),
      );
    });
    _serverResponses[requestId] = _Pending('server.response', completer, timer);
    try {
      channel.sink.add(
        jsonEncode({'jsonrpc': '2.0', 'id': requestId, 'result': result}),
      );
      await completer.future;
    } finally {
      timer.cancel();
      _serverResponses.remove(requestId);
    }
  }

  static const validReasoningEfforts = <String>{
    'none',
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
    'ultra',
  };

  static String normalizeReasoningEffort(Object? value) {
    final normalized = value?.toString().trim().toLowerCase() ?? '';
    return validReasoningEfforts.contains(normalized) ? normalized : 'medium';
  }

  /// Builds the gateway `/model` value used for one live session.
  ///
  /// A bare `custom` provider represents the endpoint already stored in the
  /// profile's `model.base_url`; it is not a resolvable named provider before
  /// the deferred agent build finishes. Omitting the redundant provider flag
  /// lets Hermes resolve that endpoint from the active profile immediately.
  static String buildSessionModelValue({
    required String provider,
    required String model,
  }) {
    final normalizedProvider = provider.trim();
    final modelValue = model.trim();
    if (normalizedProvider.isEmpty || normalizedProvider == 'custom') {
      return '$modelValue --session';
    }
    return '$modelValue --provider $normalizedProvider --session';
  }

  /// Close the connection.
  void close() {
    if (!_connected && _channel == null) return;
    final generation = _connectionGeneration;
    final channel = _channel;
    logConnectionDiagnostic(
      'ws.local_closed',
      details: {
        ..._diagnosticContext,
        'generation': generation,
        'pending_requests': _pending.length,
      },
    );
    _handleClosedConnection(generation);
    channel?.sink.close();
  }
}

class _Pending {
  final String method;
  final Completer<Map<String, dynamic>> completer;
  final Timer? timer;
  _Pending(this.method, this.completer, this.timer);
}

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'connection_manager.dart';
import 'gateway_refusal.dart';
import 'ws_client.dart';

const chatEndpointFailureMessage =
    'This address doesn’t support Wing chats. Use '
    'the Hermes gateway’s Webapp address.';

bool isUnsupportedChatEndpoint(Object error) =>
    error is JsonRpcError && error.reason == 'session_authority_unavailable';

/// Only failures that can recover without changing settings are retried.
bool isTemporaryWorkspaceFailure(Object error) {
  if (error is DashboardRequestNotSentException) {
    return isTemporaryWorkspaceFailure(error.cause);
  }
  if (error is HandshakeException || error is TlsException) return false;
  if (error is WebSocketChannelException && error.inner != null) {
    return isTemporaryWorkspaceFailure(error.inner!);
  }
  return error is TimeoutException ||
      error is SocketException ||
      error is http.ClientException ||
      error is WebSocketException ||
      isRetryableGatewayRefusal(error) ||
      error is JsonRpcError &&
          ({'connection_closed', 'request_timeout'}.contains(error.reason) ||
              // Stock session.resume can race disconnect cleanup or fail while
              // rebuilding its runtime. The WS dispatcher reports an uncaught
              // handler failure as -32603 rather than the resume handler's 5000.
              // A client-rejected stale resume snapshot is also a read race.
              // These observations may be retried;
              // identical codes on prompt.submit must not replay a message.
              error.method == 'session.resume' &&
                  (error.reason == 'snapshot_superseded' ||
                      {5000, -32603}.contains(error.code) ||
                      error.code == 4009 &&
                          error.message ==
                              'session disconnect interrupt settling' ||
                      error.code == 4007 &&
                          error.message ==
                              'session no longer live; retry resume')) ||
      error is DashboardHttpException &&
          (error.statusCode == 408 ||
              error.statusCode == 429 ||
              error.statusCode >= 500 && error.statusCode <= 599);
}

/// Bounded recovery for observations only. Never use this to replay a mutation.
Future<T> retryTransientRead<T>(
  Future<T> Function() read, {
  required bool Function() isActive,
}) async {
  for (var attempt = 0; ; attempt++) {
    try {
      return await read();
    } catch (error) {
      if (attempt == 2 || !isTemporaryWorkspaceFailure(error) || !isActive()) {
        rethrow;
      }
      await Future<void>.delayed(Duration(seconds: 1 << attempt));
      if (!isActive()) rethrow;
    }
  }
}

String workspaceFailureMessage(Object error) {
  if (isUnsupportedChatEndpoint(error)) return chatEndpointFailureMessage;
  if (error is DashboardHttpException) {
    if (error.statusCode == 401) {
      return 'Sign-in was rejected. Check this connection’s sign-in settings.';
    }
    if (error.statusCode == 403) {
      return 'Access was denied. Check this connection’s access settings.';
    }
  }
  if (error is HandshakeException || error is TlsException) {
    return 'The server’s certificate could not be verified.';
  }
  return 'Couldn’t open this workspace. Check the connection settings and try again.';
}

bool isConversationAttachmentRefused(Object error) =>
    error is JsonRpcError &&
    error.method == 'session.resume' &&
    error.reason == 'runtime_coordination_required';

String conversationOpeningFailureMessage(Object error) {
  if (isUnsupportedChatEndpoint(error)) return chatEndpointFailureMessage;
  if (isConversationAttachmentRefused(error)) {
    return 'Sending is unavailable. Hermes could not confirm chat ownership. If this chat is open in another app, close it there, then retry.';
  }
  if (error is TlsException ||
      error is DashboardHttpException &&
          {401, 403}.contains(error.statusCode)) {
    return workspaceFailureMessage(error);
  }
  return 'Couldn’t reopen this chat. Retry to continue.';
}

/// Structured failure metadata for internal diagnostics; server prose and RPC
/// data can contain chat content or secrets and are deliberately excluded.
Map<String, Object?> workspaceFailureDiagnostic(Object error) {
  if (error is DashboardRequestNotSentException) {
    return {'request_sent': false, ...workspaceFailureDiagnostic(error.cause)};
  }
  return {
    'retryable': isTemporaryWorkspaceFailure(error),
    if (error is DashboardHttpException) 'http_status': error.statusCode,
    if (error is JsonRpcError) ...{
      'rpc_method': error.method,
      if (error.code != null) 'rpc_code': error.code,
      if ({4000, -32602}.contains(error.code)) 'rpc_failure': 'invalid_params',
      if (error.code == -32601) 'rpc_failure': 'method_not_found',
      if ({
        'connection_closed',
        'request_timeout',
        'snapshot_superseded',
      }.contains(error.reason))
        'rpc_reason': error.reason,
    },
  };
}

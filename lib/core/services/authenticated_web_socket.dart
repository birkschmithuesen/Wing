import 'dart:io';

import 'package:web_socket_channel/io.dart';

final HttpClient _noRedirectClient = _NoRedirectWebSocketHttpClient();

/// Opens a gateway socket without forwarding credentials through redirects.
/// Authentication may be carried in headers or in a stock ticket/token URL.
IOWebSocketChannel connectAuthenticatedWebSocket(
  Uri uri, {
  required Map<String, String> headers,
  Duration? connectTimeout,
}) => IOWebSocketChannel.connect(
  uri,
  headers: headers,
  connectTimeout: connectTimeout,
  customClient: _noRedirectClient,
);

/// `WebSocket.connect` only calls `openUrl` on its custom client. The SDK
/// otherwise follows redirects and forwards arbitrary headers to the new
/// origin, so authenticated gateways use this narrow fail-closed seam.
class _NoRedirectWebSocketHttpClient implements HttpClient {
  final HttpClient _inner = HttpClient();

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final request = await _inner.openUrl(method, url);
    request.followRedirects = false;
    return request;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'WebSocket transport used an unsupported HttpClient operation.',
  );
}

import '../models/connection.dart';

/// Resolves the remote file gateway origin with an explicit scheme and port.
String normalizedGatewayBaseUrl(SavedConnection connection) {
  final override = connection.desktopGatewayUrl?.trim() ?? '';
  final overrideUri = override.isEmpty
      ? null
      : Uri.tryParse(override.contains('://') ? override : 'https://$override');
  final isDistinctOverride =
      overrideUri != null &&
      overrideUri.host.isNotEmpty &&
      overrideUri.host.toLowerCase() != connection.host.toLowerCase();
  final raw = isDistinctOverride
      ? override
      : SavedConnection.joinBaseUrl(
          '${connection.useHttps ? 'https' : 'http'}://'
          '${connection.host}:${connection.dashboardPort}',
          connection.dashboardPrefix ?? '',
        );
  final normalized = raw.contains('://') ? raw : 'https://$raw';
  final uri = Uri.tryParse(normalized);
  if (uri == null ||
      uri.host.isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw ArgumentError('Desktop Gateway URL must be an http(s) URL');
  }
  final baseUri = uri.replace(query: '', fragment: '');
  final pathPrefix = baseUri.path == '/' ? '' : baseUri.path;
  final port = baseUri.hasPort
      ? baseUri.port
      : baseUri.scheme == 'https'
      ? 443
      : 80;
  return SavedConnection.joinBaseUrl(
    '${baseUri.scheme}://${baseUri.host}:$port',
    pathPrefix,
  );
}

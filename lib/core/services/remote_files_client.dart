import 'connection_access.dart';
import 'dart:typed_data';

import 'connection_manager.dart';
import 'gateway_endpoint.dart';

/// Budget for in-memory rendering and native preview bridges, not file saving.
const maxFilePreviewBytes = 32 * 1024 * 1024;

class RemoteTextPreview {
  final String path;
  final String text;
  final String language;
  final String mimeType;
  final bool binary;
  final bool truncated;

  const RemoteTextPreview({
    required this.path,
    required this.text,
    required this.language,
    required this.mimeType,
    required this.binary,
    required this.truncated,
  });

  factory RemoteTextPreview.fromJson(Map<String, dynamic> json) =>
      RemoteTextPreview(
        path: json['path'] as String? ?? '',
        text: json['text'] as String? ?? '',
        language: json['language'] as String? ?? 'text',
        mimeType: json['mimeType'] as String? ?? 'text/plain',
        binary: json['binary'] == true,
        truncated: json['truncated'] == true,
      );
}

final class RemoteFileDownload {
  final String filename;
  final Uint8List bytes;

  RemoteFileDownload({required this.filename, required List<int> bytes})
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
}

abstract class RemoteFilesDataSource {
  Future<RemoteTextPreview> readText(
    String path, {
    required String profileName,
    required String storedSessionId,
  });
  Future<RemoteFileDownload> download(
    String path, {
    required String profileName,
    required String storedSessionId,
  });
}

class RemoteFilesClient implements RemoteFilesDataSource {
  final DashboardClient dashboard;

  RemoteFilesClient({required this.dashboard});

  factory RemoteFilesClient.fromConnection(ConnectionAccess access) {
    final connection = access.connection;
    final baseUri = Uri.parse(normalizedGatewayBaseUrl(connection));
    return RemoteFilesClient(
      dashboard: DashboardClient(
        host: baseUri.host,
        port: baseUri.port,
        useHttps: baseUri.scheme == 'https',
        pathPrefix: baseUri.path == '/' ? '' : baseUri.path,
        proxied: connection.dashboardProxied,
        username: connection.dashboardUsername,
        password: connection.dashboardPassword,
        dashboardOAuth: access.dashboardOAuth,
        requiresOAuth: connection.isCloud,
        gatewayHeaders: connection.gatewayHeaders,
        authentication: access.dashboardAuthentication,
      ),
    );
  }

  @override
  Future<RemoteTextPreview> readText(
    String path, {
    required String profileName,
    required String storedSessionId,
  }) async {
    final owner = _owner(profileName, storedSessionId);
    final data = await dashboard.apiGet(
      'fs/read-text',
      queryParameters: {'path': path, ...owner},
    );
    return RemoteTextPreview.fromJson(data);
  }

  @override
  Future<RemoteFileDownload> download(
    String path, {
    required String profileName,
    required String storedSessionId,
  }) async {
    final owner = _owner(profileName, storedSessionId);
    final response = await dashboard.apiGetBytes(
      'fs/download',
      queryParameters: {'path': path, ...owner},
    );
    final disposition = response.headers['content-disposition'] ?? '';
    final encoded = RegExp(
      r'''filename\*=(?:UTF-8'')?([^;]+)''',
      caseSensitive: false,
    ).firstMatch(disposition)?.group(1);
    final plain = RegExp(
      r'''filename=["']?([^"';]+)''',
      caseSensitive: false,
    ).firstMatch(disposition)?.group(1);
    return RemoteFileDownload(
      filename: _safeBasename(encoded ?? plain ?? path),
      bytes: response.bodyBytes,
    );
  }

  Map<String, String> _owner(String profileName, String storedSessionId) {
    final profile = profileName.trim();
    final session = storedSessionId.trim();
    if (profile.isEmpty || session.isEmpty) {
      throw ArgumentError('A profile and saved chat identity are required');
    }
    return {'profile': profile, 'session_id': session};
  }

  String _safeBasename(String value) {
    var decoded = value.trim().replaceAll(RegExp(r'''^["']|["']$'''), '');
    try {
      decoded = Uri.decodeComponent(decoded);
    } on FormatException {
      // Keep the literal server name when percent encoding is malformed.
    }
    final name = decoded.split(RegExp(r'[\\/]')).last.trim();
    return name.isEmpty || name == '.' || name == '..' ? 'download' : name;
  }

  void close() => dashboard.close();
}

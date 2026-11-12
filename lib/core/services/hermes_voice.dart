import 'connection_access.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'connection_manager.dart';

abstract interface class RemoteVoice {
  Future<String> transcribe(Uint8List audio);
  Future<Uint8List> synthesize(String text);
  void close();
}

typedef VoiceRequest =
    Future<Map<String, dynamic>> Function(
      String endpoint,
      Map<String, dynamic> body,
    );

/// Immutable profile scope and a dedicated client that can be closed on cancel.
class HermesVoice implements RemoteVoice {
  static const maxAudioBytes = 25 * 1024 * 1024;
  final String profile;
  final VoiceRequest request;
  final void Function() closeClient;
  HermesVoice({
    required this.profile,
    required this.request,
    required this.closeClient,
  });

  factory HermesVoice.forConnection(ConnectionAccess access, String profile) {
    final connection = access.connection;
    final client = DashboardClient(
      host: connection.host,
      port: connection.dashboardPort,
      useHttps: connection.useHttps,
      pathPrefix: connection.dashboardPrefix ?? '',
      proxied: connection.dashboardProxied,
      username: connection.dashboardUsername,
      password: connection.dashboardPassword,
      dashboardOAuth: access.dashboardOAuth,
      requiresOAuth: connection.isCloud,
      gatewayHeaders: connection.gatewayHeaders,
      authentication: access.dashboardAuthentication,
    );
    return HermesVoice(
      profile: profile,
      closeClient: client.close,
      request: (endpoint, body) => client
          .apiPost(endpoint, body: body)
          .timeout(const Duration(minutes: 3)),
    );
  }
  Future<Map<String, dynamic>> _post(
    String action,
    Map<String, dynamic> body,
  ) => request(
    Uri(
      path: 'audio/$action',
      queryParameters: {'profile': profile},
    ).toString(),
    body,
  );
  @override
  Future<String> transcribe(Uint8List audio) async {
    if (audio.isEmpty || audio.length > maxAudioBytes) {
      throw StateError('Recording is empty or too large.');
    }
    final data = await _post('transcribe', {
      'data_url': 'data:audio/mp4;base64,${base64Encode(audio)}',
      'mime_type': 'audio/mp4',
    });
    if (data['ok'] != true || data['transcript'] is! String) {
      throw const FormatException('Hermes returned an invalid transcription.');
    }
    return (data['transcript'] as String).trim();
  }

  @override
  Future<Uint8List> synthesize(String text) async {
    final data = await _post('speak', {'text': text});
    final url = data['data_url'];
    if (data['ok'] != true ||
        url is! String ||
        !url.startsWith('data:audio/') ||
        !url.contains(';base64,')) {
      throw const FormatException('Hermes returned invalid speech audio.');
    }
    if (url.length > maxAudioBytes * 4 / 3 + 256) {
      throw const FormatException('Hermes speech audio is too large.');
    }
    final bytes = base64Decode(url.substring(url.indexOf(',') + 1));
    if (bytes.isEmpty || bytes.length > maxAudioBytes) {
      throw const FormatException('Hermes speech audio is empty or too large.');
    }
    return bytes;
  }

  @override
  void close() => closeClient();
}

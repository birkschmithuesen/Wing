import 'dart:convert';

import '../core/services/connection_manager.dart';
import 'porter_wake_notice.dart';

enum PorterProbe { active, absent, unknown }

class PorterApiError implements Exception {
  const PorterApiError(this.status, this.serverError);
  final int status;
  final String? serverError;
  String get message => serverError ?? 'The server answered HTTP $status.';
  @override
  String toString() => 'PorterApiError($status)';
}

class PorterQuietHours {
  const PorterQuietHours({
    required this.enabled,
    required this.from,
    required this.to,
    required this.timezone,
  });

  final bool enabled;
  final String from;
  final String to;
  final String timezone;

  factory PorterQuietHours.fromJson(Map<String, dynamic> json) => PorterQuietHours(
    enabled: json['enabled'] as bool,
    from: json['from'] as String,
    to: json['to'] as String,
    timezone: json['timezone'] as String? ?? '',
  );

  PorterQuietHours copyWith({bool? enabled, String? from, String? to}) =>
      PorterQuietHours(
        enabled: enabled ?? this.enabled,
        from: from ?? this.from,
        to: to ?? this.to,
        timezone: timezone,
      );

  /// The timezone is read-only on the server; sending it answers 400.
  Map<String, Object> toPutJson() => {'enabled': enabled, 'from': from, 'to': to};
}

/// The porter wake routes of contract §3 over the connection's dashboard auth.
class PorterWakeApi {
  PorterWakeApi(this._client);

  final DashboardClient _client;
  static const _base = 'plugins/porter_wake';

  Future<PorterProbe> probe() async {
    try {
      await _json('GET', 'settings/quiet-hours');
      return PorterProbe.active;
    } on PorterApiError catch (error) {
      return error.status == 404 || error.status == 503
          ? PorterProbe.absent
          : PorterProbe.unknown;
    } on Object {
      return PorterProbe.unknown;
    }
  }

  Future<PorterNotice> notice(String noticeId) async =>
      PorterNotice.fromJson(await _json('GET', 'notices/$noticeId'));

  Future<bool> feedback(String noticeId, Map<String, String> body) async =>
      (await _json('POST', 'notices/$noticeId/feedback', body: body))['applied'] == true;

  Future<PorterQuietHours> quietHours() async =>
      PorterQuietHours.fromJson(await _json('GET', 'settings/quiet-hours'));

  Future<PorterQuietHours> saveQuietHours(PorterQuietHours value) async =>
      PorterQuietHours.fromJson(
        await _json('PUT', 'settings/quiet-hours', body: value.toPutJson()),
      );

  Future<void> registerDevice({
    required String deviceId,
    required String endpoint,
    String? label,
  }) => _json('POST', 'push/devices', body: {
    'device_id': deviceId,
    'endpoint': endpoint,
    'label': ?label,
  });

  Future<void> removeDevice(String deviceId) =>
      _json('DELETE', 'push/devices/$deviceId');

  void close() => _client.close();

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, Object>? body,
  }) async {
    final res = await _client
        .apiSend(method, '$_base/$path', body: body)
        .timeout(const Duration(seconds: 20));
    Object? decoded;
    try {
      decoded = res.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      decoded = null;
    }
    final map = decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{};
    if (res.statusCode != 200) {
      final error = map['error'];
      throw PorterApiError(res.statusCode, error is String ? error : null);
    }
    return map;
  }
}

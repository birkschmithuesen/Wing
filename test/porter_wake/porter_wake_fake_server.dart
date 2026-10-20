import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wing/core/services/connection_manager.dart';

import 'porter_wake_fixtures.dart';

/// Fake dashboard for porter wake tests. Synthetic data only.
class FakePorterServer {
  static const base = '/api/plugins/porter_wake';
  final requests = <http.Request>[];
  final _statusFor = <String, int>{};
  Map<String, int> get statusFor => _statusFor;
  final bodyFor = <String, Object?>{};
  int logins = 0;
  Map<String, Object?> quietHours = {
    'enabled': true,
    'from': '22:00',
    'to': '08:00',
    'timezone': 'Europe/Berlin',
  };

  List<http.Request> porterRequests() =>
      requests.where((r) => r.url.path.startsWith(base)).toList();

  DashboardClient client() => DashboardClient(
    host: 'hermes.test',
    port: 9119,
    username: 'owner',
    password: 'fixture',
    httpClient: MockClient(_handle),
  );

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path == '/auth/password-login') {
      logins++;
      return http.Response('{}', 200,
          headers: {'set-cookie': 'hermes_session_at=fixture; Path=/'});
    }
    final key = '${request.method} $path';
    final status = statusFor[key] ?? 200;
    Object? body = bodyFor[key];
    if (body == null && status == 200) body = _default(request, path);
    return http.Response.bytes(
      utf8.encode(jsonEncode(body ?? {'error': 'fixture error'})),
      status,
      headers: {'content-type': 'application/json'},
    );
  }

  Object? _default(http.Request request, String path) {
    if (path == '$base/settings/quiet-hours') {
      if (request.method == 'PUT') {
        quietHours = {...jsonDecode(request.body) as Map<String, dynamic>,
            'timezone': 'Europe/Berlin'};
      }
      return quietHours;
    }
    for (var i = 0; i < porterNoticeIds.length; i++) {
      final id = porterNoticeIds[i];
      if (path == '$base/notices/$id') return jsonDecode(porterExamples[i]);
      if (path == '$base/notices/$id/feedback') {
        final sent = jsonDecode(request.body) as Map<String, dynamic>;
        return {'notice_id': id, 'action': sent['action'], 'applied': true, 'result': {}};
      }
    }
    if (path == '$base/push/devices') {
      return {'device_id': 'x', 'registered': '2026-10-19T06:00:00.000Z', 'replaced': false};
    }
    if (path.startsWith('$base/push/devices/')) return {'removed': true};
    return null;
  }
}

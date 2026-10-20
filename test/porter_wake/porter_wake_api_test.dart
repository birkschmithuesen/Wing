import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/porter_wake/porter_wake_api.dart';

import 'porter_wake_fake_server.dart';

void main() {
  late FakePorterServer server;
  late PorterWakeApi api;
  setUp(() {
    server = FakePorterServer();
    api = PorterWakeApi(server.client());
  });

  test('probe: 200 active, 404 and 503 absent, 500 unknown', () async {
    expect(await api.probe(), PorterProbe.active);
    for (final (status, expected) in [
      (404, PorterProbe.absent),
      (503, PorterProbe.absent),
      (500, PorterProbe.unknown),
    ]) {
      server.statusFor['GET ${FakePorterServer.base}/settings/quiet-hours'] = status;
      expect(await api.probe(), expected, reason: '$status');
    }
  });

  test('a 401 re-logs in once and retries', () async {
    final s = _FlakyAuthServer();
    expect(await PorterWakeApi(s.client()).probe(), PorterProbe.active);
    expect(s.logins, 2);
  });

  test('notice text survives UTF-8 (emoji and umlauts)', () async {
    final n = await api.notice('n-9e8d7c6b5a41');
    expect(n.title, '🔴 3 Dinge warten');
    expect(n.items.last.line, 'Zugangsdaten im Klartext in Notiz gefunden: löschen?');
  });

  test('saveQuietHours sends exactly enabled, from, to and returns the 200 body', () async {
    final saved = await api.saveQuietHours(
      const PorterQuietHours(enabled: true, from: '22:00', to: '07:30', timezone: 'Europe/Berlin'),
    );
    final put = server.porterRequests().last;
    expect(put.method, 'PUT');
    expect(jsonDecode(put.body), {'enabled': true, 'from': '22:00', 'to': '07:30'});
    expect(saved.to, '07:30');
  });

  test('400 and 409 carry the server error text', () async {
    for (final (status, text) in [(400, 'from equals to'), (409, 'config layout not editable')]) {
      server.statusFor['PUT ${FakePorterServer.base}/settings/quiet-hours'] = status;
      server.bodyFor['PUT ${FakePorterServer.base}/settings/quiet-hours'] = {'error': text};
      await expectLater(
        api.saveQuietHours(const PorterQuietHours(
            enabled: true, from: '22:00', to: '22:00', timezone: 'Europe/Berlin')),
        throwsA(isA<PorterApiError>()
            .having((e) => e.status, 'status', status)
            .having((e) => e.message, 'message', text)),
      );
    }
  });

  test('device registration and removal use the contract shapes', () async {
    await api.registerDevice(
      deviceId: 'wing-0123456789abcdef',
      endpoint: 'http://100.75.24.33:2586/upAbC123xyz?up=1',
      label: 'Pixel 7',
    );
    await api.removeDevice('wing-0123456789abcdef');
    final [post, delete] = server.porterRequests();
    expect(post.url.path, '${FakePorterServer.base}/push/devices');
    expect(jsonDecode(post.body), {
      'device_id': 'wing-0123456789abcdef',
      'endpoint': 'http://100.75.24.33:2586/upAbC123xyz?up=1',
      'label': 'Pixel 7',
    });
    expect(delete.method, 'DELETE');
    expect(delete.url.path, '${FakePorterServer.base}/push/devices/wing-0123456789abcdef');
  });
}

/// The first quiet-hours GET answers 401; the retry after re-login answers 200.
class _FlakyAuthServer extends FakePorterServer {
  var _rejected = false;
  @override
  Map<String, int> get statusFor {
    if (!_rejected && requests.where((r) => r.url.path.endsWith('/quiet-hours')).length == 1) {
      _rejected = true;
      return {'GET ${FakePorterServer.base}/settings/quiet-hours': 401};
    }
    return {};
  }
}

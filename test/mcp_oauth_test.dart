import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/mcp_oauth.dart';
import 'package:wing/core/services/ws_client.dart';
import 'support/administration_fixture.dart';

class FlowFixture {
  final fixture = AdministrationFixture();
  final requests = <(String, Map<String, dynamic>)>[];
  Uri? target;
  Future<bool> Function(Uri)? receive;
  int closed = 0;
  String pollStatus = 'pending';
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)? override;
  late final flow = McpOAuth(
    profile: fixture.server.profile('personal'),
    name: 'aspire',
    bindLoopback: (uri, callback) async {
      target = uri;
      receive = callback;
      return McpLoopback(
        close: () async {
          closed++;
        },
      );
    },
  );
  FlowFixture() {
    fixture.configs['personal']!['mcp_servers'] = {
      'aspire': <String, dynamic>{
        'url': 'https://example.test/mcp',
        'auth': 'oauth',
      },
    };
    fixture.rpcOverride = (method, params) async {
      requests.add((method, {...params}));
      if (override != null) return override!(method, params);
      return response(method, params);
    };
  }
  Map<String, dynamic> response(String method, Map<String, dynamic> params) => {
    'ok': true,
    if (method.endsWith('.start')) ...{
      'session_id': 'session',
      'flow': 'pkce',
      'auth_url': Uri.https('oauth.test', '/authorize', {
        'state': 'fixture-state',
        'redirect_uri': params['client_redirect_uri'] as String,
      }).toString(),
    },
    if (method.endsWith('.poll')) ...{
      'status': pollStatus,
      'error_message': 'Authorization denied.',
    },
  };
  Uri callback({String state = 'fixture-state'}) => target!.replace(
    queryParameters: {
      'code': 'fixture-code',
      'state': state,
      'iss': 'https://oauth.test',
    },
  );
  Map get entry =>
      (fixture.configs['personal']!['mcp_servers'] as Map)['aspire'] as Map;
}

void main() {
  test('only temporary poll failures permit event recovery', () async {
    final h = FlowFixture();
    addTearDown(h.flow.dispose);
    await h.flow.start();
    expect(h.flow.canRecoverPoll, isTrue);
    h.override = (_, _) async => throw TimeoutException('Offline');
    await h.flow.poll();
    expect(h.flow.canRecoverPoll, isTrue);
    h.override = (_, _) async => {'ok': true, 'status': 'unknown'};
    await h.flow.poll();
    expect(h.flow.pending, isTrue);
    expect(h.flow.canRecoverPoll, isFalse);
    h.override = null;
    h.pollStatus = 'approved';
    await h.flow.poll(); // Explicit Check status is still available.
    expect(h.flow.status, 'approved');
    expect(h.flow.canRecoverPoll, isFalse);
    expect(h.requests.where((r) => r.$1.endsWith('.start')).length, 1);
  });

  test(
    'provider callback rejection explains the next action without losing its reason',
    () async {
      final h = FlowFixture();
      addTearDown(h.flow.dispose);
      h.override = (method, _) async => throw JsonRpcError(
        method,
        'Registration failed: invalid_client_metadata: redirect_uri is not an approved callback destination',
        code: 5024,
      );
      await h.flow.start();
      expect(h.flow.error, contains('service rejected the callback address'));
      expect(h.flow.error, contains('invalid_client_metadata'));
      expect(h.closed, 1);
    },
  );

  test(
    'automatic receipt relays code/state/issuer to captured profile, approval comes from poll',
    () async {
      final h = FlowFixture();
      addTearDown(h.flow.dispose);
      await h.flow.start();
      expect(h.flow.pending, isTrue);
      expect(await h.receive!(h.callback()), isTrue);
      expect(h.flow.status, 'pending');
      final request = h.requests.last;
      expect(request.$1, 'mcp.servers.oauth.callback');
      expect(request.$2, {
        'profile': 'personal',
        'name': 'aspire',
        'session_id': 'session',
        'code': 'fixture-code',
        'state': 'fixture-state',
        'iss': 'https://oauth.test',
      });
      expect(await h.flow.submitCallback(h.callback().toString()), isFalse);
      h.pollStatus = 'approved';
      await h.flow.poll();
      expect(h.flow.status, 'approved');
      expect(h.closed, 1);
    },
  );

  test(
    'paste rejects wrong destination, state, duplicates, missing response and fragments',
    () async {
      final h = FlowFixture();
      addTearDown(h.flow.dispose);
      await h.flow.start();
      for (final uri in [
        h.callback(state: 'other'),
        h.callback().replace(host: 'evil.test'),
        h.callback().replace(path: '/other'),
        h.callback().replace(fragment: 'code=secret'),
        h.callback().replace(query: 'code=one&code=two&state=fixture-state'),
        h.callback().replace(
          query: 'code=one&error=denied&state=fixture-state',
        ),
        h.callback().replace(query: 'state=fixture-state'),
      ]) {
        expect(await h.flow.submitCallback(uri.toString()), isFalse);
      }
      expect(h.requests.length, 1);
      expect(await h.flow.submitCallback(h.callback().toString()), isTrue);
    },
  );

  test('provider denial is relayed and reported by Hermes', () async {
    final h = FlowFixture();
    addTearDown(h.flow.dispose);
    await h.flow.start();
    expect(
      await h.flow.submitCallback(
        h.target!
            .replace(
              queryParameters: {
                'state': 'fixture-state',
                'error': 'access_denied',
              },
            )
            .toString(),
      ),
      isTrue,
    );
    h.pollStatus = 'error';
    await h.flow.poll();
    expect(h.flow.error, contains('Authorization denied'));
    expect(h.closed, 1);
  });

  test('repeat attempts keep a stable per-profile callback port', () async {
    final h = FlowFixture();
    addTearDown(h.flow.dispose);
    await h.flow.start();
    final first = h.target;
    await h.flow.cancel();
    await h.flow.start();
    expect(h.target, first);
    expect(h.flow.pending, isTrue);
    final other = McpOAuth(
      profile: h.fixture.server.profile('work'),
      name: 'aspire',
    );
    expect(other.defaultCallback, isNot(first));
    other.dispose();
  });

  test('registered localhost callback is preserved', () async {
    final h = FlowFixture();
    addTearDown(h.flow.dispose);
    h.entry['oauth'] = {'redirect_uri': 'http://localhost:42123/approved'};
    await h.flow.start();
    expect(h.target.toString(), 'http://localhost:42123/approved');
    expect(await h.receive!(h.callback()), isTrue);
  });

  test(
    'configured HTTPS callback accepts manual relay only for the exact destination',
    () async {
      final h = FlowFixture();
      addTearDown(h.flow.dispose);
      h.entry['oauth'] = {'redirect_uri': 'https://private.test/callback'};
      h.override = (method, params) async => h.response(method, {
        ...params,
        'client_redirect_uri': 'https://private.test/callback',
      });
      await h.flow.start();
      expect(h.flow.manualOnly, isTrue);
      expect(h.target, isNull);
      expect(
        await h.flow.submitCallback(
          'https://private.test/callback?code=fixture-code&state=fixture-state',
        ),
        isTrue,
      );
    },
  );

  test(
    'callback override mismatch blocks opening the authorization link',
    () async {
      final h = FlowFixture();
      addTearDown(h.flow.dispose);
      h.override = (method, params) async => h.response(method, {
        ...params,
        'client_redirect_uri': 'https://other.test/callback',
      });
      await h.flow.start();
      expect(h.flow.authUrl, isNull);
      expect(h.flow.error, contains('different callback'));
      await h.flow.cancel();
    },
  );

  test(
    'device-code configuration gets terminal guidance without starting browser OAuth',
    () async {
      final h = FlowFixture();
      addTearDown(h.flow.dispose);
      h.entry['oauth'] = {'flow': 'device'};
      await h.flow.start();
      expect(h.flow.terminalRequired, isTrue);
      expect(h.requests, isEmpty);
      expect(h.target, isNull);
    },
  );

  test(
    'missing RPC produces update guidance and closes phone listener',
    () async {
      final h = FlowFixture();
      addTearDown(h.flow.dispose);
      h.override = (method, _) async =>
          throw JsonRpcError(method, 'Unknown method', code: -32601);
      await h.flow.start();
      expect(h.flow.error, contains('Update Hermes'));
      expect(h.closed, 1);
    },
  );

  test(
    'dispose while start is outstanding cancels the returned session',
    () async {
      final h = FlowFixture();
      final started = Completer<void>();
      final gate = Completer<void>();
      h.override = (method, params) async {
        if (method.endsWith('.start')) {
          started.complete();
          await gate.future;
        }
        return h.response(method, params);
      };
      final pending = h.flow.start();
      await started.future;
      h.flow.dispose();
      gate.complete();
      await pending;
      expect(h.requests.last.$1, 'mcp.servers.oauth.cancel');
      expect(h.closed, 1);
    },
  );

  test('a late poll cannot resurrect a cancelled attempt', () async {
    final h = FlowFixture();
    addTearDown(h.flow.dispose);
    await h.flow.start();
    final gate = Completer<void>();
    final polled = Completer<void>();
    h.override = (method, params) async {
      if (method.endsWith('.poll')) {
        polled.complete();
        await gate.future;
      }
      return h.response(method, params);
    };
    final poll = h.flow.poll();
    await polled.future;
    await h.flow.cancel();
    gate.complete();
    await poll;
    expect(h.flow.status, 'cancelled');
    expect(h.closed, 1);
  });

  test('failed cancel keeps the pending session available to retry', () async {
    final h = FlowFixture();
    addTearDown(h.flow.dispose);
    await h.flow.start();
    h.override = (_, _) async => throw StateError('disconnected');
    expect(await h.flow.cancel(), isFalse);
    expect(h.flow.pending, isTrue);
    expect(h.closed, 0);
    h.override = null;
    expect(await h.flow.cancel(), isTrue);
    expect(h.closed, 1);
  });

  test(
    'real phone loopback listener relays a browser response without echoing its code',
    () async {
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = reservation.port;
      await reservation.close();
      Uri? received;
      final target = Uri.parse('http://127.0.0.1:$port/callback');
      final listener = await McpLoopback.bind(target, (uri) async {
        received = uri;
        return true;
      });
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      addTearDown(() async {
        client.close(force: true);
        await listener.close();
      });
      final callback = target.replace(
        queryParameters: {'code': 'fixture-secret', 'state': 'fixture-state'},
      );
      final response = await (await client.getUrl(callback)).close();
      final body = await response.fold<String>(
        '',
        (text, bytes) => text + String.fromCharCodes(bytes),
      );
      expect(response.statusCode, 200);
      expect(received, callback);
      expect(body, isNot(contains('fixture-secret')));
      expect(response.headers.value('cache-control'), 'no-store');
    },
  );
}

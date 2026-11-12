import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wing/core/services/connection_manager.dart';

const _renameBody = {'new_name': 'studio'};
const _renameAck = {'ok': true, 'name': 'studio', 'path': '/fixture/studio'};

http.Response _authenticated() =>
    http.Response('window.__HERMES_SESSION_TOKEN__="fixture-token";', 200);

void main() {
  for (final renew in [false, true]) {
    test(
      'authorized profile PATCH ${renew ? 'renews once' : 'dispatches'} with its captured command',
      () async {
        var writes = 0, logins = 0, dispatched = 0;
        final client = DashboardClient(
          host: 'fixture.invalid',
          httpClient: MockClient((request) async {
            if (request.url.path == '/') {
              logins++;
              return _authenticated();
            }
            expect(request.method, 'PATCH');
            expect(request.url.path, '/api/profiles/work');
            expect(jsonDecode(request.body), _renameBody);
            writes++;
            if (renew && writes == 1) return http.Response('{}', 401);
            return http.Response(
              '{"ok":true,"name":"studio","path":"/fixture/studio"}',
              200,
            );
          }),
        );
        addTearDown(client.close);
        expect(
          await client.apiWriteOwned(
            'PATCH',
            'profiles/work',
            body: _renameBody,
            canDispatch: () => true,
            onDispatched: () => dispatched++,
          ),
          _renameAck,
        );
        expect(writes, renew ? 2 : 1);
        expect(logins, renew ? 2 : 1);
        expect(dispatched, 1);
      },
    );
  }

  for (final renew in [false, true]) {
    test(
      'retired profile PATCH during ${renew ? '401 renewal' : 'authentication'} sends no later write',
      () async {
        final entered = Completer<void>();
        final held = Completer<http.Response>();
        var active = true, logins = 0, writes = 0, dispatched = 0;
        final client = DashboardClient(
          host: 'fixture.invalid',
          httpClient: MockClient((request) async {
            if (request.url.path == '/') {
              logins++;
              if (logins == (renew ? 2 : 1)) {
                entered.complete();
                return held.future;
              }
              return _authenticated();
            }
            expect(request.method, 'PATCH');
            expect(request.url.path, '/api/profiles/work');
            expect(jsonDecode(request.body), _renameBody);
            writes++;
            return http.Response('{}', 401);
          }),
        );
        addTearDown(client.close);
        final result = client.apiWriteOwned(
          'PATCH',
          'profiles/work',
          body: _renameBody,
          canDispatch: () => active,
          onDispatched: () => dispatched++,
        );
        final assertion = expectLater(
          result,
          throwsA(isA<DashboardRequestNotSentException>()),
        );
        await entered.future;
        active = false;
        held.complete(_authenticated());
        await assertion;
        expect(writes, renew ? 1 : 0);
        expect(dispatched, renew ? 1 : 0);
      },
    );
  }

  test('connection closure fences a still-authorized profile PATCH', () async {
    final entered = Completer<void>();
    final held = Completer<http.Response>();
    var writes = 0, dispatched = 0;
    final client = DashboardClient(
      host: 'fixture.invalid',
      httpClient: MockClient((request) async {
        if (request.url.path == '/') {
          entered.complete();
          return held.future;
        }
        writes++;
        return http.Response('{"ok":true}', 200);
      }),
    );
    addTearDown(client.close);
    final result = client.apiWriteOwned(
      'PATCH',
      'profiles/work',
      body: _renameBody,
      canDispatch: () => true,
      onDispatched: () => dispatched++,
    );
    final assertion = expectLater(
      result,
      throwsA(isA<DashboardRequestNotSentException>()),
    );
    await entered.future;
    client.close();
    held.complete(_authenticated());
    await assertion;
    expect(writes, 0);
    expect(dispatched, 0);
  });
}

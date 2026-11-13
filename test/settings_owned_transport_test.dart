import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/models/settings_edit.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/settings_edit_session.dart';
import 'support/administration_fixture.dart';

void main() {
  test(
    'owned DELETE retains the exact scoped JSON body and acknowledgement',
    () async {
      var dispatched = 0;
      final client = DashboardClient(
        host: 'fixture.invalid',
        httpClient: MockClient((request) async {
          if (request.url.path == '/') {
            return http.Response(
              'window.__HERMES_SESSION_TOKEN__="fixture-token";',
              200,
            );
          }
          expect(request.method, 'DELETE');
          expect(request.url.path, '/api/env');
          expect(request.body, '{"key":"API_KEY","profile":"work"}');
          return http.Response('{"ok":true,"key":"API_KEY"}', 200);
        }),
      );
      addTearDown(client.close);
      expect(
        await client.apiWriteOwned(
          'DELETE',
          'env',
          body: {'key': 'API_KEY', 'profile': 'work'},
          canDispatch: () => true,
          onDispatched: () => dispatched++,
        ),
        {'ok': true, 'key': 'API_KEY'},
      );
      expect(dispatched, 1);
    },
  );
  test(
    'settled auth timeout revokes the still-open settings command',
    () async {
      final fixture = AdministrationFixture();
      final held = Completer<http.Response>();
      final entered = Completer<void>();
      var writes = 0;
      final client = DashboardClient(
        host: 'fixture.invalid',
        httpClient: MockClient((request) async {
          if (request.url.path == '/') {
            entered.complete();
            return held.future;
          }
          if (request.method == 'PUT') {
            writes++;
          }
          return http.Response('{"ok":true}', 200);
        }),
      );
      addTearDown(client.close);
      final server = AdministrationRepository(
        ownedMutation: (_, _, _, _, _, _) async =>
            throw StateError('Unexpected model mutation'),
        connectionId: fixture.server.connectionId,
        connectionIdentity: fixture.server.connectionIdentity,
        connectionLabel: fixture.server.connectionLabel,
        request: fixture.send,
        gateway: fixture.server.gateway,
        settingsWrite: (name, patch, canDispatch, onDispatched) => client
            .apiWriteOwned(
              'PUT',
              'config',
              body: {'profile': name, 'config': patch},
              canDispatch: canDispatch,
              onDispatched: onDispatched,
            )
            .timeout(const Duration(milliseconds: 20)),
      );
      final session = SettingsEditSession(
        server.profile('personal'),
        fields: [memoryFields[2]],
      );
      addTearDown(session.dispose);
      await session.load();
      session.setText(memoryFields[2].key, '2500');
      final result = session.save();
      await entered.future;
      expect(await result, SettingsSaveOutcome.failed);
      expect(session.state.saving, false);
      expect(session.state.dirtyCount, 1);
      held.complete(
        http.Response('window.__HERMES_SESSION_TOKEN__="fixture-token";', 200),
      );
      // Drain the actual auth/read future and the already-timed-out PUT chain.
      await client.apiGet('profiles');
      expect(writes, 0);
    },
  );
  for (final method in ['PUT', 'POST', 'DELETE']) {
    test(
      '$method retired during authentication never starts HTTP write',
      () async {
        final held = Completer<http.Response>();
        final entered = Completer<void>();
        var active = true, writes = 0, dispatched = 0;
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
          method,
          'config?profile=personal',
          body: {'config': {}},
          canDispatch: () => active,
          onDispatched: () => dispatched++,
        );
        final assertion = expectLater(
          result,
          throwsA(isA<DashboardRequestNotSentException>()),
        );
        await entered.future;
        active = false;
        held.complete(
          http.Response(
            'window.__HERMES_SESSION_TOKEN__="fixture-token";',
            200,
          ),
        );
        await assertion;
        expect(writes, 0);
        expect(dispatched, 0);
      },
    );
  }
  for (final method in ['PUT', 'POST', 'DELETE']) {
    test(
      '$method retired during 401 credential renewal never sends replacement write',
      () async {
        final renewal = Completer<http.Response>();
        final entered = Completer<void>();
        var active = true, logins = 0, writes = 0, dispatched = 0;
        final client = DashboardClient(
          host: 'fixture.invalid',
          httpClient: MockClient((request) async {
            if (request.url.path == '/') {
              if (++logins == 2) {
                entered.complete();
                return renewal.future;
              }
              return http.Response(
                'window.__HERMES_SESSION_TOKEN__="fixture-first";',
                200,
              );
            }
            writes++;
            return http.Response('{}', 401);
          }),
        );
        addTearDown(client.close);
        final result = client.apiWriteOwned(
          method,
          'config',
          body: {},
          canDispatch: () => active,
          onDispatched: () => dispatched++,
        );
        final assertion = expectLater(
          result,
          throwsA(isA<DashboardRequestNotSentException>()),
        );
        await entered.future;
        active = false;
        renewal.complete(
          http.Response(
            'window.__HERMES_SESSION_TOKEN__="fixture-second";',
            200,
          ),
        );
        await assertion;
        expect(writes, 1);
        expect(dispatched, 1);
      },
    );
  }
  test(
    'connection closure during authentication fences a still-active command',
    () async {
      final held = Completer<http.Response>();
      final entered = Completer<void>();
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
      final result = client.apiWriteOwned(
        'POST',
        'model/set',
        body: {},
        canDispatch: () => true,
        onDispatched: () => dispatched++,
      );
      final assertion = expectLater(
        result,
        throwsA(isA<DashboardRequestNotSentException>()),
      );
      await entered.future;
      client.close();
      held.complete(
        http.Response('window.__HERMES_SESSION_TOKEN__="fixture-token";', 200),
      );
      await assertion;
      expect(writes, 0);
      expect(dispatched, 0);
    },
  );
  test(
    'authorized renewal marks dispatch once and keeps original command body',
    () async {
      var writes = 0, dispatched = 0;
      final client = DashboardClient(
        host: 'fixture.invalid',
        httpClient: MockClient((request) async {
          if (request.url.path == '/') {
            return http.Response(
              'window.__HERMES_SESSION_TOKEN__="fixture-token";',
              200,
            );
          }
          expect(request.method, 'POST');
          expect(request.url.path, '/api/model/set');
          expect(request.body, '{"scope":"main","model":"captured"}');
          return http.Response(
            ++writes == 1 ? '{}' : '{"ok":true}',
            writes == 1 ? 401 : 200,
          );
        }),
      );
      addTearDown(client.close);
      expect(
        await client.apiWriteOwned(
          'POST',
          'model/set',
          body: {'scope': 'main', 'model': 'captured'},
          canDispatch: () => true,
          onDispatched: () => dispatched++,
        ),
        {'ok': true},
      );
      expect(writes, 2);
      expect(dispatched, 1);
    },
  );
}

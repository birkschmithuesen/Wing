import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_fallback_edit_session.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_model_edit_session.dart';
import 'package:wing/core/services/profiles_repository.dart';

void main() {
  for (final route in ['main', 'fallback']) {
    for (final timeout in [false, true]) {
      test('$route ${timeout ? 'settled timeout' : 'retired route'} cannot '
          'dispatch when held authentication finishes', () async {
        final authentication = Completer<http.Response>();
        final entered = Completer<void>();
        var writes = 0, dispatches = 0;
        final client = DashboardClient(
          host: 'fixture.invalid',
          httpClient: MockClient((request) async {
            if (request.url.path == '/') {
              if (!entered.isCompleted) entered.complete();
              return authentication.future;
            }
            if (request.method == 'POST' || request.method == 'PUT') writes++;
            return http.Response('{"ok":true}', 200);
          }),
        );
        addTearDown(client.close);

        Future<Map<String, dynamic>> withTimeout(
          Future<Map<String, dynamic>> response,
        ) => timeout
            ? response.timeout(const Duration(milliseconds: 20))
            : response;
        Future<Map<String, dynamic>> mutate(
          String method,
          String endpoint,
          Map<String, dynamic> body,
          bool Function() canDispatch,
          void Function() onDispatched,
        ) => withTimeout(
          client.apiWriteOwned(
            method,
            endpoint,
            body: body,
            canDispatch: canDispatch,
            onDispatched: () {
              dispatches++;
              onDispatched();
            },
          ),
        );

        late Future<void> Function() save;
        late void Function() dispose;
        late bool Function() dirty;
        late String? Function() error;
        if (route == 'main') {
          final owner = ProfileModelEditSession(
            ProfileGateway(
              scope: WorkspaceScope(
                connectionId: 'test',
                connectionIdentity: 'held-auth',
                profileName: 'work',
              ),
              get: (endpoint, query) async {
                expect(query['profile'], 'work');
                if (endpoint == 'model/info') {
                  return {'provider': 'p', 'model': 'before'};
                }
                if (endpoint == 'model/options') {
                  return {
                    'providers': [
                      {
                        'slug': 'p',
                        'name': 'Provider',
                        'models': ['before', 'after'],
                      },
                    ],
                  };
                }
                throw StateError(endpoint);
              },
              // The generic capability remains a real transport for the frozen
              // original-source counterexample. The route must choose ownedPost.
              post: (endpoint, body) =>
                  withTimeout(client.apiPost(endpoint, body: body)),
              ownedPost: (endpoint, body, canDispatch, onDispatched) =>
                  mutate('POST', endpoint, body, canDispatch, onDispatched),
              rpc: (_, _) async => throw StateError('Unexpected RPC'),
              discover: () async => const ProfileDiscovery(
                profiles: [HermesProfile(name: 'work')],
                currentName: 'work',
                activeName: 'work',
              ),
            ),
          );
          await owner.load();
          owner.select(owner.choices.last);
          save = () async {
            await owner.save(confirm: (_) async => true);
          };
          dispose = owner.dispose;
          dirty = () => owner.dirty;
          error = () => owner.error;
        } else {
          final server = AdministrationRepository(
            connectionId: 'test',
            connectionIdentity: 'held-auth',
            connectionLabel: 'Test',
            gateway: (_) => throw StateError('Unexpected gateway'),
            settingsWrite: (_, _, _, _) async =>
                throw StateError('Unexpected settings write'),
            ownedMutation:
                (method, endpoint, query, body, canDispatch, onDispatched) =>
                    mutate(
                      method,
                      Uri(path: endpoint, queryParameters: query).toString(),
                      body,
                      canDispatch,
                      onDispatched,
                    ),
            request: (method, endpoint, query, body) async {
              if (endpoint == 'profiles') {
                return {
                  'profiles': [
                    {'name': 'work', 'is_default': false},
                  ],
                };
              }
              if (endpoint == 'profiles/active') {
                return {'current': 'work', 'active': 'work'};
              }
              expect(query['profile'], 'work');
              if (endpoint == 'config' && method == 'GET') {
                return {
                  'fallback_providers': [
                    {'provider': 'p', 'model': 'before'},
                    {'provider': 'p', 'model': 'other'},
                  ],
                };
              }
              // The original owner used this unchecked mutation transport.
              if (endpoint == 'config' && method == 'PUT') {
                return withTimeout(client.apiPut(endpoint, body: body));
              }
              throw StateError('$method $endpoint');
            },
          );
          final owner = ProfileFallbackEditSession(server.profile('work'));
          await owner.load();
          save = () => owner.remove(0);
          dispose = owner.dispose;
          dirty = () => owner.pending != null;
          error = () => owner.error;
        }

        final operation = save();
        await entered.future;
        if (timeout) {
          await operation;
        } else {
          dispose();
        }
        authentication.complete(
          http.Response(
            'window.__HERMES_SESSION_TOKEN__="fixture-token";',
            200,
          ),
        );
        // Drain the shared actual authentication future after the owner has
        // retired or settled. No guessed delay establishes the send ordering.
        await client.apiGet('profiles');
        await operation;
        expect(writes, 0);
        expect(dispatches, 0);
        if (timeout) {
          expect(dirty(), isTrue);
          expect(error(), contains('not sent'));
          dispose();
        }
      });
    }
  }
}

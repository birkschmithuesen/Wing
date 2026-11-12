import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:convert';
import 'dart:async';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/session_visibility.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'dart:io';

import 'support/gateway_application_requests.dart';
import 'support/canonical_gateway_fixture.dart';
import 'package:wing/core/services/ws_client.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/chat_browser_data.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

void main() {
  test('read acknowledgement supplies stock mutation identity', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final patches = <Map<String, dynamic>>[];
    final snapshots = <Uri>[];
    final subscription = server.listen((request) async {
      Object result;
      if (request.uri.path == '/auth/password-login') {
        await request.drain<void>();
        request.response.headers.add(
          'set-cookie',
          'hermes_session_at=fixture; Path=/',
        );
        result = <String, Object>{};
      } else if (request.uri.path.endsWith('/mutation-snapshot')) {
        snapshots.add(request.uri);
        result = {
          'session_id': 'chat',
          'exists': true,
          'runtime_revision': 7,
          'runtime_generation': 3,
        };
      } else if (request.method == 'PATCH') {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        patches.add(body);
        if (body['request_id'] is! String || body['expected_revision'] != 7) {
          request.response.statusCode = 409;
          result = {'detail': 'mutation_identity_required'};
        } else {
          result = {'ok': true, 'unread': false};
        }
      } else {
        result = switch (request.uri.path) {
          '/api/profiles' => {
            'profiles': [
              {'name': 'personal'},
            ],
          },
          '/api/profiles/active' => {
            'current': 'personal',
            'active': 'personal',
          },
          _ => throw StateError(
            'Unexpected fixture route: ${request.uri.path}',
          ),
        };
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
      await request.response.close();
    });
    final gateway = ProfileGateway.forConnection(
      ConnectionAccess(
        connection: SavedConnection(
          id: 'read-receipt',
          label: 'Fixture',
          host: '127.0.0.1',
          port: server.port,
          dashboardPortOverride: server.port,
          apiKey: '',
          dashboardUsername: 'fixture',
          dashboardPassword: 'fixture',
        ),
        dashboardOAuth: null,
      ),
      WorkspaceScope(connectionId: 'read-receipt', profileName: 'personal'),
    );
    addTearDown(() async {
      gateway.close();
      await subscription.cancel();
      await server.close(force: true);
    });
    final result = await gateway.updateSession('chat', {
      'unread': false,
    }, canDispatch: () => true);
    expect(result['ok'], true);
    expect(snapshots.single.queryParameters['profile'], 'personal');
    expect(patches.single, containsPair('profile', 'personal'));
    expect(patches.single, containsPair('expected_generation', 3));
    expect(patches.single['request_id'], isNotEmpty);
  });

  Map<String, dynamic> mutationSnapshot() => {
    'session_id': 'chat',
    'exists': true,
    'runtime_revision': 7,
    'runtime_generation': 3,
  };

  for (final owner in ['old', 'conversation-root']) {
    test(
      'workspace move prepares saved chat before fencing owner $owner',
      () async {
        var prepared = false;
        final order = <String>[];
        final gateway = ProfileGateway(
          scope: WorkspaceScope(connectionId: 'move', profileName: 'personal'),
          discover: () async => const ProfileDiscovery(
            profiles: [HermesProfile(name: 'personal')],
            currentName: 'personal',
            activeName: 'personal',
          ),
          get: (endpoint, query) async {
            order.add('snapshot');
            if (prepared) expect(endpoint, 'sessions/$owner/mutation-snapshot');
            return {
              'session_id': prepared ? owner : 'old',
              'exists': true,
              'runtime_revision': prepared ? 2 : 0,
              'runtime_generation': prepared ? 1 : 0,
            };
          },
          rpc: (method, params) async {
            expect(params['profile'], 'personal');
            if (method == 'session.resume') {
              order.add('prepare');
              expect(params['session_id'], 'old');
              expect(params['omit_messages'], true);
              prepared = true;
              return {
                ...canonicalSnapshotFields,
                'session_id': owner,
                'stored_session_id': 'old',
                'info': {'profile_name': 'personal'},
              };
            }
            order.add('move');
            if (!prepared) {
              throw JsonRpcError(
                method,
                'runtime_coordination_required',
                code: 4001,
                reason: 'runtime_coordination_required',
              );
            }
            expect(method, 'session.mutate');
            expect(params['session_id'], owner);
            expect(params['expected_revision'], 2);
            expect(params['expected_generation'], 1);
            expect(params['payload'], {'cwd': '/project'});
            return {
              'session_id': owner,
              'operation': 'workspace',
              'revision': 3,
              'execution_generation': 2,
              'cwd': '/project',
            };
          },
        );
        addTearDown(gateway.close);
        expect(
          (await gateway.moveSession(
            'old',
            '/project',
            canDispatch: () => true,
          ))['cwd'],
          '/project',
        );
        expect(order, ['prepare', 'snapshot', 'move']);
      },
    );
  }

  for (final refusal in ['departure', 'close', 'wrong-profile', 'conflict']) {
    test('workspace move refuses $refusal without replaying writes', () async {
      var active = true, preparations = 0, snapshots = 0, writes = 0;
      late ProfileGateway gateway;
      gateway = ProfileGateway(
        scope: WorkspaceScope(connectionId: 'move', profileName: 'personal'),
        discover: () async => const ProfileDiscovery(
          profiles: [HermesProfile(name: 'personal')],
          currentName: 'personal',
          activeName: 'personal',
        ),
        get: (endpoint, query) async {
          snapshots++;
          return {
            'session_id': 'old',
            'exists': true,
            'runtime_revision': 0,
            'runtime_generation': 0,
          };
        },
        rpc: (method, params) async {
          if (method == 'session.resume') {
            preparations++;
            if (refusal == 'departure') active = false;
            if (refusal == 'close') gateway.close();
            return {
              ...canonicalSnapshotFields,
              'session_id': 'old',
              'stored_session_id': 'old',
              'info': {
                'profile_name': refusal == 'wrong-profile'
                    ? 'work'
                    : 'personal',
              },
            };
          }
          writes++;
          throw JsonRpcError(
            method,
            'revision_conflict',
            code: 4001,
            reason: 'revision_conflict',
          );
        },
      );
      addTearDown(gateway.close);
      await expectLater(
        gateway.moveSession('old', '/project', canDispatch: () => active),
        throwsA(
          refusal == 'conflict'
              ? isA<JsonRpcError>()
              : refusal == 'wrong-profile'
              ? isA<FormatException>()
              : isA<DashboardRequestNotSentException>(),
        ),
      );
      expect(preparations, 1);
      expect(snapshots, refusal == 'conflict' ? 1 : 0);
      expect(writes, refusal == 'conflict' ? 1 : 0);
    });
  }

  ProfileGateway mutationGateway(ScopedGet read, ScopedOwnedPost patch) =>
      ProfileGateway(
        scope: WorkspaceScope(
          connectionId: 'mutation',
          profileName: 'personal',
        ),
        get: read,
        rpc: (_, _) async => throw StateError('No RPC expected'),
        discover: () async => const ProfileDiscovery(
          profiles: [HermesProfile(name: 'personal')],
          currentName: 'personal',
          activeName: 'personal',
        ),
        ownedPatch: patch,
      );

  for (final retirement in ['departure', 'close']) {
    test('session update $retirement during snapshot sends no PATCH', () async {
      final entered = Completer<void>(), release = Completer<void>();
      var active = true, writes = 0;
      final gateway = mutationGateway(
        (endpoint, query) async {
          expect(endpoint, 'sessions/chat/mutation-snapshot');
          expect(query['profile'], 'personal');
          entered.complete();
          await release.future;
          return mutationSnapshot();
        },
        (_, _, _, _) async {
          writes++;
          return {'ok': true};
        },
      );
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        gateway.close();
      });
      final pending = gateway.updateSession('chat', {
        'unread': false,
      }, canDispatch: () => active);
      final checked = expectLater(
        pending,
        throwsA(isA<DashboardRequestNotSentException>()),
      );
      await entered.future.timeout(const Duration(seconds: 5));
      if (retirement == 'departure') {
        active = false;
      } else {
        gateway.close();
      }
      release.complete();
      await checked;
      expect(writes, 0);
    });
  }

  for (final invalid in [
    {'session_id': 'other'},
    {'exists': false},
    {'runtime_revision': null},
    {'runtime_generation': -1},
  ]) {
    test(
      'session update rejects invalid snapshot $invalid before PATCH',
      () async {
        var writes = 0;
        final gateway = mutationGateway(
          (_, _) async => {...mutationSnapshot(), ...invalid},
          (_, _, _, _) async {
            writes++;
            return {'ok': true};
          },
        );
        addTearDown(gateway.close);
        await expectLater(
          gateway.updateSession('chat', {
            'unread': false,
          }, canDispatch: () => true),
          throwsFormatException,
        );
        expect(writes, 0);
      },
    );
  }

  test(
    'session update captures flags before snapshot and issues distinct identities',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final patches = <Map<String, dynamic>>[];
      final gateway = mutationGateway(
        (_, _) async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
          return mutationSnapshot();
        },
        (_, body, canDispatch, onDispatched) async {
          expect(canDispatch(), true);
          onDispatched();
          patches.add(body);
          return {'ok': true, 'unread': body['unread']};
        },
      );
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        gateway.close();
      });
      final flags = <String, dynamic>{'unread': false};
      final pending = gateway.updateSession(
        'chat',
        flags,
        canDispatch: () => true,
      );
      await entered.future.timeout(const Duration(seconds: 5));
      flags['unread'] = true;
      release.complete();
      await pending;
      await gateway.updateSession('chat', flags, canDispatch: () => true);
      expect(patches.map((body) => body['unread']), [false, true]);
      expect(patches.map((body) => body['request_id']).toSet(), hasLength(2));
    },
  );

  test(
    'session revision conflict is surfaced without replaying the update',
    () async {
      var writes = 0;
      final gateway = mutationGateway((_, _) async => mutationSnapshot(), (
        _,
        _,
        _,
        _,
      ) async {
        writes++;
        throw const DashboardHttpException(409, 'sessions/chat');
      });
      addTearDown(gateway.close);
      await expectLater(
        gateway.updateSession('chat', {
          'unread': false,
        }, canDispatch: () => true),
        throwsA(
          isA<DashboardHttpException>().having(
            (e) => e.statusCode,
            'status',
            409,
          ),
        ),
      );
      expect(writes, 1);
    },
  );

  test(
    'retired captured browser PATCH held at authentication sends zero writes',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final entered = Completer<void>(), release = Completer<void>();
      var writes = 0;
      final subscription = server.listen((request) async {
        Object result;
        if (request.uri.path == '/auth/password-login') {
          await request.drain<void>();
          entered.complete();
          await release.future;
          request.response.headers.add(
            'set-cookie',
            'hermes_session_at=fixture; Path=/',
          );
          result = <String, Object>{};
        } else if (request.method == 'PATCH') {
          writes++;
          result = {'ok': true};
        } else {
          result = switch (request.uri.path) {
            '/api/profiles' => {
              'profiles': [
                {'name': 'personal'},
              ],
            },
            '/api/profiles/active' => {
              'current': 'personal',
              'active': 'personal',
            },
            _ => throw StateError(
              'Unexpected fixture route: ${request.uri.path}',
            ),
          };
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(result));
        await request.response.close();
      });
      final connection = SavedConnection(
        id: 'held',
        label: 'Fixture',
        host: '127.0.0.1',
        port: server.port,
        dashboardPortOverride: server.port,
        apiKey: '',
        dashboardUsername: 'fixture',
        dashboardPassword: 'fixture',
      );
      final gateway = ProfileGateway.forConnection(
        ConnectionAccess(connection: connection, dashboardOAuth: null),
        WorkspaceScope(
          connectionId: 'held',
          profileName: 'personal',
          connectionIdentity: 'held-auth',
        ),
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        gateway.close();
        await subscription.cancel();
        await server.close(force: true);
      });
      var active = true;
      final pending = gateway.updateSession('chat', {
        'unread': false,
      }, canDispatch: () => active);
      final checked = expectLater(
        pending,
        throwsA(isA<DashboardRequestNotSentException>()),
      );
      await entered.future.timeout(const Duration(seconds: 5));
      active = false;
      release.complete();
      await checked;
      expect(writes, 0);
    },
  );

  test(
    'profile browsing reuses one sign-in without closing the live socket',
    () async {
      final prematureReads = <Map<String, dynamic>>[];
      final previousPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null && message.startsWith('[WingConnection] ')) {
          final event =
              jsonDecode(message.substring('[WingConnection] '.length))
                  as Map<String, dynamic>;
          if (event['event'] == 'gateway.rpc_failed' &&
              event['rpc_method'] == 'session.list') {
            prematureReads.add(event);
          }
        }
        previousPrint(message, wrapWidth: wrapWidth);
      };
      addTearDown(() => debugPrint = previousPrint);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final requestedProfiles = <String>{};
      var logins = 0;
      final subscription = server.listen((request) async {
        if (request.uri.path == '/api/ws') {
          final socket = await WebSocketTransformer.upgrade(request);
          sockets.add(socket);
          gatewayApplicationRequests(socket).listen((raw) {
            final rpc = jsonDecode(raw as String) as Map;
            final params = rpc['params'] as Map;
            requestedProfiles.add(params['profile'] as String);
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': rpc['id'],
                'result':
                    const {
                      'session.active_list',
                      'session.list',
                    }.contains(rpc['method'])
                    ? {'sessions': []}
                    : {'projects': []},
              }),
            );
          });
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'gateway.ready',
                'payload': {'session_authority': true},
              },
            }),
          );
          return;
        }
        Object result;
        if (request.uri.path == '/auth/password-login') {
          logins++;
          await request.drain<void>();
          if (logins > 1) {
            request.response.statusCode = HttpStatus.tooManyRequests;
            await request.response.close();
            return;
          }
          request.response.headers.add(
            'set-cookie',
            'hermes_session_at=fixture; Path=/',
          );
          result = <String, Object>{};
        } else {
          expect(request.headers.value('cookie'), 'hermes_session_at=fixture');
          result = switch (request.uri.path) {
            '/api/profiles' => {
              'profiles': [
                {'name': 'personal'},
                {'name': 'work'},
              ],
            },
            '/api/profiles/active' => {
              'current': 'personal',
              'active': 'personal',
            },
            '/api/auth/ws-ticket' => {'ticket': 'fixture-ticket'},
            '/api/sessions' => {
              'sessions': [],
              'offset': int.parse(request.uri.queryParameters['offset']!),
              'limit': int.parse(request.uri.queryParameters['limit']!),
              'total': 0,
            },
            _ => throw StateError('Unexpected fixture route'),
          };
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(result));
        await request.response.close();
      });
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'test',
            label: 'Fixture',
            host: '127.0.0.1',
            port: server.port,
            dashboardPortOverride: server.port,
            apiKey: '',
            dashboardUsername: 'fixture',
            dashboardPassword: 'fixture',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'fixture',
        preferences: preferences,
        appPreferences: appPreferences,
      );
      final browser = ChatBrowserData(controller);
      addTearDown(() async {
        browser.dispose();
        controller.dispose();
        for (final socket in sockets) {
          await socket.close();
        }
        await subscription.cancel();
        await server.close(force: true);
      });
      await controller.initialize();
      expect(controller.initialized, isTrue);
      final owner = controller.current;
      await browser.chooseVisibility(SessionVisibility.all);
      expect(
        prematureReads,
        isEmpty,
        reason: 'A healthy server must not trigger unopened-socket failures',
      );
      expect(
        controller.browserResource('work').loaded,
        isFalse,
        reason: 'Read-only browsing must not start conversation recovery',
      );
      expect(controller.browserResource('work').reconnectScheduled, isFalse);
      for (var i = 0; i < 5; i++) {
        await browser.refresh(archivedOnly: false);
        expect(
          browser.state.profiles.values.where(
            (profile) => profile.error != null,
          ),
          isEmpty,
        );
      }
      expect(
        browser.state.profiles.values.where((profile) => profile.error != null),
        isEmpty,
      );
      expect(requestedProfiles, containsAll(['personal', 'work']));
      expect(controller.current, same(owner));
      expect(await owner!.gateway.call('session.active_list'), {
        'sessions': [],
      });
      expect(controller.connectionStatus.description, 'Connected');
      expect(
        logins,
        1,
        reason: 'profile readers share the saved connection authentication',
      );
    },
  );
}

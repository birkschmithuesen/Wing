import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/mcp_setup.dart';
import 'package:wing/core/services/profile_connectors_session.dart';
import 'support/administration_fixture.dart';

Map<String, dynamic> connector({bool enabled = false}) => {
  'name': 'docs',
  'transport': 'http',
  'auth': 'oauth',
  'enabled': enabled,
  'source': 'config',
  'plugin': null,
};

void main() {
  test(
    'enable ACK survives malformed readback and never authorizes duplicate delivery',
    () async {
      final fixture = AdministrationFixture();
      final session = ProfileConnectorsSession(
        fixture.server.profile('personal'),
      );
      addTearDown(session.dispose);
      var enabled = false, malformed = false, writes = 0;
      fixture.override = (method, path, query, body) async {
        if (path == 'profiles') {
          return {
            'profiles': [
              {'name': 'personal'},
            ],
          };
        }
        if (path == 'profiles/active') return {'current': 'personal'};
        if (method == 'GET' && path == 'mcp/servers') {
          return {
            'servers': malformed
                ? [
                    {'name': 'docs'},
                  ]
                : [connector(enabled: enabled)],
          };
        }
        if (method == 'PUT') {
          expect(path, 'mcp/servers/docs/enabled');
          expect(query, {'profile': 'personal'});
          expect(body, {'enabled': true, 'profile': 'personal'});
          writes++;
          enabled = true;
          malformed = true;
          return {'ok': true, 'name': 'docs', 'enabled': true};
        }
        throw StateError('Unexpected $method $path');
      };
      await session.refresh();
      final before = session.state;
      await session.toggle(before.connectors.single, true);
      expect(writes, 1);
      expect(enabled, isTrue);
      expect(session.state.notice, startsWith('Saved.'));
      expect(session.state.verified, isFalse);
      expect(
        session.state.error,
        contains('current connector list is unavailable'),
      );
      await session.toggle(before.connectors.single, true);
      expect(writes, 1);
      expect(() => before.connectors.clear(), throwsUnsupportedError);
      malformed = false;
      await session.refresh();
      expect(session.state.verified, isTrue);
      expect(session.state.connectors.single.enabled, isTrue);
      expect(before.connectors.single.enabled, isFalse);
    },
  );

  test(
    'retired detail cannot remove after held physical dispatch admission',
    () async {
      final fixture = AdministrationFixture();
      final session = ProfileConnectorsSession(
        fixture.server.profile('personal'),
      );
      addTearDown(session.dispose);
      fixture.override = (method, path, query, body) async => switch (path) {
        'profiles' => {
          'profiles': [
            {'name': 'personal'},
          ],
        },
        'profiles/active' => {'current': 'personal'},
        _ => {
          'servers': [connector()],
        },
      };
      final admitted = Completer<void>(), release = Completer<void>();
      var deliveries = 0;
      fixture.mutationOverride =
          (method, path, query, body, canDispatch, onDispatched) async {
            admitted.complete();
            await release.future;
            if (!canDispatch()) {
              throw StateError('Retired before physical delivery');
            }
            onDispatched();
            deliveries++;
            return {'ok': true};
          };
      await session.refresh();
      final route = session.openDetail('docs', signInOnOpen: false);
      final pending = session.remove(route, () async => true);
      await admitted.future;
      route.dispose();
      release.complete();
      expect(await pending, isFalse);
      expect(deliveries, 0);
      expect(fixture.requests.where((request) => request.$1 != 'GET'), isEmpty);
      await session.refresh();
      expect(session.state.verified, isTrue);
      expect(session.state.connectors.single.name, 'docs');
    },
  );

  test(
    'setup retirement after held membership read keeps parent usable and sends no credentials',
    () async {
      final fixture = AdministrationFixture();
      final parent = ProfileConnectorsSession(
        fixture.server.profile('personal'),
      );
      addTearDown(parent.dispose);
      final admitted = Completer<void>(), release = Completer<void>();
      var hold = false;
      fixture.override = (method, path, query, body) async {
        if (path == 'profiles') {
          if (hold) {
            admitted.complete();
            await release.future;
          }
          return {
            'profiles': [
              {'name': 'personal'},
            ],
          };
        }
        if (path == 'profiles/active') return {'current': 'personal'};
        if (path == 'mcp/servers') return {'servers': <Object>[]};
        throw StateError('Unexpected $method $path');
      };
      await parent.refresh();
      final child = parent.createSetup();
      child.edit(
        McpSetupInput(
          name: 'docs',
          address: 'https://example.test/mcp',
          clientId: 'id',
          clientSecret: 'fixture-secret',
        ),
      );
      hold = true;
      final pending = child.save();
      await admitted.future;
      child.dispose();
      release.complete();
      expect(await pending, isNull);
      expect(fixture.requests.where((request) => request.$1 != 'GET'), isEmpty);
      expect(fixture.rpcRequests, [('personal', 'mcp.servers.status')]);
      hold = false;
      await parent.refresh();
      expect(parent.state.canMutate, isTrue);
    },
  );
}

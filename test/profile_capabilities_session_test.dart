import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_capabilities.dart';
import 'package:wing/core/services/profile_capabilities_session.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profiles_repository.dart';

const _profiles = ProfileDiscovery(
  profiles: [HermesProfile(name: 'work')],
  currentName: 'work',
  activeName: 'default',
);

ProfileGateway _gateway({
  required ScopedGet get,
  required ScopedOwnedPost put,
  Future<ProfileDiscovery> Function()? discover,
}) => ProfileGateway(
  scope: WorkspaceScope(connectionId: 'server', profileName: 'work'),
  get: get,
  rpc: (_, _) async => throw StateError('No capability RPC'),
  ownedPut: put,
  discover: discover ?? () async => _profiles,
);

Map<String, dynamic> _tool(bool enabled) => {
  'name': 'browser',
  'label': 'Browser',
  'description': 'Browse pages',
  'platform': 'cli',
  'platform_label': 'CLI',
  'enabled': enabled,
  'configured': false,
  'tools': ['browse'],
};

void main() {
  test(
    'observations are detached and malformed refresh retains confirmed history',
    () async {
      final row = _tool(false);
      var malformed = false;
      final session = ProfileCapabilitiesSession(
        _gateway(
          get: (_, _) async => {
            'data': malformed
                ? [
                    <String, dynamic>{'name': 7},
                  ]
                : [row],
          },
          put: (_, _, _, _) async => throw StateError('No write'),
        ),
      );
      addTearDown(session.dispose);
      await session.load(ProfileCapabilityKind.tools);
      final original = session.state;
      row['enabled'] = true;
      (row['tools'] as List).add('changed');
      expect(original.rows.single.enabled, isFalse);
      expect(original.rows.single.tools, ['browse']);
      expect(() => original.rows.clear(), throwsUnsupportedError);
      expect(() => original.rows.single.tools.clear(), throwsUnsupportedError);
      malformed = true;
      await session.load(ProfileCapabilityKind.tools);
      expect(session.state.rows.single, same(original.rows.single));
      expect(session.state.verified, isFalse);
      expect(session.state.canToggle, isFalse);
      expect(session.state.error, contains('Could not load tools'));
    },
  );

  test(
    'retirement during fresh membership sends no mutation and borrows gateway',
    () async {
      final entered = Completer<void>();
      final release = Completer<ProfileDiscovery>();
      var dispatches = 0;
      final gateway = _gateway(
        get: (_, _) async => {
          'data': [_tool(false)],
        },
        discover: () {
          entered.complete();
          return release.future;
        },
        put: (_, _, _, _) async {
          dispatches++;
          return {};
        },
      );
      final session = ProfileCapabilitiesSession(gateway);
      await session.load(ProfileCapabilityKind.tools);
      final saving = session.toggle(
        ProfileCapabilityKind.tools,
        'browser',
        true,
        confirm: (_) async => true,
      );
      await entered.future;
      final captured = session.state;
      session.dispose();
      release.complete(_profiles);
      await saving;
      expect(dispatches, 0);
      expect(session.state, same(captured));
      expect((await gateway.read('tools/toolsets'))['data'], hasLength(1));
    },
  );

  test(
    'owned PUT rechecks route authority after held adapter authentication',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var dispatches = 0;
      final session = ProfileCapabilitiesSession(
        _gateway(
          get: (_, _) async => {
            'data': [_tool(false)],
          },
          put: (path, body, canDispatch, onDispatched) async {
            expect(path, 'tools/toolsets/browser?profile=work');
            expect(body, {'enabled': true});
            entered.complete();
            await release.future;
            if (!canDispatch()) {
              throw StateError('Retired before physical dispatch');
            }
            onDispatched();
            dispatches++;
            return {
              'ok': true,
              'name': 'browser',
              'platform': 'cli',
              'enabled': true,
              'post_setup_started': null,
            };
          },
        ),
      );
      await session.load(ProfileCapabilityKind.tools);
      final saving = session.toggle(
        ProfileCapabilityKind.tools,
        'browser',
        true,
        confirm: (_) async => true,
      );
      await entered.future;
      session.dispose();
      release.complete();
      await saving;
      expect(dispatches, 0);
    },
  );

  test(
    'confirmed toggle survives follow-up read failure without replay',
    () async {
      var reads = 0;
      var writes = 0;
      final session = ProfileCapabilitiesSession(
        _gateway(
          get: (_, _) async {
            reads++;
            if (reads > 1) throw StateError('Read offline');
            return {
              'data': [_tool(false)],
            };
          },
          put: (_, _, canDispatch, onDispatched) async {
            expect(canDispatch(), isTrue);
            onDispatched();
            writes++;
            return {
              'ok': true,
              'name': 'browser',
              'platform': 'cli',
              'enabled': true,
              'post_setup_started': 'install-browser',
            };
          },
        ),
      );
      addTearDown(session.dispose);
      await session.load(ProfileCapabilityKind.tools);
      final before = session.state;
      await session.toggle(
        ProfileCapabilityKind.tools,
        'browser',
        true,
        confirm: (_) async => true,
      );
      expect(writes, 1);
      expect(before.rows.single.enabled, isFalse);
      expect(session.state.rows.single.enabled, isTrue);
      expect(
        session.state.notice,
        contains('Saved. Hermes started server setup'),
      );
      expect(session.state.error, contains('Could not load tools'));
      expect(session.state.canToggle, isFalse);
      await session.toggle(
        ProfileCapabilityKind.tools,
        'browser',
        false,
        confirm: (_) async => true,
      );
      expect(writes, 1);
    },
  );

  test(
    'contradictory acknowledgement requires a read before another command',
    () async {
      var writes = 0;
      var enabled = false;
      final session = ProfileCapabilitiesSession(
        _gateway(
          get: (_, _) async => {
            'data': [_tool(enabled)],
          },
          put: (_, _, _, onDispatched) async {
            onDispatched();
            writes++;
            enabled = true;
            return {
              'ok': true,
              'name': 'different',
              'platform': 'cli',
              'enabled': true,
              'post_setup_started': null,
            };
          },
        ),
      );
      addTearDown(session.dispose);
      await session.load(ProfileCapabilityKind.tools);
      await session.toggle(
        ProfileCapabilityKind.tools,
        'browser',
        true,
        confirm: (_) async => true,
      );
      expect(session.state.rows.single.enabled, isFalse);
      expect(session.state.notice, isNull);
      expect(session.state.error, contains('could not be confirmed'));
      await session.toggle(
        ProfileCapabilityKind.tools,
        'browser',
        true,
        confirm: (_) async => true,
      );
      expect(writes, 1);
      await session.load(ProfileCapabilityKind.tools);
      expect(session.state.rows.single.enabled, isTrue);
      expect(session.state.canToggle, isTrue);
    },
  );

  test(
    'synchronous listener retirement revokes command before confirmation',
    () async {
      var confirms = 0;
      var writes = 0;
      final session = ProfileCapabilitiesSession(
        _gateway(
          get: (_, _) async => {
            'data': [_tool(false)],
          },
          put: (_, _, _, _) async {
            writes++;
            return {};
          },
        ),
      );
      await session.load(ProfileCapabilityKind.tools);
      session.addListener(() {
        if (session.state.busy) session.dispose();
      });
      await session.toggle(
        ProfileCapabilityKind.tools,
        'browser',
        true,
        confirm: (_) async {
          confirms++;
          return true;
        },
      );
      expect(confirms, 0);
      expect(writes, 0);
    },
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/session_visibility.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/services/wing_session_source.dart';

Map<String, dynamic> _ready(Map<String, dynamic> payload) => {
  'jsonrpc': '2.0',
  'method': 'event',
  'params': {'type': 'gateway.ready', 'payload': payload},
};

ProfileGateway _gateway(List<(String, Map<String, dynamic>)> calls) {
  final scope = WorkspaceScope(connectionId: 'host', profileName: 'a');
  return ProfileGateway(
    scope: scope,
    discover: () async => ProfileDiscovery(
      profiles: [HermesProfile(name: 'a')],
      currentName: 'a',
      activeName: 'a',
    ),
    get: (path, query) async => {},
    rpc: (method, params) async {
      calls.add((method, params));
      return {
        'session_id': 'runtime',
        'stored_session_id': 'stored',
        'info': {'profile_name': 'a'},
      };
    },
  );
}

void main() {
  group('gatewayAdvertisesWingSource', () {
    test('true only for a session_sources list containing wing', () {
      expect(
        gatewayAdvertisesWingSource(
          _ready({
            'session_sources': ['wing'],
          }),
        ),
        isTrue,
      );
      expect(gatewayAdvertisesWingSource(_ready({})), isFalse);
      expect(
        gatewayAdvertisesWingSource(_ready({'session_sources': 'wing'})),
        isFalse,
      );
      expect(
        gatewayAdvertisesWingSource(
          _ready({
            'session_sources': ['tui'],
          }),
        ),
        isFalse,
      );
      expect(gatewayAdvertisesWingSource({'method': 'event'}), isFalse);
    });
  });

  group('ProfileGateway source', () {
    test('stock gateway: create says desktop, resume sends no source', () async {
      final calls = <(String, Map<String, dynamic>)>[];
      final gateway = _gateway(calls);
      await gateway.createSession();
      await gateway.resume('stored');
      expect(calls[0].$1, 'session.create');
      expect(calls[0].$2['source'], desktopSessionSource);
      expect(calls[1].$1, 'session.resume');
      expect(calls[1].$2.containsKey('source'), isFalse);
      expect(gateway.sessionSource, desktopSessionSource);
    });

    test('advertising gateway: create and resume say wing', () async {
      final calls = <(String, Map<String, dynamic>)>[];
      final gateway = _gateway(calls)..wingSourceAdvertised = true;
      await gateway.createSession();
      await gateway.resume('stored');
      expect(calls[0].$2['source'], wingSessionSource);
      expect(calls[1].$2['source'], wingSessionSource);
      expect(gateway.sessionSource, wingSessionSource);
    });
  });

  test('wing sessions stay in the chat list', () {
    expect(SessionVisibility.chats.includes(wingSessionSource), isTrue);
    expect(SessionVisibility.chats.includes(desktopSessionSource), isTrue);
  });
}

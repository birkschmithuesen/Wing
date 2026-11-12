import 'package:wing/core/services/connection_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';

/// Opt-in writes only to the existing disposable android-qa-a profile. Every
/// changed value is restored, including when an assertion fails. No model call.
void main() {
  const port = int.fromEnvironment('HERMES_TEST_PORT');
  test(
    'existing Hermes administration writes, readback and restoration',
    () async {
      final connection = SavedConnection(
        id: 'local-admin-qa',
        label: 'Local QA',
        host: '127.0.0.1',
        port: port,
        dashboardPortOverride: port,
        apiKey: '',
      );
      final gateway = ProfileGateway.forConnection(
        ConnectionAccess(connection: connection, dashboardOAuth: null),
        WorkspaceScope(
          connectionId: connection.id,
          profileName: 'android-qa-a',
        ),
      );
      addTearDown(gateway.close);
      await gateway.requireProfile();
      Future<List<Map<String, dynamic>>> rows(String endpoint) async =>
          ((await gateway.read(endpoint))['data'] as List)
              .cast<Map<String, dynamic>>();

      final skill = (await rows(
        'skills',
      )).singleWhere((row) => row['name'] == 'android-mobile-slash-qa');
      final skillName = skill['name'] as String;
      final skillEnabled = skill['enabled'] as bool;
      final content = await gateway.read('skills/content', {'name': skillName});
      expect(content['name'], skillName);
      expect(content['content'], isA<String>());
      try {
        final ack = await gateway.putOwned(
          'skills/toggle',
          {'name': skillName, 'enabled': !skillEnabled},
          canDispatch: () => true,
          onDispatched: () {},
        );
        expect(ack['ok'], true);
        expect(
          (await rows(
            'skills',
          )).singleWhere((row) => row['name'] == skillName)['enabled'],
          !skillEnabled,
        );
      } finally {
        await gateway.putOwned(
          'skills/toggle',
          {'name': skillName, 'enabled': skillEnabled},
          canDispatch: () => true,
          onDispatched: () {},
        );
        expect(
          (await rows(
            'skills',
          )).singleWhere((row) => row['name'] == skillName)['enabled'],
          skillEnabled,
        );
      }

      // Only configured tools: restoring an enabled tool must not start setup.
      final tool = (await rows('tools/toolsets')).firstWhere(
        (row) => row['configured'] == true && row['enabled'] == true,
      );
      final toolName = tool['name'] as String;
      final endpoint = 'tools/toolsets/${Uri.encodeComponent(toolName)}';
      try {
        final ack = await gateway.putOwned(
          endpoint,
          {'enabled': false},
          canDispatch: () => true,
          onDispatched: () {},
        );
        expect(ack['ok'], true);
        expect(
          (await rows(
            'tools/toolsets',
          )).singleWhere((row) => row['name'] == toolName)['enabled'],
          false,
        );
      } finally {
        await gateway.putOwned(
          endpoint,
          {'enabled': true},
          canDispatch: () => true,
          onDispatched: () {},
        );
        expect(
          (await rows(
            'tools/toolsets',
          )).singleWhere((row) => row['name'] == toolName)['enabled'],
          true,
        );
      }

      final original = await gateway.read('model/info');
      final originalModel = original['model'] as String;
      final originalProvider = original['provider'] as String;
      // Re-save the known configured route; no provider change or paid model run.
      final ack = await gateway.post('model/set', {
        'scope': 'main',
        'provider': originalProvider,
        'model': originalModel,
      });
      expect(ack['ok'], true);
      final reread = await gateway.read('model/info');
      expect(reread['model'], originalModel);
      expect(reread['provider'], originalProvider);
    },
    skip: port == 0,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

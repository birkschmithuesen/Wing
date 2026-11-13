import 'package:wing/core/services/connection_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/slash_command.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';

/// Requires the disposable android-mobile-slash-qa skill in both QA profiles.
/// Expands skill text only; never sends a prompt or runs a model.
void main() {
  const port = int.fromEnvironment('HERMES_TEST_PORT');
  test(
    'live command catalog and expansion respect the session profile',
    () async {
      final connection = SavedConnection(
        id: 'slash-contract',
        label: 'Prestige QA',
        host: '127.0.0.1',
        port: port,
        dashboardPortOverride: port,
        apiKey: '',
      );
      for (final profile in ['android-qa-a', 'android-qa-b']) {
        final gateway = ProfileGateway.forConnection(
          ConnectionAccess(connection: connection, dashboardOAuth: null),
          WorkspaceScope(connectionId: connection.id, profileName: profile),
        );
        addTearDown(gateway.close);
        await gateway.connect();
        final session = await gateway.createSession(
          cwdExplicit: false,
          title: 'Android slash contract check',
          canDispatch: () => true,
        );
        final id = session['session_id'] as String;
        final catalog = SlashCatalog.fromJson(
          await gateway.call('commands.catalog', {'session_id': id}),
        );
        final matches = catalog.commands
            .where((c) => c.text == '/android-mobile-slash-qa')
            .toList();
        expect(
          matches,
          hasLength(1),
          reason:
              '$profile must expose its QA skill. Catalog has ${catalog.commands.length} entries. ${catalog.warning}',
        );
        final skill = matches.single;
        expect(
          skill.description,
          contains(profile),
          reason: 'Catalog must use $profile',
        );
        final completions = await gateway.completeSlash(
          sessionId: id,
          text: '/android-mobile-slash',
        );
        final completion = (completions['items'] as List)
            .where(
              (row) =>
                  row['text'].toString().replaceFirst('/', '') ==
                  'android-mobile-slash-qa',
            )
            .single;
        expect(
          completion['meta'],
          contains(profile),
          reason: 'Completion must use $profile',
        );
        final expanded = await gateway.call('command.dispatch', {
          'session_id': id,
          'name': 'android-mobile-slash-qa',
          'arg': 'Contract check',
        });
        expect(expanded['type'], 'skill');
        expect(
          expanded['message'],
          contains('ANDROID_SLASH_$profile'),
          reason: 'Skill expansion must use $profile',
        );
      }
    },
    skip: port == 0,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

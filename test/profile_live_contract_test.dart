import 'support/canonical_gateway_fixture.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profiles_repository.dart';

/// Opt-in, no model calls. Uses existing disposable profiles on the unmodified
/// local Desktop-managed server. Authentication is fetched, never logged/saved.
void main() {
  // Canonical gateway/session_policy.py CREATE_FIELDS at e5ea5fd9, plus
  // profile routing and title/hidden consumed by session_controls.create.
  const createFields = {
    'profile',
    'title',
    'hidden',
    'request_id',
    'source',
    'cwd',
    'model',
    'toolsets',
    'provider',
    'base_url',
    'reasoning',
    'max_turns',
    'ignore_rules',
    'api_key',
    'editor',
    'yolo',
    'safe_mode',
    'ignore_user_config',
    'skills',
    'checkpoints',
    'accept_hooks',
    'pass_session_id',
    'follow_profile_config',
    'service_tier',
    'cwd_explicit',
    'run_budget',
    'verbose',
    'row_cwd',
    'client_env',
  };
  for (final project in [false, true]) {
    test(
      'strict stock session.create accepts ${project ? 'project' : 'inherited'} cwd',
      () async {
        final scope = WorkspaceScope(
          connectionId: 'strict-stock-contract',
          profileName: 'default',
        );
        var creates = 0;
        final gateway = ProfileGateway(
          scope: scope,
          discover: () async => const ProfileDiscovery(
            profiles: [HermesProfile(name: 'default', isDefault: true)],
            currentName: 'default',
            activeName: 'default',
          ),
          get: (_, _) async => throw StateError('Unexpected REST read'),
          rpc: (method, params) async {
            expect(method, 'session.create');
            final unknown = params.keys.toSet().difference(createFields);
            if (unknown.isNotEmpty) {
              throw FormatException('Stock rejects unknown fields: $unknown');
            }
            creates++;
            expect(params['profile'], 'default');
            expect(params['source'], 'gui');
            expect(
              params['request_id'],
              isA<String>().having(
                (value) => value.isNotEmpty,
                'nonempty creation identity',
                isTrue,
              ),
            );
            expect(params.containsKey('cwd'), project);
            expect(params['cwd_explicit'], project);
            return {
              ...canonicalSnapshotFields,
              'session_id': 'owned-runtime',
              'stored_session_id': 'owned-stored',
              'messages': <Map<String, dynamic>>[],
              'info': {
                'profile_name': 'default',
                'cwd': params['cwd_explicit'] == true
                    ? params['cwd']
                    : '/profile-default',
              },
            };
          },
        );
        addTearDown(gateway.close);
        final response = await gateway.createSession(
          cwdExplicit: project,
          cwd: project ? '/selected-project' : null,
          title: 'Strict stock contract QA',
          canDispatch: () => true,
        );
        expect(creates, 1);
        expect(response['stored_session_id'], 'owned-stored');
        expect(
          response['info']['cwd'],
          project ? '/selected-project' : '/profile-default',
        );
      },
    );
  }

  const port = int.fromEnvironment('HERMES_TEST_PORT');
  test(
    'stock local Hermes profile REST and RPC contract',
    () async {
      final connection = SavedConnection(
        id: 'local-qa',
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
        expect((await gateway.discover()).named(profile), isNotNull);
        await gateway.connect();
        final sessions = await gateway.sessions();
        expect(sessions.rows.every((s) => s['profile'] == profile), isTrue);
        await gateway.projects();
        final session = await gateway.createSession(
          cwdExplicit: false,
          title: 'Android QA draft',
          canDispatch: () => true,
        );
        expect(session['info']['profile_name'], profile);
        expect(session['stored_session_id'], isA<String>());
        await gateway
            .connect(); // Reusing a healthy socket must not detach drafts.
        final attachment = await gateway.call('file.attach', {
          'session_id': session['session_id'],
          'name': 'android-qa.txt',
          'data_url': 'data:text/plain;base64,SGVybWVzIEFuZHJvaWQgUUE=',
        });
        expect(attachment['ref_text'], isA<String>());
      }
    },
    skip: port == 0,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

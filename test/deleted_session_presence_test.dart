import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wing/core/models/deleted_draft_cleanup.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profiles_repository.dart';

const _discovery = ProfileDiscovery(
  profiles: [HermesProfile(name: 'work')],
  currentName: 'work',
  activeName: 'work',
);
const _missingProfile = ProfileDiscovery(
  profiles: [],
  currentName: null,
  activeName: null,
);

void main() {
  for (final example in [
    ('sessions/exact', 404, '{"detail":"Session not found"}', true),
    ('sessions/exact', 404, '{"detail":"Profile work does not exist."}', false),
    ('sessions/exact', 404, '{"detail":"Not Found"}', false),
    (
      'sessions/exact',
      404,
      '{"detail":"Session not found","other":true}',
      false,
    ),
    ('sessions/exact', 404, '{"detail":["Session not found"]}', false),
    ('sessions/exact', 404, 'Session not found', false),
    ('sessions/exact', 503, '{"detail":"Session not found"}', false),
    ('sessions/exact/history', 404, '{"detail":"Session not found"}', false),
    ('profiles', 404, '{"detail":"Session not found"}', false),
  ]) {
    test('only precise session-detail absence is typed: $example', () async {
      final (endpoint, status, body, absent) = example;
      final client = DashboardClient(
        host: 'fixture.invalid',
        httpClient: MockClient((request) async {
          if (request.url.path == '/') {
            return http.Response(
              'window.__HERMES_SESSION_TOKEN__="fixture-token";',
              200,
            );
          }
          return http.Response(body, status);
        }),
      );
      addTearDown(client.close);
      await expectLater(
        client.apiGet(endpoint),
        throwsA(
          isA<DashboardHttpException>().having(
            (failure) => failure is DashboardSessionNotFound,
            'precise absence',
            absent,
          ),
        ),
      );
    });
  }

  ProfileGateway gateway({
    required ScopedGet get,
    Future<ProfileDiscovery> Function()? discover,
  }) => ProfileGateway(
    scope: WorkspaceScope(connectionId: 'fixture', profileName: 'work'),
    discover: discover ?? () async => _discovery,
    get: get,
    rpc: (_, _) async => throw StateError('No mutation is allowed'),
  );

  for (final example in [
    ({'id': 'exact', 'profile': 'work'}, SessionPresence.present),
    (
      {'id': 'exact', 'profile': 'work', 'archived': true},
      SessionPresence.present,
    ),
    ({'id': 'exact-longer', 'profile': 'work'}, SessionPresence.unavailable),
    ({'id': 'exact', 'profile': 'default'}, SessionPresence.unavailable),
    ({'id': 'exact'}, SessionPresence.unavailable),
    (
      {
        'session': {'id': 'exact', 'profile': 'work'},
      },
      SessionPresence.unavailable,
    ),
  ]) {
    test(
      'presence requires exact direct row and canonical owner: $example',
      () async {
        final (row, expected) = example;
        final reader = gateway(
          get: (endpoint, query) async {
            expect(endpoint, 'sessions/exact');
            expect(query, {'profile': 'work'});
            return row;
          },
        );
        expect(await reader.verifyDeletedSession('exact'), expected);
      },
    );
  }

  for (final failure in <Object>[
    const DashboardHttpException(404, 'sessions/exact'),
    const DashboardHttpException(503, 'sessions/exact'),
    const DashboardHttpException(401, 'sessions/exact'),
    const DashboardSessionNotFound('sessions/another'),
    const FormatException('Malformed row'),
    TimeoutException('Unavailable'),
  ]) {
    test('read failure cannot authorize cleanup: $failure', () async {
      final reader = gateway(get: (_, _) async => throw failure);
      expect(
        await reader.verifyDeletedSession('exact'),
        SessionPresence.unavailable,
      );
    });
  }

  test(
    'precise absence also requires fresh membership after the read',
    () async {
      var discoveries = 0;
      final reader = gateway(
        discover: () async => ++discoveries == 1 ? _discovery : _missingProfile,
        get: (_, _) async =>
            throw const DashboardSessionNotFound('sessions/exact'),
      );
      expect(
        await reader.verifyDeletedSession('exact'),
        SessionPresence.unavailable,
      );
      expect(discoveries, 2);
    },
  );

  test(
    'precise absence with retained profile is read-only and confirmed',
    () async {
      final reader = gateway(
        get: (_, _) async =>
            throw const DashboardSessionNotFound('sessions/exact'),
      );
      expect(
        await reader.verifyDeletedSession('exact'),
        SessionPresence.absent,
      );
    },
  );

  test('missing profile does not enter the session request', () async {
    var reads = 0;
    final reader = gateway(
      discover: () async => _missingProfile,
      get: (_, _) async {
        reads++;
        return {};
      },
    );
    expect(
      await reader.verifyDeletedSession('exact'),
      SessionPresence.unavailable,
    );
    expect(reads, 0);
  });
}

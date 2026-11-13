import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profiles_repository.dart';

void main() {
  Map<String, dynamic> profilesPayload() => {
    'profiles': [
      {
        'name': 'default',
        'display_name': '',
        'is_default': true,
        'provider': 'openai-codex',
        'model': 'gpt-5.6-luna',
      },
      {
        'name': 'client-work',
        'display_name': 'Client Work',
        'is_default': false,
      },
    ],
  };

  test(
    'discovers profiles and honors the running server profile first',
    () async {
      final requested = <String>[];
      final repository = ProfilesRepository((endpoint) async {
        requested.add(endpoint);
        if (endpoint == 'profiles') return profilesPayload();
        return {'current': 'client-work', 'active': 'default'};
      });

      final result = await repository.discover();

      expect(requested, ['profiles', 'profiles/active']);
      expect(result.serverPreferred.name, 'client-work');
      expect(result.profiles.last.label, 'Client Work');
    },
  );

  test(
    'preserves authentication failures without making a fallback request',
    () async {
      final requested = <String>[];
      final repository = ProfilesRepository((endpoint) async {
        requested.add(endpoint);
        throw const DashboardHttpException(401, 'profiles');
      });

      await expectLater(
        repository.discover(),
        throwsA(
          isA<DashboardHttpException>().having(
            (error) => error.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
      expect(requested, ['profiles']);
    },
  );

  test(
    'preserves an absent modern endpoint without making a fallback request',
    () async {
      final requested = <String>[];
      final repository = ProfilesRepository((endpoint) async {
        requested.add(endpoint);
        throw const DashboardHttpException(404, 'profiles');
      });

      await expectLater(
        repository.discover(),
        throwsA(
          isA<DashboardHttpException>().having(
            (error) => error.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
      expect(requested, ['profiles']);
    },
  );

  test('fails closed on duplicate profile identities', () async {
    final payload = profilesPayload();
    (payload['profiles'] as List).add({
      'name': 'default',
      'display_name': 'Duplicate',
    });
    final repository = ProfilesRepository((endpoint) async {
      if (endpoint == 'profiles') return payload;
      return {'current': 'default', 'active': 'default'};
    });

    await expectLater(repository.discover(), throwsFormatException);
  });

  for (final malformed in [
    <String, dynamic>{'display_name': 'Missing identity'},
    <String, dynamic>{'name': 42},
    <String, dynamic>{'name': ''},
  ]) {
    test('rejects malformed profile identity $malformed', () async {
      final repository = ProfilesRepository((endpoint) async {
        if (endpoint == 'profiles') {
          return {
            'profiles': [malformed],
          };
        }
        return {'current': 'default', 'active': 'default'};
      });
      await expectLater(repository.discover(), throwsFormatException);
    });
  }
}

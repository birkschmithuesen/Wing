import 'support/backend_update_channel_fixture.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/backend_update_controller.dart';
import 'package:wing/core/services/profile_gateway.dart';

void main() {
  BackendUpdateController controller(ScopedGet read) {
    final result = BackendUpdateController(
      ProfileGateway(
        scope: WorkspaceScope(connectionId: 'host', profileName: 'default'),
        get: read,
        rpc: (_, _) async => {},
        discover: () => throw UnimplementedError(),
      ),
    );
    addTearDown(result.dispose);
    return result;
  }

  test('installed version arrives before a slow upstream comparison', () async {
    final upstream = Completer<Map<String, dynamic>>();
    final version = controller(
      (endpoint, _) async => endpoint == 'health'
          ? {'ok': true, 'version': '1.2.3'}
          : upstream.future,
    );
    final refresh = version.checkForUpdate();
    await Future<void>.delayed(Duration.zero);
    expect(version.installedVersion, '1.2.3');
    expect(version.checking, isTrue);
    expect(version.versionLoading, isFalse);
    upstream.completeError(TimeoutException('upstream unavailable'));
    await refresh;
    expect(version.installedVersion, '1.2.3');
    expect(version.versionStale, isFalse);
    expect(version.check, isNull);
    expect(version.canStart, isFalse);
  });

  test('a transient identity read is retried once', () async {
    var attempts = 0;
    final version = controller((endpoint, _) async {
      if (endpoint != 'health') throw StateError('upstream unavailable');
      attempts++;
      if (attempts == 1) throw TimeoutException('connection interrupted');
      return {'ok': true, 'version': '1.2.3'};
    });
    await version.checkForUpdate();
    expect(attempts, 2);
    expect(version.installedVersion, '1.2.3');
    expect(version.canStart, isFalse);
  });

  test(
    'failed refresh retains identity but clears update eligibility',
    () async {
      var offline = false;
      final source = BackendUpdateChannelFixture();
      final version = controller((endpoint, query) async {
        if (offline) throw StateError('offline');
        if (endpoint == 'hermes/update/check') source.fetchedAt++;
        final metadata = source.read(endpoint, query);
        if (metadata != null) {
          if (endpoint == 'profiles') {
            return {
              'profiles': [
                {'name': 'default', 'path': BackendUpdateChannelFixture.home},
              ],
            };
          }
          return metadata;
        }
        return endpoint == 'health'
            ? {
                'ok': true,
                'version': '1.2.3',
                'commit': BackendUpdateChannelFixture.currentSha,
              }
            : {
                'current_version': '1.2.3',
                'update_available': true,
                'can_apply': true,
                'behind': 2,
              };
      });
      await version.checkForUpdate();
      expect(version.canStart, isTrue);
      offline = true;
      await version.checkForUpdate();
      expect(version.installedVersion, '1.2.3');
      expect(version.versionStale, isTrue);
      expect(version.canStart, isFalse);
      expect(version.check, isNull);
    },
  );

  test(
    'late liveness failure cannot mark a freshly confirmed version stale',
    () async {
      final health = Completer<Map<String, dynamic>>();
      final version = controller(
        (endpoint, _) async => endpoint == 'health'
            ? health.future
            : {
                'current_version': '1.2.4',
                'update_available': false,
                'behind': 0,
              },
      );
      final refresh = version.checkForUpdate();
      await Future<void>.delayed(Duration.zero);
      health.completeError(StateError('connection interrupted'));
      await refresh;
      expect(version.installedVersion, '1.2.4');
      expect(version.versionStale, isFalse);
    },
  );

  test('permanent invalid identity is not retried', () async {
    var attempts = 0;
    final version = controller((endpoint, _) async {
      if (endpoint != 'health') throw StateError('upstream unavailable');
      attempts++;
      return {'ok': true, 'version': ''};
    });
    await version.checkForUpdate();
    expect(attempts, 1);
    expect(version.installedVersion, isNull);
    expect(version.versionLoading, isFalse);
  });
}

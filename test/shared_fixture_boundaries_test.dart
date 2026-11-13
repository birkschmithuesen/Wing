import 'package:flutter_test/flutter_test.dart';

import 'support/administration_fixture.dart';
import 'support/administration_design_fixture.dart';
import 'support/backend_update_channel_fixture.dart';
import 'support/model_defaults_fixture.dart';
import 'support/scheduled_tasks_fixture.dart';

void main() {
  for (final route in ['health', 'profiles', 'config', 'model/options']) {
    test('administration fixture rejects POST to read route $route', () async {
      final fixture = AdministrationFixture();
      await expectLater(
        fixture.send('POST', route, {'profile': 'personal'}, {}),
        throwsStateError,
      );
    });
  }
  test('administration fixture accepts configured profile reads', () async {
    final fixture = AdministrationFixture();
    final result = await fixture.send('GET', 'config', {
      'profile': 'personal',
    }, null);
    expect(result['agent'], {'max_turns': 20});
  });
  test(
    'administration fixture rejects unknown RPC instead of an empty success',
    () async {
      final fixture = AdministrationFixture();
      addTearDown(fixture.server.close);
      await expectLater(
        fixture.server.profile('personal').rpc('unknown.operation'),
        throwsStateError,
      );
    },
  );
  test('administration fixture rejects unsupported plugin mutation', () async {
    final fixture = AdministrationFixture();
    addTearDown(fixture.server.close);
    await expectLater(
      fixture.server.profile('personal').rpc('plugins.manage', {
        'action': 'toggle',
      }),
      throwsStateError,
    );
  });
  test('administration fixture serves explicit plugin list', () async {
    final fixture = AdministrationFixture();
    addTearDown(fixture.server.close);
    expect(
      await fixture.server.profile('personal').rpc('plugins.manage', {
        'action': 'list',
      }),
      {'plugins': []},
    );
  });
  for (final (method, route) in [
    ('PATCH', 'cron/jobs/morning'),
    ('POST', 'cron/jobs/morning/unknown'),
    ('GET', 'cron/jobs/morning/pause'),
    ('DELETE', 'cron/jobs/morning/pause'),
    ('GET', 'cron/blueprints/instantiate'),
    ('POST', 'cron/blueprints'),
  ]) {
    test('scheduled fixture rejects $method $route before mutation', () async {
      final fixture = ScheduledTasksFixture();
      await expectLater(
        fixture.send(method, route, {'profile': 'personal'}, {}),
        throwsStateError,
      );
      expect(fixture.mutations, 0);
      expect(fixture.jobs['morning']!['enabled'], isTrue);
    });
  }
  test('scheduled fixture applies supported pause', () async {
    final fixture = ScheduledTasksFixture();
    await fixture.send('POST', 'cron/jobs/morning/pause', {
      'profile': 'personal',
    }, {});
    expect(fixture.jobs['morning']!['enabled'], isFalse);
    expect(fixture.mutations, 1);
  });
  for (final route in ['config', 'model/auxiliary', 'profiles']) {
    test('model defaults fixture rejects mutation to $route read', () async {
      final fixture = ModelDefaultsFixture();
      await expectLater(
        fixture.respond('POST', route, {'profile': 'personal'}, {}),
        throwsStateError,
      );
      expect(fixture.posts, isEmpty);
    });
  }
  for (final (method, route) in [
    ('DELETE', 'profiles/personal/soul'),
    ('POST', 'analytics/models'),
    ('GET', 'ops/doctor'),
  ]) {
    test('design fixture rejects $method $route', () async {
      final fixture = AdministrationDesignFixture();
      await expectLater(
        fixture.send(method, route, {'profile': 'personal'}, {}),
        throwsStateError,
      );
      expect(fixture.requests, isEmpty);
    });
  }
  for (final route in ['wrong?profile=work', 'config?profile=personal']) {
    test('channel fixture rejects $route before dispatch', () async {
      final fixture = BackendUpdateChannelFixture();
      var dispatched = false;
      await expectLater(
        fixture.put(route, {}, () => true, () => dispatched = true),
        throwsStateError,
      );
      expect(dispatched, isFalse);
      expect(fixture.writes, isEmpty);
      expect(fixture.savedRecord, isNull);
    });
  }
}

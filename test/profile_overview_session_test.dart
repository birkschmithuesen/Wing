import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/profile_overview_summary.dart';
import 'package:wing/core/services/profile_overview_session.dart';
import 'package:wing/core/services/scheduled_tasks_controller.dart';

import 'support/administration_fixture.dart';
import 'support/scheduled_tasks_fixture.dart';

String text(OverviewText value) => value.render(
  integer: (value) => '<$value>',
  checkedTime: (value) => '<checked>',
  taskTime: (value) => value.toUtc().toIso8601String(),
);

void main() {
  late AdministrationFixture fixture;
  late SharedPreferences preferences;
  late ProfileOverviewSession session;
  var workspaceRefreshes = 0;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    fixture = AdministrationFixture('Overview tests');
    workspaceRefreshes = 0;
    session = ProfileOverviewSession(
      fixture.server.profile('personal'),
      preferences,
      refreshWorkspace: () async {
        workspaceRefreshes++;
      },
      now: () => DateTime.utc(2026, 10, 4),
    );
  });
  tearDown(() => session.dispose());

  test('passive summary collections and fragments are immutable', () {
    expect(() => session.summary.rows.clear(), throwsUnsupportedError);
    expect(() => OverviewText('value').parts.clear(), throwsUnsupportedError);
    expect(() => OverviewText.parts([]).parts.clear(), throwsUnsupportedError);
  });

  test(
    'initial loading and confirmed empty tasks remain different facts',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      fixture.override = (_, _, _, _) => pending.future;
      final refresh = session.refresh();
      expect(text(session.summary.modelMetadata), 'Loading…');
      expect(
        text(
          session
              .summary
              .rows[ProfileOverviewDestination.scheduledTasks]!
              .summary,
        ),
        'Loading schedules…',
      );
      pending.complete({'data': []});
      await refresh;
      expect(
        text(
          session
              .summary
              .rows[ProfileOverviewDestination.scheduledTasks]!
              .summary,
        ),
        'No scheduled tasks',
      );
      expect(session.summary.modelAttention, 'Information unavailable');
    },
  );

  test('automatic provider is a configured stock model route', () async {
    fixture.override = (_, path, _, _) async => switch (path) {
      'model/info' => {'provider': '', 'model': 'stock-model'},
      'config' => {
        'agent': {'reasoning_effort': 'high'},
      },
      _ => {'data': []},
    };
    await session.refresh(keys: {'model', 'config'});
    expect(session.summary.modelTitle, 'stock-model');
    expect(
      text(session.summary.modelMetadata),
      'Automatic provider · Reasoning high',
    );
    expect(session.summary.modelAttention, isNull);
  });

  test(
    'partial refresh retains good independent observations and timestamps',
    () async {
      await session.refresh();
      final checked = session.overviewOwner.observations['config']!.checkedAt;
      fixture.failReads = true;
      await session.refresh(keys: {'config'});
      final memory = session.summary.rows[ProfileOverviewDestination.memory]!;
      expect(
        text(memory.summary),
        contains('<2000>-character budget · Retention on'),
      );
      expect(
        text(memory.summary),
        contains('Last checked <checked>; refresh unavailable'),
      );
      expect(memory.attention, 'Refresh unavailable');
      expect(session.overviewOwner.observations['config']!.checkedAt, checked);
      expect(session.summary.modelTitle, 'Research model');
      expect(session.summary.modelAttention, 'Refresh unavailable');
    },
  );

  test(
    'unknown booleans never become disabled or confirmed empty configuration',
    () async {
      fixture.override = (_, path, _, _) async => switch (path) {
        'config' => {
          'memory': {
            'memory_enabled': 'false',
            'memory_char_limit': double.infinity,
          },
        },
        'skills' => {
          'data': [
            {'enabled': null},
          ],
        },
        'tools/toolsets' => {
          'data': [
            {'enabled': true},
          ],
        },
        _ => {'data': []},
      };
      await session.refresh(keys: {'config', 'skills', 'tools'});
      expect(
        text(session.summary.rows[ProfileOverviewDestination.memory]!.summary),
        'Memory budget unavailable · Retention unavailable',
      );
      expect(
        text(session.summary.rows[ProfileOverviewDestination.skills]!.summary),
        contains('Some states unavailable'),
      );
      expect(
        text(session.summary.rows[ProfileOverviewDestination.skills]!.summary),
        contains('Some tool states unavailable'),
      );
    },
  );

  test(
    'selected provider metadata and expired credential attention are separate',
    () async {
      fixture.override = (_, path, _, _) async => switch (path) {
        'model/info' => {'model': 'chosen', 'provider': 'selected'},
        'providers/oauth' => {
          'providers': [
            {
              'id': 'selected',
              'status': {
                'logged_in': true,
                'source_label': 'Profile credentials',
              },
            },
            {
              'id': 'old',
              'status': {
                'logged_in': true,
                'expires_at': '2020-01-01T00:00:00Z',
              },
            },
          ],
        },
        'mcp/servers' => {
          'servers': [
            {
              'name': 'local',
              'enabled': true,
              'transport': 'stdio',
              'auth': null,
              'source': 'config',
              'plugin': null,
            },
          ],
        },
        _ => {'data': []},
      };
      await session.refresh(keys: {'model', 'access', 'connectors'});
      final access = session.summary.rows[ProfileOverviewDestination.access]!;
      expect(
        text(access.summary),
        '2 sign-ins reported · Profile credentials · 1 connector',
      );
      expect(access.attention, 'Sign-in expired');
    },
  );

  test(
    'task projection ranks only eligible upcoming runs and reports listed outcomes',
    () async {
      fixture.override = (_, path, _, _) async => {
        'data': path == 'cron/jobs'
            ? [
                taskJson(id: 'later', name: 'Later')
                  ..['next_run_at'] = '2026-10-07T00:00:00Z',
                taskJson(id: 'earlier', name: 'Earlier')
                  ..['next_run_at'] = '2026-10-06T00:00:00Z',
                taskJson(id: 'paused', name: 'Paused', state: 'paused')
                  ..['next_run_at'] = '2026-10-05T00:00:00Z',
                taskJson(id: 'error', name: 'Latest listed')
                  ..['last_run_at'] = '2026-10-05T00:00:00Z'
                  ..['last_error'] = 'reported'
                  ..['next_run_at'] = null,
              ]
            : [],
      };
      await session.refresh(keys: {'tasks'});
      final tasks =
          session.summary.rows[ProfileOverviewDestination.scheduledTasks]!;
      expect(tasks.detail, 'Earlier');
      expect(text(tasks.summary), contains('Next 2026-10-06T00:00:00.000Z'));
      expect(text(tasks.summary), contains('Last listed run · Error reported'));
      expect(tasks.attention, 'Needs attention');
    },
  );

  for (final destination in ProfileOverviewDestination.values) {
    test(
      '${destination.label} return refreshes only its observations',
      () async {
        await session.returnedFrom(destination);
        final expected = switch (destination) {
          ProfileOverviewDestination.models => {
            'model/info',
            'config',
            'providers/oauth',
          },
          ProfileOverviewDestination.identity => <String>{},
          ProfileOverviewDestination.memory ||
          ProfileOverviewDestination.behavior => {'config'},
          ProfileOverviewDestination.skills => {
            'skills',
            'tools/toolsets',
            'providers/oauth',
          },
          ProfileOverviewDestination.skillHub => {'skills'},
          ProfileOverviewDestination.access => {
            'providers/oauth',
            'mcp/servers',
          },
          ProfileOverviewDestination.connectors => {'mcp/servers'},
          ProfileOverviewDestination.scheduledTasks => {'cron/jobs'},
        };
        expect(fixture.requests.map((r) => r.$2).toSet(), expected);
        expect(
          fixture.requests.every(
            (r) => r.$1 == 'GET' && r.$3['profile'] == 'personal',
          ),
          isTrue,
        );
      },
    );
  }

  test('existing task lease and route share the exact cache owner', () async {
    final otherLease = ScheduledTasksController.acquire(
      fixture.server.profile('personal'),
      preferences,
    );
    addTearDown(otherLease.release);
    expect(identical(otherLease, session.taskOwner), isTrue);
    await session.refresh(keys: {'tasks'});
    session.dispose();
    await otherLease.refresh();
    expect(otherLease.tasks, isEmpty);
  });

  test(
    'task read already in flight is not duplicated by overview refresh',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      fixture.override = (_, _, _, _) => pending.future;
      final first = session.refresh(keys: {'tasks'});
      final returning = session.returnedFrom(
        ProfileOverviewDestination.scheduledTasks,
      );
      expect(fixture.requests, hasLength(1));
      pending.complete({'data': []});
      await Future.wait([first, returning]);
    },
  );

  test('retired route never starts reads or refreshes its workspace', () async {
    session.dispose();
    await session.refresh();
    await session.returnedFrom(ProfileOverviewDestination.models);
    expect(fixture.requests, isEmpty);
    expect(workspaceRefreshes, 0);
  });

  test(
    'disposal during a held read suppresses the route observation',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      fixture.override = (_, _, _, _) => pending.future;
      final refresh = session.refresh(keys: {'config'});
      session.dispose();
      pending.complete({
        'memory': {'memory_enabled': true},
      });
      await refresh;
      expect(session.refreshing, isFalse);
      expect(session.overviewOwner.observations['config']!.data, isNull);
    },
  );

  test(
    'newer targeted refresh does not release an older pending read',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      fixture.override = (_, path, _, _) async =>
          path == 'config' ? pending.future : {'model': 'new', 'provider': ''};
      final old = session.refresh(keys: {'config'});
      await session.refresh(keys: {'model'});
      expect(session.refreshing, isTrue);
      pending.complete({
        'memory': {'memory_enabled': true, 'memory_char_limit': 1234},
      });
      await old;
      expect(session.refreshing, isFalse);
      expect(
        text(session.summary.rows[ProfileOverviewDestination.memory]!.summary),
        contains('<1234>-character budget'),
      );
      expect(session.summary.modelTitle, 'new');
    },
  );
}

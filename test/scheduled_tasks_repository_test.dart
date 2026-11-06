import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/scheduled_task.dart';
import 'package:wing/core/models/scheduled_task_edit.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/scheduled_tasks_repository.dart';
import 'support/scheduled_tasks_fixture.dart';

void main() {
  test('live execution stays stoppable when a later trigger is rejected', () {
    final t = ScheduledTask.fromJson({
      ...taskJson(),
      'live_execution': {'id': 'older', 'status': 'running'},
      'latest_execution': {
        'id': 'newer',
        'status': 'rejected',
        'error': 'Already running',
      },
    });
    expect(t.running, isTrue);
    expect(t.canStop, isTrue);
    expect(t.canRun, isFalse);
    expect(t.latestExecution!.label, 'Rejected');
  });

  test(
    'cancel decodes receipt and preserves schedule; no live run is a no-op',
    () async {
      final f = ScheduledTasksFixture();
      f.jobs['morning'] = taskJson(state: 'running');
      final repository = ScheduledTasksRepository(f.profile);
      final result = await repository.cancel('morning');
      expect(result.requested, isTrue);
      expect(result.executionId, 'execution-morning');
      expect(f.jobs['morning']!['enabled'], isTrue);
      expect(f.admin.requests.last.$3['profile'], 'personal');
      f.jobs['morning']!['live_execution'] = null;
      expect((await repository.cancel('morning')).requested, isFalse);
    },
  );

  test('cancel rejects mismatched receipt identity as uncertain', () async {
    final f = ScheduledTasksFixture();
    f.intercept = (method, path, query, body) async {
      if (method == 'GET' && path == 'cron/jobs') {
        return {
          'data': [taskJson()],
        };
      }
      if (path == 'profiles') {
        return {
          'profiles': [
            {'name': 'personal'},
          ],
        };
      }
      return {
        'success': true,
        'cancelled': true,
        'execution_id': 'e',
        'job_id': 'other',
      };
    };
    await expectLater(
      ScheduledTasksRepository(f.profile).cancel('morning'),
      throwsA(isA<TaskMutationUncertain>()),
    );
  });

  test(
    'room targets use room host profile independently of task profile',
    () async {
      final f = ScheduledTasksFixture();
      f.rooms.add({'room_id': 'room-1', 'name': 'Release team', 'members': []});
      final rooms = await ScheduledTasksRepository(
        f.profile,
      ).roomDestinations();
      expect(rooms.single.id, 'room:room-1@default');
      expect(rooms.single.label, 'Release team');
      expect(f.admin.rpcRequests.single, ('default', 'groups.list'));
      expect(f.mutations, 0);
    },
  );

  test(
    'policy intent retains null false and zero with conflict protection',
    () {
      final baseline = ScheduledTask.fromJson({
        ...taskJson(),
        'catch_up': null,
        'grace_minutes': null,
      });
      final intent = TaskEditIntent(
        baseline: baseline,
        values: {
          'catch_up': false,
          'grace_minutes': 0,
          'timezone': 'Asia/Singapore',
        },
      );
      expect(intent.resolve(baseline).updates, {
        'catch_up': false,
        'grace_minutes': 0,
        'timezone': 'Asia/Singapore',
      });
      final changed = ScheduledTask.fromJson({
        ...baseline.data,
        'catch_up': true,
      });
      expect(intent.resolve(changed).conflicts, ['catch_up']);
      final reconciled = intent.review(changed).reconcile({
        TaskConflictField.catchUp: TaskConflictDecision.useServer,
      });
      expect(reconciled.values.containsKey('catch_up'), isFalse);
      expect(reconciled.values['grace_minutes'], 0);
    },
  );

  for (final operation in ['update', 'pause', 'resume', 'trigger', 'delete']) {
    for (final failure in ['missing', 'offline', 'duplicate', 'wrong owner']) {
      test('$operation refuses $failure membership before dispatch', () async {
        final fixture = ScheduledTasksFixture();
        final repository = ScheduledTasksRepository(fixture.profile);
        final baseline = (await repository.list()).first;
        switch (failure) {
          case 'missing':
            fixture.jobs.remove(baseline.id);
          case 'offline':
            fixture.failList = true;
          case 'duplicate':
            fixture.jobs['duplicate'] = taskJson();
          case 'wrong owner':
            fixture.jobs[baseline.id] = taskJson(profile: 'work');
        }
        final Future<Object?> request = switch (operation) {
          'update' => repository.update(
            TaskEditIntent(baseline: baseline, values: {'name': 'Draft'}),
          ),
          'delete' => repository.delete(baseline.id),
          _ => repository.action(baseline.id, operation),
        };
        await expectLater(request, throwsA(isA<TaskPreflightFailure>()));
        expect(fixture.mutations, 0);
      });
    }
  }

  test(
    'same-field conflict preserves the server value without a write',
    () async {
      final fixture = ScheduledTasksFixture();
      final repository = ScheduledTasksRepository(fixture.profile);
      final baseline = await repository.get('morning');
      fixture.jobs['morning']!['name'] = 'Another client';
      await expectLater(
        repository.update(
          TaskEditIntent(baseline: baseline, values: {'name': 'My draft'}),
        ),
        throwsA(
          isA<TaskEditConflict>().having((e) => e.fields, 'fields', ['name']),
        ),
      );
      expect(fixture.jobs['morning']!['name'], 'Another client');
      expect(fixture.mutations, 0);
    },
  );

  test('already applied desired edit needs no write or conflict', () async {
    final fixture = ScheduledTasksFixture();
    final repository = ScheduledTasksRepository(fixture.profile);
    final baseline = await repository.get('morning');
    fixture.jobs['morning']!['name'] = 'My draft';
    expect(
      (await repository.update(
        TaskEditIntent(baseline: baseline, values: {'name': 'My draft'}),
      )).name,
      'My draft',
    );
    expect(fixture.mutations, 0);
  });

  test(
    'already applied one-shot instant needs no write across stock UTC spelling',
    () async {
      final fixture = ScheduledTasksFixture();
      fixture.jobs['morning']!['schedule'] = {
        'kind': 'once',
        'run_at': '2026-10-05T09:45:00+00:00',
      };
      final repository = ScheduledTasksRepository(fixture.profile);
      final baseline = await repository.get('morning');
      await fixture.send('PUT', 'cron/jobs/morning', {}, {
        'updates': {'schedule': '2026-10-04T09:45:00.000Z'},
      });
      final mutations = fixture.mutations;
      final result = await repository.update(
        TaskEditIntent(
          baseline: baseline,
          values: {'schedule': '2026-10-04T09:45:00.000Z'},
        ),
      );
      expect(result.schedule['kind'], 'once');
      expect(
        DateTime.parse(result.schedule['run_at'] as String),
        DateTime.utc(2026, 10, 4, 9, 45),
      );
      expect(fixture.mutations, mutations);
      expect(
        fixture.admin.requests.where((request) => request.$1 == 'PUT'),
        isEmpty,
      );
    },
  );

  test(
    'reselecting the same one-shot instant does not dispatch a schedule write',
    () async {
      final fixture = ScheduledTasksFixture();
      fixture.jobs['morning']!['schedule'] = {
        'kind': 'once',
        'run_at': '2026-10-04T09:45:00+00:00',
      };
      final repository = ScheduledTasksRepository(fixture.profile);
      final baseline = await repository.get('morning');
      final result = await repository.update(
        TaskEditIntent(
          baseline: baseline,
          values: {'schedule': '2026-10-04T09:45:00.000Z'},
        ),
      );
      expect(result.scheduleInput, '2026-10-04T09:45:00+00:00');
      expect(fixture.mutations, 0);
    },
  );

  test(
    'a distinct remote one-shot instant still conflicts at microsecond precision',
    () async {
      final fixture = ScheduledTasksFixture();
      fixture.jobs['morning']!['schedule'] = {
        'kind': 'once',
        'run_at': '2026-10-04T09:45:00+00:00',
      };
      final repository = ScheduledTasksRepository(fixture.profile);
      final baseline = await repository.get('morning');
      fixture.jobs['morning']!['schedule'] = {
        'kind': 'once',
        'run_at': '2026-10-04T09:45:00.000001+00:00',
      };
      await expectLater(
        repository.update(
          TaskEditIntent(
            baseline: baseline,
            values: {'schedule': '2026-10-04T09:45:00.000002Z'},
          ),
        ),
        throwsA(
          isA<TaskEditConflict>().having((error) => error.fields, 'fields', [
            'schedule',
          ]),
        ),
      );
      expect(fixture.mutations, 0);
    },
  );

  test('model edit conflicts when its provider changed externally', () async {
    final fixture = ScheduledTasksFixture();
    fixture.jobs['morning']!.addAll({
      'model': 'old-model',
      'provider': 'anthropic',
    });
    final repository = ScheduledTasksRepository(fixture.profile);
    final baseline = await repository.get('morning');
    fixture.jobs['morning']!['provider'] = 'openai';
    await expectLater(
      repository.update(
        TaskEditIntent(baseline: baseline, values: {'model': 'new-model'}),
      ),
      throwsA(
        isA<TaskEditConflict>().having((e) => e.fields, 'fields', ['provider']),
      ),
    );
    expect(fixture.mutations, 0);
  });

  test('opening edit snapshot survives nested source changes', () {
    final source = taskJson()
      ..['schedule'] = {'kind': 'interval', 'minutes': 30};
    final baseline = ScheduledTask.fromJson(source);
    (source['schedule'] as Map)['minutes'] = 45;
    source['name'] = 'External change';
    expect(baseline.scheduleInput, 'every 30m');
    expect(baseline.name, 'Morning briefing');
    expect(baseline.changes({'schedule': 'every 30m', 'name': 'Draft'}), {
      'name': 'Draft',
    });
  });

  for (final operation in [
    'update',
    'pause',
    'resume',
    'trigger',
    'create',
    'instantiate',
  ]) {
    test('$operation rejects a contradictory dispatched owner', () async {
      final fixture = ScheduledTasksFixture();
      Future<Map<String, dynamic>> handler(
        String method,
        String path,
        Map<String, String> query,
        Map<String, dynamic>? body,
      ) async {
        if (method != 'GET') {
          fixture.mutations++;
          return taskJson(profile: 'work');
        }
        fixture.intercept = null;
        try {
          return await fixture.send(method, path, query, body);
        } finally {
          fixture.intercept = handler;
        }
      }

      fixture.intercept = handler;
      final repository = ScheduledTasksRepository(fixture.profile);
      final Future<Object?> request = switch (operation) {
        'update' => repository.update(
          TaskEditIntent(
            baseline: ScheduledTask.fromJson(taskJson()),
            values: {'name': 'Draft'},
          ),
        ),
        'create' => repository.create({'name': 'Draft'}),
        'instantiate' => repository.instantiate(
          (await repository.templates()).singleWhere(
            (template) => template.key == 'morning-brief',
          ),
          {'time': '09:00'},
        ),
        _ => repository.action('morning', operation),
      };
      await expectLater(request, throwsA(isA<TaskMutationUncertain>()));
      expect(fixture.mutations, 1);
    });
  }

  test(
    'cached task moved to another profile is refused before dispatch',
    () async {
      final fixture = ScheduledTasksFixture(samples: false);
      final personal = taskJson()
        ..addAll({'profile': 'personal', 'profile_name': 'personal'});
      final work = taskJson()
        ..addAll({'profile': 'work', 'profile_name': 'work'});
      var moved = false;
      var writes = 0;
      fixture.intercept = (method, path, query, body) async {
        if (path == 'profiles') {
          return {
            'profiles': [
              {'name': 'personal'},
              {'name': 'work'},
              {'name': 'default', 'is_default': true},
            ],
          };
        }
        if (path == 'profiles/active') {
          return {'current': 'default', 'active': 'default'};
        }
        if (method == 'GET' && path == 'cron/jobs') {
          expect(query['profile'], 'personal');
          return {
            'data': moved
                ? <Map<String, dynamic>>[]
                : [
                    {...personal},
                  ],
          };
        }
        if (method == 'POST' && path == 'cron/jobs/morning/pause') {
          writes++;
          // Stock Hermes treats the supplied profile as a hint. After a move,
          // this route resolves the task in work and would mutate that store.
          final resolved = moved ? work : personal;
          resolved.addAll({'state': 'paused', 'enabled': false});
          return {...resolved};
        }
        throw StateError('Unexpected scheduled-task request: $method $path');
      };
      final repository = ScheduledTasksRepository(fixture.profile);
      final cached = (await repository.list()).single;
      moved = true;

      await expectLater(
        repository.action(cached.id, 'pause'),
        throwsA(isA<AdministrationFailure>()),
      );
      expect(writes, 0);
      expect(work['state'], 'scheduled');
    },
  );

  for (final owner in <Map<String, dynamic>>[
    {},
    {'profile': 'personal'},
    {'profile_name': 'personal'},
    {'profile': 'personal', 'profile_name': 'work'},
  ]) {
    test(
      'task read rejects incomplete or contradictory owner $owner',
      () async {
        final fixture = ScheduledTasksFixture(samples: false);
        fixture.jobs['morning'] = taskJson()
          ..remove('profile')
          ..remove('profile_name')
          ..addAll(owner);
        await expectLater(
          ScheduledTasksRepository(fixture.profile).get('morning'),
          throwsFormatException,
        );
      },
    );
  }

  test('task read accepts matching explicit profile ownership', () async {
    final fixture = ScheduledTasksFixture(samples: false);
    fixture.jobs['morning'] = taskJson()
      ..addAll({'profile': 'personal', 'profile_name': 'personal'});
    expect(
      (await ScheduledTasksRepository(fixture.profile).get('morning')).id,
      'morning',
    );
  });

  test(
    'current mixed run records preserve source, preview and status title',
    () async {
      final fixture = ScheduledTasksFixture();
      fixture.runRows.addAll([
        {
          'id': 'cron_output:morning:20260918_090000',
          'source': 'cron_output',
          'title': 'COMPLETED · Script-only run',
          'preview': 'The report was saved.',
          'started_at': 1789700000,
          'is_active': false,
        },
        {
          'id': 'cron_output:morning:exec:0',
          'source': 'cron_output',
          'title': 'FAILED · Script exited with code 1',
          'preview': 'Script exited with code 1',
          'started_at': 1789600000,
          'is_active': false,
        },
        {
          'id': 'cron_output:morning:latest',
          'source': 'cron_output',
          'title': 'COMPLETED',
          'preview': null,
          'started_at': 1789500000,
          'is_active': false,
        },
      ]);
      final runs = await ScheduledTasksRepository(
        fixture.profile,
      ).runs('morning');
      expect(runs.first.source, 'cron');
      expect(runs.first.isConversation, isTrue);
      expect(
        runs.skip(1).every((r) => r.isScriptOutput && !r.isConversation),
        isTrue,
      );
      expect(runs[1].title, 'COMPLETED · Script-only run');
      expect(runs[1].preview, 'The report was saved.');
      expect(runs[2].preview, 'Script exited with code 1');
      expect(runs[3].preview, isEmpty);
      expect(runs.every((r) => r.started?.isUtc == true), isTrue);
    },
  );
  test('unchanged interval schedules are omitted from edits', () {
    final task = ScheduledTask.fromJson(
      taskJson()..['schedule'] = {'kind': 'interval', 'minutes': 30},
    );
    expect(task.scheduleInput, 'every 30m');
    expect(task.changes({'name': 'Changed', 'schedule': task.scheduleInput}), {
      'name': 'Changed',
    });
  });

  test('unchanged one-shot schedule retains its offset spelling', () {
    final once = ScheduledTask.fromJson(
      taskJson()
        ..['schedule'] = {
          'kind': 'once',
          'run_at': '2026-11-01T01:30:00-04:00',
        },
    );
    expect(once.scheduleInput, '2026-11-01T01:30:00-04:00');
    expect(once.changes({'schedule': once.scheduleInput}), isEmpty);
  });

  test('one-shot input serializes the same instant in UTC', () {
    expect(
      taskScheduleExpression(
        TaskScheduleKind.once,
        once: DateTime.parse('2026-11-01T01:30:00-04:00'),
      ),
      '2026-11-01T05:30:00.000Z',
    );
  });

  for (final (kind, expected) in [
    (TaskScheduleKind.weekdays, '30 17 * * 1-5'),
    (TaskScheduleKind.weekly, '30 17 * * 0'),
    (TaskScheduleKind.monthly, '30 17 31 * *'),
    (TaskScheduleKind.delay, 'in 90m'),
    (TaskScheduleKind.interval, 'every 90m'),
  ]) {
    test('$kind serializes its requested schedule', () {
      expect(
        taskScheduleExpression(
          kind,
          hour: 17,
          minute: 30,
          weekday: 0,
          monthDay: 31,
          minutes: 90,
        ),
        expected,
      );
    });
  }
  test('unknown state is unavailable, never inferred from enabled', () {
    final t = ScheduledTask.fromJson(taskJson()..remove('state'));
    expect(t.statusLabel, 'Status unavailable');
    expect(t.canRun, false);
    expect(t.canPause, false);
  });
  test('incomplete task record is rejected', () {
    expect(() => ScheduledTask.fromJson({'id': 'x'}), throwsFormatException);
  });
  for (final operation in [
    'get',
    'runs',
    'update',
    'pause',
    'resume',
    'trigger',
    'delete',
  ]) {
    test(
      '$operation encodes its task ID and retains canonical profile',
      () async {
        final f = ScheduledTasksFixture(samples: false);
        f.jobs['a/b +'] = taskJson(id: 'a/b +');
        final repo = ScheduledTasksRepository(f.profile);
        switch (operation) {
          case 'get':
            expect((await repo.get('a/b +')).id, 'a/b +');
          case 'runs':
            await repo.runs('a/b +', limit: 1000);
          case 'update':
            await repo.update(
              TaskEditIntent(
                baseline: ScheduledTask.fromJson(taskJson(id: 'a/b +')),
                values: {'name': 'Renamed'},
              ),
            );
          case 'delete':
            await repo.delete('a/b +');
          default:
            await repo.action('a/b +', operation);
        }
        final endpoint =
            'cron/jobs/a%2Fb%20%2B${['runs', 'pause', 'resume', 'trigger'].contains(operation) ? '/$operation' : ''}';
        final method = switch (operation) {
          'get' || 'runs' => 'GET',
          'update' => 'PUT',
          'delete' => 'DELETE',
          _ => 'POST',
        };
        final request = f.admin.requests.singleWhere(
          (r) => r.$1 == method && r.$2 == endpoint,
        );
        expect(request.$3['profile'], 'personal');
        if (operation == 'runs') expect(request.$3['limit'], '100');
        if (operation == 'update') {
          expect(request.$4, {
            'updates': {'name': 'Renamed'},
            'profile': 'personal',
          });
        }
      },
    );
  }
  test(
    'missing profile prevents writes and template targets are explicit',
    () async {
      final f = ScheduledTasksFixture();
      final repo = ScheduledTasksRepository(f.profile);
      final template = (await repo.templates()).singleWhere(
        (template) => template.key == 'morning-brief',
      );
      expect(template.initialValues['deliver'], 'local');
      await repo.instantiate(template, {
        ...template.initialValues,
        'time': '09:00',
      });
      expect(f.admin.requests.last.$3['profile'], 'personal');
      f.missingProfile = true;
      await expectLater(
        repo.action('morning', 'pause'),
        throwsA(isA<AdministrationFailure>()),
      );
      expect(f.mutations, 1);
    },
  );
  test('common edits do not erase script skills or execution settings', () {
    final task = ScheduledTask.fromJson(
      taskJson()..addAll({
        'script': 'brief.sh',
        'no_agent': true,
        'skills': ['research'],
        'base_url': 'http://internal',
      }),
    );
    expect(task.changes({'name': 'Review'}), {'name': 'Review'});
    expect(task.scriptOnly, true);
  });
}

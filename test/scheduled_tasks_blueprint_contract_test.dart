import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/scheduled_tasks_repository.dart';

import 'support/scheduled_tasks_fixture.dart';

Future<ProcessResult> checkContract(
  String rule,
  Map<String, dynamic> payload,
) async {
  final directory = await Directory.systemTemp.createTemp('wing-blueprint-');
  try {
    final input = File('${directory.path}/response.json');
    await input.writeAsString(jsonEncode(payload));
    return await Process.run('python3', [
      'tools/architecture/rules/stock_task_blueprint_$rule.py',
      '--input',
      input.path,
    ]);
  } finally {
    await directory.delete(recursive: true);
  }
}

void main() {
  test(
    'independent blueprint guard CLIs reject their invalid fixtures',
    () async {
      final result = await Process.run('python3', [
        'tools/architecture/tests/test_task_blueprint_guards.py',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );

  test(
    'actual scheduled fixture schema equals the pinned stock catalog',
    () async {
      final fixture = ScheduledTasksFixture();
      final response = await fixture.profile.read('cron/blueprints');
      final targets = await fixture.profile.read('cron/delivery-targets');
      final result = await checkContract('schema', {
        ...response,
        'delivery_targets': [
          for (final target in targets['targets'] as List) target['id'],
        ],
      });
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

      // A caller's local changes must not alter the fixture's next response.
      ((response['blueprints'] as List).first['fields'] as List).clear();
      final fresh = await ScheduledTasksRepository(fixture.profile).templates();
      final morning = fresh.singleWhere(
        (template) => template.key == 'morning-brief',
      );
      expect(morning.initialValues, {'time': '08:00', 'deliver': 'local'});
      expect(fresh, hasLength(16));
    },
  );

  test(
    'actual template submissions use canonical morning and news slots',
    () async {
      final fixture = ScheduledTasksFixture(samples: false);
      final repository = ScheduledTasksRepository(fixture.profile);
      final templates = await repository.templates();
      for (final key in ['morning-brief', 'news-digest']) {
        final template = templates.singleWhere(
          (template) => template.key == key,
        );
        await repository.instantiate(template, {
          ...template.initialValues,
          if (key == 'news-digest') 'topic': 'Flutter',
        });
      }
      final result = await checkContract('slots', {
        'submissions': [
          for (final request in fixture.admin.requests)
            if (request.$2 == 'cron/blueprints/instantiate')
              {
                'blueprint': request.$4!['blueprint'],
                'values': request.$4!['values'],
              },
        ],
      });
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(fixture.jobs, hasLength(2));
    },
  );

  test(
    'fixture rejects invented morning topic before creating a job',
    () async {
      final fixture = ScheduledTasksFixture(samples: false);
      final repository = ScheduledTasksRepository(fixture.profile);
      final template = (await repository.templates()).singleWhere(
        (template) => template.key == 'morning-brief',
      );
      await expectLater(
        repository.instantiate(template, {'topic': 'Calendar'}),
        throwsA(
          isA<CronHttpException>().having(
            (error) => error.statusCode,
            'status',
            422,
          ),
        ),
      );
      expect(fixture.jobs, isEmpty);
    },
  );

  test(
    'fixture accepts stock defaults but rejects explicit empty required slots',
    () async {
      final fixture = ScheduledTasksFixture(samples: false);
      final repository = ScheduledTasksRepository(fixture.profile);
      final template = (await repository.templates()).singleWhere(
        (template) => template.key == 'morning-brief',
      );
      await repository.instantiate(template, {});
      await expectLater(
        repository.instantiate(template, {'time': ''}),
        throwsA(
          isA<CronHttpException>().having(
            (error) => error.statusCode,
            'status',
            422,
          ),
        ),
      );
      expect(fixture.jobs, hasLength(1));
    },
  );
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/scheduled_task_edit.dart';
import 'package:wing/core/services/scheduled_tasks_repository.dart';

import 'support/scheduled_tasks_fixture.dart';

void main() {
  test(
    'actual fixture create/update DTOs preserve pinned stock schedule kinds',
    () async {
      final artifact =
          jsonDecode(
                File(
                  'tools/contracts/hermes_task_schedule_projection.json',
                ).readAsStringSync(),
              )
              as Map;
      final observations = <Map<String, dynamic>>[];
      for (final raw in artifact['cases'] as List) {
        final sample = raw as Map;
        final fixture = ScheduledTasksFixture(
          samples: false,
          now: DateTime.parse(artifact['clock'] as String),
        );
        final repository = ScheduledTasksRepository(fixture.profile);
        final created = await repository.create({
          'prompt': 'Synthetic schedule contract',
          'schedule': sample['input'],
        });
        observations.add({
          'id': sample['id'],
          'operation': 'POST',
          'response': created.data,
        });
        final baseline = await repository.create({
          'prompt': 'Synthetic schedule baseline',
          'schedule': sample['input'] == '0 9 * * *'
              ? '*/15 * * * *'
              : '0 9 * * *',
        });
        final updated = await repository.update(
          TaskEditIntent(
            baseline: baseline,
            values: {'schedule': sample['input']},
          ),
        );
        observations.add({
          'id': sample['id'],
          'operation': 'PUT',
          'response': updated.data,
        });
        expect(
          fixture.admin.requests.where((request) => request.$1 == 'PUT'),
          hasLength(1),
        );
        expect(updated.schedule, sample['schedule']);
      }
      final directory = await Directory.systemTemp.createTemp(
        'wing-schedule-projection-',
      );
      try {
        final exported = File('${directory.path}/actual.json');
        await exported.writeAsString(
          jsonEncode({'observations': observations}),
        );
        final result = await Process.run('python3', [
          'tools/architecture/rules/stock_task_schedule_projection.py',
          '--input',
          exported.path,
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'fixture rejects malformed and unsupported schedules explicitly',
    () async {
      for (final schedule in [
        'unknown',
        'every 0m',
        '2026-99-04T09:45:00Z',
        '2026-10-04T09:45:00+24:00',
      ]) {
        final fixture = ScheduledTasksFixture(samples: false);
        await expectLater(
          fixture.send('POST', 'cron/jobs', {}, {'schedule': schedule}),
          throwsFormatException,
        );
        expect(fixture.jobs, isEmpty);
      }
    },
  );
}

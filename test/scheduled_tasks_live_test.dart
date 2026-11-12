import 'package:wing/core/services/connection_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/scheduled_task_edit.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/scheduled_tasks_repository.dart';
import 'package:wing/core/services/server_connection_status.dart';

/// Opt-in local acceptance. The backend must use a disposable HERMES_HOME,
/// contain mobile-test/scripts/probe.sh (a harmless printf script), and have its
/// scheduler stopped for this probe. The template API creates enabled jobs;
/// pausing them afterward cannot prevent an intervening scheduler tick.
/// Creates/deletes only jobs it owns. Agent tasks are never explicitly triggered.
/// One script-only task is run.
/// flutter test test/scheduled_tasks_live_test.dart --dart-define=SCHEDULED_TASKS_LIVE=true
void main() {
  const enabled = bool.fromEnvironment('SCHEDULED_TASKS_LIVE');
  test(
    'real Hermes profile CRUD, schedule, template, delivery and script execution',
    () async {
      const port = int.fromEnvironment(
        'SCHEDULED_TASKS_PORT',
        defaultValue: 9847,
      );
      final status = ServerConnectionStatus('Disposable scheduling acceptance');
      addTearDown(status.dispose);
      final server = AdministrationRepository.forConnection(
        ConnectionAccess(
          connection: SavedConnection(
            id: 'disposable-scheduled-acceptance',
            label: status.label,
            host: '127.0.0.1',
            port: port,
            dashboardPortOverride: port,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        'local-disposable-only',
        connectionStatus: status,
      );
      addTearDown(server.close);
      final repo = ScheduledTasksRepository(server.profile('mobile-test'));
      final owned = <String>[];
      void own(String id) {
        owned.add(id);
        // Register separately so one cleanup failure cannot strand other jobs
        // or prevent repository/connection disposal.
        addTearDown(() async {
          await repo.delete(id);
          expect((await repo.list()).any((task) => task.id == id), isFalse);
        });
      }

      final initial = await repo.list();
      expect(await repo.destinations(), isNotEmpty);
      final templates = await repo.templates();
      expect(templates.any((t) => t.key == 'morning-brief'), true);
      var job = await repo.create({
        'name': 'Wing local acceptance',
        'prompt': 'Never run: client acceptance fixture',
        'schedule': '0 9 * * 1-5',
        'deliver': 'local',
        'paused': true,
      });
      own(job.id);
      expect(job.paused, true);
      expect(job.schedule['kind'], 'cron');
      expect(job.schedule['expr'], '0 9 * * 1-5');
      job = await repo.update(
        TaskEditIntent(
          baseline: job,
          values: {
            'name': 'Wing edited acceptance',
            'model': null,
            'provider': null,
          },
        ),
      );
      expect(job.name, 'Wing edited acceptance');
      expect(job.text('model'), '');
      job = await repo.action(job.id, 'resume');
      expect(job.enabled, true);
      job = await repo.action(job.id, 'pause');
      expect(job.paused, true);
      expect((await repo.runs(job.id)), isEmpty);
      expect(
        (await ScheduledTasksRepository(
          server.profile('default'),
        ).list()).any((t) => t.id == job.id),
        false,
      );
      var script = await repo.create({
        'name': 'Wing script acceptance',
        'schedule': 'every 1d',
        'script': 'probe.sh',
        'no_agent': true,
        'deliver': 'local',
        'paused': true,
      });
      own(script.id);
      script = await repo.action(script.id, 'trigger');
      expect(script.lastRun, isNotNull);
      expect(script.error, isEmpty);
      // The template API creates enabled jobs. Run this probe only against a
      // disposable backend with its scheduler stopped: pausing afterward
      // cannot prevent a scheduler tick between creation and pause.
      final template = templates.singleWhere((t) => t.key == 'morning-brief');
      final templateJob = await repo.instantiate(template, {
        ...template.initialValues,
        'time': '23:47',
        'deliver': 'local',
      });
      own(templateJob.id);
      await repo.action(templateJob.id, 'pause');
      expect(templateJob.prompt, isNotEmpty);
      expect(templateJob.destinations, ['local']);
      expect((await repo.list()).length, initial.length + owned.length);
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/model_choice.dart';
import 'package:wing/core/models/scheduled_task.dart';
import 'package:wing/core/models/scheduled_task_edit.dart';
import 'package:wing/core/services/scheduled_task_edit_session.dart';
import 'package:wing/core/services/scheduled_tasks_controller.dart';
import 'package:wing/core/services/scheduled_tasks_repository.dart';

import 'support/scheduled_tasks_fixture.dart';

void main() {
  late ScheduledTasksFixture fixture;
  late ScheduledTasksController controller;
  final now = DateTime.utc(2026, 10, 3, 12);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fixture = ScheduledTasksFixture();
    controller = ScheduledTasksController(
      ScheduledTasksRepository(fixture.profile),
      await SharedPreferences.getInstance(),
    );
    await controller.refresh();
  });
  tearDown(() {
    controller.dispose();
    fixture.admin.server.close();
  });

  test(
    'unrelated edit preserves raw inherited policy without sending defaults',
    () async {
      fixture.jobs['morning']!.addAll({
        'timezone': null,
        'grace_minutes': '05',
        'catch_up': null,
      });
      await controller.refresh();
      final session = ScheduledTaskEditSession(
        controller,
        original: controller.task('morning'),
      );
      addTearDown(session.dispose);
      session.setText(TaskEditText.name, 'Renamed');
      expect(await session.save(), TaskEditOutcome.confirmed);
      final write = fixture.admin.requests.singleWhere((r) => r.$1 == 'PUT');
      expect(write.$4!['updates'], {'name': 'Renamed'});
      expect(fixture.jobs['morning']!['grace_minutes'], '05');
    },
  );

  test(
    'policy resets are explicit null and false and zero remain real choices',
    () async {
      fixture.jobs['morning']!.addAll({
        'timezone': 'Europe/Paris',
        'grace_minutes': 60,
        'catch_up': true,
      });
      await controller.refresh();
      final session = ScheduledTaskEditSession(
        controller,
        original: controller.task('morning'),
      );
      addTearDown(session.dispose);
      session.setTimezone('');
      session.setGrace('0');
      session.setCatchUp(TaskCatchUp.skip);
      expect(await session.save(), TaskEditOutcome.confirmed);
      final updates = fixture.admin.requests
          .singleWhere((r) => r.$1 == 'PUT')
          .$4!['updates'];
      expect(updates, {
        'timezone': null,
        'grace_minutes': 0,
        'catch_up': false,
      });
    },
  );

  test(
    'invalid grace is retained and non-cron switch requires explicit clearing',
    () async {
      final session = ScheduledTaskEditSession(
        controller,
        original: controller.task('morning'),
      );
      addTearDown(session.dispose);
      session.setGrace('1441');
      expect(await session.save(), TaskEditOutcome.invalid);
      expect(session.state.graceMinutes, '1441');
      session.setGrace('0');
      session.setSchedule(
        session.state.schedule.copyWith(kind: TaskScheduleKind.interval),
      );
      expect(await session.save(), TaskEditOutcome.invalid);
      expect(fixture.mutations, 0);
      session.setGrace('');
      expect(await session.save(), TaskEditOutcome.confirmed);
    },
  );

  test(
    'failed room discovery does not hide platform delivery or change selected room',
    () async {
      fixture.jobs['morning']!['deliver'] = 'local,room:old@work';
      await controller.refresh();
      fixture.admin.rpcOverride = (_, _) async => throw StateError('offline');
      final session = ScheduledTaskEditSession(
        controller,
        original: controller.task('morning'),
      );
      addTearDown(session.dispose);
      await session.load(TaskEditCatalog.delivery);
      await session.load(TaskEditCatalog.rooms);
      expect(session.state.roomError, isNotNull);
      expect(
        session.state.deliveryChoices.any(
          (c) => c.id == 'telegram' && c.discovered,
        ),
        isTrue,
      );
      expect(
        session.state.deliveryChoices
            .singleWhere((c) => c.id == 'room:old@work')
            .selected,
        isTrue,
      );
      session.setText(TaskEditText.name, 'Keep target');
      expect(await session.save(), TaskEditOutcome.confirmed);
      expect(fixture.jobs['morning']!['deliver'], 'local,room:old@work');
    },
  );

  test(
    'name edit preserves an untouched expired one-shot expression exactly',
    () async {
      fixture.jobs['morning']!['schedule'] = {
        'kind': 'once',
        'run_at': '2026-01-01T09:00:00+08:00',
      };
      await controller.refresh();
      final session = ScheduledTaskEditSession(
        controller,
        original: controller.task('morning'),
        now: () => now,
      );
      addTearDown(session.dispose);
      session.setText(TaskEditText.name, 'Renamed');
      expect(await session.save(), TaskEditOutcome.confirmed);
      final write = fixture.admin.requests.singleWhere(
        (request) => request.$1 == 'PUT',
      );
      expect(write.$4!['updates'], {'name': 'Renamed'});
    },
  );

  test(
    'date picker bounds normalize and clamp without editing stored instants',
    () async {
      for (final instant in [
        '2025-11-02T01:30:00-04:00',
        '2046-10-03T09:45:00+08:00',
        '2027-01-01T00:15:00+08:00',
      ]) {
        fixture.jobs['morning']!['schedule'] = {
          'kind': 'once',
          'run_at': instant,
        };
        await controller.refresh();
        final session = ScheduledTaskEditSession(
          controller,
          original: controller.task('morning'),
          now: () => now,
        );
        addTearDown(session.dispose);
        final input = session.datePickerInput;
        final local = DateTime.parse(instant).toLocal();
        expect(input.firstDate, DateTime(2026, 10, 3));
        expect(input.lastDate, DateTime(2036));
        expect(input.initialDate.isBefore(input.firstDate), false);
        expect(input.initialDate.isAfter(input.lastDate), false);
        expect(input.initialDate.hour, 0);
        expect(input.initialTime, local);
        expect(session.state.schedule.expression, instant);
        expect(session.state.dirty, false);
        if (local.isBefore(input.firstDate)) {
          expect(input.initialDate, input.firstDate);
        } else if (local.isAfter(input.lastDate)) {
          expect(input.initialDate, input.lastDate);
        } else {
          expect(
            input.initialDate,
            DateTime(local.year, local.month, local.day),
          );
        }
      }
      final session = ScheduledTaskEditSession(controller, now: () => now);
      addTearDown(session.dispose);
      final input = session.datePickerInput;
      expect(input.initialDate, input.firstDate);
      expect(input.initialTime, now.toLocal());
      expect(session.state.dirty, false);
    },
  );

  test(
    'explicit date and time selection commits a validated local instant',
    () async {
      final session = ScheduledTaskEditSession(controller, now: () => now);
      addTearDown(session.dispose);
      session.setText(TaskEditText.prompt, 'Brief me');
      session.setSchedule(
        session.state.schedule.copyWith(kind: TaskScheduleKind.once),
      );
      session.setOnceDateTime(DateTime(2026, 10, 4), hour: 9, minute: 45);
      expect(session.state.schedule.once, DateTime(2026, 10, 4, 9, 45));
      expect(session.state.dirty, true);
      expect(await session.save(), TaskEditOutcome.confirmed);
      final write = fixture.admin.requests.singleWhere(
        (request) => request.$1 == 'POST' && request.$2 == 'cron/jobs',
      );
      expect(
        write.$4!['schedule'],
        DateTime(2026, 10, 4, 9, 45).toUtc().toIso8601String(),
      );
      final cached = controller.task(fixture.jobs.keys.last)!;
      expect(cached.schedule['kind'], 'once');
      expect(
        DateTime.parse(cached.schedule['run_at'] as String),
        DateTime(2026, 10, 4, 9, 45).toUtc(),
      );
    },
  );

  test(
    'editing an expired one-shot rejects it using the injected clock',
    () async {
      final session = ScheduledTaskEditSession(controller, now: () => now);
      addTearDown(session.dispose);
      session.setText(TaskEditText.prompt, 'Brief me');
      session.setSchedule(
        session.state.schedule.copyWith(kind: TaskScheduleKind.once, once: now),
      );
      expect(await session.save(), TaskEditOutcome.invalid);
      expect(session.state.error, 'Choose a future date and time.');
      expect(fixture.mutations, 0);
    },
  );

  test(
    'opening baseline survives a refreshed external same-field edit',
    () async {
      final session = ScheduledTaskEditSession(
        controller,
        original: controller.task('morning'),
      );
      addTearDown(session.dispose);
      session.setText(TaskEditText.name, 'My draft');
      fixture.jobs['morning']!['name'] = 'Other client';
      await controller.refresh();
      expect(await session.save(), TaskEditOutcome.failed);
      expect(session.state.conflicts, ['name']);
      expect(session.state.name, 'My draft');
      expect(session.state.dirty, true);
      expect(fixture.mutations, 0);
    },
  );

  test(
    'cancelled review keeps exact dirty inputs and does not rebase the opening observation',
    () async {
      final session = ScheduledTaskEditSession(
        controller,
        original: controller.task('morning'),
      );
      addTearDown(session.dispose);
      session.setText(TaskEditText.name, '  My draft  ');
      fixture.jobs['morning']!.addAll({
        'name': 'Other client',
        'prompt': 'Unedited remote prompt',
      });
      expect(await session.save(), TaskEditOutcome.failed);
      final promptBefore = session.state.prompt;
      final review = (await session.reviewConflicts())!;
      expect(review.fields.single.field, TaskConflictField.name);
      expect(review.fields.single.mine, 'My draft');
      expect(review.fields.single.server, 'Other client');
      expect(session.cancelReview(review), TaskReviewOutcome.cancelled);
      expect(session.state.name, '  My draft  ');
      expect(session.state.prompt, promptBefore);
      expect(session.state.dirty, true);
      expect(await session.save(), TaskEditOutcome.failed);
      expect(session.state.conflicts, ['name']);
      expect(fixture.mutations, 0);
      expect(
        session.applyReview(review, {
          TaskConflictField.name: TaskConflictDecision.keepMine,
        }),
        TaskReviewOutcome.retired,
      );
    },
  );

  test(
    'keeping a reviewed name preserves its raw draft and unedited server fields',
    () async {
      final session = ScheduledTaskEditSession(
        controller,
        original: controller.task('morning'),
      );
      addTearDown(session.dispose);
      session.setText(TaskEditText.name, '  My draft  ');
      fixture.jobs['morning']!.addAll({
        'name': 'Other client',
        'prompt': 'Unedited remote prompt',
        'schedule': {'kind': 'once', 'run_at': '2026-01-01T09:00:00+08:00'},
        'deliver': 'telegram',
        'script': 'server-owned.sh',
      });
      expect(await session.save(), TaskEditOutcome.failed);
      final review = (await session.reviewConflicts())!;
      expect(
        session.applyReview(review, {
          TaskConflictField.name: TaskConflictDecision.keepMine,
        }),
        TaskReviewOutcome.applied,
      );
      expect(fixture.mutations, 0);
      expect(session.state.name, '  My draft  ');
      expect(session.state.prompt, 'Unedited remote prompt');
      expect(session.state.schedule.expression, '2026-01-01T09:00:00+08:00');
      expect(await session.save(), TaskEditOutcome.confirmed);
      final write = fixture.admin.requests.singleWhere((r) => r.$1 == 'PUT');
      expect(write.$4!['updates'], {'name': 'My draft'});
      expect(fixture.jobs['morning']!['script'], 'server-owned.sh');
      expect(fixture.jobs['morning']!['deliver'], 'telegram');
      expect(fixture.jobs['morning']!['prompt'], 'Unedited remote prompt');
    },
  );

  test(
    'using the server name preserves a different dirty field for the later sparse save',
    () async {
      final session = ScheduledTaskEditSession(
        controller,
        original: controller.task('morning'),
      );
      addTearDown(session.dispose);
      session.setText(TaskEditText.name, 'My draft');
      session.setText(TaskEditText.prompt, '  My instructions  ');
      fixture.jobs['morning']!['name'] = 'Other client';
      expect(await session.save(), TaskEditOutcome.failed);
      final review = (await session.reviewConflicts())!;
      expect(
        session.applyReview(review, {
          TaskConflictField.name: TaskConflictDecision.useServer,
        }),
        TaskReviewOutcome.applied,
      );
      expect(fixture.mutations, 0);
      expect(session.state.name, 'Other client');
      expect(session.state.prompt, '  My instructions  ');
      expect(session.state.dirty, true);
      expect(await session.save(), TaskEditOutcome.confirmed);
      final write = fixture.admin.requests.singleWhere((r) => r.$1 == 'PUT');
      expect(write.$4!['updates'], {'prompt': 'My instructions'});
    },
  );

  test(
    'every conflict requires an explicit decision before changing intent',
    () async {
      final session = ScheduledTaskEditSession(
        controller,
        original: controller.task('morning'),
      );
      addTearDown(session.dispose);
      session.setText(TaskEditText.name, 'My name');
      session.setText(TaskEditText.prompt, 'My prompt');
      fixture.jobs['morning']!.addAll({
        'name': 'Other name',
        'prompt': 'Other prompt',
      });
      expect(await session.save(), TaskEditOutcome.failed);
      final review = (await session.reviewConflicts())!;
      expect(review.fields.map((field) => field.field), [
        TaskConflictField.name,
        TaskConflictField.prompt,
      ]);
      expect(
        session.applyReview(review, {
          TaskConflictField.name: TaskConflictDecision.keepMine,
        }),
        TaskReviewOutcome.incomplete,
      );
      expect(session.state.name, 'My name');
      expect(session.state.prompt, 'My prompt');
      expect(fixture.mutations, 0);
      expect(
        session.applyReview(review, {
          TaskConflictField.name: TaskConflictDecision.keepMine,
          TaskConflictField.prompt: TaskConflictDecision.useServer,
        }),
        TaskReviewOutcome.applied,
      );
      expect(session.state.prompt, 'Other prompt');
    },
  );

  test(
    'a later remote change conflicts again after explicit reconciliation',
    () async {
      final session = ScheduledTaskEditSession(
        controller,
        original: controller.task('morning'),
      );
      addTearDown(session.dispose);
      session.setText(TaskEditText.name, 'Mine');
      fixture.jobs['morning']!['name'] = 'Remote one';
      expect(await session.save(), TaskEditOutcome.failed);
      final first = (await session.reviewConflicts())!;
      fixture.jobs['morning']!['name'] = 'Remote two';
      expect(
        session.applyReview(first, {
          TaskConflictField.name: TaskConflictDecision.keepMine,
        }),
        TaskReviewOutcome.applied,
      );
      expect(await session.save(), TaskEditOutcome.failed);
      expect(fixture.mutations, 0);
      expect(session.state.name, 'Mine');
      final second = (await session.reviewConflicts())!;
      expect(second.fields.single.server, 'Remote two');
      expect(
        session.applyReview(second, {
          TaskConflictField.name: TaskConflictDecision.keepMine,
        }),
        TaskReviewOutcome.applied,
      );
      expect(await session.save(), TaskEditOutcome.confirmed);
      expect(fixture.mutations, 1);
    },
  );

  test(
    'edited and foreign session drafts cannot consume an older review',
    () async {
      final original = controller.task('morning');
      final session = ScheduledTaskEditSession(controller, original: original);
      final other = ScheduledTaskEditSession(controller, original: original);
      addTearDown(session.dispose);
      addTearDown(other.dispose);
      session.setText(TaskEditText.name, 'Mine');
      other.setText(TaskEditText.name, 'Other local draft');
      fixture.jobs['morning']!['name'] = 'Remote';
      expect(await session.save(), TaskEditOutcome.failed);
      final review = (await session.reviewConflicts())!;
      final keep = {TaskConflictField.name: TaskConflictDecision.keepMine};
      expect(other.applyReview(review, keep), TaskReviewOutcome.retired);
      session.setText(TaskEditText.name, 'A newer draft');
      expect(session.applyReview(review, keep), TaskReviewOutcome.retired);
      expect(session.state.name, 'A newer draft');
      expect(other.state.name, 'Other local draft');
      expect(fixture.mutations, 0);
    },
  );

  test(
    'another review retires an older ticket without altering the draft',
    () async {
      final session = ScheduledTaskEditSession(
        controller,
        original: controller.task('morning'),
      );
      addTearDown(session.dispose);
      session.setText(TaskEditText.name, 'Mine');
      fixture.jobs['morning']!['name'] = 'Remote one';
      expect(await session.save(), TaskEditOutcome.failed);
      final older = (await session.reviewConflicts())!;
      fixture.jobs['morning']!['name'] = 'Remote two';
      final latest = (await session.reviewConflicts())!;
      final decisions = {TaskConflictField.name: TaskConflictDecision.keepMine};
      expect(session.applyReview(older, decisions), TaskReviewOutcome.retired);
      expect(session.state.name, 'Mine');
      expect(latest.fields.single.server, 'Remote two');
      expect(session.applyReview(latest, decisions), TaskReviewOutcome.applied);
      expect(fixture.mutations, 0);
      expect(await session.save(), TaskEditOutcome.confirmed);
      expect(fixture.mutations, 1);
    },
  );

  for (final dispose in [false, true]) {
    test(
      'held review is retired by ${dispose ? 'disposal' : 'a newer draft'}',
      () async {
        final session = ScheduledTaskEditSession(
          controller,
          original: controller.task('morning'),
        );
        if (!dispose) addTearDown(session.dispose);
        session.setText(TaskEditText.name, 'Mine');
        fixture.jobs['morning']!['name'] = 'Remote';
        expect(await session.save(), TaskEditOutcome.failed);
        final entered = Completer<void>();
        final release = Completer<void>();
        final send = fixture.admin.override!;
        fixture.admin.override = (method, path, query, body) async {
          final response = await send(method, path, query, body);
          if (method == 'GET' && path == 'cron/jobs') {
            entered.complete();
            await release.future;
          }
          return response;
        };
        final pending = session.reviewConflicts();
        await entered.future;
        var notifications = 0;
        session.addListener(() => notifications++);
        if (dispose) {
          session.dispose();
        } else {
          session.setText(TaskEditText.prompt, 'Newer local prompt');
        }
        final beforeRelease = notifications;
        release.complete();
        expect(await pending, isNull);
        expect(notifications, beforeRelease);
        expect(fixture.mutations, 0);
        if (!dispose) {
          expect(session.state.name, 'Mine');
          expect(session.state.prompt, 'Newer local prompt');
          expect(session.state.reviewing, false);
        }
      },
    );
  }

  test('disposed tickets cannot rebase or dispatch', () async {
    final session = ScheduledTaskEditSession(
      controller,
      original: controller.task('morning'),
    );
    session.setText(TaskEditText.name, 'Mine');
    fixture.jobs['morning']!['name'] = 'Remote';
    expect(await session.save(), TaskEditOutcome.failed);
    final review = (await session.reviewConflicts())!;
    session.dispose();
    expect(
      session.applyReview(review, {
        TaskConflictField.name: TaskConflictDecision.keepMine,
      }),
      TaskReviewOutcome.retired,
    );
    expect(await session.save(), TaskEditOutcome.disposed);
    expect(fixture.mutations, 0);
  });

  for (final unavailable in ['offline', 'removed', 'wrong owner']) {
    test(
      'review of $unavailable task refuses without changing the draft',
      () async {
        final session = ScheduledTaskEditSession(
          controller,
          original: controller.task('morning'),
        );
        addTearDown(session.dispose);
        session.setText(TaskEditText.name, 'Mine');
        fixture.jobs['morning']!['name'] = 'Remote';
        expect(await session.save(), TaskEditOutcome.failed);
        switch (unavailable) {
          case 'offline':
            fixture.failList = true;
          case 'removed':
            fixture.jobs.remove('morning');
          case 'wrong owner':
            fixture.jobs['morning']!.addAll({
              'profile': 'work',
              'profile_name': 'work',
            });
        }
        expect(await session.reviewConflicts(), isNull);
        expect(session.state.name, 'Mine');
        expect(session.state.dirty, true);
        expect(session.state.error, isNotNull);
        expect(session.state.reviewing, false);
        expect(fixture.mutations, 0);
      },
    );
  }

  for (final edit in ['prompt', 'model']) {
    test(
      'script-only conversion requires a decision over dirty $edit',
      () async {
        final session = ScheduledTaskEditSession(
          controller,
          original: controller.task('morning'),
        );
        addTearDown(session.dispose);
        session.setText(TaskEditText.name, 'My name');
        if (edit == 'prompt') {
          session.setText(TaskEditText.prompt, 'My retained instructions');
        } else {
          session.setModel(
            const ModelSelection.model(
              ModelChoice(provider: 'anthropic', model: 'claude-sonnet-4-5'),
            ),
          );
        }
        fixture.jobs['morning']!.addAll({
          'name': 'Remote name',
          'no_agent': true,
          'script': 'server-owned.sh',
        });
        expect(await session.save(), TaskEditOutcome.failed);
        expect(session.state.dirty, true);
        expect(fixture.mutations, 0);
        final review = (await session.reviewConflicts())!;
        final affected = edit == 'prompt'
            ? TaskConflictField.prompt
            : TaskConflictField.modelRouting;
        expect(review.fields.map((field) => field.field), [
          TaskConflictField.name,
          affected,
        ]);
        expect(review.fields.last.canKeepMine, false);
        expect(
          session.applyReview(review, {
            TaskConflictField.name: TaskConflictDecision.useServer,
          }),
          TaskReviewOutcome.incomplete,
        );
        expect(session.state.scriptOnly, false);
        expect(session.state.dirty, true);
        expect(
          session.applyReview(review, {
            TaskConflictField.name: TaskConflictDecision.useServer,
            affected: TaskConflictDecision.keepMine,
          }),
          TaskReviewOutcome.incomplete,
        );
        expect(session.state.scriptOnly, false);
        expect(await session.save(), TaskEditOutcome.failed);
        expect(session.state.dirty, true);
        expect(fixture.mutations, 0);
        final complete = (await session.reviewConflicts())!;
        expect(
          session.applyReview(complete, {
            TaskConflictField.name: TaskConflictDecision.useServer,
            affected: TaskConflictDecision.useServer,
          }),
          TaskReviewOutcome.applied,
        );
        expect(session.state.scriptOnly, true);
        expect(session.state.dirty, false);
        expect(session.state.prompt, fixture.jobs['morning']!['prompt']);
        expect(session.state.selection.choice, isNull);
        expect(fixture.mutations, 0);
      },
    );
  }

  test(
    'discarding script-only instructions and routing preserves a kept name',
    () async {
      final session = ScheduledTaskEditSession(
        controller,
        original: controller.task('morning'),
      );
      addTearDown(session.dispose);
      session.setText(TaskEditText.name, 'My name');
      session.setText(TaskEditText.prompt, 'My retained instructions');
      session.setModel(
        const ModelSelection.model(
          ModelChoice(provider: 'anthropic', model: 'claude-sonnet-4-5'),
        ),
      );
      fixture.jobs['morning']!.addAll({
        'name': 'Remote name',
        'no_agent': true,
        'script': 'server-owned.sh',
      });
      expect(await session.save(), TaskEditOutcome.failed);
      final review = (await session.reviewConflicts())!;
      expect(review.fields.map((field) => field.field), [
        TaskConflictField.name,
        TaskConflictField.prompt,
        TaskConflictField.modelRouting,
      ]);
      expect(
        session.applyReview(review, {
          TaskConflictField.name: TaskConflictDecision.keepMine,
          TaskConflictField.prompt: TaskConflictDecision.useServer,
        }),
        TaskReviewOutcome.incomplete,
      );
      expect(session.state.prompt, 'My retained instructions');
      expect(session.state.selection.choice!.model, 'claude-sonnet-4-5');
      expect(
        session.applyReview(review, {
          TaskConflictField.name: TaskConflictDecision.keepMine,
          TaskConflictField.prompt: TaskConflictDecision.useServer,
          TaskConflictField.modelRouting: TaskConflictDecision.useServer,
        }),
        TaskReviewOutcome.applied,
      );
      expect(session.state.name, 'My name');
      expect(session.state.dirty, true);
      expect(fixture.mutations, 0);
      expect(await session.save(), TaskEditOutcome.confirmed);
      final write = fixture.admin.requests.singleWhere((r) => r.$1 == 'PUT');
      expect(write.$4!['updates'], {'name': 'My name'});
      expect(fixture.jobs['morning']!['no_agent'], true);
      expect(fixture.jobs['morning']!['script'], 'server-owned.sh');
    },
  );

  test(
    'script-only conversion after review still refuses the next Save',
    () async {
      final session = ScheduledTaskEditSession(
        controller,
        original: controller.task('morning'),
      );
      addTearDown(session.dispose);
      session.setText(TaskEditText.name, 'My name');
      session.setText(TaskEditText.prompt, 'My retained instructions');
      fixture.jobs['morning']!['name'] = 'Remote name';
      expect(await session.save(), TaskEditOutcome.failed);
      final review = (await session.reviewConflicts())!;
      expect(
        session.applyReview(review, {
          TaskConflictField.name: TaskConflictDecision.useServer,
        }),
        TaskReviewOutcome.applied,
      );
      fixture.jobs['morning']!.addAll({
        'no_agent': true,
        'script': 'server-owned.sh',
      });
      expect(await session.save(), TaskEditOutcome.failed);
      expect(session.state.prompt, 'My retained instructions');
      expect(session.state.dirty, true);
      expect(fixture.mutations, 0);
      final nextReview = (await session.reviewConflicts())!;
      expect(nextReview.fields.single.field, TaskConflictField.prompt);
      expect(nextReview.fields.single.canKeepMine, false);
    },
  );

  test(
    'server custom routing can be adopted without losing a separate name edit',
    () async {
      final session = ScheduledTaskEditSession(
        controller,
        original: controller.task('morning'),
      );
      addTearDown(session.dispose);
      session.setText(TaskEditText.name, 'Mine');
      session.setModel(
        const ModelSelection.model(
          ModelChoice(provider: 'anthropic', model: 'claude-sonnet-4-5'),
        ),
      );
      fixture.jobs['morning']!.addAll({
        'base_url': 'https://example.invalid/remote',
        'model': 'remote-model',
        'provider': 'remote-provider',
      });
      expect(await session.save(), TaskEditOutcome.failed);
      final review = (await session.reviewConflicts())!;
      expect(review.fields.single.field, TaskConflictField.modelRouting);
      expect(review.fields.single.canKeepMine, false);
      expect(
        session.applyReview(review, {
          TaskConflictField.modelRouting: TaskConflictDecision.keepMine,
        }),
        TaskReviewOutcome.incomplete,
      );
      expect(session.state.customEndpoint, false);
      expect(
        session.applyReview(review, {
          TaskConflictField.modelRouting: TaskConflictDecision.useServer,
        }),
        TaskReviewOutcome.applied,
      );
      expect(fixture.mutations, 0);
      expect(session.state.customEndpoint, true);
      expect(session.state.selection.choice!.model, 'remote-model');
      expect(session.state.name, 'Mine');
      expect(await session.save(), TaskEditOutcome.confirmed);
      final write = fixture.admin.requests.singleWhere((r) => r.$1 == 'PUT');
      expect(write.$4!['updates'], {'name': 'Mine'});
      expect(
        fixture.jobs['morning']!['base_url'],
        'https://example.invalid/remote',
      );
      expect(fixture.jobs['morning']!['model'], 'remote-model');
    },
  );

  test(
    'converged remote values are explicitly adopted without a PUT',
    () async {
      final session = ScheduledTaskEditSession(
        controller,
        original: controller.task('morning'),
      );
      addTearDown(session.dispose);
      session.setText(TaskEditText.name, 'Mine');
      fixture.jobs['morning']!['name'] = 'Other';
      expect(await session.save(), TaskEditOutcome.failed);
      fixture.jobs['morning']!['name'] = 'Mine';
      final review = (await session.reviewConflicts())!;
      expect(review.fields, isEmpty);
      expect(session.applyReview(review, const {}), TaskReviewOutcome.applied);
      expect(session.state.dirty, false);
      expect(await session.save(), TaskEditOutcome.confirmed);
      expect(fixture.mutations, 0);
    },
  );

  test(
    'model selection writes a pair and conflicts with a new custom endpoint',
    () async {
      final session = ScheduledTaskEditSession(
        controller,
        original: controller.task('morning'),
      );
      addTearDown(session.dispose);
      session.setModel(
        const ModelSelection.model(
          ModelChoice(provider: 'anthropic', model: 'claude-sonnet-4-5'),
        ),
      );
      fixture.jobs['morning']!['base_url'] = 'https://example.invalid/custom';
      expect(await session.save(), TaskEditOutcome.failed);
      expect(session.state.conflicts, ['base_url']);
      expect(fixture.mutations, 0);
    },
  );

  test(
    'destination eligibility retains unavailable choices and the last choice',
    () async {
      fixture.jobs['morning']!['deliver'] = 'custom-target';
      await controller.refresh();
      final session = ScheduledTaskEditSession(
        controller,
        original: controller.task('morning'),
      );
      addTearDown(session.dispose);
      await session.load(TaskEditCatalog.delivery);
      session.setDestination('custom-target', false);
      expect(
        session.state.deliveryChoices
            .singleWhere((choice) => choice.id == 'custom-target')
            .selected,
        true,
      );
      session.setDestination('discord', true);
      expect(
        session.state.deliveryChoices
            .singleWhere((choice) => choice.id == 'discord')
            .selected,
        false,
      );
      session.setDestination('local', true);
      session.setDestination('custom-target', false);
      expect(
        session.state.deliveryChoices
            .where((choice) => choice.selected)
            .map((choice) => choice.id),
        ['local'],
      );
    },
  );

  test(
    'canonical template submission applies defaults without invented fields',
    () async {
      final session = ScheduledTaskEditSession(controller);
      addTearDown(session.dispose);
      await session.load(TaskEditCatalog.blueprints);
      session.setTemplate('morning-brief');
      expect(await session.save(), TaskEditOutcome.confirmed);
      final write = fixture.admin.requests.singleWhere(
        (request) => request.$2 == 'cron/blueprints/instantiate',
      );
      expect(write.$4!['values'], {'time': '08:00', 'deliver': 'local'});
    },
  );

  test('late catalog response cannot replace a newer refresh', () async {
    final first = Completer<void>();
    final entered = Completer<void>();
    var modelRequests = 0;
    final stock = fixture.admin;
    stock.override = (method, path, query, body) async {
      if (path == 'model/options') {
        if (++modelRequests == 1) {
          entered.complete();
          await first.future;
          return {
            'providers': [
              {
                'slug': 'old',
                'name': 'Old',
                'models': ['old-model'],
              },
            ],
          };
        }
        return {
          'providers': [
            {
              'slug': 'new',
              'name': 'New',
              'models': ['new-model'],
            },
          ],
        };
      }
      return stock.send(method, path, query, body);
    };
    final session = ScheduledTaskEditSession(controller);
    await entered.future;
    await session.refreshModels();
    first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(session.state.models!.single.model, 'new-model');
    session.dispose();
  });

  test('disposing a route cannot cancel or forget a dispatched save', () async {
    fixture.gate = Completer<void>();
    final dispatched = Completer<void>();
    fixture.admin.override = (method, path, query, body) {
      final response = fixture.send(method, path, query, body);
      if (method == 'POST' && path == 'cron/jobs') dispatched.complete();
      return response;
    };
    final session = ScheduledTaskEditSession(controller);
    session.setText(TaskEditText.prompt, 'Brief me');
    final result = session.save();
    await dispatched.future;
    expect(fixture.mutations, 1);
    session.dispose();
    expect(controller.blocked('__create__'), true);
    fixture.gate!.complete();
    expect(await result, TaskEditOutcome.disposed);
    expect(controller.blocked('__create__'), false);
    expect(controller.tasks!.any((task) => task.id.startsWith('new-')), true);
  });

  test(
    'uncertain save retains draft and never automatically retries',
    () async {
      fixture.mutationError = TimeoutException('held acknowledgement');
      final session = ScheduledTaskEditSession(controller);
      addTearDown(session.dispose);
      session.setText(TaskEditText.prompt, 'Brief me');
      expect(await session.save(), TaskEditOutcome.uncertain);
      expect(session.state.prompt, 'Brief me');
      expect(session.state.dirty, true);
      expect(await session.save(), TaskEditOutcome.blocked);
      expect(fixture.mutations, 1);
    },
  );
}

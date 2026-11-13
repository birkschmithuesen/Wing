import 'dart:io';
import 'package:wing/core/models/scheduled_task.dart';
import 'package:wing/core/models/scheduled_task_edit.dart';

ScheduledTask row({
  String endpoint = '',
  Map<String, dynamic> extra = const {},
}) => ScheduledTask.fromJson({
  'id': 'morning',
  'profile': 'personal',
  'profile_name': 'personal',
  'enabled': true,
  'state': 'scheduled',
  'name': 'Morning',
  'prompt': 'Brief me',
  'schedule': {'kind': 'cron', 'expr': '0 9 * * *'},
  'model': 'old-model',
  'provider': 'anthropic',
  'base_url': endpoint,
  ...extra,
});

void main() {
  var passed = 0;
  void check(String name, bool condition) {
    if (!condition) throw StateError(name);
    passed++;
  }

  final intent = TaskEditIntent(
    baseline: row(),
    values: {'model': 'new-model'},
  );
  check(
    'new endpoint conflicts with model edit',
    intent
            .resolve(row(endpoint: 'https://example.invalid/custom'))
            .conflicts
            .join(',') ==
        'base_url',
  );
  check(
    'existing custom endpoint cannot be rewritten by model picker',
    TaskEditIntent(
              baseline: row(endpoint: 'https://example.invalid/custom'),
              values: {'model': 'new-model'},
            )
            .resolve(row(endpoint: 'https://example.invalid/custom'))
            .conflicts
            .join(',') ==
        'base_url',
  );
  check(
    'model changes review provider too',
    intent.resolve(row(extra: {'provider': 'other'})).conflicts.join(',') ==
        'provider',
  );
  final pair = intent.resolve(row()).updates;
  check(
    'model route dispatch is a pair',
    pair.length == 2 &&
        pair['model'] == 'new-model' &&
        pair['provider'] == 'anthropic',
  );
  final nameEdit = TaskEditIntent(baseline: row(), values: {'name': 'Mine'});
  final independent = nameEdit.resolve(
    row(extra: {'prompt': 'Another client prompt'}),
  );
  check(
    'independent remote prompt remains unedited',
    independent.conflicts.isEmpty &&
        independent.updates.length == 1 &&
        independent.updates['name'] == 'Mine',
  );
  check(
    'same field conflicts',
    nameEdit.resolve(row(extra: {'name': 'Other'})).conflicts.join(',') ==
        'name',
  );
  final observed = row(
    extra: {
      'name': 'Other',
      'prompt': 'Unedited remote prompt',
      'script': 'server-owned.sh',
    },
  );
  final nameReview = nameEdit.review(observed);
  check(
    'review exposes exact conflicting values without changing intent',
    nameReview.fields.single.field == TaskConflictField.name &&
        nameReview.fields.single.mine == 'Mine' &&
        nameReview.fields.single.server == 'Other' &&
        nameEdit.baseline.name == 'Morning',
  );
  final keptName = nameReview.reconcile({
    TaskConflictField.name: TaskConflictDecision.keepMine,
  });
  final keptNameUpdates = keptName.resolve(observed).updates;
  check(
    'explicit name reconciliation retains only the original edit',
    identical(keptName.baseline, observed) &&
        keptNameUpdates.length == 1 &&
        keptNameUpdates['name'] == 'Mine' &&
        keptName.baseline.prompt == 'Unedited remote prompt' &&
        keptName.baseline.text('script') == 'server-owned.sh',
  );
  check(
    'review does not authorize a later conflicting observation',
    keptName.resolve(row(extra: {'name': 'Changed again'})).conflicts.single ==
        'name',
  );
  final mixedReview = TaskEditIntent(
    baseline: row(),
    values: {'name': 'Mine', 'prompt': 'My prompt'},
  ).review(observed);
  final mixed = mixedReview.reconcile({
    TaskConflictField.name: TaskConflictDecision.useServer,
    TaskConflictField.prompt: TaskConflictDecision.keepMine,
  });
  check(
    'server choice removes only its conflicting edit',
    mixed.values.length == 1 && mixed.values['prompt'] == 'My prompt',
  );
  final providerReview = TaskEditIntent(
    baseline: row(),
    values: {'provider': 'requested-provider'},
  ).review(row(extra: {'model': 'remote-model'}));
  final providerIntent = providerReview.reconcile({
    TaskConflictField.modelRouting: TaskConflictDecision.keepMine,
  });
  final providerPair = providerIntent.resolve(providerIntent.baseline).updates;
  check(
    'review retains the entire originally requested model route',
    providerPair.length == 2 &&
        providerPair['model'] == 'old-model' &&
        providerPair['provider'] == 'requested-provider',
  );
  final scriptTask = row(
    extra: {
      'name': 'Remote name',
      'no_agent': true,
      'script': 'server-owned.sh',
    },
  );
  final scriptIntent = TaskEditIntent(
    baseline: row(),
    values: {'name': 'Mine', 'prompt': 'My prompt', 'model': 'new-model'},
  );
  final scriptReview = scriptIntent.review(scriptTask);
  check(
    'script-only execution change reviews otherwise unchanged edited fields',
    scriptReview.fields.map((field) => field.field).join(',') ==
        [
          TaskConflictField.name,
          TaskConflictField.prompt,
          TaskConflictField.modelRouting,
        ].join(','),
  );
  check(
    'script-only instructions and routing cannot be kept',
    scriptReview.fields.skip(1).every((field) => !field.canKeepMine),
  );
  for (final unsupported in [
    TaskConflictField.prompt,
    TaskConflictField.modelRouting,
  ]) {
    var rejected = false;
    try {
      scriptReview.reconcile({
        TaskConflictField.name: TaskConflictDecision.keepMine,
        TaskConflictField.prompt: TaskConflictDecision.useServer,
        TaskConflictField.modelRouting: TaskConflictDecision.useServer,
        unsupported: TaskConflictDecision.keepMine,
      });
    } on ArgumentError {
      rejected = true;
    }
    check(
      '$unsupported script-only keep decision rejects entire rebase',
      rejected,
    );
  }
  final scriptAdopted = scriptReview.reconcile({
    TaskConflictField.name: TaskConflictDecision.keepMine,
    TaskConflictField.prompt: TaskConflictDecision.useServer,
    TaskConflictField.modelRouting: TaskConflictDecision.useServer,
  });
  check(
    'explicit script-only discard preserves independent kept intent',
    scriptAdopted.values.length == 1 && scriptAdopted.values['name'] == 'Mine',
  );
  check(
    'script-only name update has no hidden execution edits',
    scriptAdopted.resolve(scriptTask).conflicts.isEmpty &&
        scriptAdopted.resolve(scriptTask).updates.length == 1 &&
        scriptAdopted.resolve(scriptTask).updates['name'] == 'Mine',
  );
  check(
    'execution-capability change alone blocks a retained instructions edit',
    TaskEditIntent(baseline: row(), values: {'prompt': 'My prompt'})
        .resolve(row(extra: {'no_agent': true, 'script': 'server-owned.sh'}))
        .conflicts
        .contains('prompt'),
  );

  final endpointReview = TaskEditIntent(
    baseline: row(),
    values: {'name': 'Mine', 'model': 'new-model'},
  ).review(row(endpoint: 'https://example.invalid/current'));
  check(
    'custom routing is a coupled server-only conflict decision',
    endpointReview.fields.single.field == TaskConflictField.modelRouting &&
        !endpointReview.fields.single.canKeepMine,
  );
  final endpointAdopted = endpointReview.reconcile({
    TaskConflictField.modelRouting: TaskConflictDecision.useServer,
  });
  check(
    'adopting custom routing does not lose an independent name edit',
    endpointAdopted.values.length == 1 &&
        endpointAdopted.values['name'] == 'Mine',
  );
  for (final (reason, invalid) in <(String, void Function())>[
    (
      'incomplete review',
      () => mixedReview.reconcile({
        TaskConflictField.name: TaskConflictDecision.keepMine,
      }),
    ),
    (
      'unsupported routing decision',
      () => endpointReview.reconcile({
        TaskConflictField.modelRouting: TaskConflictDecision.keepMine,
      }),
    ),
    (
      'foreign-owner review',
      () => nameEdit.review(
        row(extra: {'profile': 'work', 'profile_name': 'work'}),
      ),
    ),
  ]) {
    var rejected = false;
    try {
      invalid();
    } on ArgumentError {
      rejected = true;
    }
    check('$reason is rejected', rejected);
  }
  check(
    'already converged desired field has no write',
    nameEdit.resolve(row(extra: {'name': 'Mine'})).updates.isEmpty,
  );
  final onceBaseline = row(
    extra: {
      'schedule': {'kind': 'once', 'run_at': '2026-10-05T09:45:00+00:00'},
    },
  );
  final onceDesired = TaskEditIntent(
    baseline: onceBaseline,
    values: {'schedule': '2026-10-04T09:45:00.000Z'},
  );
  final onceCurrent = row(
    extra: {
      'schedule': {'kind': 'once', 'run_at': '2026-10-04T09:45:00+00:00'},
    },
  );
  final convergedOnce = onceDesired.resolve(onceCurrent);
  check(
    'stock UTC spellings converge without conflict or write',
    convergedOnce.conflicts.isEmpty && convergedOnce.updates.isEmpty,
  );
  check(
    'same-instant explicit reselect is unchanged',
    TaskEditIntent(
      baseline: onceCurrent,
      values: {'schedule': '2026-10-04T17:45:00.000000+08:00'},
    ).values.isEmpty,
  );
  check(
    'timestamp comparison retains microsecond precision',
    onceDesired
            .resolve(
              row(
                extra: {
                  'schedule': {
                    'kind': 'once',
                    'run_at': '2026-10-04T09:45:00.000001+00:00',
                  },
                },
              ),
            )
            .conflicts
            .join(',') ==
        'schedule',
  );
  check(
    'invalid calendar input does not normalize as another date',
    ScheduledTask.normalizeEdit('schedule', '2026-99-04T09:45:00Z') ==
        '2026-99-04T09:45:00Z',
  );
  check(
    'cron expressions retain exact expression semantics',
    ScheduledTask.normalizeEdit('schedule', '0 9 * * *') == '0 9 * * *',
  );
  final input = <String, dynamic>{'name': 'Captured'};
  final captured = TaskEditIntent(baseline: row(), values: input);
  input['name'] = 'Later';
  check(
    'intent copies mutable caller input',
    captured.values['name'] == 'Captured',
  );
  check(
    'scope mismatch cannot resolve',
    nameEdit
            .resolve(row(extra: {'profile': 'work', 'profile_name': 'work'}))
            .conflicts
            .join(',') ==
        'ownership',
  );
  final past = TaskScheduleDraft.open(
    row(
      extra: {
        'schedule': {'kind': 'once', 'run_at': '2026-01-01T09:00:00+08:00'},
      },
    ),
  );
  check(
    'untouched expired once preserves exact input',
    past.expression == '2026-01-01T09:00:00+08:00' &&
        past.validate(DateTime.utc(2026, 10, 3)) == null,
  );
  final future = past.copyWith(once: DateTime.utc(2026, 10, 4, 9));
  check(
    'edited once encodes UTC and validates injected time',
    future.expression == '2026-10-04T09:00:00.000Z' &&
        future.validate(DateTime.utc(2026, 10, 3)) == null,
  );
  check(
    'edited past once is rejected',
    past.copyWith().validate(DateTime.utc(2026, 10, 3)) ==
        'Choose a future date and time.',
  );
  final interval = TaskScheduleDraft.open(
    row(
      extra: {
        'schedule': {'kind': 'interval', 'minutes': 30.5},
      },
    ),
  );
  check(
    'untouched fractional stock interval stays exact',
    interval.expression == 'every 30.5m' &&
        interval.validate(DateTime.utc(2026)) == null,
  );
  final weekdays = TaskScheduleDraft.open(
    row(
      extra: {
        'schedule': {'kind': 'cron', 'expr': '30 17 * * 1-5'},
      },
    ),
  );
  check(
    'cron decomposes into typed input',
    weekdays.kind == TaskScheduleKind.weekdays &&
        weekdays.hour == 17 &&
        weekdays.minute == 30 &&
        weekdays.expression == '30 17 * * 1-5',
  );
  Map<String, dynamic> field({bool strict = true, bool optional = false}) => {
    'name': 'choice',
    'label': 'Choice',
    'help': '',
    'default': 'one',
    'type': 'enum',
    'options': ['one', 'two'],
    'strict': strict,
    'optional': optional,
  };
  check(
    'strict options reject invented value',
    TaskTemplateField.fromJson(field()).validate('three') == 'Choose Choice.',
  );
  check(
    'suggested options permit custom value',
    TaskTemplateField.fromJson(field(strict: false)).validate('three') == null,
  );
  final optional = TaskTemplate.fromJson({
    'key': 'synthetic-optional',
    'title': 'Unit slot semantics',
    'description': 'Not an advertised fixture blueprint',
    'fields': [field(optional: true)],
  });
  check(
    'empty optional field is omitted from submission',
    optional.submission({'choice': ''}, 'local').isEmpty,
  );
  final ranked = visibleScheduledTasks(
    [
      row(extra: {'id': 'paused', 'state': 'paused', 'enabled': false}),
      row(extra: {'id': 'later', 'next_run_at': '2026-10-05T09:00:00Z'}),
      row(extra: {'id': 'attention', 'last_error': 'failed'}),
      row(
        extra: {
          'id': 'running',
          'state': 'scheduled',
          'live_execution': {'id': 'live-run', 'status': 'running'},
          'latest_execution': {'id': 'rejected-trigger', 'status': 'rejected'},
        },
      ),
      row(extra: {'id': 'earlier', 'next_run_at': '2026-10-04T09:00:00Z'}),
    ],
    '',
    TaskListFilter.all,
  );
  check(
    'task status and next-run ranking is stable',
    ranked.map((task) => task.id).join(',') ==
        'running,attention,earlier,later,paused',
  );
  stdout.writeln(
    'Task intent/schedule/template projection: $passed checks passed',
  );
}

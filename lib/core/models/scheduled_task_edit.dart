import 'scheduled_task.dart';

/// Immutable user intent, resolved once against fresh scoped membership.
/// Reading a newer row never replaces the opening baseline or edits.
class TaskEditIntent {
  TaskEditIntent({required this.baseline, required Map<String, dynamic> values})
    : values = Map.unmodifiable(baseline.changes(values)) {
    if (values.entries.any(
      (entry) =>
          !const {
            'name',
            'prompt',
            'schedule',
            'deliver',
            'model',
            'provider',
            'timezone',
            'grace_minutes',
            'catch_up',
          }.contains(entry.key) ||
          entry.value != null &&
              !(switch (entry.key) {
                'catch_up' => entry.value is bool,
                'grace_minutes' => entry.value is int,
                _ => entry.value is String,
              }),
    )) {
      throw ArgumentError('Task edits require scalar editable fields');
    }
  }
  final ScheduledTask baseline;
  final Map<String, dynamic> values;

  /// A fresh observation does not change intent. Only a complete, explicit
  /// decision over this review can establish a new baseline.
  TaskEditReview review(ScheduledTask current) =>
      TaskEditReview._(this, current);

  TaskEditResolution resolve(ScheduledTask current) {
    if (current.id != baseline.id ||
        current.profileName != baseline.profileName) {
      return TaskEditResolution(const {}, const ['ownership']);
    }
    final desired = {...values};
    final fields = desired.keys.toSet();
    final routeChanged =
        fields.contains('model') || fields.contains('provider');
    if (routeChanged) {
      fields.addAll({'model', 'provider'});
      desired.putIfAbsent('model', () => baseline.editableValue('model'));
      desired.putIfAbsent('provider', () => baseline.editableValue('provider'));
    }
    final conflicts = fields
        .where(
          (key) =>
              current.editableValue(key) != baseline.editableValue(key) &&
              current.editableValue(key) !=
                  ScheduledTask.normalizeEdit(key, desired[key]),
        )
        .toList();
    if (routeChanged &&
        (baseline.text('base_url').isNotEmpty ||
            current.text('base_url') != baseline.text('base_url'))) {
      conflicts.add('base_url');
    }
    // A script-only task cannot execute these retained edits. Even unchanged
    // wire values require an explicit discard before adopting that mode.
    if (current.scriptOnly) {
      if (fields.contains('prompt') && !conflicts.contains('prompt')) {
        conflicts.add('prompt');
      }
      if (routeChanged &&
          !conflicts.contains('model') &&
          !conflicts.contains('provider')) {
        conflicts.add('model');
      }
    }
    final updates = current.changes(desired);
    if (routeChanged &&
        (updates.containsKey('model') || updates.containsKey('provider'))) {
      updates.addAll({
        'model': desired['model'],
        'provider': desired['provider'],
      });
    }
    return TaskEditResolution(updates, conflicts);
  }
}

class TaskEditResolution {
  TaskEditResolution(Map<String, dynamic> updates, Iterable<String> conflicts)
    : updates = Map.unmodifiable(updates),
      conflicts = List.unmodifiable(conflicts);
  final Map<String, dynamic> updates;
  final List<String> conflicts;
}

enum TaskConflictField {
  name,
  prompt,
  schedule,
  delivery,
  timezone,
  grace,
  catchUp,
  modelRouting;

  Set<String> get keys => switch (this) {
    name => const {'name'},
    prompt => const {'prompt'},
    schedule => const {'schedule'},
    delivery => const {'deliver'},
    timezone => const {'timezone'},
    grace => const {'grace_minutes'},
    catchUp => const {'catch_up'},
    modelRouting => const {'model', 'provider', 'base_url'},
  };
}

enum TaskConflictDecision { keepMine, useServer }

/// Passive, exact values for one coupled conflict. Endpoint routing is managed
/// on Hermes, so a picker cannot overwrite a newly observed custom endpoint.
class TaskConflictObservation {
  const TaskConflictObservation({
    required this.field,
    required this.mine,
    required this.server,
    required this.keepMineUnavailableReason,
  });
  final TaskConflictField field;
  final String mine, server;
  final String? keepMineUnavailableReason;
  bool get canKeepMine => keepMineUnavailableReason == null;
}

/// A pure review of captured sparse intent against one immutable observation.
/// It performs no write; caller lifetime and draft identity belong to the edit
/// session. Unedited remote values are never manufactured into new user edits.
class TaskEditReview {
  TaskEditReview._(this._intent, this.current) {
    final conflicts = _intent.resolve(current).conflicts.toSet();
    if (conflicts.contains('ownership')) {
      throw ArgumentError('Cannot review a task from another owner');
    }
    fields = List.unmodifiable([
      for (final field in TaskConflictField.values)
        if (field.keys.any(conflicts.contains))
          TaskConflictObservation(
            field: field,
            mine: _display(field, desired: true),
            server: _display(field, desired: false),
            keepMineUnavailableReason: _keepMineUnavailableReason(field),
          ),
    ]);
  }
  final TaskEditIntent _intent;
  final ScheduledTask current;
  late final List<TaskConflictObservation> fields;

  String? _keepMineUnavailableReason(TaskConflictField field) {
    if (current.scriptOnly &&
        (field == TaskConflictField.prompt ||
            field == TaskConflictField.modelRouting)) {
      return field == TaskConflictField.prompt
          ? 'This task now runs only its script. Use server to discard your instructions edit and keep your other edits.'
          : 'This task now runs only its script. Use server to discard your model edit and keep your other edits.';
    }
    if (field == TaskConflictField.modelRouting &&
        current.text('base_url').isNotEmpty) {
      return 'This task’s routing is managed on Hermes. Use its current routing to keep your other edits.';
    }
    return null;
  }

  String _display(TaskConflictField field, {required bool desired}) {
    String value(String key) {
      if (desired && _intent.values.containsKey(key)) {
        return _intent.values[key]?.toString() ?? 'Hermes default';
      }
      final task = desired ? _intent.baseline : current;
      return key == 'schedule'
          ? task.scheduleInput
          : task.data[key]?.toString() ?? 'Hermes default';
    }

    return switch (field) {
      TaskConflictField.name => value('name'),
      TaskConflictField.prompt => value('prompt'),
      TaskConflictField.schedule => value('schedule'),
      TaskConflictField.delivery => value('deliver'),
      TaskConflictField.timezone => value('timezone'),
      TaskConflictField.grace => value('grace_minutes'),
      TaskConflictField.catchUp => value('catch_up'),
      TaskConflictField.modelRouting =>
        value('model').isEmpty
            ? 'Profile default'
            : '${value('provider')} / ${value('model')}'
                  '${!desired && current.text('base_url').isNotEmpty ? '\nCustom endpoint on Hermes' : ''}',
    };
  }

  TaskEditIntent reconcile(
    Map<TaskConflictField, TaskConflictDecision> decisions,
  ) {
    if (decisions.length != fields.length ||
        fields.any((field) => !decisions.containsKey(field.field))) {
      throw ArgumentError('Choose a decision for every reviewed conflict');
    }
    final retained = {..._intent.values};
    if (retained.containsKey('model') || retained.containsKey('provider')) {
      retained.putIfAbsent('model', () => _intent.baseline.text('model'));
      retained.putIfAbsent('provider', () => _intent.baseline.text('provider'));
    }
    for (final field in fields) {
      final decision = decisions[field.field]!;
      if (decision == TaskConflictDecision.keepMine && !field.canKeepMine) {
        throw ArgumentError(field.keepMineUnavailableReason!);
      }
      if (decision == TaskConflictDecision.useServer) {
        for (final key in field.field.keys) {
          retained.remove(key);
        }
      }
    }
    return TaskEditIntent(baseline: current, values: retained);
  }
}

/// Schedule input is separate from the exact opening expression. An untouched
/// one-shot or interval is never rebuilt or re-anchored by a name/model edit.
class TaskScheduleDraft {
  const TaskScheduleDraft({
    this.kind = TaskScheduleKind.daily,
    this.hour = 9,
    this.minute = 0,
    this.weekday = 1,
    this.monthDay = 1,
    this.minutes = '30',
    this.once,
    this.custom = '',
    this.changed = false,
    this.originalExpression,
  });
  factory TaskScheduleDraft.open(ScheduledTask? task) {
    if (task == null) return const TaskScheduleDraft();
    final schedule = task.schedule;
    final initial = TaskScheduleDraft(
      kind: TaskScheduleKind.custom,
      custom: task.scheduleInput,
      originalExpression: task.scheduleInput,
    );
    if (schedule['kind'] == 'interval' && schedule['minutes'] is num) {
      return initial.copyWith(
        kind: TaskScheduleKind.interval,
        minutes: '${schedule['minutes']}',
        changed: false,
      );
    }
    if (schedule['kind'] == 'once') {
      final once = DateTime.tryParse(
        schedule['run_at'] as String? ?? '',
      )?.toLocal();
      return once == null
          ? initial
          : initial.copyWith(
              kind: TaskScheduleKind.once,
              once: once,
              changed: false,
            );
    }
    if (schedule['kind'] != 'cron') return initial;
    final expr = task.scheduleInput;
    if (expr == '0 * * * *') {
      return initial.copyWith(kind: TaskScheduleKind.hourly, changed: false);
    }
    if (expr == '*/15 * * * *') {
      return initial.copyWith(
        kind: TaskScheduleKind.quarterHourly,
        changed: false,
      );
    }
    final parts = expr.trim().split(RegExp(r'\s+'));
    if (parts.length != 5 || parts[3] != '*') return initial;
    final minute = int.tryParse(parts[0]), hour = int.tryParse(parts[1]);
    if (minute == null ||
        hour == null ||
        minute < 0 ||
        minute > 59 ||
        hour < 0 ||
        hour > 23) {
      return initial;
    }
    final clock = initial.copyWith(hour: hour, minute: minute, changed: false);
    if (parts[2] == '*') {
      if (parts[4] == '*') {
        return clock.copyWith(kind: TaskScheduleKind.daily, changed: false);
      }
      if (parts[4] == '1-5') {
        return clock.copyWith(kind: TaskScheduleKind.weekdays, changed: false);
      }
      final day = int.tryParse(parts[4]);
      if (day != null && day >= 0 && day <= 6) {
        return clock.copyWith(
          kind: TaskScheduleKind.weekly,
          weekday: day,
          changed: false,
        );
      }
    } else if (parts[4] == '*') {
      final day = int.tryParse(parts[2]);
      if (day != null && day >= 1 && day <= 31) {
        return clock.copyWith(
          kind: TaskScheduleKind.monthly,
          monthDay: day,
          changed: false,
        );
      }
    }
    return initial;
  }
  final TaskScheduleKind kind;
  final int hour, minute, weekday, monthDay;
  final String minutes, custom;
  final DateTime? once;
  final bool changed;
  final String? originalExpression;
  bool get usesClock => const {
    TaskScheduleKind.daily,
    TaskScheduleKind.weekdays,
    TaskScheduleKind.weekly,
    TaskScheduleKind.monthly,
  }.contains(kind);
  TaskScheduleDraft copyWith({
    TaskScheduleKind? kind,
    int? hour,
    int? minute,
    int? weekday,
    int? monthDay,
    String? minutes,
    DateTime? once,
    String? custom,
    bool changed = true,
  }) => TaskScheduleDraft(
    kind: kind ?? this.kind,
    hour: hour ?? this.hour,
    minute: minute ?? this.minute,
    weekday: weekday ?? this.weekday,
    monthDay: monthDay ?? this.monthDay,
    minutes: minutes ?? this.minutes,
    once: once ?? this.once,
    custom: custom ?? this.custom,
    changed: changed,
    originalExpression: originalExpression,
  );
  String get expression => !changed && originalExpression != null
      ? originalExpression!
      : taskScheduleExpression(
          kind,
          hour: hour,
          minute: minute,
          weekday: weekday,
          monthDay: monthDay,
          minutes: int.tryParse(minutes) ?? 0,
          once: once,
          custom: custom,
        );
  String? validate(DateTime now) {
    if (!changed && originalExpression != null) return null;
    if (expression.isEmpty) return 'Enter a schedule.';
    if ((kind == TaskScheduleKind.interval || kind == TaskScheduleKind.delay) &&
        (int.tryParse(minutes) ?? 0) <= 0) {
      return 'Enter a positive number of minutes.';
    }
    if (kind == TaskScheduleKind.once &&
        (once == null || !once!.isAfter(now))) {
      return 'Choose a future date and time.';
    }
    if (usesClock && (hour < 0 || hour > 23 || minute < 0 || minute > 59) ||
        kind == TaskScheduleKind.weekly && (weekday < 0 || weekday > 6) ||
        kind == TaskScheduleKind.monthly && (monthDay < 1 || monthDay > 31)) {
      return 'Choose a valid schedule.';
    }
    return null;
  }

  String summary(String clockLabel) => switch (kind) {
    TaskScheduleKind.daily => 'Every day at $clockLabel',
    TaskScheduleKind.weekdays => 'Monday–Friday at $clockLabel',
    TaskScheduleKind.weekly =>
      'Every ${const ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'][weekday]} at $clockLabel',
    TaskScheduleKind.monthly => 'Day $monthDay of each month at $clockLabel',
    TaskScheduleKind.hourly => 'Every hour, on the hour',
    TaskScheduleKind.quarterHourly => 'Every hour at :00, :15, :30 and :45',
    TaskScheduleKind.interval => 'Repeats every $minutes minutes',
    TaskScheduleKind.delay => 'Runs once, $minutes minutes after creation',
    TaskScheduleKind.once =>
      once == null
          ? 'Choose when this task should run once.'
          : 'Runs once at the selected phone time',
    TaskScheduleKind.custom => custom,
  };
}

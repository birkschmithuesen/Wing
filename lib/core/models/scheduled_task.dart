import 'hermes_profile.dart';

/// Captured failure and destination; navigation never borrows ambient selection.
class ScheduledTaskInvestigationRequest {
  const ScheduledTaskInvestigationRequest({
    required this.owner,
    required this.task,
  });
  final WorkspaceScope owner;
  final ScheduledTask task;
}

/// Current Hermes scheduled-task contract. Display strings never become writes.
class ScheduledTask {
  ScheduledTask.fromJson(Map<String, dynamic> value)
    : profileName = _taskProfile(value),
      data = _immutableTaskValue(value) as Map<String, dynamic> {
    if (value['id'] is! String ||
        (value['id'] as String).isEmpty ||
        value['enabled'] is! bool ||
        value['schedule'] is! Map) {
      throw const FormatException('Invalid scheduled task');
    }
    TaskExecution.decode(value['live_execution']);
    TaskExecution.decode(value['latest_execution']);
  }

  final Map<String, dynamic> data;
  final String profileName;
  String get id => data['id'] as String;
  String text(String key) => data[key] is String ? data[key] as String : '';
  String get name => text('name');
  String get title => name.isEmpty ? 'Untitled task' : name;
  String get prompt => text('prompt');
  String get state => text('state');
  bool get enabled => data['enabled'] == true;
  TaskExecution? get liveExecution =>
      TaskExecution.decode(data['live_execution']);
  TaskExecution? get latestExecution =>
      TaskExecution.decode(data['latest_execution']);
  bool get running => liveExecution?.live == true;
  bool get canStop => running;
  String get timezoneLabel =>
      text('timezone').isEmpty ? 'Hermes profile timezone' : text('timezone');
  String get catchUpLabel => switch (data['catch_up']) {
    true => 'Run one catch-up',
    false => 'Skip missed runs',
    _ => 'Hermes default',
  };
  String get graceLabel => data['grace_minutes'] == null
      ? 'Computed window'
      : data['grace_minutes'] == 0
      ? 'No grace window'
      : '${data['grace_minutes']} minutes';
  bool get paused => state == 'paused';
  bool get knownState => const {
    'scheduled',
    'running',
    'paused',
    'completed',
    'error',
    'disabled',
    'enabled',
  }.contains(state);
  bool get canRun =>
      knownState && !running && state != 'running' && state != 'completed';
  bool get canPause => knownState && enabled && state != 'completed';
  bool get canResume => paused || state == 'disabled';
  bool get scriptOnly => data['no_agent'] == true;
  bool get hasServerExecution =>
      text('script').isNotEmpty ||
      (data['skills'] is List && (data['skills'] as List).isNotEmpty);
  String get statusLabel => running
      ? 'Running'
      : switch (state) {
          'scheduled' || 'enabled' => 'Scheduled',
          'paused' => 'Paused',
          'disabled' => 'Disabled',
          'running' => 'Run status unavailable',
          'error' => 'Needs attention',
          'completed' => 'Completed',
          _ => 'Status unavailable',
        };
  String get error => text('last_error');
  bool get needsAttention =>
      !const {'cancelled', 'missed'}.contains(text('last_status')) &&
      (error.isNotEmpty || state == 'error');
  DateTime? get nextRun => DateTime.tryParse(text('next_run_at'));
  DateTime? get lastRun => DateTime.tryParse(text('last_run_at'));
  String get failureInvestigationPrompt {
    final recordedTime = lastRun?.toIso8601String();
    final when = recordedTime == null
        ? 'whose run time was not recorded'
        : 'that ran at $recordedTime';
    return 'The last run of scheduled task "$title" (task ID: $id) in '
        'profile "$profileName", $when, failed with this error:\n\n'
        '$error\n\nPlease investigate the failure and explain what went wrong.';
  }

  Map<String, dynamic> get schedule =>
      Map<String, dynamic>.from(data['schedule'] as Map);
  String get scheduleLabel => text('schedule_display');
  String get scheduleInput => switch (schedule['kind']) {
    'cron' => schedule['expr'] as String? ?? '',
    'interval' => 'every ${schedule['minutes']}m',
    'once' => schedule['run_at'] as String? ?? '',
    _ => '',
  };
  List<String> get destinations => text(
    'deliver',
  ).split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet().toList();
  String? get listStatusText => running
      ? 'Working on it now'
      : !knownState
      ? 'Status unavailable'
      : state == 'completed'
      ? 'No further runs'
      : state == 'disabled'
      ? 'Schedule disabled'
      : paused
      ? 'Schedule paused'
      : null;
  String get nextRunHeading => running
      ? 'IN PROGRESS'
      : !knownState || state == 'completed' || state == 'disabled'
      ? statusLabel.toUpperCase()
      : paused
      ? 'ON PAUSE'
      : 'NEXT RUN';
  String? get nextRunText => running
      ? 'Your agent is working'
      : !knownState
      ? 'Schedule status unavailable'
      : state == 'completed'
      ? 'No further runs'
      : state == 'disabled'
      ? 'Schedule disabled'
      : !enabled
      ? 'Ready when you are'
      : null;
  String get instructionsDisplay => prompt.isNotEmpty
      ? prompt
      : scriptOnly
      ? 'Runs a server script without an agent.'
      : 'Uses the task’s server-side execution settings.';
  String get destinationsDisplay => destinations
      .map((id) => id == 'local' ? 'Saved on server' : id)
      .join(' · ');
  String get modelDisplay => scriptOnly
      ? 'No agent'
      : text('model').isEmpty
      ? 'Profile default at run time'
      : '${text('provider')} / ${text('model')}';
  List<String> get skills => List.unmodifiable(
    (data['skills'] as List?)?.cast<String>() ?? const <String>[],
  );
  List<String> get contextFrom => List.unmodifiable(
    (data['context_from'] as List?)?.cast<String>() ?? const <String>[],
  );

  /// Only changed editable fields are sent; an unchanged interval/one-shot must
  /// not be re-anchored, and advanced execution settings stay server-owned.
  Map<String, dynamic> changes(Map<String, dynamic> values) => {
    for (final entry in values.entries)
      if (editableValue(entry.key) != normalizeEdit(entry.key, entry.value))
        entry.key: entry.value,
  };

  Object? editableValue(String key) =>
      normalizeEdit(key, key == 'schedule' ? scheduleInput : data[key]);

  static Object? normalizeEdit(String key, Object? value) {
    if (key == 'schedule' && value is String) {
      final instant = _awareOnceMicroseconds(value);
      if (instant != null) return (onceMicrosecondsUtc: instant);
    }
    return const {
          'name',
          'prompt',
          'schedule',
          'deliver',
          'model',
          'provider',
        }.contains(key)
        ? value ?? ''
        : value;
  }

  // Stock emits aware ISO timestamps; the picker emits UTC ISO. Compare their
  // instant without replacing either wire text. Naive times need profile-zone
  // authority, and non-timestamp expressions retain exact expression semantics.
  static final _awareOnce = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$',
  );
  static int? _awareOnceMicroseconds(String value) {
    final match = _awareOnce.firstMatch(value);
    if (match == null) return null;
    final parts = [for (var i = 1; i <= 6; i++) int.parse(match[i]!)];
    final wall = DateTime.utc(
      parts[0],
      parts[1],
      parts[2],
      parts[3],
      parts[4],
      parts[5],
    );
    final offset = match[7]!;
    if (parts[0] < 1 ||
        wall.year != parts[0] ||
        wall.month != parts[1] ||
        wall.day != parts[2] ||
        wall.hour != parts[3] ||
        wall.minute != parts[4] ||
        wall.second != parts[5] ||
        offset != 'Z' &&
            (int.parse(offset.substring(1, 3)) > 23 ||
                int.parse(offset.substring(4)) > 59)) {
      return null;
    }
    return DateTime.tryParse(value)?.microsecondsSinceEpoch;
  }
}

/// Independent ledger observations: latest attempt need not be the live attempt.
class TaskExecution {
  const TaskExecution(this.id, this.status, this.reason);
  final String id, status, reason;
  bool get live => status == 'claimed' || status == 'running';
  String get label => switch (status) {
    'claimed' => 'Starting',
    'running' => 'Running',
    'completed' => 'Completed',
    'failed' => 'Failed',
    'cancelled' => 'Cancelled',
    'missed' => 'Missed',
    'rejected' => 'Rejected',
    _ => 'Outcome unavailable',
  };
  static TaskExecution? decode(Object? value) {
    if (value == null) return null;
    if (value is! Map ||
        value['id'] is! String ||
        (value['id'] as String).isEmpty ||
        value['status'] is! String) {
      throw const FormatException('Invalid scheduled execution');
    }
    return TaskExecution(
      value['id'] as String,
      value['status'] as String,
      value['error'] is String ? value['error'] as String : '',
    );
  }
}

class TaskCancellation {
  const TaskCancellation(this.requested, this.executionId);
  final bool requested;
  final String? executionId;
  String get notice => requested
      ? 'Stop requested. The run stops at its next cancellation check. The schedule is unchanged.'
      : 'No run is in flight. The schedule is unchanged.';
}

enum TaskListFilter {
  all('All'),
  active('Active'),
  paused('Paused'),
  attention('Needs attention');

  const TaskListFilter(this.label);
  final String label;
}

enum TaskAction { edit, pause, resume, trigger, cancel, remove }

class TaskConfirmation {
  const TaskConfirmation(this.title, this.message, this.buttonLabel);
  final String title, message, buttonLabel;
}

class TaskActionChoice {
  const TaskActionChoice(
    this.kind,
    this.label,
    this.enabled, {
    this.confirmation,
  });
  final TaskAction kind;
  final String label;
  final bool enabled;
  final TaskConfirmation? confirmation;
}

/// Domain status/ranking projection; query/filter selection is view input.
List<ScheduledTask> visibleScheduledTasks(
  Iterable<ScheduledTask> tasks,
  String query,
  TaskListFilter filter,
) {
  final normalized = query.toLowerCase().trim();
  int rank(ScheduledTask task) => task.running
      ? 0
      : task.needsAttention
      ? 1
      : task.enabled && task.state != 'completed'
      ? 2
      : 3;
  final result =
      tasks
          .where(
            (task) =>
                '${task.title} ${task.prompt} ${task.scheduleLabel}'
                    .toLowerCase()
                    .contains(normalized) &&
                switch (filter) {
                  TaskListFilter.active =>
                    task.enabled && task.state != 'completed',
                  TaskListFilter.paused =>
                    task.paused || task.state == 'disabled',
                  TaskListFilter.attention => task.needsAttention,
                  TaskListFilter.all => true,
                },
          )
          .toList()
        ..sort((a, b) {
          final byRank = rank(a).compareTo(rank(b));
          if (byRank != 0) return byRank;
          if (rank(a) == 2) {
            final time = (a.nextRun?.millisecondsSinceEpoch ?? 8640000000000000)
                .compareTo(
                  b.nextRun?.millisecondsSinceEpoch ?? 8640000000000000,
                );
            if (time != 0) return time;
          }
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });
  return List.unmodifiable(result);
}

String _taskProfile(Map<String, dynamic> value) {
  final profile = value['profile'];
  if (profile is! String ||
      profile.isEmpty ||
      value['profile_name'] != profile) {
    throw const FormatException('Invalid scheduled task profile ownership');
  }
  return profile;
}

Object? _immutableTaskValue(Object? value) => switch (value) {
  Map value => Map<String, dynamic>.unmodifiable({
    for (final entry in value.entries)
      entry.key as String: _immutableTaskValue(entry.value),
  }),
  List value => List<Object?>.unmodifiable(value.map(_immutableTaskValue)),
  _ => value,
};

class TaskDeliveryTarget {
  const TaskDeliveryTarget.room({required this.id, required this.name})
    : configured = true;
  TaskDeliveryTarget.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      name = json['name'] as String,
      configured = json['home_target_set'] == true;
  final String id, name;
  final bool configured;
  bool get isRoom => id.startsWith('room:');
  String get label => id == 'local' ? 'Save on server' : name;
}

class TaskRun {
  TaskRun.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      source = json['source'] as String,
      title = json['title'] as String? ?? '',
      preview = json['preview'] as String? ?? '',
      active = json['is_active'] == true,
      started = json['started_at'] is num
          ? DateTime.fromMillisecondsSinceEpoch(
              ((json['started_at'] as num) * 1000).round(),
              isUtc: true,
            )
          : null;
  final String id, source, title, preview;
  final bool active;
  final DateTime? started;
  bool get isConversation => source == 'cron';
  bool get isScriptOutput => source == 'cron_output';
}

enum TaskTemplateFieldKind { text, time, choice, weekdays, unsupported }

/// Stock form metadata; validation and widget choice never inspect raw maps.
class TaskTemplateField {
  TaskTemplateField.fromJson(Map<String, dynamic> json)
    : name = json['name'] as String,
      label = json['label'] as String,
      help = json['help'] as String,
      defaultValue = json['default'] as String?,
      optional = json['optional'] as bool,
      strict = json['strict'] as bool,
      options = List.unmodifiable((json['options'] as List).cast<String>()),
      kind = switch (json['type']) {
        'text' => TaskTemplateFieldKind.text,
        'time' => TaskTemplateFieldKind.time,
        'enum' => TaskTemplateFieldKind.choice,
        'weekdays' => TaskTemplateFieldKind.weekdays,
        String _ => TaskTemplateFieldKind.unsupported,
        _ => throw const FormatException('Invalid task template field type'),
      };
  final String name, label, help;
  final String? defaultValue;
  final bool optional, strict;
  final List<String> options;
  final TaskTemplateFieldKind kind;
  bool get selectable =>
      strict &&
      options.isNotEmpty &&
      (kind == TaskTemplateFieldKind.choice ||
          kind == TaskTemplateFieldKind.weekdays);
  String? validate(String value) {
    if (value.isEmpty) return optional ? null : 'Enter $label.';
    if (strict &&
        kind == TaskTemplateFieldKind.choice &&
        options.isNotEmpty &&
        !options.contains(value)) {
      return 'Choose $label.';
    }
    if (kind == TaskTemplateFieldKind.time &&
        !RegExp(r'^([01]?\d|2[0-3]):[0-5]\d$').hasMatch(value.trim())) {
      return 'Use a time such as 09:00.';
    }
    return null;
  }
}

class TaskTemplate {
  TaskTemplate.fromJson(Map<String, dynamic> json)
    : key = json['key'] as String,
      title = json['title'] as String,
      description = json['description'] as String,
      fields = List.unmodifiable(
        (json['fields'] as List).map(
          (v) =>
              TaskTemplateField.fromJson(Map<String, dynamic>.from(v as Map)),
        ),
      ) {
    if (fields.map((field) => field.name).toSet().length != fields.length) {
      throw const FormatException('Duplicate task template field');
    }
  }
  final String key, title, description;
  final List<TaskTemplateField> fields;
  bool get supported =>
      fields.every((field) => field.kind != TaskTemplateFieldKind.unsupported);
  Map<String, String> get initialValues => Map.unmodifiable({
    for (final field in fields)
      field.name: field.name == 'deliver' ? 'local' : field.defaultValue ?? '',
  });
  List<TaskTemplateField> get inputFields =>
      List.unmodifiable(fields.where((field) => field.name != 'deliver'));
  Map<String, String> submission(Map<String, String> values, String delivery) =>
      Map.unmodifiable({
        for (final field in fields)
          if (field.name == 'deliver')
            field.name: delivery
          else if (!field.optional || (values[field.name] ?? '').isNotEmpty)
            field.name: values[field.name] ?? field.defaultValue ?? '',
      });
}

enum TaskScheduleKind {
  daily('Daily'),
  weekdays('Weekdays'),
  weekly('Weekly'),
  monthly('Monthly'),
  hourly('Hourly'),
  quarterHourly('Every 15 minutes'),
  interval('Every…'),
  once('Once, on a date'),
  delay('Once, after a delay'),
  custom('Custom schedule');

  const TaskScheduleKind(this.label);
  final String label;
}

String taskScheduleExpression(
  TaskScheduleKind kind, {
  int hour = 9,
  int minute = 0,
  int weekday = 1,
  int monthDay = 1,
  int minutes = 30,
  DateTime? once,
  String custom = '',
}) => switch (kind) {
  TaskScheduleKind.daily => '$minute $hour * * *',
  TaskScheduleKind.weekdays => '$minute $hour * * 1-5',
  TaskScheduleKind.weekly => '$minute $hour * * $weekday',
  TaskScheduleKind.monthly => '$minute $hour $monthDay * *',
  TaskScheduleKind.hourly => '0 * * * *',
  TaskScheduleKind.quarterHourly => '*/15 * * * *',
  TaskScheduleKind.interval => 'every ${minutes}m',
  TaskScheduleKind.delay => 'in ${minutes}m',
  TaskScheduleKind.once => once?.toUtc().toIso8601String() ?? '',
  TaskScheduleKind.custom => custom.trim(),
};

import 'dart:async';
import 'dart:convert';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'administration_fixture.dart';
import 'stock_task_blueprints.dart';

Map<String, dynamic> taskJson({
  String id = 'morning',
  String state = 'scheduled',
  String? name,
  String profile = 'personal',
}) => {
  'id': id,
  'profile': profile,
  'profile_name': profile,
  'name': name ?? 'Morning briefing',
  'prompt':
      'Summarize my calendar and the three things that need my attention today.',
  'enabled': state != 'paused',
  'state': state,
  'live_execution': state == 'running'
      ? {'id': 'execution-$id', 'status': 'running', 'job_id': id}
      : null,
  'latest_execution': null,
  'schedule': {'kind': 'cron', 'expr': '0 9 * * 1-5'},
  'schedule_display': 'Weekdays at 09:00',
  'deliver': 'local',
  'next_run_at': '2026-09-18T09:00:00+08:00',
  'last_run_at': '2026-09-17T09:00:00+08:00',
};

class ScheduledTasksFixture {
  ScheduledTasksFixture({
    String serverId = 'Home server',
    bool samples = true,
    DateTime? now,
  }) : admin = AdministrationFixture(serverId),
       _now = now ?? DateTime.utc(2026, 10, 3, 12) {
    if (samples) {
      jobs['morning'] = taskJson();
      jobs['review'] = taskJson(
        id: 'review',
        name: 'Weekly review',
        state: 'paused',
      )..['schedule_display'] = 'Every Friday at 18:00';
      jobs['watch'] = taskJson(id: 'watch', name: 'Watch the release notes')
        ..['last_error'] =
            'The destination needs a home channel. Update it and run the task again.';
    }
    admin.override = send;
    admin.rpcOverride = (method, params) async {
      if (method == 'groups.list') return {'rooms': rooms, 'next_offset': null};
      throw StateError('Unexpected task RPC $method');
    };
  }
  final AdministrationFixture admin;
  final DateTime _now;
  final jobs = <String, Map<String, dynamic>>{};
  final rooms = <Map<String, dynamic>>[];
  final runRows = <Map<String, dynamic>>[
    {
      'id': 'cron_morning_123',
      'source': 'cron',
      'title': 'Your morning briefing',
      'started_at': 1789606800,
      'is_active': false,
    },
  ];
  bool failList = false,
      failListAfterMutation = false,
      failRuns = false,
      missingProfile = false,
      deleteOneShot = false;
  Object? mutationError;
  Completer<void>? gate;
  int mutations = 0;
  AdministrationRequest? intercept;
  ProfileAdministration get profile => admin.server.profile('personal');
  Future<Map<String, dynamic>> send(
    String method,
    String path,
    Map<String, String> query,
    Map<String, dynamic>? body,
  ) async {
    if (intercept != null) return intercept!(method, path, query, body);
    final jobPath = RegExp(r'^cron/jobs/[^/]+$').hasMatch(path);
    final actionPath = RegExp(
      r'^cron/jobs/[^/]+/(pause|resume|trigger|cancel)$',
    ).hasMatch(path);
    final runPath = RegExp(r'^cron/jobs/[^/]+/runs$').hasMatch(path);
    final supported = switch (method) {
      'GET' =>
        const {
              'profiles',
              'profiles/active',
              'model/options',
              'cron/delivery-targets',
              'cron/blueprints',
              'cron/jobs',
            }.contains(path) ||
            jobPath ||
            runPath,
      'POST' =>
        path == 'cron/jobs' ||
            path == 'cron/blueprints/instantiate' ||
            actionPath,
      'PUT' || 'DELETE' => jobPath,
      _ => false,
    };
    if (!supported) throw StateError('Unexpected task request $method $path');
    if (path == 'profiles') {
      return {
        'profiles': [
          if (!missingProfile) {'name': 'personal'},
          {'name': 'work'},
          {'name': 'default', 'is_default': true},
        ],
      };
    }
    if (path == 'profiles/active') {
      return {'current': 'default', 'active': 'default'};
    }
    if (path == 'model/options') {
      return {
        'providers': [
          {
            'slug': 'anthropic',
            'name': 'Anthropic',
            'models': ['claude-sonnet-4-5'],
          },
        ],
      };
    }
    if (path == 'cron/delivery-targets') {
      return {
        'targets': [
          {'id': 'local', 'name': 'Local (save only)', 'home_target_set': true},
          {'id': 'telegram', 'name': 'Telegram', 'home_target_set': true},
          {'id': 'discord', 'name': 'Discord', 'home_target_set': false},
        ],
      };
    }
    if (path == 'cron/blueprints') {
      // Copy the immutable form schema so callers cannot mutate later replies.
      // Stock's HTTP route advertises discovered platform IDs for deliver.
      final blueprints = (jsonDecode(jsonEncode(stockTaskBlueprints)) as List)
          .cast<Map<String, dynamic>>();
      for (final blueprint in blueprints) {
        for (final field in blueprint['fields'] as List) {
          if (field['name'] == 'deliver') {
            field['options'] = ['origin', 'local', 'telegram', 'discord'];
          }
        }
      }
      return {'blueprints': blueprints};
    }
    if (path == 'cron/jobs' && method == 'GET') {
      if (failList) throw StateError('offline');
      return {
        'data': jobs.values.map((j) => {...j}).toList(),
      };
    }
    if (path.endsWith('/runs')) {
      if (failRuns) throw StateError('offline');
      final limit = int.parse(query['limit']!);
      return {'runs': runRows.take(limit).toList(), 'limit': limit};
    }
    if (method != 'GET') {
      mutations++;
      if (failListAfterMutation) failList = true;
      if (gate != null) await gate!.future;
      if (mutationError != null) throw mutationError!;
    }
    if (path == 'cron/jobs' && method == 'POST' ||
        path == 'cron/blueprints/instantiate') {
      if (path == 'cron/blueprints/instantiate') {
        final matching = stockTaskBlueprints.where(
          (blueprint) => blueprint['key'] == body?['blueprint'],
        );
        if (matching.isEmpty) throw CronHttpException(404, path, null);
        final fields = (matching.single['fields'] as List)
            .cast<Map<String, dynamic>>();
        final values = Map<String, dynamic>.from(body!['values'] as Map);
        final names = fields.map((field) => field['name']).toSet();
        if (values.keys.any((name) => !names.contains(name))) {
          throw CronHttpException(422, path, null);
        }
        for (final field in fields) {
          final value = values.containsKey(field['name'])
              ? values[field['name']]
              : field['default'];
          if ((value == null || value == '') && field['optional'] == false ||
              field['type'] == 'enum' &&
                  field['strict'] == true &&
                  !(field['options'] as List).contains(value.toString())) {
            throw CronHttpException(422, path, null);
          }
        }
      }
      final job = taskJson(id: 'new-${jobs.length}')..addAll(body ?? {});
      final expression = path == 'cron/blueprints/instantiate'
          ? '0 9 * * *'
          : body!['schedule'] as String;
      job['schedule'] = _projectSchedule(expression, _now);
      job['schedule_display'] = job['schedule']['display'];
      jobs[job['id'] as String] = job;
      return {...job};
    }
    final parts = path.split('/');
    final id = Uri.decodeComponent(parts[2]);
    final job = jobs[id];
    if (job == null) throw CronHttpException(404, path, null);
    if (path.endsWith('/cancel')) {
      final id = path.split('/')[2];
      final live = jobs[id]?['live_execution'];
      return {
        'success': true,
        'cancelled': live != null,
        'execution_id': live is Map ? live['id'] : null,
        'job_id': id,
      };
    }
    if (method == 'DELETE') {
      jobs.remove(id);
      return {'ok': true};
    }
    if (method == 'PUT') {
      final updates = Map<String, dynamic>.from(body!['updates'] as Map);
      if (updates['schedule'] is String) {
        updates['schedule'] = _projectSchedule(
          updates['schedule'] as String,
          _now,
        );
        updates['schedule_display'] = updates['schedule']['display'];
      }
      job.addAll(updates);
    }
    if (path.endsWith('/pause')) {
      job['state'] = 'paused';
      job['enabled'] = false;
    }
    if (path.endsWith('/resume')) {
      job['state'] = 'scheduled';
      job['enabled'] = true;
    }
    if (path.endsWith('/trigger')) {
      job['last_run_at'] = '2026-09-17T10:00:00+08:00';
      if (deleteOneShot) jobs.remove(id);
    }
    return {...job};
  }
}

// A bounded fake adapter for canonical UI-emitted forms, not a croniter clone.
// Stock projection golden cases are pinned in hermes_task_schedule_projection.json.
Map<String, dynamic> _projectSchedule(String value, DateTime now) {
  final text = value.trim();
  final instant = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(text);
  if (instant != null) {
    final parts = [for (var i = 1; i <= 6; i++) int.parse(instant[i]!)];
    final wall = DateTime.utc(
      parts[0],
      parts[1],
      parts[2],
      parts[3],
      parts[4],
      parts[5],
    );
    final fraction = (instant[7] ?? '').padRight(6, '0');
    final offset = instant[8]!;
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
      throw const FormatException('Invalid fixture timestamp');
    }
    final stored =
        '${text.substring(0, 19)}${int.parse(fraction) == 0 ? '' : '.$fraction'}${offset == 'Z' ? '+00:00' : offset}';
    return {
      'kind': 'once',
      'run_at': stored,
      'display': 'once at ${text.substring(0, 10)} ${text.substring(11, 16)}',
    };
  }
  final duration = RegExp(r'^(every|in) ([1-9][0-9]*)m$').firstMatch(text);
  if (duration != null) {
    final minutes = int.parse(duration[2]!);
    if (duration[1] == 'every') {
      return {
        'kind': 'interval',
        'minutes': minutes,
        'display': 'every ${minutes}m',
      };
    }
    final utc = now.toUtc().add(Duration(minutes: minutes));
    final fraction = utc.millisecond * 1000 + utc.microsecond;
    final stored =
        '${utc.toIso8601String().substring(0, 19)}${fraction == 0 ? '' : '.${fraction.toString().padLeft(6, '0')}'}+00:00';
    return {'kind': 'once', 'run_at': stored, 'display': 'once in ${minutes}m'};
  }
  final fields = text.split(RegExp(r'\s+'));
  if ((fields.length == 5 || fields.length == 6) &&
      fields.every((field) => RegExp(r'^[A-Za-z0-9*\-,/]+$').hasMatch(field))) {
    return {'kind': 'cron', 'expr': text, 'display': text};
  }
  throw const FormatException(
    'Fixture schedule is outside its explicitly supported canonical forms',
  );
}

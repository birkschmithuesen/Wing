import '../models/scheduled_task.dart';
import '../models/scheduled_task_edit.dart';
import 'administration_repository.dart';
import 'bots_repository.dart';

/// A request refused before any task mutation was dispatched.
class TaskPreflightFailure extends AdministrationFailure {
  const TaskPreflightFailure(super.message);
}

class TaskEditConflict extends TaskPreflightFailure {
  TaskEditConflict(Iterable<String> fields)
    : fields = List.unmodifiable(fields),
      super(
        'This task changed on Hermes. Your edits are kept. Review the changed fields before saving again.',
      );
  final List<String> fields;
}

/// A dispatched request whose response cannot establish the intended outcome.
class TaskMutationUncertain implements Exception {
  const TaskMutationUncertain();
}

class ScheduledTasksRepository {
  ScheduledTasksRepository(this.profile);
  final ProfileAdministration profile;
  String path(String id) => 'cron/jobs/${Uri.encodeComponent(id)}';
  ScheduledTask _task(Map<String, dynamic> value, {String? id}) {
    final task = ScheduledTask.fromJson(value);
    if (task.profileName != profile.name || id != null && task.id != id) {
      throw const FormatException('Scheduled task ownership did not match');
    }
    return task;
  }

  ScheduledTask _mutationResult(Map<String, dynamic> value, {String? id}) {
    try {
      return _task(value, id: id);
    } on FormatException {
      throw const TaskMutationUncertain();
    }
  }

  Future<List<ScheduledTask>> list() async {
    final tasks = administrationRows(
      (await profile.read('cron/jobs'))['data'],
    ).map((value) => _task(value)).toList();
    if (tasks.map((task) => task.id).toSet().length != tasks.length) {
      throw const FormatException('Ambiguous scheduled task membership');
    }
    return tasks;
  }

  Future<ScheduledTask> _requireMember(String id) async {
    try {
      final current = (await list()).where((task) => task.id == id).firstOrNull;
      if (current == null) {
        throw const TaskPreflightFailure(
          'This task is no longer available in this profile. Refresh before trying again.',
        );
      }
      return current;
    } on TaskPreflightFailure {
      rethrow;
    } catch (_) {
      throw const TaskPreflightFailure(
        'Task ownership could not be checked. Refresh before trying again.',
      );
    }
  }

  Future<ScheduledTask> get(String id) async =>
      _task(await profile.read(path(id)), id: id);
  Future<ScheduledTask> create(Map<String, dynamic> values) async =>
      _mutationResult(await profile.write('POST', 'cron/jobs', values));
  Future<ScheduledTask> update(TaskEditIntent intent) async {
    final baseline = intent.baseline;
    if (baseline.profileName != profile.name) {
      throw const TaskPreflightFailure('The task belongs to another profile.');
    }
    final id = baseline.id;
    final current = await _requireMember(id);
    final resolution = intent.resolve(current);
    if (resolution.conflicts.isNotEmpty) {
      throw TaskEditConflict(resolution.conflicts);
    }
    final updates = resolution.updates;
    if (updates.isEmpty) return current;
    final result = _mutationResult(
      await profile.write('PUT', path(id), {'updates': updates}),
      id: id,
    );
    for (final key in ['name', 'prompt', 'deliver', 'model', 'provider']) {
      if (!updates.containsKey(key) || key == 'name' && updates[key] == '') {
        continue;
      }
      if (result.text(key) != (updates[key] ?? '')) {
        throw const TaskMutationUncertain();
      }
    }
    for (final key in ['timezone', 'grace_minutes', 'catch_up']) {
      if (updates.containsKey(key) && result.data[key] != updates[key]) {
        throw const TaskMutationUncertain();
      }
    }
    return result;
  }

  Future<ScheduledTask> action(String id, String action) async {
    if (!const {'pause', 'resume', 'trigger'}.contains(action)) {
      throw ArgumentError.value(action);
    }
    await _requireMember(id);
    return _mutationResult(
      await profile.write('POST', '${path(id)}/$action'),
      id: id,
    );
  }

  Future<TaskCancellation> cancel(String id) async {
    await _requireMember(id);
    final result = await profile.write('POST', '${path(id)}/cancel');
    final requested = result['cancelled'], execution = result['execution_id'];
    if (result['success'] != true ||
        result['job_id'] != id ||
        requested is! bool ||
        (requested
            ? execution is! String || execution.isEmpty
            : execution != null)) {
      throw const TaskMutationUncertain();
    }
    return TaskCancellation(requested, execution as String?);
  }

  Future<void> delete(String id) async {
    await _requireMember(id);
    final result = await profile.write('DELETE', path(id));
    if (result['ok'] != true) {
      throw const TaskMutationUncertain();
    }
  }

  Future<List<TaskRun>> runs(String id, {int limit = 20}) async {
    await _requireMember(id);
    final rows = administrationRows(
      (await profile.read('${path(id)}/runs', {
        'limit': limit.clamp(1, 100).toString(),
      }))['runs'],
    );
    if (rows.any(
      (row) => row.containsKey('profile') && row['profile'] != profile.name,
    )) {
      throw const FormatException('Task run ownership did not match');
    }
    return rows.map(TaskRun.fromJson).toList();
  }

  // Discovery describes the connected server's gateway destinations, not a
  // fabricated inventory of per-profile channels.
  Future<List<TaskDeliveryTarget>> destinations() async => administrationRows(
    (await profile.read('cron/delivery-targets'))['targets'],
  ).map(TaskDeliveryTarget.fromJson).toList();

  Future<List<TaskDeliveryTarget>> roomDestinations() async {
    final server = profile.server;
    final rooms = await BotsRepository.readRoomCatalog(
      read: (name, method, params) => server.profile(name).rpc(method, params),
      scope: server.profile('default').scope,
      instance: server.connectionLabel,
    );
    return List.unmodifiable([
      for (final room in rooms)
        TaskDeliveryTarget.room(
          id: 'room:${room.id}@${room.scope.profileName}',
          name: room.name,
        ),
    ]);
  }

  Future<List<TaskTemplate>> templates() async => administrationRows(
    (await profile.read('cron/blueprints'))['blueprints'],
  ).map(TaskTemplate.fromJson).toList();
  Future<ScheduledTask> instantiate(
    TaskTemplate template,
    Map<String, String> values,
  ) async => _mutationResult(
    await profile.write('POST', 'cron/blueprints/instantiate', {
      'blueprint': template.key,
      'values': values,
    }),
  );
}

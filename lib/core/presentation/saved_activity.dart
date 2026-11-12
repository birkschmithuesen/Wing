import '../models/tool_payload.dart';
import '../models/gateway_todo.dart';
import '../models/transcript_message.dart';

/// Passive facts from one loaded Activity section. Never grants runtime control.
final class SavedActivity {
  SavedActivity(Iterable<TranscriptToolResult> calls) {
    GatewayTodoSnapshot? tasks;
    final agents = <SavedAgentResult>[];
    for (final call in calls) {
      final output = decodeToolPayload(call.rawResult);
      if (output is! Map) continue;
      // Full stock todo snapshots carry both revision and todos. Recognition
      // uses that contract, not a catalog of historical tool-name aliases.
      if (output['revision'] is num && output['todos'] is List) {
        final snapshot = GatewayTodoSnapshot.parse(output);
        if (snapshot != null) tasks = snapshot;
      }
      if (call.name != 'delegate_task') continue;
      final input = decodeToolPayload(call.arguments);
      final args = input is Map ? input : const {};
      final results = output['results'] ?? output['inline_results'];
      final byIndex = <int, Map>{};
      if (results is List) {
        for (final result in results.whereType<Map>()) {
          final index = result['task_index'];
          if (index is int && index >= 0 && result['status'] is String) {
            byIndex[index] = result;
          }
        }
      }
      if (output['status'] == 'dispatched' && output['goals'] is List) {
        final goals = output['goals'] as List;
        for (var index = 0; index < goals.length; index++) {
          if (goals[index] is String) {
            agents.add(
              SavedAgentResult._(
                goal: goals[index] as String,
                goalSupplied: true,
                rawDetails: call.rawResult,
                result: byIndex.remove(index) ?? const {'status': 'dispatched'},
              ),
            );
          }
        }
      }
      for (final entry in byIndex.entries) {
        final index = entry.key;
        final tasks = args['tasks'];
        final task = tasks is List && index < tasks.length
            ? tasks[index]
            : null;
        agents.add(
          SavedAgentResult._(
            goal: task is Map && task['goal'] is String
                ? task['goal'] as String
                : 'Delegated task',
            goalSupplied: task is Map && task['goal'] is String,
            rawDetails: call.rawResult,
            result: entry.value,
          ),
        );
      }
    }
    todos = List.unmodifiable(tasks?.todos ?? const <GatewayTodo>[]);
    this.agents = List.unmodifiable(agents);
  }

  late final List<GatewayTodo> todos;
  late final List<SavedAgentResult> agents;
}

/// A saved child result has no guaranteed live subagent ID. No fabricated ID,
/// clock, steering, interruption or runtime adoption is possible here.
final class SavedAgentResult {
  SavedAgentResult._({
    required this.goal,
    required this.goalSupplied,
    required this.rawDetails,
    required Map result,
  }) : status = result['status'] as String,
       exitReason = result['exit_reason'] is String
           ? result['exit_reason'] as String
           : null,
       truncated = result['truncated'] is bool
           ? result['truncated'] as bool
           : null,
       summaryTruncated = result['summary_truncated'] is bool
           ? result['summary_truncated'] as bool
           : null,
       schemaValid = result['schema_valid'] is bool
           ? result['schema_valid'] as bool
           : null,
       schemaNote = result['schema_note'] is String
           ? result['schema_note'] as String
           : null,
       schemaErrors = List<String>.unmodifiable(
         result['schema_errors'] is List
             ? (result['schema_errors'] as List).whereType<String>()
             : const <String>[],
       ),
       summary = result['summary'] is String
           ? result['summary'] as String
           : null,
       error = result['error'] is String ? result['error'] as String : null,
       model = result['model'] is String ? result['model'] as String : null,
       apiCalls =
           result['api_calls'] is int && (result['api_calls'] as int) >= 0
           ? result['api_calls'] as int
           : null,
       durationSeconds =
           result['duration_seconds'] is num &&
               (result['duration_seconds'] as num).isFinite &&
               (result['duration_seconds'] as num) >= 0
           ? (result['duration_seconds'] as num).toDouble()
           : null;

  final String goal;
  final bool goalSupplied;
  final String rawDetails;
  final String status;
  final String? exitReason;
  final bool? truncated;
  final bool? summaryTruncated;
  final bool? schemaValid;
  final String? schemaNote;
  final List<String> schemaErrors;
  final String? summary;
  final String? error;
  final String? model;
  final int? apiCalls;
  final double? durationSeconds;

  bool get failed => status == 'failed' || status == 'timeout';
  bool get warning =>
      status == 'interrupted' ||
      exitReason == 'max_iterations' ||
      truncated == true ||
      summaryTruncated == true ||
      schemaValid == false;
  bool get terminal =>
      const ['completed', 'failed', 'timeout', 'interrupted'].contains(status);

  String get statusLabel => switch (status) {
    'completed' => 'Completed',
    'dispatched' => 'Dispatched in background',
    'failed' => 'Failed',
    'timeout' => 'Timed out',
    'interrupted' => 'Interrupted',
    _ => status.replaceAll('_', ' '),
  };

  List<String> get qualifications => List.unmodifiable([
    if (exitReason == 'max_iterations')
      'Stopped at the iteration limit'
    else if (truncated == true)
      'Partial result supplied',
    if (summaryTruncated == true) 'Summary shortened by the server',
    if (schemaValid == false) 'Output does not meet the requested schema',
  ]);

  String? get notice => qualifications.isNotEmpty
      ? qualifications.join(' · ')
      : status == 'completed'
      ? null
      : statusLabel;
}

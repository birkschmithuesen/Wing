import '../models/tool_payload.dart';
import 'dart:convert';
import '../models/hermes_question.dart';
import '../models/bot_exchange.dart';
import '../models/gateway_activity.dart';
import '../models/transcript_message.dart';
import 'desktop_tool_labels.dart';
import 'tool_activity_details.dart';
import 'resource_identity.dart';

enum ToolCallOutcome { running, completed, success, warning, error }

/// Readable projection of delivered facts. It owns no execution or transport.
final class ToolCallPresentation {
  ToolCallPresentation._({
    required this.name,
    required this.title,
    required this.target,
    required this.subtitle,
    required this.status,
    required this.outcome,
    required this.activityDetails,
    required this.arguments,
    required this.result,
    required this.labels,
    this.callId,
    this.requestId,
    this.disclosureId,
    this.context,
    this.summary,
    this.durationSeconds,
    this.startedAt,
    this.progress,
    this.filenameTarget,
    this.exchangeReceipts = const [],
  });

  final String name;
  final String? callId;

  /// Gateway request identity stays distinct from a native tool-call identity.
  final String? requestId;
  final Object? disclosureId;
  final String? context;
  final String? summary;
  final String title;
  final String? target;
  final String status;
  final ToolCallOutcome outcome;
  final ToolActivityDetails activityDetails;
  final List<BotExchangeReceipt> exchangeReceipts;

  /// Exact supplied resource for inspecting a compact filename subtitle.
  final String? filenameTarget;
  final String? arguments;
  final String? result;
  final List<ToolCallLabel> labels;
  final double? durationSeconds;
  final Duration? startedAt;
  final GatewayToolProgress? progress;

  /// One compact input fact; raw targets and inputs remain unmodified.
  final String subtitle;

  /// Exceptions replace the input subtitle; normal completion adds no notice.
  String? get notice => switch (outcome) {
    ToolCallOutcome.warning || ToolCallOutcome.error => status,
    _ => null,
  };

  /// Shared desktop captions for a tool name delivered by Hermes.
  static String titleFor(String name, {required bool completed}) {
    final catalog = desktopToolLabels[name];
    final caption = switch (name) {
      'skill_view' => ('Read skill', 'Reading skill'),
      'skill_manage' => ('Managed skills', 'Managing skills'),
      'todo_list' => ('Checked tasks', 'Checking tasks'),
      'delegate_task' => ('Delegated tasks', 'Delegating tasks'),
      'cronjob_manage' => (
        'Managed scheduled tasks',
        'Managing scheduled tasks',
      ),
      'session_search' => ('Searched conversations', 'Searching conversations'),
      'tool_search' => ('Searched tools', 'Searching tools'),
      'tool_describe' => ('Inspected tools', 'Inspecting tools'),
      'tool_call' => ('Called tools', 'Calling tools'),
      'browser_exec' => ('Ran browser code', 'Running browser code'),
      'image_generate' => ('Generated images', 'Generating images'),
      _ => null,
    };
    if (caption != null) return completed ? caption.$1 : caption.$2;
    if (catalog != null) return completed ? catalog.done : catalog.pending;
    return _humanize(name);
  }

  factory ToolCallPresentation.live(GatewayToolActivity activity) => _project(
    name: activity.name,
    callId: activity.toolId,
    arguments: activity.arguments,
    result: activity.result,
    labels: activity.labels,
    completed: activity.isTerminal,
    durationSeconds: activity.durationSeconds,
    startedAt: activity.startedAt,
    context: activity.context,
    summary: activity.summary,
    progress: activity.isTerminal ? null : activity.progress,
  );

  factory ToolCallPresentation.saved(TranscriptToolResult result) => _project(
    name: result.name,
    callId: result.callId,
    arguments: result.arguments,
    result: result.rawResult.isEmpty ? result.text : result.rawResult,
    labels: result.labels,
    completed: true,
    durationSeconds: result.durationSeconds,
    context: result.context,
    summary: result.summary,
    exchangeReceipts: result.exchangeReceipts,
  );

  factory ToolCallPresentation.question(HermesQuestion question) {
    final exceptional =
        question.status == HermesQuestionStatus.expired ||
        question.status == HermesQuestionStatus.cancelled ||
        question.status == HermesQuestionStatus.closed;
    return ToolCallPresentation._(
      name: question.kind.name,
      requestId: question.requestId,
      disclosureId: ('question', question.id),
      title: titleFor(
        'clarify',
        completed: question.status != HermesQuestionStatus.pending,
      ),
      target: null,
      subtitle:
          '${question.status.label} · ${_oneLine(question.description.isEmpty ? question.command : question.description)}',
      status: question.status.label,
      // Waiting for consent is not evidence that a tool is executing.
      outcome: exceptional
          ? ToolCallOutcome.warning
          : ToolCallOutcome.completed,
      activityDetails: ToolActivityDetails.question(question),
      arguments: jsonEncode(question.toJson()),
      result: null,
      labels: const [],
    );
  }

  static ToolCallPresentation _project({
    required String name,
    required String? arguments,
    required String? result,
    required List<ToolCallLabel> labels,
    required bool completed,
    String? callId,
    double? durationSeconds,
    Duration? startedAt,
    String? context,
    String? summary,
    GatewayToolProgress? progress,
    List<BotExchangeReceipt> exchangeReceipts = const [],
  }) {
    final input = decodeToolPayload(arguments);
    final output = decodeToolPayload(result);
    final args = input is Map ? input : const {};
    final data = output is Map ? output : const {};
    final title = labels.isNotEmpty
        ? labels.first.text
        : titleFor(name, completed: completed);
    final target =
        _firstText(args, const [
          'image_url',
          'video_url',
          'url',
          'file_path',
          'path',
          'query',
          'pattern',
          'command',
          'name',
        ]) ??
        _listTarget(args['urls']) ??
        (labels.isNotEmpty ? _nonempty(labels.first.preview) : null);
    var outcome = completed
        ? ToolCallOutcome.completed
        : ToolCallOutcome.running;
    var status = completed ? 'Completed' : 'Running';
    if (completed) {
      final error = _firstText(data, const ['error']);
      final exit = data['exit_code'];
      if (data['success'] == false ||
          data['ok'] == false ||
          data['isError'] == true ||
          error != null ||
          data['error'] == true ||
          const ['error', 'timeout', 'interrupted'].contains(data['status']) ||
          (exit is num && exit != 0)) {
        outcome = ToolCallOutcome.error;
        status = error == null ? 'Failed' : _oneLine(error);
        if (exit is num && exit != 0) status = 'Exited with code $exit';
      } else if (_returned404(data)) {
        outcome = ToolCallOutcome.warning;
        status = 'Returned a 404 page';
      } else if (_firstText(data, const ['fallback_warning'])
          case final warning?) {
        outcome = ToolCallOutcome.warning;
        status = _oneLine(warning);
      } else if (data['no_change'] == true) {
        status = 'No change';
      } else if (data['status'] == 'unchanged') {
        outcome = ToolCallOutcome.completed;
        status = 'Already loaded';
      } else if (data['success'] == true ||
          data['ok'] == true ||
          data['status'] == 'success' ||
          data['verified'] == true) {
        outcome = ToolCallOutcome.success;
        status = 'Completed';
      }
    }
    final activityDetails = ToolActivityDetails.project(
      name: name,
      input: input,
      output: output,
    );
    if (completed && activityDetails.receiptState != null) {
      final state = activityDetails.receiptState!;
      outcome = switch (state) {
        ToolReceiptState.completed => ToolCallOutcome.completed,
        ToolReceiptState.warning => ToolCallOutcome.warning,
        ToolReceiptState.error => ToolCallOutcome.error,
      };
    }
    if (completed && activityDetails.receiptStatus != null) {
      status = activityDetails.receiptStatus!;
    }
    final inputSummary =
        labels.isNotEmpty && labels.first.preview.trim().isNotEmpty
        ? _inputDetail(name, args, data, labels, context)
        : _intentLine(
            activityDetails.intent ??
                _inputDetail(name, args, data, labels, context),
          );
    final suppliedPath = _firstText(args, const ['path', 'file_path']);
    final fileOperation = const [
      'read_file',
      'write_file',
      'patch',
    ].contains(name);
    final filenameTarget =
        suppliedPath != null &&
            (fileOperation ||
                inputSummary == suppliedPath ||
                inputSummary.endsWith(' · $suppliedPath'))
        ? activityDetails.resourceTarget ?? suppliedPath
        : null;
    final subtitle = filenameTarget == null
        ? inputSummary
        : fileOperation || inputSummary == suppliedPath
        ? resourceFileName(suppliedPath!)
        : '${inputSummary.substring(0, inputSummary.length - suppliedPath!.length)}${resourceFileName(suppliedPath)}';
    return ToolCallPresentation._(
      progress: progress,
      name: name,
      callId: callId,
      context: context,
      summary: summary,
      title: title,
      target: target == null ? null : _oneLine(target),
      subtitle: subtitle,
      filenameTarget: filenameTarget,
      status: status,
      outcome: outcome,
      activityDetails: activityDetails,
      arguments: arguments,
      result: result,
      labels: labels,
      durationSeconds: durationSeconds,
      startedAt: completed ? null : startedAt,
      exchangeReceipts: exchangeReceipts,
    );
  }
}

String _intentLine(String value) {
  var text = _oneLine(
    value,
  ).replaceAll(RegExp(r'https?://', caseSensitive: false), '');
  if (RegExp(
    r'^(open|close|read|click|type|elements|wait|run|create|update|delete|list) · ',
  ).hasMatch(text)) {
    text = '${text[0].toUpperCase()}${text.substring(1)}';
  }
  return text;
}

String _inputDetail(
  String name,
  Map args,
  Map data,
  List<ToolCallLabel> labels,
  String? context,
) {
  String display(String value) {
    final text = _oneLine(value);
    if (text.startsWith('data:')) return 'Attached image';
    return text.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
  }

  String? list(Object? value) {
    if (value is! List) return null;
    final values = value
        .whereType<String>()
        .where((s) => s.trim().isNotEmpty)
        .map(display);
    return values.isEmpty ? null : values.join(' · ');
  }

  if (labels.isNotEmpty && labels.first.preview.trim().isNotEmpty) {
    return display(labels.first.preview);
  }
  final code = _firstText(args, const ['code']);
  if (name == 'browser_exec' && code != null) {
    // Only literal input URLs are summarized. Never evaluate code or borrow a
    // URL from another call; scripts may use entirely different browser tabs.
    final literals = RegExp(r'''(["'])(.*?)\1''').allMatches(code);
    for (final literal in literals) {
      final url = RegExp(
        r'''https?://[^\s"'<>`\\]+''',
      ).firstMatch(literal.group(2)!)?.group(0);
      if (url != null && !url.contains('{') && !url.contains('}')) {
        return display(url);
      }
    }
    final first = code.trim().split('\n').first.trim();
    if (first.startsWith('#') && first.substring(1).trim().isNotEmpty) {
      return _oneLine(first.substring(1));
    }
    return _oneLine(code);
  }
  if (name == 'search_files') {
    final pattern = _firstText(args, const ['pattern', 'query']);
    final path = _firstText(args, const ['path']);
    if (pattern != null || path != null) {
      return [?pattern, ?path].map(display).join(' · ');
    }
  }
  if (args['tasks'] case final List tasks
      when name == 'delegate_task' && tasks.isNotEmpty) {
    final goal = tasks.first is Map
        ? _firstText(tasks.first as Map, const ['goal'])
        : null;
    return '${tasks.length} ${tasks.length == 1 ? 'task' : 'tasks'}${goal == null ? '' : ' · ${_oneLine(goal)}'}';
  }
  if (name == 'delegate_task' && data['goals'] is List) {
    final goals = (data['goals'] as List)
        .whereType<String>()
        .where((goal) => goal.trim().isNotEmpty)
        .toList();
    if (goals.isNotEmpty) {
      return '${goals.length} ${goals.length == 1 ? 'task' : 'tasks'} · ${_oneLine(goals.first)}';
    }
  }
  final target =
      _firstText(args, const [
        'image_url',
        'url',
        'file_path',
        'path',
        'query',
        'pattern',
        'command',
        'name',
        'goal',
        'prompt',
        'ref',
        'selector',
        'text',
        'content',
        'code',
        'subagent_id',
      ]) ??
      list(args['urls']) ??
      list(args['names']);
  final action = _firstText(args, const ['action']);
  if (action != null) {
    return [_humanize(action), if (target != null) display(target)].join(' · ');
  }
  if (target != null) return display(target);
  if (context != null && context.trim().isNotEmpty) return display(context);
  final deliveredTarget = _firstText(data, const ['url', 'file_path', 'path']);
  if (deliveredTarget != null) return display(deliveredTarget);
  return 'No input details supplied';
}

String? _firstText(Map data, List<String> keys) {
  for (final key in keys) {
    final value = data[key];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return null;
}

String? _nonempty(String text) => text.trim().isEmpty ? null : text;
String? _listTarget(Object? value) => value is List && value.isNotEmpty
    ? value.whereType<String>().join(' · ')
    : null;
String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();
String _humanize(String text) {
  final words = text.replaceAll(RegExp(r'[_-]+'), ' ').trim();
  return words.isEmpty
      ? 'Tool'
      : '${words[0].toUpperCase()}${words.substring(1)}';
}

bool _returned404(Map data) {
  if (data['status_code'] == 404) return true;
  final sources = data['results'];
  if (sources is! List) return false;
  return sources.any(
    (source) =>
        source is Map &&
        (source['status_code'] == 404 ||
            RegExp(
              r'(?:^|[-|:])\s*404(?:\s+error|\s+page\s+not\s+found|\s+not\s+found)?\s*(?:$|[-|:])',
              caseSensitive: false,
            ).hasMatch('${source['title'] ?? ''}') ||
            RegExp(
              r'^\s*(?:#{1,6}\s*)?404\s+page\s+not\s+found\s*$',
              caseSensitive: false,
              multiLine: true,
            ).hasMatch('${source['content'] ?? ''}')),
  );
}

String formatToolDuration(double seconds) {
  if (seconds < 1) return '${(seconds * 1000).round()} ms';
  if (seconds < 60) return '${seconds.toStringAsFixed(seconds < 10 ? 1 : 0)} s';
  final whole = seconds.floor();
  return '${whole ~/ 60}m ${whole % 60}s';
}

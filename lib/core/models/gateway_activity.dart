import 'dart:convert';

enum GatewayToolActivityPhase { running, generating, completed }

/// Ephemeral MCP progress for an exact running call; never a saved result.
final class GatewayToolProgress {
  const GatewayToolProgress({
    required this.value,
    this.total,
    this.percent,
    this.message,
  });

  final double value;
  final double? total;
  final int? percent;
  final String? message;

  static GatewayToolProgress? parse(Map<String, dynamic> data) {
    final value = data['progress'];
    if (value is! num || !value.isFinite || value < 0) return null;
    final total = data['total'];
    final percent = data['percent'];
    final message = data['message'];
    return GatewayToolProgress(
      value: value.toDouble(),
      total: total is num && total.isFinite && total > 0
          ? total.toDouble()
          : null,
      percent: percent is int && percent >= 0 && percent <= 100
          ? percent
          : null,
      message: message is String && message.trim().isNotEmpty
          ? message.trim()
          : null,
    );
  }

  String get label => [
    if (percent != null)
      '$percent%'
    else if (total != null)
      '${_number(value)} / ${_number(total!)}'
    else
      _number(value),
    ?message,
  ].join(' · ');

  static String _number(double value) => value == value.truncateToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();
}

/// Structured labels supplied by stock Hermes for connector/MCP bridge calls.
final class ToolCallLabel {
  const ToolCallLabel({
    required this.text,
    required this.name,
    required this.preview,
  });
  final String text;
  final String name;
  final String preview;

  static List<ToolCallLabel> parse(Object? value) => List.unmodifiable([
    if (value is List)
      for (final row in value)
        if (row is Map && row['text'] is String && row['name'] is String)
          ToolCallLabel(
            text: row['text'] as String,
            name: row['name'] as String,
            preview: row['preview'] is String ? row['preview'] as String : '',
          ),
  ]);
}

class GatewayToolActivity {
  static const _maxDetailLength = 500;

  final String? toolId;
  final String name;
  final GatewayToolActivityPhase phase;
  final String? detail;
  final double? durationSeconds;
  final String? arguments;
  final String? result;
  final String? context;
  final String? summary;
  final List<ToolCallLabel> labels;
  final GatewayToolProgress? progress;

  /// Monotonic receipt time of a live backend start, never a replay or draft.
  final Duration? startedAt;

  const GatewayToolActivity({
    required this.name,
    required this.phase,
    this.toolId,
    this.detail,
    this.durationSeconds,
    this.arguments,
    this.result,
    this.context,
    this.summary,
    this.labels = const [],
    this.startedAt,
    this.progress,
  });

  bool get isTerminal => phase == GatewayToolActivityPhase.completed;

  String get displayName {
    final words = name.replaceAll(RegExp(r'[_-]+'), ' ').trim();
    if (words.isEmpty) return 'Tool';
    return words[0].toUpperCase() + words.substring(1);
  }

  String get statusLabel {
    switch (phase) {
      case GatewayToolActivityPhase.running:
        return 'Running';
      case GatewayToolActivityPhase.generating:
        return 'Preparing';
      case GatewayToolActivityPhase.completed:
        return durationSeconds == null
            ? 'Completed'
            : 'Completed in ${_formatDuration(durationSeconds!)}';
    }
  }

  static GatewayToolActivity? fromGatewayEvent(
    String eventType,
    Map<String, dynamic> data, {
    Duration? receivedAt,
  }) {
    final phase = switch (eventType) {
      'tool.start' => GatewayToolActivityPhase.running,
      'tool.progress' => GatewayToolActivityPhase.running,
      'tool.generating' => GatewayToolActivityPhase.generating,
      'tool.complete' => GatewayToolActivityPhase.completed,
      _ => null,
    };
    if (phase == null) return null;

    final toolId = _firstText(data, const ['tool_id']);
    final name = _firstText(data, const ['name']) ?? 'tool';
    final durationSeconds = _duration(data['duration_s']);
    final detail = switch (phase) {
      GatewayToolActivityPhase.completed => _normalizeText(
        _firstText(data, const ['summary']),
        _maxDetailLength,
      ),
      GatewayToolActivityPhase.generating => null,
      GatewayToolActivityPhase.running => _normalizeText(
        _firstText(data, const ['context']),
        _maxDetailLength,
      ),
    };

    return GatewayToolActivity(
      toolId: toolId,
      name: name,
      phase: phase,
      detail: detail,
      durationSeconds: durationSeconds,
      arguments: _payload(data['args']),
      result: _payload(data['result'] ?? data['result_text']),
      context: _firstText(data, const ['context']),
      summary: _firstText(data, const ['summary']),
      labels: ToolCallLabel.parse(data['labels']),
      startedAt: eventType == 'tool.start' ? receivedAt : null,
      progress: eventType == 'tool.progress'
          ? GatewayToolProgress.parse(data)
          : null,
    );
  }

  GatewayToolActivity merge(GatewayToolActivity update) {
    return GatewayToolActivity(
      toolId: update.toolId ?? toolId,
      name: update.name == 'tool' && name != 'tool' ? name : update.name,
      phase: update.phase,
      detail: update.detail ?? detail,
      durationSeconds: update.durationSeconds ?? durationSeconds,
      arguments: update.arguments ?? arguments,
      result: update.result ?? result,
      context: update.context ?? context,
      summary: update.summary ?? summary,
      labels: update.labels.isEmpty ? labels : update.labels,
      startedAt: startedAt ?? update.startedAt,
      progress: update.isTerminal ? null : update.progress ?? progress,
    );
  }

  GatewayToolActivity withoutProgress() => GatewayToolActivity(
    toolId: toolId,
    name: name,
    phase: phase,
    detail: detail,
    durationSeconds: durationSeconds,
    arguments: arguments,
    result: result,
    context: context,
    summary: summary,
    labels: labels,
    startedAt: startedAt,
  );

  static String? _firstText(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key];
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return null;
  }

  static String? _normalizeText(String? value, int maxLength) {
    if (value == null) return null;
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return null;
    return normalized.length <= maxLength
        ? normalized
        : '${normalized.substring(0, maxLength - 1)}…';
  }

  static double? _duration(dynamic value) {
    if (value is num && value.isFinite && value >= 0) {
      return value.toDouble();
    }
    return null;
  }

  static String? _payload(dynamic value) {
    if (value == null) return null;
    String text;
    try {
      text = value is String ? value : jsonEncode(value);
    } catch (_) {
      text = value.toString();
    }
    return text.isEmpty ? null : text;
  }

  static String _formatDuration(double value) {
    if (value < 1) return '${(value * 1000).round()} ms';
    return '${value.toStringAsFixed(value < 10 ? 1 : 0)} s';
  }
}

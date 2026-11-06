/// Immutable facts from stock message.complete.error_surface. Recovery remains
/// a user action; a descriptor never authorizes a resend or credit purchase.
final class TurnFailure {
  TurnFailure._({
    required this.message,
    required this.layer,
    required this.code,
    required this.retryable,
    this.provider,
    this.providerLabel,
    this.description,
    this.model,
    this.authKind,
    this.apiKeyEnvironment,
    this.resetsAt,
    this.usageLimit,
  });

  final String message, layer, code;
  final bool? retryable;
  final String? provider,
      providerLabel,
      description,
      model,
      authKind,
      apiKeyEnvironment;
  final DateTime? resetsAt;
  final TurnUsageLimit? usageLimit;

  static TurnFailure? fromCompletion(Map<String, dynamic> completion) {
    if (completion['status'] != 'error') return null;
    final surface = completion['error_surface'];
    final data = surface is Map ? surface : const {};
    return TurnFailure._(
      message:
          _text(completion['error']) ??
          _text(completion['text']) ??
          'Turn failed',
      layer: _text(data['layer']) ?? '',
      code: _text(data['code']) ?? '',
      retryable: data['retryable'] is bool ? data['retryable'] as bool : null,
      provider: _text(data['provider']),
      providerLabel: _text(data['provider_label']),
      description: _text(data['message']),
      model: _text(data['model']),
      authKind: _text(data['auth_kind']),
      apiKeyEnvironment: _text(data['api_key_env']),
      resetsAt: _epoch(data['resets_at'], 1000),
      usageLimit: TurnUsageLimit.parse(data['usage_limit']),
    );
  }

  String get title => usageLimit != null
      ? 'Plan allowance reached'
      : switch (code) {
          'workspace_unavailable' => 'Workspace unavailable',
          'launch_credentials_unavailable' => 'Launch credentials changed',
          'max_iterations_no_summary' => 'Turn budget reached',
          'context_overflow' => 'Context limit reached',
          'truncated' => 'Reply cut short',
          'local_runtime_unavailable' => 'Local model unavailable',
          _ => switch (layer) {
            'auth' => 'Provider access needs attention',
            'billing' => 'Provider allowance needs attention',
            'endpoint' => 'Model endpoint unavailable',
            'streaming' => 'Response connection interrupted',
            'disk' => 'Server storage needs attention',
            _ => 'Turn failed',
          },
        };

  String? get recovery => switch (code) {
    'workspace_unavailable' =>
      'Restore the project folder or choose an available workspace before continuing.',
    'launch_credentials_unavailable' =>
      'Review this profile’s credentials, then start a new chat. This chat retains its original launch credentials.',
    'max_iterations_no_summary' =>
      'Continue the work, or adjust the turn budget in profile settings.',
    'truncated' => 'Continue the reply when you are ready.',
    'local_runtime_unavailable' =>
      'Start the local model server or choose another model.',
    'context_overflow' =>
      'Compact the conversation or choose a model with a larger context window.',
    _ => switch (layer) {
      'auth' =>
        authKind == 'oauth'
            ? 'Sign in to the provider again.'
            : 'Review this profile’s provider credentials.',
      'endpoint' => 'Check the configured model endpoint and its connection.',
      'disk' => 'Free server disk space before continuing.',
      _ =>
        retryable == true
            ? 'You can try again after resolving the interruption.'
            : null,
    },
  };

  bool get canContinue =>
      const {'truncated', 'max_iterations_no_summary'}.contains(code);
  bool get blocking =>
      !canContinue &&
      !(retryable == true &&
          !const {'auth', 'billing', 'endpoint'}.contains(layer)) &&
      code != 'free_tier_model_not_free';
  bool get canReviewEndpoint =>
      layer == 'endpoint' || code == 'local_runtime_unavailable';

  bool get canChooseModel =>
      code == 'local_runtime_unavailable' ||
      usageLimit != null ||
      const {'provider', 'auth', 'billing', 'endpoint'}.contains(layer);
  bool get canReviewProvider =>
      const {'auth', 'billing'}.contains(layer) &&
      code != 'local_runtime_unavailable';
}

final class TurnUsageLimit {
  TurnUsageLimit._({
    required this.name,
    required this.message,
    required this.scope,
    required Iterable<TurnModelSuggestion> suggestions,
    this.resetsAt,
    this.creditsAction,
  }) : suggestions = List.unmodifiable(suggestions);
  final String name, message, scope;
  final DateTime? resetsAt;
  final List<TurnModelSuggestion> suggestions;
  final String? creditsAction;

  static TurnUsageLimit? parse(Object? value) {
    if (value is! Map ||
        value['message'] is! String ||
        value['limit_name'] is! String) {
      return null;
    }
    final rows = value['suggestions'];
    final credits = value['credits'];
    return TurnUsageLimit._(
      name: value['limit_name'] as String,
      message: value['message'] as String,
      scope: _text(value['scope']) ?? '',
      resetsAt: _epoch(value['resets_at_ms'], 1),
      creditsAction: credits is Map ? _text(credits['action']) : null,
      suggestions: [
        if (rows is List)
          for (final row in rows)
            if (row is Map &&
                _text(row['model']) != null &&
                _text(row['provider']) != null)
              TurnModelSuggestion(
                provider: row['provider'] as String,
                model: row['model'] as String,
                label: _text(row['label']) ?? row['model'] as String,
                note: _text(row['note']) ?? '',
              ),
      ],
    );
  }
}

final class TurnModelSuggestion {
  const TurnModelSuggestion({
    required this.provider,
    required this.model,
    required this.label,
    required this.note,
  });
  final String provider, model, label, note;
}

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;
DateTime? _epoch(Object? value, int scale) =>
    value is num &&
        value.isFinite &&
        value > 0 &&
        value * scale < 8640000000000000
    ? DateTime.fromMillisecondsSinceEpoch((value * scale).round(), isUtc: true)
    : null;

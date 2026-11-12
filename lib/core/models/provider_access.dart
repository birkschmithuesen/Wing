/// A provider-level credential observation, not a live request or account pool.
enum ProviderAccessState { connected, expired, signedOut, external, unknown }

class ProviderAccess {
  final Map<String, dynamic> row;
  final DateTime checkedAt;
  ProviderAccess(this.row, {DateTime? now}) : checkedAt = now ?? DateTime.now();

  Map get status => row['status'] is Map ? row['status'] as Map : const {};

  /// Stock provider rows carry a nonempty identity even when status is sparse.
  /// Validate before replacing a retained observation, not during rendering.
  static void validateIdentity(Map<String, dynamic> row) {
    final id = row['id'];
    if (id is! String || id.trim().isEmpty) {
      throw const FormatException('Invalid stock provider identity');
    }
  }

  String get id => row['id'] as String;
  String get name => switch (id) {
    'claude-code' => 'Claude Code',
    'openai-codex' => 'ChatGPT / Codex',
    'anthropic' => 'Anthropic',
    _ => row['name'] as String? ?? id,
  };
  bool get external => row['flow'] == 'external';
  DateTime? get expiresAt => providerStatusDate(status['expires_at']);
  bool get canRefresh => status['has_refresh_token'] == true;
  bool get hasCredential => status['logged_in'] == true || expiresAt != null;

  ProviderAccessState get state {
    if (status['error'] != null || status['logged_in'] is! bool) {
      return ProviderAccessState.unknown;
    }
    if (expiresAt != null && !expiresAt!.isAfter(checkedAt)) {
      return ProviderAccessState.expired;
    }
    if (status['logged_in'] == true) return ProviderAccessState.connected;
    return external
        ? ProviderAccessState.external
        : ProviderAccessState.signedOut;
  }

  bool get needsAttention =>
      state == ProviderAccessState.expired ||
      state == ProviderAccessState.unknown;
  String get detail => switch (state) {
    ProviderAccessState.connected => 'Credentials detected by the server.',
    ProviderAccessState.expired when canRefresh =>
      'A refresh token is stored. Automatic renewal has not been checked.',
    ProviderAccessState.expired when external =>
      'Renew the token in the provider\'s tool on the server.',
    ProviderAccessState.expired => 'Sign in again to renew access.',
    ProviderAccessState.signedOut => 'No sign-in detected for this provider.',
    ProviderAccessState.external =>
      'Check the provider\'s tool on the server. Its sign-in could not be verified.',
    ProviderAccessState.unknown => 'Check status to read this provider again.',
  };
  String get signInLabel => hasCredential ? 'Sign in again' : 'Sign in';
  int get sortOrder => needsAttention
      ? 0
      : state == ProviderAccessState.connected
      ? 1
      : 2;
}

/// Hermes status helpers return ISO timestamps or Unix seconds/milliseconds.
DateTime? providerStatusDate(Object? value) {
  if (value is String) {
    final numeric = num.tryParse(value);
    if (numeric != null) return providerStatusDate(numeric);
    // A timestamp without a timezone cannot establish token expiry safely.
    if (!RegExp(
      r'(Z|[+-]\d{2}:?\d{2})$',
      caseSensitive: false,
    ).hasMatch(value)) {
      return null;
    }
    return DateTime.tryParse(value)?.toUtc();
  }
  if (value is! num || !value.isFinite || value <= 0) return null;
  final milliseconds = value > 100000000000 ? value : value * 1000;
  if (milliseconds > 8640000000000000) return null;
  return DateTime.fromMillisecondsSinceEpoch(milliseconds.round(), isUtc: true);
}

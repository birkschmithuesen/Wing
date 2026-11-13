/// Stock owner receipts. Identity is independent of prompt text and UI position.
final class CanonicalAdmission {
  CanonicalAdmission({
    required this.id,
    required this.inputId,
    required this.sessionId,
    required this.sequence,
    required this.status,
    required this.text,
    required this.generation,
    required Iterable<String> controls,
    this.outcome,
    this.steering = false,
  }) : controls = Set.unmodifiable(controls);

  final String id, inputId, sessionId, status, text;
  final int sequence;
  final int? generation;
  final String? outcome;
  final bool steering;
  final Set<String> controls;
  bool get queued => status == 'queued';
  bool get unknown => status == 'unknown';

  factory CanonicalAdmission.fromJson(Map value) {
    final ref = value['ref'];
    final id = value['admission_id'];
    final sid = ref is Map ? ref['session_id'] : null;
    final sequence = value['sequence'];
    final status = value['status'];
    if (id is! String ||
        id.isEmpty ||
        sid is! String ||
        sid.isEmpty ||
        sequence is! int ||
        sequence < 0 ||
        !const {'queued', 'started', 'unknown', 'terminal'}.contains(status)) {
      throw const FormatException('Invalid Hermes admission receipt');
    }
    return CanonicalAdmission(
      id: id,
      inputId: value['input_id'] is String ? value['input_id'] as String : '',
      sessionId: sid,
      sequence: sequence,
      status: status as String,
      text: value['text'] is String ? value['text'] as String : '',
      generation: value['execution_generation'] as int?,
      outcome: value['outcome'] as String?,
      steering: value['steering'] == true,
      controls: (value['controls'] as List? ?? const []).whereType<String>(),
    );
  }
}

/// The exact read-only subscription and replay watermark returned by resume.
final class CanonicalReplayCursor {
  const CanonicalReplayCursor(this.sessionId, this.epoch, this.sequence);

  factory CanonicalReplayCursor.fromSnapshot(
    Map<String, dynamic> value, {
    required String expectedSessionId,
    String? expectedEpoch,
  }) {
    final id = value['session_id'];
    final epoch = value['replay_epoch'];
    final sequence = value['last_sequence'];
    if (id != expectedSessionId ||
        value['stored_session_id'] != expectedSessionId ||
        epoch is! String ||
        epoch.isEmpty ||
        expectedEpoch != null && epoch != expectedEpoch ||
        sequence is! int ||
        sequence < 0) {
      throw const FormatException('Invalid canonical passive subscription');
    }
    return CanonicalReplayCursor(expectedSessionId, epoch, sequence);
  }

  final String sessionId, epoch;
  final int sequence;
}

final class CanonicalSessionObservation {
  CanonicalSessionObservation({
    required this.sessionId,
    required this.revision,
    required this.generation,
    required this.authorityEpoch,
    required this.replayEpoch,
    required this.sequence,
    required this.subscriptionId,
    required Iterable<CanonicalAdmission> pending,
    this.readOnlyReason,
  }) : pending = List.unmodifiable(pending);
  final String sessionId, replayEpoch, subscriptionId;
  final int revision, generation, authorityEpoch, sequence;
  final List<CanonicalAdmission> pending;
  final String? readOnlyReason;
}

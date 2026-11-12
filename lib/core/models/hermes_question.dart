enum HermesQuestionStatus {
  pending('Pending'),
  approved('Approved'),
  rejected('Rejected'),
  answered('Answered'),
  expired('Expired'),
  cancelled('Cancelled'),
  closed('Closed');

  const HermesQuestionStatus(this.label);
  final String label;

  bool get isPending => this == pending;

  int get certainty => switch (this) {
    pending => 0,
    closed => 1,
    cancelled || expired => 2,
    approved || rejected || answered => 3,
  };

  static HermesQuestionStatus decision(String choice) =>
      choice == 'deny' ? rejected : approved;

  static HermesQuestionStatus cancellation(Object? reason) => switch (reason) {
    'timeout' => expired,
    'interrupted' || 'session_closed' || 'shutdown' => cancelled,
    _ => closed,
  };
}

enum HermesQuestionKind { approval, clarification, secureInput }

/// Display-only request history. Response values and execution authority never
/// enter this record, including for password and vault prompts.
final class HermesQuestion {
  const HermesQuestion({
    required this.id,
    required this.requestId,
    required this.kind,
    required this.status,
    required this.timestamp,
    required this.description,
    this.command = '',
    this.sender = '',
  });

  final String id, requestId, description, command, sender;
  final HermesQuestionKind kind;
  final HermesQuestionStatus status;
  final DateTime timestamp;

  HermesQuestion withStatus(HermesQuestionStatus next) => HermesQuestion(
    id: id,
    requestId: requestId,
    kind: kind,
    status: next,
    timestamp: timestamp,
    description: description,
    command: command,
    sender: sender,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'request': requestId,
    'kind': kind.name,
    'status': status.name,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'description': description,
    'command': command,
    'sender': sender,
  };

  factory HermesQuestion.fromJson(Map value) => HermesQuestion(
    id: value['id'] as String,
    requestId: value['request'] as String,
    kind: HermesQuestionKind.values.byName(value['kind'] as String),
    status: HermesQuestionStatus.values.byName(value['status'] as String),
    timestamp: DateTime.fromMillisecondsSinceEpoch(value['timestamp'] as int),
    description: value['description'] as String,
    command: value['command'] as String,
    sender: value['sender'] as String,
  );
}

/// A request's first observed place in Activity, separate from backend messages
/// and tool receipts. Later status changes retain these presentation anchors.
final class PositionedHermesQuestion {
  const PositionedHermesQuestion(
    this.question, {
    this.afterMessage,
    this.groupSequence,
    this.afterTool,
  });

  final HermesQuestion question;
  final Object? afterMessage;
  final int? groupSequence;
  final String? afterTool;
}

/// A clarification prompt keyed by Hermes' server-owned JSON-RPC request ID.
///
/// The `clarify` server request accepts these params, plus `session_id`:
///
/// * Single: `{"question": ..., "choices": [...], "multi_select": ...}`
/// * Batch: `{"questions": [{"qid": ..., "question": ..., "choices": [...], "multi_select": ...}]}`
/// The socket attaches the frame's `id` as `request_id` for the UI.
///
/// Batch responses must echo the per-question `qid` back as `question_id` so
/// `clarify.lock` can lock each answer independently.
class GatewayClarifyRequest {
  final String requestId;

  /// The per-question id inside a batch `questions[]` payload. Null for the
  /// flat single-question shape.
  final String? questionId;
  final String question;
  final List<String> choices;
  final bool multiSelect;

  const GatewayClarifyRequest({
    required this.requestId,
    required this.question,
    required this.choices,
    required this.multiSelect,
    this.questionId,
  });

  bool get hasChoices => choices.isNotEmpty;

  /// Encodes a staged answer in Hermes' choice order, with custom text last.
  /// For a single choice, nonempty custom text takes precedence.
  String answer({
    required int? selectedIndex,
    required Iterable<int> selectedIndices,
    required String customText,
  }) {
    final custom = customText.trim();
    if (!multiSelect) {
      if (custom.isNotEmpty) return custom;
      return selectedIndex == null ? '' : choices[selectedIndex];
    }

    final ordered = selectedIndices.toList()..sort();
    final parts = [
      for (final index in ordered) choices[index],
      if (custom.isNotEmpty) custom,
    ];
    return parts.join(', ');
  }

  /// Parses a normalized `clarify` request into zero or more prompts.
  ///
  /// Batch payloads expand to one prompt per question (each carrying its own
  /// `questionId`); flat payloads expand to a single prompt with no
  /// `questionId`. Questions missing a usable `qid` in a batch are dropped,
  /// since the gateway cannot correlate an answer without one.
  static List<GatewayClarifyRequest> fromEventDataList(
    Map<String, dynamic> data,
  ) {
    final requestId = data['request_id']?.toString().trim() ?? '';
    if (requestId.isEmpty) return const [];

    final rawQuestions = data['questions'];
    if (rawQuestions is List) {
      final requests = <GatewayClarifyRequest>[];
      for (final rawQuestion in rawQuestions) {
        if (rawQuestion is! Map) continue;
        final qid = rawQuestion['qid']?.toString().trim() ?? '';
        if (qid.isEmpty) continue;
        final choices = _normalizeChoices(rawQuestion['choices']);
        requests.add(
          GatewayClarifyRequest(
            requestId: requestId,
            questionId: qid,
            question: _normalizeQuestion(rawQuestion['question']?.toString()),
            choices: choices,
            multiSelect:
                rawQuestion['multi_select'] == true && choices.isNotEmpty,
          ),
        );
      }
      return requests;
    }

    final flat = fromEventData(data);
    return flat == null ? const [] : [flat];
  }

  /// Parses the single-question request params with their attached request ID.
  static GatewayClarifyRequest? fromEventData(Map<String, dynamic> data) {
    final requestId = data['request_id']?.toString().trim() ?? '';
    if (requestId.isEmpty) return null;

    final choices = _normalizeChoices(data['choices']);
    final question = _normalizeQuestion(data['question']?.toString());

    return GatewayClarifyRequest(
      requestId: requestId,
      question: question.isEmpty
          ? 'Hermes needs more information to continue.'
          : question,
      choices: choices,
      multiSelect: data['multi_select'] == true && choices.isNotEmpty,
    );
  }

  static List<String> _normalizeChoices(Object? rawChoices) {
    if (rawChoices is! List) return const <String>[];
    return rawChoices
        .whereType<String>()
        .where(
          (choice) =>
              choice.trim().isNotEmpty &&
              choice.length <= 200 &&
              !choice.contains('\n') &&
              !choice.contains('\r'),
        )
        .toList(growable: false);
  }

  static String _normalizeQuestion(String? rawQuestion) =>
      rawQuestion?.trim() ?? '';
}

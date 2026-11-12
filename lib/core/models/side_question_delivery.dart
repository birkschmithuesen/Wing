import 'composer_reference.dart';

enum SideQuestionDeliveryState { pending, completed, failed }

enum SideQuestionDeliveryKind { sideQuestion, backgroundTask }

class SideQuestionDelivery {
  final SideQuestionDeliveryKind kind;
  final String? taskId;
  final String question;
  final SideQuestionDeliveryState state;
  final String result;
  final bool questionTruncated;
  final bool resultTruncated;

  const SideQuestionDelivery({
    this.kind = SideQuestionDeliveryKind.sideQuestion,
    required this.taskId,
    required this.question,
    required this.state,
    this.result = '',
    this.questionTruncated = false,
    this.resultTruncated = false,
  });

  SideQuestionDelivery complete({
    required String result,
    String? question,
    bool failed = false,
  }) => SideQuestionDelivery(
    kind: kind,
    taskId: taskId,
    question: this.question.isNotEmpty && !questionTruncated
        ? this.question
        : question ?? this.question,
    state: failed
        ? SideQuestionDeliveryState.failed
        : SideQuestionDeliveryState.completed,
    result: result,
    questionTruncated: question?.isNotEmpty == true ? false : questionTruncated,
    resultTruncated: false,
  );

  static List<SideQuestionDelivery> parseSnapshot(Object? value) {
    if (value is! Map ||
        value['retention'] != 'live_session' ||
        value['tasks'] is! List) {
      return const [];
    }
    final deliveries = <SideQuestionDelivery>[];
    final ids = <String>{};
    for (final raw in value['tasks'] as List) {
      if (raw is! Map) return const [];
      final taskId = raw['task_id'];
      final kindValue = raw['kind'];
      final prompt = raw['prompt'];
      final promptTruncated = raw['prompt_truncated'];
      final status = raw['status'];
      final result = raw['result'];
      final resultTruncated = raw['result_truncated'];
      if (taskId is! String ||
          taskId.trim().isEmpty ||
          taskId.trim() != taskId ||
          !ids.add(taskId) ||
          prompt is! String ||
          prompt.length > 65536 ||
          promptTruncated is! bool ||
          resultTruncated is! bool ||
          status is! String ||
          (status == 'running' ? result != null : result is! String) ||
          (result is String && result.length > 65536)) {
        return const [];
      }
      final kind = switch (kindValue) {
        'background' => SideQuestionDeliveryKind.backgroundTask,
        'btw' => SideQuestionDeliveryKind.sideQuestion,
        _ => null,
      };
      final state = switch (status) {
        'running' => SideQuestionDeliveryState.pending,
        'completed' => SideQuestionDeliveryState.completed,
        'error' => SideQuestionDeliveryState.failed,
        _ => null,
      };
      if (kind == null || state == null) return const [];
      final prepared = PreparedComposerMessage.parse(prompt);
      final original =
          prepared?.message ??
          (promptTruncated
              ? PreparedComposerMessage.truncatedMessage(prompt)
              : null);
      deliveries.add(
        SideQuestionDelivery(
          kind: kind,
          taskId: taskId,
          question:
              original ??
              (promptTruncated &&
                      prompt.startsWith(PreparedComposerMessage.header)
                  ? 'Question text is unavailable in this snapshot.'
                  : prompt),
          state: state,
          result: result is String ? result : '',
          questionTruncated: original == null && promptTruncated,
          resultTruncated: resultTruncated,
        ),
      );
    }
    return List.unmodifiable(deliveries);
  }
}

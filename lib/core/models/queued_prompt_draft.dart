import 'composer_reference.dart';
import 'attachment_draft.dart';

class QueuedPromptDraft {
  final String text;
  final String? voiceContext;
  final List<ComposerReference> references;
  final List<AttachmentDraft> attachments;
  final bool submissionUncertain;
  final String? submissionId;
  final Map<String, dynamic>? submissionPayload;

  QueuedPromptDraft({
    required this.text,
    this.voiceContext,
    Iterable<ComposerReference> references = const [],
    Iterable<AttachmentDraft> attachments = const [],
    this.submissionUncertain = false,
    this.submissionId,
    this.submissionPayload,
  }) : references = List.unmodifiable(references),
       attachments = List.unmodifiable(attachments);
}

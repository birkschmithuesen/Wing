import 'composer_reference.dart';
import 'attachment_draft.dart';
import 'composer_action.dart';

/// Identity belongs to the queue entry, not a particular uncertainty snapshot.
final class ComposerQueueId {
  ComposerQueueId();
}

final class ComposerAttachmentObservation {
  const ComposerAttachmentObservation({
    required this.id,
    required this.name,
    required this.mediaType,
    required this.kind,
    required this.status,
    required this.error,
    required this.refText,
  });

  final String id;
  final String name;
  final String mediaType;
  final AttachmentDraftKind kind;
  final AttachmentDraftStatus status;
  final String? error;
  final String? refText;
  bool get isImage => kind == AttachmentDraftKind.image;
}

final class ComposerQueueObservation {
  ComposerQueueObservation({
    required this.id,
    required this.text,
    Iterable<ComposerReference> references = const [],
    required Iterable<ComposerAttachmentObservation> attachments,
    required this.submissionUncertain,
    this.serverOwned = false,
    this.unknownOutcome = false,
    this.pendingSteering = false,
  }) : references = List.unmodifiable(references),
       attachments = List.unmodifiable(attachments);

  final ComposerQueueId id;
  final String text;
  final List<ComposerReference> references;
  final List<ComposerAttachmentObservation> attachments;
  final bool submissionUncertain;
  final bool serverOwned, unknownOutcome, pendingSteering;
}

/// Server support is separate from temporary admission. Views omit unsupported
/// actions and explain restrictions on supported actions without guessing origin.
final class ComposerQueueActions {
  const ComposerQueueActions({
    required this.supportsEdit,
    required this.supportsSteer,
    required this.supportsDelete,
    required this.editUnavailableReason,
    required this.steerUnavailableReason,
    required this.deleteUnavailableReason,
  });

  final bool supportsEdit, supportsSteer, supportsDelete;
  final String? editUnavailableReason,
      steerUnavailableReason,
      deleteUnavailableReason;
  bool get canDelete => supportsDelete && deleteUnavailableReason == null;
  bool get canEdit => supportsEdit && editUnavailableReason == null;
  bool get canSteer => supportsSteer && steerUnavailableReason == null;
}

enum ComposerUnavailableReason {
  dictation,
  reconnect,
  saving,
  preparingAttachment,
  empty,
  disconnectedCommand,
  currentTurn,
  steering,
  needsRunningTurn,
  textOnly,
  textRequired,
  sending,
  queueDuringTurn,
}

/// Runtime facts are read-only input. They never transfer runtime ownership.
final class ComposerRuntimeObservation {
  const ComposerRuntimeObservation({
    required this.runtimeId,
    required this.working,
    required this.canSteer,
    required this.connected,
    required this.attachmentBlocked,
    required this.automaticDrainAvailable,
    required this.switching,
    required this.changingAnswer,
    required this.commandRunning,
    required this.changingIntelligence,
    required this.failedOrCancelled,
    required this.historyAvailable,
  });

  final String runtimeId;

  final bool working;
  final bool canSteer;
  final bool connected;
  final bool attachmentBlocked;

  /// Automatic sending requires positively observed access and live transport.
  /// Optimistic availability offered by the UI does not grant this authority.
  final bool automaticDrainAvailable;
  final bool switching;
  final bool changingAnswer;
  final bool commandRunning;
  final bool changingIntelligence;
  final bool failedOrCancelled;
  final bool historyAvailable;
}

/// One locally prepared batch; progress is indeterminate until it is saved.
final class ComposerAttachmentPreparation {
  const ComposerAttachmentPreparation({
    required this.imageCount,
    required this.fileCount,
  });

  final int imageCount;
  final int fileCount;
  int get count => imageCount + fileCount;
}

final class ComposerObservation {
  ComposerObservation({
    required this.revision,
    required this.text,
    Iterable<ComposerReference> references = const [],
    required this.submissionUncertain,
    required Iterable<ComposerAttachmentObservation> attachments,
    required Iterable<ComposerQueueObservation> queue,
    required this.editing,
    required this.editText,
    required this.paused,
    required this.saving,
    required this.draining,
    required this.preparing,
    required this.attachmentPreparation,
    required this.sending,
    required this.steering,
    required this.restored,
    required this.error,
  }) : references = List.unmodifiable(references),
       attachments = List.unmodifiable(attachments),
       queue = List.unmodifiable(queue);

  final int revision;
  final String text;
  final List<ComposerReference> references;
  final bool submissionUncertain;
  final List<ComposerAttachmentObservation> attachments;
  final List<ComposerQueueObservation> queue;
  final ComposerQueueId? editing;
  final String editText;
  final bool paused;
  final bool saving;
  final bool draining;
  final bool preparing;
  final ComposerAttachmentPreparation? attachmentPreparation;
  final bool sending;
  final bool steering;
  final bool restored;
  final String? error;
  String get displayedText => editing == null ? text : editText;
  ComposerQueueObservation? get editingEntry =>
      queue.where((item) => identical(item.id, editing)).firstOrNull;
}

/// A captured claim on outgoing work; only its issuing owner can settle it.
final class ComposerSubmission {
  ComposerSubmission({
    required this.submissionId,
    required this.text,
    this.voiceContext,
    Iterable<ComposerReference> references = const [],
    required Iterable<ComposerAttachmentObservation> attachments,
  }) : references = List.unmodifiable(references),
       attachments = List.unmodifiable(attachments);

  final String submissionId;
  final String text;
  final String? voiceContext;
  final List<ComposerReference> references;
  final List<ComposerAttachmentObservation> attachments;
}

final class ComposerTransfer {
  ComposerTransfer();
}

final class ComposerSavedWork {
  ComposerSavedWork({
    required this.text,
    Iterable<ComposerReference> references = const [],
    required Iterable<ComposerAttachmentObservation> attachments,
    required Iterable<ComposerQueueObservation> queuedPrompts,
    required this.queuePaused,
  }) : references = List.unmodifiable(references),
       attachments = List.unmodifiable(attachments),
       queuedPrompts = List.unmodifiable(queuedPrompts);
  final String text;
  final List<ComposerReference> references;
  final List<ComposerAttachmentObservation> attachments;
  final List<ComposerQueueObservation> queuedPrompts;
  final bool queuePaused;
}

enum ComposerDelivery { definitelyUnsent, uncertain, accepted }

final class ComposerPauseCapture {
  const ComposerPauseCapture();
}

/// The adapter gets bytes/metadata, never the mutable owned attachment record.
final class ComposerUpload {
  const ComposerUpload({
    required this.name,
    required this.isImage,
    required this.dataUrl,
  });

  final String name;
  final bool isImage;
  final String dataUrl;
}

final class ComposerActions {
  ComposerActions(
    Map<ComposerAction, ComposerUnavailableReason?> reasons, {
    required this.canEditQueue,
    required this.canSaveQueueEdit,
    required this.canSteerQueueEdit,
    required this.prefersRunningAction,
    required this.prefersStopAction,
    required this.canResumeQueue,
    required this.editingBusy,
    required this.canEditText,
  }) : unavailable = Map.unmodifiable(reasons);

  final Map<ComposerAction, ComposerUnavailableReason?> unavailable;
  final bool canEditQueue;
  final bool canSaveQueueEdit;
  final bool canSteerQueueEdit;
  final bool prefersRunningAction;
  final bool prefersStopAction;
  final bool canResumeQueue;
  final bool editingBusy;
  final bool canEditText;

  ComposerAction? primaryAction(ComposerAction? runningAction) {
    if (prefersStopAction) return ComposerAction.stop;
    if (!prefersRunningAction) return ComposerAction.send;
    if (runningAction == null) return null;
    return unavailable[runningAction] == null ||
            unavailable[ComposerAction.send] != null
        ? runningAction
        : ComposerAction.send;
  }
}

import '../core/models/chat_runtime.dart';
import '../core/services/profile_workspace_controller.dart';
import 'barge_in_policy.dart';

/// The ProfileChat state the fork voice driver and car mode read. The only
/// place that follows upstream's chat.runtime / chat.composer split.
extension ChatVoiceView on ProfileChat {
  bool get voiceBusy => runtime.blocksTurnAdmission;

  String get voiceDraft => composer.observation.text;

  /// Approvals, clarify questions and secure prompts need the user's hands or
  /// eyes, so they end a hands-free conversation.
  bool get needsUserInput => runtime.needsInput;

  bool get voiceOpening => runtime.opening;

  bool get voiceOffline => runtime.offline;

  bool get voiceCommandRunning => runtime.commandRunning;

  bool get voiceChangingAnswer => runtime.changingAnswer;

  bool get voiceEditingQueue => composer.observation.editing != null;

  bool get voiceTurnEnded =>
      runtime.execution == ChatExecution.failed ||
      runtime.execution == ChatExecution.cancelled;

  ListenChatState get listenState => runtime.canSteer || runtime.needsInput
      ? ListenChatState.steerable
      : runtime.execution == ChatExecution.submitting ||
            runtime.reconnecting ||
            runtime.executionActive
      ? ListenChatState.busy
      : ListenChatState.idle;
}

import '../core/services/profile_workspace_controller.dart';
import 'barge_in_policy.dart';

/// The ProfileChat fields the fork voice driver reads. At the upstream merge
/// only this file follows upstream's chat.composer / chat.runtime split.
extension ChatVoiceView on ProfileChat {
  bool get voiceBusy => busy;

  String get voiceDraft => draft;

  /// Approvals, clarify questions and secure prompts need the user's hands or
  /// eyes, so they end a hands-free conversation.
  bool get needsUserInput =>
      approval != null || clarification != null || sensitivePrompt != null;

  ListenChatState get listenState => switch (status) {
    ProfileTurnStatus.running ||
    ProfileTurnStatus.attention => ListenChatState.steerable,
    ProfileTurnStatus.submitting ||
    ProfileTurnStatus.reconnecting => ListenChatState.busy,
    _ => ListenChatState.idle,
  };
}

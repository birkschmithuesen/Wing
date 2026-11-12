import '../core/models/queued_prompt_draft.dart';
import '../core/services/profile_gateway.dart';
import '../core/services/profile_workspace_controller.dart';

/// Returns null when the server's own history can't be read right now
/// (undecidable: the caller must pause and ask the user, never guess).
///
/// [gatewayOf] resolves the chat's gateway inside the guarded block, as the
/// controller's ownership lookup may throw.
Future<bool?> queuedHeadDelivered(
  ProfileGateway Function() gatewayOf,
  ProfileChat chat,
  QueuedPromptDraft queued,
) async {
  try {
    final page = await gatewayOf().history(
      chat.key.sessionId,
      runtimeId: chat.runtimeId,
    );
    return page.rows.any(
      (row) => row['role'] == 'user' && row['content'] == queued.text,
    );
  } catch (_) {
    return null;
  }
}

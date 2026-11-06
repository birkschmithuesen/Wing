import 'chat_runtime.dart';
import 'transcript_reading.dart';

/// Shared display handoff for live chats and passive worker event replay.
/// Each caller keeps transport, publication fencing and completion authority.
void applyChatTranscriptEvent({
  required ChatRuntime runtime,
  required TranscriptReading reading,
  required String type,
  required Map<String, dynamic> data,
  bool live = true,
}) {
  switch (type) {
    case 'message.start':
      if (!reading.startReply(data)) return;
      if (!runtime.observation.executionActive) {
        runtime.beginTurn(submitting: false);
        reading.cancelReads();
      }
    case 'message.delta':
      final text = data['text']?.toString() ?? '';
      if (reading.appendReplyDelta(data)) runtime.observeText(text);
    case 'message.interim':
      if (reading.sealReply(data, turnGeneration: runtime.turnRevision)) {
        runtime.finishSegment();
      }
    case 'tool.generating':
    case 'tool.start':
    case 'tool.progress':
    case 'tool.complete':
      final activity = runtime.observeTool(type, data, live: live);
      if (activity != null &&
          type != 'tool.generating' &&
          type != 'tool.progress') {
        reading.observeTool(activity);
      }
    case 'reasoning.delta':
    case 'reasoning.available':
      runtime.observeReasoning(type, data);
  }
}

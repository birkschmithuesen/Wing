import 'package:flutter/material.dart';

import '../models/chat_output.dart';
import '../models/profile_session_key.dart';
import '../screens/chat_outputs_screen.dart';
import '../services/transcript_resource_session.dart';
import 'activity/skill_document_viewer.dart';
import '../models/transcript_presentation.dart';
import '../models/transcript_timeline.dart';
import '../screens/profile_transcript.dart';
import '../models/profile_supervision.dart';
import 'activity/activity_detail_actions.dart';
import 'conversation_activity.dart';
import 'profile_message.dart';
import 'studio_error.dart';
import 'studio_loading.dart';

/// Uses the same projection, viewport, tool and reasoning renderers as chat.
class SubagentTimeline extends StatefulWidget {
  const SubagentTimeline({
    super.key,
    required this.session,
    required this.createResources,
    required this.agentsBuilder,
  });
  final SubagentTimelineReader session;
  final TranscriptResourceSession Function(ProfileSessionKey) createResources;
  final Widget Function(SubagentInspectionSession) agentsBuilder;

  @override
  State<SubagentTimeline> createState() => _SubagentTimelineState();
}

class _SubagentTimelineState extends State<SubagentTimeline> {
  late TranscriptResourceSession _resources = widget.createResources(
    widget.session.state.key,
  );
  SubagentTimelineReader get session => widget.session;

  @override
  void didUpdateWidget(SubagentTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, session)) {
      _resources.dispose();
      _resources = widget.createResources(session.state.key);
    }
  }

  @override
  void dispose() {
    _resources.dispose();
    super.dispose();
  }

  bool _canDeliver(TranscriptResourceSession resources) =>
      mounted &&
      identical(resources, _resources) &&
      ModalRoute.of(context)?.isCurrent == true;

  Future<void> _openResource(ChatOutput output) async {
    final resources = _resources;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatOutputsScreen(
          chatTitle: 'Subagent activity',
          initialOutput: output,
          createSession: resources.createOutputsSession,
        ),
      ),
    );
  }

  Future<void> _shareResource(ChatOutput output) {
    final resources = _resources;
    return resources.files.downloadAndShare(
      output.path!,
      admitPresentation: () => _canDeliver(resources),
    );
  }

  Future<bool> _saveResource(ChatOutput output) {
    final resources = _resources;
    return resources.files.downloadAndSave(
      output.path!,
      admitPresentation: () => _canDeliver(resources),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final projection = ChatTranscriptProjection(
        savedRows: session.messages,
        requestActivities: session.requestActivities,
        streamingMessage: session.streamingMessage,
        runtime: session.runtime,
        presentationId: session.messagePresentationId,
        liveAnswering: session.liveAnswering,
      );
      final activity = ConversationActivity(
        runtime: session.runtime,
        entries: projection.activity,
        beforeMessagePresentationId:
            projection.retainedActivityBeforePresentationId,
        todos: session.todos,
        inspection: session,
        agentsBuilder: () => widget.agentsBuilder(session),
        live: session.liveAnswering,
        taskCount: session.todos.length,
        agentCount: session.state.subagents.length,
      );
      return SkillReaderScope(
        createReader: (document) =>
            _resources.skillReader(document.readerTarget),
        child: StudioPageLoading(
          active: session.historyLoading && !session.historyPaging,
          label: 'Loading subagent activity',
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ProfileTranscript(
                    key: ObjectKey(session),
                    presentation: TranscriptPresentation.capture(
                      identity: ('subagent', session.state.key),
                      reader: session,
                      timeline: projection.timeline,
                      needsInput: false,
                      turnAdmissionBlocked: session.liveAnswering,
                    ),
                    onRefreshHistory: session.refresh,
                    onLoadOlder: session.loadOlder,
                    loadImage: _resources.loadImage,
                    onOpenResource: _openResource,
                    onShareResource: _shareResource,
                    activity: activity,
                    emptyContent: const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No subagent activity is available yet.'),
                    ),
                    tail: const [],
                    messageBuilder: (entry) => ProfileMessage(
                      message: entry.message,
                      loadAttachmentImage: _resources.loadImage,
                      onOpenRemoteFile: _openResource,
                      onShareRemoteFile: _shareResource,
                      onDownloadRemoteFile: _saveResource,
                    ),
                  ),
                ),
                if (session.qualification case final text?)
                  _boundedFeedback(
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(text),
                    ),
                    constraints.maxHeight * 0.2,
                  ),
                if (session.liveError case final error?)
                  Row(
                    children: [
                      Expanded(
                        child: _boundedFeedback(
                          StudioError(error),
                          constraints.maxHeight * 0.35,
                        ),
                      ),
                      ActivityDetailAction(
                        label: 'Retry subagent activity',
                        icon: Icons.refresh,
                        onPressed: session.refresh,
                      ),
                    ],
                  ),
                activity.dock(),
              ],
            ),
          ),
        ),
      );
    },
  );
  Widget _boundedFeedback(Widget child, double height) => ConstrainedBox(
    constraints: BoxConstraints(maxHeight: height),
    child: SingleChildScrollView(primary: false, child: child),
  );
}

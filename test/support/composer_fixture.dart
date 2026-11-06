import 'package:wing/core/models/gateway_approval.dart';
import 'package:wing/core/services/chat_runtime.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/models/composer_work.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:wing/core/services/composer_session.dart';
import 'package:wing/core/services/transcript_reading.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/server_connection_status.dart';

/// Explicit composition for standalone read-only transcript fixtures.
/// Canonical registry fixtures cross the controller open/create commands below.
ProfileChat composeChat({
  required ProfileWorkspaceController controller,
  required SharedPreferences preferences,
  required ProfileSessionKey key,
  required ChatRuntime runtime,
  required String title,
  String source = '',
  String? parentSessionId,
  String? projectId,
}) {
  late final ProfileChat chat;
  final capturedResource = controller.current?.scope == key.workspace
      ? controller.current
      : null;
  final composer = ComposerSession(
    key: key,
    store: ComposerDraftStore(
      preferences,
      connectionIdentity: key.workspace.connectionIdentity,
    ),
    attachments: controller.attachments,
    ensureAvailable: () {
      if (!controller.owns(key)) {
        throw StateError('This workspace is no longer available.');
      }
    },
    acknowledgedDeletion: () =>
        capturedResource?.deletedSessions.contains(key.sessionId) == true,
    runtime: () => ComposerRuntimeObservation(
      runtimeId: chat.runtime.runtimeId,
      working: chat.runtime.blocksTurnAdmission,
      canSteer: chat.runtime.canSteer,
      attachmentBlocked: chat.attachmentBlocked,
      connected:
          !chat.runtime.offline &&
          !chat.runtime.opening &&
          !controller.recovering,
      automaticDrainAvailable:
          !chat.runtime.offline &&
          !chat.runtime.opening &&
          !controller.recovering &&
          controller.connectionStatus.access ==
              ConnectionAvailability.available &&
          controller.connectionStatus.liveAvailable(key.workspace.profileName),
      switching: controller.switching,
      changingAnswer: chat.runtime.changingAnswer,
      commandRunning: chat.runtime.commandRunning,
      changingIntelligence: chat.changingIntelligence,
      failedOrCancelled: {
        ChatExecution.failed,
        ChatExecution.cancelled,
      }.contains(chat.runtime.execution),
      historyAvailable: chat.reading.historyError == null,
    ),
    onChanged: (_) {},
  );
  chat = ProfileChat(
    key: key,
    runtime: runtime,
    title: title,
    source: source,
    parentSessionId: parentSessionId,
    projectId: projectId,
    composer: composer,
    reading: TranscriptReading(
      gateway:
          (capturedResource ??
                  controller.browserResource(key.workspace.profileName))
              .gateway,
    ),
  );
  return chat;
}

/// Seeds the real existing record codec, then crosses the production restoration
/// interface. No fixture writes composer fields or substitutes a mutable view.
Future<void> restoreComposerFixture({
  required ProfileChat chat,
  required SharedPreferences preferences,
  String? text,
  Iterable<AttachmentDraft>? attachments,
  Iterable<QueuedPromptDraft>? queuedPrompts,
  Iterable<AttachmentDraft> appendAttachments = const [],
  Iterable<QueuedPromptDraft> appendQueued = const [],
  bool? uncertain,
  bool? paused,
}) async {
  final store = ComposerDraftStore(
    preferences,
    connectionIdentity: chat.key.workspace.connectionIdentity,
  );
  await chat.composer.admittedWrites;
  final saved = await store.read(
    profileName: chat.key.workspace.profileName,
    sessionId: chat.key.sessionId,
  );
  await store.write(
    profileName: chat.key.workspace.profileName,
    sessionId: chat.key.sessionId,
    text: text ?? saved?.text ?? chat.composer.observation.text,
    attachments: [
      ...?(attachments ?? saved?.attachments),
      ...appendAttachments,
    ],
    queuedPrompts: [
      ...?(queuedPrompts ?? saved?.queuedPrompts),
      ...appendQueued,
    ],
    submissionUncertain: uncertain ?? saved?.submissionUncertain ?? false,
    queuePaused: paused ?? saved?.queuePaused ?? false,
  );
  await chat.composer.restoreSavedWork();
}

Future<ComposerDraftSnapshot?> readComposerFixture({
  required ProfileChat chat,
  required SharedPreferences preferences,
}) =>
    ComposerDraftStore(
      preferences,
      connectionIdentity: chat.key.workspace.connectionIdentity,
    ).read(
      profileName: chat.key.workspace.profileName,
      sessionId: chat.key.sessionId,
    );

/// Delivers a stock event through the registered, captured controller callback.
/// It does not expose the private runtime writer or bypass owner admission.
int _fixtureReplySequence = 0;
final _fixtureReplies = Expando<Map<String, Object>>();

Map<String, dynamic> stockChatReply(
  Object owner,
  String type,
  Map<String, dynamic> data,
) {
  if (!{'message.start', 'message.delta', 'message.interim'}.contains(type)) {
    return data;
  }
  var state = _fixtureReplies[owner];
  final explicit = data['turn_id'];
  if (state == null ||
      type == 'message.start' &&
          (explicit == null || state['turn'] != explicit)) {
    state = {
      'turn': explicit is String
          ? explicit
          : 'chat-fixture-${++_fixtureReplySequence}',
      'segment': 0,
      'offset': 0,
    };
    _fixtureReplies[owner] = state;
  }
  final stamped = <String, dynamic>{
    'turn_id': state['turn'],
    if (type != 'message.start') 'segment': state['segment'],
    if (type == 'message.delta') 'offset': state['offset'],
    ...data,
  };
  if (type == 'message.delta') {
    state['offset'] =
        (stamped['offset'] as int) + (data['text']?.toString().length ?? 0);
  }
  if (type == 'message.interim') {
    state['segment'] = (stamped['segment'] as int) + 1;
    state['offset'] = 0;
  }
  return stamped;
}

void emitChatEvent(
  ProfileWorkspaceController controller,
  ProfileChat chat,
  String type, [
  Map<String, dynamic> data = const {},
]) {
  final gateway = controller
      .browserResource(chat.key.workspace.profileName)
      .gateway;
  data = stockChatReply(gateway, type, data);
  final deliver = gateway.onEvent;
  if (deliver == null) {
    throw StateError('The fixture gateway is not connected.');
  }
  if (type == 'approval' && data['server_request_id'] == null) {
    final generation = gateway.canonical
        .session(chat.runtime.runtimeId)!
        .generation;
    type = 'approval.request';
    data = {
      ...data,
      'kind': 'approval',
      'prompt_id': data['request_id'],
      'execution_generation': generation,
      'choices': GatewayApprovalRequest.fromEventData(
        data,
      ).choices.map((choice) => choice.wireValue).toList(),
    }..remove('request_id');
  }
  deliver(
    StreamEvent(type: type, data: data, sessionId: chat.runtime.runtimeId),
  );
}

/// Owns fixture composition references, never canonical workspace state.
final class WorkspaceRuntimeFixture {
  final _runtimes = <(ProfileSessionKey, String), ChatRuntime>{};
  ChatRuntime create(ProfileSessionKey key, String runtimeId) {
    final runtime = ChatRuntime(runtimeId: runtimeId);
    _runtimes[(key, runtimeId)] = runtime;
    return runtime;
  }

  ChatRuntime forChat(ProfileChat chat) => _runtimes.entries
      .singleWhere(
        (entry) =>
            entry.key.$1 == chat.key &&
            entry.value.observation.runtimeId == chat.runtime.runtimeId,
      )
      .value;
}

/// Opens a captured stock fixture through actual registry/history admission.
Future<ProfileChat> openFixtureChat({
  required ProfileWorkspaceController controller,
  required ProfileSessionKey key,
  String? title,
  bool select = true,
}) async {
  final chat = select
      ? await controller.openSession(key)
      : await controller.loadNotificationApproval(key);
  if (chat == null) throw StateError('The captured fixture chat did not open.');
  if (!select) await chat.composer.restore();
  if (title != null) {
    emitChatEvent(controller, chat, 'session.title', {
      'session_id': key.sessionId,
      'title': title,
    });
  }
  return chat;
}

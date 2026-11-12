import 'hermes_question.dart';
import 'turn_failure.dart';
import 'gateway_activity.dart';
import 'gateway_approval.dart';
import 'gateway_clarify.dart';
import 'gateway_sensitive_prompt.dart';
import 'profile_live_activity.dart';

enum ChatExecution { idle, submitting, running, completed, cancelled, failed }

enum ChatRecovery { ready, opening, offline, reconnecting }

enum ChatMainActivity { working, thinking, writing, tool }

/// Ordered native observations. Identities address presentation only.
sealed class ChatActivityEntry {
  const ChatActivityEntry();
  Object get identity;
}

final class ChatToolEntry extends ChatActivityEntry {
  const ChatToolEntry(this.activity);
  final GatewayToolActivity activity;
  @override
  Object get identity => activity.toolId!;
}

/// Passive request lifecycle, never a native tool execution observation.
final class ChatRequestEntry extends ChatActivityEntry {
  const ChatRequestEntry(this.question);
  final HermesQuestion question;
  @override
  Object get identity => ('request', question.id);
}

final class ChatReasoningEntry extends ChatActivityEntry {
  const ChatReasoningEntry({
    required this.identity,
    required this.text,
    required this.source,
    this.availableText,
    this.running = false,
    this.postedAt,
  });
  @override
  final Object identity;
  final String text;
  final String source;

  /// A separately delivered preview never replaces already streamed text.
  final String? availableText;
  final bool running;

  /// First receipt of this reasoning block, retained across deltas and sealing.
  final DateTime? postedAt;

  ChatReasoningEntry sealed() => ChatReasoningEntry(
    identity: identity,
    text: text,
    source: source,
    availableText: availableText,
    postedAt: postedAt,
  );
}

/// The correlation is issued by the runtime owner, not inferred from display text.
class ChatApproval {
  ChatApproval({
    required this.correlation,
    required this.requestId,
    required this.serverRequestId,
    required GatewayApprovalRequest request,
    required this.eventId,
    this.nativeGeneration,
  }) : request = GatewayApprovalRequest(
         command: request.command,
         description: request.description,
         allowPermanent: request.allowPermanent,
         smartDenied: request.smartDenied,
         choices: List.unmodifiable(request.choices),
       );
  final Object correlation;
  final String requestId;
  final String? serverRequestId;
  final GatewayApprovalRequest request;
  final String? eventId;

  /// Null identifies a current server-to-client request, not a native waiter.
  final int? nativeGeneration;
}

class ChatQuestions {
  ChatQuestions({
    required this.correlation,
    required Iterable<GatewayClarifyRequest> questions,
    required Iterable<String> answeredIds,
    required Map<String, String> lockedAnswers,
    this.nativeGeneration,
  }) : questions = List.unmodifiable(
         questions.map(
           (q) => GatewayClarifyRequest(
             requestId: q.requestId,
             questionId: q.questionId,
             question: q.question,
             choices: List.unmodifiable(q.choices),
             multiSelect: q.multiSelect,
           ),
         ),
       ),
       answeredIds = Set.unmodifiable(answeredIds),
       lockedAnswers = Map.unmodifiable(lockedAnswers);
  final Object correlation;
  final int? nativeGeneration;
  final List<GatewayClarifyRequest> questions;
  final Set<String> answeredIds;
  final Map<String, String> lockedAnswers;
  GatewayClarifyRequest? get pending => questions
      .where((q) => q.questionId == null || !answeredIds.contains(q.questionId))
      .firstOrNull;
  int get pendingCount => questions
      .where((q) => q.questionId == null || !answeredIds.contains(q.questionId))
      .length;
  int get pendingNumber =>
      pending == null ? 0 : questions.indexOf(pending!) + 1;
}

/// Passive facts only. Secret response values are never captured here.
class ChatRuntimeObservation {
  ChatRuntimeObservation({
    required this.runtimeId,
    required this.execution,
    required this.recovery,
    required this.liveSessionConfirmed,
    required this.openingError,
    required this.mainActivity,
    required this.compacting,
    required this.mainToolActivity,
    required Iterable<GatewayToolActivity> toolActivities,
    required Iterable<ChatActivityEntry> activityEntries,
    required Iterable<ChatApproval> approvals,
    required this.approvalPosition,
    required this.approvalTotal,
    required this.approvalResponding,
    required this.questions,
    required this.secureInput,
    required this.secureResponding,
    required this.commandRunning,
    required this.changingAnswer,
    required this.error,
    required this.decisionError,
    required this.decisionErrorRequestId,
    this.failure,
  }) : activityEntries = List.unmodifiable(activityEntries),
       toolActivities = List.unmodifiable(toolActivities),
       approvals = List.unmodifiable(approvals);
  final String runtimeId;
  final ChatExecution execution;
  final ChatRecovery recovery;

  /// True after a live session is admitted; passive snapshots never confirm it.
  final bool liveSessionConfirmed;
  final String? openingError;
  final ChatMainActivity mainActivity;

  /// A session-scoped phase, independent of a live turn or slash RPC.
  final bool compacting;
  final GatewayToolActivity? mainToolActivity;
  final Iterable<GatewayToolActivity> toolActivities;
  final List<ChatActivityEntry> activityEntries;
  final List<ChatApproval> approvals;
  final int approvalPosition;
  final int approvalTotal;
  final bool approvalResponding;
  final ChatQuestions? questions;
  final GatewaySensitivePromptRequest? secureInput;
  final bool secureResponding;
  final bool commandRunning;
  final bool changingAnswer;
  final String? error;
  final String? decisionError;
  final String? decisionErrorRequestId;
  final TurnFailure? failure;
  ChatApproval? get approval => approvals.firstOrNull;
  GatewayClarifyRequest? get pendingQuestion => questions?.pending;
  String? get tool => mainToolActivity?.name;
  bool get needsInput =>
      approvals.isNotEmpty || pendingQuestion != null || secureInput != null;
  bool get executionActive =>
      execution == ChatExecution.submitting ||
      execution == ChatExecution.running;
  bool get opening => recovery == ChatRecovery.opening;
  bool get offline => !liveSessionConfirmed;
  bool get reconnecting => recovery == ChatRecovery.reconnecting;
  bool get blocksTurnAdmission => executionActive || needsInput || reconnecting;
  bool get canSteer =>
      execution == ChatExecution.running && recovery == ChatRecovery.ready;
  ProfileLiveActivityState? activity({required bool backgroundWorking}) =>
      needsInput
      ? ProfileLiveActivityState.needsInput
      : executionActive || compacting || reconnecting || backgroundWorking
      ? ProfileLiveActivityState.running
      : null;
}

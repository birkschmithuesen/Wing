import 'dart:convert';
import '../models/turn_failure.dart';
import '../models/hermes_question.dart';
import '../models/chat_runtime.dart';
import '../models/gateway_activity.dart';
import '../models/gateway_approval.dart';
import '../models/gateway_clarify.dart';
import '../models/gateway_insight.dart';
import '../models/gateway_sensitive_prompt.dart';
import '../utils/tool_activity_clock.dart';

part 'chat_runtime_questions.dart';

class ChatRuntimeRead {
  ChatRuntimeRead._(
    this._owner,
    this.runtimeId,
    this._read,
    this._turn,
    this._resume,
    this._event,
    this._input,
    this._execution,
    this._recovery,
  );
  final ChatRuntime _owner;
  final String runtimeId;
  final int _read, _turn, _resume, _event;
  final String _input;
  final ChatExecution _execution;
  final ChatRecovery _recovery;
  bool get current => _owner._owns(this);
}

/// Captures an operation's original facts for definite refusal.
/// It never grants permission to call a gateway.
class ChatRuntimeOperation {
  ChatRuntimeOperation._(
    this._owner,
    this.runtimeId,
    this._turn,
    this._execution,
    this._main,
    this._tool,
  );
  final ChatRuntime _owner;
  final String runtimeId;
  final int _turn;
  final ChatExecution _execution;
  final ChatMainActivity _main;
  final GatewayToolActivity? _tool;
}

class ChatRuntimeApprovalRead {
  ChatRuntimeApprovalRead._(
    this._owner,
    this.runtimeId,
    this._read,
    this._revision,
  );
  final ChatRuntime _owner;
  final String runtimeId;
  final int _read, _revision;
}

/// Issued only for a returned slash prompt. It binds the command and exact
/// preflight; it never grants transport or composer authority.
class ChatRuntimeCommandPrompt {
  ChatRuntimeCommandPrompt._(
    this._owner,
    this.runtimeId,
    this._command,
    this._turn,
    this._preflight,
  );
  final ChatRuntime _owner;
  final String runtimeId;
  final int _command;
  int _turn;
  final GatewaySensitivePromptRequest? _preflight;
  bool _accepted = false, _revoked = false;
  bool get current => _owner._ownsCommandPrompt(this);
}

class ChatRuntimeAnswer {
  ChatRuntimeAnswer._(
    this._owner,
    this.runtimeId,
    this._request,
    this._turn,
    this._events,
  );
  final ChatRuntime _owner;
  final String runtimeId;
  final Object _request;
  final int _turn, _events;
  String? _approvalChoice, _questionHistoryId;
  bool get current => _owner._ownsAnswer(this);
}

/// One execution/recovery/input writer. It owns no gateway, transcript, draft
/// store or secret response value. Transport admission remains with the workspace.
class ChatRuntime {
  ChatRuntime({required this._runtimeId});
  String _runtimeId;
  final _questionHistory = <String, HermesQuestion>{};
  void Function(HermesQuestion)? onQuestion;
  void Function(HermesQuestionKind, Set<String>)? onQuestionReconciliation;

  void publishQuestionHistory() {
    for (final question in _questionHistory.values) {
      onQuestion?.call(question);
    }
  }

  void cancelQuestion(String requestId) {
    _settleQuestionRequest(requestId, HermesQuestionStatus.cancelled);
    if (_serverQuestions?.pending?.requestId == requestId) {
      _serverQuestions = null;
    }
  }

  void closeQuestion(String requestId) {
    _settleQuestionRequest(requestId, HermesQuestionStatus.closed);
    if (_serverQuestions?.pending?.requestId == requestId) {
      _serverQuestions = null;
    }
  }

  bool _closed = false;
  bool _liveSessionConfirmed = true;
  ChatExecution _execution = ChatExecution.idle;
  ChatRecovery _recovery = ChatRecovery.ready;
  String? _openingError, _error, _commandError;
  TurnFailure? _failure;
  ChatMainActivity _main = ChatMainActivity.working;
  bool _compacting = false;
  GatewayToolActivity? _mainTool;
  final _tools = <GatewayToolActivity>[];
  final _activity = <ChatActivityEntry>[];
  int _reasoningOrdinal = 0;
  final _approvals = GatewayApprovalQueue();
  final _approvalCorrelations = <String, Object>{};
  bool _approvalResponding = false;
  Object? _answeringApproval;
  ChatQuestions? _serverQuestions;
  final _nativeClarifications = <String, ChatQuestions>{};
  ChatQuestions? get _nativeQuestions =>
      _nativeClarifications.values.firstOrNull;
  set _nativeQuestions(ChatQuestions? value) {
    if (value == null) {
      _nativeClarifications.remove(_nativeQuestions?.pending?.requestId);
    } else {
      _nativeClarifications[value.pending!.requestId] = value;
    }
  }

  int? _nativeGeneration;
  final _settledNativePrompts = <(String, String, int)>{};
  ChatQuestions? get _questions => _nativeQuestions ?? _serverQuestions;
  set _questions(ChatQuestions? value) {
    if (value?.nativeGeneration != null ||
        value == null && _nativeQuestions != null) {
      _nativeQuestions = value;
    } else {
      _serverQuestions = value;
    }
  }

  Set<String> get _activeClarificationIds => {
    for (final lane in [..._nativeClarifications.values, _serverQuestions])
      for (final q in lane?.questions ?? const <GatewayClarifyRequest>[])
        _clarifyHistoryId(q, lane?.nativeGeneration),
  };
  GatewaySensitivePromptRequest? _secure;
  bool _secureResponding = false;
  bool _commandRunning = false,
      _changingAnswer = false,
      _commandDispatchPending = false;
  GatewaySensitivePromptRequest? _commandPreflight;
  ChatRuntimeCommandPrompt? _commandPrompt;
  int _commandRevision = 0;
  int _turn = 0, _resume = 0, _read = 0, _events = 0, _approvalRead = 0;
  String? _decisionError, _decisionErrorRequestId;

  ChatApproval _approval(Map<String, dynamic> raw) => ChatApproval(
    correlation: _approvalCorrelations.putIfAbsent(
      raw['request_id'] as String,
      Object.new,
    ),
    requestId: raw['request_id'] as String,
    nativeGeneration: raw['execution_generation'] as int?,
    serverRequestId: raw['server_request_id'] is String
        ? raw['server_request_id'] as String
        : null,
    request: GatewayApprovalRequest.fromEventData(raw),
    eventId: raw['mobile_push_event_id'] is String
        ? (raw['mobile_push_event_id'] as String).trim()
        : null,
  );
  ChatRuntimeObservation get observation => ChatRuntimeObservation(
    runtimeId: _runtimeId,
    execution: _execution,
    recovery: _recovery,
    liveSessionConfirmed: _liveSessionConfirmed,
    openingError: _openingError,
    mainActivity: _main,
    compacting: _compacting,
    mainToolActivity: _mainTool,
    toolActivities: _tools,
    activityEntries: _activity,
    approvals: _approvals.requests.map(_approval),
    approvalPosition: _approvals.position,
    approvalTotal: _approvals.total,
    approvalResponding: _approvalResponding,
    questions: _questions,
    secureInput: _secure,
    secureResponding: _secureResponding,
    commandRunning: _commandRunning,
    changingAnswer: _changingAnswer,
    error: _error ?? _commandError,
    decisionError: _decisionError,
    decisionErrorRequestId: _decisionErrorRequestId,
    failure: _error == null ? null : _failure,
  );
  int get turnRevision => _turn;
  int get resumeRevision => _resume;
  bool get commandDispatchPending => _commandDispatchPending;

  /// A returned slash prompt may continue while the exact command preflight
  /// response receipt is outstanding. Ordinary sends/drains remain blocked.
  bool get canContinueCommandPrompt =>
      !_closed &&
      _commandRunning &&
      !observation.executionActive &&
      _recovery == ChatRecovery.ready &&
      _approvals.requests.isEmpty &&
      _questions?.pending == null &&
      (_secure == null ||
          (identical(_secure, _commandPreflight) && _secureResponding));
  ChatRuntimeCommandPrompt captureCommandPrompt() {
    if (!canContinueCommandPrompt) {
      throw StateError('The command continuation is no longer available.');
    }
    return _commandPrompt = ChatRuntimeCommandPrompt._(
      this,
      _runtimeId,
      _commandRevision,
      _turn,
      _commandPreflight,
    );
  }

  bool _ownsCommandPrompt(ChatRuntimeCommandPrompt capture) =>
      !_closed &&
      identical(capture._owner, this) &&
      identical(_commandPrompt, capture) &&
      !capture._revoked &&
      _commandRunning &&
      capture._command == _commandRevision &&
      capture.runtimeId == _runtimeId &&
      capture._turn == _turn &&
      _recovery == ChatRecovery.ready &&
      _approvals.requests.isEmpty &&
      _questions?.pending == null &&
      (capture._preflight == null
          ? _secure == null
          : identical(_secure, capture._preflight) && _secureResponding ||
                _secure == null && capture._accepted);
  void beginCommandPrompt(ChatRuntimeCommandPrompt capture) {
    if (!capture.current) {
      throw StateError('The command continuation has changed.');
    }
    beginTurn(submitting: true);
    capture._turn = _turn;
  }

  void _revokeCommandPrompt() {
    _commandPrompt?._revoked = true;
  }

  String _inputSignature() => jsonEncode([
    _approvals.requests,
    _approvals.total,
    _approvalResponding,
    _questions?.nativeGeneration,
    _questions?.questions
        .map(
          (q) => [
            q.requestId,
            q.questionId,
            q.question,
            q.choices,
            q.multiSelect,
          ],
        )
        .toList(),
    _questions?.answeredIds.toList(),
    _secure == null
        ? null
        : [
            _secure!.kind.name,
            _secure!.requestId,
            _secure!.title,
            _secure!.description,
            _secure!.fieldLabel,
          ],
    _secureResponding,
    _decisionError,
    _decisionErrorRequestId,
  ]);
  Map<String, dynamic> _approvalWire(Map<String, dynamic> raw) {
    final id = raw['request_id'];
    final previous = _approvals.requests
        .where(
          (r) =>
              r['request_id'] == id &&
              r['execution_generation'] == raw['execution_generation'],
        )
        .firstOrNull;
    final combined = {...?previous, ...raw};
    final parsed = GatewayApprovalRequest.fromEventData(combined);
    return {
      'request_id': id,
      'prompt_id': combined['prompt_id'],
      'execution_generation': combined['execution_generation'],
      'command': parsed.command,
      'description': parsed.description,
      'allow_permanent': parsed.allowPermanent,
      'smart_denied': parsed.smartDenied,
      'choices': parsed.choices.map((v) => v.wireValue).toList(growable: false),
      'server_request_id': combined['server_request_id'],
      if (combined['mobile_push_event_id'] is String)
        'mobile_push_event_id': combined['mobile_push_event_id'],
    };
  }

  bool _owns(ChatRuntimeRead capture) =>
      !_closed &&
      identical(capture._owner, this) &&
      capture.runtimeId == _runtimeId &&
      capture._read == _read &&
      capture._turn == _turn &&
      capture._resume == _resume &&
      capture._event == _events &&
      capture._input == _inputSignature() &&
      capture._execution == _execution &&
      capture._recovery == _recovery;
  ChatRuntimeRead captureRead({bool startRead = true}) {
    if (startRead) _read++;
    return ChatRuntimeRead._(
      this,
      _runtimeId,
      _read,
      _turn,
      _resume,
      _events,
      _inputSignature(),
      _execution,
      _recovery,
    );
  }

  void observeEvent(String type, Map<String, dynamic> data) {
    if (_closed) return;
    final wasCompacting = _compacting;
    final compressionStatus =
        type == 'status.update' &&
        const {
          'compacting',
          'compressing',
          'compacted',
          'ready',
        }.contains(data['kind']);
    if (compressionStatus) {
      _compacting =
          data['kind'] == 'compacting' || data['kind'] == 'compressing';
    } else if (const {
          'message.start',
          'message.delta',
          'message.interim',
          'message.complete',
          'turn.end',
          'reasoning.delta',
          'reasoning.available',
          'tool.start',
          'tool.generating',
          'tool.complete',
          'turn.error',
          'error',
        }.contains(type) ||
        type == 'session.info' && data['running'] == false) {
      // Retire only on stock completion or evidence that the main work resumed.
      // Child progress and a running heartbeat do not finish compression.
      _compacting = false;
    }
    final relevant = switch (type) {
      'session.info' => const [
        'open_requests',
        'prompts',
        'side_tasks',
        'model',
        'provider',
        'reasoning_effort',
        'yolo',
        'title',
      ].any(data.containsKey),
      'session.title' ||
      'message.start' ||
      'message.delta' ||
      'message.interim' ||
      'message.complete' ||
      'turn.end' ||
      'reasoning.delta' ||
      'reasoning.available' ||
      'tool.start' ||
      'tool.generating' ||
      'tool.complete' ||
      'todo.updated' ||
      'btw.complete' ||
      'background.complete' ||
      'approval.request' ||
      'approval.settled' ||
      'clarify.request' ||
      'clarify.settled' ||
      'approval' ||
      'clarify' ||
      'request.cancel' ||
      'sudo' ||
      'secret' ||
      'vault.unlock_prompt' ||
      'vault.save_login' ||
      'vault.code' ||
      'turn.error' ||
      'error' => true,
      _ => false,
    };
    if (relevant || compressionStatus || wasCompacting != _compacting) {
      _events++;
    }
  }

  ChatRuntimeOperation beginTurn({required bool submitting}) {
    final original = ChatRuntimeOperation._(
      this,
      _runtimeId,
      ++_turn,
      _execution,
      _main,
      _mainTool,
    );
    if (!_closed) {
      _execution = submitting
          ? ChatExecution.submitting
          : ChatExecution.running;
      _main = ChatMainActivity.working;
      _compacting = false;
      _mainTool = null;
      _tools.clear();
      _activity.clear();
      _error = null;
      _commandError = null;
    }
    return original;
  }

  ChatRuntimeOperation beginAnswerChange({required bool submitting}) {
    final capture = ChatRuntimeOperation._(
      this,
      _runtimeId,
      _turn,
      _execution,
      _main,
      _mainTool,
    );
    if (!_closed) {
      _changingAnswer = true;
      if (submitting) _execution = ChatExecution.submitting;
      _main = ChatMainActivity.working;
      _mainTool = null;
      _error = null;
      _commandError = null;
    }
    return capture;
  }

  void acceptTurn() {
    if (!_closed) _execution = ChatExecution.running;
  }

  void finishAnswerChange() {
    _changingAnswer = false;
  }

  void rejectRegeneration(
    ChatRuntimeOperation capture, {
    required bool dispatched,
    required String error,
  }) => _rejectAnswerChange(
    capture,
    dispatched: dispatched,
    failed: dispatched,
    error: error,
  );

  void rejectSavedPromptEdit(
    ChatRuntimeOperation capture, {
    required bool dispatched,
    required String error,
  }) => _rejectAnswerChange(
    capture,
    dispatched: dispatched,
    failed: false,
    error: error,
  );

  void _rejectAnswerChange(
    ChatRuntimeOperation capture, {
    required bool dispatched,
    required bool failed,
    required String error,
  }) {
    // An owned, definitely unsent operation may settle after disposal. Closure
    // never grants dispatch authority, and a newer runtime/turn still wins.
    if ((_closed && dispatched) ||
        !identical(capture._owner, this) ||
        capture.runtimeId != _runtimeId ||
        capture._turn != _turn) {
      return;
    }
    _execution = failed ? ChatExecution.failed : capture._execution;
    if (!failed) {
      _main = capture._main;
      _mainTool = capture._tool;
    }
    _error = error;
    _failure = null;
  }

  void deliveryUncertain(String error) {
    if (!_closed) {
      _retireToolProgress();
      _recovery = ChatRecovery.reconnecting;
      _error = error;
      _failure = null;
    }
  }

  void failTurn(String error) {
    if (!_closed) {
      _retireToolProgress();
      _sealReasoning();
      _compacting = false;
      _execution = ChatExecution.failed;
      _error = error;
      _failure = null;
    }
  }

  void completeTurn({
    required bool failed,
    required bool cancelled,
    required String? error,
    TurnFailure? failure,
  }) {
    if (_closed) return;
    _retireToolProgress();
    _sealReasoning();
    _compacting = false;
    _execution = failed
        ? ChatExecution.failed
        : cancelled
        ? ChatExecution.cancelled
        : ChatExecution.completed;
    _mainTool = null;
    _secureResponding = false;
    _commandPreflight = null;
    _error = error;
    _failure = failure;
  }

  void reportError(String? error) {
    if (!_closed) {
      _error = error;
      _failure = null;
    }
  }

  void reportCommandError(String error) {
    // A resume describes the turn, not the outcome of a timed-out command.
    // Keep this local outcome until the next explicit command or turn.
    if (!_closed) {
      _error = null;
      _commandError = error;
    }
  }

  void beginCommand() {
    if (!_closed) {
      _commandRevision++;
      _commandPrompt = null;
      _commandRunning = true;
      _error = null;
      _commandError = null;
    }
  }

  void beginCommandDispatch() {
    if (!_closed) _commandDispatchPending = true;
  }

  void finishCommandDispatch() {
    _commandDispatchPending = false;
  }

  void finishCommand() {
    _commandRunning = false;
    _revokeCommandPrompt();
    _commandPrompt = null;
  }

  void observeText(String text) {
    if (!_closed && text.isNotEmpty) {
      _sealReasoning();
      _main = ChatMainActivity.writing;
    }
  }

  void finishSegment() {
    if (!_closed) {
      _sealReasoning();
      _main = ChatMainActivity.working;
    }
  }

  void reconcileHistoricalActivity() {
    if (_closed || observation.executionActive || observation.needsInput) {
      return;
    }
    _tools.removeWhere((activity) => activity.isTerminal);
    _activity.removeWhere(
      (entry) => switch (entry) {
        ChatToolEntry(:final activity) => activity.isTerminal,
        ChatReasoningEntry(:final running) => !running,
        ChatRequestEntry(:final question) =>
          question.status != HermesQuestionStatus.pending,
      },
    );
  }

  void finishActivity() {
    if (!_closed) {
      _tools.clear();
      _activity.clear();
    }
  }

  void observeReasoning(
    String type,
    Map<String, dynamic> data, {
    DateTime? receivedAt,
  }) {
    if (_closed) return;
    final update = GatewayReasoningUpdate.fromGatewayEvent(type, data);
    if (update == null) return;
    final last = _activity.lastOrNull;
    final current = last is ChatReasoningEntry && last.running ? last : null;
    final available = type == 'reasoning.available';
    final entry = ChatReasoningEntry(
      identity: current?.identity ?? (_runtimeId, _turn, ++_reasoningOrdinal),
      text: available && current != null
          ? current.text
          : '${current?.text ?? ''}${update.text}',
      source: current?.source ?? type,
      availableText: available && current != null ? update.text : null,
      running: !available,
      postedAt: current?.postedAt ?? receivedAt ?? DateTime.now(),
    );
    if (current == null) {
      _activity.add(entry);
    } else {
      _activity[_activity.length - 1] = entry;
    }
    if (type == 'reasoning.delta') _main = ChatMainActivity.thinking;
  }

  void _sealReasoning() {
    if (_activity.lastOrNull case final ChatReasoningEntry entry
        when entry.running) {
      _activity[_activity.length - 1] = entry.sealed();
    }
  }

  GatewayToolActivity? observeTool(
    String type,
    Map<String, dynamic> data, {
    bool live = true,
    Duration? receivedAt,
  }) {
    if (_closed) return null;
    final update = GatewayToolActivity.fromGatewayEvent(
      type,
      data,
      receivedAt: live ? receivedAt ?? toolActivityNow() : null,
    );
    if (update == null) return null;
    if (type == 'tool.progress') {
      // Progress cannot invent a call, reorder reasoning or revive settled work.
      if (!live ||
          _recovery != ChatRecovery.ready ||
          !observation.executionActive ||
          update.progress == null) {
        return null;
      }
      final index = _tools.indexWhere((a) => a.toolId == update.toolId);
      if (index < 0 || _tools[index].isTerminal) return null;
      final previous = _tools[index];
      final merged = previous.merge(update);
      _tools[index] = merged;
      final position = _activity.indexWhere(
        (entry) =>
            entry is ChatToolEntry && entry.activity.toolId == merged.toolId,
      );
      if (position >= 0) _activity[position] = ChatToolEntry(merged);
      if (identical(_mainTool, previous)) _mainTool = merged;
      return merged;
    }
    _sealReasoning();
    // Argument generation announces a name, not a call identity or a start.
    if (type == 'tool.generating') {
      _mainTool = update;
      _main = ChatMainActivity.tool;
      return update;
    }
    if (update.toolId == null) return null;
    final index = _tools.indexWhere((a) => a.toolId == update.toolId);
    if (index >= 0 && _tools[index].isTerminal && !update.isTerminal) {
      return _tools[index];
    }
    final merged = index < 0 ? update : _tools[index].merge(update);
    if (index < 0) {
      _tools.add(merged);
      _activity.add(ChatToolEntry(merged));
    } else {
      _tools[index] = merged;
      final position = _activity.indexWhere(
        (entry) =>
            entry is ChatToolEntry && entry.activity.toolId == merged.toolId,
      );
      if (position >= 0) _activity[position] = ChatToolEntry(merged);
    }
    if (type != 'tool.complete') {
      _mainTool = merged;
      _main = ChatMainActivity.tool;
    } else if (!_tools.any((a) => identical(a, _mainTool) && !a.isTerminal)) {
      _mainTool = _tools.reversed.where((a) => !a.isTerminal).firstOrNull;
      if (_main == ChatMainActivity.tool) {
        _main = _mainTool == null
            ? ChatMainActivity.working
            : ChatMainActivity.tool;
      }
    }
    return merged;
  }

  void observeExecutionSnapshot(Map<String, dynamic> data) {
    if (_closed || data['running'] is! bool) return;
    if (data['running'] == true) {
      _execution = ChatExecution.running;
    } else {
      _retireToolProgress();
      _sealReasoning();
      _compacting = false;
      if (observation.executionActive) _execution = ChatExecution.completed;
    }
  }

  void beginRecovery() {
    if (!_closed) {
      _retireToolProgress();
      _revokeCommandPrompt();
      _recovery = ChatRecovery.reconnecting;
      _secureResponding = false;
    }
  }

  void _retireToolProgress() {
    for (var i = 0; i < _tools.length; i++) {
      if (_tools[i].progress == null) continue;
      final previous = _tools[i];
      final next = previous.withoutProgress();
      _tools[i] = next;
      if (identical(_mainTool, previous)) _mainTool = next;
      final position = _activity.indexWhere(
        (entry) =>
            entry is ChatToolEntry && entry.activity.toolId == next.toolId,
      );
      if (position >= 0) _activity[position] = ChatToolEntry(next);
    }
  }

  void installOfflineReading() {
    if (!_closed) {
      _liveSessionConfirmed = false;
      _recovery = ChatRecovery.offline;
    }
  }

  void beginOpening() {
    if (!_closed) {
      _recovery = ChatRecovery.opening;
      _openingError = null;
    }
  }

  void finishOpening({String? error}) {
    if (!_closed) {
      _openingError = error;
      if (error == null) _liveSessionConfirmed = true;
      _recovery = error == null ? ChatRecovery.ready : ChatRecovery.opening;
    }
  }

  void cancelOpening() {
    if (!_closed && _recovery == ChatRecovery.opening) {
      _recovery = ChatRecovery.offline;
    }
  }

  void recovered() {
    if (!_closed) {
      _liveSessionConfirmed = true;
      _recovery = ChatRecovery.ready;
      _openingError = null;
    }
  }

  void invalidateResume() {
    _resume++;
  }

  void resetCompleted() {
    if (!_closed && !observation.blocksTurnAdmission) {
      _execution = ChatExecution.idle;
    }
  }

  void bindProvisional(String runtimeId) {
    if (!_closed) {
      _runtimeId = runtimeId;
      _liveSessionConfirmed = true;
      _recovery = ChatRecovery.ready;
    }
  }

  void rollbackProvisional(
    ChatRuntimeRead capture, {
    required String runtimeId,
    required ChatRecovery recovery,
    required bool liveSessionConfirmed,
  }) {
    if (capture.current) {
      _runtimeId = runtimeId;
      _liveSessionConfirmed = liveSessionConfirmed;
      _recovery = recovery;
    }
  }

  void replaceRuntime(String runtimeId) {
    if (_closed) return;
    for (final question in _questionHistory.values.toList()) {
      if (question.status == HermesQuestionStatus.pending) {
        _settleQuestion(question.id, HermesQuestionStatus.cancelled);
      }
    }
    _runtimeId = runtimeId;
    _liveSessionConfirmed = true;
    _read++;
    _resume++;
    _turn++;
    _execution = ChatExecution.idle;
    _compacting = false;
    _recovery = ChatRecovery.ready;
    _error = null;
    _approvals.clear();
    _approvalCorrelations.clear();
    _serverQuestions = null;
    _nativeClarifications.clear();
    _nativeGeneration = null;
    _settledNativePrompts.clear();
    _secure = null;
    _approvalResponding = false;
    _answeringApproval = null;
    _secureResponding = false;
    _commandPreflight = null;
    _mainTool = null;
    finishActivity();
  }

  /// Native waiters are generation-bound and independent of JSON-RPC requests.
  bool receiveNativePrompt(Map<String, dynamic> prompt) {
    final kind = prompt['kind'], id = prompt['prompt_id'];
    final generation = prompt['execution_generation'];
    if (_closed ||
        id is! String ||
        id.isEmpty ||
        generation is! int ||
        generation < 0 ||
        !{'approval', 'clarify'}.contains(kind) ||
        generation < (_nativeGeneration ?? generation) ||
        _settledNativePrompts.contains((kind as String, id, generation))) {
      return false;
    }
    if (_nativeGeneration != generation) {
      reconcileNativePrompts(const [], generation);
    }
    if (kind == 'approval') {
      if (_approvals.requests.any(
        (r) => r['request_id'] == id && r['server_request_id'] is String,
      )) {
        return false;
      }
      if (_questionHistory['native/$generation/approval/$id']
              ?.status
              .isPending ==
          false) {
        return false;
      }
      return receiveApproval({...prompt, 'request_id': id});
    }
    receiveQuestions({
      ...prompt,
      'request_id': id,
    }, nativeGeneration: generation);
    return true;
  }

  void settleNativePrompt(String kind, String id, int generation) {
    if (_closed) return;
    _settledNativePrompts.add((kind, id, generation));
    if (kind == 'approval') {
      final raw = _approvals.requests
          .where(
            (r) =>
                r['request_id'] == id &&
                r['execution_generation'] == generation,
          )
          .firstOrNull;
      if (raw == null) return;
      _settleQuestion(_approvalHistoryId(raw), HermesQuestionStatus.closed);
      final correlation = _approvalCorrelations.remove(id);
      _approvals.remove(id);
      if (identical(_answeringApproval, correlation)) {
        _approvalResponding = false;
        _answeringApproval = null;
      }
    } else if (kind == 'clarify' &&
        _nativeClarifications[id]?.nativeGeneration == generation) {
      for (final q in _nativeClarifications[id]!.questions) {
        _settleQuestion(
          _clarifyHistoryId(q, generation),
          HermesQuestionStatus.closed,
        );
      }
      _nativeClarifications.remove(id);
    }
  }

  /// A full canonical native snapshot retires only native controls.
  void reconcileNativePrompts(Object? value, int generation) {
    if (_closed ||
        value is! List ||
        generation < 0 ||
        generation < (_nativeGeneration ?? generation)) {
      return;
    }
    final prompts = value
        .whereType<Map>()
        .where(
          (p) =>
              p['execution_generation'] == generation &&
              p['prompt_id'] is String &&
              {'approval', 'clarify'}.contains(p['kind']),
        )
        .map((p) => Map<String, dynamic>.from(p))
        .toList();
    final ids = {for (final p in prompts) (p['kind'], p['prompt_id'])};
    for (final raw
        in _approvals.requests
            .where((r) => r['execution_generation'] is int)
            .toList()) {
      if (raw['execution_generation'] != generation ||
          !ids.contains(('approval', raw['prompt_id']))) {
        settleNativePrompt(
          'approval',
          raw['request_id'] as String,
          raw['execution_generation'] as int,
        );
      }
    }
    for (final previous in _nativeClarifications.values.toList()) {
      if (previous.nativeGeneration == generation &&
          ids.contains(('clarify', previous.pending?.requestId))) {
        continue;
      }
      settleNativePrompt(
        'clarify',
        previous.pending!.requestId,
        previous.nativeGeneration!,
      );
    }
    _nativeGeneration = generation;
    for (final prompt in prompts) {
      receiveNativePrompt(prompt);
    }
    _reconcileQuestionHistory(
      HermesQuestionKind.clarification,
      _activeClarificationIds,
    );
  }

  /// approval.pending is native-only; its read owner supplies the captured
  /// canonical generation because that endpoint deliberately omits it.
  bool reconcileNativeApprovals(
    ChatRuntimeApprovalRead capture,
    List<Map<String, dynamic>> rows,
    int generation,
  ) {
    if (_closed ||
        !identical(capture._owner, this) ||
        capture.runtimeId != _runtimeId ||
        capture._read != _approvalRead ||
        capture._revision != _approvals.revision ||
        generation < 0 ||
        generation < (_nativeGeneration ?? generation)) {
      return false;
    }
    final wire = <Map<String, dynamic>>[
      ..._approvals.requests.where((r) => r['execution_generation'] == null),
      for (final row in rows)
        if (row['request_id'] is String &&
            !_approvals.requests.any(
              (r) =>
                  r['request_id'] == row['request_id'] &&
                  r['server_request_id'] is String,
            ) &&
            !_settledNativePrompts.contains((
              'approval',
              row['request_id'] as String,
              generation,
            )))
          {
            ...row,
            'kind': 'approval',
            'prompt_id': row['request_id'],
            'execution_generation': generation,
          },
    ];
    final previousNative = _approvals.requests
        .where((r) => r['execution_generation'] is int)
        .toList();
    if (!reconcileApprovals(capture, wire)) return false;
    for (final previous in previousNative) {
      if (!wire.any(
        (r) =>
            r['request_id'] == previous['request_id'] &&
            r['execution_generation'] == previous['execution_generation'],
      )) {
        _settledNativePrompts.add((
          'approval',
          previous['request_id'] as String,
          previous['execution_generation'] as int,
        ));
      }
    }
    for (final previous in _nativeClarifications.values.toList()) {
      if (previous.nativeGeneration != generation) {
        settleNativePrompt(
          'clarify',
          previous.pending!.requestId,
          previous.nativeGeneration!,
        );
      }
    }
    _nativeGeneration = generation;
    return true;
  }

  bool receiveApproval(Map<String, dynamic> request) {
    if (_closed) return false;
    _revokeCommandPrompt();
    final wire = _approvalWire(request);
    _rememberApproval(wire);
    final previous = _approvals.requests
        .where((r) => r['request_id'] == wire['request_id'])
        .firstOrNull;
    final changed = jsonEncode(previous) != jsonEncode(wire);
    final added = _approvals.add(wire);
    final id = request['request_id'];
    if (id is String && id.isNotEmpty) {
      if (changed) _approvalCorrelations[id] = Object();
    }
    return added;
  }

  ChatRuntimeApprovalRead captureApprovalRead() => ChatRuntimeApprovalRead._(
    this,
    _runtimeId,
    ++_approvalRead,
    _approvals.revision,
  );
  bool reconcileApprovals(
    ChatRuntimeApprovalRead capture,
    List<Map<String, dynamic>> requests,
  ) {
    if (_closed ||
        !identical(capture._owner, this) ||
        capture.runtimeId != _runtimeId ||
        capture._read != _approvalRead ||
        capture._revision != _approvals.revision) {
      return false;
    }
    final before = {
      for (final r in _approvals.requests) r['request_id']: jsonEncode(r),
    };
    final wire = requests.map(_approvalWire).toList();
    if (wire.isNotEmpty) _revokeCommandPrompt();
    _approvals.reconcile(wire);
    for (final request in _approvals.requests) {
      _rememberApproval(request);
    }
    _reconcileQuestionHistory(
      HermesQuestionKind.approval,
      _approvals.requests.map(_approvalHistoryId).toSet(),
    );
    final ids = _approvals.requests.map((r) => r['request_id']).toSet();
    _approvalCorrelations.removeWhere((id, _) => !ids.contains(id));
    for (final raw in _approvals.requests) {
      final id = raw['request_id'] as String;
      if (before[id] != jsonEncode(raw)) _approvalCorrelations[id] = Object();
    }
    if (_approvalResponding &&
        !_approvalCorrelations.values.any(
          (value) => identical(value, _answeringApproval),
        )) {
      _approvalResponding = false;
      _answeringApproval = null;
    }
    if (_recovery == ChatRecovery.reconnecting) _recovery = ChatRecovery.ready;
    return true;
  }

  ChatRuntimeAnswer beginApprovalAnswer(String id, String choice) {
    final request = observation.approval;
    if (_closed || request == null || request.requestId != id) {
      throw StateError(
        'This approval has changed. Review the current command.',
      );
    }
    if (_approvalResponding) {
      throw StateError('Approval is already being submitted.');
    }
    if (!request.request.choices.any((v) => v.wireValue == choice)) {
      throw ArgumentError('Approval choice is unavailable');
    }
    _approvalResponding = true;
    _answeringApproval = request.correlation;
    _decisionError = null;
    return ChatRuntimeAnswer._(
        this,
        _runtimeId,
        request.correlation,
        _turn,
        _events,
      )
      .._approvalChoice = choice
      .._questionHistoryId = _approvalHistoryId(
        _approvals.requests.firstWhere((r) => r['request_id'] == id),
      );
  }

  bool _ownsAnswer(ChatRuntimeAnswer capture) =>
      _answerCurrent(capture) &&
      (identical(_questions?.correlation, capture._request) ||
          identical(_secure, capture._request) ||
          _approvalCorrelations.values.any(
            (value) => identical(value, capture._request),
          ));
  bool _answerCurrent(ChatRuntimeAnswer capture) =>
      !_closed &&
      identical(capture._owner, this) &&
      capture.runtimeId == _runtimeId;
  void finishApprovalAnswer(
    ChatRuntimeAnswer capture,
    String id, {
    required bool accepted,
    String? error,
  }) {
    if (!_answerCurrent(capture)) return;
    if (accepted &&
        capture._approvalChoice != null &&
        capture._questionHistoryId != null) {
      _settleQuestion(
        capture._questionHistoryId!,
        HermesQuestionStatus.decision(capture._approvalChoice!),
      );
    }
    if (identical(_approvalCorrelations[id], capture._request) && accepted) {
      _approvals.remove(id);
      _approvalCorrelations.remove(id);
    }
    if (error != null &&
        identical(_approvalCorrelations[id], capture._request)) {
      _decisionError = error;
      _decisionErrorRequestId = id;
    }
    if (identical(_answeringApproval, capture._request)) {
      _approvalResponding = false;
      _answeringApproval = null;
    }
  }

  void reportDecisionError(String id, String error) {
    if (!_closed && observation.approvals.any((a) => a.requestId == id)) {
      _decisionError = error;
      _decisionErrorRequestId = id;
    }
  }

  void receiveQuestions(Map<String, dynamic> data, {int? nativeGeneration}) {
    if (_closed) return;
    final parsed = GatewayClarifyRequest.fromEventDataList(data);
    _rememberQuestions(parsed, nativeGeneration: nativeGeneration);
    bool settled(GatewayClarifyRequest question) =>
        _questionHistory[_clarifyHistoryId(question, nativeGeneration)]
            ?.status
            .isPending ==
        false;
    // Request IDs cannot reopen after settlement. A late replay must not
    // restore its controls or displace a newer request.
    if (parsed.isNotEmpty && parsed.every(settled)) return;
    if (parsed.isNotEmpty) _revokeCommandPrompt();
    final answeredIds = data['answers'] is Map
        ? (data['answers'] as Map).keys.whereType<String>().toSet()
        : <String>{};
    answeredIds.addAll(
      parsed.where(settled).map((q) => q.questionId).whereType<String>(),
    );
    final pending = parsed
        .where(
          (q) => q.questionId == null || !answeredIds.contains(q.questionId),
        )
        .firstOrNull;
    final lane = nativeGeneration == null
        ? _serverQuestions
        : _nativeClarifications[parsed.firstOrNull?.requestId];
    final previous = lane?.pending;
    // A repeated server snapshot does not replace the pending question's
    // response authority. Advancing to another question does.
    final correlation =
        pending != null &&
            previous != null &&
            pending.requestId == previous.requestId &&
            pending.questionId == previous.questionId &&
            lane?.nativeGeneration == nativeGeneration
        ? lane!.correlation
        : Object();
    final next = pending == null
        ? null
        : ChatQuestions(
            correlation: correlation,
            nativeGeneration: nativeGeneration,
            questions: parsed,
            answeredIds: answeredIds,
            lockedAnswers: data['answers'] is Map
                ? {
                    for (final e in (data['answers'] as Map).entries)
                      if (e.key is String && e.value is String)
                        e.key as String: e.value as String,
                  }
                : const {},
          );
    if (nativeGeneration == null) {
      _serverQuestions = next;
    } else if (next != null) {
      _nativeQuestions = next;
    }
    for (final question in parsed) {
      if (data['answers'] is Map &&
          (data['answers'] as Map).containsKey(question.questionId)) {
        _settleQuestion(
          _clarifyHistoryId(question, nativeGeneration),
          HermesQuestionStatus.answered,
        );
      }
    }
    _reconcileQuestionHistory(
      HermesQuestionKind.clarification,
      _activeClarificationIds,
    );
  }

  ChatRuntimeAnswer? beginQuestionAnswer(ChatQuestions? expected) {
    if (_closed || (expected != null && !identical(expected, _questions))) {
      throw StateError(
        'This question has changed. Review the current question.',
      );
    }
    if (_questions?.pending == null) return null;
    return ChatRuntimeAnswer._(
        this,
        _runtimeId,
        _questions!.correlation,
        _turn,
        _events,
      )
      .._questionHistoryId = _clarifyHistoryId(
        _questions!.pending!,
        _questions!.nativeGeneration,
      );
  }

  void finishQuestionAnswer(
    ChatRuntimeAnswer capture, {
    required String answer,
    required List<String>? remaining,
  }) {
    if (!_answerCurrent(capture)) return;
    // Native settlement is published before its response ACK. That ACK can
    // confirm the captured history without consuming a newer pending prompt.
    if (capture._questionHistoryId?.startsWith('native/') == true) {
      _settleQuestion(
        capture._questionHistoryId!,
        HermesQuestionStatus.answered,
      );
    }
    if (!identical(_questions?.correlation, capture._request)) return;
    final questions = _questions!;
    final pending = questions.pending;
    if (pending != null) {
      _settleQuestion(
        _clarifyHistoryId(pending, questions.nativeGeneration),
        HermesQuestionStatus.answered,
      );
    }
    if (remaining == null || remaining.isEmpty) {
      _questions = null;
    } else {
      _questions = ChatQuestions(
        correlation: Object(),
        nativeGeneration: questions.nativeGeneration,
        questions: questions.questions,
        answeredIds: questions.questions
            .map((q) => q.questionId)
            .whereType<String>()
            .where((id) => !remaining.contains(id)),
        lockedAnswers: {
          ...questions.lockedAnswers,
          ?questions.pending?.questionId: answer,
        },
      );
    }
  }

  void reportQuestionExpiry(ChatRuntimeAnswer capture) {
    if (!_answerCurrent(capture) ||
        capture._turn != _turn ||
        capture._events != _events ||
        (!capture.current && observation.needsInput)) {
      return;
    }
    // The anchored history entry owns expiry feedback.
  }

  void receiveSecure(GatewaySensitivePromptRequest request) {
    if (_closed) return;
    _rememberSecure(request);
    _revokeCommandPrompt();
    _secure = GatewaySensitivePromptRequest(
      kind: request.kind,
      requestId: request.requestId,
      title: request.title,
      description: request.description,
      fieldLabel: request.fieldLabel,
    );
    _secureResponding = false;
    _commandPreflight = _commandDispatchPending ? _secure : null;
    _reconcileQuestionHistory(HermesQuestionKind.secureInput, {
      'secure/${request.kind.name}/${request.requestId}',
    });
  }

  ChatRuntimeAnswer beginSecureAnswer(GatewaySensitivePromptRequest expected) {
    if (_closed || !identical(expected, _secure)) {
      throw StateError('This request has changed. Review the current request.');
    }
    if (_secureResponding) {
      throw StateError('A response is already being submitted.');
    }
    _secureResponding = true;
    return ChatRuntimeAnswer._(this, _runtimeId, expected, _turn, _events);
  }

  void finishSecureAnswer(ChatRuntimeAnswer capture, {required bool accepted}) {
    if (!_answerCurrent(capture)) return;
    final continuation = _commandPrompt;
    if (continuation != null &&
        identical(continuation._preflight, capture._request)) {
      if (accepted) {
        continuation._accepted = true;
      } else {
        continuation._revoked = true;
      }
    }
    if (accepted) {
      final request = capture._request as GatewaySensitivePromptRequest;
      _settleQuestion(
        'secure/${request.kind.name}/${request.requestId}',
        HermesQuestionStatus.answered,
      );
    }
    if (!identical(_secure, capture._request)) return;
    _secureResponding = false;
    if (accepted) {
      if (_recovery == ChatRecovery.reconnecting) {
        _recovery = ChatRecovery.ready;
      }
      _secure = null;
      _commandPreflight = null;
    }
  }

  void cancelRequest(Map<String, dynamic> data) {
    if (_closed) return;
    final id = data['id'];
    final method = data['method'];
    if (id is! String) return;
    _settleQuestionRequest(
      id,
      HermesQuestionStatus.cancellation(data['reason']),
    );
    if (method == 'approval') {
      for (final raw
          in _approvals.requests
              .where((r) => r['server_request_id'] == id)
              .toList()) {
        final rid = raw['request_id'] as String;
        _approvals.remove(rid);
        _approvalCorrelations.remove(rid);
      }
    }
    if (method == 'clarify' && _serverQuestions?.pending?.requestId == id) {
      _serverQuestions = null;
    }
    if (_secure?.requestId == id &&
        GatewaySensitivePromptRequest.kindForMethod(
              method is String ? method : null,
            ) ==
            _secure?.kind) {
      _secure = null;
      _secureResponding = false;
      _commandPreflight = null;
    }
  }

  void reconcileOpenRequests(Object? value) {
    if (_closed || value is! List) return;
    final frames = value
        .whereType<Map>()
        .where(
          (r) => r['params'] is Map && r['params']['session_id'] == _runtimeId,
        )
        .toList();
    final serverApprovals = <Map<String, dynamic>>[
      for (final frame in frames)
        if (frame['method'] == 'approval' &&
            frame['params']['request_id'] is String)
          {
            ...Map<String, dynamic>.from(frame['params'] as Map),
            'server_request_id': frame['id'],
          },
    ];
    reconcileApprovals(captureApprovalRead(), [
      ..._approvals.requests.where((r) => r['execution_generation'] is int),
      ...serverApprovals,
    ]);
    GatewaySensitivePromptRequest? next;
    for (final frame in frames) {
      next = GatewaySensitivePromptRequest.fromServerRequest(frame);
      if (next != null) break;
    }
    final sameSecure =
        next?.requestId == _secure?.requestId && next?.kind == _secure?.kind;
    if (!sameSecure && next != null) _revokeCommandPrompt();
    if (!sameSecure || !_secureResponding) _secure = next;
    if (next != null) _rememberSecure(next);
    if (!sameSecure) {
      _secureResponding = false;
      _commandPreflight = null;
    }
    final questionFrame = frames
        .where((r) => r['method'] == 'clarify')
        .firstOrNull;
    if (questionFrame == null) {
      _serverQuestions = null;
    } else {
      receiveQuestions({
        ...Map<String, dynamic>.from(questionFrame['params'] as Map),
        'request_id': questionFrame['id'],
      });
    }
    _reconcileQuestionHistory(
      HermesQuestionKind.clarification,
      _activeClarificationIds,
    );
    _reconcileQuestionHistory(HermesQuestionKind.secureInput, {
      if (next != null) 'secure/${next.kind.name}/${next.requestId}',
    });
  }

  /// Called only after the coordinator accepts a captured current resume read.
  bool installResume(Map<String, dynamic> result) {
    if (_closed) return false;
    _retireToolProgress();
    final runtime = result['session_id'] as String;
    final changed = runtime != _runtimeId;
    final wasActive = observation.executionActive;
    if (changed) replaceRuntime(runtime);
    if (result['running'] == false) _compacting = false;
    _resume++;
    _main = ChatMainActivity.working;
    _mainTool = null;
    final inflight = result['inflight'] is Map
        ? result['inflight'] as Map
        : null;
    final failed = inflight?['status'] == 'error';
    _execution = failed
        ? ChatExecution.failed
        : result['running'] == true
        ? ChatExecution.running
        : wasActive
        ? ChatExecution.completed
        : _execution == ChatExecution.submitting
        ? ChatExecution.idle
        : _execution;
    _failure = failed
        ? TurnFailure.fromCompletion(Map<String, dynamic>.from(inflight!))
        : null;
    _error = _failure?.message;
    final generation = result['execution_generation'];
    if (generation is int) {
      reconcileNativePrompts(result['prompts'], generation);
    }
    reconcileOpenRequests(result['open_requests']);
    return changed;
  }

  void dispose() {
    _closed = true;
    _revokeCommandPrompt();
    _read++;
    _approvalRead++;
  }
}

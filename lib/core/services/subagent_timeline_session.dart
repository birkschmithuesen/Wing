import '../models/hermes_question.dart';
import '../models/operational_error.dart';
import '../models/canonical_session.dart';
import 'dart:async';
import '../models/transcript_position.dart';

import 'package:flutter/foundation.dart';

import '../models/chat_runtime.dart';
import '../models/gateway_insight.dart';
import '../models/gateway_todo.dart';
import '../models/hermes_profile.dart';
import '../models/profile_session_key.dart';
import '../models/profile_supervision.dart';
import 'chat_runtime.dart';
import 'chat_transcript_events.dart';
import 'profile_gateway.dart';
import 'transcript_reading.dart';

/// A child-only reading visit. Canonical resume mounts a read-only subscription; it
/// never submits a prompt, changes the selected chat or claims child controls.
final class SubagentTimelineSession extends ChangeNotifier
    implements SubagentTimelineReader {
  SubagentTimelineSession({
    required this.scope,
    required this.sessionId,
    required this._read,
    required this._history,
    required this._isCurrent,
    this.onOperationalError,
  }) : _reading = TranscriptReading.passive(scope: scope),
       _runtime = ChatRuntime(runtimeId: sessionId);

  final WorkspaceScope scope;
  final String sessionId;
  final OperationalErrorReporter? onOperationalError;
  final ScopedRpc _read;
  final Future<ProfileHistoryPage> Function(String, int) _history;
  final bool Function() _isCurrent;
  final TranscriptReading _reading;
  final ChatRuntime _runtime;
  final _rows = <int, Map<String, dynamic>>{};
  final _agents = <String, GatewaySubagentActivity>{};
  GatewayTodoState _taskState = GatewayTodoState();
  String? _watch, _epoch, _error;
  int _sequence = 0;
  int? _older;
  bool _closed = false, _active = false, _available = false;
  bool _loading = false, _paging = false, _partial = false;
  bool _reconcile = false;
  int _completionFloor = 0;
  int _failures = 0;
  bool _historyFailed = false, _showReadFailure = false;
  @override
  String? get liveError => _historyFailed || !_showReadFailure ? null : _error;
  Timer? _timer;
  Future<void>? _pending;

  bool get _current => !_closed && _isCurrent();
  @override
  ChatRuntimeObservation get runtime => _runtime.observation;
  @override
  Map<String, dynamic>? get streamingMessage => _reading.streamingMessage;
  @override
  List<GatewayTodo> get todos => _taskState.current(
    active: runtime.executionActive,
    turn: _runtime.turnRevision,
  );
  @override
  // Completion is reported by runtime; presentation waits for saved history.
  bool get liveAnswering =>
      runtime.executionActive || runtime.needsInput || _reconcile;
  @override
  String? get qualification => _partial
      ? 'Earlier live activity is unavailable. Showing saved history and received updates.'
      : null;

  @override
  void setActive(bool value) {
    _active = value;
    _timer?.cancel();
    _timer = null;
    if (value && _current) unawaited(_update());
  }

  @override
  Future<void> refresh() => _update(explicit: true);
  @override
  Future<void> loadOlder() => _update(older: true, explicit: true);

  Future<void> _update({bool older = false, bool explicit = false}) async {
    if (!_current || older && _older == null) return;
    if (_pending case final pending?) {
      if (explicit) {
        _showReadFailure = true;
        _loading = true;
        notifyListeners();
      }
      await pending;
      return;
    }
    final done = Completer<void>();
    _pending = done.future;
    _showReadFailure = explicit || !_available;
    _loading = explicit || !_available;
    _paging = older;
    if (_loading) notifyListeners();
    var failed = false, historyFailed = false;
    bool? historyOutcome, liveOutcome;
    Future<void> observe(
      Future<void> Function() operation, {
      bool history = false,
    }) async {
      if (!_current) return;
      var succeeded = false;
      try {
        await operation();
        succeeded = true;
      } catch (_) {
        failed = true;
        historyFailed |= history;
      }
      if (history) {
        if (!older) historyOutcome = succeeded;
      } else {
        liveOutcome = (liveOutcome ?? true) && succeeded;
      }
    }

    try {
      // Mount first so events emitted while the REST page loads are replayable.
      // Each read settles independently: a missing mirror cannot hide saved
      // history, and a child not persisted yet can still stream its live work.
      if (_watch == null) await observe(_mount);
      if (!_available || explicit || _reconcile) {
        await observe(() => _loadPage(older ? _older! : 0), history: true);
      }
      if (!older && _watch != null) await observe(_replay);
      if (!_current) return;
      _historyFailed = historyFailed;
      _error = failed
          ? 'Subagent activity could not refresh. Retry to continue.'
          : null;
      _failures = failed ? _failures + 1 : 0;
      if (historyOutcome != false ||
          _available ||
          !(runtime.executionActive || runtime.needsInput)) {
        _reportReadOutcome('subagent-history', historyOutcome);
      }
      _reportReadOutcome('subagent-timeline', liveOutcome);
    } finally {
      _pending = null;
      _loading = false;
      _paging = false;
      done.complete();
      if (_current) {
        notifyListeners();
        _timer?.cancel();
        if (_active &&
            _failures < 3 &&
            (liveAnswering || _reconcile || !_available)) {
          _timer = Timer(Duration(seconds: liveAnswering ? 1 : 3), _update);
        }
      }
    }
  }

  void _reportReadOutcome(String source, bool? succeeded) {
    if (succeeded == null) return;
    onOperationalError?.call(
      OperationalErrorObservation(
        connectionIdentity: scope.connectionIdentity,
        profileName: scope.profileName,
        operation: '$source:${scope.profileName}:$sessionId',
        title: 'Subagent activity unavailable',
        error: succeeded ? null : 'Open the subagent and refresh its activity.',
      ),
    );
  }

  Future<void> _mount({String? expectedEpoch, bool skipMissing = false}) async {
    final response = await _read('session.resume', {
      'session_id': sessionId,
      'display_projection': true,
    });
    if (!_current) return;
    final cursor = CanonicalReplayCursor.fromSnapshot(
      response,
      expectedSessionId: sessionId,
      expectedEpoch: expectedEpoch,
    );
    _watch = cursor.sessionId;
    _epoch = cursor.epoch;
    _sequence = skipMissing ? cursor.sequence : 0;
    _runtime.replaceRuntime(cursor.sessionId);
    _runtime.observeExecutionSnapshot(response);
  }

  Future<void> _loadPage(int offset) async {
    final page = await _history(sessionId, offset);
    if (!_current) return;
    if (page.sessionId != sessionId || page.offset != offset) {
      throw const FormatException('Child history identity changed');
    }
    final rows = <int, Map<String, dynamic>>{};
    for (final row in page.rows) {
      if (row['id'] is! int) {
        throw const FormatException('Missing saved message identity');
      }
      rows[row['id'] as int] = row;
    }
    // Keep already-read older rows when refreshing the latest page.
    final retainedStart =
        offset == 0 &&
        _available &&
        _older == null &&
        rows.keys.any(_rows.containsKey);
    _rows.addAll(rows);
    _older = page.nextOffset == null || retainedStart ? null : _rows.length;
    _reading.installSavedPage(
      ProfileHistoryPage(
        sessionId,
        [for (final id in _rows.keys.toList()..sort()) _rows[id]!],
        0,
        _rows.length,
        isComplete: _older == null,
      ),
    );
    _available = true;
    final savedCompletion = page.rows.any(
      (row) =>
          row['role'] == 'assistant' &&
          ((streaming.isNotEmpty && row['content'] == streaming) ||
              (row['id'] is int &&
                  (row['id'] as int) > _completionFloor &&
                  row['content'] is String &&
                  (row['content'] as String).isNotEmpty)),
    );
    if (_reconcile && savedCompletion) {
      _reading.updateStreaming('');
      _runtime.reconcileHistoricalActivity();
      _reconcile = false;
    }
    notifyListeners();
  }

  Future<void> _replay() async {
    Future<Map<String, dynamic>> readReplay() => _read('session.events.since', {
      'session_id': _watch,
      'replay_epoch': _epoch,
      'last_sequence': _sequence,
    });
    var replay = await readReplay();
    if (!_current) return;
    final epoch = replay['replay_epoch'];
    if (epoch is! String || epoch.isEmpty) {
      throw const FormatException('Missing child replay epoch');
    }
    if (epoch != _epoch) {
      _partial = true;
      _reconcile = false;
      _agents.clear();
      _taskState = GatewayTodoState();
      await _mount(expectedEpoch: epoch);
      if (!_current) return;
      _reading.updateStreaming('');
      await _loadPage(0);
      if (!_current) return;
      replay = await readReplay();
      if (!_current) return;
    }
    if (replay['replay_epoch'] != _epoch) {
      throw const FormatException('Child replay changed during refresh');
    }
    if (replay['snapshot_required'] is! bool || replay['truncated'] is! bool) {
      throw const FormatException('Missing canonical replay continuity');
    }
    if (replay['snapshot_required'] == true || replay['truncated'] == true) {
      _partial = true;
      _reconcile = false;
      _agents.clear();
      _taskState = GatewayTodoState();
      await _mount(expectedEpoch: _epoch, skipMissing: true);
      if (!_current) return;
      _reading.updateStreaming('');
      await _loadPage(0);
      return;
    }
    final events = replay['events'];
    final latest = replay['latest_seq'];
    if (events is! List ||
        latest is! int ||
        latest < _sequence ||
        replay['replay_epoch'] is! String ||
        replay['truncated'] is! bool) {
      throw const FormatException('Invalid child replay');
    }
    final received = <Map<String, dynamic>>[];
    var last = _sequence;
    for (final event in events) {
      if (event is! Map<String, dynamic> ||
          event['session_id'] != _watch ||
          event['seq'] is! int ||
          event['type'] is! String ||
          event['payload'] != null &&
              event['payload'] is! Map<String, dynamic>) {
        throw const FormatException('Invalid child event');
      }
      final seq = event['seq'] as int;
      if (seq <= _sequence) continue;
      if (seq <= last || seq > latest) {
        throw const FormatException('Unordered child replay');
      }
      received.add(event);
      last = seq;
    }
    _partial |= replay['truncated'] == true;
    for (final event in received) {
      final type = event['type'] as String;
      final data = event['payload'] as Map<String, dynamic>? ?? const {};
      _observeWork(type, data);
      // Mirrored tools have synthetic IDs and preview-only payloads. Do not
      // start a stopwatch from a replayed or inferred lifecycle boundary.
      if (type == 'tool.start' || type == 'tool.complete') {
        final mirrored =
            data['tool_id'] is String &&
            (data['tool_id'] as String).startsWith('submirror:');
        final tool = _runtime.observeTool(
          type,
          mirrored
              ? {
                  for (final entry in data.entries)
                    if (entry.key != 'args' && entry.key != 'duration_s')
                      entry.key: entry.value,
                  if (data['preview'] is String) 'context': data['preview'],
                }
              : data,
          live: false,
        );
        if (tool != null) _reading.observeTool(tool);
      } else {
        applyChatTranscriptEvent(
          runtime: _runtime,
          reading: _reading,
          type: type,
          data: data,
          live: false,
        );
      }
      if (type == 'message.complete' || type == 'turn.end') {
        if (!_reconcile) {
          _completionFloor = _rows.keys.fold(0, (a, b) => a > b ? a : b);
        }
        _runtime.completeTurn(
          failed: data['status'] == 'error',
          cancelled: data['status'] == 'interrupted',
          error: data['error']?.toString(),
        );
        // Keep the received reply until its saved replacement is available.
        final text = data['text']?.toString();
        if (text != null && text.isNotEmpty) _reading.updateStreaming(text);
        _reconcile = true;
      } else if (type == 'error' || type == 'turn.error') {
        _runtime.failTurn(data['message']?.toString() ?? 'Subagent failed');
      } else if (type == 'session.info') {
        _runtime.observeExecutionSnapshot(data);
      }
    }
    _epoch = replay['replay_epoch'] as String;
    _sequence = latest;
    if (_reconcile) await _loadPage(0);
  }

  void _observeWork(String type, Map<String, dynamic> data) {
    final agent = GatewaySubagentActivity.fromGatewayEvent(type, data);
    if (agent != null) {
      _agents[agent.id] = _agents[agent.id]?.merge(agent) ?? agent;
    }
    if (type == 'todo.updated') {
      final next = GatewayTodoSnapshot.parse(data);
      if (next != null) {
        _taskState.observe(
          next,
          liveTurn: runtime.executionActive ? _runtime.turnRevision : null,
        );
      }
    }
  }

  @override
  ProfileSupervisionObservation get state => ProfileSupervisionObservation(
    key: ProfileSessionKey(scope, sessionId),
    subagents: _agents.values,
    unconfirmedSubagentIds: const {},
    subagentsLoading: false,
    subagentsAvailable: _available,
    subagentsError: null,
    sessionControl: null,
    sessionControlLoading: false,
    sessionControlWorking: false,
    sessionControlError: null,
    sessionControlNotice: null,
    processes: const [],
    processesLoading: false,
    processesError: null,
    inlineProcessesError: null,
    actionBusy: false,
    actionError: null,
    stopping: const {},
    processErrors: const {},
  );
  @override
  Future<void> refreshSubagents() => refresh();
  @override
  SubagentInspectionDetail openSubagent(String id) => ReadOnlySubagentDetail(
    owner: this,
    activity: () => _agents[id]!,
    unconfirmed: () => _error != null,
    createTimeline: (child) => child.childSessionId == null
        ? null
        : SubagentTimelineSession(
            onOperationalError: onOperationalError,
            scope: scope,
            sessionId: child.childSessionId!,
            read: _read,
            history: _history,
            isCurrent: () => _current,
          ),
  );

  @override
  Iterable<PositionedHermesQuestion> get requestActivities =>
      _reading.requestActivities;
  @override
  List<Map<String, dynamic>> get messages => _reading.messages;
  @override
  String get streaming => _reading.streaming;
  @override
  String? get historySessionId => sessionId;
  @override
  int? get nextHistoryOffset => _older;
  @override
  bool get historyLoading => _loading;
  @override
  bool get historyAvailable => _available;
  @override
  bool get historyPaging => _paging;
  @override
  String? get historyError =>
      _historyFailed && _showReadFailure ? _error : null;
  @override
  bool get historyUnavailable => false;
  @override
  TranscriptPosition get readingPosition => _reading.readingPosition;
  @override
  Object messagePresentationId(Map<String, dynamic> row) =>
      _reading.messagePresentationId(row);
  @override
  void recordReading(TranscriptBookmark? resume, {int? readThrough}) =>
      _reading.recordReading(resume, readThrough: readThrough);
  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _reading.dispose();
    _runtime.dispose();
    super.dispose();
  }
}

/// Read-only detail used by worker history and nested child timelines.
final class ReadOnlySubagentDetail extends ChangeNotifier
    implements SubagentInspectionDetail {
  ReadOnlySubagentDetail({
    required this._owner,
    required this._activity,
    required this._unconfirmed,
    required SubagentTimelineSession? Function(GatewaySubagentActivity)
    createTimeline,
  }) : timeline = createTimeline(_activity()) {
    _owner.addListener(_changed);
  }
  final Listenable _owner;
  final GatewaySubagentActivity Function() _activity;
  final bool Function() _unconfirmed;
  void _changed() => notifyListeners();
  @override
  final SubagentTimelineSession? timeline;
  @override
  bool get supportsTail => false;
  @override
  SubagentSupervisionObservation get state => SubagentSupervisionObservation(
    activity: _activity(),
    unconfirmed: _unconfirmed(),
    canControl: false,
    acceptsSteer: false,
    tail: null,
    lastAvailableTail: null,
    tailError: null,
    inlineTailError: null,
    tailFailures: 0,
    loadingTail: false,
    steering: false,
    interrupting: false,
    controlMessage: null,
    controlFailed: false,
  );
  @override
  void setActive(bool value) => timeline?.setActive(value);
  @override
  Future<void> refreshTail() async {}
  @override
  void retryTail() {}
  @override
  Future<bool> steer(String text) async => false;
  @override
  Future<void> interrupt() async {}
  @override
  void dispose() {
    _owner.removeListener(_changed);
    timeline?.dispose();
    super.dispose();
  }
}

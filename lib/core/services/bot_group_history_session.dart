import '../models/hermes_question.dart';
import '../models/canonical_session.dart';
import 'chat_transcript_events.dart';
import 'conversation_reading_memory.dart';
import 'subagent_timeline_session.dart';
import 'dart:async';
import '../models/transcript_position.dart';
import '../models/chat_runtime.dart';
import '../models/gateway_insight.dart';
import '../models/gateway_todo.dart';
import '../models/hermes_profile.dart';
import '../models/profile_session_key.dart';
import '../models/profile_supervision.dart';
import 'chat_runtime.dart';
import 'transcript_reading.dart';
import 'package:flutter/foundation.dart';
import '../models/bots.dart';
import '../models/transcript_reader.dart';
import '../models/transcript_timeline.dart';
import 'bots_repository.dart';
import 'profile_gateway.dart';

/// One passive inspection route. Polls stock observations; never admits commands.
class BotGroupHistorySession extends ChangeNotifier
    implements SubagentInspectionSession {
  BotGroupHistorySession(this.repository, this.group, {this.readingPositions}) {
    repository.retain();
    _reading = _newReading(null);
  }

  final BotsRepository repository;
  final ConversationReadingRegistry? readingPositions;
  final BotGroup group;
  BotGroupMember? _member;
  BotGroupMember? get member => _member;
  late _BotGroupHistoryReading _reading;
  TranscriptReader get reader => _reading;
  bool get historyAvailable => _reading._available;
  final _savedReadings = <(String, String), _BotGroupHistoryReading>{};
  bool _closed = false;
  int _generation = 0;

  Timer? _poll;
  bool _visible = false;
  int _liveGeneration = 0;
  ChatRuntimeObservation get runtime => _reading._runtime.observation;
  Map<String, dynamic>? get streamingMessage =>
      _reading._reading.streamingMessage;
  List<GatewayTodo> get todos => _reading._taskState.current(
    active: runtime.executionActive,
    turn: _reading._runtime.turnRevision,
  );
  List<GatewaySubagentActivity> get subagents =>
      List.unmodifiable(_reading._agents.values);
  String? get liveError => _reading._liveError;
  ProfileSessionKey? get key => _reading._session == null
      ? null
      : ProfileSessionKey(_reading._reading.scope, _reading._session!);
  bool get liveAnswering =>
      runtime.executionActive ||
      runtime.needsInput ||
      _reading._needsHistoryReconciliation;

  _BotGroupHistoryReading _newReading(BotGroupMember? member) =>
      _BotGroupHistoryReading(
        WorkspaceScope(
          connectionId: repository.scope.connectionId,
          connectionIdentity: repository.scope.connectionIdentity,
          profileName: member?.profile ?? repository.scope.profileName,
        ),
      );

  void _bindReading(_BotGroupHistoryReading reading, String session) {
    final memory = readingPositions?.chat(
      ProfileSessionKey(reading._reading.scope, session),
    );
    if (memory != null) reading._reading.readingMemory = memory;
  }

  void setVisible(bool value) {
    _visible = value;
    _schedulePoll();
  }

  void _schedulePoll() {
    _poll?.cancel();
    _poll = null;
    if (_closed || !_visible) return;
    final working =
        liveAnswering ||
        liveError == null && subagents.any((agent) => !agent.isTerminal);
    _poll = Timer(Duration(milliseconds: working ? 500 : 3000), () async {
      await refreshLive(discover: true);
      _schedulePoll();
    });
  }

  /// Coalesced read-only replay, scoped to the selected durable worker identity.
  Future<void> refreshLive({bool discover = false}) async {
    final member = _member;
    final reading = _reading;
    if (_closed || member == null || reading._loading && !reading._available) {
      return;
    }
    if (reading._session == null && !discover) return;
    if (reading._livePending case final pending?) return pending;
    final generation = _liveGeneration;
    bool current() =>
        !_closed &&
        generation == _liveGeneration &&
        identical(reading, _reading);
    final done = Completer<void>();
    reading._livePending = done.future;
    repository.retain();
    try {
      if (reading._session == null) {
        await _load(refresh: true, quiet: true);
        if (!current() || reading._session == null) return;
      }
      final response = await repository.groupMemberObservation(
        group,
        member,
        'session.active_list',
        {},
      );
      if (!current()) return;
      final rows = response['sessions'];
      if (rows is! List) {
        throw const FormatException('Missing active worker list');
      }
      final matches = rows
          .whereType<Map>()
          .where(
            (row) =>
                row['session_key'] == reading._session &&
                row['title'] == 'Group: ${group.id}',
          )
          .toList();
      if (matches.length > 1) {
        throw const FormatException('Ambiguous worker runtime');
      }
      final live = matches.firstOrNull;
      if (live == null) {
        reading._needsHistoryReconciliation |=
            runtime.executionActive || reading._reading.streaming.isNotEmpty;
        // Runtime absence settles the work indicator independently of whether
        // the saved replacement can be read. Preserve received text on failure.
        reading._runtime.observeExecutionSnapshot({'running': false});
        if (discover || reading._needsHistoryReconciliation) {
          final reconciled = await _load(refresh: true, quiet: true);
          if (!current()) return;
          if (reconciled) reading.reconcileSavedHistory();
        }
        reading._liveError = null;
        return;
      }
      final id = live['id'];
      final status = live['status'];
      if (id is! String ||
          id.isEmpty ||
          !const {'working', 'starting', 'waiting', 'idle'}.contains(status)) {
        throw const FormatException('Invalid worker runtime');
      }
      if (id != reading._runtimeId) {
        reading._runtimeId = id;
        reading._sequence = 0;
        reading._epoch = null;
        reading._partialLive = false;
        reading._agents.clear();
        reading._runtime.replaceRuntime(id);
        reading._reading.updateStreaming('');
      }
      Future<void> mount({
        String? expectedEpoch,
        bool skipMissing = false,
      }) async {
        final snapshot = await repository.groupMemberObservation(
          group,
          member,
          'session.resume',
          {'session_id': id, 'display_projection': true},
        );
        if (!current()) return;
        final cursor = CanonicalReplayCursor.fromSnapshot(
          snapshot,
          expectedSessionId: id,
          expectedEpoch: expectedEpoch,
        );
        reading._epoch = cursor.epoch;
        reading._sequence = skipMissing ? cursor.sequence : 0;
        reading._runtime.replaceRuntime(id);
        reading._runtime.observeExecutionSnapshot(snapshot);
        if (snapshot['pending'] is List) {
          reading._reading.observePendingReplyAdmissions(
            (snapshot['pending'] as List)
                .whereType<Map>()
                .where((row) => row['status'] != 'queued')
                .map((row) => row['admission_id'])
                .whereType<String>(),
          );
        }
      }

      Future<Map<String, dynamic>> readReplay() => repository
          .groupMemberObservation(group, member, 'session.events.since', {
            'session_id': id,
            'replay_epoch': reading._epoch,
            'last_sequence': reading._sequence,
          });
      if (reading._epoch == null) {
        await mount();
        if (!current()) return;
      }
      var replay = await readReplay();
      if (!current()) return;
      final epoch = replay['replay_epoch'];
      if (epoch is! String || epoch.isEmpty) {
        throw const FormatException('Missing worker replay epoch');
      }
      if (reading._epoch != epoch) {
        reading._partialLive = true;
        reading._agents.clear();
        await mount(expectedEpoch: epoch);
        if (!current()) return;
        reading._reading.updateStreaming('');
        replay = await readReplay();
        if (!current()) return;
      }
      if (replay['replay_epoch'] != reading._epoch) {
        throw const FormatException('Worker replay changed during refresh');
      }
      if (replay['snapshot_required'] is! bool ||
          replay['truncated'] is! bool) {
        throw const FormatException('Missing canonical replay continuity');
      }
      if (replay['snapshot_required'] == true || replay['truncated'] == true) {
        reading._partialLive = true;
        reading._agents.clear();
        await mount(expectedEpoch: reading._epoch, skipMissing: true);
        if (!current()) return;
        reading._reading.updateStreaming('');
        await _load(refresh: true, quiet: true);
        if (!current()) return;
        reading._liveError =
            'Earlier live activity is unavailable. Showing saved history and received updates.';
        return;
      }
      final events = replay['events'];
      final latest = replay['latest_seq'];
      if (events is! List ||
          latest is! int ||
          latest < 0 ||
          replay['truncated'] is! bool) {
        throw const FormatException('Invalid worker replay');
      }
      final received = <Map<String, dynamic>>[];
      var last = reading._sequence;
      for (final event in events) {
        if (event is! Map<String, dynamic> ||
            event['session_id'] != id ||
            event['type'] is! String ||
            (event['payload'] != null &&
                event['payload'] is! Map<String, dynamic>) ||
            event['seq'] is! int) {
          throw const FormatException('Invalid worker event');
        }
        final seq = event['seq'] as int;
        if (seq <= reading._sequence) continue;
        if (seq <= last || seq > latest) {
          throw const FormatException('Unordered worker replay');
        }
        received.add(event);
        last = seq;
      }
      final cold = reading._sequence == 0;
      var start = received.lastIndexWhere((e) => e['type'] == 'message.start');
      if (start >= 0) {
        final turn = (received[start]['payload'] as Map?)?['turn_id'];
        if (turn is String) {
          start = received.indexWhere(
            (event) =>
                event['type'] == 'message.start' &&
                (event['payload'] as Map?)?['turn_id'] == turn,
          );
        }
      }
      if (replay['truncated'] == true && (!cold || start < 0)) {
        reading._partialLive = true;
      }
      final wasActive = runtime.executionActive;
      var terminal = false;
      for (var index = 0; index < received.length; index++) {
        final event = received[index];
        final type = event['type'] as String;
        final data = event['payload'] as Map<String, dynamic>? ?? const {};
        reading.observeWork(type, data);
        if (cold && (status == 'idle' || index < start)) continue;
        if (type == 'message.start') {
          reading._partialLive = false;
          terminal = false;
        }
        if (data['turn_id'] is String) {
          reading._reading.observeReplyAdmission(
            event['admission_id'],
            turn: data['turn_id'],
          );
        }
        terminal |= reading.observeExecution(type, data);
      }
      reading._epoch = replay['replay_epoch'] as String;
      reading._sequence = latest;
      reading._runtime.reconcileOpenRequests(replay['open_requests']);
      if (!terminal) {
        reading._runtime.observeExecutionSnapshot({
          'running': status != 'idle',
        });
      }
      reading._needsHistoryReconciliation |=
          terminal ||
          status == 'idle' &&
              (wasActive || reading._reading.streaming.isNotEmpty);
      if (reading._needsHistoryReconciliation && !runtime.executionActive) {
        final reconciled = await _load(refresh: true, quiet: true);
        if (!current()) return;
        if (reconciled) reading.reconcileSavedHistory();
      }
      reading._liveError = reading._partialLive
          ? 'Earlier live activity is unavailable. Showing saved history and received updates.'
          : null;
    } catch (_) {
      if (current()) {
        reading._liveError =
            'Live activity could not refresh. Refresh to try again.';
      }
    } finally {
      repository.release();
      reading._livePending = null;
      done.complete();
      if (current()) notifyListeners();
    }
  }

  @override
  Future<void> refreshSubagents() => refreshLive();

  @override
  ProfileSupervisionObservation get state => ProfileSupervisionObservation(
    key: key ?? ProfileSessionKey(repository.scope, ''),
    subagents: subagents,
    unconfirmedSubagentIds: liveError == null
        ? const {}
        : subagents.map((a) => a.id),
    subagentsLoading: _reading._livePending != null,
    subagentsAvailable: _reading._epoch != null,
    subagentsError: liveError,
    sessionControl: null,
    sessionControlLoading: false,
    sessionControlWorking: false,
    sessionControlError: null,
    sessionControlNotice: null,
    processes: const [],
    processesLoading: false,
    processesError: null,
    actionBusy: false,
    actionError: null,
    stopping: const {},
    processErrors: const {},
  );

  @override
  SubagentInspectionDetail openSubagent(String id) {
    final reading = _reading;
    final member = _member!;
    final initial = subagents.firstWhere((agent) => agent.id == id);
    return ReadOnlySubagentDetail(
      owner: this,
      activity: () => reading._agents[id] ?? initial,
      unconfirmed: () => reading._liveError != null,
      createTimeline: (activity) {
        final child = activity.childSessionId;
        if (child == null) return null;
        return SubagentTimelineSession(
          scope: reading._reading.scope,
          sessionId: child,
          isCurrent: () => !_closed && identical(_reading, reading),
          read: (method, params) => method == 'session.resume'
              ? repository.watchSubagent(group, member, child)
              : repository.groupMemberObservation(
                  group,
                  member,
                  method,
                  params,
                ),
          history: (session, offset) =>
              repository.groupMemberHistory(group, member, session, offset),
        );
      },
    );
  }

  Future<void> select(BotGroupMember member) async {
    if (_closed) return;
    ++_generation;
    ++_liveGeneration;
    _member = member;
    _reading =
        _savedReadings[(member.id, member.profile)] ?? _newReading(member);
    final reading = _reading;
    reading._explicitRead = true;
    notifyListeners();
    try {
      if (!reading._available) await _load(refresh: true);
      // The screen admits initial live enrichment after its first readable
      // frame; selecting saved history must never await that independent read.
    } finally {
      reading._explicitRead = false;
      if (!_closed && identical(reading, _reading)) {
        notifyListeners();
        _schedulePoll();
      }
    }
  }

  Future<void> refresh() async {
    if (_closed || _reading.historyLoading || _member == null) return;
    final reading = _reading;
    reading._explicitRead = true;
    notifyListeners();
    try {
      await _load(refresh: true);
      if (!_closed && identical(reading, _reading)) await refreshLive();
    } finally {
      reading._explicitRead = false;
      if (!_closed && identical(reading, _reading)) {
        notifyListeners();
        _schedulePoll();
      }
    }
  }

  Future<void> loadOlder() async {
    if (_closed || _reading._loading || _reading._older == null) return;
    await _load(refresh: false);
  }

  Future<bool> _load({required bool refresh, bool quiet = false}) async {
    final reading = _reading;
    final generation = _generation;
    bool current() =>
        !_closed && generation == _generation && identical(reading, _reading);
    // Live replay remains independent of progressive history. Its terminal
    // reconciliation queues behind backfill, then reads a fresh saved tail.
    // Joining the older read would miss messages persisted after it started.
    while (reading._historyPending != null) {
      await reading._historyPending;
      if (!current()) return false;
    }
    if (!current()) return false;
    final done = Completer<bool>();
    reading._historyPending = done.future;
    var success = false;
    try {
      success = await _readHistory(refresh: refresh, quiet: quiet);
      return success;
    } finally {
      reading._historyPending = null;
      done.complete(success);
    }
  }

  Future<bool> _readHistory({
    required bool refresh,
    required bool quiet,
  }) async {
    final member = _member!;
    final reading = _reading;
    final generation = _generation;
    if (!refresh && reading._older == null) return true;
    final initial = refresh && !reading._available;
    // Only settled successful readings can be borrowed by another selection.
    _savedReadings.remove((member.id, member.profile));
    reading._loading = !quiet;
    reading._paging = !refresh;
    reading._error = null;
    notifyListeners();
    repository.retain();
    try {
      final session = refresh
          ? await repository.groupMemberSession(group, member)
          : reading._session;
      if (_closed || generation != _generation) return false;
      if (session == null) {
        reading._session = null;
        reading._older = null;
        reading._reading.installSavedHistory(const []);
        reading._available = true;
        return true;
      }
      // Raw pages can contain only invisible assistant calls and folded tools.
      // Stage the full read before replacing a previously readable snapshot.
      final retainedIds = reading._session == session
          ? reading.messages.map((row) => row['id']).whereType<int>().toSet()
          : const <int>{};
      final rows = <int, Map<String, dynamic>>{};
      var offset = refresh ? 0 : reading._older!;
      int? older;
      do {
        final page = await repository.groupMemberHistory(
          group,
          member,
          session,
          offset,
        );
        if (_closed || generation != _generation) return false;
        final pageIds = <int>{};
        for (final row in page.rows) {
          final id = row['id'];
          if (id is! int || !pageIds.add(id)) {
            throw const FormatException('Invalid worker history row');
          }
          rows[id] = Map.unmodifiable(row);
        }
        older = page.nextOffset;
        if (initial) {
          // Publish each received page before waiting on older messages. The
          // transcript renders their Activity lazily while backfill continues.
          _bindReading(reading, session);
          reading.installNewestPage(session, rows, older);
          notifyListeners();
        }
        final coversRetained =
            retainedIds.isNotEmpty && rows.keys.any(retainedIds.contains);
        if (older == null ||
            !refresh ||
            (quiet && coversRetained) ||
            ((!quiet || retainedIds.isEmpty) &&
                _conversationCount(rows) >= 20)) {
          break;
        }
        if (older <= offset) {
          throw const FormatException('Invalid worker history cursor');
        }
        offset = older;
      } while (true);
      if (refresh) {
        _bindReading(reading, session);
        reading.installNewestPage(session, rows, older);
      } else {
        final merged = <int, Map<String, dynamic>>{
          for (final row in reading.messages)
            if (row['id'] is int) row['id'] as int: row,
          ...rows,
        };
        reading._reading.installSavedHistory([
          for (final id in merged.keys.toList()..sort()) merged[id]!,
        ]);
      }
      reading.restoreWork();
      reading._session = session;
      if (!refresh) reading._older = older;
      reading._available = true;
      return true;
    } catch (_) {
      if (!_closed && generation == _generation) {
        reading._error =
            'Working history could not load. Refresh to try again.';
      }
      return false;
    } finally {
      repository.release();
      if (!_closed && generation == _generation) {
        reading._loading = false;
        reading._paging = false;
        if (reading._available && reading._error == null) {
          _savedReadings[(member.id, member.profile)] = reading;
        }
        notifyListeners();
      }
    }
  }

  static int _conversationCount(Map<int, Map<String, dynamic>> rows) {
    final timeline = TranscriptTimeline.project([
      for (final id in rows.keys.toList()..sort()) rows[id]!,
    ], presentationId: (row) => row['id'] as int);
    return timeline.sections
        .where((section) => !section.isActivity)
        .expand((section) => section.messages)
        .where((entry) => entry.role == 'user' || entry.role == 'assistant')
        .length;
  }

  @override
  void dispose() {
    _closed = true;
    _poll?.cancel();
    ++_liveGeneration;
    ++_generation;
    for (final reading in {..._savedReadings.values, _reading}) {
      reading._runtime.dispose();
      reading._reading.dispose();
    }
    _savedReadings.clear();
    repository.release();
    super.dispose();
  }
}

/// Each member keeps its saved rows and scroll memory for this inspection visit.
/// It holds saved facts only; all I/O remains in BotGroupHistorySession.
final class _BotGroupHistoryReading implements TranscriptReader {
  _BotGroupHistoryReading(WorkspaceScope scope)
    : _reading = TranscriptReading.passive(scope: scope),
      _runtime = ChatRuntime(runtimeId: '');
  final TranscriptReading _reading;
  final ChatRuntime _runtime;
  Future<void>? _livePending;
  Future<bool>? _historyPending;
  bool _needsHistoryReconciliation = false;

  void reconcileSavedHistory() {
    _needsHistoryReconciliation = false;
    _reading.updateStreaming('');
    _partialLive = false;
    _runtime.reconcileHistoricalActivity();
  }

  String? _runtimeId, _epoch, _liveError;
  int _sequence = 0;
  bool _partialLive = false;
  final _taskState = GatewayTodoState();
  bool _receivedLiveTodos = false;
  final _agents = <String, GatewaySubagentActivity>{};

  void observeWork(String type, Map<String, dynamic> data) {
    if (type == 'todo.updated') {
      final next = GatewayTodoSnapshot.parse(data);
      if (next != null &&
          _taskState.observe(
            next,
            liveTurn: _runtime.observation.executionActive
                ? _runtime.turnRevision
                : null,
          )) {
        _receivedLiveTodos = true;
      }
    }
    final agent = GatewaySubagentActivity.fromGatewayEvent(type, data);
    if (agent != null) {
      _agents[agent.id] = _agents[agent.id]?.merge(agent) ?? agent;
    }
  }

  void installNewestPage(
    String session,
    Map<int, Map<String, dynamic>> rows,
    int? older,
  ) {
    _reading.installSavedPage(
      ProfileHistoryPage(
        session,
        [for (final id in rows.keys.toList()..sort()) rows[id]!],
        0,
        rows.length,
        isComplete: older == null,
      ),
    );
    _session = session;
    // The adopted page may retain an older prefix already on screen. Its raw
    // row count, rather than the newest request's offset, is the next cursor.
    _older = older == null
        ? null
        : messages.where((row) => row['id'] is int).length;
    _available = true;
  }

  void restoreWork() {
    // History backfill can finish after a newer live snapshot. These older
    // receipts must not replace that snapshot, including an empty live list.
    if (_receivedLiveTodos) return;
    final todoCalls = <String>{};
    for (final row in messages) {
      if (row['tool_calls'] case final List calls) {
        for (final call in calls.whereType<Map>()) {
          if (call['function'] is Map &&
              call['function']['name'] == 'todo_list' &&
              call['id'] is String) {
            todoCalls.add(call['id'] as String);
          }
        }
      }
      if (row['role'] == 'tool' &&
          (todoCalls.contains(row['tool_call_id']) ||
              row['tool_name'] == 'todo_list')) {
        final snapshot = GatewayTodoSnapshot.parse(row['content']);
        if (snapshot != null) _taskState.observe(snapshot);
      }
    }
  }

  bool observeExecution(String type, Map<String, dynamic> data) {
    _runtime.observeEvent(type, data);
    applyChatTranscriptEvent(
      live: false,
      runtime: _runtime,
      reading: _reading,
      type: type,
      data: data,
    );
    switch (type) {
      case 'session.info':
        _runtime.observeExecutionSnapshot(data);
      case 'status.update':
        break;
      case 'message.complete':
      case 'turn.end':
        if (!_runtime.observation.executionActive) return true;
        final failed = data['status'] == 'error';
        final cancelled = data['status'] == 'interrupted';
        final text = data['text']?.toString() ?? _reading.streaming;
        if (text.isNotEmpty) {
          _reading.appendAssistant(
            text,
            turnGeneration: _runtime.turnRevision,
            reasoning: data['reasoning'] is String
                ? data['reasoning'] as String
                : '',
            responseReused:
                !failed && !cancelled && data['response_reused'] == true,
            responsePreviewed: data['response_previewed'] == true,
            responseTransformed: data['response_transformed'] == true,
            persistedTurn: data['persisted_turn'],
          );
        }
        _reading.retireReply();
        _runtime.completeTurn(
          failed: failed,
          cancelled: cancelled,
          error: failed ? data['error']?.toString() ?? 'Turn failed' : null,
        );
        return true;
      case 'error':
      case 'turn.error':
        _reading.retireReply();
        _runtime.failTurn(data['message']?.toString() ?? 'Turn failed');
        return true;
    }
    return false;
  }

  String? _session;
  int? _older;
  bool _explicitRead = false;
  bool _loading = false;
  bool _paging = false;
  bool _available = false;
  String? _error;
  @override
  bool get historyLoading => _loading || _explicitRead;
  @override
  bool get historyPaging => _loading && _paging;
  @override
  int? get nextHistoryOffset => _older;
  @override
  String? get historyError => _error;
  @override
  String? get historySessionId => _session;
  @override
  bool get historyUnavailable => false;
  @override
  bool get historyAvailable => _available;
  @override
  String get streaming => _reading.streaming;
  @override
  TranscriptPosition get readingPosition => _reading.readingPosition;
  @override
  void recordReading(TranscriptBookmark? resume, {int? readThrough}) =>
      _reading.recordReading(resume, readThrough: readThrough);
  @override
  Object messagePresentationId(Map<String, dynamic> row) =>
      _reading.messagePresentationId(row);
  @override
  Iterable<PositionedHermesQuestion> get requestActivities =>
      _reading.requestActivities;
  @override
  List<Map<String, dynamic>> get messages => _reading.messages;
}

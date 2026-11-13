import 'dart:async';
import '../models/transcript_position.dart';
import 'conversation_reading_memory.dart';

import '../models/notification_focus.dart';
import '../models/transcript_reader.dart';
import '../models/gateway_activity.dart';
import '../models/answer_versions.dart';
import '../models/hermes_profile.dart';
import '../models/local_transcript_message.dart';
import '../models/reading_snapshot_message.dart';
import '../models/transcript_reading.dart';
import '../models/user_message_content.dart';
import 'completion_diagnostics.dart';
import 'hermes_question_history.dart';
import '../models/hermes_question.dart';
import 'profile_gateway.dart';
import 'workspace_connection_failure.dart';

/// Sole writer of a chat's transcript rows, read revisions and presentation IDs.
/// It borrows transport; the coordinator supplies captured publication authority.
final class TranscriptReading implements TranscriptReader {
  TranscriptReading({
    required ProfileGateway gateway,
    ConversationReadingMemory? readingMemory,
  }) : readingMemory = readingMemory ?? ConversationReadingMemory(),
       _gateway = gateway,
       scope = gateway.scope;

  /// Saved rows and live display buffers without transport or command authority.
  TranscriptReading.passive({required this.scope})
    : readingMemory = ConversationReadingMemory(),
      _gateway = null;

  ConversationReadingMemory readingMemory;

  static const _observedToolLimit = 256;

  HermesQuestionHistory? questionHistory;

  @override
  Iterable<PositionedHermesQuestion> get requestActivities =>
      questionHistory?.activities ?? const [];

  void observeQuestion(HermesQuestion question, {String? afterTool}) =>
      questionHistory?.observe(
        question,
        afterMessage: _messages.lastOrNull?['id'],
        afterTool: afterTool,
      );

  final ProfileGateway? _gateway;
  final WorkspaceScope scope;
  ProfileGateway get _transport =>
      _gateway ?? (throw StateError('Passive reading has no transport'));
  List<Map<String, dynamic>> _messages = const [];
  String? _historySessionId;
  int? _nextHistoryOffset;
  int _historyGeneration = 0;
  bool _historyLoading = false;
  bool _historyPaging = false;
  String? _historyError;
  bool _historyUnavailable = false;
  bool _closed = false;
  String _streaming = '';
  Map<String, dynamic>? _streamingMessage;
  Map<String, dynamic>? _lastInterimMessage;
  int _lastInterimTurn = -1;
  String? _replyTurn;
  int _replySegment = 0;
  int _replyDisplayedOffset = 0;
  final _replyFragments = <int, String>{};
  final _sealedReplySegments = <(String, int)>{};
  final _completedReplyTurns = <String>{};
  String? _replyAdmission;
  final _replyReceipts = <String, Set<int>>{};
  Set<String>? _pendingReplyAdmissions;

  // Presentation provenance, scoped to this reading. Hermes still owns all
  // rows and work; hanging up must not erase which replies came from voice work.
  final _voiceSubmissions = <String>{};
  final _voiceAdmissions = <String>{};
  final _voiceReplyRows = <int>{};

  void registerVoiceSubmission(String submission) =>
      _voiceSubmissions.add(submission);

  void registerVoiceReplacement(String admission, String submission) {
    if (_voiceAdmissions.contains(admission)) {
      registerVoiceSubmission(submission);
    }
  }

  void observeVoiceAdmission(String submission, String admission) {
    if (_voiceSubmissions.contains(submission)) _voiceAdmissions.add(admission);
  }

  void observeVoiceCompletion(Map<String, dynamic> completion) {
    final receipt = completion['persisted_turn'];
    if (receipt is! Map ||
        !_voiceSubmissions.contains(receipt['submission_id'])) {
      return;
    }
    final rows = receipt['row_ids'];
    if (rows is List) _voiceReplyRows.addAll(rows.whereType<int>());
  }

  bool isVoiceTaskReply(Map<String, dynamic> row) =>
      row['role'] == 'assistant' &&
      (_voiceAdmissions.contains(row['_reply_admission']) ||
          _voiceReplyRows.contains(row['id']));

  void observePendingReplyAdmissions(Iterable<String> ids) {
    _pendingReplyAdmissions = ids.toSet();
  }

  /// Native completion can omit its body after streaming it. All consumers use
  /// the same resolved answer before settlement retires the stream.
  String completionText(Map<String, dynamic> completion) =>
      completion['text']?.toString() ?? streaming;

  void retireReply() {
    if (_replyTurn != null) _completedReplyTurns.add(_replyTurn!);
  }

  /// Envelope admission identifies the execution independently of its queued
  /// successor. A start replay must not clear the active segment's buffer.
  void observeReplyAdmission(Object? admission, {Object? turn}) {
    if (turn is String && _completedReplyTurns.contains(turn)) return;
    if (admission is String && admission.isNotEmpty) {
      _replyAdmission = admission;
    }
  }

  bool startReply(Map<String, dynamic> data) {
    final turn = data['turn_id'];
    if (turn is! String ||
        turn.isEmpty ||
        _completedReplyTurns.contains(turn)) {
      return false;
    }
    if (_replyTurn != turn) {
      if (_replyTurn != null) _completedReplyTurns.add(_replyTurn!);
      _replyTurn = turn;
      _replySegment = 0;
      _replyDisplayedOffset = 0;
      _replyFragments.clear();
      updateStreaming('');
    }
    return true;
  }

  /// Dart strings index UTF-16 code units, exactly the stock wire offset unit.
  /// Hold gaps rather than fabricating text; overlapping replay contributes only
  /// its not-yet-seen suffix. A seal supplies the authoritative complete body.
  bool appendReplyDelta(Map<String, dynamic> data) {
    final turn = data['turn_id'],
        segment = data['segment'],
        offset = data['offset'];
    final text = data['text'];
    if (turn is! String ||
        segment is! int ||
        segment < 0 ||
        offset is! int ||
        offset < 0 ||
        text is! String ||
        _completedReplyTurns.contains(turn) ||
        _sealedReplySegments.contains((turn, segment))) {
      return false;
    }
    if (_replyTurn != turn) {
      if (!startReply(data)) return false;
    }
    if (segment < _replySegment) return false;
    if (segment != _replySegment) {
      _replySegment = segment;
      _replyDisplayedOffset = 0;
      _replyFragments.clear();
      updateStreaming('');
    }
    final previous = _replyFragments[offset];
    if (previous == null || previous.length < text.length) {
      _replyFragments[offset] = text;
    }
    var body = _streaming;
    for (final start in _replyFragments.keys.toList()..sort()) {
      if (start > body.length + _replyDisplayedOffset) break;
      final part = _replyFragments.remove(start)!;
      final overlap = body.length + _replyDisplayedOffset - start;
      if (overlap < part.length) body += part.substring(overlap);
    }
    final changed = body != _streaming;
    if (changed) updateStreaming(body);
    return changed;
  }

  /// Steering splits display order, not the server's wire segment identity.
  void splitReplyForSteering({required int turnGeneration}) {
    if (_streaming.isEmpty) return;
    final length = _streaming.length;
    appendAssistant(
      _streaming,
      turnGeneration: turnGeneration,
      reasoning: '',
      responseReused: false,
      interim: true,
    );
    _replyDisplayedOffset += length;
  }

  bool sealReply(Map<String, dynamic> data, {required int turnGeneration}) {
    final turn = data['turn_id'], segment = data['segment'];
    if (turn is! String ||
        segment is! int ||
        segment < 0 ||
        _completedReplyTurns.contains(turn) ||
        _sealedReplySegments.contains((turn, segment))) {
      return false;
    }
    if (_replyTurn != turn && !startReply(data)) return false;
    if (segment < _replySegment) return false;
    if (segment != _replySegment) _replyDisplayedOffset = 0;
    _replySegment = segment;
    final body = data['text'];
    final text = body is String
        ? body.substring(_replyDisplayedOffset.clamp(0, body.length))
        : _streaming;
    if (text.isNotEmpty) {
      appendAssistant(
        text,
        turnGeneration: turnGeneration,
        reasoning: '',
        responseReused: false,
        interim: true,
        wireSealed: true,
      );
    }
    _sealedReplySegments.add((turn, segment));
    _replySegment = segment + 1;
    _replyDisplayedOffset = 0;
    _replyFragments.clear();
    updateStreaming('');
    return true;
  }

  final _messagePresentations = Expando<Object>();
  final _displayedPromptInputs = <String>{};
  final _ownedRows = Expando<bool>();
  final _observedTools = <String, GatewayToolActivity>{};
  // Passive measured facts from this chat's independent timing index. Both the
  // durable row and backend call must match; reopening cannot start a timer.
  final _cachedToolDurations = <(Object, String), double>{};
  int _toolDurationRevision = 0;

  int get toolDurationRevision => _toolDurationRevision;

  /// Measured facts are independent of the bounded transcript preview. Both
  /// saved-row and call identity must match before a restored timing is used.
  void restoreToolDurations(Iterable<Map<String, dynamic>> rows) {
    if (_closed) return;
    for (final row in rows) {
      _retainToolDuration(row);
    }
  }

  List<Map<String, dynamic>> captureToolDurations() => List.unmodifiable([
    for (final entry in _cachedToolDurations.entries)
      Map<String, dynamic>.unmodifiable({
        'id': entry.key.$1,
        'tool_call_id': entry.key.$2,
        'duration_s': entry.value,
      }),
  ]);

  void _retainToolDuration(Map<String, dynamic> row) {
    final id = row['id'];
    final callId = row['tool_call_id'];
    final seconds = row['duration_s'];
    if ((id is! int && id is! String) ||
        callId is! String ||
        callId.isEmpty ||
        seconds is! num ||
        !seconds.isFinite ||
        seconds < 0) {
      return;
    }
    final key = (id as Object, callId);
    final measured = seconds.toDouble();
    if (_cachedToolDurations[key] == measured) return;
    _cachedToolDurations[key] = measured;
    _toolDurationRevision++;
  }

  /// Retains actual backend receipts for matching saved rows, never creates a
  /// history row or gives a saved output execution authority.
  void observeTool(GatewayToolActivity activity) {
    final id = activity.toolId;
    if (_closed || id == null) return;
    if (identical(_observedTools[id], activity)) return;
    _observedTools[id] = activity;
    if (_observedTools.length > _observedToolLimit) {
      _observedTools.remove(_observedTools.keys.first);
    }
    if (!_messages.any(
      (row) => row['role'] == 'tool' && row['tool_call_id'] == id,
    )) {
      return;
    }
    _messages = List.unmodifiable([
      for (final row in _messages)
        if (row['role'] == 'tool' && row['tool_call_id'] == id)
          _freezeRow(_withToolReceipt(row, activity))
        else
          row,
    ]);
  }

  Map<String, dynamic> _withToolReceipt(
    Map<String, dynamic> row,
    GatewayToolActivity activity,
  ) {
    final enriched = <String, dynamic>{
      ...row,
      if (row['tool_name'] == null) 'tool_name': activity.name,
      if (row['args'] == null && activity.arguments != null)
        'args': activity.arguments,
      if (activity.durationSeconds != null)
        'duration_s': activity.durationSeconds,
      if (row['context'] == null && activity.context != null)
        'context': activity.context,
      if (row['summary'] == null && activity.summary != null)
        'summary': activity.summary,
      if (row['content'] == null && activity.result != null)
        'content': activity.result,
      if (row['labels'] == null && activity.labels.isNotEmpty)
        'labels': [
          for (final label in activity.labels)
            {'text': label.text, 'name': label.name, 'preview': label.preview},
        ],
    };
    _messagePresentations[enriched] = messagePresentationId(row);
    return enriched;
  }

  final _confirmedPresentations = <int, Object>{};
  int _commandNoticeSequence = 0;
  NotificationFocus? _notificationFocus;
  NotificationFocus? _notificationReadTarget;
  int _notificationFocusGeneration = 0;

  NotificationFocus? get notificationFocus => _notificationFocus;
  NotificationFocus? get notificationReadTarget => _notificationReadTarget;
  int get notificationFocusGeneration => _notificationFocusGeneration;

  void revealNotification(NotificationFocus? focus) {
    if (_closed) return;
    _notificationFocus = focus;
    _notificationFocusGeneration++;
  }

  bool releaseNotificationFocus(NotificationFocus focus, int generation) {
    if (_closed ||
        generation != _notificationFocusGeneration ||
        _notificationFocus != focus) {
      return false;
    }
    _notificationFocus = null;
    return true;
  }

  void restoreNotificationReadTarget(NotificationFocus? focus) {
    if (!_closed) _notificationReadTarget ??= focus;
  }

  void recordNotificationResult(NotificationFocus? focus) {
    if (!_closed) _notificationReadTarget = focus;
  }

  bool acknowledgeNotificationRead(NotificationFocus focus) {
    if (_closed || _notificationReadTarget?.identity != focus.identity) {
      return false;
    }
    _notificationReadTarget = null;
    return true;
  }

  @override
  List<Map<String, dynamic>> get messages => _messages;
  @override
  String? get historySessionId => _historySessionId;
  @override
  int? get nextHistoryOffset => _nextHistoryOffset;
  int get historyGeneration => _historyGeneration;
  @override
  bool get historyLoading => _historyLoading;
  @override
  bool get historyPaging => _historyLoading && _historyPaging;
  @override
  String? get historyError => _historyError;
  @override
  bool get historyUnavailable => _historyUnavailable;
  @override
  bool get historyAvailable =>
      _historySessionId != null || _messages.isNotEmpty;
  @override
  TranscriptPosition get readingPosition => readingMemory.position;
  @override
  String get streaming => _streaming;
  Map<String, dynamic>? get streamingMessage => _streamingMessage;

  @override
  Object messagePresentationId(Map<String, dynamic> row) =>
      _messagePresentations[row] ??= Object();

  @override
  void recordReading(TranscriptBookmark? resume, {int? readThrough}) {
    if (!_closed) readingMemory.record(resume, readThrough: readThrough);
  }

  void cancelReads() {
    _historyGeneration++;
    _historyLoading = false;
    _historyPaging = false;
  }

  void dispose() {
    _closed = true;
    _observedTools.clear();
    _displayedPromptInputs.clear();
    // Retire read/publication authority immediately, but retain passive facts
    // for the controller's final ordered snapshot. Later chats may be captured
    // only after earlier index writes finish; disposal cannot erase their batch.
    cancelReads();
  }

  /// A replacement runtime keeps visible work but cannot retain old paging.
  void resetHistorySegment() {
    if (_closed) return;
    cancelReads();
    _historySessionId = null;
    _nextHistoryOffset = null;
    _historyError = null;
  }

  void updateStreaming(String text) {
    if (_closed) return;
    _streaming = text;
    final previous = _streamingMessage;
    if (text.isEmpty) {
      _streamingMessage = null;
    } else {
      final row = _freezeRow({
        'role': 'assistant',
        'content': text,
        '_reply_turn': ?_replyTurn,
        '_reply_segment': _replySegment,
        '_reply_offset': _replyDisplayedOffset,
        '_reply_admission': ?_replyAdmission,
      });
      if (previous != null) {
        _messagePresentations[row] = messagePresentationId(previous);
      }
      _streamingMessage = row;
    }
  }

  /// Resume has no authority to erase an admission still owned by the server.
  void applyReplySnapshot(String? text) {
    if (text == null || text.isEmpty) return;
    updateStreaming(
      text.substring(_replyDisplayedOffset.clamp(0, text.length)),
    );
    _replyFragments.clear();
  }

  void appendStreaming(String text) => updateStreaming('$_streaming$text');

  /// Sending and the later claim event describe the same input. Keep its first
  /// authored row, including attachments and presentation identity. Remember the
  /// input across saved-history refreshes so a late start cannot reinsert it.
  void appendSubmittedPrompt({
    required String inputId,
    required String text,
    String? displayText,
    String? displayKind,
    Map<String, dynamic>? displayMetadata,
    Iterable<UserMessageAttachment> attachments = const [],
  }) {
    if (_closed || !_displayedPromptInputs.add(inputId)) return;
    appendPrompt(
      text: text,
      displayText: displayText,
      displayKind: displayKind,
      displayMetadata: displayMetadata,
      attachments: attachments,
    );
  }

  void appendPrompt({
    required String text,
    String? displayText,
    String? displayKind,
    Map<String, dynamic>? displayMetadata,
    Iterable<UserMessageAttachment> attachments = const [],
    bool steering = false,
  }) {
    _append({
      'role': 'user',
      'content': text,
      'display_content': ?displayText,
      if (attachments.isNotEmpty) 'submitted_attachments': attachments.toList(),
      if (steering || displayKind != null)
        'display_kind': steering ? 'steer' : displayKind,
      'display_metadata': ?displayMetadata,
      if (!steering) 'timestamp': DateTime.now().millisecondsSinceEpoch / 1000,
    });
  }

  void appendCommandNotice(String text, {String? command}) {
    _append({
      'id':
          'command-${DateTime.now().microsecondsSinceEpoch}-${++_commandNoticeSequence}',
      'role': 'system',
      'content': text,
      '_command': ?command,
      '_command_notice': true,
      'timestamp': DateTime.now().millisecondsSinceEpoch / 1000,
    });
  }

  void appendReviewNotice({
    required String identity,
    required String text,
    num? timestamp,
  }) {
    _append({
      'id': 'review-$identity',
      'role': 'system',
      'content': text,
      '_review_notice': identity,
      'timestamp': timestamp ?? DateTime.now().millisecondsSinceEpoch / 1000,
    });
  }

  void retireReviewNotice(String identity) {
    if (_closed) return;
    _messages = List.unmodifiable(
      _messages.where((row) => row['_review_notice'] != identity),
    );
  }

  void _append(Map<String, dynamic> row) {
    if (_closed) return;
    _messages = List.unmodifiable([..._messages, _freezeRow(row)]);
  }

  /// Used by real saved-history adoption, branch creation and passive restore.
  /// Input containers never remain writable aliases of the owned transcript.
  void installSavedHistory(Iterable<Map<String, dynamic>> rows) {
    if (_closed) return;
    _messages = List.unmodifiable(rows.map(_freezeRow));
  }

  void installSnapshot(TranscriptReadingSnapshot snapshot) {
    if (_closed) return;
    cancelReads();
    // An index write can finish before its preview write. A stale preview must
    // not replace a newer independently persisted measurement after a restart.
    final rows = snapshot.messages.map(_snapshotToolDuration).toList();
    final streaming = rows
        .where((row) => row['_reply_streaming'] == true)
        .lastOrNull;
    installSavedHistory(rows.where((row) => row['_reply_streaming'] != true));
    for (final row in rows) {
      final turn = row['_reply_turn'], segment = row['_reply_segment'];
      if (turn is String && segment is int) {
        _replyTurn = turn;
        _replySegment = segment;
        _replyAdmission = row['_reply_admission'] as String?;
        final offset = row['_reply_offset'] is int
            ? row['_reply_offset'] as int
            : 0;
        _replyDisplayedOffset = offset;
        if (row['_reply_streaming'] != true) {
          if (row['_reply_sealed'] == true) {
            _sealedReplySegments.add((turn, segment));
            _replySegment = segment + 1;
            _replyDisplayedOffset = 0;
          } else if (row['content'] is String) {
            _replyDisplayedOffset += (row['content'] as String).length;
          }
        }
      }
    }
    if (streaming != null && streaming['content'] is String) {
      final text = streaming['content'] as String;
      _replyFragments.clear();
      updateStreaming(text);
    }

    _historySessionId = snapshot.historySessionId;
    _nextHistoryOffset = null;
  }

  Map<String, dynamic> _snapshotToolDuration(Map<String, dynamic> row) {
    if (row['role'] != 'tool') return row;
    final id = row['id'];
    final callId = row['tool_call_id'];
    final seconds = id != null && callId is String
        ? _cachedToolDurations[(id, callId)]
        : null;
    return seconds == null ? row : {...row, 'duration_s': seconds};
  }

  /// Adopts a saved page through the same paging and presentation policy used
  /// by a latest read. Local feedback remains in the resolved history segment.
  void installSavedPage(ProfileHistoryPage page) {
    if (_closed) return;
    final anchor = page.rows.isEmpty || _historySessionId != page.sessionId
        ? -1
        : _messages.indexWhere((row) => row['id'] == page.rows.first['id']);
    final prefix = anchor > 0
        ? _messages.take(anchor)
        : const <Map<String, dynamic>>[];
    final refreshed = [
      ...prefix.where((row) => !isLocalTranscriptMessage(row)),
      ...page.rows.map(_freezeRow),
    ];
    _retainMessagePresentations(refreshed, page.sessionId);
    final committedIds = refreshed.map((row) => row['id']).toSet();
    final journal = _messages.where((row) {
      final turn = row['_reply_turn'];
      final admission = row['_reply_admission'];
      if (turn is! String || admission is! String) return false;
      final receipt = _replyReceipts[turn];
      if (receipt != null && receipt.every(committedIds.contains)) return false;
      // A queued successor cannot keep a finished predecessor's journal alive.
      // Retire only after this successful canonical read, never on a failed read.
      return _pendingReplyAdmissions == null ||
          _pendingReplyAdmissions!.contains(admission);
    }).toList();
    final projected = [...refreshed, ...journal];
    _messages = List.unmodifiable(
      _historySessionId == page.sessionId
          ? retainLocalTranscriptMessages(_messages, projected)
          : projected,
    );
    if (_replyAdmission != null &&
        _pendingReplyAdmissions != null &&
        !_pendingReplyAdmissions!.contains(_replyAdmission)) {
      updateStreaming('');
    }
    _historySessionId = page.sessionId;
    _nextHistoryOffset = page.nextOffset == null ? null : refreshed.length;
  }

  /// Issues fixed-field passive rows without recopying owned content. Large
  /// content is already immutable; the snapshot encoder validates its bounds.
  /// Newly projected metadata and attachment containers are frozen here.
  ({String? historySessionId, List<Map<String, dynamic>> messages})
  captureSnapshot() => (
    historySessionId: _historySessionId,
    messages: List<Map<String, dynamic>>.unmodifiable(
      [
        ..._messages.skip(_messages.length > 60 ? _messages.length - 60 : 0),
        if (_streamingMessage != null)
          {..._streamingMessage!, '_reply_streaming': true},
      ].map(_captureSnapshotRow),
    ),
  );

  Map<String, dynamic> _captureSnapshotRow(Map<String, dynamic> row) {
    final projected = captureReadingSnapshotMessage(row);
    final metadata = projected['display_metadata'];
    if (metadata is Map) {
      projected['display_metadata'] = Map<Object?, Object?>.unmodifiable(
        metadata,
      );
    }
    final attachments = projected['submitted_attachments'];
    if (attachments is List) {
      projected['submitted_attachments'] =
          List<Map<String, dynamic>>.unmodifiable([
            for (final attachment in attachments)
              Map<String, dynamic>.unmodifiable(
                attachment as Map<String, dynamic>,
              ),
          ]);
    }
    return Map<String, dynamic>.unmodifiable(projected);
  }

  /// Captures only reading facts; status and dispatch remain coordinator-owned.
  TranscriptBranchCapture captureBranch() =>
      TranscriptBranchCapture._(this, _messages, _streaming, _streamingMessage);

  void stageRegeneration(List<Map<String, dynamic>> history, int promptIndex) {
    cancelReads();
    installSavedHistory(
      answerHistoryRows(history.take(promptIndex + 1).toList()),
    );
    updateStreaming('');
  }

  void stageSavedPromptEdit(
    List<Map<String, dynamic>> history,
    int promptIndex,
    String text,
  ) {
    cancelReads();
    installSavedHistory(answerHistoryRows(history.take(promptIndex).toList()));
    appendPrompt(text: text);
    updateStreaming('');
  }

  void restoreBranch(
    TranscriptBranchCapture capture, {
    required bool restoreStreaming,
  }) {
    if (_closed || !identical(capture._owner, this)) return;
    _messages = capture._messages;
    if (restoreStreaming) {
      _streaming = capture._streaming;
      _streamingMessage = capture._streamingMessage;
    }
  }

  void appendAssistant(
    String text, {
    required int turnGeneration,
    required String reasoning,
    required bool responseReused,
    Object? persistedTurn,
    bool interim = false,
    bool responsePreviewed = false,
    bool wireSealed = false,
    bool responseTransformed = false,
  }) {
    if (_closed) return;
    var preview = responsePreviewed || responseReused
        ? _lastInterimMessage
        : null;
    if (responseTransformed && _replyTurn != null) {
      final segment = preview?['_reply_segment'] ?? _replySegment;
      _messages = List.unmodifiable(
        _messages.where(
          (row) =>
              row['_reply_turn'] != _replyTurn ||
              row['_reply_segment'] != segment,
        ),
      );
      preview = null;
    }
    final reusePreview =
        preview != null &&
        _lastInterimTurn == turnGeneration &&
        _streaming.isEmpty &&
        _messages.contains(preview);
    // Stock reuse names text already delivered in this turn. Keep the complete
    // visible buffer across tool rounds; a reconnect with missing text still
    // needs the authoritative final body.
    final previewOffset = reusePreview && preview['_reply_offset'] is int
        ? preview['_reply_offset'] as int
        : interim
        ? 0
        : _replyDisplayedOffset;
    final content = responseTransformed
        ? text
        : responseReused && _streaming.isNotEmpty
        ? _streaming
        : previewOffset > 0
        ? text.substring(previewOffset.clamp(0, text.length))
        : text;
    final previous = reusePreview ? preview : _streamingMessage;
    final row = _freezeRow({
      ...?previous,
      'role': 'assistant',
      'content': content,
      '_reply_turn': ?_replyTurn,
      '_reply_segment': reusePreview
          ? preview['_reply_segment']
          : _replySegment,
      '_reply_admission': ?_replyAdmission,
      '_reply_offset': responseTransformed
          ? 0
          : reusePreview
          ? preview['_reply_offset']
          : _replyDisplayedOffset,
      if (wireSealed) '_reply_sealed': true,
      'timestamp': DateTime.now().millisecondsSinceEpoch / 1000,
      if (reasoning.isNotEmpty) '_gateway_reasoning': reasoning,
    });
    if (previous != null) {
      _messagePresentations[row] = messagePresentationId(previous);
    }
    if (reusePreview) {
      _messages = List.unmodifiable(
        _messages.map((item) => identical(item, preview) ? row : item),
      );
    } else {
      _messages = List.unmodifiable([..._messages, row]);
    }
    _lastInterimMessage = interim ? row : null;
    _lastInterimTurn = interim ? turnGeneration : -1;
    // Stock receipt proves final-row persistence, independently of whole-turn ACK.
    if (persistedTurn is Map) {
      final id = persistedTurn['final_assistant_row_id'];
      final ids = persistedTurn['row_ids'];
      if (_replyTurn != null &&
          persistedTurn['complete'] == true &&
          ids is List) {
        _replyReceipts[_replyTurn!] = ids.whereType<int>().toSet();
      }
      if (id is int &&
          id > 0 &&
          ids is List &&
          ids.whereType<int>().contains(id)) {
        _confirmedPresentations
          ..clear()
          ..[id] = messagePresentationId(row);
      }
    }
    if (!interim && _replyTurn != null) _completedReplyTurns.add(_replyTurn!);
    updateStreaming('');
  }

  void _retainMessagePresentations(
    List<Map<String, dynamic>> refreshed,
    String segment,
  ) {
    if (_historySessionId != null && _historySessionId != segment) {
      _confirmedPresentations.clear();
      _lastInterimMessage = null;
      return;
    }
    final previousById = {
      for (final row in _messages)
        if (row['id'] != null) row['id']: row,
    };
    for (final row in refreshed) {
      final previous = previousById[row['id']];
      final previousToken = previous == null
          ? null
          : _messagePresentations[previous];
      final confirmed = row['role'] == 'assistant'
          ? _confirmedPresentations.remove(row['id'])
          : null;
      if (confirmed != null && row['role'] == 'assistant') {
        _messagePresentations[row] = confirmed;
      } else if (previousToken != null) {
        _messagePresentations[row] = previousToken;
      }
    }
    // Bind local rows only within the ordered suffix after the same saved
    // boundary (or the whole transcript for its first turn), never by a global
    // text search. The reading bookmark may precede an unseen saved reply.
    final boundary = _messages.lastIndexWhere((row) => row['id'] != null);
    final nextBoundary = boundary < 0
        ? -1
        : refreshed.indexWhere((row) => row['id'] == _messages[boundary]['id']);
    if (boundary < 0 || nextBoundary >= 0) {
      bool visible(Map<String, dynamic> row) =>
          isBranchMessage(row) && !isHiddenAnswerMessage(row);
      final pending = _messages.skip(boundary + 1).where(visible).toList();
      final saved = refreshed.skip(nextBoundary + 1).where(visible).toList();
      bool matchesPrefix(int length) =>
          length > 0 &&
          saved.length >= length &&
          (boundary >= 0 || pending.firstOrNull?['role'] == 'user') &&
          pending
              .take(length)
              .indexed
              .every(
                (entry) =>
                    entry.$2['role'] == saved[entry.$1]['role'] &&
                    entry.$2['display_kind'] ==
                        saved[entry.$1]['display_kind'] &&
                    answerMessageDisplayText(entry.$2) ==
                        answerMessageDisplayText(saved[entry.$1]),
              );
      final bookmark = readingPosition.resume;
      final bookmarkIndex = bookmark == null
          ? -1
          : pending.indexWhere(
              (row) => _messagePresentations[row] == bookmark.messageId,
            );
      final retainCount =
          boundary >= 0 &&
              pending.length == saved.length &&
              matchesPrefix(pending.length)
          ? pending.length
          : matchesPrefix(bookmarkIndex + 1)
          ? bookmarkIndex + 1
          : 0;
      for (var i = 0; i < retainCount; i++) {
        final token = _messagePresentations[pending[i]];
        if (token != null) _messagePresentations[saved[i]] = token;
      }
    }
    final bookmark = readingPosition.resume;
    if (bookmark != null) {
      final saved = refreshed
          .where(
            (row) =>
                row['id'] is int &&
                _messagePresentations[row] == bookmark.messageId,
          )
          .firstOrNull;
      if (saved != null) {
        readingMemory.record(
          TranscriptBookmark(
            messageId: saved['id'] as int,
            fraction: bookmark.fraction,
            alignment: bookmark.alignment,
          ),
        );
      }
    }
    final interim = _lastInterimMessage;
    if (interim != null) {
      final token = messagePresentationId(interim);
      _lastInterimMessage = refreshed
          .where((row) => identical(_messagePresentations[row], token))
          .firstOrNull;
    }
  }

  /// Captured read-only routes own selection/publication; this read cannot
  /// install rows or revive execution from a saved transcript.
  Future<ProfileHistoryPage> savedPage(
    String sessionId, {
    int offset = 0,
  }) async {
    if (_closed) throw StateError('This chat reading owner is closed.');
    final page = await _transport.history(
      sessionId,
      offset: offset,
      limit: 500,
    );
    if (_closed) throw StateError('This chat reading owner is closed.');
    if (page.sessionId != sessionId) {
      throw const FormatException(
        'The server returned a different chat history.',
      );
    }
    return ProfileHistoryPage(
      page.sessionId,
      List.unmodifiable(page.rows.map(_freezeRow)),
      page.offset,
      page.limit,
      isComplete: page.isComplete,
    );
  }

  Future<bool> refresh({
    required String sessionId,
    required String runtimeId,
    required bool Function() canPublish,
    required void Function() onChanged,
    bool propagateFailure = false,
  }) async {
    final historySetupStarted = CompletionDiagnostics.enabled
        ? CompletionDiagnostics.start()
        : 0;
    final generation = ++_historyGeneration;
    _historyLoading = true;
    _historyPaging = false;
    _historyError = null;
    _historyUnavailable = false;
    onChanged();
    bool valid() =>
        !_closed && _historyGeneration == generation && canPublish();
    if (!valid()) {
      if (!_closed && _historyGeneration == generation) {
        _historyLoading = false;
        _historyPaging = false;
      }
      return false;
    }
    try {
      final historyRead = _transport.history(sessionId, runtimeId: runtimeId);
      // The REST transcript omits durations. Recover actual completion receipts
      // alongside the page, including calls completed while Wing was detached.
      final toolRead = _readCompletedTools(runtimeId);
      if (CompletionDiagnostics.enabled) {
        CompletionDiagnostics.finish(
          'controller.history_setup_sync',
          historySetupStarted,
        );
      }
      final page = await historyRead;
      if (!valid()) return false;
      final historyApplyStarted = CompletionDiagnostics.enabled
          ? CompletionDiagnostics.start()
          : 0;
      installSavedPage(page);
      // The page limit counts raw rows. A running turn can fill it with tool
      // calls and empty assistant rows, hiding the conversation on reopen.
      // Backfill such a page to its prompt; ordinary dialogue stays paginated.
      final needsConversationContext = _messages.any(
        (row) => row['role'] == 'tool',
      );
      if (CompletionDiagnostics.enabled) {
        CompletionDiagnostics.finish(
          'controller.history_apply_initial_sync',
          historyApplyStarted,
          values: {'rows': _messages.length},
        );
      }
      while (needsConversationContext &&
          _nextHistoryOffset != null &&
          !_messages.any(
            (row) => isAnswerPrompt(row) && !isHiddenAnswerMessage(row),
          )) {
        onChanged();
        if (!valid()) return false;
        final olderPage = await _transport.history(
          _historySessionId!,
          offset: _nextHistoryOffset!,
        );
        if (!valid()) return false;
        if (olderPage.sessionId != _historySessionId) {
          throw StateError('History moved to a new segment');
        }
        final ids = _messages.map((row) => row['id']).toSet();
        final oldest =
            _messages.where((row) => row['id'] is int).firstOrNull?['id']
                as int?;
        final older = olderPage.rows
            .where(
              (row) =>
                  !ids.contains(row['id']) &&
                  (oldest == null || (row['id'] as int) < oldest),
            )
            .toList();
        if (older.isEmpty && olderPage.nextOffset != null) {
          throw StateError('History did not advance');
        }
        _messages = List.unmodifiable([...older.map(_freezeRow), ..._messages]);
        _nextHistoryOffset = olderPage.nextOffset;
      }
      // Authoritative history owns loading and refresh completion. Optional
      // replay may span many runtime rings; publish the page without waiting.
      unawaited(_enrichCompletedTools(toolRead, valid, onChanged));
      return true;
    } catch (failure) {
      if (valid()) {
        _historyUnavailable = isTemporaryWorkspaceFailure(failure);
        _historyError = 'History could not be loaded. Retry to reload.';
      }
      if (propagateFailure) rethrow;
      return false;
    } finally {
      if (!_closed && _historyGeneration == generation) {
        _historyLoading = false;
        _historyPaging = false;
        if (canPublish()) onChanged();
      }
    }
  }

  Future<void> _enrichCompletedTools(
    Future<List<GatewayToolActivity>> read,
    bool Function() canPublish,
    void Function() onChanged,
  ) async {
    final tools = await read;
    if (!canPublish()) return;
    final previous = _messages;
    for (final activity in tools.skip(
      tools.length > _observedToolLimit ? tools.length - _observedToolLimit : 0,
    )) {
      // A live completion arriving during replay remains authoritative.
      if (_observedTools[activity.toolId]?.durationSeconds == null) {
        observeTool(activity);
      }
    }
    if (!identical(previous, _messages)) onChanged();
  }

  Future<List<GatewayToolActivity>> _readCompletedTools(
    String runtimeId,
  ) async {
    try {
      return await _transport.completedToolActivities(runtimeId);
    } catch (_) {
      // Timing enrichment is optional; a failed read cannot hide saved messages.
      return const [];
    }
  }

  Future<void> loadOlder({
    required bool Function() canPublish,
    required void Function() onChanged,
  }) async {
    if (_closed ||
        _historyLoading ||
        _nextHistoryOffset == null ||
        !canPublish()) {
      return;
    }
    final generation = _historyGeneration;
    final offset = _nextHistoryOffset!;
    _historyLoading = true;
    _historyPaging = true;
    _historyError = null;
    onChanged();
    bool valid() =>
        !_closed && _historyGeneration == generation && canPublish();
    if (!valid()) {
      if (!_closed && _historyGeneration == generation) {
        _historyLoading = false;
        _historyPaging = false;
      }
      return;
    }
    try {
      final page = await _transport.history(_historySessionId!, offset: offset);
      if (!valid()) return;
      if (page.sessionId != _historySessionId) {
        throw StateError('History moved to a new segment');
      }
      final ids = _messages.map((r) => r['id']).toSet();
      final oldest =
          _messages.where((r) => r['id'] is int).firstOrNull?['id'] as int?;
      final older = page.rows
          .where(
            (r) =>
                !ids.contains(r['id']) &&
                (oldest == null || (r['id'] as int) < oldest),
          )
          .toList();
      _messages = List.unmodifiable([...older.map(_freezeRow), ..._messages]);
      _nextHistoryOffset = page.nextOffset;
    } catch (_) {
      if (valid()) {
        _historyError =
            'Older messages could not be loaded. Retry or refresh history.';
      }
    } finally {
      if (!_closed && _historyGeneration == generation) {
        _historyLoading = false;
        _historyPaging = false;
        if (canPublish()) onChanged();
      }
    }
  }

  Map<String, dynamic> _freezeRow(Map<String, dynamic> source) {
    // Reuse already-owned immutable rows and their in-memory presentation token.
    if (_ownedRows[source] == true) return source;
    final receipt = source['role'] == 'tool'
        ? _observedTools[source['tool_call_id']]
        : null;
    if (receipt != null) source = _withToolReceipt(source, receipt);
    if (source['role'] == 'tool' && source['duration_s'] == null) {
      final id = source['id'];
      final callId = source['tool_call_id'];
      final seconds = id != null && callId is String
          ? _cachedToolDurations[(id, callId)]
          : null;
      if (seconds != null) source = {...source, 'duration_s': seconds};
    }
    if (source['role'] == 'tool') _retainToolDuration(source);
    final row = Map<String, dynamic>.unmodifiable({
      for (final entry in source.entries) entry.key: _freezeValue(entry.value),
    });
    _ownedRows[row] = true;
    final token = _messagePresentations[source];
    if (token != null) _messagePresentations[row] = token;
    return row;
  }

  Object? _freezeValue(Object? value) {
    if (value is Map) {
      return Map<Object?, Object?>.unmodifiable({
        for (final entry in value.entries) entry.key: _freezeValue(entry.value),
      });
    }
    if (value is List<UserMessageAttachment>) {
      return List<UserMessageAttachment>.unmodifiable([
        for (final attachment in value)
          UserMessageAttachment(
            name: attachment.name,
            target: attachment.target,
            isImage: attachment.isImage,
          ),
      ]);
    }
    if (value is List) {
      return List<Object?>.unmodifiable(value.map(_freezeValue));
    }
    if (value is UserMessageAttachment) {
      return UserMessageAttachment(
        name: value.name,
        target: value.target,
        isImage: value.isImage,
      );
    }
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    throw const FormatException('Unsupported transcript value.');
  }
}

/// Opaque owner-issued rollback facts, never an execution/resume capability.
final class TranscriptBranchCapture {
  const TranscriptBranchCapture._(
    this._owner,
    this._messages,
    this._streaming,
    this._streamingMessage,
  );
  final TranscriptReading _owner;
  final List<Map<String, dynamic>> _messages;
  final String _streaming;
  final Map<String, dynamic>? _streamingMessage;
}

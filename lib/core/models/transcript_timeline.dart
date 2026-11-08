import 'chat_runtime.dart';
import 'live_voice_turn.dart';
import 'hermes_question.dart';
import 'answer_versions.dart';
import 'review_notice.dart';
import 'transcript_message.dart';
import 'transcript_notice.dart';
import 'bot_exchange.dart';
import 'user_message_delivery.dart';

/// A transient, pure projection of the existing owner's immutable reading rows.
/// Ordinals identify presentation inputs, never runtime or command authority.
final class TranscriptTimeline {
  TranscriptTimeline._values(
    this.entries,
    this.sections,
    this.hasLiveMessage,
    this._replyDurations,
  );

  factory TranscriptTimeline._(
    Iterable<TranscriptTimelineEntry> source, {
    required bool hasLiveMessage,
    Map<Object, Duration>? replyDurations,
  }) {
    final entries = List<TranscriptTimelineEntry>.unmodifiable(source);
    final groups = _groupRows(entries);
    final durations = replyDurations ?? _savedReplyDurations(entries);
    return TranscriptTimeline._values(
      entries,
      _groupSections(groups, durations),
      hasLiveMessage,
      durations,
    );
  }

  final List<TranscriptTimelineEntry> entries;
  final List<TranscriptTimelineSection> sections;
  final bool hasLiveMessage;
  final Map<Object, Duration> _replyDurations;

  /// Merge local speech for display, preserving every native row and its order.
  /// Local timestamps place speech beside received task results; they never
  /// become saved history timestamps or contribute to execution timing.
  TranscriptTimeline withVoiceTurns(List<LiveVoiceTurn> turns) {
    if (turns.isEmpty) return this;
    final merged = <TranscriptTimelineEntry>[];
    var next = 0;
    for (final entry in entries) {
      final timestamp = entry.timestamp;
      while (next < turns.length &&
          timestamp != null &&
          turns[next].timestamp.isBefore(timestamp)) {
        if (turns[next].text.isNotEmpty) {
          merged.add(TranscriptTimelineEntry.voice(turns[next]));
        }
        next++;
      }
      merged.add(entry);
    }
    for (final turn in turns.skip(next)) {
      if (turn.text.isNotEmpty) merged.add(TranscriptTimelineEntry.voice(turn));
    }
    return TranscriptTimeline._(
      merged,
      hasLiveMessage: hasLiveMessage || turns.any((turn) => !turn.complete),
      replyDurations: _replyDurations,
    );
  }

  /// Message boundaries for the positioned live execution, before reasoning
  /// divides it into runs. Steering and internal notices are not new prompts.
  ({DateTime? start, DateTime? end}) executionTimingBefore(Object? answerId) {
    final endIndex = answerId == null
        ? entries.length
        : entries.indexWhere((entry) => entry.presentationId == answerId);
    if (endIndex < 0) return (start: null, end: null);
    final end = answerId == null ? null : entries[endIndex].timestamp;
    for (var index = endIndex - 1; index >= 0; index--) {
      final entry = entries[index];
      if (!isHiddenAnswerMessage(entry._row) && _isProcessReceipt(entry._row)) {
        return (start: null, end: end);
      }
      if (entry.suppressed || entry.role != 'user') continue;
      if (entry._startsReply) {
        return (start: entry.timestamp, end: end);
      }
    }
    return (start: null, end: end);
  }

  /// The current reading window admits older pages while holding newer saved
  /// rows until the reader reaches Latest. Input facts remain unchanged.
  TranscriptTimeline through(Object presentationId) {
    final end = entries.indexWhere(
      (entry) => entry.presentationId == presentationId,
    );
    if (end < 0) return this; // The selected row was retired by its source.
    return TranscriptTimeline._(
      entries.take(end + 1),
      hasLiveMessage: false,
      replyDurations: _replyDurations,
    );
  }

  factory TranscriptTimeline.project(
    List<Map<String, dynamic>> rows, {
    required Object Function(Map<String, dynamic>) presentationId,
    int? liveMessageIndex,
    TranscriptMessage Function(Map<String, dynamic>)? messageProjection,
    Iterable<PositionedHermesQuestion> requestActivities = const [],
  }) {
    final entries = <TranscriptTimelineEntry>[];
    final requests = <int, List<HermesQuestion>>{};
    for (final positioned in requestActivities) {
      final question = positioned.question;
      // Native clarify already owns its genuine question/choices/answer receipt.
      // Pending requests retain their existing authoritative input controls.
      if (question.kind == HermesQuestionKind.clarification ||
          question.status == HermesQuestionStatus.pending) {
        continue;
      }
      var after = positioned.afterTool == null
          ? -1
          : rows.lastIndexWhere(
              (row) =>
                  row['role'] == 'tool' &&
                  row['tool_call_id'] == positioned.afterTool,
            );
      if (after < 0 && positioned.groupSequence != null) {
        final sequence = positioned.groupSequence!;
        after = rows.lastIndexWhere(
          (row) =>
              row['sequence'] is int && (row['sequence'] as int) <= sequence,
        );
      } else if (positioned.afterMessage != null) {
        final messageIndex = rows.indexWhere(
          (row) => row['id'] == positioned.afterMessage,
        );
        if (messageIndex > after) after = messageIndex;
      }
      if (after < 0) {
        after = rows.lastIndexWhere(
          (row) =>
              row['timestamp'] is num &&
              (row['timestamp'] as num) * 1000 <=
                  question.timestamp.millisecondsSinceEpoch,
        );
      }
      (requests[after + 1] ??= []).add(question);
    }
    // Saved outputs refer to assistant calls by their backend identity. Calls
    // with no assistant prose must still contribute their inputs.
    final calls = <String, Map>{};
    final callLabels = <String, Object?>{};
    for (final row in rows) {
      if (row['role'] != 'assistant' || row['tool_calls'] is! List) continue;
      for (final call in row['tool_calls'] as List) {
        if (call is Map && call['id'] is String && call['function'] is Map) {
          calls[call['id'] as String] = call['function'] as Map;
          final labels = row['tool_call_labels'];
          if (labels is Map) {
            callLabels[call['id'] as String] = labels[call['id']];
          }
        }
      }
    }
    final readingRows = <Map<String, dynamic>>[
      for (final row in rows)
        if (row['role'] == 'tool' && calls[row['tool_call_id']] != null)
          {
            ...row,
            if (row['tool_name'] == null)
              'tool_name': calls[row['tool_call_id']]!['name'],
            if (row['args'] == null)
              'args': calls[row['tool_call_id']]!['arguments'],
            if (row['labels'] == null &&
                callLabels[row['tool_call_id']] != null)
              'labels': callLabels[row['tool_call_id']],
          }
        else
          row,
    ];
    final exchanges = _joinBotExchanges(readingRows);
    var humanReplay = false;
    for (var index = 0; index <= rows.length; index++) {
      for (final question in requests[index] ?? const <HermesQuestion>[]) {
        entries.add(TranscriptTimelineEntry.request(question));
      }
      if (index == rows.length) break;
      final row = rows[index];
      final readingRow = exchanges.remaining[index] ?? readingRows[index];
      final hidden = isHiddenAnswerMessage(row);
      if (!hidden && row['role'] == 'user') {
        if (transcriptUserDelivery(row)?.kind == 'agent_message' ||
            _isProcessReceipt(row)) {
          humanReplay = false;
        } else if (isAnswerPrompt(row)) {
          humanReplay = isHumanAnswerPrompt(row);
        }
      }
      final streaming = index == liveMessageIndex;
      final savedId = answerMessageId(row);
      final display = row['display_content'] ?? row['content'] ?? '';
      final branchAnswer =
          row['role'] == 'assistant' &&
          savedId != null &&
          isBranchMessage(row) &&
          humanReplay;
      entries.add(
        TranscriptTimelineEntry._(
          sourceIndex: index,
          presentationId: presentationId(row),
          row: readingRow,
          messageProjection: messageProjection,
          review:
              row['role'] == 'system' &&
              answerMessageText(row).startsWith('review:'),
          suppressed: hidden || exchanges.consumed.contains(index),
          exchangeReceipts: exchanges.receipts[index] ?? const [],
          emptyAssistant:
              row['role'] == 'assistant' &&
              display is String &&
              display.isEmpty,
          streaming: streaming,
          hasReasoning: _hasReasoning(row),
          savedMessageId: savedId,
          branchAnswer: branchAnswer,
        ),
      );
    }
    return TranscriptTimeline._(
      entries,
      hasLiveMessage: liveMessageIndex != null,
    );
  }

  /// Retained execution can join the activity immediately before its received
  /// final answer while saved history catches up. A durable answer, prompt or
  /// completed review still closes the association.
  TranscriptTimelineSection? get adjacentCurrentActivity =>
      _adjacentActivity(includeReceivedAnswer: true);

  /// Only adjacent unfinished activity joins a live reply. A saved answer,
  /// prompt, ordinary notice or completed review remains a boundary.
  TranscriptTimelineSection? get adjacentLiveActivity =>
      _adjacentActivity(includeReceivedAnswer: false);

  TranscriptTimelineSection? _adjacentActivity({
    required bool includeReceivedAnswer,
  }) {
    var index = sections.length - 1;
    if (index >= 0 && !sections[index].isActivity) {
      final last = sections[index].messages.last;
      if (last.streaming ||
          includeReceivedAnswer &&
              last.role == 'assistant' &&
              last.savedMessageId == null) {
        index--;
      }
    }
    if (index < 0 ||
        !sections[index].isActivity ||
        sections[index].hasLatestReview ||
        sections[index].messages.any((entry) => entry.streaming)) {
      return null;
    }
    return sections[index];
  }

  /// Post-frame visibility targets consult the current owner's rows, not a
  /// preceding frame's timeline. This returns identity only, never raw content.
  static Object? notificationAnswerPresentation(
    List<Map<String, dynamic>> rows, {
    required Object Function(Map<String, dynamic>) presentationId,
    int? messageId,
  }) {
    for (final row in rows.reversed) {
      if (row['role'] == 'assistant' &&
          !isHiddenAnswerMessage(row) &&
          row['content'] is String &&
          (row['content'] as String).trim().isNotEmpty &&
          (messageId == null || row['id'] == messageId)) {
        return presentationId(row);
      }
    }
    return null;
  }

  /// Choose the original nine-row neighborhood before hiding or grouping rows.
  /// Full-source ordinals and delivery context remain captured by the entries.
  TranscriptTimeline? nearby(int messageId) {
    final index = entries.indexWhere((entry) => entry.id == messageId);
    if (index < 0) return null;
    final start = (index - 4).clamp(0, entries.length).toInt();
    final end = (index + 5).clamp(0, entries.length).toInt();
    final result = TranscriptTimeline._(
      entries.sublist(start, end),
      hasLiveMessage: false,
      replyDurations: _replyDurations,
    );
    return result.sections.any((section) => section.containsMessage(messageId))
        ? result
        : null;
  }
}

/// Rebuild from the complete loaded reading on each observation. History stays
/// untouched; even a completion beyond Find's neighborhood enriches its call.
({
  Map<int, List<BotExchangeReceipt>> receipts,
  Set<int> consumed,
  Map<int, Map<String, dynamic>> remaining,
})
_joinBotExchanges(List<Map<String, dynamic>> rows) {
  final queues = <String, ({int index, BotExchangeQueue queue})>{};
  final ambiguous = <String>{};
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    if (row['role'] != 'tool' ||
        row['tool_name'] != 'message_agent' ||
        isHiddenAnswerMessage(row)) {
      continue;
    }
    final queue = BotExchangeQueue.fromResult(answerMessageText(row));
    if (queue == null) continue;
    if (queues.containsKey(queue.processId)) ambiguous.add(queue.processId);
    queues[queue.processId] = (index: i, queue: queue);
  }
  final receipts = <int, List<BotExchangeReceipt>>{};
  final consumed = <int>{};
  final remaining = <int, Map<String, dynamic>>{};
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    // Only producer notices carry process authority. Never inspect quoted
    // assistant/tool output or user prose to establish an exchange receipt.
    if (row['role'] != 'user' ||
        isHiddenAnswerMessage(row) ||
        (row['display_kind'] != null &&
            row['display_kind'] != 'process_complete')) {
      continue;
    }
    final delivery = processCompletionDelivery(
      answerMessageInspectionText(row),
    );
    if (delivery == null || delivery.processes.isEmpty) continue;
    final unmatched = <ProcessCompletion>[];
    final seconds = _savedTimestamp(row['timestamp']);
    final timestamp = seconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
    for (final process in delivery.processes) {
      final owner = queues[process.id];
      final receipt =
          owner == null || owner.index >= i || ambiguous.contains(process.id)
          ? null
          : owner.queue.receive(process, timestamp);
      if (receipt == null) {
        unmatched.add(process);
      } else {
        final values = receipts.putIfAbsent(owner!.index, () => []);
        if (!values.any((value) => value.raw == receipt.raw)) {
          values.add(receipt);
        }
      }
    }
    if (unmatched.isEmpty) {
      consumed.add(i);
    } else if (unmatched.length != delivery.processes.length) {
      final content = unmatched.length == 1
          ? unmatched.single.raw
          : '[IMPORTANT: ${unmatched.length} background processes completed.]\n\n${unmatched.map((p) => p.raw).join('\n\n')}';
      remaining[i] = {
        ...row,
        'content': content,
        'display_content': content,
        'display_metadata': const <String, dynamic>{},
      };
    }
  }
  return (
    receipts: {
      for (final e in receipts.entries) e.key: List.unmodifiable(e.value),
    },
    consumed: consumed,
    remaining: remaining,
  );
}

final class TranscriptTimelineEntry {
  TranscriptTimelineEntry.voice(LiveVoiceTurn turn)
    : question = null,
      sourceIndex = -1,
      presentationId = ('voice', turn.id),
      _row = const {},
      isReview = false,
      role = turn.user ? 'user' : 'assistant',
      id = null,
      suppressed = false,
      emptyAssistant = false,
      streaming = !turn.complete,
      hasReasoning = false,
      savedMessageId = null,
      branchAnswer = false,
      exchangeReceipts = const [],
      messageProjection = ((_) => TranscriptMessage.voice(
        id: turn.id,
        user: turn.user,
        text: turn.text,
        timestamp: turn.timestamp,
        complete: turn.complete,
      ));

  TranscriptTimelineEntry.request(HermesQuestion request)
    : question = request,
      sourceIndex = -1,
      presentationId = ('request', request.id),
      _row = const {},
      isReview = false,
      role = 'request',
      id = null,
      suppressed = false,
      emptyAssistant = false,
      streaming = false,
      hasReasoning = false,
      savedMessageId = null,
      branchAnswer = false,
      exchangeReceipts = const [],
      messageProjection = null;

  TranscriptTimelineEntry._({
    required this.sourceIndex,
    required this.presentationId,
    required Map<String, dynamic> row,
    required bool review,
    required this.suppressed,
    required this.emptyAssistant,
    required this.streaming,
    required this.hasReasoning,
    required this.savedMessageId,
    required this.branchAnswer,
    required this.exchangeReceipts,
    required this.messageProjection,
  }) : question = null,
       _row = row,
       isReview = review,
       role = row['role']?.toString() ?? '',
       id = row['id'] is int || row['id'] is String ? row['id'] : null;

  final int sourceIndex;
  final HermesQuestion? question;
  final Object presentationId;
  // Borrow the existing immutable reading row. Bodies are prepared only when a
  // viewport row or an opened disclosure asks for them; no rendered tree lives
  // in this transient index. Identity/grouping must never force these getters.
  final Map<String, dynamic> _row;
  DateTime? get timestamp {
    final seconds = _savedTimestamp(_row['timestamp']);
    return seconds == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch((seconds * 1000000).round());
  }

  final String role;
  final Object? id;
  final bool isReview;
  bool get isAgentNotice =>
      role == 'user' &&
      transcriptNoticeKind(_row) == 'async_delegation_complete';
  final TranscriptMessage Function(Map<String, dynamic>)? messageProjection;
  late final TranscriptMessage message =
      messageProjection?.call(_row) ??
      TranscriptMessage.fromRow(_row, streaming: streaming);
  late final TranscriptToolResult? tool = role == 'tool'
      ? TranscriptToolResult.fromRow(_row, exchangeReceipts: exchangeReceipts)
      : null;
  final List<BotExchangeReceipt> exchangeReceipts;
  late final String? reviewText = isReview ? reviewMessageText(_row) : null;
  final bool suppressed;
  final bool emptyAssistant;
  final bool streaming;
  final bool hasReasoning;
  late final String reasoning = _reasoning(_row);
  final int? savedMessageId;
  late final bool editablePrompt =
      savedMessageId != null && isHumanAnswerPrompt(_row);
  bool get _startsReply =>
      role == 'user' &&
      (isHumanAnswerPrompt(_row) ||
          transcriptUserDelivery(_row)?.kind == 'agent_message');
  final bool branchAnswer;
}

final class TranscriptTimelineGroup {
  TranscriptTimelineGroup._(
    Iterable<TranscriptTimelineEntry> messages, {
    this.isReasoning = false,
  }) : messages = List.unmodifiable(messages);
  final List<TranscriptTimelineEntry> messages;
  final bool isReasoning;
  Iterable<Object> get presentationIds => messages.map(
    (entry) => isReasoning
        ? ('reasoning', entry.presentationId)
        : entry.presentationId,
  );
  bool get isTool => !isReasoning && messages.last.role == 'tool';
  bool get isAgentNotice => !isReasoning && messages.last.isAgentNotice;
  HermesQuestion? get question => messages.last.question;
  String? get reviewText => messages.last.reviewText;
  bool get isActivity =>
      isReasoning ||
      isTool ||
      isAgentNotice ||
      messages.last.isReview ||
      question != null;
  List<TranscriptToolResult> get toolResults =>
      List.unmodifiable([for (final message in messages) ?message.tool]);
  bool containsMessage(int id) => messages.any((entry) => entry.id == id);
}

final class TranscriptTimelineSection {
  TranscriptTimelineSection._(
    Iterable<TranscriptTimelineGroup> groups, {
    this.replyDuration,
  }) : groups = List.unmodifiable(groups);
  final List<TranscriptTimelineGroup> groups;

  /// Approximate interval from the saved human prompt to its final saved reply.
  /// Both timestamps belong to Hermes; receipt time and tool durations do not.
  final Duration? replyDuration;
  Iterable<TranscriptTimelineEntry> get messages =>
      groups.expand((group) => group.messages);
  Iterable<Object> get presentationIds =>
      groups.expand((group) => group.presentationIds);
  bool get isTool => groups.last.isTool;
  bool get isActivity => groups.last.isActivity;
  int get toolCount => groups
      .where((group) => group.isTool)
      .fold(0, (count, group) => count + group.messages.length);
  int get reviewCount => messages.where((entry) => entry.isReview).length;
  bool get hasLatestReview => groups.last.messages.last.isReview;
  bool containsMessage(int id) =>
      groups.any((group) => group.containsMessage(id));
}

List<TranscriptTimelineGroup> _groupRows(
  Iterable<TranscriptTimelineEntry> entries,
) {
  final groups = <TranscriptTimelineGroup>[];
  final tools = <TranscriptTimelineEntry>[];
  void flushTools() {
    if (tools.isEmpty) return;
    groups.add(TranscriptTimelineGroup._(tools));
    tools.clear();
  }

  for (final entry in entries) {
    if (entry.suppressed) continue;
    if (entry.hasReasoning) {
      flushTools();
      groups.add(TranscriptTimelineGroup._([entry], isReasoning: true));
    }
    if (entry.emptyAssistant) {
      // Invisible assistant rows still separate neighboring tool runs.
      flushTools();
      continue;
    }
    if (entry.question != null) {
      flushTools();
      groups.add(TranscriptTimelineGroup._([entry]));
    } else if (entry.role == 'tool') {
      tools.add(entry);
    } else {
      flushTools();
      groups.add(TranscriptTimelineGroup._([entry]));
    }
  }
  flushTools();
  return List.unmodifiable(groups);
}

bool _isProcessReceipt(Map<String, dynamic> row) =>
    row['role'] == 'user' &&
    const {
      'process_complete',
      'process_notification',
    }.contains(transcriptNoticeKind(row));

List<TranscriptTimelineSection> _groupSections(
  List<TranscriptTimelineGroup> groups,
  Map<Object, Duration> replyDurations,
) {
  final sections = <List<TranscriptTimelineGroup>>[];
  for (final group in groups) {
    // The native post-turn review arrives after the final answer. Present it
    // with that answer's work while leaving the underlying entries untouched.
    // A user or other notice between them is a boundary, not a guessed owner.
    if (group.messages.last.isReview &&
        sections.isNotEmpty &&
        sections.last.last.messages.last.role == 'assistant' &&
        !sections.last.last.isActivity) {
      final answer = sections.length - 1;
      if (answer > 0 && sections[answer - 1].last.isActivity) {
        sections[answer - 1].add(group);
      } else {
        sections.insert(answer, [group]);
      }
    } else if (group.isActivity &&
        sections.isNotEmpty &&
        sections.last.last.isActivity) {
      sections.last.add(group);
    } else {
      sections.add([group]);
    }
  }
  return List.unmodifiable([
    for (var index = 0; index < sections.length; index++)
      TranscriptTimelineSection._(
        sections[index],
        replyDuration:
            sections[index].last.isActivity && index + 1 < sections.length
            ? replyDurations[sections[index + 1]
                  .last
                  .messages
                  .last
                  .presentationId]
            : null,
      ),
  ]);
}

Map<Object, Duration> _savedReplyDurations(
  List<TranscriptTimelineEntry> entries,
) {
  final durations = <Object, Duration>{};
  TranscriptTimelineEntry? prompt;
  TranscriptTimelineEntry? reply;

  void record() {
    final sent = prompt;
    final answer = reply;
    if (sent == null ||
        answer == null ||
        sent.savedMessageId == null ||
        answer.savedMessageId == null ||
        answer.streaming) {
      return;
    }
    final start = _savedTimestamp(sent._row['timestamp']);
    final end = _savedTimestamp(answer._row['timestamp']);
    if (start == null || end == null || end < start) return;
    durations[answer.presentationId] = Duration(
      microseconds: ((end - start) * Duration.microsecondsPerSecond).round(),
    );
  }

  for (final entry in entries) {
    // Folding a process receipt changes visibility, never the original turn's
    // timing boundary. A response to this internal trigger is a separate turn.
    if (!isHiddenAnswerMessage(entry._row) && _isProcessReceipt(entry._row)) {
      record();
      prompt = null;
      reply = null;
      continue;
    }
    if (entry.suppressed) continue;
    if (entry._startsReply) {
      record();
      prompt = entry;
      reply = null;
    } else if (entry.role == 'tool' || entry.emptyAssistant) {
      reply = null;
    } else if (entry.role == 'assistant') {
      final calls = entry._row['tool_calls'];
      reply =
          calls is List && calls.isNotEmpty ||
              transcriptNoticeKind(entry._row) != null
          ? null
          : entry;
    }
  }
  record();
  return Map.unmodifiable(durations);
}

double? _savedTimestamp(Object? value) =>
    value is num && value.isFinite && value > 0 && value <= 8640000000000
    ? value.toDouble()
    : null;

bool _hasReasoning(Map<String, dynamic> row) =>
    _reasoningParts(row).any((text) => text.trim().isNotEmpty);

String _reasoning(Map<String, dynamic> row) =>
    _reasoningParts(row).join('\n\n');

/// One authority/selection policy for grouping, rendering and receipt matching.
/// Iteration lets metadata indexing stop at the first readable part without
/// preparing the whole reasoning body. Empty display text remains authoritative.
Iterable<String> _reasoningParts(Map<String, dynamic> row) sync* {
  if (row['display_reasoning'] case final String text) {
    yield text;
    return;
  }
  for (final key in const [
    '_gateway_reasoning',
    'reasoning',
    'reasoning_content',
    'reasoning_details',
  ]) {
    final value = row[key];
    if (value is String && value.trim().isNotEmpty) {
      yield value;
      return;
    }
  }
  final details = row['reasoning_details'];
  var hasDetails = false;
  if (details is List) {
    for (final detail in details) {
      if (detail is! Map) continue;
      final text = switch (detail['type']) {
        'reasoning.text' => detail['text'],
        'reasoning.summary' => detail['summary'],
        _ => null,
      };
      if (text is String && text.trim().isNotEmpty) {
        hasDetails = true;
        yield text;
      }
    }
  }
  if (hasDetails) return;
  final items = row['codex_reasoning_items'];
  if (items is! List) return;
  for (final item in items) {
    if (item is! Map || item['type'] != 'reasoning') continue;
    final summary = item['summary'];
    if (summary is! List) continue;
    for (final part in summary) {
      if (part is! Map || part['type'] != 'summary_text') continue;
      final text = part['text'];
      if (text is String && text.trim().isNotEmpty) yield text;
    }
  }
}

/// One saved/live projection for normal chats and passive worker inspection.
final class ChatTranscriptProjection {
  ChatTranscriptProjection({
    required List<Map<String, dynamic>> savedRows,
    required Map<String, dynamic>? streamingMessage,
    required ChatRuntimeObservation runtime,
    required Object Function(Map<String, dynamic>) presentationId,
    required bool liveAnswering,
    Iterable<PositionedHermesQuestion> requestActivities = const [],
    bool readingWindow = false,
  }) {
    final captured = [...savedRows, ?streamingMessage];
    final active = liveAnswering
        ? runtime.activityEntries
              .where(
                (entry) =>
                    entry is! ChatRequestEntry ||
                    entry.question.status != HermesQuestionStatus.pending,
              )
              .toList()
        : const <ChatActivityEntry>[];
    final savedCalls = savedRows
        .where((row) => row['role'] == 'tool')
        .map((row) => row['tool_call_id'])
        .toSet();
    final firstRetained = runtime.activityEntries.indexWhere(
      (entry) =>
          entry is ChatReasoningEntry ||
          entry is ChatToolEntry && !savedCalls.contains(entry.activity.toolId),
    );
    final firstUnsavedTool = runtime.activityEntries.indexWhere(
      (entry) =>
          entry is ChatToolEntry && !savedCalls.contains(entry.activity.toolId),
    );
    final retained = <ChatActivityEntry>[
      for (var index = 0; index < runtime.activityEntries.length; index++)
        if (runtime.activityEntries[index] case final entry)
          if (switch (entry) {
            ChatRequestEntry(:final question) =>
              firstRetained >= 0 &&
                  index > firstRetained &&
                  question.status != HermesQuestionStatus.pending,
            // A newest-first history page can already contain a later call
            // while an earlier call still awaits backfill. Keep that suffix
            // in received order until all preceding calls have saved receipts.
            ChatToolEntry(:final activity) =>
              !savedCalls.contains(activity.toolId) ||
                  firstUnsavedTool >= 0 && index >= firstUnsavedTool,
            ChatReasoningEntry() => true,
          })
            entry,
    ];
    final current = readingWindow
        ? const <ChatActivityEntry>[]
        : liveAnswering
        ? active
        : retained;
    final currentRequests = current
        .whereType<ChatRequestEntry>()
        .map((entry) => entry.question.id)
        .toSet();
    final windowMessages = readingWindow
        ? savedRows.map((row) => row['id']).toSet()
        : null;
    final windowTools = readingWindow ? savedCalls : null;
    final currentCalls = current
        .whereType<ChatToolEntry>()
        .map((e) => e.activity.toolId)
        .whereType<String>()
        .toSet();
    final activeReasoning = <String>{
      for (final entry in active.whereType<ChatReasoningEntry>()) ...[
        entry.text.trim(),
        if (entry.availableText case final text?) text.trim(),
      ],
    }..remove('');
    bool isLiveReasoningReceipt(Map<String, dynamic> row) {
      if (row['role'] != 'assistant' ||
          (row['display_content'] ?? row['content'] ?? '') != '' ||
          !activeReasoning.contains(_reasoning(row).trim())) {
        return false;
      }
      final calls = row['tool_calls'];
      // Text alone cannot identify a turn. All calls must belong to the live
      // sequence, which already supplies this reasoning at its received position.
      return calls is List &&
          calls.isNotEmpty &&
          calls.every(
            (call) => call is Map && currentCalls.contains(call['id']),
          );
    }

    rows = List.unmodifiable(
      captured.where(
        (row) =>
            (row['role'] != 'tool' ||
                !currentCalls.contains(row['tool_call_id'])) &&
            !isLiveReasoningReceipt(row),
      ),
    );
    timeline = TranscriptTimeline.project(
      rows,
      presentationId: presentationId,
      liveMessageIndex: streamingMessage == null ? null : rows.length - 1,
      requestActivities: requestActivities.where(
        (entry) =>
            !currentRequests.contains(entry.question.id) &&
            (!readingWindow ||
                windowMessages!.contains(entry.afterMessage) ||
                entry.afterTool != null &&
                    windowTools!.contains(entry.afterTool)),
      ),
    );
    activity = List.unmodifiable(current);
    // A genuine saved current-call receipt establishes where retained work
    // belongs even when earlier receipts still await backfill. Hand its next
    // rendered conversation boundary to the viewport without inventing a row.
    final suppressedSuffix = !readingWindow && !liveAnswering
        ? captured.lastIndexWhere(
            (row) =>
                row['role'] == 'tool' &&
                currentCalls.contains(row['tool_call_id']),
          )
        : -1;
    final conversationBoundaries = {
      for (final section in timeline.sections)
        if (!section.isActivity) ...section.presentationIds,
    };
    retainedActivityBeforePresentationId = suppressedSuffix < 0
        ? null
        : captured
              .skip(suppressedSuffix + 1)
              .map(presentationId)
              .where(conversationBoundaries.contains)
              .firstOrNull;
  }
  late final List<Map<String, dynamic>> rows;
  late final TranscriptTimeline timeline;
  late final List<ChatActivityEntry> activity;
  late final Object? retainedActivityBeforePresentationId;
}

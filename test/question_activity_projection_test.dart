import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/models/gateway_sensitive_prompt.dart';
import 'package:wing/core/models/hermes_question.dart';
import 'package:wing/core/models/transcript_timeline.dart';
import 'package:wing/core/services/chat_runtime.dart' as execution;
import 'package:wing/core/services/hermes_question_history.dart';

const _prompt = <String, dynamic>{
  'id': 10,
  'role': 'user',
  'content': 'Inspect and report',
};
const _answer = <String, dynamic>{
  'id': 20,
  'role': 'assistant',
  'content': 'Finished inspecting',
};

Map<String, dynamic> _receipt(String call, int message) => {
  'id': message,
  'role': 'tool',
  'tool_call_id': call,
  'tool_name': 'terminal',
  'args': {'command': 'inspect $call'},
  'content': 'Completed $call',
};

/// Read the received Activity content, including retained work displayed after
/// its saved prefix while final history is unavailable.
List<String> _activityOrder(ChatTranscriptProjection projection) => [
  for (final section in projection.timeline.sections)
    if (section.isActivity)
      for (final entry in section.messages)
        if (entry.question case final question?)
          question.id
        else if (entry.tool case final tool?)
          tool.callId!,
  for (final entry in projection.activity)
    switch (entry) {
      ChatToolEntry(:final activity) => activity.toolId!,
      ChatRequestEntry(:final question) => question.id,
      ChatReasoningEntry() => 'reasoning',
    },
];

void main() {
  late execution.ChatRuntime runtime;
  late HermesQuestionHistory history;
  late List<Map<String, dynamic>> observedRows;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    history = HermesQuestionHistory(
      await SharedPreferences.getInstance(),
      'projection-owner',
    );
    runtime = execution.ChatRuntime(runtimeId: 'runtime');
    observedRows = [_prompt];
    runtime.onQuestion = (question) => history.observe(
      question,
      afterMessage: observedRows.lastOrNull?['id'],
      afterTool: runtime.observation.activityEntries
          .whereType<ChatToolEntry>()
          .lastOrNull
          ?.activity
          .toolId,
    );
    runtime.beginTurn(submitting: false);
    addTearDown(runtime.dispose);
    addTearDown(history.flush);
  });

  void tool(String id, {bool complete = false}) {
    runtime.observeTool(complete ? 'tool.complete' : 'tool.start', {
      'tool_id': id,
      'name': 'terminal',
      'args': {'command': 'inspect $id'},
      if (complete) 'result': 'Completed $id',
    });
  }

  void approve() {
    runtime.receiveApproval({
      'request_id': 'decision',
      'server_request_id': 'server-decision',
      'command': 'inspect protected source',
      'description': 'Allow inspection?',
      'choices': ['once', 'deny'],
    });
    final answer = runtime.beginApprovalAnswer('decision', 'once');
    runtime.finishApprovalAnswer(answer, 'decision', accepted: true);
  }

  void completeTurn() =>
      runtime.completeTurn(failed: false, cancelled: false, error: null);

  ChatTranscriptProjection project(
    List<Map<String, dynamic>> rows, {
    bool live = false,
    bool readingWindow = false,
  }) => ChatTranscriptProjection(
    savedRows: rows,
    streamingMessage: null,
    runtime: runtime.observation,
    presentationId: (row) => row['id']!,
    liveAnswering: live,
    requestActivities: history.activities,
    readingWindow: readingWindow,
  );

  test('live decisions remain between the tools received around them', () {
    tool('before');
    approve();
    tool('before', complete: true);
    tool('after');

    final projection = project([_prompt], live: true);
    expect(_activityOrder(projection), [
      'before',
      'approval/decision',
      'after',
    ]);
    expect(projection.timeline.entries.any((e) => e.question != null), isFalse);
    expect(history.questions.single.status, HermesQuestionStatus.approved);
    expect(projection.rows, [_prompt]);
  });

  test('accepted secure input follows the same ordered Activity handoff', () {
    tool('before');
    runtime.receiveSecure(
      const GatewaySensitivePromptRequest(
        kind: GatewaySensitivePromptKind.secret,
        requestId: 'secure-request',
        title: 'API credential needed',
        description: 'Provide the credential to continue',
        fieldLabel: 'Credential',
      ),
    );
    final response = runtime.beginSecureAnswer(
      runtime.observation.secureInput!,
    );
    runtime.finishSecureAnswer(response, accepted: true);
    tool('before', complete: true);
    tool('after');
    tool('after', complete: true);

    expect(_activityOrder(project([_prompt], live: true)), [
      'before',
      'secure/secret/secure-request',
      'after',
    ]);
    expect(history.questions.single.status, HermesQuestionStatus.answered);
    completeTurn();
    expect(
      _activityOrder(
        project([
          _prompt,
          _receipt('before', 11),
          _receipt('after', 12),
          _answer,
        ]),
      ),
      ['before', 'secure/secret/secure-request', 'after'],
    );
  });

  test(
    'completion preserves decision order while final history is missing',
    () {
      tool('before');
      approve();
      tool('before', complete: true);
      tool('after');
      tool('after', complete: true);
      completeTurn();

      // The final response is readable before its optional history refresh.
      final held = project([_prompt, _answer]);
      expect(_activityOrder(held), ['before', 'approval/decision', 'after']);
      expect(held.timeline.sections.last.messages.single.id, 20);

      expect(
        held.activity.whereType<ChatRequestEntry>().single.question.status,
        HermesQuestionStatus.approved,
      );
    },
  );

  test(
    'partial and complete saved history transfer a decision exactly once',
    () {
      tool('before');
      approve();
      tool('before', complete: true);
      tool('after');
      tool('after', complete: true);
      completeTurn();

      for (final rows in <List<Map<String, dynamic>>>[
        [_prompt, _answer],
        [_prompt, _receipt('before', 11), _answer],
        [_prompt, _receipt('before', 11), _receipt('after', 12), _answer],
      ]) {
        final projection = project(rows);
        expect(_activityOrder(projection), [
          'before',
          'approval/decision',
          'after',
        ]);
      }

      runtime.reconcileHistoricalActivity();
      final restored = project([
        _prompt,
        _receipt('before', 11),
        _receipt('after', 12),
        _answer,
      ]);
      expect(_activityOrder(restored), [
        'before',
        'approval/decision',
        'after',
      ]);
      expect(restored.activity, isEmpty);
      expect(
        restored.timeline.sections.where((s) => s.isActivity).single.toolCount,
        2,
      );
    },
  );

  test(
    'a newest history page cannot move later tools before retained work',
    () {
      tool('before');
      approve();
      tool('before', complete: true);
      tool('after');
      tool('after', complete: true);
      completeTurn();

      // REST pages start at the newest rows. Earlier tool receipts and the
      // prompt can still be awaiting an older-page read after this publication.
      final newestPage = [_receipt('after', 12), _answer];
      final held = project(newestPage);
      expect(_activityOrder(held), ['before', 'approval/decision', 'after']);
      expect(held.rows, [_answer]);
      expect(held.retainedActivityBeforePresentationId, 20);

      expect(held.timeline.entries.where((e) => e.question != null), isEmpty);

      final backfilled = project([
        _prompt,
        _receipt('before', 11),
        ...newestPage,
      ]);
      expect(_activityOrder(backfilled), [
        'before',
        'approval/decision',
        'after',
      ]);
      expect(backfilled.activity, isEmpty);
      expect(backfilled.retainedActivityBeforePresentationId, isNull);
      expect(
        backfilled.timeline.sections
            .where((s) => s.isActivity)
            .single
            .toolCount,
        2,
      );
      expect(
        backfilled.timeline.entries.where((e) => e.question != null),
        hasLength(1),
      );
    },
  );

  test(
    'saved receipts arriving during execution do not duplicate live facts',
    () {
      tool('before');
      approve();
      tool('before', complete: true);
      tool('after');
      final projection = project([_prompt, _receipt('before', 11)], live: true);

      expect(_activityOrder(projection), [
        'before',
        'approval/decision',
        'after',
      ]);
      expect(
        projection.timeline.entries.where((e) => e.role == 'tool'),
        isEmpty,
      );
      expect(
        projection.timeline.entries.where((e) => e.question != null),
        isEmpty,
      );
    },
  );

  test('a later interim message remains before its following request', () {
    tool('before');
    tool('before', complete: true);
    const interim = <String, dynamic>{
      'id': 12,
      'role': 'assistant',
      'content': 'The protected source needs consent',
    };
    observedRows = [_prompt, _receipt('before', 11), interim];
    approve();
    completeTurn();

    final projection = project([...observedRows, _answer]);
    expect(projection.timeline.entries.map((e) => e.question?.id ?? e.id), [
      10,
      11,
      12,
      'approval/decision',
      20,
    ]);
  });

  test('Find includes only requests anchored inside its captured window', () {
    tool('before');
    approve();
    tool('before', complete: true);
    completeTurn();
    final unrelated = project([
      const {'id': 30, 'role': 'user', 'content': 'An unrelated later turn'},
      const {'id': 31, 'role': 'assistant', 'content': 'A later reply'},
    ], readingWindow: true);
    expect(unrelated.timeline.entries.map((e) => e.id), [30, 31]);
    expect(unrelated.activity, isEmpty);
    expect(
      unrelated.timeline.entries.where((e) => e.question != null),
      isEmpty,
    );

    final matching = project([_prompt, _answer], readingWindow: true);
    expect(matching.timeline.entries.map((e) => e.question?.id ?? e.id), [
      10,
      'approval/decision',
      20,
    ]);
  });

  test(
    'a request received before the first tool stays first after completion',
    () {
      approve();
      tool('after');
      expect(_activityOrder(project([_prompt], live: true)), [
        'approval/decision',
        'after',
      ]);
      tool('after', complete: true);
      completeTurn();
      expect(_activityOrder(project([_prompt, _answer])), [
        'approval/decision',
        'after',
      ]);
      expect(
        _activityOrder(project([_prompt, _receipt('after', 11), _answer])),
        ['approval/decision', 'after'],
      );
    },
  );
}

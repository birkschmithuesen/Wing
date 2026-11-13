import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/transcript_reading.dart';
import 'dart:convert';
import 'package:wing/core/models/transcript_timeline.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_question.dart';
import 'package:wing/core/models/gateway_sensitive_prompt.dart';
import 'package:wing/core/services/chat_runtime.dart';
import 'package:wing/core/services/hermes_question_history.dart';

TranscriptTimeline project(
  HermesQuestionHistory history,
  List<Map<String, dynamic>> messages,
) => TranscriptTimeline.project(
  messages,
  presentationId: (row) => row['id']!,
  requestActivities: history.activities,
);

Iterable<Object?> identities(TranscriptTimeline timeline) =>
    timeline.entries.map((entry) => entry.question?.id ?? entry.id);

void main() {
  late SharedPreferences preferences;
  late HermesQuestionHistory history;
  late ChatRuntime runtime;
  const request = {
    'request_id': 'request',
    'server_request_id': 'server-request',
    'command': "python -c 'print(1)'",
    'description': 'Run verification',
  };
  final messages = <Map<String, dynamic>>[
    {'id': 10, 'role': 'user', 'content': 'Before'},
    {'id': 11, 'role': 'assistant', 'content': 'After'},
    {'id': 12, 'role': 'user', 'content': 'Newer'},
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    history = HermesQuestionHistory(preferences, 'chat-owner');
    addTearDown(history.flush);
    runtime = ChatRuntime(runtimeId: 'runtime');
    addTearDown(runtime.dispose);
    runtime.onQuestion = (question) =>
        history.observe(question, afterMessage: 10);
  });

  void expireApproval() => runtime.cancelRequest({
    'id': 'server-request',
    'method': 'approval',
    'reason': 'timeout',
  });

  void answerQuestion() {
    runtime.receiveQuestions({
      'request_id': 'question',
      'question': 'Which source?',
    });
    final answer = runtime.beginQuestionAnswer(runtime.observation.questions)!;
    runtime.finishQuestionAnswer(
      answer,
      answer: 'the chosen source',
      remaining: null,
    );
  }

  test('a settled clarification cannot return through a delayed snapshot', () {
    answerQuestion();
    runtime.reconcileOpenRequests([
      {
        'id': 'question',
        'method': 'clarify',
        'params': {'session_id': 'runtime', 'question': 'Which source?'},
      },
    ]);
    expect(runtime.observation.pendingQuestion, isNull);
    expect(history.questions.single.status, HermesQuestionStatus.answered);
  });

  test(
    'replayed batch cannot restore an answered question or replace a newer request',
    () {
      final batch = {
        'request_id': 'batch',
        'questions': [
          {'qid': 'q0', 'question': 'First?'},
          {'qid': 'q1', 'question': 'Second?'},
        ],
      };
      runtime.receiveQuestions(batch);
      final first = runtime.beginQuestionAnswer(runtime.observation.questions)!;
      runtime.finishQuestionAnswer(first, answer: 'one', remaining: ['q1']);
      runtime.receiveQuestions(batch);
      expect(runtime.observation.pendingQuestion?.questionId, 'q1');
      expect(runtime.observation.questions?.pendingNumber, 2);
      final second = runtime.beginQuestionAnswer(
        runtime.observation.questions,
      )!;
      runtime.finishQuestionAnswer(second, answer: 'two', remaining: []);
      runtime.receiveQuestions({
        'request_id': 'new',
        'question': 'New question?',
      });
      runtime.receiveQuestions(batch);
      expect(runtime.observation.pendingQuestion?.requestId, 'new');
    },
  );

  test(
    'same-question snapshot retains response but advancing the batch retires it',
    () {
      final batch = {
        'request_id': 'batch',
        'questions': [
          {'qid': 'q0', 'question': 'First?'},
          {'qid': 'q1', 'question': 'Second?'},
        ],
      };
      runtime.receiveQuestions(batch);
      final first = runtime.beginQuestionAnswer(runtime.observation.questions)!;
      runtime.receiveQuestions(batch);
      expect(first.current, isTrue);
      runtime.receiveQuestions({
        ...batch,
        'answers': {'q0': 'desktop answer'},
      });
      expect(first.current, isFalse);
      runtime.finishQuestionAnswer(first, answer: 'late answer', remaining: []);
      expect(runtime.observation.pendingQuestion?.questionId, 'q1');
    },
  );

  test('closed clarification cannot displace a newer request on replay', () {
    runtime.receiveQuestions({'request_id': 'old', 'question': 'Old?'});
    runtime.closeQuestion('old');
    expect(runtime.observation.pendingQuestion, isNull);
    runtime.receiveQuestions({'request_id': 'new', 'question': 'New?'});
    runtime.receiveQuestions({'request_id': 'old', 'question': 'Old?'});
    expect(runtime.observation.pendingQuestion?.requestId, 'new');
  });

  test('completed approvals join the canonical Activity timeline', () {
    runtime.receiveApproval(request);
    expireApproval();
    final timeline = TranscriptTimeline.project(
      messages,
      requestActivities: history.activities,
      presentationId: (row) => row['id']!,
    );
    final activity = timeline.sections.where((section) => section.isActivity);
    expect(activity, hasLength(1));
    expect(timeline.sections.first.messages.single.id, 10);
    expect(timeline.sections[2].messages.single.id, 11);
    expect(activity.single.toolCount, 0);
  });

  test('pending requests do not duplicate the active question in history', () {
    runtime.receiveApproval(request);
    expect(history.questions.single.status, HermesQuestionStatus.pending);
    expect(
      project(history, messages).entries.where((e) => e.question != null),
      isEmpty,
    );
  });

  test('delayed approval replay cannot erase expiry or first appearance', () {
    runtime.receiveApproval(request);
    final appeared = history.questions.single.timestamp;
    expireApproval();
    runtime.receiveApproval(request);
    expect(history.questions.single.status, HermesQuestionStatus.expired);
    expect(history.questions.single.timestamp, appeared);
  });

  test('completed question keeps its original neighbor as messages arrive', () {
    runtime.receiveApproval(request);
    expireApproval();
    expect(identities(project(history, messages.take(2).toList())), [
      10,
      'approval/request',
      11,
    ]);
    expect(identities(project(history, messages)), [
      10,
      'approval/request',
      11,
      12,
    ]);
  });

  test(
    'reopened history retains the saved outcome and message position',
    () async {
      runtime.receiveApproval(request);
      final appeared =
          history.questions.single.timestamp.millisecondsSinceEpoch;
      expireApproval();
      await history.flush();
      SharedPreferences.setMockInitialValues({
        for (final key in preferences.getKeys()) key: preferences.get(key)!,
      });
      final reopened = HermesQuestionHistory(
        await SharedPreferences.getInstance(),
        'chat-owner',
      );
      expect(reopened.questions.single.status, HermesQuestionStatus.expired);
      expect(
        reopened.questions.single.timestamp.millisecondsSinceEpoch,
        appeared,
      );
      expect(identities(project(reopened, messages)), [
        10,
        'approval/request',
        11,
        12,
      ]);
    },
  );

  test(
    'a different authenticated owner cannot read another question history',
    () {
      runtime.receiveApproval(request);
      expireApproval();
      expect(history.questions, isNotEmpty);
      expect(
        HermesQuestionHistory(preferences, 'another-owner').questions,
        isEmpty,
      );
    },
  );

  test(
    'room outcome retains the first sequence through replay and later answers',
    () {
      final question = HermesQuestion(
        id: 'approval',
        requestId: 'request',
        kind: HermesQuestionKind.approval,
        status: HermesQuestionStatus.pending,
        timestamp: DateTime(2026, 10, 15, 13, 27),
        description: 'Inspect source',
      );
      history.observe(question, groupSequence: 5);
      history.reconcile({});
      history.observe(question, groupSequence: 50);
      history.settle('approval', HermesQuestionStatus.approved);
      history.reconcile({});
      expect(history.questions.single.status, HermesQuestionStatus.approved);
      expect(
        identities(
          project(history, [
            {'id': 'old', 'sequence': 3},
            {'id': 'reply', 'sequence': 6},
            {'id': 'new', 'sequence': 51},
          ]),
        ),
        ['old', 'approval', 'reply', 'new'],
      );
    },
  );

  for (final (choice, status) in [
    ('once', HermesQuestionStatus.approved),
    ('deny', HermesQuestionStatus.rejected),
  ]) {
    test('accepted $choice decision records ${status.name}', () {
      runtime.receiveApproval({
        'request_id': choice,
        'command': 'echo $choice',
      });
      final answer = runtime.beginApprovalAnswer(choice, choice);
      runtime.finishApprovalAnswer(answer, choice, accepted: true);
      expect(history.questions.single.status, status);
    });
  }

  test('clarification response records an answered outcome', () {
    answerQuestion();
    expect(history.questions.single.status, HermesQuestionStatus.answered);
  });

  test(
    'native clarification history does not receive a second question row',
    () {
      answerQuestion();
      final native = <Map<String, dynamic>>[
        ...messages,
        {
          'id': 13,
          'role': 'tool',
          'name': 'clarify',
          'tool_call_id': 'native-clarify',
          'content': jsonEncode({
            'responses': [
              {
                'question': 'Which source?',
                'choices_offered': ['the chosen source'],
                'status': 'answered',
                'user_response': 'the chosen source',
              },
            ],
          }),
        },
      ];
      final timeline = project(history, native);
      expect(
        timeline.entries.where((entry) => entry.question != null),
        isEmpty,
      );
      expect(timeline.entries.last.tool!.rawResult, native.last['content']);
    },
  );

  test('interrupted secure input records cancellation', () {
    runtime.receiveSecure(
      const GatewaySensitivePromptRequest(
        kind: GatewaySensitivePromptKind.secret,
        requestId: 'secret',
        title: 'Secret needed',
        description: 'Authenticate',
        fieldLabel: 'Secret',
      ),
    );
    runtime.cancelRequest({
      'id': 'secret',
      'method': 'secret',
      'reason': 'interrupted',
    });
    expect(history.questions.single.status, HermesQuestionStatus.cancelled);
  });

  test(
    'missing pending approval records closed without inventing an answer',
    () {
      runtime.receiveApproval(request);
      runtime.reconcileApprovals(runtime.captureApprovalRead(), []);
      expect(history.questions.single.status, HermesQuestionStatus.closed);
    },
  );

  test(
    'saved question history excludes clarification response values',
    () async {
      answerQuestion();
      await history.flush();
      final saved = jsonEncode({
        for (final key in preferences.getKeys()) key: preferences.get(key)!,
      });
      expect(saved, contains('Which source?'));
      expect(saved, isNot(contains('the chosen source')));
      expect(saved, isNot(contains('lockedAnswers')));
    },
  );
  test(
    'question presentation identity survives outcome updates and refreshed rows',
    () {
      final reading = TranscriptReading.passive(
        scope: WorkspaceScope(
          connectionId: 'host',
          connectionIdentity: 'identity',
          profileName: 'default',
        ),
      )..questionHistory = history;
      reading.installSavedHistory([
        {'id': 10, 'role': 'user', 'content': 'Before'},
      ]);
      runtime.receiveApproval(request);
      expireApproval();
      final first = project(
        history,
        reading.messages,
      ).entries.singleWhere((entry) => entry.question != null);
      final identity = first.presentationId;
      history.settle('approval/request', HermesQuestionStatus.approved);
      reading.installSavedHistory([
        {'id': 10, 'role': 'user', 'content': 'Before'},
        {'id': 11, 'role': 'assistant', 'content': 'After'},
      ]);
      final updated = project(
        history,
        reading.messages,
      ).entries.singleWhere((entry) => entry.question != null);
      expect(updated.presentationId, identity);
      expect(updated.question!.status, HermesQuestionStatus.approved);
      expect(reading.messages.map((row) => row['id']), [10, 11]);
    },
  );

  test(
    'an untimestamped later reply cannot drag an unconfirmed prompt anchor down',
    () {
      history.observe(
        HermesQuestion(
          id: 'late-id',
          requestId: 'request',
          kind: HermesQuestionKind.approval,
          status: HermesQuestionStatus.closed,
          timestamp: DateTime.fromMillisecondsSinceEpoch(2000),
          description: '',
        ),
      );
      final projected = project(history, [
        {'id': 'prompt', 'timestamp': 1},
        {'id': 'later-reply'},
        {'id': 'newer-prompt', 'timestamp': 3},
      ]);
      expect(identities(projected), [
        'prompt',
        'late-id',
        'later-reply',
        'newer-prompt',
      ]);
    },
  );
  test(
    'pending command metadata updates without moving its original position',
    () {
      runtime.receiveApproval(request);
      final appeared = history.questions.single.timestamp;
      runtime.receiveApproval({...request, 'command': 'echo changed command'});
      expect(history.questions.single.command, 'echo changed command');
      expect(history.questions.single.timestamp, appeared);
      expireApproval();
      expect(
        identities(
          project(history, [
            {'id': 10},
            {'id': 11},
          ]),
        ),
        [10, 'approval/request', 11],
      );
    },
  );

  test(
    'restored locked clarification answers retain only the answered status',
    () {
      runtime.receiveQuestions({
        'request_id': 'batch',
        'questions': [
          {'qid': 'first', 'question': 'First question?'},
          {'qid': 'second', 'question': 'Second question?'},
        ],
        'answers': {'first': 'private response value'},
      });
      expect(history.questions.map((q) => q.status), [
        HermesQuestionStatus.answered,
        HermesQuestionStatus.pending,
      ]);
      expect(
        history.questions.map((q) => q.description).join(),
        isNot(contains('private response value')),
      );
    },
  );
}

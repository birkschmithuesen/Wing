import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_question.dart';
import 'package:wing/core/services/chat_runtime.dart';

Map<String, dynamic> approval(String id, int generation) => {
  'kind': 'approval',
  'prompt_id': id,
  'execution_generation': generation,
  'command': 'echo reviewed',
  'description': 'Check the workspace',
  'choices': ['once', 'deny'],
};
Map<String, dynamic> question(String id, int generation) => {
  'kind': 'clarify',
  'prompt_id': id,
  'execution_generation': generation,
  'question': 'Which source?',
  'choices': ['Work', 'Home'],
  'multi_select': false,
};
Map<String, dynamic> serverApproval() => {
  'id': 'server-frame',
  'method': 'approval',
  'params': {
    'session_id': 'runtime',
    'request_id': 'server-approval',
    'command': 'server command',
    'choices': ['once', 'deny'],
  },
};
Map<String, dynamic> serverQuestion() => {
  'id': 'server-question',
  'method': 'clarify',
  'params': {
    'session_id': 'runtime',
    'questions': [
      {'qid': 'first', 'question': 'First server question'},
      {'qid': 'second', 'question': 'Second server question'},
    ],
  },
};

void main() {
  late ChatRuntime runtime;
  setUp(() => runtime = ChatRuntime(runtimeId: 'runtime'));
  tearDown(() => runtime.dispose());

  test(
    'canonical snapshot restores native prompts alongside independent requests',
    () {
      runtime.installResume({
        'session_id': 'runtime',
        'running': true,
        'execution_generation': 4,
        'prompts': [approval('native', 4), question('native-question', 4)],
        'open_requests': [serverApproval(), serverQuestion()],
      });
      expect(
        runtime.observation.approvals.map(
          (a) => (a.requestId, a.nativeGeneration),
        ),
        [('native', 4), ('server-approval', null)],
      );
      expect(runtime.observation.questions!.nativeGeneration, 4);
      runtime.reconcileOpenRequests([serverApproval(), serverQuestion()]);
      expect(runtime.observation.pendingQuestion!.requestId, 'native-question');
      runtime.settleNativePrompt('clarify', 'native-question', 4);
      expect(runtime.observation.pendingQuestion!.requestId, 'server-question');
      expect(runtime.observation.questions!.nativeGeneration, isNull);
      expect(runtime.observation.questions!.pendingCount, 2);
    },
  );

  test(
    'native snapshot empties only native controls and server snapshot only server controls',
    () {
      runtime.receiveNativePrompt(approval('native', 2));
      runtime.receiveNativePrompt(question('native-question', 2));
      runtime.reconcileOpenRequests([serverApproval(), serverQuestion()]);
      runtime.reconcileNativePrompts([], 2);
      expect(
        runtime.observation.approvals.single.serverRequestId,
        'server-frame',
      );
      expect(runtime.observation.pendingQuestion!.requestId, 'server-question');
      runtime.receiveNativePrompt(question('new-question', 2));
      runtime.reconcileOpenRequests([]);
      expect(runtime.observation.approvals, isEmpty);
      expect(runtime.observation.pendingQuestion!.requestId, 'new-question');
    },
  );

  test(
    'native poll preserves server approvals and absent tuple cannot reopen',
    () {
      runtime.receiveNativePrompt(approval('native', 3));
      runtime.reconcileOpenRequests([serverApproval()]);
      expect(
        runtime.reconcileNativeApprovals(runtime.captureApprovalRead(), [], 3),
        isTrue,
      );
      expect(runtime.receiveNativePrompt(approval('native', 3)), isFalse);
      expect(runtime.observation.approvals.single.requestId, 'server-approval');
      expect(runtime.observation.approvals.single.nativeGeneration, isNull);
    },
  );

  test(
    'native polling binds generation and rejects superseded read or generation',
    () {
      final stale = runtime.captureApprovalRead();
      runtime.receiveNativePrompt(approval('first', 5));
      expect(runtime.reconcileNativeApprovals(stale, [], 5), isFalse);
      expect(
        runtime.reconcileNativeApprovals(runtime.captureApprovalRead(), [], 4),
        isFalse,
      );
      expect(
        runtime.reconcileNativeApprovals(runtime.captureApprovalRead(), [
          {
            'request_id': 'from-poll',
            'command': 'read',
            'choices': ['once', 'deny'],
          },
        ], 5),
        isTrue,
      );
      expect(runtime.observation.approval!.nativeGeneration, 5);
      expect(runtime.observation.approval!.requestId, 'from-poll');
    },
  );

  test(
    'same prompt identity in new generation retires old answers and history',
    () {
      final history = <String, HermesQuestion>{};
      runtime.onQuestion = (q) => history[q.id] = q;
      runtime.receiveNativePrompt(approval('reused', 1));
      final old = runtime.observation.approval!;
      final response = runtime.beginApprovalAnswer('reused', 'once');
      runtime.receiveNativePrompt(approval('reused', 2));
      expect(runtime.observation.approval!.nativeGeneration, 2);
      expect(
        identical(runtime.observation.approval!.correlation, old.correlation),
        isFalse,
      );
      expect(response.current, isFalse);
      runtime.finishApprovalAnswer(response, 'reused', accepted: true);
      expect(runtime.observation.approval!.nativeGeneration, 2);
      expect(
        history['native/2/approval/reused']!.status,
        HermesQuestionStatus.pending,
      );
      runtime.settleNativePrompt('approval', 'reused', 1);
      expect(runtime.observation.approval!.nativeGeneration, 2);
    },
  );

  test(
    'same clarification id in new generation has fresh response authority',
    () {
      runtime.receiveNativePrompt(question('reused', 1));
      final first = runtime.observation.questions!;
      final answer = runtime.beginQuestionAnswer(first)!;
      runtime.finishQuestionAnswer(answer, answer: 'Work', remaining: null);
      expect(runtime.observation.questions, isNull);
      runtime.receiveNativePrompt(question('reused', 2));
      expect(runtime.observation.questions!.nativeGeneration, 2);
      expect(
        identical(
          runtime.observation.questions!.correlation,
          first.correlation,
        ),
        isFalse,
      );
      runtime.finishQuestionAnswer(answer, answer: 'Home', remaining: null);
      runtime.settleNativePrompt('clarify', 'reused', 1);
      expect(runtime.observation.pendingQuestion!.requestId, 'reused');
    },
  );

  test(
    'multiple native clarifications remain FIFO and reveal the server batch',
    () {
      runtime.reconcileOpenRequests([serverQuestion()]);
      runtime.reconcileNativePrompts([
        question('first-native', 2),
        question('second-native', 2),
      ], 2);
      expect(runtime.observation.pendingQuestion!.requestId, 'first-native');
      final capture = runtime.beginQuestionAnswer(
        runtime.observation.questions,
      )!;
      runtime.finishQuestionAnswer(capture, answer: 'Work', remaining: null);
      expect(runtime.observation.pendingQuestion!.requestId, 'second-native');
      runtime.settleNativePrompt('clarify', 'second-native', 2);
      expect(runtime.observation.pendingQuestion!.requestId, 'server-question');
      expect(runtime.observation.questions!.pendingCount, 2);
    },
  );

  test(
    'runtime replacement clears every prompt lane and retires outstanding read',
    () {
      runtime.receiveNativePrompt(approval('native', 2));
      runtime.reconcileNativePrompts([
        approval('native', 2),
        question('one', 2),
        question('two', 2),
      ], 2);
      runtime.reconcileOpenRequests([serverApproval(), serverQuestion()]);
      final read = runtime.captureApprovalRead();
      runtime.replaceRuntime('replacement');
      expect(runtime.observation.approvals, isEmpty);
      expect(runtime.observation.questions, isNull);
      expect(runtime.reconcileNativeApprovals(read, [], 2), isFalse);
    },
  );
  test(
    'native polling cannot replace a live server reply owner for the same request',
    () {
      final history = <String, HermesQuestion>{};
      runtime.onQuestion = (q) => history[q.id] = q;
      runtime.receiveNativePrompt(approval('server-approval', 0));
      runtime.reconcileOpenRequests([serverApproval()]);
      expect(
        history.values.where(
          (q) => q.requestId == 'server-approval' && q.status.isPending,
        ),
        isEmpty,
      );
      expect(
        history.values.where((q) => q.status.isPending).single.requestId,
        'server-frame',
      );
      final original = runtime.observation.approval!;
      runtime.reconcileNativeApprovals(runtime.captureApprovalRead(), [
        {
          'request_id': 'server-approval',
          'command': 'server command',
          'choices': ['once', 'deny'],
        },
      ], 0);
      expect(runtime.observation.approval!.serverRequestId, 'server-frame');
      expect(runtime.observation.approval!.nativeGeneration, isNull);
      expect(
        identical(
          runtime.observation.approval!.correlation,
          original.correlation,
        ),
        isTrue,
      );
      runtime.receiveNativePrompt(approval('server-approval', 0));
      expect(runtime.observation.approval!.serverRequestId, 'server-frame');
      runtime.settleNativePrompt('approval', 'server-approval', 0);
      expect(runtime.observation.approval!.serverRequestId, 'server-frame');
    },
  );
  test(
    'settled event before native answer ACK confirms only captured history',
    () {
      final history = <String, HermesQuestion>{};
      runtime.onQuestion = (q) => history[q.id] = q;
      runtime.reconcileNativePrompts([
        question('first', 2),
        question('next', 2),
      ], 2);
      final capture = runtime.beginQuestionAnswer(
        runtime.observation.questions,
      )!;
      runtime.settleNativePrompt('clarify', 'first', 2);
      expect(runtime.observation.pendingQuestion!.requestId, 'next');
      runtime.finishQuestionAnswer(capture, answer: 'Work', remaining: null);
      expect(
        history['native/2/clarify/first/']!.status,
        HermesQuestionStatus.answered,
      );
      expect(runtime.observation.pendingQuestion!.requestId, 'next');
    },
  );
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wing/core/models/answer_versions.dart';
import 'package:wing/core/models/chat_runtime.dart';

import '../test/helpers/journey_controls.dart';
import 'hermes_next_conversation_prod_test.dart'
    show
        ownedProductionJourney,
        productionWorkspace,
        sendProductionText,
        showProductionWorkspace,
        waitForProductionState;
import 'support/journey_capture.dart';

const _nonce = String.fromEnvironment('WING_QA_NONCE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testJourney('Production N13 stages and confirms a real clarification batch', (
    tester,
  ) async {
    final owner = await productionWorkspace('wing-prod-clarification-$_nonce');
    await showProductionWorkspace(tester, owner);
    await ownedProductionJourney(
      tester,
      owner,
      'clarification',
      'Wing batch clarification QA $_nonce',
      (chat, checkpoint) async {
        final marker = 'WING_BATCH_$_nonce';
        await sendProductionText(
          tester,
          'Isolated Wing acceptance $_nonce. I need to choose two independent '
          'preferences. Call the clarify tool exactly once with a questions '
          'array containing these two questions: '
          '1. Which color? choices [Blue, Green]. '
          '2. Which length? choices [Brief, Detailed]. '
          'Use single-selection for each. Wait for my two answers, then reply '
          'with $marker followed by the exact color and length I selected. '
          'Do not answer these decisions yourself, ask in plain text, call '
          'other tools, delegate, browse, or read/change files.',
        );
        await waitForProductionState(
          tester,
          () =>
              chat.runtime.questions != null ||
              (!chat.runtime.blocksTurnAdmission &&
                  chat.runtime.execution == ChatExecution.completed),
          'Provider requests the real clarification form',
        );
        final batch = chat.runtime.questions;
        expect(
          batch,
          isNotNull,
          reason: 'Plain text is not batch clarification',
        );
        expect(batch!.questions, hasLength(2));
        expect(batch.pendingCount, 2);
        expect(batch.answeredIds, isEmpty);
        expect(batch.questions.map((q) => q.requestId).toSet(), hasLength(1));
        expect(batch.questions.map((q) => q.questionId).toSet(), hasLength(2));
        expect(batch.questions.every((q) => q.questionId != null), isTrue);
        final selected = <String>[];
        for (final question in batch.questions) {
          expect(question.multiSelect, isFalse);
          final answer = question.choices.indexWhere(
            (choice) => choice.startsWith('Blue') || choice.startsWith('Brief'),
          );
          expect(answer, greaterThanOrEqualTo(0));
          selected.add(question.choices[answer]);
          await tapJourneyControl(
            tester,
            find.byKey(Key('clarify-${question.questionId}-choice-$answer')),
          );
          await tester.pump();
          expect(
            chat.runtime.questions!.answeredIds,
            isEmpty,
            reason: 'Selecting an answer only stages it',
          );
        }
        expect(selected.any((answer) => answer.startsWith('Blue')), isTrue);
        expect(selected.any((answer) => answer.startsWith('Brief')), isTrue);
        const draft = 'Keep this unrelated clarification draft';
        final composer = find.byKey(const Key('profile-message-composer'));
        await tapJourneyControl(tester, composer);
        await tester.enterText(composer, draft);
        await tester.pump();
        expect(chat.composer.observation.text, draft);
        final confirm = find.byKey(const Key('clarify-continue'));
        await revealJourneyControl(tester, confirm);
        await captureJourney(tester, 'prod-n13-batch-staged');
        await tapJourneyControl(tester, confirm);
        await waitForProductionState(
          tester,
          () =>
              chat.runtime.pendingQuestion == null &&
              !chat.runtime.blocksTurnAdmission &&
              chat.runtime.execution == ChatExecution.completed &&
              chat.reading.messages.any(
                (row) =>
                    row['role'] == 'assistant' &&
                    answerMessageText(row).contains(marker) &&
                    answerMessageText(row).contains('Blue') &&
                    answerMessageText(row).contains('Brief'),
              ),
          'Both confirmed answers reach the actual provider reply',
        );
        expect(chat.runtime.error, isNull);
        expect(chat.composer.observation.text, draft);
        expect(find.byKey(const Key('clarify-error')), findsNothing);
        await checkpoint();
        final history = await owner.current!.gateway.history(
          chat.key.sessionId,
        );
        expect(
          history.rows.any(
            (row) =>
                row['role'] == 'assistant' &&
                answerMessageText(row).contains(marker) &&
                answerMessageText(row).contains('Blue') &&
                answerMessageText(row).contains('Brief'),
          ),
          isTrue,
        );
        await captureJourney(tester, 'prod-n13-batch-completed-draft-retained');
      },
    );
  });

  testJourney('Production N15 resets an owned session to its profile model', (
    tester,
  ) async {
    final owner = await productionWorkspace('wing-prod-model-reset-$_nonce');
    await showProductionWorkspace(tester, owner);
    await ownedProductionJourney(
      tester,
      owner,
      'model-reset',
      'Wing profile model reset QA $_nonce',
      (chat, checkpoint) async {
        final gateway = owner.current!.gateway;
        final marker = 'WING_RESET_$_nonce';
        await sendProductionText(
          tester,
          'Isolated Wing acceptance $_nonce. Reply exactly $marker. '
          'Do not call tools, delegate, browse, or read/change files.',
        );
        await waitForProductionState(
          tester,
          () =>
              !chat.runtime.blocksTurnAdmission &&
              chat.runtime.execution == ChatExecution.completed &&
              chat.reading.messages.any(
                (row) =>
                    row['role'] == 'assistant' &&
                    answerMessageText(row).contains(marker),
              ),
          'Owned conversation has a saved real reply before reset',
        );
        await checkpoint();
        final defaults = await gateway.read('model/info');
        final model = defaults['model'];
        final provider = defaults['provider'];
        expect(
          model,
          isA<String>().having((value) => value.isNotEmpty, 'configured', true),
        );
        expect(provider, isA<String>());
        final catalog = await gateway.modelCatalog.load();
        final alternative = catalog.choices
            .where(
              (choice) => choice.provider == provider && choice.model != model,
            )
            .firstOrNull;
        expect(
          alternative,
          isNotNull,
          reason:
              'A distinct advertised model on the same provider is '
              'required to distinguish reset from a stock no-op',
        );
        // Seed only this QA conversation. The alternate model receives no
        // inference; the UI must resolve back to the unchanged profile default.
        final seeded = await gateway.mutateSession(
          chat.runtime.runtimeId,
          'model',
          {'model': alternative!.model, 'provider': alternative.provider},
        );
        expect(seeded['status'], isNot('confirmation_required'));
        expect(seeded['status'], isNot('deferred'));
        final before = await gateway.resume(chat.runtime.runtimeId);
        expect((before['info'] as Map)['model'], alternative.model);
        final beforeHistory = await gateway.history(chat.key.sessionId);
        final revision = gateway.canonical
            .session(chat.runtime.runtimeId)!
            .revision;
        final reasoning = (await gateway.call('config.get', {
          'session_id': chat.runtime.runtimeId,
          'key': 'reasoning',
        }))['value'];
        final fast = (await gateway.call('config.get', {
          'session_id': chat.runtime.runtimeId,
          'key': 'fast',
        }))['value'];
        const draft = 'Keep this unsent model-reset draft';
        final composer = find.byKey(const Key('profile-message-composer'));
        await tapJourneyControl(tester, composer);
        await tester.enterText(composer, draft);
        await tester.pump();
        await tapJourneyControl(
          tester,
          find.byKey(const Key('chat-intelligence-button')),
        );
        await tapJourneyControl(tester, find.byTooltip('More model options'));
        await revealJourneyControl(tester, find.text('Use profile default'));
        await captureJourney(tester, 'prod-n15-profile-default-menu');
        await tapJourneyControl(tester, find.text('Use profile default'));
        await waitForProductionState(
          tester,
          () =>
              !chat.changingIntelligence &&
              gateway.canonical.session(chat.runtime.runtimeId)!.revision >
                  revision &&
              find.byTooltip('More model options').evaluate().isEmpty,
          'Real reset commits and closes its model picker',
        );
        expect(chat.runtime.error, isNull);
        final resolved = await gateway.resume(chat.runtime.runtimeId);
        final info = resolved['info'] as Map;
        expect(info['model'], model);
        expect(chat.model, info['model']);
        expect(chat.model, isNot('reset'));
        expect(chat.composer.observation.text, draft);
        expect(
          jsonEncode((await gateway.history(chat.key.sessionId)).rows),
          jsonEncode(beforeHistory.rows),
        );
        final defaultsAfter = await gateway.read('model/info');
        expect(defaultsAfter['model'], model);
        expect(defaultsAfter['provider'], provider);
        for (final entry in {'reasoning': reasoning, 'fast': fast}.entries) {
          expect(
            (await gateway.call('config.get', {
              'session_id': chat.runtime.runtimeId,
              'key': entry.key,
            }))['value'],
            entry.value,
          );
        }
        await checkpoint();
        await captureJourney(tester, 'prod-n15-reset-resolved-draft-retained');
      },
    );
  });
}

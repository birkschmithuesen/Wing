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
const _profile = String.fromEnvironment('WING_QA_PROFILE');
const _pinnedMaximum = 65536;

/// The driver creates this exact blank profile with a configured context pin.
/// The shared journey records and deletes only its newly created QA chat before
/// the driver verifies that cleanup and deletes the owned profile.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testJourney(
    'Production N16 shows a configured context pin after a real reply',
    (tester) async {
      expect(_profile, _nonce);
      expect(_profile, isNot('default'));
      final owner = await productionWorkspace(
        'wing-prod-context-$_nonce',
        profile: _profile,
      );
      expect(owner.current!.scope.profileName, _profile);
      final gateway = owner.current!.gateway;
      final configured = await gateway.read('model/info');
      expect(configured['config_context_length'], _pinnedMaximum);
      expect(configured['effective_context_length'], _pinnedMaximum);
      await showProductionWorkspace(tester, owner);
      await ownedProductionJourney(
        tester,
        owner,
        'context',
        'Wing configured context QA $_nonce',
        (chat, checkpoint) async {
          expect(chat.key.workspace.profileName, _profile);
          final marker = 'WING_CONTEXT_$_nonce';
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
            'The configured QA profile completes a real provider reply',
          );
          expect(chat.runtime.error, isNull);
          await checkpoint();
          final stats = await gateway.call('session.stats', {
            'session_id': chat.runtime.runtimeId,
          });
          expect(stats['config_context_length'], _pinnedMaximum);
          expect(stats['context_length'], _pinnedMaximum);
          expect(stats['context_tokens'], greaterThan(0));
          await owner.refreshContext(chat);
          expect(chat.contextError, isNull);
          expect(chat.context, isNotNull);
          expect(chat.context!.configuredMax, _pinnedMaximum);
          expect(chat.context!.max, _pinnedMaximum);
          expect(chat.context!.pinned, isTrue);
          expect(chat.context!.used, greaterThan(0));
          await tester.pump();
          await tapJourneyControl(
            tester,
            find.byKey(const ValueKey('context-ring-details')),
          );
          await waitForProductionState(
            tester,
            () =>
                !chat.contextLoading &&
                find.textContaining('65,536 (pinned)').evaluate().isNotEmpty,
            'Actual context-ring detail displays the server-confirmed pin',
          );
          expect(chat.contextError, isNull);
          expect(find.textContaining('65,536 (pinned)'), findsOneWidget);
          await revealJourneyControl(
            tester,
            find.textContaining('65,536 (pinned)'),
          );
          await captureJourney(tester, 'prod-n16-configured-context-pinned');
          await tapJourneyControl(
            tester,
            find.byTooltip('Close context window'),
          );
          await checkpoint();
        },
      );
    },
  );
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wing/core/widgets/tool_activity_details.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/widgets/profile_execution_activity.dart';
import 'package:wing/core/widgets/profile_live_execution.dart';
import 'package:wing/core/widgets/profile_tool_call.dart';

import '../test/helpers/pump_markdown_widget.dart';

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

/// Explicit production opt-in through test_existing_hermes_next.py. Only the
/// newly created chat may submit prompts or stop processes. Both commands are
/// bounded, print-only jobs; existing chats and server settings are untouched.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  WidgetController.hitTestWarningShouldBeFatal = true;

  testJourney(
    'production Android discovers follows and stops background processes',
    (tester) async {
      final owner = await productionWorkspace('wing-prod-processes-$_nonce');
      await showProductionWorkspace(tester, owner);
      await waitForProductionState(
        tester,
        () {
          final button = find.byKey(const ValueKey('workspace-new-chat'));
          return button.evaluate().length == 1 &&
              tester.widget<FloatingActionButton>(button).onPressed != null;
        },
        'Browser finishes loading and enables New chat',
        seconds: 30,
      );
      await tester.pump(const Duration(milliseconds: 400));
      await ownedProductionJourney(
        tester,
        owner,
        'processes',
        'Wing background process QA $_nonce',
        (chat, checkpoint) async {
          final gateway = owner.current!.gateway;
          expect(chat.processes, isEmpty);
          Finder tab(int id, {bool open = false}) =>
              find.byKey(ValueKey(('live-work-tab', id, open)));
          expect(tab(2), findsNothing);
          final command =
              'python3 -u -c "import time; '
              "[(print('$_nonce-LONG', i, flush=True), time.sleep(2)) "
              'for i in range(90)]"';
          final shortCommand =
              'python3 -u -c "import time; '
              "[(print('$_nonce-SHORT', i, flush=True), time.sleep(1)) "
              'for i in range(25)]"';
          try {
            await sendProductionText(
              tester,
              'This is an authorized isolated Wing UI verification $_nonce. '
              'Use todo to create one in_progress item: Observe QA processes. '
              'Then invoke terminal exactly twice, each with background=true: '
              'first `$command`, then `$shortCommand`. These print-only jobs '
              'are intentionally bounded and do not access files or network. '
              'After both launch, delegate exactly one child with the goal: '
              'Run python3 -c "import time; time.sleep(45); print(123)" once '
              'in the foreground, then reply QA_CHILD_DONE. '
              'Leave the todo in_progress. Do not poll, kill or wait for either '
              'parent background process; the tester will stop it in Wing. '
              'Do not launch anything else or change settings or files.',
            );
            await waitForProductionState(
              tester,
              () => chat.processes.any(
                (p) => p.command.contains('$_nonce-LONG') && p.isRunning,
              ),
              'Tool completion discovers a running process without manual refresh',
            );
            await checkpoint();
            expect(tab(2), findsOneWidget);
            final draft = find.byKey(const Key('profile-message-composer'));
            await tapJourneyControl(tester, draft);
            await tester.enterText(draft, 'Retain my unsent process QA draft');
            await tester.pump(const Duration(milliseconds: 500));
            final keyboard = tester.view.viewInsets.bottom;
            expect(keyboard, greaterThan(0), reason: 'Real Android keyboard');
            await tapJourneyControl(tester, tab(2));
            await tester.pump(const Duration(milliseconds: 400));
            expect(
              find.byKey(const ValueKey('live-work-panel')),
              findsOneWidget,
            );
            await captureJourney(tester, 'prod-process-keyboard');
            // Close the drawer, then ask the native input channel to hide IME.
            // Flutter's handlePopRoute bypasses Android's IME Back handling.
            await tapJourneyControl(tester, tab(2, open: true));
            await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
            await waitForProductionState(
              tester,
              () => tester.view.viewInsets.bottom == 0,
              'Native keyboard finishes hiding before measuring composer',
              seconds: 15,
            );
            await tester.pump(const Duration(milliseconds: 400));
            final composerRect = tester.getRect(draft);
            await tapJourneyControl(tester, tab(2));
            await tester.pump(const Duration(milliseconds: 400));
            expect(tester.getRect(draft), composerRect);
            final longId = chat.processes
                .firstWhere((p) => p.command.contains('$_nonce-LONG'))
                .id;
            final before = chat.processes
                .firstWhere((p) => p.id == longId)
                .outputTail;
            final rowTitle = chat.processes
                .firstWhere((p) => p.id == longId)
                .command;
            await tapJourneyControl(tester, find.text(rowTitle));
            await tapJourneyControl(
              tester,
              find.byKey(const ValueKey('live-work-handle')),
            );
            await waitForProductionState(
              tester,
              () => chat.processes.any(
                (p) => p.id == longId && p.outputTail != before,
              ),
              'Output changes automatically with the drawer open',
              seconds: 20,
            );
            expect(
              tester
                  .widgetList<ActivityDetailSection>(
                    find.byType(ActivityDetailSection),
                  )
                  .any(
                    (section) =>
                        section.block.label == 'Recent output' &&
                        section.block.text.contains('$_nonce-LONG'),
                  ),
              isTrue,
              reason: 'Live output reaches the production detail renderer',
            );
            await captureJourney(tester, 'prod-process-live-output');
            await waitForProductionState(
              tester,
              () =>
                  chat.currentSubagents.isNotEmpty &&
                  chat.currentTodos.isNotEmpty,
              'Real Subagents and Tasks coexist with Background',
              seconds: 90,
            );
            expect(tab(0, open: true), findsOneWidget);
            expect(tab(1, open: true), findsOneWidget);
            expect(tab(2, open: true), findsOneWidget);
            await captureJourney(tester, 'prod-process-three-tabs');
            await waitForProductionState(
              tester,
              () => chat.processes.any(
                (p) => p.command.contains('$_nonce-SHORT') && !p.isRunning,
              ),
              'Natural process completion appears through the watch',
              seconds: 60,
            );
            final short = chat.processes.firstWhere(
              (p) => p.command.contains('$_nonce-SHORT'),
            );
            expect(short.exitCode, 0);
            await tapJourneyControl(tester, find.byTooltip('Stop process'));
            await waitForProductionState(
              tester,
              () => chat.processes.any((p) => p.id == longId && !p.isRunning),
              'Stop acknowledges and refreshes the exact running process',
              seconds: 30,
            );
            final registry = await gateway.call('process.list', {
              'session_id': chat.runtime.runtimeId,
            });
            expect(
              (registry['processes'] as List).cast<Map>().any(
                (p) => p['session_id'] == longId && p['status'] == 'running',
              ),
              isFalse,
              reason: 'Independent backend read confirms the stop',
            );
            await captureJourney(tester, 'prod-process-stopped');
            await waitForProductionState(
              tester,
              () => !chat.runtime.executionActive,
              'The parent response settles after its child finishes',
              seconds: 90,
            );
            expect(chat.currentProcesses, isEmpty);
            expect(tab(2), findsNothing);
            expect(tab(2, open: true), findsNothing);
            expect(
              chat.composer.observation.text,
              'Retain my unsent process QA draft',
            );
            await captureJourney(tester, 'prod-process-retired');
            debugPrint(
              'WING_PROD_PROCESSES ${jsonEncode({'discovered': true, 'automatic_output': true, 'three_categories': true, 'natural_exit': true, 'stop_readback': true, 'retired_after_response': true, 'keyboard': true, 'draft_retained': true})}',
            );
          } finally {
            // Fresh authoritative rows identify only jobs created in this exact
            // test chat. Never use the registry-wide process.stop endpoint.
            await owner.refreshProcesses(chat);
            for (final process
                in chat.processes.where((p) => p.isRunning).toList()) {
              expect(process.command.contains(_nonce), isTrue);
              await owner.stopProcess(
                chat,
                process.id,
                canDispatch: () => true,
              );
            }
          }
        },
      );
    },
  );
  testJourney('production Android compact activity preserves streamed order and details', (
    tester,
  ) async {
    final owner = await productionWorkspace('wing-prod-compact-$_nonce');
    await showProductionWorkspace(tester, owner);
    await ownedProductionJourney(
      tester,
      owner,
      'compact',
      'Wing compact activity QA $_nonce',
      (chat, checkpoint) async {
        await sendProductionText(
          tester,
          'This is an authorized isolated UI test $_nonce. Use terminal exactly three times, sequentially. '
          'For each call use this command, replacing STEP with FIRST then SECOND then THIRD: '
          'python3 -u -c "import time; print(\'$_nonce-STEP-start\', flush=True); time.sleep(15); print(\'$_nonce-STEP-done\', flush=True)". '
          'Keep all three calls foreground. Give a short progress summary before each call. '
          'Do not access files or network, delegate, or change settings. After all three finish reply COMPACT_QA_DONE.',
        );
        List<ChatToolEntry> tools() =>
            chat.runtime.activityEntries.whereType<ChatToolEntry>().toList();
        List<ChatReasoningEntry> reasoning() => chat.runtime.activityEntries
            .whereType<ChatReasoningEntry>()
            .where((r) => r.text.trim().isNotEmpty)
            .toList();
        await waitForProductionState(
          tester,
          () => tools().isNotEmpty && reasoning().isNotEmpty,
          'Real provider supplies readable reasoning and a live tool',
        );
        await checkpoint();
        expect(find.byType(ProfileLiveExecution), findsOneWidget);
        expect(find.byType(ProfileReasoningDisclosure), findsNothing);
        final latestHeading = reasoningHeading(reasoning().last.text);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('live-activity-toggle')),
            matching: find.text(latestHeading),
          ),
          findsOneWidget,
        );
        await captureJourney(tester, 'prod-compact-collapsed');
        final draft = find.byKey(const Key('profile-message-composer'));
        await tapJourneyControl(tester, draft);
        await tester.enterText(draft, 'Keep this unsent compact QA draft');
        await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        await waitForProductionState(
          tester,
          () => tester.view.viewInsets.bottom == 0,
          'Native keyboard closes before inspecting activity',
          seconds: 15,
        );
        await tester.openLiveActivity();
        final firstId = tools().first.activity.toolId;
        Finder firstCall() => find.byWidgetPredicate(
          (w) => w is ProfileToolCall && w.call.callId == firstId,
        );
        final firstHeader = find
            .descendant(of: firstCall(), matching: find.byType(ListTile))
            .first;
        await tapJourneyControl(tester, firstHeader);
        await tester.pump(const Duration(milliseconds: 300));
        final retained = tester.element(firstCall());
        await captureJourney(tester, 'prod-compact-expanded-first');
        await waitForProductionState(
          tester,
          () => tools().length >= 2 && reasoning().length >= 2,
          'Second real tool follows a later reasoning block',
        );
        expect(tester.element(firstCall()), same(retained));
        expect(
          find.descendant(
            of: firstCall(),
            matching: find.byType(ActivityDetailsCard),
          ),
          findsWidgets,
        );
        await tester.openLiveActivity();
        final visibleReasoning = tester.widgetList<ProfileReasoningDisclosure>(
          find.byType(ProfileReasoningDisclosure),
        );
        expect(
          visibleReasoning.map((r) => r.text),
          reasoning().reversed.map((r) => r.text),
        );
        final visibleTools = tester.widgetList<ProfileToolCall>(
          find.byType(ProfileToolCall),
        );
        expect(
          visibleTools.map((w) => w.call.callId),
          tools().reversed.map((e) => e.activity.toolId),
        );
        final outer = find.byKey(const ValueKey('live-activity-toggle'));
        expect(
          find.descendant(of: outer, matching: find.text('Reasoning')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: outer,
            matching: find.text(reasoningHeading(reasoning().last.text)),
          ),
          findsNothing,
        );
        await captureJourney(tester, 'prod-compact-newest-first');
        await waitForProductionState(
          tester,
          () => tools().length >= 3,
          'Third tool arrives while earlier details remain open',
        );
        expect(tester.element(firstCall()), same(retained));
        expect(
          chat.composer.observation.text,
          'Keep this unsent compact QA draft',
        );
        await captureJourney(tester, 'prod-compact-retained-details');
        await waitForProductionState(
          tester,
          () => !chat.runtime.executionActive,
          'Real response finishes',
          seconds: 120,
        );
        await owner.refreshHistory(chat);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.settleMarkdown();
        expect(
          chat.reading.messages.any(
            (row) =>
                row['role'] == 'assistant' &&
                '${row['content']}'.contains('COMPACT_QA_DONE'),
          ),
          isTrue,
        );
        expect(
          chat.composer.observation.text,
          'Keep this unsent compact QA draft',
        );
        expect(
          find.byType(ProfileToolCall),
          findsNothing,
          reason: 'Completed activity folds',
        );
        await captureJourney(tester, 'prod-compact-completed');
        await owner.reconnect(owner.current!.scope);
        await tester.pump(const Duration(milliseconds: 400));
        await waitForProductionState(
          tester,
          () => !chat.runtime.reconnecting && !chat.runtime.opening,
          'Real gateway reconnect settles',
        );
        await owner.refreshHistory(chat);
        expect(
          chat.reading.messages.any(
            (row) =>
                row['role'] == 'assistant' &&
                '${row['content']}'.contains('COMPACT_QA_DONE'),
          ),
          isTrue,
        );
        expect(
          chat.composer.observation.text,
          'Keep this unsent compact QA draft',
        );
        await captureJourney(tester, 'prod-compact-reconnected');

        debugPrint(
          'WING_PROD_COMPACT ${jsonEncode({'real_reasoning': true, 'newest_first': true, 'unique_header': true, 'retained_details': true, 'draft_retained': true, 'saved_answer': true, 'reconnected': true})}',
        );
      },
    );
  });
}

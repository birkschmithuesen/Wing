import 'dart:async';
import '../test/helpers/journey_controls.dart';
import '../test/helpers/pump_markdown_widget.dart';
import 'package:wing/core/widgets/turn_failure_view.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/widgets/profile_goal_panel.dart';
import 'package:wing/core/widgets/profile_activity_tabs.dart';
import 'package:wing/core/widgets/profile_live_execution.dart';
import 'package:wing/core/widgets/gateway_approval_panel.dart';
import 'package:wing/core/widgets/source_code_text.dart';
import '../test/support/composer_fixture.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wing/core/models/answer_versions.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/administration/administration_content.dart';
import 'package:wing/core/screens/analytics_content.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/screens/profile_transcript.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_connection_identity.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_workspace_registry.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/services/versions_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import 'package:wing/core/widgets/composer_action_button.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/main.dart';

import '../test/support/administration_fixture.dart';
import 'support/journey_capture.dart';
import 'support/roadmap_emulator_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  late _RoadmapHarness harness;

  setUp(() async {
    PackageInfo.setMockInitialValues(
      appName: 'Wing',
      packageName: 'com.tarkilhk.wing',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    SharedPreferences.setMockInitialValues({'theme_mode': journeyTheme});
    harness = await _RoadmapHarness.create();
  });

  tearDown(() => harness.dispose());

  testJourney(
    'Git review opens from chat and retains draft through held reads',
    (tester) async {
      await harness.launch(tester);
      await tapJourneyControl(
        tester,
        find.byKey(const ValueKey('chat-personal-chat-0')),
      );
      await _settle(tester);
      final chat = harness.controller.current!.chat!;
      for (final theme in [AppThemePreference.light, AppThemePreference.dark]) {
        await harness.appPreferences.setTheme(theme);
        await harness.appPreferences.setTextSize(
          AppTextSizePreference.extraLarge,
        );
        await tester.enterText(
          find.byKey(const Key('profile-message-composer')),
          'Review without losing this draft',
        );
        tester.binding.focusManager.primaryFocus?.unfocus();
        final held = Completer<void>();
        harness.fixture.gitReview.listGate = held;
        await tapJourneyControl(tester, find.byTooltip('Chat actions'));
        await _settle(tester);
        await tapJourneyControl(tester, find.text('Git review'));
        await _settle(tester);
        expect(find.text('Git review'), findsOneWidget);
        expect(find.byType(StudioLoadingSlot), findsWidgets);
        expect(find.byType(StudioLoading), findsOneWidget);
        await captureJourney(tester, 'git-held-${theme.name}');
        held.complete();
        await _pumpUntil(
          tester,
          () => find.text('lib/phone.dart').evaluate().isNotEmpty,
        );
        await tester.ensureVisible(find.text('lib/phone.dart'));
        await tapJourneyControl(tester, find.text('lib/phone.dart'));
        await _pumpUntil(
          tester,
          () => find.byTooltip('Copy hunk reference').evaluate().isNotEmpty,
        );
        expect(find.text('Working tree compared with HEAD'), findsOneWidget);
        await captureJourney(tester, 'git-diff-${theme.name}');
        await tester.ensureVisible(find.text('Staged'));
        await tapJourneyControl(tester, find.text('Staged'));
        await _settle(tester);
        expect(find.text('Index compared with HEAD'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byTooltip('Copy hunk reference'),
          160,
          scrollable: find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tapJourneyControl(tester, find.byTooltip('Copy hunk reference'));
        await _settle(tester);
        expect(find.text('Reference copied'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await _settle(tester);
        await tester.binding.handlePopRoute();
        await _settle(tester);
        expect(
          chat.composer.observation.text,
          'Review without losing this draft',
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testJourney(
    'live tool progress and plan recovery use the production conversation',
    (tester) async {
      await harness.launch(tester);
      await tapJourneyControl(
        tester,
        find.byKey(const ValueKey('chat-personal-chat-0')),
      );
      await _settle(tester);
      final chat = harness.controller.current!.chat!;
      for (final theme in [AppThemePreference.light, AppThemePreference.dark]) {
        await harness.appPreferences.setTheme(theme);
        for (final size in [
          AppTextSizePreference.standard,
          AppTextSizePreference.extraLarge,
        ]) {
          await harness.appPreferences.setTextSize(size);
          await _settle(tester);
          await tester.enterText(
            find.byKey(const Key('profile-message-composer')),
            'Keep this recovery draft',
          );
          tester.binding.focusManager.primaryFocus?.unfocus();
          emitChatEvent(harness.controller, chat, 'message.start');
          emitChatEvent(harness.controller, chat, 'session.usage', {
            'usage': {
              'plan_gauge': {
                'id': 'daily',
                'label': 'Daily',
                'used_bp': 4200,
                'resets_at_ms': 1893456000000,
              },
            },
          });
          await _settle(tester);
          expect(find.text('Daily · 42% used'), findsOneWidget);
          await captureJourney(
            tester,
            'upstream-gauge-${theme.name}-${size.name}',
          );
          emitChatEvent(harness.controller, chat, 'tool.start', {
            'tool_id': 'progress-${theme.name}-${size.name}',
            'name': 'mcp_search',
            'args': {'query': 'project files'},
          });
          emitChatEvent(harness.controller, chat, 'tool.progress', {
            'tool_id': 'progress-${theme.name}-${size.name}',
            'name': 'mcp_search',
            'progress': 4,
            'total': 10,
            'percent': 40,
            'message': 'Indexed project files',
          });
          await _settle(tester);
          await tester.openLiveActivity();
          await _settle(tester);
          expect(find.text('40% · Indexed project files'), findsOneWidget);
          await captureJourney(
            tester,
            'upstream-progress-${theme.name}-${size.name}',
          );
          emitChatEvent(harness.controller, chat, 'tool.complete', {
            'tool_id': 'progress-${theme.name}-${size.name}',
            'name': 'mcp_search',
            'result': 'Four folders indexed',
          });
          await _settle(tester);
          expect(find.text('40% · Indexed project files'), findsNothing);
          emitChatEvent(harness.controller, chat, 'message.complete', {
            'status': 'error',
            'error': 'The provider reported its daily allowance is exhausted.',
            'error_surface': {
              'layer': 'billing',
              'code': 'usage_limit',
              'retryable': false,
              'provider': 'nous',
              'model': 'large-demo',
              'usage_limit': {
                'limit_name': 'Daily',
                'scope': 'all',
                'message': 'Daily allowance exhausted',
                'resets_at_ms': 1893456000000,
                'suggestions': [
                  {
                    'provider': 'nous',
                    'model': 'free-demo',
                    'label': 'Free demo',
                    'note': 'free',
                  },
                ],
              },
            },
          });
          await _pumpUntil(
            tester,
            () => find.byType(TurnFailureView).evaluate().isNotEmpty,
          );
          await tester.ensureVisible(find.byType(TurnFailureView));
          await _settle(tester);
          expect(find.text('Plan allowance reached'), findsOneWidget);
          expect(find.text('Daily allowance exhausted'), findsOneWidget);
          await captureJourney(
            tester,
            'upstream-limit-${theme.name}-${size.name}',
          );
          final choose = find.descendant(
            of: find.byType(TurnFailureView),
            matching: find.byTooltip('Choose model'),
          );
          await tester.ensureVisible(choose);
          await tapJourneyControl(tester, choose);
          final modelSearch = find.byKey(const Key('model-search'));
          await _pumpUntil(
            tester,
            () => modelSearch.hitTestable().evaluate().isNotEmpty,
          );
          // Search through the real control to leave the effective model's
          // provider filter and find the plan-backed model from another provider.
          await tester.enterText(modelSearch, 'large-demo');
          tester.binding.focusManager.primaryFocus?.unfocus();
          final info = find.byTooltip('About large-demo');
          await _pumpUntil(tester, () => info.evaluate().isNotEmpty);
          await tester.ensureVisible(info);
          await _pumpUntil(
            tester,
            () => info.hitTestable().evaluate().isNotEmpty,
          );
          await tapJourneyControl(tester, info);
          await _settle(tester);
          expect(find.text('Fixture plan'), findsOneWidget);
          expect(find.text('0% left'), findsOneWidget);
          expect(find.text('Stops at the limit'), findsOneWidget);
          await captureJourney(
            tester,
            'upstream-allowance-${theme.name}-${size.name}',
          );
          await tapJourneyControl(tester, find.byTooltip('Close model card'));
          await _settle(tester);
          await tester.binding.handlePopRoute();
          await _settle(tester);
          expect(chat.composer.observation.text, 'Keep this recovery draft');
          expect(tester.takeException(), isNull);
        }
      }
    },
  );

  testJourney(
    'native clarification answers from the composer with its captured generation',
    (tester) async {
      await harness.launch(tester);
      await harness.appPreferences.setTextSize(
        AppTextSizePreference.extraLarge,
      );
      await tapJourneyControl(
        tester,
        find.byKey(const ValueKey('chat-personal-chat-0')),
      );
      await _settle(tester);
      final chat = harness.controller.current!.chat!;
      emitChatEvent(harness.controller, chat, 'clarify.request', {
        'kind': 'clarify',
        'prompt_id': 'native-question',
        'execution_generation': 0,
        'question': 'Which result should I prepare?',
        'choices': ['Summary', 'Details'],
      });
      await _settle(tester);
      await tester.enterText(
        find.byKey(const Key('profile-message-composer')),
        'Summary',
      );
      tester.binding.focusManager.primaryFocus?.unfocus();
      await _settle(tester);
      final answer = find.byWidgetPredicate(
        (widget) =>
            widget is IconButton &&
            widget.tooltip == 'Answer with composer text',
      );
      await tester.ensureVisible(answer);
      await _pumpUntil(
        tester,
        () =>
            answer.hitTestable().evaluate().isNotEmpty &&
            tester.widget<IconButton>(answer).onPressed != null,
      );
      final gate = harness.fixture.clarificationGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await tapJourneyControl(tester, answer);
      await _pumpUntil(
        tester,
        () => harness.fixture.clarificationResponses.isNotEmpty,
      );
      expect(
        find.descendant(
          of: answer,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      await captureJourney(tester, 'native-clarification-answer-pending');
      expect(harness.fixture.clarificationResponses.single, {
        'profile': 'personal',
        'session_id': chat.runtime.runtimeId,
        'prompt_id': 'native-question',
        'execution_generation': 0,
        'answer': 'Summary',
      });
      gate.complete();
      await _pumpUntil(tester, () => chat.runtime.pendingQuestion == null);
      expect(chat.composer.observation.text, isEmpty);
      expect(harness.fixture.clarificationResponses, hasLength(1));
      await captureJourney(tester, 'native-clarification-answered');
      emitChatEvent(harness.controller, chat, 'clarify', {
        'request_id': 'native-batch',
        'questions': [
          {
            'qid': 'q1',
            'question': 'Which layout?',
            'choices': ['Compact'],
          },
          {
            'qid': 'q2',
            'question': 'Which theme?',
            'choices': ['Dark'],
          },
        ],
      });
      await _settle(tester);
      await tapJourneyControl(tester, find.text('Compact'));
      await tapJourneyControl(tester, find.text('Dark'));
      final composer = find.byKey(const Key('profile-message-composer'));
      await _journeyStep('clarification.preserve-draft', () async {
        await tapJourneyControl(tester, composer);
        await tester.enterText(composer, 'Keep this unrelated draft');
      });
      await _pumpUntil(tester, () => tester.view.viewInsets.bottom > 0);
      expect(chat.composer.observation.text, 'Keep this unrelated draft');
      expect(harness.fixture.clarificationLocks, isEmpty);
      final firstLock = harness.fixture.clarificationLockGate =
          Completer<void>();
      final retryLock = harness.fixture.clarificationRetryGate =
          Completer<void>();
      addTearDown(() {
        if (!firstLock.isCompleted) firstLock.complete();
        if (!retryLock.isCompleted) retryLock.complete();
      });
      final confirm = find.byKey(const Key('clarify-continue'));
      await tapJourneyControl(tester, confirm);
      await _pumpUntil(
        tester,
        () => harness.fixture.clarificationLocks.length == 1,
      );
      expect(
        find.descendant(
          of: confirm,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(tester.view.viewInsets.bottom, greaterThan(0));
      await captureJourney(
        tester,
        'native-clarification-batch-pending-keyboard',
      );
      firstLock.complete();
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('clarify-error')).evaluate().isNotEmpty,
      );
      expect(chat.runtime.questions!.answeredIds, {'q1'});
      expect(chat.composer.observation.text, 'Keep this unrelated draft');
      await captureJourney(
        tester,
        'native-clarification-batch-failed-keyboard',
      );
      // Touch-scroll the real conversation; its standard drag behavior may
      // dismiss the keyboard. Reopen it and prove the footer remains reachable.
      await _journeyStep(
        'clarification.retry-drag',
        () => dragTranscriptToControl(tester, confirm),
      );
      await _journeyStep(
        'clarification.reopen-keyboard',
        () => tapJourneyControl(tester, composer),
      );
      await _pumpUntil(tester, () => tester.view.viewInsets.bottom > 0);
      expect(confirm.hitTestable(), findsOneWidget);
      final visibleTranscript = tester.getRect(
        find.byKey(const ValueKey('profile-transcript')),
      );
      final retryBounds = tester.getRect(confirm);
      expect(visibleTranscript.contains(retryBounds.topLeft), isTrue);
      expect(
        visibleTranscript.contains(
          retryBounds.bottomRight - const Offset(.1, .1),
        ),
        isTrue,
      );
      expect(chat.composer.observation.text, 'Keep this unrelated draft');
      harness.fixture.failClarificationSecond = false;
      await captureJourney(tester, 'native-clarification-batch-retry-keyboard');
      await tester.tap(confirm);
      await _pumpUntil(
        tester,
        () => harness.fixture.clarificationLocks.length == 3,
      );
      expect(
        find.descendant(
          of: confirm,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(harness.fixture.clarificationLocks, [
        {
          'profile': 'personal',
          'request_id': 'native-batch',
          'question_id': 'q1',
          'answer': 'Compact',
        },
        {
          'profile': 'personal',
          'request_id': 'native-batch',
          'question_id': 'q2',
          'answer': 'Dark',
        },
        {
          'profile': 'personal',
          'request_id': 'native-batch',
          'question_id': 'q2',
          'answer': 'Dark',
        },
      ]);
      retryLock.complete();
      await _pumpUntil(tester, () => chat.runtime.questions == null);
      expect(chat.composer.observation.text, 'Keep this unrelated draft');
      expect(find.byKey(const Key('clarify-continue')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testJourney('drawer settings profiles chats and projects work at large text', (
    tester,
  ) async {
    await harness.launch(tester);

    expect(find.byType(ProfileWorkspaceScreen), findsOneWidget);
    expect(find.text('personal chat 0'), findsOneWidget);
    expect(find.text('personal project'), findsOneWidget);
    await captureJourney(tester, 'chats');

    await _navigate(tester, AppDestination.settings);
    await tester.scrollUntilVisible(
      find.text('Theme'),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Theme'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Text size'),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    await tapJourneyControl(tester, find.text('Text size'));
    await _settle(tester);
    await tapJourneyControl(tester, find.text('Extra large'));
    await _settle(tester);
    expect(
      harness.preferences.getString(AppPreferenceField.textSize.storageKey),
      AppTextSizePreference.extraLarge.storageValue,
    );
    await captureJourney(tester, 'settings-large-text');

    await _navigate(tester, AppDestination.chats);
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('chat-profile-work')),
    );
    try {
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey('chat-work-chat-3'))
            .evaluate()
            .isNotEmpty,
      );
    } catch (_) {
      final view = harness.appPreferences
          .browserPreferencesFor(harness.controller.connectionIdentity)
          .value;
      debugPrint(
        'Roadmap profile roundtrip: discovery=${harness.controller.discovery?.profiles.map((p) => p.name).toList()}, view=${view.display?.profiles}, statuses=${view.display?.statuses}, projects=${view.display?.projects}, workRows=${harness.controller.browserResource('work').sessions.length}, reads=${harness.fixture.reads.where((r) => r.$1 == 'sessions').toList()}',
      );
      rethrow;
    }
    await _revealChat(tester, 'work', 'chat-0');
    expect(find.text('personal chat 0'), findsNothing);
    expect(find.text('work project'), findsOneWidget);
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('chat-work-chat-0')),
    );
    await _pumpUntil(
      tester,
      () => harness.controller.current?.scope.profileName == 'work',
    );
    await _settle(tester);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.text('work project'), findsOneWidget);
    expect(find.text('work chat 0'), findsOneWidget);

    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('chat-filter-project')),
    );
    await _settle(tester);
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('chat-menu-work/shared-project')),
    );
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.text('work project'), findsWidgets);
    expect(find.text('work chat 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testJourney(
    'draft model slash find outputs and context use the production chat',
    (tester) async {
      await harness.launch(tester);
      await tapJourneyControl(
        tester,
        find.byKey(const ValueKey('chat-personal-chat-0')),
      );
      await _pumpUntil(
        tester,
        () =>
            find.text('personal message 620').evaluate().isNotEmpty &&
            harness.controller.current?.chat?.runtime.opening == false,
      );
      final chat = harness.controller.current!.chat!;

      expect(find.text('personal message 620'), findsOneWidget);
      expect(
        find.bySemanticsLabel('32768 of 131072 tokens, 25 percent used'),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('profile-message-composer')),
        'Draft survives chat navigation',
      );
      await tester.pump();
      await tester.binding.handlePopRoute();
      await _settle(tester);
      await tapJourneyControl(
        tester,
        find.byKey(const ValueKey('chat-personal-chat-0')),
      );
      await _settle(tester);
      expect(find.text('Draft survives chat navigation'), findsOneWidget);

      await tapJourneyControl(
        tester,
        find.byKey(const Key('chat-intelligence-button')),
      );
      await _settle(tester);
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('model-search'))
            .hitTestable()
            .evaluate()
            .isNotEmpty,
      );
      await tester.enterText(find.byKey(const Key('model-search')), 'sol');
      await _settle(tester);
      await tapJourneyControl(
        tester,
        find.byKey(const Key('model-openai-codex-gpt-5.6-sol')),
      );
      await _settle(tester);
      await tapJourneyControl(
        tester,
        find.byKey(const Key('chat-reasoning-control')).last,
      );
      await _settle(tester);
      await tester.ensureVisible(find.byKey(const Key('reasoning-xhigh')));
      await tapJourneyControl(tester, find.byKey(const Key('reasoning-xhigh')));
      await _settle(tester);
      await tapJourneyControl(tester, find.byTooltip('Apply model settings'));
      await _settle(tester);
      expect(find.text('5.6 Sol'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('composer-reasoning-control')),
          matching: find.text('X'),
        ),
        findsOneWidget,
      );
      final mutation = harness.fixture.configWrites.single;
      expect(mutation['session_id'], chat.runtime.runtimeId);
      expect(mutation['profile'], 'personal');
      expect(mutation['operation'], 'model');
      expect(mutation['payload'], {
        'model': 'gpt-5.6-sol',
        'provider': 'openai-codex',
        'reasoning': 'xhigh',
      });
      expect(mutation['request_id'], isA<String>());
      expect(mutation['request_id'], isNotEmpty);
      expect(mutation['expected_revision'], 0);
      expect(mutation['expected_generation'], 0);
      await captureJourney(tester, 'chat-model-and-draft');

      await tester.enterText(
        find.byKey(const Key('profile-message-composer')),
        '/road',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await _settle(tester);
      await tapJourneyControl(tester, find.text('/roadmap-check'));
      await tapJourneyControl(tester, find.byTooltip('Send'));
      await _pumpUntil(
        tester,
        () => find
            .textContaining('Roadmap fixture command complete')
            .evaluate()
            .isNotEmpty,
      );
      expect(harness.fixture.commandDispatches.single['name'], 'roadmap-check');

      await tapJourneyControl(tester, find.byTooltip('Chat actions'));
      await _settle(tester);
      await tapJourneyControl(tester, find.text('Find in chat'));
      await _settle(tester);
      await tester.enterText(find.byType(TextField).last, 'roadmap needle');
      await tester.pump();
      expect(
        find.text('1 matching message in loaded messages'),
        findsOneWidget,
      );
      await tapJourneyControl(
        tester,
        find.text('Roadmap needle: the emulator found this saved answer.').last,
      );
      await _settle(tester);
      await tapJourneyControl(tester, find.text('View in chat'));
      await _settle(tester);
      expect(
        find.text('Roadmap needle: the emulator found this saved answer.'),
        findsOneWidget,
      );
      await captureJourney(tester, 'search-result');

      await tapJourneyControl(tester, find.byTooltip('Chat actions'));
      await _settle(tester);
      await tapJourneyControl(tester, find.text('Outputs'));
      await _settle(tester);
      expect(find.text('roadmap-notes.md'), findsOneWidget);
      expect(find.textContaining('Outputs ·'), findsOneWidget);
      expect(chat.key.sessionId, 'chat-0');
      expect(tester.takeException(), isNull);
    },
  );

  testJourney('a missing staged file restores as removable without sending', (
    tester,
  ) async {
    await harness.launch(tester);
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('chat-personal-chat-0')),
    );
    await _settle(tester);
    final original = harness.controller.current!.chat!;
    const draftText = 'Keep this draft when its staged file disappears';
    const fileName = 'missing-staged-roadmap.txt';
    await harness.controller.updateDraft(original, draftText);

    final temporary = await getTemporaryDirectory();
    final source = File(
      '${temporary.path}/roadmap-source-'
      '${DateTime.now().microsecondsSinceEpoch}.txt',
    );
    await source.writeAsString('temporary attachment');
    addTearDown(() async {
      if (await source.exists()) await source.delete();
    });
    await harness.controller.addAttachments(original, [
      (path: source.path, name: fileName),
    ]);
    final staged = File(
      (await readComposerFixture(
        chat: original,
        preferences: harness.controller.preferences,
      ))!.attachments.single.cachedPath,
    ).absolute;
    final support = (await getApplicationSupportDirectory()).absolute;
    expect(staged.path, isNot(source.absolute.path));
    expect(
      staged.parent.path,
      '${support.path}${Platform.pathSeparator}attachment_drafts',
      reason: 'Only the production-owned staged copy may be removed.',
    );
    expect(await staged.exists(), isTrue);
    await staged.delete();
    expect(await staged.exists(), isFalse);

    final key = original.key;
    final connection = harness.controller.connection;
    final identity = harness.controller.connectionIdentity;
    await tester.pumpWidget(const SizedBox.shrink());
    final restoredAppPreferences = AppPreferences(harness.preferences);
    addTearDown(restoredAppPreferences.dispose);
    final restoredController = ProfileWorkspaceController(
      access: ConnectionAccess(connection: connection, dashboardOAuth: null),
      connectionIdentity: identity,
      preferences: harness.preferences,
      appPreferences: restoredAppPreferences,
      gatewayFactory: harness.fixture.gateway,
    );
    addTearDown(restoredController.dispose);
    await restoredController.initialize();
    await restoredController.openSession(key);
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: restoredController,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await _settle(tester);

    final restored = restoredController.current!.chat!;
    expect(restored.composer.observation.text, draftText);
    expect(restored.composer.observation.attachments.single.name, fileName);
    expect(
      restored.composer.observation.attachments.single.error,
      contains('no longer available'),
    );
    expect(find.text(fileName), findsOneWidget);
    expect(
      find.byTooltip(
        'This staged file is no longer available. Remove it and attach it again.',
      ),
      findsOneWidget,
    );
    // Reopening preserves the prior reading point. The failed-file chip is
    // immediately actionable; use Latest to inspect the transcript's warning.
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('jump-to-latest')),
    );
    await _pumpUntil(
      tester,
      () => find
          .text(
            'A staged attachment is no longer available. Your draft text was kept.',
          )
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.text(
        'A staged attachment is no longer available. Your draft text was kept.',
      ),
      findsOneWidget,
    );

    final submitsBefore = harness.fixture.calls
        .where((call) => call.$2 == 'prompt.submit')
        .length;
    // This is still the editable draft. Send transfers it to a distinct outbox
    // entry; per-file queued editing is not the behavior under test here.
    final removeAttachment = find.descendant(
      of: find.widgetWithText(InputChip, fileName),
      matching: find.byTooltip('Delete'),
    );
    await tester.ensureVisible(removeAttachment);
    await tapJourneyControl(tester, removeAttachment);
    await _pumpUntil(
      tester,
      () => restored.composer.observation.attachments.isEmpty,
    );
    await _settle(tester);
    expect(restored.composer.observation.text, draftText);
    expect(restored.composer.observation.queue, isEmpty);
    expect(find.text(fileName), findsNothing);
    final saved = (await readComposerFixture(
      chat: restored,
      preferences: restoredController.preferences,
    ))!;
    expect(saved.text, draftText);
    expect(saved.attachments, isEmpty);
    expect(saved.queuedPrompts, isEmpty);
    expect(
      harness.fixture.calls.where((call) => call.$2 == 'prompt.submit'),
      hasLength(submitsBefore),
    );
    expect(tester.takeException(), isNull);
  });

  testJourney('activity approvals and queued work keep their chat owner', (
    tester,
  ) async {
    harness.fixture.resumedRuntimes[('personal', 'chat-0')] = 'runtime-running';
    await harness.launch(tester);
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('chat-personal-chat-0')),
    );
    await _settle(tester);
    final runningChat = harness.controller.current!.chat!;
    await tester.binding.handlePopRoute();
    await _settle(tester);
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('chat-personal-chat-1')),
    );
    await _settle(tester);
    final chat = harness.controller.current!.chat!;

    emitChatEvent(harness.controller, chat, 'message.start');
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('profile-message-composer')),
      'Queue this after the synthetic turn',
    );
    await tester.pump();
    await _chooseComposerAction(tester, 'queue');
    expect(
      chat.composer.observation.queue.single.text,
      'Queue this after the synthetic turn',
    );
    expect(find.byTooltip('Message actions'), findsNothing);
    await captureJourney(tester, 'queued-message');

    harness.fixture.requestApproval('personal', chat.runtime.runtimeId);
    await tester.pump();
    final approval = find.byType(GatewayApprovalPanel);
    expect(approval, findsOneWidget);
    expect(
      tester.widget<GatewayApprovalPanel>(approval).request.command,
      'echo isolated-roadmap-check',
    );
    expect(
      find.descendant(of: approval, matching: find.text('Review command')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: approval,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText &&
              widget.data == 'echo isolated-roadmap-check',
        ),
      ),
      findsOneWidget,
    );
    await captureJourney(tester, 'approval');
    final approveOnce = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == 'Approve once',
    );
    await tester.ensureVisible(approveOnce);
    await _pumpUntil(
      tester,
      () => approveOnce.hitTestable().evaluate().isNotEmpty,
    );
    await tapJourneyControl(tester, approveOnce);
    await _settle(tester);
    expect(
      harness.fixture.approvalResponses.single,
      containsPair('choice', 'once'),
    );
    expect(find.byType(GatewayApprovalPanel), findsNothing);

    final gateway = harness.controller.browserResource('personal').gateway;
    final queuedAdmission = gateway.canonical
        .session(chat.runtime.runtimeId)!
        .pending
        .single;
    expect(queuedAdmission.queued, isTrue);
    expect(queuedAdmission.text, 'Queue this after the synthetic turn');
    // Completing the current turn cannot locally drain Hermes's accepted FIFO.
    emitChatEvent(harness.controller, chat, 'message.complete', {
      'text': 'The approved fixture turn completed.',
    });
    await tester.pump();
    expect(chat.composer.observation.queue, hasLength(1));
    // The stock owner publishes the claimed admission on message.start, then
    // publishes its updated pending receipts through session.info.
    gateway.onEvent!(
      StreamEvent(
        type: 'message.start',
        sessionId: chat.runtime.runtimeId,
        envelope: {'admission_id': queuedAdmission.id},
        data: const {},
      ),
    );
    emitChatEvent(harness.controller, chat, 'session.info', {
      'running': true,
      'pending': [
        {
          'admission_id': queuedAdmission.id,
          'input_id': queuedAdmission.inputId,
          'ref': {'session_id': chat.runtime.runtimeId},
          'sequence': queuedAdmission.sequence,
          'status': 'started',
          'execution_generation': queuedAdmission.generation,
          'text': queuedAdmission.text,
          'controls': const <String>[],
          'steering': false,
        },
      ],
    });
    await _pumpUntil(tester, () => chat.composer.observation.queue.isEmpty);
    harness.fixture.requestApproval('personal', chat.runtime.runtimeId);
    await tester.pump();
    harness.fixture.liveSessions['personal'] = [
      {
        'id': runningChat.runtime.runtimeId,
        'session_key': 'chat-0',
        'status': 'working',
        'last_active': 2,
      },
      {
        'id': chat.runtime.runtimeId,
        'session_key': 'chat-1',
        'status': 'waiting',
        'last_active': 1,
      },
    ];
    await _navigate(tester, AppDestination.activity);
    await _pumpUntil(
      tester,
      () => find.text('personal chat 0').evaluate().isNotEmpty,
    );
    expect(find.text('personal chat 1'), findsOneWidget);
    expect(find.byType(FilterChip), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('activity-personal-chat-1')),
        matching: find.text('Needs your input'),
      ),
      findsOneWidget,
    );
    expect(find.text('personal chat 0'), findsOneWidget);
    expect(find.text('personal chat 1'), findsOneWidget);
    await captureJourney(tester, 'activity-needs-input');
    await tapJourneyControl(tester, find.text('personal chat 1'));
    await _settle(tester);
    expect(harness.controller.current!.chat, same(chat));
    expect(chat.composer.observation.queue, isEmpty);
    final queuedSubmit = harness.fixture.calls.singleWhere(
      (call) => call.$2 == 'prompt.submit',
    );
    expect(queuedSubmit.$1, 'personal');
    expect(queuedSubmit.$3['text'], 'Queue this after the synthetic turn');
    expect(tester.takeException(), isNull);
  });

  testJourney('project discovery review delivery and input jump stay native', (
    tester,
  ) async {
    await harness.launch(tester);

    await tapJourneyControl(tester, find.byTooltip('Chat list options'));
    await _settle(tester);
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('chat-menu-new-project')),
    );
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('project-name-field')),
      'Roadmap integration',
    );
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('project-choose-folder')),
    );
    await _settle(tester);
    final discoveredFolder = find.byKey(
      const ValueKey('project-folder-/srv/wing'),
    );
    await tester.ensureVisible(discoveredFolder);
    await _settle(tester);
    await tapJourneyControl(tester, discoveredFolder);
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey('project-folder-continue')),
    );
    await _settle(tester);
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('project-folder-continue')),
    );
    await _settle(tester);

    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('project-create-confirm')),
    );
    await _pumpUntil(tester, () => find.text('New project').evaluate().isEmpty);

    expect(harness.fixture.projectCreates.single, {
      'name': 'Roadmap integration',
      'folders': ['/srv/wing'],
      'primary_path': '/srv/wing',
      'color': '',
      'icon': 'folder-library',
      'profile': 'personal',
    });
    expect(find.text('Roadmap integration'), findsOneWidget);
    await captureJourney(tester, 'project-created');

    final createdProjectActions = find.descendant(
      of: find.byKey(const ValueKey('project-personal-roadmap-created')),
      matching: find.byTooltip('Project actions'),
    );
    await tapJourneyControl(tester, createdProjectActions);
    await _settle(tester);
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('project-action-editProject')),
    );
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('project-name-field')),
      'Roadmap renamed',
    );
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('project-edit-confirm')),
    );
    await _settle(tester);
    expect(harness.fixture.projectUpdates.single, {
      'id': 'roadmap-created',
      'name': 'Roadmap renamed',
      'color': '',
      'icon': 'folder-library',
      'profile': 'personal',
    });
    expect(find.text('Roadmap renamed'), findsOneWidget);

    await tapJourneyControl(tester, createdProjectActions);
    await _settle(tester);
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('project-action-delete')),
    );
    await _settle(tester);
    expect(find.textContaining('chats will remain'), findsOneWidget);
    expect(
      find.textContaining('Files on the host will not be deleted'),
      findsOneWidget,
    );
    await tapJourneyControl(tester, find.byTooltip('Cancel'));
    await _settle(tester);
    expect(harness.fixture.projectDeletes, isEmpty);
    expect(find.text('Roadmap renamed'), findsOneWidget);

    await tapJourneyControl(tester, createdProjectActions);
    await _settle(tester);
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('project-action-delete')),
    );
    await _settle(tester);
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('project-delete-confirm')),
    );
    await _settle(tester);
    expect(harness.fixture.projectDeletes.single, {
      'id': 'roadmap-created',
      'profile': 'personal',
    });
    expect(find.text('Roadmap renamed'), findsNothing);

    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('chat-personal-chat-0')),
    );
    await _settle(tester);
    final chat = harness.controller.current!.chat!;
    harness.fixture.deliverReview('personal', chat.runtime.runtimeId);
    await tester.pump();
    expect(find.text('Memory and skills review'), findsNothing);
    await tapJourneyControl(
      tester,
      find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')).first,
    );
    await _settle(tester);
    expect(find.text('Memory and skills review'), findsOneWidget);
    expect(find.text('Reported changes'), findsNothing);
    await Scrollable.ensureVisible(
      tester.element(find.text('Memory and skills review')),
      alignment: .5,
    );
    await _settle(tester);
    await tapJourneyControl(tester, find.text('Memory and skills review'));
    await _settle(tester);
    expect(find.text('Reported changes'), findsOneWidget);
    await captureJourney(tester, 'review');
    await tapJourneyControl(tester, find.text('Memory and skills review'));
    await _settle(tester);

    final transcript = find.byKey(const ValueKey('profile-transcript'));
    await tester.drag(transcript, const Offset(0, 550));
    await _settle(tester);
    expect(find.byKey(const ValueKey('jump-to-latest')), findsOneWidget);

    harness.fixture.requestVaultUnlock('personal', chat.runtime.runtimeId);
    await _settle(tester);
    final inputJump = find.byKey(const ValueKey('jump-to-latest'));
    expect(
      find.descendant(of: inputJump, matching: find.byTooltip('Input needed')),
      findsOneWidget,
    );
    await tapJourneyControl(tester, inputJump);
    await _settle(tester);

    expect(chat.reading.readingPosition.resume, isNull);
    expect(chat.runtime.secureInput?.requestId, 'roadmap-vault-unlock');
    expect(find.text('Unlock Roadmap Vault'), findsOneWidget);
    await captureJourney(tester, 'vault-unlock');
    const vaultPassword = 'isolated-roadmap-vault-secret';
    await tester.enterText(
      find.byKey(const Key('sensitive-prompt-field')),
      vaultPassword,
    );
    final sensitiveSubmit = find.byKey(const Key('sensitive-prompt-submit'));
    await _settle(tester);
    expect(tester.widget<IconButton>(sensitiveSubmit).onPressed, isNotNull);
    await Scrollable.ensureVisible(
      tester.element(sensitiveSubmit),
      alignment: 0.5,
    );
    await _settle(tester);
    await tapJourneyControl(tester, sensitiveSubmit);
    await _pumpUntil(tester, () => chat.runtime.secureInput == null);
    await _settle(tester);
    expect(harness.fixture.sensitiveResponses.single, {
      'id': 'roadmap-vault-unlock',
      'result': {'value': vaultPassword},
      'profile': 'personal',
    });
    expect(find.text('Unlock Roadmap Vault'), findsNothing);
    expect(chat.composer.observation.text, isNot(contains(vaultPassword)));
    expect(chat.reading.messages.toString(), isNot(contains(vaultPassword)));
    expect(
      [
        for (final key in harness.preferences.getKeys())
          harness.preferences.get(key),
      ].toString(),
      isNot(contains(vaultPassword)),
    );
    expect(tester.takeException(), isNull);
  });

  testJourney(
    'completed child stays in current work while the parent streams',
    (tester) async {
      final rows = <Map<String, dynamic>>[
        {'id': 1, 'role': 'user', 'content': 'Inspect the emulator release.'},
      ];
      harness.fixture.scopedHistories[('personal', 'chat-0')] = rows;
      await harness.launch(tester);
      await tapJourneyControl(
        tester,
        find.byKey(const ValueKey('chat-personal-chat-0')),
      );
      await _settle(tester);
      final chat = harness.controller.current!.chat!;
      final runtime = chat.runtime.runtimeId;
      final composer = find.byKey(const Key('profile-message-composer'));
      const draft = 'Keep this draft while the child completes';
      await tester.enterText(composer, draft);
      tester.binding.focusManager.primaryFocus?.unfocus();

      emitChatEvent(harness.controller, chat, 'message.start');
      emitChatEvent(harness.controller, chat, 'tool.complete', {
        'tool_id': 'native-release-source',
        'name': 'read_file',
        'args': {'path': '/tmp/release-notes.md'},
        'result': 'The release source is available.',
      });
      emitChatEvent(harness.controller, chat, 'message.delta', {
        'text': 'Parent stream before child completion.',
      });
      await harness.controller.refreshSubagents(chat);
      await _settle(tester);

      final dockAgents = find.byKey(
        const ValueKey(('live-work-tab', 0, false)),
      );
      await tester.ensureVisible(dockAgents);
      await _settle(tester);
      await tapJourneyControl(tester, dockAgents);
      await _settle(tester);
      final child = find.byKey(
        ValueKey(('subagent', chat.key, 'roadmap-child')),
      );
      expect(child, findsOneWidget);
      await tester.ensureVisible(child);
      await _settle(tester);
      await tapJourneyControl(
        tester,
        find.descendant(of: child, matching: find.byIcon(Icons.chevron_right)),
      );
      await _settle(tester);
      Finder detailAction(String label) => find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byTooltip(label),
      );
      expect(detailAction('Steer'), findsOneWidget);
      expect(detailAction('Interrupt'), findsOneWidget);

      // The terminal event must update controls in an already-open inspection.
      // Saving its receipt is independent of the still-streaming parent answer.
      harness.fixture.subagentStatus = 'completed';
      harness.fixture.subagentOutput = 'Verified the emulator release source.';
      emitChatEvent(harness.controller, chat, 'subagent.complete', {
        'subagent_id': 'roadmap-child',
        'status': 'completed',
        'summary': 'Release source verified.',
      });
      rows.addAll([
        {
          'id': 2,
          'role': 'tool',
          'tool_call_id': 'native-release-source',
          'tool_name': 'read_file',
          'args': {'path': '/tmp/release-notes.md'},
          'content': 'The release source is available.',
        },
        {
          'id': 3,
          'role': 'assistant',
          'content': 'The inspection is underway.',
        },
        {
          'id': 4,
          'role': 'user',
          'display_kind': 'async_delegation_complete',
          'display_metadata': {
            'task_count': 1,
            'display_text':
                'Subagent Task Completed: Inspect the emulator release',
          },
          'content': 'Verified the emulator release source.',
        },
      ]);
      await harness.controller.refreshHistory(chat);
      await _settle(tester);
      expect(detailAction('Steer'), findsNothing);
      expect(detailAction('Interrupt'), findsNothing);
      final refreshOutput = detailAction('Refresh live output');
      await tester.ensureVisible(refreshOutput);
      await _settle(tester);
      await tapJourneyControl(tester, refreshOutput);
      await _settle(tester);
      final output = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is SourceCodeText &&
              widget.text == 'Verified the emulator release source.',
        ),
      );
      await tester.ensureVisible(output);
      await _settle(tester);
      expect(output, findsOneWidget);
      expect(detailAction('Copy Live output'), findsOneWidget);
      final tailReads = harness.fixture.supervisionRequests.where(
        (request) => request.$1 == 'subagent.tail',
      );
      expect(tailReads, isNotEmpty);
      for (final request in tailReads) {
        expect(request.$2, {
          'session_id': runtime,
          'subagent_id': 'roadmap-child',
          'profile': 'personal',
        });
      }
      await captureJourney(tester, 'child-completed-parent-streaming');
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(child, findsOneWidget);
      expect(
        find.descendant(
          of: child,
          matching: find.text('Inspect the emulator release'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: child, matching: find.text('Completed')),
        findsOneWidget,
      );
      expect(chat.currentSubagents.single.isTerminal, isTrue);
      expect(
        harness.fixture.supervisionRequests.where(
          (request) => const {
            'subagent.steer',
            'subagent.interrupt',
          }.contains(request.$1),
        ),
        isEmpty,
      );
      await tapJourneyControl(
        tester,
        find.byKey(const ValueKey(('live-work-tab', 0, true))),
      );
      await _settle(tester);

      emitChatEvent(harness.controller, chat, 'message.delta', {
        'text': ' Parent stream continues after child completion.',
      });
      await _settle(tester);
      expect(chat.runtime.executionActive, isTrue);
      expect(
        chat.reading.streaming,
        contains('Parent stream continues after child completion.'),
      );
      expect(
        chat.reading.messages.where((row) => row['id'] == 4),
        hasLength(1),
      );
      final activity = find
          .textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$'))
          .first;
      await tester.ensureVisible(activity);
      await _settle(tester);
      await tapJourneyControl(tester, activity);
      await _settle(tester);
      final liveTabs = find.descendant(
        of: find.byType(ProfileLiveExecution),
        matching: find.byType(ProfileActivityTabs),
      );
      expect(liveTabs, findsWidgets);
      for (final tabs in tester.widgetList<ProfileActivityTabs>(liveTabs)) {
        expect(tabs.tabs.map((tab) => tab.id), ['timeline']);
      }
      expect(
        find.text('Subagent Task Completed: Inspect the emulator release'),
        findsNothing,
      );
      final latest = find.byKey(const ValueKey('jump-to-latest'));
      if (latest.evaluate().isNotEmpty) {
        await tapJourneyControl(tester, latest);
        await _settle(tester);
      }
      final continuedAnswer = find.textContaining(
        'Parent stream continues after child completion.',
        findRichText: true,
      );
      // Expanding Activity preserves its reading anchor. Move through the
      // actual transcript to the continued answer rather than assuming that
      // opening the disclosure leaves that lazy row mounted at the newest edge.
      await tester.scrollUntilVisible(
        continuedAnswer,
        -120,
        scrollable: find
            .descendant(
              of: find.byType(ProfileTranscript),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await _settle(tester);
      await captureJourney(tester, 'continued-parent-answer');
      expect(continuedAnswer, findsOneWidget);
      expect(chat.runtime.runtimeId, runtime);
      expect(chat.composer.observation.text, draft);
      expect(tester.widget<TextField>(composer).controller!.text, draft);

      rows.add({
        'id': 5,
        'role': 'assistant',
        'content': 'The parent has finished.',
      });
      emitChatEvent(harness.controller, chat, 'message.complete', {
        'text': 'The parent has finished.',
      });
      await _settle(tester);
      expect(chat.runtime.executionActive, isFalse);
      expect(chat.currentSubagents, isEmpty);
      expect(dockAgents, findsNothing);
      expect(chat.subagents.single.isTerminal, isTrue);
      expect(chat.composer.observation.text, draft);
      expect(tester.takeException(), isNull);
    },
  );

  testJourney('subagents goals and background work keep their chat owner', (
    tester,
  ) async {
    harness.fixture.supervisionEnabled = true;
    await harness.launch(tester);
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('chat-personal-chat-0')),
    );
    await _settle(tester);
    final chat = harness.controller.current!.chat!;
    await tester.enterText(
      find.byKey(const Key('profile-message-composer')),
      'Keep this supervision draft',
    );

    await tester.ensureVisible(
      find.byKey(const ValueKey(('live-work-tab', 0, false))),
    );
    await _settle(tester);
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey(('live-work-tab', 0, false))),
    );
    await _settle(tester);
    final child = find.byKey(ValueKey(('subagent', chat.key, 'roadmap-child')));
    await tester.ensureVisible(child);
    await _settle(tester);
    await tapJourneyControl(
      tester,
      find.descendant(of: child, matching: find.byIcon(Icons.chevron_right)),
    );
    await _settle(tester);
    final childOutput = find.byWidgetPredicate(
      (widget) =>
          widget is SourceCodeText &&
          widget.text == 'Emulator child is checking the release.',
    );
    await tester.scrollUntilVisible(
      childOutput,
      160,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(childOutput, findsOneWidget);
    await tester.enterText(
      find.byType(TextField).last,
      'Check the Android route',
    );
    final steer = find.byTooltip('Steer');
    await tester.ensureVisible(steer);
    await _settle(tester);
    await tapJourneyControl(tester, steer);
    await _settle(tester);
    expect(find.text('Steering queued.'), findsOneWidget);
    final steerRequest = harness.fixture.supervisionRequests.singleWhere(
      (request) => request.$1 == 'subagent.steer',
    );
    expect(steerRequest.$2, {
      'session_id': chat.runtime.runtimeId,
      'subagent_id': 'roadmap-child',
      'text': 'Check the Android route',
      'profile': 'personal',
    });
    await tester.binding.handlePopRoute();
    await _settle(tester);
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey(('live-work-tab', 0, true))),
    );
    await _settle(tester);
    final activity = find.text('Activity');
    await tester.ensureVisible(activity);
    await _settle(tester);
    await tapJourneyControl(tester, activity);
    await _settle(tester);
    await tester.ensureVisible(find.text('Goal'));
    await _settle(tester);
    await tapJourneyControl(tester, find.text('Goal').hitTestable());
    await _settle(tester);
    final goalSheet = find.byType(ProfileGoalPanel);
    expect(
      find.descendant(
        of: goalSheet,
        matching: find.text('Verify the emulator roadmap'),
      ),
      findsOneWidget,
    );
    final pauseGoal = find.descendant(
      of: goalSheet,
      matching: find.byTooltip('Pause'),
    );
    await tester.ensureVisible(pauseGoal);
    await _settle(tester);
    await tapJourneyControl(tester, pauseGoal);
    await _settle(tester);
    expect(
      find.descendant(of: goalSheet, matching: find.text('Paused · 2/8 turns')),
      findsOneWidget,
    );
    await captureJourney(tester, 'goal-paused');
    final goalRequest = harness.fixture.supervisionRequests.singleWhere(
      (request) =>
          request.$1 == 'session.control' &&
          request.$2['action'] == 'goal.pause',
    );
    expect(goalRequest.$2['session_id'], chat.runtime.runtimeId);
    expect(goalRequest.$2['profile'], 'personal');
    await tester.ensureVisible(find.text('Background work'));
    await _settle(tester);
    await tapJourneyControl(tester, find.text('Background work'));
    await _settle(tester);
    expect(find.text('Report emulator health'), findsOneWidget);
    final countdown = find.textContaining('Next in ');
    await tester.ensureVisible(countdown);
    await _settle(tester);
    expect(countdown, findsOneWidget);
    await captureJourney(tester, 'background-work');
    await tester.ensureVisible(find.byTooltip('Pause loop'));
    await _settle(tester);
    await tapJourneyControl(tester, find.byTooltip('Pause loop'));
    await _settle(tester);
    expect(find.text('Loop · Paused'), findsOneWidget);
    expect(find.textContaining('Next in '), findsNothing);
    await tester.ensureVisible(find.text('dart run roadmap_worker.dart'));
    await _settle(tester);
    await tapJourneyControl(tester, find.text('dart run roadmap_worker.dart'));
    await _settle(tester);
    await tester.ensureVisible(find.byTooltip('Stop process'));
    await _settle(tester);
    await tapJourneyControl(tester, find.byTooltip('Stop process'));
    await _settle(tester);
    expect(find.text('dart run roadmap_worker.dart'), findsNothing);
    await tester.ensureVisible(find.text('dart test roadmap_check.dart'));
    await _settle(tester);
    await tapJourneyControl(tester, find.text('dart test roadmap_check.dart'));
    await _settle(tester);
    await tester.ensureVisible(find.byTooltip('Dismiss'));
    await _settle(tester);
    await tapJourneyControl(tester, find.byTooltip('Dismiss'));
    await _settle(tester);
    expect(find.text('dart test roadmap_check.dart'), findsNothing);

    final loopRequest = harness.fixture.supervisionRequests.singleWhere(
      (request) =>
          request.$1 == 'session.control' &&
          request.$2['action'] == 'loop.pause',
    );
    expect(loopRequest.$2['session_id'], chat.runtime.runtimeId);
    expect(loopRequest.$2['profile'], 'personal');
    final processRequest = harness.fixture.supervisionRequests.singleWhere(
      (request) => request.$1 == 'process.kill',
    );
    expect(processRequest.$2, {
      'session_id': chat.runtime.runtimeId,
      'process_id': 'roadmap-process-running',
      'profile': 'personal',
    });
    expect(chat.composer.observation.text, 'Keep this supervision draft');
    expect(tester.takeException(), isNull);
  });

  testJourney('administration checks edits and update refusal stay scoped', (
    tester,
  ) async {
    await harness.launchAdministration(tester);
    await captureJourney(tester, 'administration');

    await tester.scrollUntilVisible(
      find.text('Identity'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tapJourneyControl(tester, find.text('Identity'));
    await revealJourneyControl(
      tester,
      find.byKey(const ValueKey('profile-description-field')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('profile-description-field')),
      'Discard this edit',
    );
    await tester.pump();
    await tapJourneyControl(tester, find.byTooltip('Cancel'));
    await _settle(tester);
    expect(find.text('Discard unsaved changes?'), findsOneWidget);
    await tapJourneyControl(tester, find.byTooltip('Discard edits'));
    await _settle(tester);
    expect(harness.fixture.profileIdentityWrites, isEmpty);

    await tapJourneyControl(tester, find.text('Identity'));
    await revealJourneyControl(
      tester,
      find.byKey(const ValueKey('profile-description-field')),
    );
    await _journeyStep(
      'identity.enter-description',
      () => tester.enterText(
        find.byKey(const ValueKey('profile-description-field')),
        '  Updated from emulator  ',
      ),
    );
    await _journeyStep('identity.description-frame', () => tester.pump());
    await _journeyStep(
      'identity.reveal-soul',
      () => revealJourneyControl(
        tester,
        find.byKey(const ValueKey('profile-soul-field')),
      ),
    );
    await _journeyStep(
      'identity.enter-soul',
      () => tester.enterText(
        find.byKey(const ValueKey('profile-soul-field')),
        'Keep this exact.\n',
      ),
    );
    await _journeyStep('identity.soul-frame', () => tester.pump());
    await _journeyStep(
      'identity.keyboard-visible',
      () => _pumpUntil(tester, () => tester.view.viewInsets.bottom > 0),
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('profile-description-field')),
          )
          .controller!
          .text,
      '  Updated from emulator  ',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('profile-soul-field')))
          .controller!
          .text,
      'Keep this exact.\n',
    );
    await _journeyStep('identity.save', () async {
      final save = find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == 'Save changes',
      );
      await revealJourneyControl(tester, save);
      expect(save.hitTestable(), findsOneWidget);
      expect(tester.widget<IconButton>(save).onPressed, isNotNull);
      expect(tester.view.viewInsets.bottom, greaterThan(0));
      await tester.tap(save);
    });
    await _journeyStep(
      'identity.save-receipt',
      () => _pumpUntil(
        tester,
        () => harness.fixture.profileIdentityWrites.isNotEmpty,
      ),
    );
    await _journeyStep(
      'identity.partial-save-feedback',
      () => _pumpUntil(
        tester,
        () => find.text('Saved: description.').evaluate().isNotEmpty,
      ),
    );
    final identityWrites = harness.fixture.profileIdentityWrites;
    expect(identityWrites.map((write) => write.$1), [
      'profiles/personal/description',
      'profiles/personal/soul',
    ]);
    expect(identityWrites[0].$2, {'description': 'Updated from emulator'});
    expect(identityWrites[1].$2, {'content': 'Keep this exact.\n'});
    expect(find.text('Saved: description.'), findsOneWidget);
    expect(
      find.text('Some fields were not saved. Review them before trying again.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('profile-soul-field')))
          .controller!
          .text,
      'Keep this exact.\n',
    );
    await captureJourney(tester, 'identity-partial-save');
    await tester.ensureVisible(find.byTooltip('Cancel'));
    await _settle(tester);
    await tapJourneyControl(tester, find.byTooltip('Cancel'));
    await _settle(tester);
    await tapJourneyControl(tester, find.byTooltip('Discard edits'));
    await _settle(tester);

    await tapJourneyControl(tester, find.byTooltip('Open navigation menu'));
    await _settle(tester);
    await captureJourney(tester, 'drawer');
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('menu-server-version')),
    );
    await _settle(tester);
    final checksBeforeRefresh = harness.fixture.updateCheckCount;
    await tapJourneyControl(tester, find.byTooltip('Check for updates'));
    await _settle(tester);
    expect(find.text('1.2.3'), findsOneWidget);
    expect(find.text('Install method: git'), findsOneWidget);
    expect(harness.fixture.updateCheckCount, checksBeforeRefresh + 1);
    await captureJourney(tester, 'versions');

    await tester.ensureVisible(find.byTooltip('Update backend'));
    await _settle(tester);
    await tapJourneyControl(tester, find.byTooltip('Update backend'));
    await _settle(tester);
    expect(find.text('Update backend on Roadmap fixture?'), findsOneWidget);
    await tapJourneyControl(tester, find.byTooltip('Cancel'));
    await _settle(tester);
    expect(harness.fixture.backendUpdatePosts, isEmpty);

    await tapJourneyControl(tester, find.byTooltip('Update backend'));
    await _settle(tester);
    harness.fixture.updateAvailable = false;
    final checksBeforeConfirm = harness.fixture.updateCheckCount;
    await tapJourneyControl(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byTooltip('Update backend'),
      ),
    );
    await _settle(tester);
    expect(harness.fixture.updateCheckCount, checksBeforeConfirm + 1);
    expect(harness.fixture.backendUpdatePosts, isEmpty);
    expect(
      find.text('The server reports no update is available.'),
      findsOneWidget,
    );

    await captureJourney(tester, 'update-refused');
    await tester.pageBack();
    await _settle(tester);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    await _navigate(tester, AppDestination.health);
    await _pumpUntil(
      tester,
      () => find.text('No known vulnerabilities found').evaluate().isNotEmpty,
    );
    expect(find.text('No issues found'), findsOneWidget);
    expect(find.text('No known vulnerabilities found'), findsOneWidget);
    expect(
      harness.fixture.diagnosticPosts.map((request) => request.$1),
      unorderedEquals(['ops/doctor', 'ops/security-audit']),
    );
    await captureJourney(tester, 'health');
    await _navigate(tester, AppDestination.analytics);
    await tapJourneyControl(tester, find.text('7D'));
    await _settle(tester);
    await tapJourneyControl(tester, find.text('30D'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('usage-year-band')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('openai/gpt-6-astra'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await _settle(tester);
    expect(find.text('Roadmap fixture / personal'), findsOneWidget);
    expect(_usageChartRow('openai/gpt-6-astra: 12,760 tokens'), findsOneWidget);
    expect(
      find.descendant(
        of: _usageChartRow('openai/gpt-6-astra: 12,760 tokens'),
        matching: find.text('12.8K'),
      ),
      findsOneWidget,
    );
    final costChoice = find.byKey(const ValueKey('usage-breakdown-cost'));
    await tester.scrollUntilVisible(
      costChoice,
      -200,
      scrollable: find
          .descendant(
            of: find.byType(HermesAnalyticsContent),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await _settle(tester);
    await tapJourneyControl(tester, costChoice);
    await _settle(tester);
    expect(_usageChartRow('openai/gpt-6-astra: USD 2.50'), findsOneWidget);
    expect(
      find.descendant(
        of: _usageChartRow('openai/gpt-6-astra: USD 2.50'),
        matching: find.text('USD 2.50'),
      ),
      findsOneWidget,
    );
    await captureJourney(tester, 'usage');
    await tester.scrollUntilVisible(
      find.text('local/missing-cost'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await _settle(tester);
    expect(
      _usageChartRow('local/missing-cost: Unavailable, partial'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _usageChartRow('local/missing-cost: Unavailable, partial'),
        matching: find.text('Unavailable · partial'),
      ),
      findsOneWidget,
    );
    expect(
      harness.fixture.administrationReads
          .where(
            (request) =>
                request.$1 == 'analytics/models' && request.$2['days'] == '30',
          )
          .map((request) => request.$2),
      unorderedEquals([
        {'days': '30', 'profile': 'personal'},
        {'days': '30', 'profile': 'work'},
      ]),
    );

    await _navigate(tester, AppDestination.health);
    await tester.scrollUntilVisible(
      find.byTooltip('Refresh profile status'),
      -250,
      scrollable: find.byType(Scrollable).last,
    );
    final checksBeforeRetry = harness.fixture.administrationRequests
        .where((request) => request.$1 == 'setup.runtime_check')
        .length;
    await tapJourneyControl(tester, find.byTooltip('Refresh profile status'));
    await _settle(tester);
    await tester.ensureVisible(find.text('Model access'));
    await _settle(tester);
    expect(find.text('Check incomplete'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('private roadmap runtime detail'), findsNothing);
    await captureJourney(tester, 'provider-access');
    expect(
      harness.fixture.reads.any(
        (request) =>
            request.$1 == 'sessions' &&
            request.$2['limit'] == '1' &&
            request.$2['offset'] == '0' &&
            request.$2['order'] == 'recent' &&
            request.$2['profile'] == 'personal',
      ),
      isFalse,
    );
    final runtimeChecks = harness.fixture.administrationRequests
        .where((request) => request.$1 == 'setup.runtime_check')
        .toList();
    expect(runtimeChecks, hasLength(checksBeforeRetry + 1));
    expect(runtimeChecks.last.$2, {'profile': 'personal'});
    expect(tester.takeException(), isNull);
  });

  testJourney('saved answers edit regenerate branch and fork through Hermes', (
    tester,
  ) async {
    await harness.launch(tester);
    harness.fixture.enableAnswerActions();
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('chat-personal-chat-0')),
    );
    await _pumpUntil(
      tester,
      () =>
          harness.controller.current?.chat?.runtime.opening == false &&
          harness.controller.current!.chat!.reading.messages.length == 4,
    );
    await _settle(tester);
    final source = harness.controller.current!.chat!;
    await tester.enterText(
      find.byKey(const Key('profile-message-composer')),
      'Keep this unrelated draft',
    );
    tester.binding.focusManager.primaryFocus?.unfocus();
    await _settle(tester);

    final edit = find.byKey(const ValueKey('edit-message-3'));
    await Scrollable.ensureVisible(tester.element(edit), alignment: .5);
    await _settle(tester);
    await tapJourneyControl(tester, edit);
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('saved-message-edit-dialog')),
      findsOneWidget,
    );
    expect(
      find.text(
        'Resending replaces this message. This answer is replaced and the prompt runs again.',
      ),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('saved-message-edit-input')),
      'Corrected emulator prompt',
    );
    final replaceAndResend = find.byWidgetPredicate(
      (widget) =>
          widget is IconButton &&
          widget.tooltip == 'Replace message and resend',
    );
    await _pumpUntil(
      tester,
      () => tester.widget<IconButton>(replaceAndResend).onPressed != null,
    );
    await tester.ensureVisible(replaceAndResend);
    await _settle(tester);
    await tapJourneyControl(tester, replaceAndResend);
    await _pumpUntil(
      tester,
      () => harness.fixture.answerActionRequests.any(
        (request) => request.$1 == 'prompt.submit',
      ),
    );
    final editSubmit = harness.fixture.answerActionRequests.singleWhere(
      (request) => request.$1 == 'prompt.submit',
    );
    expect(editSubmit.$2, {
      'session_id': source.runtime.runtimeId,
      'text': 'Corrected emulator prompt',
      'submission_id': editSubmit.$2['submission_id'],
      'profile': 'personal',
    });
    expect(source.runtime.execution, ChatExecution.running);
    harness.fixture.completeAnswerAction('personal', source.runtime.runtimeId);
    await _settle(tester);
    expect(source.composer.observation.text, 'Keep this unrelated draft');
    await _pumpUntil(
      tester,
      () => find
          .text('Corrected emulator prompt', findRichText: true)
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.text('Corrected emulator prompt', findRichText: true),
      findsOneWidget,
    );

    await _pumpUntil(
      tester,
      () =>
          source.reading.messages.last['role'] == 'assistant' &&
          answerMessageText(source.reading.messages.last) ==
              'Acknowledged Corrected emulator prompt',
    );
    final sourceAnswerId = answerMessageId(source.reading.messages.last)!;
    final sourceActions = find.byKey(
      ValueKey('answer-actions-$sourceAnswerId'),
    );
    final branchesBeforeRegenerate = harness.fixture.answerActionRequests
        .where(
          (request) =>
              request.$1 == 'session.mutate' &&
              request.$2['operation'] == 'branch',
        )
        .length;
    final submitsBeforeRegenerate = harness.fixture.answerActionRequests
        .where((request) => request.$1 == 'prompt.submit')
        .length;
    await Scrollable.ensureVisible(
      tester.element(sourceActions),
      alignment: .5,
    );
    await _settle(tester);
    await tapJourneyControl(
      tester,
      find.descendant(
        of: sourceActions,
        matching: find.byTooltip('Regenerate response'),
      ),
    );
    await _pumpUntil(
      tester,
      () =>
          harness.fixture.answerActionRequests
                  .where((request) => request.$1 == 'prompt.submit')
                  .length >
              submitsBeforeRegenerate &&
          !source.runtime.changingAnswer,
    );
    expect(harness.controller.current!.chat, same(source));
    expect(
      harness.fixture.answerActionRequests.where(
        (request) =>
            request.$1 == 'session.mutate' &&
            request.$2['operation'] == 'branch',
      ),
      hasLength(branchesBeforeRegenerate),
    );
    final regeneratedSubmit = harness.fixture.answerActionRequests
        .where((request) => request.$1 == 'prompt.submit')
        .last;
    expect(regeneratedSubmit.$2['session_id'], source.runtime.runtimeId);
    expect(regeneratedSubmit.$2['text'], 'Corrected emulator prompt');
    expect(regeneratedSubmit.$2['profile'], 'personal');
    harness.fixture.completeAnswerAction('personal', source.runtime.runtimeId);
    await _settle(tester);
    expect(find.byTooltip('Previous answer'), findsNothing);
    expect(find.byTooltip('Next answer'), findsNothing);
    await tapJourneyControl(tester, find.byTooltip('Chat actions'));
    await _settle(tester);
    expect(find.text('Parent chat'), findsNothing);
    await tester.tapAt(Offset.zero);
    await _settle(tester);
    expect(harness.controller.current!.chat, same(source));
    expect(source.composer.observation.text, 'Keep this unrelated draft');

    final submitsBeforeBranch = harness.fixture.answerActionRequests
        .where((request) => request.$1 == 'prompt.submit')
        .length;
    final regeneratedAnswerId = answerMessageId(source.reading.messages.last)!;
    final regeneratedActions = find.byKey(
      ValueKey('answer-actions-$regeneratedAnswerId'),
    );
    await Scrollable.ensureVisible(
      tester.element(regeneratedActions),
      alignment: .5,
    );
    await _settle(tester);
    await tapJourneyControl(
      tester,
      find.descendant(
        of: regeneratedActions,
        matching: find.byTooltip('Branch in new session'),
      ),
    );
    await _pumpUntil(tester, () => harness.controller.current!.chat != source);
    final ordinaryBranch = harness.controller.current!.chat!;
    await _pumpUntil(tester, () => !source.runtime.changingAnswer);
    await _settle(tester);
    final ordinaryBranchRequest = harness.fixture.answerActionRequests
        .where(
          (request) =>
              request.$1 == 'session.mutate' &&
              request.$2['operation'] == 'branch',
        )
        .last;
    expect(ordinaryBranchRequest.$2['payload'], {
      'through_message_id': regeneratedAnswerId,
    });
    expect(
      harness.fixture.answerActionRequests.where(
        (request) => request.$1 == 'prompt.submit',
      ),
      hasLength(submitsBeforeBranch),
    );
    await tapJourneyControl(tester, find.byTooltip('Chat actions'));
    await _settle(tester);
    await tapJourneyControl(tester, find.text('Parent chat'));
    await _settle(tester);
    expect(harness.controller.current!.chat, same(source));
    expect(ordinaryBranch.parentSessionId, source.key.sessionId);

    await tester.enterText(
      find.byKey(const Key('profile-message-composer')),
      'Continue in emulator fork',
    );
    final submitsBeforeFork = harness.fixture.answerActionRequests
        .where((request) => request.$1 == 'prompt.submit')
        .length;
    // The canonical owner requires idle before copying the saved answer.
    emitChatEvent(harness.controller, source, 'message.start');
    expect(harness.controller.canBranchAnswer(source), isFalse);
    harness.fixture.completeAnswerAction('personal', source.runtime.runtimeId);
    await _settle(tester);
    expect(harness.controller.canBranchAnswer(source), isTrue);
    harness.fixture.branchGate = Completer<void>();
    harness.fixture.branchEntered = Completer<void>();
    await Scrollable.ensureVisible(
      tester.element(regeneratedActions),
      alignment: .5,
    );
    await _settle(tester);
    await tapJourneyControl(
      tester,
      find.descendant(
        of: regeneratedActions,
        matching: find.byTooltip('Branch in new session'),
      ),
    );
    await tester.pump();
    expect(find.text('New chat'), findsOneWidget);
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is StudioLoading && widget.label == 'Forking chat',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('profile-message-composer')), findsNothing);
    await _pumpUntil(tester, () => harness.fixture.branchEntered!.isCompleted);
    expect(source.runtime.execution, ChatExecution.completed);
    expect(source.composer.observation.text, 'Continue in emulator fork');
    harness.fixture.branchGate!.complete();
    await _pumpUntil(tester, () => harness.controller.current!.chat != source);
    final forked = harness.controller.current!.chat!;
    await _pumpUntil(tester, () => !source.runtime.changingAnswer);
    await _settle(tester);
    expect(
      harness.fixture.answerActionRequests.where(
        (request) => request.$1 == 'prompt.submit',
      ),
      hasLength(submitsBeforeFork),
    );
    expect(forked.composer.observation.text, isEmpty);
    await captureJourney(tester, 'forked-chat');
    await tester.enterText(
      find.byKey(const Key('profile-message-composer')),
      'Continue in emulator fork',
    );
    await _settle(tester);
    await tapJourneyControl(tester, find.byTooltip('Send'));
    await _pumpUntil(
      tester,
      () => harness.fixture.answerActionRequests.any(
        (request) =>
            request.$1 == 'prompt.submit' &&
            request.$2['session_id'] == forked.runtime.runtimeId,
      ),
    );
    final forkSubmits = harness.fixture.answerActionRequests
        .where((request) => request.$1 == 'prompt.submit')
        .skip(submitsBeforeFork)
        .toList();
    expect(forkSubmits, hasLength(1));
    expect(forkSubmits.single.$2, {
      'session_id': forked.runtime.runtimeId,
      'submission_id': forkSubmits.single.$2['submission_id'],
      'text': 'Continue in emulator fork',
      'profile': 'personal',
    });
    final forkBranchRequest = harness.fixture.answerActionRequests
        .where(
          (request) =>
              request.$1 == 'session.mutate' &&
              request.$2['operation'] == 'branch',
        )
        .last;
    expect(forkBranchRequest.$2['payload'], {
      'through_message_id': regeneratedAnswerId,
    });
    expect(source.composer.observation.text, 'Continue in emulator fork');
    expect(forked.parentSessionId, source.key.sessionId);
    await tapJourneyControl(tester, find.byTooltip('Chat actions'));
    await _settle(tester);
    await tapJourneyControl(tester, find.text('Parent chat'));
    await _settle(tester);
    expect(harness.controller.current!.chat, same(source));
    expect(source.composer.observation.text, 'Continue in emulator fork');
    expect(
      harness.fixture.calls.where(
        (request) => request.$2 == 'session.answer_versions',
      ),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });
}

class _RoadmapHarness {
  final SharedPreferences preferences;
  final AppPreferences appPreferences;
  final ConnectionManager connectionManager;
  final RoadmapEmulatorFixture fixture;
  final ProfileWorkspaceRegistry registry;
  final HttpServer dashboard;
  final List<String> unexpectedRequests;
  late ProfileWorkspaceController controller;

  _RoadmapHarness({
    required this.preferences,
    required this.appPreferences,
    required this.connectionManager,
    required this.fixture,
    required this.registry,
    required this.dashboard,
    required this.unexpectedRequests,
  });

  static Future<_RoadmapHarness> create() async {
    final preferences = await SharedPreferences.getInstance();
    final credentialStore = RoadmapMemoryCredentialStore();
    final connectionManager = await ConnectionManager.create(
      preferences,
      credentialStore: credentialStore,
    );
    final dashboard = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final unexpectedRequests = <String>[];
    dashboard.listen((request) async {
      if (request.method == 'GET' && request.uri.path == '/') {
        request.response.write(
          'window.__HERMES_SESSION_TOKEN__="roadmap-only";',
        );
      } else if (request.method == 'GET' && request.uri.path == '/api/health') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'ok': true, 'version': '1.2.3'}));
      } else if (request.method == 'GET' &&
          request.uri.path == '/api/profiles') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'profiles': [
              for (final name in ['personal', 'work']) {'name': name},
            ],
          }),
        );
      } else if (request.method == 'GET' &&
          request.uri.path == '/api/hermes/update/check') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'current_version': '1.2.3',
            'update_available': false,
            'behind': 0,
            'can_apply': true,
          }),
        );
      } else {
        unexpectedRequests.add('${request.method} ${request.uri.path}');
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    final connection = SavedConnection(
      id: 'roadmap-emulator',
      label: 'Roadmap fixture',
      host: '127.0.0.1',
      port: dashboard.port,
      dashboardPortOverride: dashboard.port,
      apiKey: '',
    );
    await connectionManager.importConnections(
      [connection],
      replaceExisting: true,
      canCommit: () => true,
    );
    await preferences.setString('last_connection_id', connection.id);
    final fixture = RoadmapEmulatorFixture();
    final appPreferences = AppPreferences(preferences);
    final registry = ProfileWorkspaceRegistry(
      identities: ProfileConnectionIdentity(credentialStore: credentialStore),
      create: (saved, identity) => ProfileWorkspaceController(
        access: ConnectionAccess(connection: saved, dashboardOAuth: null),
        connectionIdentity: identity,
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: fixture.gateway,
      ),
    );
    final harness = _RoadmapHarness(
      preferences: preferences,
      appPreferences: appPreferences,
      connectionManager: connectionManager,
      fixture: fixture,
      registry: registry,
      dashboard: dashboard,
      unexpectedRequests: unexpectedRequests,
    );
    harness.controller = await registry.forConnection(connection);
    return harness;
  }

  Future<void> launch(WidgetTester tester) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    // WingApp discovers Bots through its administration owner independently of
    // the chat gateway. These journeys have an explicitly empty local roster.
    final base = AdministrationFixture('Roadmap fixture');
    addTearDown(base.server.close);
    final server = AdministrationRepository(
      connectionId: controller.connection.id,
      connectionIdentity: controller.connectionIdentity,
      connectionLabel: controller.connection.label,
      request: (method, path, query, body) => path.startsWith('git/')
          ? fixture.gitReview.readGit(method, path, query, body)
          : base.server.request(method, path, query, body),
      settingsWrite: base.server.settingsWrite,
      ownedMutation: base.server.ownedMutation,
      gateway: (profile) {
        final source = fixture.gateway(
          WorkspaceScope(
            connectionId: controller.connection.id,
            connectionIdentity: controller.connectionIdentity,
            profileName: profile,
          ),
        );
        return ProfileGateway(
          scope: source.scope,
          discover: source.discover,
          close: source.close,
          get: (path, query) async =>
              throw StateError('Unexpected administration read: $path'),
          rpc: (method, params) async => switch (method) {
            'profiles.list' => {
              'bot_mode_protocol': true,
              'install_id': controller.connectionIdentity,
              'profiles': <Map<String, dynamic>>[],
            },
            'groups.list' => {'rooms': <Map<String, dynamic>>[]},
            _ => await source.call(method, params),
          },
        );
      },
    );
    addTearDown(server.close);
    controller.healthSession(repository: server);
    await tester.pumpWidget(
      journeyCaptureBoundary(
        WingApp(
          connManager: connectionManager,
          profileControllers: registry,
          appPreferences: appPreferences,
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byType(ProfileWorkspaceScreen).evaluate().isNotEmpty,
    );
    await _pumpUntil(
      tester,
      () => controller.current != null && !controller.switching,
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('chat-profile-personal'))
          .hitTestable()
          .evaluate()
          .isNotEmpty,
    );
    // The unfiltered browser contains both profiles; their equal timestamps
    // do not promise an ordering. Enter the intended profile through its chip.
    await tapJourneyControl(
      tester,
      find.byKey(const ValueKey('chat-profile-personal')),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('chat-personal-chat-3'))
          .evaluate()
          .isNotEmpty,
    );
    await _revealChat(tester, 'personal', 'chat-0');
    await _settle(tester);
  }

  /// Exercise the production administration and drawer routes with both of
  /// their transport owners injected. The app's ordinary navigation is covered
  /// by the other journeys; this shell cannot contact a real server.
  Future<void> launchAdministration(WidgetTester tester) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await controller.initialize();
    final base = AdministrationFixture('Roadmap fixture');
    addTearDown(base.server.close);
    late final AdministrationRepository server;
    server = AdministrationRepository(
      ownedMutation:
          (method, path, query, body, canDispatch, onDispatched) async {
            if (!canDispatch()) {
              throw DashboardRequestNotSentException(
                StateError('Administration visit retired'),
              );
            }
            onDispatched();
            return server.request(method, path, query, body);
          },
      settingsWrite: base.server.settingsWrite,
      connectionId: controller.connection.id,
      connectionIdentity: controller.connectionIdentity,
      connectionLabel: controller.connection.label,
      request: (method, path, query, body) async {
        if (method == 'GET' && path == 'profiles') {
          return {
            'profiles': [
              {'name': 'personal', 'path': '/fixture/personal'},
            ],
          };
        }
        if (method == 'GET' && path == 'profiles/active') {
          return {'current': 'personal', 'active': 'personal'};
        }
        if (method == 'GET' && path == 'profiles/personal/soul') {
          return {'content': fixture.profileSoul, 'exists': true};
        }
        if (method == 'GET' && path == 'files/read') {
          expectSync(query, {'path': '/fixture/personal/profile.yaml'});
          final bytes = utf8.encode(
            'description: ${jsonEncode(fixture.profileDescription)}\n',
          );
          return {
            'name': 'profile.yaml',
            'path': '/fixture/personal/profile.yaml',
            'size': bytes.length,
            'mime_type': 'application/octet-stream',
            'data_url':
                'data:application/octet-stream;base64,${base64Encode(bytes)}',
          };
        }
        if (method == 'PUT' && path == 'profiles/personal/description') {
          fixture.profileIdentityWrites.add((
            path,
            Map<String, dynamic>.from(body!),
          ));
          fixture.profileDescription = body['description'] as String;
          return {
            'ok': true,
            'description': fixture.profileDescription,
            'description_auto': false,
          };
        }
        if (method == 'PUT' && path == 'profiles/personal/soul') {
          fixture.profileIdentityWrites.add((
            path,
            Map<String, dynamic>.from(body!),
          ));
          throw DashboardHttpException(403, path);
        }
        if (method == 'GET' &&
            const {'analytics/models', 'analytics/usage'}.contains(path)) {
          final reader = fixture.gateway(
            WorkspaceScope(
              connectionId: controller.connection.id,
              connectionIdentity: controller.connectionIdentity,
              profileName: query['profile']!,
            ),
          );
          try {
            return await reader.read(path, query);
          } finally {
            reader.close();
          }
        }
        if (method == 'GET' &&
            const {
              'actions/doctor/status',
              'actions/security-audit/status',
            }.contains(path)) {
          expectSync(query, {'lines': '2000'});
          return fixture.readDiagnosticStatus(path, query);
        }
        if (method == 'POST' &&
            const {'ops/doctor', 'ops/security-audit'}.contains(path)) {
          expectSync(query, isEmpty);
          return fixture.startDiagnostic(path, body ?? const {});
        }
        return base.send(method, path, query, body);
      },
      gateway: (name) => fixture.gateway(
        WorkspaceScope(
          connectionId: controller.connection.id,
          connectionIdentity: controller.connectionIdentity,
          profileName: name,
        ),
      ),
    );
    final scaffold = GlobalKey<ScaffoldState>();
    var destination = AppDestination.administration;
    addTearDown(server.close);
    await tester.pumpWidget(
      journeyCaptureBoundary(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: wingTheme(
            journeyTheme == 'dark' ? Brightness.dark : Brightness.light,
          ),
          home: StatefulBuilder(
            builder: (context, update) => Scaffold(
              key: scaffold,
              appBar: destination == AppDestination.administration
                  ? null
                  : AppBar(
                      leading: IconButton(
                        tooltip: 'Open navigation menu',
                        icon: const Icon(Icons.menu),
                        onPressed: () => scaffold.currentState!.openDrawer(),
                      ),
                      title: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(destination.label),
                          Text(
                            server
                                .profile(controller.current!.scope.profileName)
                                .label,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
              drawer: AppDrawer(
                selected: destination,
                onSelected: (selected) {
                  expectSync(const {
                    AppDestination.administration,
                    AppDestination.health,
                    AppDestination.analytics,
                  }, contains(selected));
                  update(() => destination = selected);
                },
                access: controller.access,
                connectionStatus: controller.connectionStatus,
                versionsControllerFactory: (_) =>
                    VersionsController(gateway: server.gateway('default')),
              ),
              body: switch (destination) {
                AppDestination.health => HermesHealthContent(
                  controller: controller,
                  repository: server,
                  onOpenMenu: () => scaffold.currentState!.openDrawer(),
                  onConnections: () {},
                  onOpenSession: (key) async {
                    await controller.openSession(key);
                  },
                ),
                AppDestination.analytics => HermesAnalyticsContent(
                  controller: controller,
                  repository: server,
                ),
                _ => HermesAdministrationContent(
                  controller: controller,
                  repository: server,
                  onOpenMenu: () => scaffold.currentState!.openDrawer(),
                  onConnections: () {},
                  onOpenSession: (key) async {
                    await controller.openSession(key);
                  },
                ),
              },
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
  }

  Future<void> dispose() async {
    registry.dispose();
    fixture.gitReview.server.close();
    appPreferences.dispose();
    await dashboard.close(force: true);
    expect(unexpectedRequests, isEmpty);
  }
}

// Android merges passive chart rows into one semantics node. Check each row's
// exact annotation and visible descendant value independently of that merge.
Finder _usageChartRow(String label) => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.label == label,
  description: 'usage chart row labeled "$label"',
);

Future<void> _navigate(WidgetTester tester, AppDestination destination) async {
  await tapJourneyControl(tester, find.byTooltip('Open navigation menu'));
  await _settle(tester);
  final item = find.byKey(ValueKey('nav-${destination.name}'));
  await tester.ensureVisible(item);
  await tapJourneyControl(tester, item);
  await _settle(tester);
}

Future<void> _revealChat(WidgetTester tester, String profile, String id) async {
  await tester.scrollUntilVisible(
    find.byKey(ValueKey('chat-$profile-$id')),
    180,
    scrollable: find.descendant(
      of: find.byKey(const ValueKey('chat-list-false')),
      matching: find.byType(Scrollable),
    ),
  );
  await _settle(tester);
}

Future<void> _chooseComposerAction(WidgetTester tester, String action) async {
  await _settle(tester);
  final gesture = await tester.startGesture(
    tester.getCenter(find.byType(ComposerActionButton)),
  );
  await _pumpUntil(
    tester,
    () => find.byKey(ValueKey('composer-choice-$action')).evaluate().isNotEmpty,
  );
  await gesture.moveTo(
    tester.getCenter(find.byKey(ValueKey('composer-choice-$action'))),
  );
  await tester.pump();
  await gesture.up();
  await _settle(tester);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  await tester.pump();
  final deadline = tester.binding.clock.now().add(timeout);
  while (!condition() && tester.binding.clock.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  }
  expect(
    condition(),
    isTrue,
    reason:
        'Roadmap journey condition did not complete within $timeout; '
        'visible text: ${tester.widgetList<Text>(find.byType(Text).hitTestable()).map((widget) => widget.data).toList()}; '
        'tiles: ${tester.widgetList<ListTile>(find.byType(ListTile)).map((widget) => widget.key).toList()}',
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<T> _journeyStep<T>(String name, Future<T> Function() action) async {
  debugPrint('Journey step started: $name');
  final value = await action().timeout(
    const Duration(seconds: 15),
    onTimeout: () {
      throw TestFailure('Journey step timed out after 15 seconds: $name');
    },
  );
  debugPrint('Journey step completed: $name');
  return value;
}

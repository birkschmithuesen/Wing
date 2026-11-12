import 'helpers/journey_controls.dart'
    show dragTranscriptToControl, dragViewportToControl;
import 'package:wing/core/widgets/gateway_clarify_dialog.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'dart:async';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import 'support/form_family_capture.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;
import '../integration_test/support/roadmap_emulator_fixture.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/widgets/conversation_page.dart';
import 'package:wing/core/widgets/wing_app_bar.dart';
import 'package:wing/core/widgets/composer_action_button.dart';

void main() {
  setUpAll(loadFormFamilyFonts);
  for (final brightness in Brightness.values) {
    for (final (geometry, bodyHeight, scale) in <(String, double?, double)>[
      ('portrait', null, 1.3),
      ('minimum', 96, 1),
      ('minimum-large', 96, 2),
      ('landscape', 102, 1),
      ('landscape-large', 102, 2),
      ('roomy', 176, 1),
      ('roomy-large', 176, 2),
    ]) {
      testWidgets(
        'pending input remains reachable with native keyboard and work dock $geometry ${brightness.name}',
        (tester) async {
          final landscape = bodyHeight != null;
          final keyboardHeight = landscape ? 240.0 : 332.190476;
          tester.view.physicalSize = landscape
              ? const Size(844, 390)
              : const Size(411.428571, 731.428571);
          tester.view.devicePixelRatio = 1;
          final safeTop = landscape ? 0.0 : 24.0;
          tester.view.viewPadding = FakeViewPadding(
            top: safeTop,
            bottom: landscape ? 0 : 24,
          );
          tester.view.padding = FakeViewPadding(
            top: safeTop,
            bottom: landscape ? 0 : 24,
          );
          addTearDown(tester.view.reset);
          SharedPreferences.setMockInitialValues({});
          final host = RoadmapEmulatorFixture();
          final preferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(preferences);
          addTearDown(appPreferences.dispose);
          final controller = ProfileWorkspaceController(
            access: ConnectionAccess(
              connection: identityTestConnection(),
              dashboardOAuth: null,
            ),
            connectionIdentity: 'native-input-layout',
            preferences: preferences,
            appPreferences: appPreferences,
            gatewayFactory: host.gateway,
          );
          addTearDown(controller.dispose);
          await controller.initialize();
          final chat = await openFixtureChat(
            controller: controller,
            key: ProfileSessionKey(controller.current!.scope, 'chat-0'),
          );
          emitChatEvent(controller, chat, 'clarify', {
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
          await tester.pumpWidget(
            RepaintBoundary(
              key: formFamilyCapture,
              child: MaterialApp(
                theme: profileWorkspaceTheme(ThemeData(brightness: brightness)),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: ProfileWorkspaceScreen(
                  controller: controller,
                  createBotsSession: () => BotsSession((_) async => const []),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (final choice in ['Compact', 'Dark']) {
            await tester.ensureVisible(find.text(choice));
            await tester.pumpAndSettle();
            await tester.tap(find.text(choice));
            await tester.pump();
          }
          final composer = find.byKey(const Key('profile-message-composer'));
          await tester.tap(composer);
          await tester.enterText(composer, 'Keep this unrelated draft');
          if (bodyHeight != null) {
            final header = tester.widget<WingAppBar>(find.byType(WingAppBar));
            tester.view.physicalSize = Size(
              844,
              bodyHeight + keyboardHeight + header.preferredSize.height,
            );
          }
          tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
          tester.view.padding = FakeViewPadding(top: safeTop);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(chat.subagents, isNotEmpty);
          final footer = tester.getRect(find.byType(ConversationFooter));
          final composerAction = find.descendant(
            of: find.byType(ComposerActionButton),
            matching: find.byType(IconButton),
          );
          await dragViewportToControl(
            tester,
            find.byType(ConversationFooter),
            composerAction,
          );
          expect(composerAction.hitTestable(), findsOneWidget);
          final actionBounds = tester.getRect(composerAction);
          expect(
            tester.getSize(composerAction).height,
            greaterThanOrEqualTo(48),
          );
          expect(footer.contains(actionBounds.topLeft), isTrue);
          expect(
            footer.contains(actionBounds.bottomRight - const Offset(.1, .1)),
            isTrue,
          );
          if (bodyHeight != null) {
            expect(
              tester.getSize(find.byType(ConversationLayout)).height,
              closeTo(bodyHeight, .01),
            );
          }
          final inputNavigation = find.byKey(const ValueKey('jump-to-latest'));
          if (inputNavigation.hitTestable().evaluate().isNotEmpty) {
            await tester.tap(inputNavigation);
            await tester.pumpAndSettle();
          }
          final confirm = find.byKey(const Key('clarify-continue'));
          await dragTranscriptToControl(tester, confirm);
          expect(confirm.hitTestable(), findsOneWidget);
          expect(tester.getSize(confirm).height, greaterThanOrEqualTo(48));
          expect(chat.composer.observation.text, 'Keep this unrelated draft');
          await captureFormFamily(
            tester,
            'clarify-native-keyboard-work-dock-$geometry-${brightness.name}',
          );
          final first = host.clarificationLockGate = Completer<void>();
          final retry = host.clarificationRetryGate = Completer<void>();
          addTearDown(() {
            if (!first.isCompleted) first.complete();
            if (!retry.isCompleted) retry.complete();
          });
          Future<void> until(bool Function() ready) async {
            await tester.pump();
            for (var attempt = 0; attempt < 100 && !ready(); attempt++) {
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(ready(), isTrue);
            expect(tester.takeException(), isNull);
          }

          await tester.tap(confirm);
          await until(() => host.clarificationLocks.length == 1);
          expect(
            find.descendant(
              of: confirm,
              matching: find.byType(CircularProgressIndicator),
            ),
            findsOneWidget,
          );
          first.complete();
          await until(
            () => find.byKey(const Key('clarify-error')).evaluate().isNotEmpty,
          );
          await until(
            () => find
                .text('Send failed. Try again.')
                .hitTestable()
                .evaluate()
                .isNotEmpty,
          );
          await captureFormFamily(
            tester,
            'clarify-native-keyboard-error-$geometry-${brightness.name}',
          );
          expect(chat.runtime.questions!.answeredIds, {'q1'});
          await dragTranscriptToControl(tester, confirm);
          expect(tester.view.viewInsets.bottom, keyboardHeight);
          expect(chat.composer.observation.text, 'Keep this unrelated draft');
          await captureFormFamily(
            tester,
            'clarify-native-keyboard-retry-$geometry-${brightness.name}',
          );
          host.failClarificationSecond = false;
          await tester.tap(confirm);
          await until(() => host.clarificationLocks.length == 3);
          expect(
            find.descendant(
              of: confirm,
              matching: find.byType(CircularProgressIndicator),
            ),
            findsOneWidget,
          );
          retry.complete();
          await until(() => chat.runtime.questions == null);
          expect(host.clarificationLocks.map((lock) => lock['question_id']), [
            'q1',
            'q2',
            'q2',
          ]);
          expect(chat.composer.observation.text, 'Keep this unrelated draft');
        },
      );
    }
  }
  testWidgets(
    'Continue admits one new continuation and retains a newer draft',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final host = Host();
      final prefs = await SharedPreferences.getInstance();
      final preferences = AppPreferences(prefs);
      addTearDown(preferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'continue',
        preferences: prefs,
        appPreferences: preferences,
        gatewayFactory: host.gateway,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final chat = await controller.createChat(canDispatch: () => true);
      host.event('a', 'message.start');
      host.event('a', 'message.complete', {
        'status': 'error',
        'error': 'Reply cut short',
        'error_surface': {'code': 'truncated', 'layer': 'streaming'},
      });
      await tester.pump();
      await chat.composer.editText('Keep my newer draft');
      final failure = chat.runtime.failure!;
      await controller.continueFailedTurn(chat, failure);
      expect(chat.composer.observation.text, 'Keep my newer draft');
      expect(
        host.calls
            .where((call) => call.$2 == 'prompt.submit')
            .map((call) => call.$3['text']),
        ['continue'],
      );
      await expectLater(
        controller.continueFailedTurn(chat, failure),
        throwsStateError,
      );
    },
  );
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'whole set stages all answers and retries only the unconfirmed lock $brightness $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          tester.view.viewInsets = const FakeViewPadding(bottom: 260);
          addTearDown(tester.view.reset);
          SharedPreferences.setMockInitialValues({});
          final host = Host();
          final preferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(preferences);
          addTearDown(appPreferences.dispose);
          final controller = ProfileWorkspaceController(
            access: ConnectionAccess(
              connection: identityTestConnection(),
              dashboardOAuth: null,
            ),
            connectionIdentity: 'whole-set',
            preferences: preferences,
            appPreferences: appPreferences,
            gatewayFactory: host.gateway,
          );
          addTearDown(controller.dispose);
          await controller.initialize();
          final chat = await controller.createChat(canDispatch: () => true);
          host.event('a', 'clarify', {
            'request_id': 'batch',
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
          await tester.pumpWidget(
            RepaintBoundary(
              key: formFamilyCapture,
              child: MaterialApp(
                theme: profileWorkspaceTheme(ThemeData(brightness: brightness)),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: scale == 2,
                  ),
                  child: child!,
                ),
                home: ProfileWorkspaceScreen(
                  controller: controller,
                  createBotsSession: () => BotsSession((_) async => const []),
                ),
              ),
            ),
          );
          expect(find.text('Which layout?'), findsOneWidget);
          expect(find.text('Which theme?'), findsOneWidget);
          await tester.ensureVisible(find.text('Compact'));
          await tester.pump();
          await tester.tap(find.text('Compact'));
          await tester.ensureVisible(find.text('Dark'));
          await tester.pump();
          await tester.tap(find.text('Dark'));
          await tester.pump();
          expect(host.calls.where((c) => c.$2 == 'clarify.lock'), isEmpty);
          final gate = Completer<void>();
          final retryGate = Completer<void>();
          var fail = true;
          chat.composer.editText('Preserve this unrelated draft');
          host.onClarifyResponse = () async {
            final q = host.calls.last.$3['question_id'];
            if (q == 'q1') {
              await gate.future;
              host.clarifyResult = {
                'status': 'ok',
                'remaining': ['q2'],
              };
            } else {
              if (fail) throw StateError('second answer failed');
              await retryGate.future;
              host.clarifyResult = {'status': 'ok', 'remaining': []};
            }
          };
          await tester.ensureVisible(find.byKey(const Key('clarify-continue')));
          await tester.pump();
          expect(
            tester
                .widget<IconButton>(find.byKey(const Key('clarify-continue')))
                .onPressed,
            isNotNull,
          );
          await tester.tap(find.byKey(const Key('clarify-continue')));
          await tester.pump();
          await tester.pump();
          expect(host.calls.where((c) => c.$2 == 'clarify.lock'), hasLength(1));
          expect(find.byType(CircularProgressIndicator), findsWidgets);
          await captureFormFamily(
            tester,
            'clarify-batch-pending-${brightness.name}-$scale',
          );
          gate.complete();
          await tester.pump();
          await tester.pump();
          expect(chat.runtime.questions!.answeredIds, {'q1'});
          expect(find.byKey(const Key('clarify-error')), findsOneWidget);
          await captureFormFamily(
            tester,
            'clarify-batch-failed-${brightness.name}-$scale',
          );
          fail = false;
          final confirm = find.byKey(const Key('clarify-continue'));
          final drags = await dragTranscriptToControl(tester, confirm);
          if (scale == 2) expect(drags, greaterThan(0));
          expect(confirm.hitTestable(), findsOneWidget);
          expect(
            chat.composer.observation.text,
            'Preserve this unrelated draft',
          );
          await captureFormFamily(
            tester,
            'clarify-batch-retry-${brightness.name}-$scale',
          );
          await tester.tap(confirm);
          await tester.pump();
          expect(
            find.descendant(
              of: confirm,
              matching: find.byType(CircularProgressIndicator),
            ),
            findsOneWidget,
          );
          expect(host.calls.last.$3['answer'], 'Dark');
          retryGate.complete();
          await tester.pump();
          await tester.pump();
          expect(
            host.calls
                .where((c) => c.$2 == 'clarify.lock')
                .map((c) => c.$3['question_id']),
            ['q1', 'q2', 'q2'],
          );
          expect(chat.runtime.questions, isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
  testWidgets('composer answer reacts to typing, held failure and retry', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final host = Host()..running = false;
    final preferences = await SharedPreferences.getInstance();
    final appPreferences = AppPreferences(preferences);
    addTearDown(appPreferences.dispose);
    final controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'composer-answer-ui',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final chat = await controller.createChat(canDispatch: () => true);
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    host.event('a', 'clarify', {
      'request_id': 'composer-question',
      'question': 'What should I prepare?',
    });
    await tester.pump();
    await tester.pump();
    final answer = find.byWidgetPredicate(
      (widget) =>
          widget is IconButton && widget.tooltip == 'Answer with composer text',
    );
    final editor = find.byKey(const Key('profile-message-composer'));
    expect(tester.widget<IconButton>(answer).onPressed, isNull);
    await tester.enterText(editor, 'Summary');
    await tester.pump();
    expect(controller.canAnswerWithComposer(chat), isTrue);
    expect(tester.widget<IconButton>(answer).onPressed, isNotNull);
    await tester.enterText(editor, '');
    await tester.pump();
    expect(tester.widget<IconButton>(answer).onPressed, isNull);
    await tester.enterText(editor, 'Summary');
    await tester.pump();
    var gate = Completer<void>();
    var fail = true;
    host.onClarifyResponse = () async {
      await gate.future;
      if (fail) throw StateError('Synthetic answer failure');
    };
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    await tester.ensureVisible(answer);
    await tester.tap(answer);
    await tester.pump();
    expect(
      find.descendant(
        of: answer,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(tester.widget<IconButton>(answer).onPressed, isNull);
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Synthetic answer failure'), findsOneWidget);
    expect(chat.composer.observation.text, 'Summary');
    expect(tester.widget<IconButton>(answer).onPressed, isNotNull);
    expect(
      find.descendant(
        of: answer,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    fail = false;
    gate = Completer<void>();
    await tester.ensureVisible(answer);
    await tester.tap(answer);
    await tester.pump();
    expect(
      find.descendant(
        of: answer,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(chat.runtime.pendingQuestion, isNull);
    expect(chat.composer.observation.text, isEmpty);
    expect(answer, findsNothing);
    expect(
      host.calls.where((call) => call.$2 == 'request.answer'),
      hasLength(2),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'desktop-resolved question closes after a pending snapshot overtakes skip $brightness/$scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          tester.view.viewInsets = const FakeViewPadding(bottom: 260);
          addTearDown(tester.view.reset);
          SharedPreferences.setMockInitialValues({});
          final host = Host();
          final preferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(preferences);
          addTearDown(appPreferences.dispose);
          final controller = ProfileWorkspaceController(
            access: ConnectionAccess(
              connection: identityTestConnection(),
              dashboardOAuth: null,
            ),
            connectionIdentity: 'test-identity',
            preferences: preferences,
            appPreferences: appPreferences,
            gatewayFactory: host.gateway,
          );
          addTearDown(controller.dispose);
          await controller.initialize();
          final chat = await controller.createChat(canDispatch: () => true);
          await tester.pumpWidget(
            RepaintBoundary(
              key: formFamilyCapture,
              child: MaterialApp(
                theme: profileWorkspaceTheme(ThemeData(brightness: brightness)),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: scale == 2,
                  ),
                  child: child!,
                ),
                home: ProfileWorkspaceScreen(controller: controller),
              ),
            ),
          );
          final question = {
            'questions': [
              {'qid': 'q0', 'question': 'Already answered on desktop?'},
            ],
          };
          host.event('a', 'clarify', {'request_id': 'request', ...question});
          await tester.pump();
          await tester.pump();
          final reply = Completer<void>();
          host.onClarifyResponse = () => reply.future;
          host.clarifyResult = {'status': 'expired'};
          final resume = Completer<void>();
          host.resumeDelay = resume;
          addTearDown(() {
            if (!resume.isCompleted) resume.complete();
          });
          await tester.ensureVisible(find.byKey(const Key('clarify-skip')));
          await tester.tap(find.byKey(const Key('clarify-skip')));
          await tester.pump();
          expect(
            find.descendant(
              of: find.byType(GatewayClarifyDialog),
              matching: find.byType(CircularProgressIndicator),
            ),
            findsOneWidget,
          );
          await captureFormFamily(
            tester,
            'clarify-${brightness.name}-$scale-held',
          );
          host.event('a', 'session.info', {
            'open_requests': [
              {
                'id': 'request',
                'method': 'clarify',
                'params': {'session_id': chat.runtime.runtimeId, ...question},
              },
            ],
          });
          await tester.pump();
          reply.complete();
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(chat.runtime.pendingQuestion, isNull);
          expect(find.byKey(const Key('clarify-skip')), findsNothing);
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget is StudioLoading && widget.label == 'Reconnecting',
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await captureFormFamily(
            tester,
            'clarify-${brightness.name}-$scale-closed',
          );
          resume.complete();
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(chat.runtime.pendingQuestion, isNull);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    'incoming question shows choices inline and confirms explicitly',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final host = Host();
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final controller = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: identityTestConnection(),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'test-identity',
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.createChat(canDispatch: () => true);
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            createBotsSession: () => BotsSession((_) async => const []),
            controller: controller,
          ),
        ),
      );
      host.event('a', 'clarify', {
        'request_id': 'request',
        'questions': [
          {
            'qid': 'q0',
            'question': 'Which review should I run?',
            'choices': ['Detailed review', 'Quick review'],
          },
        ],
      });
      await tester.pump();
      await tester.pump();
      expect(find.text('Detailed review'), findsOneWidget);
      expect(find.text('Quick review'), findsOneWidget);
      expect(find.text('Reply'), findsNothing);
      await tester.tap(find.text('Quick review'));
      await tester.pump();
      expect(host.calls.where((c) => c.$2 == 'clarify.lock'), isEmpty);
      await tester.ensureVisible(find.byKey(const Key('clarify-continue')));
      await tester.tap(find.byKey(const Key('clarify-continue')));
      await tester.pump();
      expect(host.calls.last.$2, 'clarify.lock');
      expect(host.calls.last.$3['question_id'], 'q0');
      expect(host.calls.last.$3['request_id'], 'request');
      expect(host.calls.last.$3['answer'], 'Quick review');
      expect(host.calls.last.$3['profile'], 'a');
      expect(find.text('Quick review'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

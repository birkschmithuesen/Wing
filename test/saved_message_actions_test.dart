import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/answer_versions.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/screens/profile_transcript.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/widgets/studio_error.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'answer_versions_test.dart' show AnswerHost;
import 'helpers/pump_markdown_widget.dart';

const _capture = bool.fromEnvironment('STUDIO_REVIEW');
const _reviewFrame = ValueKey('saved-edit-review-frame');

class _CaptureBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

void main() {
  if (_capture) _CaptureBinding();
  late AnswerHost host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat original;

  setUpAll(() async {
    if (!_capture) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'Ahem': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            Future.value(
              ByteData.sublistView(File(entry.value).readAsBytesSync()),
            ),
          ))
          .load();
    }
  });

  Future<void> capture(WidgetTester tester, String name) async {
    if (!_capture) return;
    await tester.pump();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_reviewFrame),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('build/chat-footer-review')
        ..createSync(recursive: true);
      await File(
        '${directory.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    host = AnswerHost();
    controller = ProfileWorkspaceController(
      connectionIdentity: 'host-settings',
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Host',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    await controller.openSession(
      ProfileSessionKey(controller.current!.scope, 'original'),
    );
    original = controller.current!.chat!;
  });

  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final compacted in [false, true]) {
        testWidgets(
          '${compacted ? 'compacted' : 'blocked'} branch explains why ${brightness.name} $scale',
          (tester) async {
            if (compacted) {
              host.addCompressedContext();
              await controller.refreshHistory(original);
            }
            await tester.binding.setSurfaceSize(const Size(390, 844));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            await tester.pumpWidget(
              RepaintBoundary(
                key: _reviewFrame,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: wingTheme(brightness),
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
            await tester.pumpAndSettle();
            await tester.settleMarkdown();
            emitChatEvent(controller, original, 'message.start');
            await tester.pump();
            final fork = find.descendant(
              of: find.byKey(ValueKey('answer-actions-${compacted ? 2 : 3}')),
              matching: find.byTooltip('Branch in new session'),
            );
            await tester.scrollUntilVisible(
              fork,
              200,
              scrollable: find
                  .descendant(
                    of: find.byType(ProfileTranscript),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
            await tester.ensureVisible(fork);
            await tester.pump(const Duration(milliseconds: 300));
            final before = tester.getRect(fork);
            await tester.tap(fork);
            await tester.pump();
            await tester.pump();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 200));
            await tester.pump(const Duration(milliseconds: 200));
            final reason = compacted
                ? 'This answer was archived when the chat was compressed. Branch from a more recent answer.'
                : 'Wait for this turn to finish, or stop it, before branching.';
            expect(find.text(reason), findsOneWidget);
            expect(find.text('New chat'), findsNothing);
            expect(
              host.calls.where((call) => call.$1 == 'session.mutate'),
              isEmpty,
            );
            expect(
              host.calls.where((call) => call.$1 == 'session.interrupt'),
              isEmpty,
            );
            expect(tester.getRect(fork), before);
            final notice = tester.getRect(
              find.widgetWithText(StudioError, reason),
            );
            expect(notice.overlaps(before), isFalse);
            expect(notice.left, greaterThanOrEqualTo(0));
            expect(notice.right, lessThanOrEqualTo(390));
            expect(notice.top, greaterThanOrEqualTo(0));
            expect(tester.takeException(), isNull);
            await capture(
              tester,
              'branch-${compacted ? 'compacted' : 'blocked'}-${brightness.name}-$scale',
            );

            await tester.pump(const Duration(seconds: 5));
            await tester.pump();
            expect(find.text(reason), findsNothing);
            await tester.tap(fork);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 200));
            expect(find.text(reason), findsOneWidget);

            emitChatEvent(controller, original, 'message.complete');
            await tester.pump();
            if (compacted) {
              await tester.tap(fork);
              await tester.pumpAndSettle();
              expect(find.text(reason), findsOneWidget);
              expect(host.parents, isEmpty);
              await tester.drag(
                find.widgetWithText(StudioError, reason),
                const Offset(400, 0),
              );
              await tester.pumpAndSettle();
              expect(find.text(reason), findsNothing);
              final newerFork = find.descendant(
                of: find.byKey(const ValueKey('answer-actions-103')),
                matching: find.byTooltip('Branch in new session'),
              );
              await tester.scrollUntilVisible(
                newerFork,
                -200,
                scrollable: find
                    .descendant(
                      of: find.byType(ProfileTranscript),
                      matching: find.byType(Scrollable),
                    )
                    .first,
              );
              await tester.ensureVisible(newerFork);
              await tester.pump(const Duration(milliseconds: 300));
              await tester.tap(newerFork);
            } else {
              await tester.tap(fork);
            }
            await tester.pumpAndSettle();
            expect(find.text(reason), findsNothing);
            expect(host.parents, hasLength(1));
            expect(controller.current!.chat, isNot(same(original)));
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('edit stays on sent messages and out of Fork and Find', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('edit-message-4')), findsOneWidget);
    expect(find.byTooltip('Edit prompt'), findsNothing);
    final reading = controller.openReadingSession(original);
    addTearDown(reading.dispose);
    await reading.start();
    reading.search('Follow-up');
    expect(reading.select(reading.observation.matches.single), isTrue);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Edit message'), findsNothing);
    expect(find.byTooltip('Restore checkpoint'), findsNothing);
    expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('${brightness.name} edit dialog at $scale above keyboard', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(320, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpWidget(
          RepaintBoundary(
            key: _reviewFrame,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
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
        final edit = find.byKey(const ValueKey('edit-message-4'));
        final transcriptScroll = find
            .descendant(
              of: find.byKey(const ValueKey('profile-transcript')),
              matching: find.byType(Scrollable),
            )
            .first;
        if (edit.evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            edit,
            160,
            scrollable: transcriptScroll,
          );
        }
        // Keep the target clear of both fixed chrome and the Latest overlay,
        // then finish the reversed transcript's layout before measuring it.
        await Scrollable.ensureVisible(tester.element(edit), alignment: 0.5);
        await tester.pumpAndSettle();
        expect(tester.widget<IconButton>(edit).onPressed, isNotNull);
        expect(edit.hitTestable(), findsOneWidget);
        await tester.tap(edit);
        await tester.pumpAndSettle();
        tester.view.viewInsets = FakeViewPadding(
          bottom: 240 * tester.view.devicePixelRatio,
        );
        await tester.pumpAndSettle();
        final submit = find.byTooltip('Replace message and resend');
        final close = find.byTooltip('Cancel');
        expect(tester.getRect(submit).bottom, lessThanOrEqualTo(400));
        expect(tester.getRect(close).top, greaterThanOrEqualTo(0));
        expect(tester.getSize(close).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(close).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
        await capture(tester, 'editor-${brightness.name}-$scale');
        final field = find.byKey(const ValueKey('saved-message-edit-input'));
        await tester.ensureVisible(field);
        await tester.enterText(field, 'Corrected follow-up');
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<IconButton>(
                find.ancestor(of: submit, matching: find.byType(IconButton)),
              )
              .onPressed,
          isNotNull,
        );
        host.mutationError = JsonRpcError(
          'session.mutate',
          'Session busy',
          reason: 'session_busy',
        );
        await tester.tap(submit);
        for (
          var i = 0;
          i < 100 &&
              (original.runtime.changingAnswer ||
                  !host.calls.any((call) => call.$1 == 'session.mutate'));
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 1));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
        }
        await tester.pumpAndSettle();
        final error = find.byKey(const ValueKey('edit-message-error'));
        await tester.ensureVisible(error);
        await tester.pumpAndSettle();
        expect(tester.widget<TextFormField>(field).enabled, isTrue);
        expect(tester.getRect(submit).bottom, lessThanOrEqualTo(400));
        expect(tester.getRect(close).top, greaterThanOrEqualTo(0));
        expect(
          tester.getRect(find.text('Edit message')).top,
          greaterThanOrEqualTo(0),
        );
        expect(tester.takeException(), isNull);
        await capture(tester, 'editor-error-${brightness.name}-$scale');
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('saved-message-edit-dialog')),
          findsNothing,
        );
      });
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('${brightness.name} Target chat and Restore at $scale', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(scale == 1 ? 390 : 320, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final timestamp =
            DateTime(2026, 10, 10, 16, 38).millisecondsSinceEpoch / 1000;
        host.history('a', 'original')
          ..clear()
          ..addAll([
            {
              'role': 'user',
              'text': 'is this an upstream issue?',
              'row_id': 1,
              'timestamp': timestamp,
            },
            {
              'role': 'tool',
              'text': 'Checked upstream issue and pull request.',
              'tool_name': 'terminal',
              'row_id': 2,
            },
            {
              'role': 'assistant',
              'text':
                  'Yes—and it is **already reported upstream with the same symptoms**.\n\nThe fix is still open. Updating alone will not resolve this yet.',
              'row_id': 3,
              'timestamp': timestamp + 60,
            },
          ]);
        await controller.refreshHistory(original);
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: _reviewFrame,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
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
        await tester.settleMarkdown();
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Yes—and', findRichText: true),
          findsOneWidget,
        );
        expect(find.text('10 Oct, 16:39'), findsOneWidget);
        final scrollable = find
            .descendant(
              of: find.byType(ProfileTranscript),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Scrollable &&
                    widget.axisDirection == AxisDirection.up,
              ),
            )
            .first;
        await tester.scrollUntilVisible(
          find.text('Activity · 1 tool'),
          200,
          scrollable: scrollable,
        );
        final answerCopy = find.descendant(
          of: find.byType(ProfileToolActivitySection),
          matching: find.byTooltip('Copy message'),
        );
        expect(answerCopy, findsOneWidget);
        expect(
          find.byTooltip('Copy message'),
          scale == 1 ? findsNWidgets(2) : findsWidgets,
        );
        await tester.ensureVisible(answerCopy);
        await tester.tap(answerCopy);
        await tester.pump();
        expect(copied, contains('already reported upstream'));
        expect(
          find.text('Checked upstream issue and pull request.'),
          findsNothing,
        );
        ScaffoldMessenger.of(tester.element(answerCopy)).hideCurrentSnackBar();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await capture(tester, 'target-answer-${brightness.name}-$scale');
        final restore = find.byKey(const ValueKey('restore-message-1'));
        await tester.scrollUntilVisible(restore, 200, scrollable: scrollable);
        final userMessage = find.ancestor(
          of: find.byKey(
            const ValueKey<(String, Object?)>(('user-message-bubble', 1)),
          ),
          matching: find.byType(ProfileMessage),
        );
        final userCopy = find.descendant(
          of: userMessage,
          matching: find.byTooltip('Copy message'),
        );
        await tester.ensureVisible(userCopy);
        expect(userCopy.hitTestable(), findsOneWidget);
        expect(find.text('10 Oct, 16:38'), findsOneWidget);
        await tester.pump();
        await capture(tester, 'target-${brightness.name}-$scale');
        await tester.tap(restore);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('restore-message-confirm')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await capture(tester, 'restore-${brightness.name}-$scale');
        await tester.tap(find.byKey(const ValueKey('restore-message-cancel')));
        await tester.pumpAndSettle();
        expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
      });
    }
  }

  test(
    'a confirmed depth cannot silently include newly appended turns',
    () async {
      final selected = original.reading.messages.first;
      host.history('a', 'original').add({
        'role': 'user',
        'text': 'Newer work',
        'row_id': 99,
      });
      expect(
        await controller.restoreSavedPrompt(
          original,
          selected,
          expectedLaterTurns: 1,
        ),
        isFalse,
      );
      expect(original.runtime.error, contains('Later work changed'));
      expect(host.calls.where((call) => call.$1 == 'session.mutate'), isEmpty);
      expect(host.history('a', 'original').last['text'], 'Newer work');
    },
  );

  test(
    'restore reruns the selected saved prompt, retaining draft and paused queue',
    () async {
      await controller.updateDraft(original, 'Keep this separate draft');
      await restoreComposerFixture(
        chat: original,
        preferences: controller.preferences,
        appendQueued: [QueuedPromptDraft(text: 'Queued followup')],
      );
      final prompt = original.reading.messages.first;
      expect(await controller.restoreSavedPrompt(original, prompt), isTrue);
      final submit = host.calls
          .lastWhere((call) => call.$1 == 'prompt.submit')
          .$2;
      expect(submit, {
        'session_id': 'runtime-original',
        'profile': 'a',
        'text': 'Original prompt',
        'submission_id': submit['submission_id'],
      });
      expect(submit['submission_id'], isNotEmpty);
      final rewind = host.calls
          .lastWhere((call) => call.$1 == 'session.mutate')
          .$2;
      expect(rewind['operation'], 'rewind');
      expect(rewind['payload'], {'target_message_id': 1});
      expect(host.history('a', 'original').first['text'], 'Original prompt');
      expect(
        host
            .history('a', 'original')
            .any((row) => row['text'] == 'Later answer'),
        isFalse,
      );
      expect(original.composer.observation.text, 'Keep this separate draft');
      expect(original.composer.observation.paused, isTrue);
      expect(
        original.composer.observation.queue.single.text,
        'Queued followup',
      );
      expect(
        host.calls.where(
          (call) =>
              call.$1 == 'session.mutate' && call.$2['operation'] == 'branch',
        ),
        isEmpty,
      );
    },
  );

  test(
    'restore refusal retains history and never resubmits as a new prompt',
    () async {
      final before = original.reading.messages.toList();
      host.mutationError = JsonRpcError(
        'session.mutate',
        'Target no longer exists',
        reason: 'revision_conflict',
      );
      expect(
        await controller.restoreSavedPrompt(original, before.first),
        isFalse,
      );
      expect(original.reading.messages, before);
      expect(original.runtime.error, contains('did not accept the restore'));
      expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
    },
  );

  for (final reason in ['not_found', 'profile_mismatch']) {
    for (final regenerate in [false, true]) {
      test(
        '${regenerate ? 'regenerate' : 'restore'} $reason refusal preserves history without an uncertain submission',
        () async {
          final before = original.reading.messages.toList();
          host.mutationError = JsonRpcError(
            'session.mutate',
            'The target is unavailable',
            code: 4001,
            reason: reason,
          );
          if (regenerate) {
            await expectLater(
              controller.branchAnswer(
                original,
                original.reading.messages.indexWhere(
                  (row) => row['role'] == 'assistant',
                ),
                regenerate: true,
                expectedLaterTurns: 1,
              ),
              throwsStateError,
            );
          } else {
            expect(
              await controller.restoreSavedPrompt(original, before.first),
              isFalse,
            );
          }
          expect(original.reading.messages, before);
          expect(original.runtime.error, contains('did not accept'));
          expect(original.runtime.error, isNot(contains('uncertain')));
          expect(original.runtime.reconnecting, isFalse);
          expect(
            host.calls.where((call) => call.$1 == 'session.mutate'),
            hasLength(1),
          );
          expect(
            host.calls.where((call) => call.$1 == 'prompt.submit'),
            isEmpty,
          );
        },
      );
    }
  }

  test(
    'restore transport uncertainty is not retried or rolled back as unsent',
    () async {
      host.submitError = JsonRpcError(
        'prompt.submit',
        'Disconnected',
        reason: 'connection_closed',
      );
      host.submitErrorAfterAcceptance = true;
      expect(
        await controller.restoreSavedPrompt(
          original,
          original.reading.messages.first,
        ),
        isFalse,
      );
      expect(original.runtime.error, contains('Restore status is uncertain'));
      expect(
        host.calls.where((call) => call.$1 == 'prompt.submit'),
        hasLength(1),
      );
    },
  );

  test('restore interrupts a live turn before its durable rewind', () async {
    emitChatEvent(controller, original, 'message.start');
    final prompt = original.reading.messages.first;
    expect(controller.canRestoreSavedPrompt(original, prompt), isTrue);
    expect(await controller.restoreSavedPrompt(original, prompt), isTrue);
    final interrupt = host.calls.indexWhere(
      (call) => call.$1 == 'session.interrupt',
    );
    final submit = host.calls.indexWhere((call) => call.$1 == 'prompt.submit');
    expect(interrupt, greaterThanOrEqualTo(0));
    expect(submit, greaterThan(interrupt));
  });

  test(
    'restore waits for confirmed idle after interrupt acknowledgement',
    () async {
      host.running = true;
      host.interruptRequested = Completer<void>();
      final firstRead = host.resumeDelay = Completer<void>();
      emitChatEvent(controller, original, 'message.start');
      final restoring = controller.restoreSavedPrompt(
        original,
        original.reading.messages.first,
        expectedLaterTurns: 1,
      );
      await host.interruptRequested!.future.timeout(const Duration(seconds: 3));
      expect(original.runtime.changingAnswer, isTrue);
      expect(host.calls.where((call) => call.$1 == 'session.mutate'), isEmpty);
      firstRead.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(host.calls.where((call) => call.$1 == 'session.mutate'), isEmpty);
      expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
      host.running = false;
      host.resumeDelay = null;
      expect(await restoring, isTrue);
      expect(
        host.calls.where((call) => call.$1 == 'session.interrupt'),
        hasLength(1),
      );
      expect(
        host.calls.where((call) => call.$1 == 'session.mutate'),
        hasLength(1),
      );
      expect(
        host.calls.where((call) => call.$1 == 'prompt.submit'),
        hasLength(1),
      );
    },
  );

  for (final changed in ['generation', 'runtime', 'depth']) {
    test(
      'restore refuses $changed changes while waiting for interrupt settlement',
      () async {
        host.running = true;
        host.interruptRequested = Completer<void>();
        final held = host.resumeDelay = Completer<void>();
        emitChatEvent(controller, original, 'message.start');
        final restoring = controller.restoreSavedPrompt(
          original,
          original.reading.messages.first,
          expectedLaterTurns: 1,
        );
        await host.interruptRequested!.future.timeout(
          const Duration(seconds: 3),
        );
        host.running = false;
        if (changed == 'generation') host.executionGeneration++;
        if (changed == 'runtime') {
          host.resumedRuntimeOverride = 'runtime-replacement';
        }
        if (changed == 'depth') {
          host.history('a', 'original').addAll([
            {'role': 'user', 'text': 'New later work', 'row_id': 100},
            {'role': 'assistant', 'text': 'New answer', 'row_id': 101},
          ]);
        }
        held.complete();
        expect(await restoring, isFalse);
        expect(
          host.calls.where((call) => call.$1 == 'session.mutate'),
          isEmpty,
        );
        expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
        expect(
          host.calls.where((call) => call.$1 == 'session.interrupt'),
          hasLength(1),
        );
      },
    );
  }

  test(
    'regeneration refuses a replacement physical prompt with identical text',
    () async {
      host.historyReads = 0;
      host.beforeHistoryRead = (count) {
        if (count != 2) return;
        final rows = host.history('a', 'original');
        rows[0] = {...rows[0], 'row_id': 900};
        rows[2] = {...rows[2], 'row_id': 901};
      };
      await expectLater(
        controller.branchAnswer(
          original,
          original.reading.messages.indexWhere(
            (row) => row['role'] == 'assistant',
          ),
          regenerate: true,
          expectedLaterTurns: 1,
        ),
        throwsStateError,
      );
      expect(host.calls.where((call) => call.$1 == 'session.mutate'), isEmpty);
      expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
      expect(host.history('a', 'original').first['row_id'], 900);
    },
  );

  for (final observedWorking in [false, true]) {
    test(
      'busy rewind is a definite refusal without resubmitting (observed working: $observedWorking)',
      () async {
        if (observedWorking) {
          emitChatEvent(controller, original, 'message.start');
        }
        final prompt = original.reading.messages.first;
        final before = original.reading.messages.toList();
        host.busySubmissions = 1;
        expect(await controller.restoreSavedPrompt(original, prompt), isFalse);
        expect(
          host.calls.where((call) => call.$1 == 'session.mutate'),
          hasLength(1),
        );
        expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
        expect(
          host.calls.where((call) => call.$1 == 'session.interrupt'),
          observedWorking ? hasLength(1) : isEmpty,
        );
        expect(original.reading.messages, before);
        expect(original.runtime.error, contains('did not accept the restore'));
      },
    );
  }

  test('restore requires a human prompt with a durable address', () async {
    for (final row in [
      {'role': 'user', 'text': 'Unpersisted'},
      {'role': 'assistant', 'text': 'Answer', 'row_id': 3},
      {'role': 'user', 'text': '', 'row_id': 4},
    ]) {
      expect(controller.canRestoreSavedPrompt(original, row), isFalse);
    }
    host.omitRowIds = true;
    expect(
      await controller.restoreSavedPrompt(
        original,
        original.reading.messages.first,
      ),
      isFalse,
    );
    expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
    expect(original.reading.messages, hasLength(5));
  });

  testWidgets(
    'restore is confirmed on the selected prompt; cancellation sends nothing',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => const []),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final restore = find.byKey(const ValueKey('restore-message-4'));
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(find.text('Restore to this checkpoint?'), findsOneWidget);
      expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
      await tester.tap(find.byTooltip('Cancel restore'));
      await tester.pumpAndSettle();
      expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      final confirm = find.byKey(const ValueKey('restore-message-confirm'));
      expect(tester.widget<IconButton>(confirm).onPressed, isNotNull);
      await tester.tap(confirm);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Restore to this checkpoint?'), findsNothing);
      for (var i = 0; i < 100 && original.runtime.changingAnswer; i++) {
        await tester.pump(const Duration(milliseconds: 1));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
      }
      expect(
        host.calls.where((call) => call.$1 == 'prompt.submit'),
        isNotEmpty,
        reason:
            'Restore error: ${original.runtime.error}; calls: ${host.calls.map((call) => call.$1).join(', ')}',
      );
      expect(
        host.calls
            .lastWhere((call) => call.$1 == 'session.mutate')
            .$2['payload']['target_message_id'],
        4,
      );
      expect(
        host.calls.lastWhere((call) => call.$1 == 'prompt.submit').$2['text'],
        'Follow-up',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('unchanged and empty edits do not rewind or pause the queue', () async {
    await restoreComposerFixture(
      chat: original,
      preferences: controller.preferences,
      appendQueued: [QueuedPromptDraft(text: 'Queued followup')],
    );
    final prompt = original.reading.messages.first;
    for (final text in ['', '  ', ' Original prompt ']) {
      expect(await controller.editSavedPrompt(original, prompt, text), isFalse);
    }
    expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
    expect(original.composer.observation.paused, isFalse);
    expect(original.reading.messages.first, prompt);
  });

  test('edit rewinds the addressed row and pauses queued followups', () async {
    await controller.updateDraft(original, 'Unrelated composer draft');
    await restoreComposerFixture(
      chat: original,
      preferences: controller.preferences,
      appendQueued: [QueuedPromptDraft(text: 'Queued followup')],
    );

    final accepted = await controller.editSavedPrompt(
      original,
      original.reading.messages.first,
      'Corrected prompt',
    );

    expect(accepted, isTrue);
    final submit = host.calls
        .lastWhere((call) => call.$1 == 'prompt.submit')
        .$2;
    expect(submit, {
      'session_id': 'runtime-original',
      'profile': 'a',
      'text': 'Corrected prompt',
      'submission_id': submit['submission_id'],
    });
    expect(submit['submission_id'], isNotEmpty);
    final rewind = host.calls
        .lastWhere((call) => call.$1 == 'session.mutate')
        .$2;
    expect(rewind['operation'], 'rewind');
    expect(rewind['payload'], {'target_message_id': 1});
    expect(original.composer.observation.text, 'Unrelated composer draft');
    expect(original.composer.observation.queue.single.text, 'Queued followup');
    expect(original.composer.observation.paused, isTrue);
    expect(original.reading.messages.map(answerMessageText), [
      'Corrected prompt',
    ]);
  });

  test('rejected edit restores history and keeps local work paused', () async {
    await controller.updateDraft(original, 'Keep this draft');
    await restoreComposerFixture(
      chat: original,
      preferences: controller.preferences,
      appendQueued: [QueuedPromptDraft(text: 'Keep this queued message')],
    );
    final before = List<Map<String, dynamic>>.of(original.reading.messages);
    final statusBefore = original.runtime.execution;
    final serverHistoryBefore = host
        .history('a', 'original')
        .map(Map<String, dynamic>.of)
        .toList();
    host.mutationError = JsonRpcError(
      'session.mutate',
      'Session busy',
      reason: 'session_busy',
    );

    final accepted = await controller.editSavedPrompt(
      original,
      original.reading.messages.first,
      'Rejected correction',
    );

    expect(accepted, isFalse);
    expect(original.reading.messages, before);
    expect(original.composer.observation.text, 'Keep this draft');
    expect(
      original.composer.observation.queue.single.text,
      'Keep this queued message',
    );
    expect(original.composer.observation.paused, isTrue);
    expect(original.runtime.execution, statusBefore);
    expect(host.history('a', 'original'), serverHistoryBefore);
    expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
    expect(original.runtime.reconnecting, isFalse);
  });

  test('lost edit acknowledgement is not reported as success', () async {
    await controller.updateDraft(original, 'Keep this unrelated draft');
    host.submitError = TimeoutException('connection lost');

    final accepted = await controller.editSavedPrompt(
      original,
      original.reading.messages.first,
      'Possibly delivered correction',
    );

    expect(accepted, isFalse);
    expect(original.runtime.reconnecting, isTrue);
    expect(original.composer.observation.text, 'Keep this unrelated draft');
    expect(original.runtime.error, contains('uncertain'));
  });

  for (final failure in [
    JsonRpcError('prompt.submit', 'Timeout', reason: 'request_timeout'),
    JsonRpcError(
      'prompt.submit',
      'Connection closed',
      reason: 'connection_closed',
    ),
    JsonRpcError('prompt.submit', 'Internal error', code: -32603),
    JsonRpcError(
      'prompt.submit',
      'Session storage could not be written',
      code: 5071,
    ),
  ]) {
    test(
      'edit reconciles accepted history after ${failure.reason ?? failure.code}',
      () async {
        await controller.updateDraft(original, 'Unrelated draft');
        await restoreComposerFixture(
          chat: original,
          preferences: controller.preferences,
          appendQueued: [QueuedPromptDraft(text: 'Keep queued followup')],
        );
        host.submitError = failure;
        host.submitErrorAfterAcceptance = true;

        final accepted = await controller.editSavedPrompt(
          original,
          original.reading.messages.first,
          'Delivered correction',
        );

        expect(accepted, isFalse);
        expect(original.runtime.reconnecting, isTrue);
        expect(original.runtime.error, contains('uncertain'));
        expect(original.reading.messages.map(answerMessageText), [
          'Delivered correction',
        ]);
        expect(original.composer.observation.paused, isTrue);

        host.resumeDelay = Completer<void>();
        final recovery = controller.reconnect(original.key.workspace);
        await controller.updateDraft(original, 'New draft during recovery');
        host.resumeDelay!.complete();
        await recovery;

        expect(original.reading.messages.map(answerMessageText), [
          'Delivered correction',
          'New answer 0',
        ]);
        expect(original.composer.observation.text, 'New draft during recovery');
        expect(
          original.composer.observation.queue.single.text,
          'Keep queued followup',
        );
        expect(original.composer.observation.paused, isTrue);
        expect(original.runtime.execution, ChatExecution.completed);
        final submits = host.calls
            .where((call) => call.$1 == 'prompt.submit')
            .toList();
        expect(submits, hasLength(2));
        expect(submits.last.$2, submits.first.$2);
        expect(host.admissionReceipts, hasLength(1));
      },
    );
  }

  testWidgets('saved user edit requires explicit history replacement', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final edit = find.byKey(const ValueKey('edit-message-4'));
    await tester.ensureVisible(edit);
    final target = tester.getRect(edit);
    expect(target.width, greaterThanOrEqualTo(48));
    expect(target.height, greaterThanOrEqualTo(32));
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final prompt = find.ancestor(
      of: edit,
      matching: find.byType(ProfileMessage),
    );
    final copy = find.descendant(
      of: prompt,
      matching: find.byTooltip('Copy message'),
    );
    final copyTarget = tester.getRect(copy);
    expect(copyTarget.width, greaterThanOrEqualTo(48));
    expect(copyTarget.height, greaterThanOrEqualTo(32));
    await tester.tapAt(Offset(copyTarget.right - 2, copyTarget.bottom - 2));
    await tester.pumpAndSettle();
    expect(copied, 'Follow-up');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.ensureVisible(edit);
    final visibleTarget = tester.getRect(edit);
    await tester.tapAt(
      Offset(visibleTarget.right - 2, visibleTarget.center.dy),
    );
    await tester.pumpAndSettle();

    expect(find.text('Edit message'), findsOneWidget);
    expect(
      find.text(
        "Resending replaces this message. This answer is replaced and the prompt runs again.",
      ),
      findsOneWidget,
    );
    expect(find.text('Follow-up'), findsWidgets);
    expect(find.byTooltip('Replace message and resend'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('Replace message and resend'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
  });

  testWidgets('rejected edit keeps the correction in the dialog', (
    tester,
  ) async {
    host.mutationError = JsonRpcError(
      'session.mutate',
      'Session busy',
      reason: 'session_busy',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final edit = find.byKey(const ValueKey('edit-message-4'));
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Corrected followup');
    await tester.pump();
    await tester.tap(find.byTooltip('Replace message and resend'));
    await tester.runAsync(() async {
      for (
        var i = 0;
        i < 100 &&
            (original.runtime.changingAnswer ||
                !host.calls.any((call) => call.$1 == 'session.mutate'));
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    });
    await tester.pump();

    expect(find.text('Edit message'), findsOneWidget);
    expect(find.text('Corrected followup'), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-message-error')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('edit-message-error')),
        matching: find.text('Hermes did not accept the edited message.'),
      ),
      findsOneWidget,
    );
  });

  for (final rejected in [false, true]) {
    testWidgets(
      'pending saved edit blocks dismissal and input until ${rejected ? 'refusal' : 'acceptance'}',
      (tester) async {
        final held = Completer<void>();
        if (rejected) {
          host.mutationDelay = held;
        } else {
          host.submitDelay = held;
        }
        if (rejected) {
          host.mutationError = JsonRpcError(
            'session.mutate',
            'Session busy',
            reason: 'session_busy',
          );
        }
        await tester.pumpWidget(
          MaterialApp(
            home: ProfileWorkspaceScreen(
              controller: controller,
              createBotsSession: () => BotsSession((_) async => const []),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final edit = find.byKey(const ValueKey('edit-message-4'));
        await tester.ensureVisible(edit);
        await tester.tap(edit);
        await tester.pumpAndSettle();
        final field = find.byKey(const ValueKey('saved-message-edit-input'));
        await tester.enterText(field, 'Retained correction');
        await tester.pump();
        await tester.tap(find.byTooltip('Replace message and resend'));
        await tester.pump();
        for (
          var i = 0;
          i < 100 && !host.calls.any((call) => call.$1 == 'session.mutate');
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 1));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
        }
        expect(
          host.calls.where((call) => call.$1 == 'session.mutate'),
          hasLength(1),
        );
        expect(original.runtime.changingAnswer, isTrue);
        expect(tester.widget<TextFormField>(field).enabled, isFalse);
        await tester.tapAt(const Offset(8, 8));
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(find.text('Edit message'), findsOneWidget);
        expect(
          find.descendant(
            of: field,
            matching: find.text('Retained correction'),
          ),
          findsOneWidget,
        );
        held.complete();
        for (
          var i = 0;
          i < 100 &&
              (original.runtime.changingAnswer ||
                  !host.calls.any((call) => call.$1 == 'session.mutate'));
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 1));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
        }
        // Accepted work keeps its live progress animation running. Render the
        // completed editor transition without waiting for that turn to finish.
        expect(original.runtime.changingAnswer, isFalse);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        if (!rejected) {
          expect(
            host.calls
                .singleWhere((call) => call.$1 == 'prompt.submit')
                .$2['text'],
            'Retained correction',
          );
        } else {
          expect(
            host.calls.where((call) => call.$1 == 'prompt.submit'),
            isEmpty,
          );
        }
        if (rejected) {
          expect(
            find.descendant(
              of: field,
              matching: find.text('Retained correction'),
            ),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('edit-message-error')),
            findsOneWidget,
          );
          expect(tester.widget<TextFormField>(field).enabled, isTrue);
        } else {
          expect(find.text('Edit message'), findsNothing);
        }
      },
    );
  }

  testWidgets('composer never offers fork; answer branching stays available', (
    tester,
  ) async {
    await controller.updateDraft(original, 'Composer followup');
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byTooltip('Send')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('composer-choice-fork')), findsNothing);
    expect(find.byTooltip('Branch in new session'), findsWidgets);
    await gesture.up();
    expect(
      host.calls.where(
        (call) =>
            call.$1 == 'session.mutate' && call.$2['operation'] == 'branch',
      ),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox());
  });
}

import 'support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import 'answer_versions_test.dart' show AnswerHost;

void main() {
  late _HeldPendingJournal platform;
  late AnswerHost host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;
  var disposed = false;

  setUp(() async {
    disposed = false;
    SharedPreferences.setMockInitialValues({});
    platform = _HeldPendingJournal();
    SharedPreferencesStorePlatform.instance = platform;
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    host = AnswerHost();
    controller = ProfileWorkspaceController(
      connectionIdentity: 'prompt-dispatch-closure',
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
    chat = controller.current!.chat!;
    await restoreComposerFixture(
      chat: chat,
      preferences: controller.preferences,
      appendQueued: [QueuedPromptDraft(text: 'Preserved follow-up')],
    );
    await chat.composer.pause();
    await controller.updateDraft(chat, 'Unrelated composer body');
  });

  tearDown(() {
    platform.release();
    if (!disposed) controller.dispose();
    appPreferences.dispose();
  });

  for (final regenerate in [true, false]) {
    test(
      '${regenerate ? 'regeneration' : 'saved prompt edit'} rejected after held journal cannot claim dispatch',
      () async {
        final transcript = chat.reading.messages
            .map(Map<String, dynamic>.of)
            .toList();
        final serverHistory = host
            .history('a', 'original')
            .map(Map<String, dynamic>.of)
            .toList();
        final status = chat.runtime.execution;
        platform.holdNext();
        final Future<Object?> pending = regenerate
            ? controller.branchAnswer(chat, 2, regenerate: true)
            : controller.editSavedPrompt(
                chat,
                chat.reading.messages.first,
                'Unsent replacement body',
              );
        await platform.entered!.future;
        expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
        disposed = true;
        controller.dispose();
        platform.release();
        Object? result, failure;
        try {
          result = await pending;
        } catch (error) {
          failure = error;
        }

        // Assert observable effects before checking the public rejection. A
        // zero-request failure must never leave a locally rewound transcript.
        expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
        expect(host.history('a', 'original'), serverHistory);
        expect(chat.reading.messages, transcript);
        expect(chat.runtime.execution, status);
        expect(chat.composer.observation.text, 'Unrelated composer body');
        expect(
          chat.composer.observation.queue.single.text,
          'Preserved follow-up',
        );
        expect(
          chat.composer.observation.queue.single.submissionUncertain,
          false,
        );
        expect(chat.composer.observation.paused, true);
        expect(chat.runtime.error, isNot(contains('uncertain')));
        if (regenerate) {
          expect(result, isNull);
          expect(failure, isA<StateError>());
        } else {
          expect(result, false);
          expect(failure, isNull);
        }
      },
    );
  }

  test(
    'saved prompt refusal restores an initially unpaused durable queue',
    () async {
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        paused: false,
      );
      await controller.updateDraft(chat, 'Unrelated composer body');
      final preferences = await SharedPreferences.getInstance();
      final drafts = ComposerDraftStore(
        preferences,
        connectionIdentity: 'prompt-dispatch-closure',
      );
      final opening = await drafts.read(
        profileName: 'a',
        sessionId: 'original',
      );
      expect(opening!.queuePaused, false);
      final transcript = chat.reading.messages
          .map(Map<String, dynamic>.of)
          .toList();
      final serverHistory = host
          .history('a', 'original')
          .map(Map<String, dynamic>.of)
          .toList();
      final status = chat.runtime.execution;
      platform.holdNext();
      final pending = controller.editSavedPrompt(
        chat,
        chat.reading.messages.first,
        'Unsent replacement body',
      );
      await platform.entered!.future;
      expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
      disposed = true;
      controller.dispose();
      platform.release();
      Object? result, failure;
      try {
        result = await pending;
      } catch (error) {
        failure = error;
      }
      final durable = await drafts.read(
        profileName: 'a',
        sessionId: 'original',
      );

      // A definite no-dispatch result must preserve both live and persisted work
      // before the public rejection is inspected.
      expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
      expect(host.history('a', 'original'), serverHistory);
      expect(chat.reading.messages, transcript);
      expect(chat.runtime.execution, status);
      expect(chat.composer.observation.text, 'Unrelated composer body');
      expect(
        chat.composer.observation.queue.single.text,
        'Preserved follow-up',
      );
      expect(chat.composer.observation.queue.single.submissionUncertain, false);
      expect(chat.composer.observation.paused, false);
      expect(durable, isNotNull);
      expect(durable!.text, opening.text);
      expect(durable.queuePaused, false);
      expect(durable.submissionUncertain, false);
      expect(
        durable.queuedPrompts.single.text,
        opening.queuedPrompts.single.text,
      );
      expect(durable.queuedPrompts.single.submissionUncertain, false);
      expect(chat.runtime.error, isNot(contains('uncertain')));
      expect(result, false);
      expect(failure, isNull);
    },
  );
}

class _HeldPendingJournal extends InMemorySharedPreferencesStore {
  _HeldPendingJournal() : super.empty();

  Completer<void>? entered, _gate;

  void holdNext() {
    entered = Completer<void>();
    _gate = Completer<void>();
  }

  void release() {
    final gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final gate = _gate;
    if (key == 'flutter.profile_pending_v2_prompt-dispatch-closure' &&
        gate != null) {
      if (!entered!.isCompleted) entered!.complete();
      await gate.future;
    }
    return super.setValue(valueType, key, value);
  }
}

import 'package:wing/core/models/composer_reference.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:wing/core/services/attachment_draft_service.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import 'profile_workspace_controller_test.dart' show Host;

class _FailingDraftStore extends ComposerDraftStore {
  Completer<void>? failureDelay;

  _FailingDraftStore(super.preferences, {required super.connectionIdentity});

  @override
  Future<void> write({
    required String profileName,
    required String sessionId,
    required String text,
    Iterable<ComposerReference> references = const [],
    required Iterable<AttachmentDraft> attachments,
    bool submissionUncertain = false,
    Iterable<QueuedPromptDraft> queuedPrompts = const [],
    bool queuePaused = false,
  }) async {
    final delay = failureDelay;
    failureDelay = null;
    if (delay != null) {
      await delay.future;
      throw StateError('Synthetic first save failure');
    }
    await super.write(
      profileName: profileName,
      sessionId: sessionId,
      text: text,
      references: references,
      attachments: attachments,
      submissionUncertain: submissionUncertain,
      queuedPrompts: queuedPrompts,
      queuePaused: queuePaused,
    );
  }
}

void main() {
  late Host host;
  late SharedPreferences preferences;
  late AppPreferences appPreferences;
  late Directory sandbox;
  final controllers = <ProfileWorkspaceController>[];
  ProfileWorkspaceController makeController({ComposerDraftStore? draftStore}) {
    final controller = ProfileWorkspaceController(
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
      connectionIdentity: 'outgoing-recovery',
      preferences: preferences,
      appPreferences: appPreferences,
      draftStore: draftStore,
      gatewayFactory: host.gateway,
      attachmentService: AttachmentDraftService(
        cacheDirectoryProvider: () async => Directory('${sandbox.path}/cache'),
      ),
    );
    controllers.add(controller);
    return controller;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    host = Host();
    sandbox = await Directory.systemTemp.createTemp('wing-outgoing-recovery-');
  });
  tearDown(() async {
    for (final controller in controllers) {
      controller.dispose();
    }
    controllers.clear();
    appPreferences.dispose();
    await sandbox.delete(recursive: true);
  });

  Future<ComposerDraftSnapshot> saved(ProfileChat chat) async =>
      (await ComposerDraftStore(
        preferences,
        connectionIdentity: 'outgoing-recovery',
      ).read(profileName: 'a', sessionId: chat.key.sessionId))!;

  Future<ProfileChat> restart(
    ProfileWorkspaceController controller,
    ProfileChat chat, {
    bool running = false,
  }) async {
    controller.dispose();
    controllers.remove(controller);
    host.running = running;
    final restarted = makeController();
    await restarted.initialize();
    await restarted.openSession(chat.key);
    return restarted.current!.chat!;
  }

  test(
    'lost acknowledgement stays in the outbox beside a fresh composer',
    () async {
      final controller = makeController();
      await controller.initialize();
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'Original outgoing');
      host.promptSubmitFails = true;
      await controller.send(chat);
      expect(chat.composer.observation.text, isEmpty);
      expect(chat.composer.observation.submissionUncertain, isFalse);
      expect(
        chat.composer.observation.queue.single.submissionUncertain,
        isTrue,
      );
      host.promptSubmitFails = false;
      await controller.updateDraft(chat, 'Fresh follow-up');
      final stored = await saved(chat);
      expect(stored.text, 'Fresh follow-up');
      expect(stored.submissionUncertain, isFalse);
      expect(stored.queuedPrompts.single.submissionUncertain, isTrue);
      await expectLater(controller.resumeQueue(chat), throwsStateError);
      expect(
        host.calls.where((call) => call.$2 == 'prompt.submit'),
        hasLength(1),
      );
    },
  );

  test(
    'failed queue save keeps uncertain original separate from fresh composer',
    () async {
      final store = _FailingDraftStore(
        preferences,
        connectionIdentity: 'outgoing-recovery',
      );
      final controller = makeController(draftStore: store);
      await controller.initialize();
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, 'Original outgoing');
      host.promptSubmitFails = true;
      await controller.send(chat);
      final delay = Completer<void>();
      await controller.updateDraft(chat, 'Queued follow-up');
      store.failureDelay = delay;
      final queueing = controller.send(chat);
      final failed = expectLater(queueing, throwsStateError);
      await controller.updateDraft(chat, 'Fresh follow-up');
      delay.complete();
      await failed;
      final stored = await saved(chat);
      expect(stored.text, 'Queued follow-up\n\nFresh follow-up');
      expect(stored.submissionUncertain, isFalse);
      expect(stored.queuedPrompts.single.text, 'Original outgoing');
      expect(stored.queuedPrompts.single.submissionUncertain, isTrue);
      expect(chat.composer.observation.paused, isTrue);
      expect(
        host.calls.where((call) => call.$2 == 'prompt.submit'),
        hasLength(1),
      );
    },
  );

  for (final fresh in ['', 'Fresh follow-up']) {
    test(
      'failed first persistence recovers outgoing beside fresh text: $fresh',
      () async {
        final store = _FailingDraftStore(
          preferences,
          connectionIdentity: 'outgoing-recovery',
        );
        final controller = makeController(draftStore: store);
        await controller.initialize();
        final chat = await controller.createChat(canDispatch: () => true);
        await controller.updateDraft(chat, 'Original outgoing');
        final delay = Completer<void>();
        store.failureDelay = delay;
        final sending = controller.send(chat);
        final rejected = expectLater(sending, throwsStateError);
        expect(chat.composer.observation.text, isEmpty);
        final editing = fresh.isEmpty
            ? Future<void>.value()
            : controller.updateDraft(chat, fresh);
        delay.complete();
        await rejected;
        await editing;
        final stored = await saved(chat);
        expect(
          stored.text,
          fresh.isEmpty ? 'Original outgoing' : 'Original outgoing\n\n$fresh',
        );
        expect(stored.queuedPrompts, isEmpty);
        expect(chat.runtime.execution, ChatExecution.idle);
        expect(chat.composer.observation.sending, isFalse);
        expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      },
    );
  }

  test(
    'first preparation snapshot consumes composer once and keeps outgoing',
    () async {
      final controller = makeController();
      await controller.initialize();
      final chat = await controller.createChat(canDispatch: () => true);
      await controller.updateDraft(chat, '  Exact outgoing text  ');
      host.discoveryStarted = Completer<void>();
      host.discoveryDelay = Completer<void>();
      final sending = controller.send(chat);
      expect(chat.composer.observation.text, isEmpty);
      await host.discoveryStarted!.future.timeout(const Duration(seconds: 3));
      final stored = await saved(chat);
      expect(stored.text, isEmpty);
      expect(stored.queuedPrompts.single.text, '  Exact outgoing text  ');
      expect(stored.queuePaused, isFalse);
      expect(stored.queuedPrompts.single.submissionUncertain, isFalse);
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      host.discoveryDelay!.complete();
      await sending;
    },
  );

  for (final fresh in ['', 'Fresh follow-up']) {
    test(
      'failed upload retains outgoing ownership and fresh composer: $fresh',
      () async {
        final controller = makeController();
        await controller.initialize();
        final chat = await controller.createChat(canDispatch: () => true);
        final file = await File(
          '${sandbox.path}/failed.txt',
        ).writeAsString('Payload');
        await controller.addAttachments(chat, [
          (path: file.path, name: 'failed.txt'),
        ]);
        final outgoingFile = (await saved(chat)).attachments.single;
        await controller.updateDraft(chat, '  Original outgoing  ');
        host.fileAttachStarted = Completer<void>();
        host.fileAttachDelay = Completer<void>();
        host.fileAttachFails = true;
        final sending = controller.send(chat);
        await host.fileAttachStarted!.future.timeout(
          const Duration(seconds: 3),
        );
        await controller.updateDraft(chat, 'Existing queued message');
        await controller.send(chat);
        await chat.composer.pause();
        if (fresh.isNotEmpty) await controller.updateDraft(chat, fresh);
        host.fileAttachDelay!.complete();
        await sending;
        final stored = await saved(chat);
        expect(stored.text, fresh);
        expect(stored.submissionUncertain, isFalse);
        expect(stored.queuedPrompts.map((prompt) => prompt.text), [
          '  Original outgoing  ',
          'Existing queued message',
        ]);
        expect(stored.attachments, isEmpty);
        final ownedFiles = stored.queuedPrompts.first.attachments;
        expect(ownedFiles.single.id, outgoingFile.id);
        expect(await File(ownedFiles.single.cachedPath).exists(), isTrue);
        expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
        expect(chat.runtime.execution, ChatExecution.failed);
      },
    );
  }

  test(
    'acknowledgement removes only outgoing recovery and its cached file',
    () async {
      final controller = makeController();
      await controller.initialize();
      final chat = await controller.createChat(canDispatch: () => true);
      final file = await File(
        '${sandbox.path}/accepted.txt',
      ).writeAsString('Payload');
      await controller.addAttachments(chat, [
        (path: file.path, name: 'accepted.txt'),
      ]);
      final outgoingFile = (await saved(chat)).attachments.single;
      await controller.updateDraft(chat, 'Original outgoing');
      host.promptSubmitStarted = Completer<void>();
      host.promptSubmitDelay = Completer<void>();
      final sending = controller.send(chat);
      await host.promptSubmitStarted!.future.timeout(
        const Duration(seconds: 3),
      );
      await controller.updateDraft(chat, 'Existing queued message');
      await controller.send(chat);
      await chat.composer.pause();
      await controller.updateDraft(chat, 'Fresh follow-up');
      // Receipts may be reusable, but the original owned bytes survive until ack.
      expect(await File(outgoingFile.cachedPath).exists(), isTrue);
      host.promptSubmitDelay!.complete();
      await sending;
      final stored = await saved(chat);
      expect(stored.text, 'Fresh follow-up');
      expect(stored.attachments, isEmpty);
      expect(stored.queuedPrompts.map((prompt) => prompt.text), [
        'Existing queued message',
      ]);
      expect(await File(outgoingFile.cachedPath).exists(), isFalse);
    },
  );

  for (final acknowledgementLost in [false, true]) {
    test(
      'dispatched outgoing restart recovers the same receipt beside the fresh draft: lost=$acknowledgementLost',
      () async {
        final controller = makeController();
        await controller.initialize();
        final chat = await controller.createChat(canDispatch: () => true);
        await controller.updateDraft(chat, 'Original outgoing');
        host.promptSubmitStarted = Completer<void>();
        final originalAck = host.promptSubmitDelay = Completer<void>();
        host.promptSubmitFails = acknowledgementLost;
        final sending = controller.send(chat);
        await host.promptSubmitStarted!.future.timeout(
          const Duration(seconds: 3),
        );
        await controller.updateDraft(chat, 'Fresh follow-up');
        if (acknowledgementLost) {
          originalAck.complete();
          await sending;
        } else {
          sending.ignore();
        }
        final stored = await saved(chat);
        expect(stored.text, 'Fresh follow-up');
        expect(stored.queuedPrompts.single.submissionUncertain, isTrue);
        final originalId = stored.queuedPrompts.single.submissionId;
        final originalPayload = stored.queuedPrompts.single.submissionPayload;
        host.promptSubmitDelay = null;
        host.promptSubmitFails = false;
        final restored = await restart(controller, chat, running: true);
        if (!originalAck.isCompleted) originalAck.complete();
        expect(restored.composer.observation.text, 'Fresh follow-up');
        expect(restored.composer.observation.queue, isEmpty);
        expect((await saved(restored)).queuedPrompts, isEmpty);
        final attempts = host.calls
            .where((call) => call.$2 == 'prompt.submit')
            .toList();
        expect(attempts, hasLength(2));
        expect(attempts[0].$3['submission_id'], originalId);
        expect(attempts[1].$3, attempts[0].$3);
        expect(attempts[1].$3, {...?originalPayload, 'profile': 'a'});
        expect(host.canonicalAdmissions, hasLength(1));
      },
    );
  }

  test(
    'queued head recovery preserves the accepted row and later local work',
    () async {
      final controller = makeController();
      await controller.initialize();
      final chat = await controller.createChat(canDispatch: () => true);
      emitChatEvent(controller, chat, 'message.start');
      await chat.composer.pause();
      await controller.queuePrompt(chat, 'Queued outgoing');
      await controller.queuePrompt(chat, 'Later queued');
      await controller.updateDraft(chat, 'Fresh composer');
      host.promptSubmitStarted = Completer<void>();
      final originalAck = host.promptSubmitDelay = Completer<void>();
      final draining = controller.resumeQueue(chat);
      draining.ignore();
      await host.promptSubmitStarted!.future.timeout(
        const Duration(seconds: 3),
      );
      final stored = await saved(chat);
      expect(stored.text, 'Fresh composer');
      expect(stored.queuedPrompts.map((prompt) => prompt.text), [
        'Queued outgoing',
        'Later queued',
      ]);
      expect(stored.queuedPrompts.first.submissionUncertain, isTrue);
      host.promptSubmitDelay = null;
      final restored = await restart(controller, chat, running: true);
      originalAck.complete();
      expect(restored.composer.observation.text, 'Fresh composer');
      expect(restored.composer.observation.queue.map((row) => row.text), [
        'Queued outgoing',
        'Later queued',
      ]);
      expect(restored.composer.observation.queue.first.serverOwned, isTrue);
      expect(restored.composer.observation.queue.last.serverOwned, isFalse);
      final replay = host.calls
          .where((call) => call.$2 == 'prompt.submit')
          .toList();
      expect(replay, hasLength(2));
      expect(replay[1].$3, replay[0].$3);
      expect(host.canonicalAdmissions, hasLength(1));
      final restarted = controllers.last;
      await restarted.resumeQueue(restored);
      expect(host.canonicalAdmissions, hasLength(2));
      expect(
        restored.composer.observation.queue.every((row) => row.serverOwned),
        isTrue,
      );
      expect((await saved(restored)).queuedPrompts, isEmpty);
    },
  );

  for (final fresh in ['Fresh follow-up', 'Original outgoing']) {
    test(
      'interrupted upload restart admits the original file and preserves the fresh draft: $fresh',
      () async {
        final controller = makeController();
        await controller.initialize();
        final chat = await controller.createChat(canDispatch: () => true);
        final key = chat.key;
        final file = File('${sandbox.path}/note.txt');
        await file.writeAsString('Attachment contents');
        await controller.addAttachments(chat, [
          (path: file.path, name: 'note.txt'),
        ]);
        final attachment = (await saved(chat)).attachments.single;
        await controller.updateDraft(chat, 'Original outgoing');
        host.fileAttachStarted = Completer<void>();
        final originalUpload = host.fileAttachDelay = Completer<void>();
        controller.send(chat).ignore();
        await host.fileAttachStarted!.future.timeout(
          const Duration(seconds: 3),
        );
        await controller.updateDraft(chat, fresh);
        final stored = await saved(chat);
        expect(stored.text, fresh);
        expect(stored.queuedPrompts.single.text, 'Original outgoing');
        expect(
          stored.queuedPrompts.single.attachments.single.id,
          attachment.id,
        );
        expect(stored.queuedPrompts.single.submissionUncertain, isFalse);
        expect(await File(attachment.cachedPath).exists(), isTrue);
        controller.dispose();
        controllers.remove(controller);
        // The new process retries unfinished local preparation, then the server
        // admits the resulting input even while another turn is running.
        host
          ..fileAttachDelay = null
          ..fileAttachStarted = null
          ..running = true;
        final restarted = makeController();
        await restarted.initialize();
        await restarted.openSession(key);
        originalUpload.complete();
        final restored = restarted.current!.chat!;
        expect(restored.composer.observation.text, fresh);
        expect(restored.composer.observation.attachments, isEmpty);
        expect(restored.composer.observation.queue.single.serverOwned, isTrue);
        expect(
          restored.composer.observation.queue.single.text,
          contains('Original outgoing'),
        );
        final outgoing = host.calls
            .where((call) => call.$2 == 'prompt.submit')
            .single;
        expect(outgoing.$3['queued'], isTrue);
        expect(outgoing.$3['text'], 'attached:note.txt\n\nOriginal outgoing');
        expect(host.canonicalAdmissions, hasLength(1));
        expect((await saved(restored)).queuedPrompts, isEmpty);
        expect(await File(attachment.cachedPath).exists(), isFalse);
      },
    );
  }
}

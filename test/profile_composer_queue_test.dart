import 'package:wing/core/models/composer_reference.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/models/composer_work.dart';
import 'support/composer_fixture.dart';
import 'support/canonical_gateway_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:wing/core/services/attachment_draft_service.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'profile_workspace_controller_test.dart' show Host;

class _FailingDraftStore extends ComposerDraftStore {
  bool failNextWrite = false;
  bool failNextEmptyQueueWrite = false;
  bool failEmptyQueueWrites = false;
  Completer<void>? delayNextWrite;

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
    final queued = queuedPrompts.toList(growable: false);
    final delay = delayNextWrite;
    delayNextWrite = null;
    if (delay != null) await delay.future;
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('Could not save unsent messages.');
    }
    if ((failNextEmptyQueueWrite || failEmptyQueueWrites) && queued.isEmpty) {
      failNextEmptyQueueWrite = false;
      throw StateError('Could not save unsent messages.');
    }
    await super.write(
      profileName: profileName,
      sessionId: sessionId,
      text: text,
      references: references,
      attachments: attachments,
      submissionUncertain: submissionUncertain,
      queuedPrompts: queued,
      queuePaused: queuePaused,
    );
  }
}

void main() {
  late Host host;
  late SharedPreferences prefs;
  late AppPreferences appPreferences;
  late _FailingDraftStore draftStore;
  late ProfileWorkspaceController controller;
  late ProfileChat chat;
  late Directory cache;
  late AttachmentDraftService attachmentService;
  Future<void> until(bool Function() ready) async {
    if (ready()) return;
    final reached = Completer<void>();
    void observe() {
      if (ready() && !reached.isCompleted) reached.complete();
    }

    controller.addListener(observe);
    try {
      await reached.future.timeout(const Duration(seconds: 5));
    } finally {
      controller.removeListener(observe);
    }
  }

  ProfileWorkspaceController makeController() => ProfileWorkspaceController(
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
    connectionIdentity: 'queue-test',
    preferences: prefs,
    appPreferences: appPreferences,
    gatewayFactory: host.gateway,
    draftStore: draftStore,
    attachmentService: attachmentService,
  );
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(prefs);
    draftStore = _FailingDraftStore(prefs, connectionIdentity: 'queue-test');
    cache = await Directory.systemTemp.createTemp('hermes-queue-');
    attachmentService = AttachmentDraftService(
      cacheDirectoryProvider: () async => Directory('${cache.path}/managed'),
    );
    host = Host();
    controller = makeController();
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
    emitChatEvent(controller, chat, 'message.start');
    // These local-draft cases deliberately hold preparation before admission.
    // Canonical server-queue cases explicitly resume below.
    await chat.composer.pause();
  });
  tearDown(() async {
    controller.dispose();
    appPreferences.dispose();
    if (await cache.exists()) await cache.delete(recursive: true);
  });
  int sends() => host.calls.where((call) => call.$2 == 'prompt.submit').length;
  List<String> queuedTexts() =>
      chat.composer.observation.queue.map((prompt) => prompt.text).toList();
  void finish() => host.event('a', 'turn.end', {'status': 'completed'});
  Future<ComposerDraftSnapshot?> saved() => ComposerDraftStore(
    prefs,
    connectionIdentity: 'queue-test',
  ).read(profileName: 'a', sessionId: chat.key.sessionId);
  Future<AttachmentDraft> attachment(String name) async {
    final file = File('${cache.path}${Platform.pathSeparator}$name');
    await file.writeAsString('payload');
    return attachmentService.prepareGenericFile(
      sourcePath: file.path,
      displayName: name,
      existingDrafts: const [],
    );
  }

  for (final restart in [false, true]) {
    test('resume-only failure holds older work restart=$restart', () async {
      await restoreComposerFixture(
        chat: chat,
        preferences: prefs,
        queuedPrompts: [QueuedPromptDraft(text: 'Older queued request')],
        paused: false,
      );
      host.running = false;
      host.inflight = {'status': 'error', 'error': 'Provider stopped'};
      if (restart) {
        final key = chat.key;
        controller.dispose();
        controller = makeController();
        await controller.initialize();
        chat = (await controller.openSession(key))!;
      } else {
        await controller.reconnect(chat.key.workspace);
      }
      expect(sends(), 0);
      expect(chat.composer.observation.paused, isTrue);
      expect(queuedTexts(), ['Older queued request']);
      expect((await saved())!.queuePaused, isTrue);
      await controller.resumeQueue(chat);
      expect(sends(), 1);
      expect(chat.composer.observation.paused, isFalse);
    });
  }

  for (final status in ['completed', 'interrupted', 'error']) {
    test('fresh Send after $status reaches Hermes', () async {
      await controller.resumeQueue(chat);
      host.event('a', 'turn.end', {'status': status});
      await until(() => !chat.runtime.blocksTurnAdmission);
      await controller.updateDraft(chat, 'A fresh request');
      await controller.send(chat);
      expect(sends(), 1);
      expect(chat.composer.observation.paused, isFalse);
    });
  }

  test(
    'fresh Send after removing the last paused item reaches Hermes',
    () async {
      await controller.queuePrompt(chat, 'Discard this');
      await controller.removeQueuedPrompt(
        chat,
        chat.composer.observation.queue.single.id,
      );
      finish();
      await until(() => !chat.runtime.blocksTurnAdmission);
      await controller.updateDraft(chat, 'A fresh request');
      await controller.send(chat);
      expect(sends(), 1);
      expect(chat.composer.observation.paused, isFalse);
    },
  );

  test('fresh Send preserves older paused work', () async {
    await controller.queuePrompt(chat, 'Older paused request');
    finish();
    await until(() => !chat.runtime.blocksTurnAdmission);
    await controller.updateDraft(chat, 'New request');
    await controller.send(chat);
    expect(sends(), 0);
    expect(queuedTexts(), ['Older paused request', 'New request']);
    expect(chat.composer.observation.paused, isTrue);
  });

  for (final errorEvent in [false, true]) {
    test(
      'failure pauses work waiting at that moment errorEvent=$errorEvent',
      () async {
        await controller.resumeQueue(chat);
        final delay = Completer<void>();
        draftStore.delayNextWrite = delay;
        final queuing = controller.queuePrompt(chat, 'Already waiting');
        if (errorEvent) {
          host.event('a', 'turn.error', {'message': 'Provider stopped'});
        } else {
          host.event('a', 'turn.end', {'status': 'interrupted'});
        }
        await until(() => !chat.runtime.blocksTurnAdmission);
        delay.complete();
        await queuing;
        expect(sends(), 0);
        expect(queuedTexts(), ['Already waiting']);
        expect(chat.composer.observation.paused, isTrue);
        expect((await saved())!.queuePaused, isTrue);
      },
    );
  }

  test(
    'screen handoff queues identical text without consuming the chat draft or attachments',
    () async {
      await controller.updateDraft(chat, 'Finished signing in');
      final file = await attachment('screen-draft.txt');
      await restoreComposerFixture(
        paused: chat.composer.observation.paused,
        chat: chat,
        preferences: controller.preferences,
        text: 'Finished signing in',
        appendAttachments: [file],
      );
      await controller.queueScreenMessage(chat, 'Finished signing in');
      expect(chat.composer.observation.text, 'Finished signing in');
      expect(chat.composer.observation.attachments.map((v) => v.id), [file.id]);
      expect(
        chat.composer.observation.queue.single.text,
        'Finished signing in',
      );
      expect(chat.composer.observation.queue.single.attachments, isEmpty);
    },
  );

  test(
    'accepted Send still reports a genuine local save failure without resending',
    () async {
      await controller.resumeQueue(chat);
      host.promptSubmitStarted = Completer<void>();
      host.promptSubmitDelay = Completer<void>();
      final sending = controller.queuePrompt(chat, 'Accepted once');
      await host.promptSubmitStarted!.future;
      draftStore.failEmptyQueueWrites = true;
      host.promptSubmitDelay!.complete();
      await sending;
      expect(sends(), 1);
      expect(host.canonicalAdmissions, hasLength(1));
      expect(
        chat.runtime.error,
        'The message was accepted. Remaining unsent work could not be saved.',
      );
      expect(chat.composer.observation.paused, isTrue);
      draftStore.failEmptyQueueWrites = false;
      await controller.resumeQueue(chat);
      expect(sends(), 1);
      expect(chat.composer.observation.submissionUncertain, isFalse);
    },
  );

  test(
    'selected identities survive queue edits, restart and failed dispatch',
    () async {
      const file = ComposerReference(
        kind: ComposerReferenceKind.file,
        token: '@file:/work/note.md',
        target: '/work/note.md',
      );
      const agent = ComposerReference(
        kind: ComposerReferenceKind.agent,
        token: '@butler',
        target: 'butler',
      );
      await controller.updateDraft(chat, 'Read ${file.token}', reference: file);
      await controller.queuePrompt(chat, chat.composer.observation.text);
      await controller.updateDraft(
        chat,
        'Ask ${agent.token}',
        reference: agent,
      );
      final id = chat.composer.observation.queue.single.id;
      await controller.beginQueuedPromptEdit(chat, id);
      controller.updateQueuedPromptEdit(chat, 'Review ${file.token} carefully');
      await controller.saveQueuedPromptEdit(chat);
      expect(chat.composer.observation.references.single.target, 'butler');
      expect(
        (await saved())!.queuedPrompts.single.references.single.target,
        file.target,
      );
      controller.dispose();
      controller = makeController();
      await controller.initialize();
      chat = (await controller.openSession(chat.key))!;
      expect(chat.composer.observation.references.single.target, 'butler');
      final queued = chat.composer.observation.queue.single;
      expect(queued.references.single.target, file.target);
      final ticket = await chat.composer.beginSubmission(
        queued: queued.id,
        preserveComposer: true,
      );
      expect(ticket.references.single.target, file.target);
      await chat.composer.settle(ticket, ComposerDelivery.definitelyUnsent);
      expect(
        chat.composer.observation.queue.single.references.single.target,
        file.target,
      );
      expect(chat.composer.observation.references.single.target, 'butler');
      await controller.updateDraft(chat, 'Ordinary editable text');
      expect(chat.composer.observation.references, isEmpty);
    },
  );

  test(
    'canonical queued receipts admit both inputs before the active turn ends',
    () async {
      await controller.resumeQueue(chat);
      await controller.queuePrompt(chat, 'First');
      await controller.queuePrompt(chat, 'Second');
      await controller.updateDraft(chat, 'Still composing');
      final file = await attachment('unused.txt');
      await restoreComposerFixture(
        paused: chat.composer.observation.paused,
        chat: chat,
        preferences: prefs,
        appendAttachments: [file],
      );
      expect(sends(), 2);
      expect(queuedTexts(), ['First', 'Second']);
      expect(
        chat.composer.observation.queue.every((row) => row.serverOwned),
        true,
      );
      finish();
      await until(() => queuedTexts().length == 1);
      expect(queuedTexts(), ['Second']);
      finish();
      await until(() => queuedTexts().isEmpty);
      expect(sends(), 2);
      expect(host.calls.where((call) => call.$2 == 'file.attach'), isEmpty);
      expect(chat.composer.observation.text, 'Still composing');
      expect(chat.composer.observation.attachments.single.id, file.id);
    },
  );

  test(
    'lost queued acknowledgement recovers the same admission across restart',
    () async {
      await controller.resumeQueue(chat);
      host.promptSubmitFails = true;
      await controller.queuePrompt(chat, 'Send once');
      expect(sends(), 1);
      expect(chat.composer.observation.paused, true);
      final key = chat.key;
      controller.dispose();
      host.promptSubmitFails = false;
      controller = makeController();
      await controller.initialize();
      chat = (await controller.openSession(key))!;
      expect(host.canonicalAdmissions, hasLength(1));
      final requests = host.calls.where((call) => call.$2 == 'prompt.submit');
      expect(
        requests.map((call) => call.$3['submission_id']).toSet(),
        hasLength(1),
      );
      expect(queuedTexts(), ['Send once']);
      expect(chat.composer.observation.queue.single.serverOwned, true);
    },
  );

  test(
    'reopening observes accepted server queue without admitting it again',
    () async {
      await controller.resumeQueue(chat);
      await controller.queuePrompt(chat, 'After the running turn');
      final key = chat.key;
      controller.dispose();
      controller = makeController();
      await controller.initialize();
      chat = (await controller.openSession(key))!;
      expect(sends(), 1);
      expect(queuedTexts(), ['After the running turn']);
      expect(chat.composer.observation.queue.single.serverOwned, true);
      expect(
        host.calls.where((call) => call.$2 == 'session.resume'),
        isNotEmpty,
      );
    },
  );

  test(
    'held admission is durably uncertain before its receipt arrives',
    () async {
      await controller.resumeQueue(chat);
      host.promptSubmitDelay = Completer<void>();
      host.promptSubmitStarted = Completer<void>();
      final queuing = controller.queuePrompt(chat, 'First');
      await host.promptSubmitStarted!.future;
      final snapshot = (await saved())!;
      expect(snapshot.queuePaused, true);
      expect(snapshot.queuedPrompts.single.submissionUncertain, true);
      expect(chat.composer.observation.draining, true);
      host.promptSubmitDelay!.complete();
      await queuing;
      expect(queuedTexts(), ['First']);
      expect(chat.composer.observation.queue.single.serverOwned, true);
      expect((await saved())?.queuedPrompts ?? [], isEmpty);
    },
  );

  test('server queued edit replaces the exact admission at the tail', () async {
    await controller.resumeQueue(chat);
    await controller.queuePrompt(chat, 'Original');
    await controller.queuePrompt(chat, 'Second');
    await controller.updateDraft(chat, 'Separate draft');
    final original = chat.composer.observation.queue.first;
    await controller.beginQueuedPromptEdit(chat, original.id);
    controller.updateQueuedPromptEdit(chat, 'Updated');
    await controller.saveQueuedPromptEdit(chat);
    expect(queuedTexts(), ['Second', 'Updated']);
    expect(chat.composer.observation.text, 'Separate draft');
    final replace = host.calls.singleWhere(
      (call) => call.$2 == 'prompt.replace_queued',
    );
    expect(replace.$3['admission_id'], 'admission-1');
    expect(replace.$3['text'], 'Updated');
    expect(sends(), 2);
  });

  test(
    'server cancel and steer use admitted identity without another submit',
    () async {
      await controller.resumeQueue(chat);
      await controller.queuePrompt(chat, 'Same');
      await controller.queuePrompt(chat, 'Same');
      final rows = List.of(chat.composer.observation.queue);
      await controller.removeQueuedPrompt(chat, rows.first.id);
      expect(queuedTexts(), ['Same']);
      expect(
        await controller.steerQueuedPrompt(
          chat,
          chat.composer.observation.queue.single.id,
        ),
        true,
      );
      expect(queuedTexts(), ['Same']);
      final transfer = chat.composer.observation.queue.single;
      expect(transfer.pendingSteering, true);
      expect(
        (
          canEdit: chat.composer.queueActions(transfer.id).canEdit,
          canSteer: chat.composer.queueActions(transfer.id).canSteer,
          canDelete: chat.composer.queueActions(transfer.id).canDelete,
        ),
        (canEdit: false, canDelete: false, canSteer: false),
      );
      host.event('a', 'turn.end');
      expect(queuedTexts(), isEmpty);
      expect(
        host.calls
            .singleWhere((call) => call.$2 == 'prompt.cancel')
            .$3['admission_id'],
        'admission-1',
      );
      expect(
        host.calls
            .singleWhere((call) => call.$2 == 'prompt.steer_queued')
            .$3['admission_id'],
        'admission-2',
      );
      expect(sends(), 2);
    },
  );

  test(
    'queued attachments upload before admission and preserve separate composer work',
    () async {
      final file = await attachment('queued.txt');
      await restoreComposerFixture(
        paused: chat.composer.observation.paused,
        chat: chat,
        preferences: prefs,
        text: 'Review queued',
        appendAttachments: [file],
      );
      await controller.queuePrompt(chat, 'Review queued');
      final composing = await attachment('composing.txt');
      await restoreComposerFixture(
        paused: chat.composer.observation.paused,
        chat: chat,
        preferences: prefs,
        text: 'Still composing',
        appendAttachments: [composing],
      );
      await controller.resumeQueue(chat);
      final methods = host.calls.map((call) => call.$2).toList();
      expect(
        methods.indexOf('file.attach'),
        lessThan(methods.indexOf('prompt.submit')),
      );
      final submit = host.calls.singleWhere(
        (call) => call.$2 == 'prompt.submit',
      );
      expect(submit.$3['text'], contains('attached:queued.txt'));
      expect(chat.composer.observation.queue.single.serverOwned, true);
      expect(chat.composer.observation.queue.single.attachments, isEmpty);
      expect(await File(file.cachedPath).exists(), false);
      expect(chat.composer.observation.text, 'Still composing');
      expect(chat.composer.observation.attachments.single.id, composing.id);
      expect(await File(composing.cachedPath).exists(), true);
    },
  );

  test(
    'attachment-only queue submits its uploaded reference to server FIFO',
    () async {
      final file = await attachment('only.txt');
      await restoreComposerFixture(
        paused: chat.composer.observation.paused,
        chat: chat,
        preferences: prefs,
        appendAttachments: [file],
      );
      await controller.queuePrompt(chat, '');
      await controller.resumeQueue(chat);
      expect(
        host.calls.singleWhere((call) => call.$2 == 'prompt.submit').$3['text'],
        'attached:only.txt',
      );
      expect(chat.composer.observation.queue.single.serverOwned, true);
      expect(await File(file.cachedPath).exists(), false);
    },
  );

  test(
    'lost attachment acknowledgement reuses uploaded reference and stable input ID',
    () async {
      final file = await attachment('uncertain.txt');
      await restoreComposerFixture(
        paused: chat.composer.observation.paused,
        chat: chat,
        preferences: prefs,
        text: 'With file',
        appendAttachments: [file],
      );
      await controller.queuePrompt(chat, 'With file');
      host.promptSubmitFails = true;
      await controller.resumeQueue(chat);
      expect(
        chat.composer.observation.queue.single.attachments.single.refText,
        'attached:uncertain.txt',
      );
      final key = chat.key;
      controller.dispose();
      host.promptSubmitFails = false;
      controller = makeController();
      await controller.initialize();
      chat = (await controller.openSession(key))!;
      expect(host.canonicalAdmissions, hasLength(1));
      expect(
        host.calls.where((call) => call.$2 == 'file.attach'),
        hasLength(1),
      );
      expect(
        host.calls
            .where((call) => call.$2 == 'prompt.submit')
            .map((call) => call.$3['submission_id'])
            .toSet(),
        hasLength(1),
      );
      expect(chat.composer.observation.queue.single.serverOwned, true);
    },
  );

  test('attachment upload failure keeps the paused head and cache', () async {
    final file = await attachment('upload-fails.txt');
    await restoreComposerFixture(
      paused: chat.composer.observation.paused,
      chat: chat,
      preferences: controller.preferences,
      appendAttachments: [file],
    );
    await controller.queuePrompt(chat, '');
    host.fileAttachFails = true;

    await controller.resumeQueue(chat);
    await until(
      () =>
          !chat.composer.observation.draining &&
          chat.composer.observation.paused,
    );

    expect(sends(), 0);
    expect(
      chat.composer.observation.queue.single.attachments.single.status,
      AttachmentDraftStatus.failed,
    );
    expect(await File(file.cachedPath).exists(), isTrue);
    final snapshot = (await saved())!;
    expect(snapshot.queuePaused, isTrue);
    expect(
      snapshot.queuedPrompts.single.attachments.single.status,
      AttachmentDraftStatus.failed,
    );
  });

  test(
    'missing queued file pauses before upload and preserves newer draft',
    () async {
      final file = await attachment('missing-local.txt');
      await restoreComposerFixture(
        paused: chat.composer.observation.paused,
        chat: chat,
        preferences: controller.preferences,
        text: 'Keep this queued work',
        appendAttachments: [file],
      );
      await controller.queuePrompt(chat, chat.composer.observation.text);
      final queuedId = chat.composer.observation.queue.single.id;
      await controller.updateDraft(chat, 'Newer separate draft');
      await File(file.cachedPath).delete();

      await controller.resumeQueue(chat);
      await until(
        () =>
            !chat.composer.observation.draining &&
            chat.composer.observation.paused,
      );
      expect(sends(), 0);
      expect(host.calls.where((call) => call.$2 == 'file.attach'), isEmpty);
      final queued = chat.composer.observation.queue.single;
      expect(queued.id, queuedId);
      expect(queued.text, 'Keep this queued work');
      expect(queued.submissionUncertain, isFalse);
      expect(queued.attachments.single.id, file.id);
      expect(queued.attachments.single.status, AttachmentDraftStatus.failed);
      expect(chat.composer.observation.text, 'Newer separate draft');
      final snapshot = (await saved())!;
      expect(snapshot.queuePaused, isTrue);
      expect(snapshot.text, 'Newer separate draft');
      expect(snapshot.queuedPrompts.single.text, 'Keep this queued work');
      expect(snapshot.queuedPrompts.single.attachments.single.id, file.id);
      expect(
        snapshot.queuedPrompts.single.attachments.single.status,
        AttachmentDraftStatus.failed,
      );

      final key = chat.key;
      controller.dispose();
      host.running = false;
      controller = makeController();
      await controller.initialize();
      await controller.openSession(key);
      chat = controller.current!.chat!;
      expect(chat.composer.observation.paused, isTrue);
      expect(
        chat.composer.observation.queue.single.text,
        'Keep this queued work',
      );
      expect(
        chat.composer.observation.queue.single.attachments.single.id,
        file.id,
      );
      expect(chat.composer.observation.text, 'Newer separate draft');
      expect(sends(), 0);
      expect(host.calls.where((call) => call.$2 == 'file.attach'), isEmpty);
    },
  );

  test(
    'failed queue save restores original work beside newer composer edits',
    () async {
      final originalFile = await attachment('original.txt');
      final newerFile = await attachment('newer.txt');
      await restoreComposerFixture(
        paused: chat.composer.observation.paused,
        chat: chat,
        preferences: controller.preferences,
        text: 'Original',
        appendAttachments: [originalFile],
      );
      final delay = Completer<void>();
      draftStore
        ..delayNextWrite = delay
        ..failNextWrite = true;

      final queued = controller.queuePrompt(
        chat,
        chat.composer.observation.text,
      );
      expect(chat.composer.observation.saving, isTrue);
      await controller.updateDraft(chat, 'Newer typing');
      await expectLater(
        controller.addAttachments(chat, [
          (path: newerFile.cachedPath, name: newerFile.name),
        ]),
        throwsStateError,
      );
      expect(await File(newerFile.cachedPath).exists(), isTrue);
      delay.complete();
      await expectLater(queued, throwsStateError);

      expect(chat.composer.observation.saving, isFalse);
      expect(chat.composer.observation.queue, isEmpty);
      expect(chat.composer.observation.text, 'Original\n\nNewer typing');
      expect(chat.composer.observation.attachments.map((file) => file.id), [
        originalFile.id,
      ]);
      expect(await File(originalFile.cachedPath).exists(), isTrue);
      expect(await File(newerFile.cachedPath).exists(), isTrue);
      final snapshot = (await saved())!;
      expect(snapshot.text, 'Original\n\nNewer typing');
      expect(snapshot.attachments.map((file) => file.id), [originalFile.id]);
      expect(snapshot.attachments.map((file) => file.name), ['original.txt']);
    },
  );

  for (final persistentFailure in [false, true]) {
    test(
      'local ACK cleanup failure preserves one canonical admission: persistent=$persistentFailure',
      () async {
        final file = await attachment('keep.txt');
        await restoreComposerFixture(
          paused: chat.composer.observation.paused,
          chat: chat,
          preferences: prefs,
          text: 'Send once',
          appendAttachments: [file],
        );
        await controller.queuePrompt(chat, 'Send once');
        draftStore
          ..failNextEmptyQueueWrite = true
          ..failEmptyQueueWrites = persistentFailure;
        await controller.resumeQueue(chat);
        expect(sends(), 1);
        expect(host.canonicalAdmissions, hasLength(1));
        expect(
          chat.composer.observation.queue.where((row) => row.serverOwned),
          hasLength(1),
        );
        final key = chat.key;
        controller.dispose();
        draftStore.failEmptyQueueWrites = false;
        controller = makeController();
        await controller.initialize();
        chat = (await controller.openSession(key))!;
        expect(host.canonicalAdmissions, hasLength(1));
        expect(
          host.calls
              .where((call) => call.$2 == 'prompt.submit')
              .map((call) => call.$3['submission_id'])
              .toSet(),
          hasLength(1),
        );
        expect(
          chat.composer.observation.queue.where((row) => row.serverOwned),
          hasLength(1),
        );
      },
    );
  }

  test('editing holds the queue when the active turn finishes', () async {
    await controller.queuePrompt(chat, 'Original');
    await controller.queuePrompt(chat, 'Second');
    final file = await attachment('draft-buffer.txt');
    await restoreComposerFixture(
      paused: chat.composer.observation.paused,
      chat: chat,
      preferences: controller.preferences,
      appendAttachments: [file],
    );
    await controller.updateDraft(chat, 'Separate draft');
    await controller.beginQueuedPromptEdit(
      chat,
      chat.composer.observation.queue.first.id,
    );
    controller.updateQueuedPromptEdit(chat, 'Changed');
    await controller.resumeQueue(chat);
    finish();
    await until(() => chat.runtime.execution == ChatExecution.completed);
    expect(sends(), 0);
    expect((await saved())!.queuePaused, isTrue);
    expect((await saved())!.text, 'Separate draft');
    await controller.saveQueuedPromptEdit(chat);
    await until(() => sends() == 2 && !chat.composer.observation.draining);
    expect(
      host.calls.where((call) => call.$2 == 'prompt.submit').first.$3['text'],
      'Changed',
    );
    expect(queuedTexts(), ['Second']);
    expect(chat.composer.observation.displayedText, 'Separate draft');
    expect(chat.composer.observation.attachments.map((file) => file.id), [
      file.id,
    ]);
    expect(await File(file.cachedPath).exists(), isTrue);
  });

  test(
    'cancel restores the draft without changing queued attachments',
    () async {
      final queuedFile = await attachment('queued-edit.txt');
      chat.composer.editText('Original');
      await restoreComposerFixture(
        paused: chat.composer.observation.paused,
        chat: chat,
        preferences: controller.preferences,
        appendAttachments: [queuedFile],
      );
      await controller.queuePrompt(chat, 'Original');
      await controller.updateDraft(chat, 'Separate draft');
      await controller.beginQueuedPromptEdit(
        chat,
        chat.composer.observation.queue.first.id,
      );
      controller.updateQueuedPromptEdit(chat, 'Discard');
      await controller.cancelQueuedPromptEdit(chat);
      expect(chat.composer.observation.displayedText, 'Separate draft');
      expect(chat.composer.observation.queue.single.text, 'Original');
      expect(
        chat.composer.observation.queue.single.attachments.map(
          (file) => file.id,
        ),
        [queuedFile.id],
      );
      expect(await File(queuedFile.cachedPath).exists(), isTrue);
    },
  );

  test(
    'failed composer queue save retains the edit and separate draft',
    () async {
      await controller.queuePrompt(chat, 'Original');
      await controller.updateDraft(chat, 'Separate draft');
      await controller.beginQueuedPromptEdit(
        chat,
        chat.composer.observation.queue.first.id,
      );
      controller.updateQueuedPromptEdit(chat, 'Changed');
      draftStore.failNextWrite = true;
      await expectLater(
        controller.saveQueuedPromptEdit(chat),
        throwsStateError,
      );
      expect(chat.composer.observation.displayedText, 'Changed');
      expect(chat.composer.observation.text, 'Separate draft');
      expect(chat.composer.observation.queue.single.text, 'Original');
      expect(chat.composer.observation.paused, isTrue);
    },
  );

  test(
    'queued steering preserves the buffered draft and its attachments',
    () async {
      await controller.queuePrompt(chat, 'Original');
      await controller.queuePrompt(chat, 'Second');
      final file = await attachment('buffered.txt');
      await restoreComposerFixture(
        paused: chat.composer.observation.paused,
        chat: chat,
        preferences: controller.preferences,
        appendAttachments: [file],
      );
      await controller.updateDraft(chat, 'Separate draft');
      await controller.beginQueuedPromptEdit(
        chat,
        chat.composer.observation.queue.first.id,
      );
      controller.updateQueuedPromptEdit(chat, 'Changed direction');
      expect(await controller.steerQueuedPromptEdit(chat), isTrue);
      expect(
        host.calls.singleWhere((call) => call.$2 == 'session.steer').$3['text'],
        'Changed direction',
      );
      expect(queuedTexts(), ['Second']);
      expect(chat.composer.observation.displayedText, 'Separate draft');
      expect(chat.composer.observation.attachments.map((file) => file.id), [
        file.id,
      ]);
      expect((await saved())!.queuedPrompts.single.text, 'Second');
      expect((await saved())!.text, 'Separate draft');
      expect(await File(file.cachedPath).exists(), isTrue);
      expect(host.calls.where((call) => call.$2 == 'file.attach'), isEmpty);
    },
  );

  test(
    'failed steering preflight save never attempts delivery or loses the edit',
    () async {
      await controller.queuePrompt(chat, 'Original');
      await controller.beginQueuedPromptEdit(
        chat,
        chat.composer.observation.queue.first.id,
      );
      controller.updateQueuedPromptEdit(chat, 'Changed');
      draftStore.failNextWrite = true;
      await expectLater(
        controller.steerQueuedPromptEdit(chat),
        throwsStateError,
      );
      expect(host.calls.where((call) => call.$2 == 'session.steer'), isEmpty);
      expect(chat.composer.observation.queue.single.text, 'Original');
      expect(chat.composer.observation.displayedText, 'Changed');
      expect(chat.composer.observation.saving, isFalse);
      expect((await saved())!.queuedPrompts.single.text, 'Original');
    },
  );

  test(
    'accepted steer with a failed final save never resends automatically',
    () async {
      await controller.queuePrompt(chat, 'Original');
      await controller.updateDraft(chat, 'Separate draft');
      await controller.beginQueuedPromptEdit(
        chat,
        chat.composer.observation.queue.first.id,
      );
      controller.updateQueuedPromptEdit(chat, 'Changed');
      draftStore.failNextEmptyQueueWrite = true;
      await expectLater(
        controller.steerQueuedPromptEdit(chat),
        throwsStateError,
      );
      expect(
        host.calls.where((call) => call.$2 == 'session.steer'),
        hasLength(1),
      );
      expect(chat.composer.observation.queue, isEmpty);
      expect(chat.composer.observation.displayedText, 'Separate draft');
      expect(chat.composer.observation.paused, isTrue);
      expect((await saved())!.queuePaused, isTrue);
      finish();
      await until(() => chat.runtime.execution == ChatExecution.completed);
      expect(sends(), 0);
    },
  );

  test(
    'editing keeps queue order, attachments and the separate draft on disk',
    () async {
      final file = await attachment('edit.txt');
      chat.composer.editText('Original');
      await restoreComposerFixture(
        paused: chat.composer.observation.paused,
        chat: chat,
        preferences: controller.preferences,
        appendAttachments: [file],
      );
      await controller.queuePrompt(chat, 'Original');
      await controller.queuePrompt(chat, 'Second');
      await controller.updateDraft(chat, 'Separate draft');
      await controller.beginQueuedPromptEdit(
        chat,
        chat.composer.observation.queue.first.id,
      );
      controller.updateQueuedPromptEdit(chat, 'Updated');
      await controller.saveQueuedPromptEdit(chat);
      expect(queuedTexts(), ['Updated', 'Second']);
      expect(
        chat.composer.observation.queue.first.attachments.map(
          (file) => file.id,
        ),
        [file.id],
      );
      expect(await File(file.cachedPath).exists(), isTrue);
      final snapshot = (await saved())!;
      expect(snapshot.text, 'Separate draft');
      expect(snapshot.queuedPrompts.map((prompt) => prompt.text), [
        'Updated',
        'Second',
      ]);
      expect(
        snapshot.queuedPrompts.first.attachments.single.cachedPath,
        file.cachedPath,
      );
    },
  );

  test(
    'failed queued edit restores the saved original and pauses the queue',
    () async {
      await controller.queuePrompt(chat, 'Original');
      final original = chat.composer.observation.queue.single;
      await controller.beginQueuedPromptEdit(chat, original.id);
      controller.updateQueuedPromptEdit(chat, 'Updated');
      draftStore.failNextWrite = true;
      await expectLater(
        controller.saveQueuedPromptEdit(chat),
        throwsStateError,
      );
      expect(chat.composer.observation.queue.single.id, same(original.id));
      expect(chat.composer.observation.paused, isTrue);
      expect(chat.composer.observation.saving, isFalse);
      expect((await saved())!.queuedPrompts.single.text, 'Original');
    },
  );

  test(
    'editing a prepared request does not reuse its old dispatch identity',
    () async {
      await restoreComposerFixture(
        chat: chat,
        preferences: prefs,
        paused: true,
        queuedPrompts: [
          QueuedPromptDraft(
            text: 'Original',
            voiceContext: 'Voice context',
            submissionId: 'prepared-input',
            submissionPayload: {
              'submission_id': 'prepared-input',
              'text': 'Original',
            },
          ),
        ],
      );
      final queued = chat.composer.observation.queue.single;
      await controller.beginQueuedPromptEdit(chat, queued.id);
      controller.updateQueuedPromptEdit(chat, 'Changed');
      await controller.saveQueuedPromptEdit(chat);
      final value = (await saved())!.queuedPrompts.single;
      expect(value.submissionId, isNull);
      expect(value.submissionPayload, isNull);
      expect(value.voiceContext, 'Voice context');
    },
  );

  test('stale queued edit cannot overwrite another entry', () async {
    await controller.queuePrompt(chat, 'Same');
    await controller.queuePrompt(chat, 'Same');
    final original = chat.composer.observation.queue.first;
    await controller.removeQueuedPrompt(chat, original.id);
    await expectLater(
      controller.beginQueuedPromptEdit(chat, original.id),
      throwsStateError,
    );
    expect(queuedTexts(), ['Same']);
  });

  test('duplicate queued text is removed by entry identity', () async {
    await controller.queuePrompt(chat, 'Same');
    await controller.queuePrompt(chat, 'Same');
    final first = chat.composer.observation.queue.first;
    final second = chat.composer.observation.queue.last;

    await controller.removeQueuedPrompt(chat, ComposerQueueId());
    expect(chat.composer.observation.queue.map((item) => item.id), [
      first.id,
      second.id,
    ]);
    await controller.removeQueuedPrompt(chat, second.id);
    expect(chat.composer.observation.queue.map((item) => item.id), [first.id]);
  });

  test('stale captured text does not clear a newer composer draft', () async {
    chat.composer.editText('Newer composer text');

    await controller.queuePrompt(chat, 'Earlier captured text');

    expect(queuedTexts(), ['Earlier captured text']);
    expect(chat.composer.observation.text, 'Newer composer text');
    expect((await saved())!.text, 'Newer composer text');
  });

  test('stale empty capture leaves newer composer work in place', () async {
    final newerFile = await attachment('newer-composer.txt');
    await restoreComposerFixture(
      paused: chat.composer.observation.paused,
      chat: chat,
      preferences: controller.preferences,
      text: 'Newer composer text',
      appendAttachments: [newerFile],
    );

    await expectLater(controller.queuePrompt(chat, ''), throwsStateError);

    expect(chat.composer.observation.queue, isEmpty);
    expect(chat.composer.observation.text, 'Newer composer text');
    expect(chat.composer.observation.attachments.map((file) => file.id), [
      newerFile.id,
    ]);
    expect(await File(newerFile.cachedPath).exists(), isTrue);
  });

  test(
    'typing during queued removal is persisted after the mutation',
    () async {
      await controller.queuePrompt(chat, 'Remove me');
      final delay = Completer<void>();
      draftStore.delayNextWrite = delay;

      final removing = controller.removeQueuedPrompt(
        chat,
        chat.composer.observation.queue[0].id,
      );
      final typing = controller.updateDraft(chat, 'Typed while saving');
      delay.complete();
      await Future.wait([removing, typing]);

      expect(chat.composer.observation.queue, isEmpty);
      expect(chat.composer.observation.text, 'Typed while saving');
      expect((await saved())!.text, 'Typed while saving');
    },
  );

  test(
    'turn end during local removal preserves the remaining row until explicit resume',
    () async {
      await controller.queuePrompt(chat, 'Remove me');
      await controller.queuePrompt(chat, 'Send me');
      final delay = Completer<void>();
      draftStore.delayNextWrite = delay;

      final removing = controller.removeQueuedPrompt(
        chat,
        chat.composer.observation.queue[0].id,
      );
      finish();
      delay.complete();
      await removing;
      expect(sends(), 0);
      expect(queuedTexts(), ['Send me']);
      await controller.resumeQueue(chat);
      expect(sends(), 1);
      expect(chat.composer.observation.queue.single.serverOwned, true);
      final submit = host.calls.singleWhere(
        (call) => call.$2 == 'prompt.submit',
      );
      expect(submit.$3['text'], 'Send me');
    },
  );

  test(
    'deleting a chat clears composer and queued attachment caches',
    () async {
      final queuedFile = await attachment('delete-queued.txt');
      final composerFile = await attachment('delete-composer.txt');
      await restoreComposerFixture(
        paused: chat.composer.observation.paused,
        chat: chat,
        preferences: controller.preferences,
        text: 'Queued',
        appendAttachments: [queuedFile],
      );
      await controller.queuePrompt(chat, chat.composer.observation.text);
      emitChatEvent(controller, chat, 'session.info', {
        ...canonicalSnapshotFields,
        'open_requests': [],
        'running': false,
      });
      await restoreComposerFixture(
        paused: chat.composer.observation.paused,
        chat: chat,
        preferences: controller.preferences,
        appendAttachments: [composerFile],
      );
      await controller.updateDraft(chat, 'Composer');

      await controller.mutateSession(
        chat.key,
        delete: true,
        canDispatch: () => true,
      );

      expect(await File(queuedFile.cachedPath).exists(), isFalse);
      expect(await File(composerFile.cachedPath).exists(), isFalse);
      expect(await saved(), isNull);
    },
  );

  test(
    'deleting an unopened chat clears its stored queued attachment cache',
    () async {
      final file = await attachment('unopened.txt');
      const sessionId = 'unopened';
      await draftStore.write(
        profileName: 'a',
        sessionId: sessionId,
        text: '',
        attachments: const [],
        queuedPrompts: [
          QueuedPromptDraft(text: 'Stored', attachments: [file]),
        ],
      );
      final key = ProfileSessionKey(chat.key.workspace, sessionId);

      await controller.mutateSession(
        key,
        delete: true,
        canDispatch: () => true,
      );

      expect(await File(file.cachedPath).exists(), isFalse);
      expect(
        await draftStore.read(profileName: 'a', sessionId: sessionId),
        isNull,
      );
    },
  );
}

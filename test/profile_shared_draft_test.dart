import 'package:wing/core/services/chat_runtime.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/attachment_image_worker.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/services/android_share_intent_service.dart';
import 'package:wing/core/services/attachment_draft_service.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_browser_fixture.dart';

void main() {
  late ProfileBrowserFixture host;
  late _RecordingAttachmentService attachments;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;
  late _FailingPreferences platform;

  setUp(() async {
    final previousPlatform = SharedPreferencesStorePlatform.instance;
    addTearDown(() {
      SharedPreferencesStorePlatform.instance = previousPlatform;
      SharedPreferences.resetStatic();
    });
    SharedPreferences.setMockInitialValues({});
    platform = _FailingPreferences();
    SharedPreferencesStorePlatform.instance = platform;
    host = ProfileBrowserFixture();
    attachments = _RecordingAttachmentService();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'shared-draft',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
      attachmentService: attachments,
    );
    await controller.initialize();
    final key = ProfileSessionKey(controller.current!.scope, 'newest');
    await controller.openSession(key);
    chat = controller.current!.chat!;
  });

  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  test(
    'merges text and files without disturbing existing unsent work',
    () async {
      final original = _draft('original', name: 'notes.txt');
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        text: 'Existing draft\n',
        uncertain: true,
        appendAttachments: [original],
        appendQueued: [QueuedPromptDraft(text: 'follow up')],
        paused: true,
      );

      await controller.stageSharedDraft(
        chat,
        const AndroidSharePayload(
          text: 'Shared title',
          files: [
            AndroidSharedFile(
              path: '/incoming/photo.jpg',
              name: 'Original photo.jpg',
              mediaType: 'image/jpeg',
              byteLength: 12,
            ),
            AndroidSharedFile(
              path: '/incoming/report.pdf',
              name: 'Quarterly report.pdf',
              mediaType: 'application/pdf',
              byteLength: 20,
            ),
          ],
        ),
      );

      expect(chat.composer.observation.text, 'Existing draft\n\nShared title');
      expect(chat.composer.observation.attachments.map((draft) => draft.name), [
        'notes.txt',
        'Original photo.jpg',
        'Quarterly report.pdf',
      ]);
      expect(
        chat.composer.observation.attachments[2].mediaType,
        'application/pdf',
      );
      expect(attachments.existingCounts, [1, 2]);
      expect(chat.composer.observation.queue.single.text, 'follow up');
      expect(chat.composer.observation.paused, isTrue);
      expect(chat.composer.observation.submissionUncertain, isTrue);

      final saved = await SharedPreferences.getInstance();
      final snapshot =
          (await ComposerDraftStore(
            saved,
            connectionIdentity: 'shared-draft',
          ).read(
            profileName: chat.key.workspace.profileName,
            sessionId: chat.key.sessionId,
          ))!;
      expect(snapshot.text, contains('Shared title'));
      expect(snapshot.attachments[1].sanitized, isTrue);
      expect(
        snapshot.attachments.map((draft) => draft.name),
        contains('Quarterly report.pdf'),
      );
    },
  );

  test(
    'typing during picker preparation preserves new text and adds the batch',
    () async {
      await controller.updateDraft(chat, 'Before');
      attachments.gate = Completer<void>();
      final pending = controller.addAttachments(chat, [
        (path: '/one', name: 'one.txt'),
        (path: '/two', name: 'two.txt'),
      ]);
      await attachments.started.future;
      await controller.updateDraft(chat, 'Typed during preparation');
      attachments.gate!.complete();
      await pending;
      expect(chat.composer.observation.text, 'Typed during preparation');
      expect(chat.composer.observation.attachments.map((file) => file.name), [
        'one.txt',
        'two.txt',
      ]);
    },
  );

  test(
    'picker batch failure cleans staged files and preserves existing work',
    () async {
      final original = _draft('original', name: 'keep.txt');
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        text: 'Keep this',
        appendAttachments: [original],
        appendQueued: [QueuedPromptDraft(text: 'Keep queued')],
        paused: true,
      );
      attachments.failAt = 2;
      await expectLater(
        controller.addAttachments(chat, [
          (path: '/one', name: 'one.png'),
          (path: '/two', name: 'two.txt'),
        ]),
        throwsA(isA<AttachmentDraftException>()),
      );
      expect(chat.composer.observation.text, 'Keep this');
      expect(chat.composer.observation.attachments.map((file) => file.id), [
        original.id,
      ]);
      expect(chat.composer.observation.queue.single.text, 'Keep queued');
      expect(chat.composer.observation.paused, isTrue);
      expect(attachments.removedIds, ['shared-1']);
      expect(controller.canAddAttachment(chat), isTrue);
    },
  );

  test(
    'picker batch includes existing attachments in the count limit',
    () async {
      final original = _draft('original', name: 'keep.txt');
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        text: 'Keep this',
        appendAttachments: [original],
      );
      await expectLater(
        controller.addAttachments(chat, [
          for (var index = 0; index < 40; index++)
            (path: '/$index', name: '$index.txt'),
        ]),
        throwsA(isA<AttachmentDraftException>()),
      );
      expect(chat.composer.observation.text, 'Keep this');
      expect(chat.composer.observation.attachments.map((file) => file.id), [
        original.id,
      ]);
      expect(attachments.removedIds, hasLength(40));
    },
  );

  test(
    'preparation failure cleans only new files and commits nothing',
    () async {
      final original = _draft('original', name: 'keep.txt');
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        text: 'Keep this',
        appendAttachments: [original],
        appendQueued: [QueuedPromptDraft(text: 'keep queued')],
        paused: true,
      );
      attachments.failAt = 2;
      bool? lastCanAdd;
      void observeAttachmentControls() {
        lastCanAdd = controller.canAddAttachment(chat);
      }

      controller.addListener(observeAttachmentControls);

      await expectLater(
        controller.stageSharedDraft(
          chat,
          const AndroidSharePayload(
            text: 'Do not merge',
            files: [
              AndroidSharedFile(
                path: '/one',
                name: 'one.txt',
                mediaType: 'text/plain',
                byteLength: 1,
              ),
              AndroidSharedFile(
                path: '/two',
                name: 'two.txt',
                mediaType: 'text/plain',
                byteLength: 1,
              ),
            ],
          ),
        ),
        throwsA(isA<AttachmentDraftException>()),
      );

      expect(chat.composer.observation.text, 'Keep this');
      expect(chat.composer.observation.attachments.map((file) => file.id), [
        original.id,
      ]);
      expect(chat.composer.observation.queue.single.text, 'keep queued');
      expect(chat.composer.observation.paused, isTrue);
      expect(lastCanAdd, isTrue);
      controller.removeListener(observeAttachmentControls);
      expect(attachments.removedIds, ['shared-1']);
      expect(attachments.removedIds, isNot(contains('original')));
    },
  );

  test('a draft edit during preparation wins and rejects the share', () async {
    await restoreComposerFixture(
      chat: chat,
      preferences: controller.preferences,
      text: 'Before',
      uncertain: true,
    );
    attachments.gate = Completer<void>();
    final staging = controller.stageSharedDraft(
      chat,
      const AndroidSharePayload(
        text: 'Shared',
        files: [
          AndroidSharedFile(
            path: '/slow',
            name: 'slow.txt',
            mediaType: 'text/plain',
            byteLength: 1,
          ),
        ],
      ),
    );
    await attachments.started.future;
    await controller.updateDraft(chat, 'Typed while preparing');
    attachments.gate!.complete();

    await expectLater(staging, throwsStateError);
    expect(chat.composer.observation.text, 'Typed while preparing');
    expect(chat.composer.observation.attachments, isEmpty);
    expect(attachments.removedIds, ['shared-1']);
  });

  test('failed share save preserves newer text and its staged files', () async {
    await controller.updateDraft(chat, 'Before');
    platform.failNextWrite();
    final staging = controller.stageSharedDraft(chat, _sharedFile);
    final failed = expectLater(staging, throwsStateError);
    await platform.started!.future;
    final editing = controller.updateDraft(chat, 'Typed after merging');
    platform.release!.complete();
    await failed;
    await editing;

    expect(chat.composer.observation.text, 'Typed after merging');
    expect(chat.composer.observation.attachments.single.id, 'shared-1');
    expect(attachments.removedIds, isEmpty);
    final snapshot =
        await ComposerDraftStore(
          await SharedPreferences.getInstance(),
          connectionIdentity: 'shared-draft',
        ).read(
          profileName: chat.key.workspace.profileName,
          sessionId: chat.key.sessionId,
        );
    expect(snapshot!.text, 'Typed after merging');
    expect(snapshot.attachments.single.id, 'shared-1');
  });

  test(
    'failed share save rolls back only when no newer edit owns it',
    () async {
      await controller.updateDraft(chat, 'Before');
      platform.failNextWrite();
      final failed = expectLater(
        controller.stageSharedDraft(chat, _sharedFile),
        throwsStateError,
      );
      await platform.started!.future;
      platform.release!.complete();
      await failed;

      expect(chat.composer.observation.text, 'Before');
      expect(chat.composer.observation.attachments, isEmpty);
      expect(attachments.removedIds, ['shared-1']);
    },
  );

  test('editing away and back still owns the newer draft revision', () async {
    await controller.updateDraft(chat, 'Before');
    platform.failNextWrite();
    final failed = expectLater(
      controller.stageSharedDraft(chat, _sharedFile),
      throwsStateError,
    );
    await platform.started!.future;
    final firstEdit = controller.updateDraft(chat, 'Changed');
    final secondEdit = controller.updateDraft(chat, 'Before\n\nShared');
    platform.release!.complete();
    await failed;
    await Future.wait([firstEdit, secondEdit]);

    expect(chat.composer.observation.text, 'Before\n\nShared');
    expect(chat.composer.observation.attachments.single.id, 'shared-1');
    expect(attachments.removedIds, isEmpty);
  });

  test('reconnecting chat stages shared work locally', () async {
    controller
        .browserResource(chat.key.workspace.profileName)
        .gateway
        .onConnectionChanged!(false);
    await restoreComposerFixture(
      chat: chat,
      preferences: controller.preferences,
      text: 'Keep reconnecting draft',
      appendQueued: [QueuedPromptDraft(text: 'keep queued')],
      paused: true,
    );
    const payload = AndroidSharePayload(
      text: 'Shared while reconnecting',
      files: [
        AndroidSharedFile(
          path: '/file',
          name: 'file.txt',
          mediaType: 'text/plain',
          byteLength: 1,
        ),
      ],
    );
    await controller.stageSharedDraft(chat, payload);

    expect(
      chat.composer.observation.text,
      'Keep reconnecting draft\n\nShared while reconnecting',
    );
    expect(chat.composer.observation.attachments.single.name, 'file.txt');
    expect(chat.composer.observation.queue.single.text, 'keep queued');
    expect(chat.composer.observation.paused, isTrue);
  });

  test('foreign chat cannot stage attachments into the owned draft', () async {
    final foreign = composeChat(
      controller: controller,
      preferences: controller.preferences,
      key: chat.key,
      runtime: ChatRuntime(runtimeId: chat.runtime.runtimeId),
      title: chat.title,
    );
    await expectLater(
      controller.stageSharedDraft(foreign, _sharedFile),
      throwsArgumentError,
    );
    expect(attachments.prepareCount, 0);
  });
}

const _sharedFile = AndroidSharePayload(
  text: 'Shared',
  files: [
    AndroidSharedFile(
      path: '/incoming/shared.txt',
      name: 'shared.txt',
      mediaType: 'text/plain',
      byteLength: 1,
    ),
  ],
);

class _FailingPreferences extends InMemorySharedPreferencesStore {
  _FailingPreferences() : super.empty();
  Completer<void>? started;
  Completer<void>? release;
  bool _failNextSet = false;

  void failNextWrite() {
    started = Completer<void>();
    release = Completer<void>();
    _failNextSet = true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (_failNextSet) {
      _failNextSet = false;
      started!.complete();
      await release!.future;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

AttachmentDraft _draft(String id, {required String name}) => AttachmentDraft(
  id: id,
  cachedPath: '/cache/$id',
  name: name,
  byteLength: 1,
  mediaType: 'text/plain',
  kind: AttachmentDraftKind.genericFile,
);

class _RecordingAttachmentService extends AttachmentDraftService {
  int prepareCount = 0;
  int? failAt;
  Completer<void>? gate;
  final started = Completer<void>();
  final existingCounts = <int>[];
  final removedIds = <String>[];

  Future<AttachmentDraft> _prepare({
    required String displayName,
    required String mediaType,
    required Iterable<AttachmentDraft> existingDrafts,
    required bool image,
  }) async {
    prepareCount++;
    existingCounts.add(existingDrafts.length);
    if (!started.isCompleted) started.complete();
    await gate?.future;
    if (prepareCount == failAt) {
      throw const AttachmentDraftException('Shared file rejected');
    }
    return AttachmentDraft(
      id: 'shared-$prepareCount',
      cachedPath: '/cache/shared-$prepareCount',
      name: displayName,
      byteLength: 1,
      mediaType: mediaType,
      kind: image ? AttachmentDraftKind.image : AttachmentDraftKind.genericFile,
      sourceImageFormat: image ? AttachmentImageFormat.jpeg : null,
      sanitized: image,
    );
  }

  @override
  Future<AttachmentDraft> prepareImage({
    required String sourcePath,
    required String displayName,
    required Iterable<AttachmentDraft> existingDrafts,
    void Function(AttachmentImageJob)? onImageJob,
  }) => _prepare(
    displayName: displayName,
    mediaType: 'image/jpeg',
    existingDrafts: existingDrafts,
    image: true,
  );

  @override
  Future<AttachmentDraft> prepareGenericFile({
    required String sourcePath,
    required String displayName,
    String mediaType = 'application/octet-stream',
    required Iterable<AttachmentDraft> existingDrafts,
  }) => _prepare(
    displayName: displayName,
    mediaType: mediaType,
    existingDrafts: existingDrafts,
    image: false,
  );

  @override
  Future<void> removeCachedFile(AttachmentDraft draft) async {
    removedIds.add(draft.id);
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory sandbox;
  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    sandbox = await Directory.systemTemp.createTemp('hermes-composer-draft-');
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  Future<AttachmentDraft> attachment(String name) async {
    final file = File('${sandbox.path}${Platform.pathSeparator}$name');
    await file.writeAsString('payload');
    return AttachmentDraft(
      id: name,
      cachedPath: file.path,
      name: name,
      byteLength: await file.length(),
      mediaType: 'text/plain',
      kind: AttachmentDraftKind.genericFile,
    );
  }

  test('voice origin and recent speech survive outbox reload', () async {
    final store = ComposerDraftStore(preferences, connectionIdentity: 'host');
    await store.write(
      profileName: 'work',
      sessionId: 'one',
      text: '',
      attachments: [],
      queuedPrompts: [
        QueuedPromptDraft(
          text: 'Use Hermes',
          voiceContext: 'Voice: I will ask Hermes.',
          submissionId: 'input-one',
        ),
      ],
    );
    final restored = await store.read(profileName: 'work', sessionId: 'one');
    expect(
      restored!.queuedPrompts.single.voiceContext,
      'Voice: I will ask Hermes.',
    );
    expect(restored.queuedPrompts.single.submissionId, 'input-one');
  });

  test(
    'retains accepted image ownership and resets it for a new session',
    () async {
      final file = File('${sandbox.path}/picture.png');
      await file.writeAsBytes([1, 2, 3, 4]);
      final image = AttachmentDraft(
        id: 'picture',
        cachedPath: file.path,
        name: 'picture.png',
        byteLength: 4,
        mediaType: 'image/png',
        kind: AttachmentDraftKind.image,
        sanitized: true,
        status: AttachmentDraftStatus.attached,
        imagePath: '/profile/images/picture.png',
        attachedSessionId: 'runtime',
      );
      final store = ComposerDraftStore(preferences, connectionIdentity: 'host');
      await store.write(
        profileName: 'work',
        sessionId: 'one',
        text: 'Read it',
        attachments: [image],
      );
      final restored = (await store.read(
        profileName: 'work',
        sessionId: 'one',
      ))!.attachments.single;
      expect(restored.hasGatewayAttachment, isTrue);
      expect(restored.imagePath, image.imagePath);
      expect(restored.attachedSessionId, 'runtime');
      final moved = (await store.move(
        profileName: 'work',
        fromSessionId: 'one',
        toSessionId: 'two',
        forNewSession: true,
      ))!.attachments.single;
      expect(moved.status, AttachmentDraftStatus.ready);
      expect(moved.imagePath, isNull);
      expect(moved.attachedSessionId, isNull);
      expect(await File(moved.cachedPath).exists(), isTrue);
    },
  );

  test(
    'separates drafts by connection identity, profile, and session',
    () async {
      final first = ComposerDraftStore(
        preferences,
        connectionIdentity: 'host-auth-a',
      );
      final second = ComposerDraftStore(
        preferences,
        connectionIdentity: 'host-auth-b',
      );
      await first.write(
        profileName: 'work',
        sessionId: 'one',
        text: 'first',
        attachments: [await attachment('first.txt')],
      );
      await first.write(
        profileName: 'personal',
        sessionId: 'one',
        text: 'second',
        attachments: const [],
      );
      await second.write(
        profileName: 'work',
        sessionId: 'one',
        text: 'third',
        attachments: const [],
      );

      await first.write(
        profileName: 'work',
        sessionId: 'two',
        text: 'fourth',
        attachments: const [],
      );
      expect(
        (await first.read(profileName: 'work', sessionId: 'two'))!.text,
        'fourth',
      );

      expect(
        (await first.read(profileName: 'work', sessionId: 'one'))!.text,
        'first',
      );
      expect(
        (await first.read(profileName: 'personal', sessionId: 'one'))!.text,
        'second',
      );
      expect(
        (await second.read(profileName: 'work', sessionId: 'one'))!.text,
        'third',
      );
    },
  );

  test('missing attachment reports failure without losing text', () async {
    final store = ComposerDraftStore(
      preferences,
      connectionIdentity: 'host-auth',
    );
    final file = await attachment('missing.txt');
    await store.write(
      profileName: 'work',
      sessionId: 'chat',
      text: 'keep this text',
      attachments: [file],
    );
    await File(file.cachedPath).delete();

    final restored = await store.read(profileName: 'work', sessionId: 'chat');
    expect(restored!.text, 'keep this text');
    expect(restored.attachments.single.status, AttachmentDraftStatus.failed);
    expect(restored.attachments.single.error, contains('no longer available'));
  });

  test('empty draft removes its durable record', () async {
    final store = ComposerDraftStore(
      preferences,
      connectionIdentity: 'host-auth',
    );
    await store.write(
      profileName: 'work',
      sessionId: 'chat',
      text: 'temporary',
      attachments: const [],
    );
    await store.write(
      profileName: 'work',
      sessionId: 'chat',
      text: '',
      attachments: const [],
    );

    expect(await store.read(profileName: 'work', sessionId: 'chat'), isNull);
    expect(
      preferences.getKeys().where((key) => key.startsWith('composer_work_v3.')),
      isEmpty,
    );
  });

  test('keeps the lost-acknowledgement marker with its draft', () async {
    final store = ComposerDraftStore(
      preferences,
      connectionIdentity: 'host-auth',
    );
    await store.write(
      profileName: 'work',
      sessionId: 'chat',
      text: 'possibly accepted',
      attachments: const [],
      submissionUncertain: true,
    );

    final restored = await store.read(profileName: 'work', sessionId: 'chat');
    expect(restored!.submissionUncertain, isTrue);
  });

  test('round trips queued attachments and their paused state', () async {
    final store = ComposerDraftStore(
      preferences,
      connectionIdentity: 'host-auth',
    );
    final file = await attachment('queued.txt');
    await store.write(
      profileName: 'work',
      sessionId: 'chat',
      text: '',
      attachments: const [],
      queuedPrompts: [
        QueuedPromptDraft(text: '', attachments: [file]),
      ],
      queuePaused: true,
    );

    final restored = await store.read(profileName: 'work', sessionId: 'chat');
    expect(restored!.queuePaused, isTrue);
    expect(restored.queuedPrompts.single.text, isEmpty);
    expect(restored.queuedPrompts.single.attachments.single.id, 'queued.txt');
  });

  test(
    'round trips queue dispatch uncertainty independently of composer',
    () async {
      final store = ComposerDraftStore(
        preferences,
        connectionIdentity: 'host-auth',
      );
      await store.write(
        profileName: 'work',
        sessionId: 'chat',
        text: 'Fresh composer',
        attachments: const [],
        queuedPrompts: [
          QueuedPromptDraft(
            text: 'Dispatched outgoing',
            submissionUncertain: true,
          ),
          QueuedPromptDraft(text: 'Ordinary queued work'),
        ],
        queuePaused: true,
      );
      final restored = await store.read(profileName: 'work', sessionId: 'chat');
      expect(restored!.text, 'Fresh composer');
      expect(restored.submissionUncertain, isFalse);
      expect(
        restored.queuedPrompts.map((prompt) => prompt.submissionUncertain),
        [true, false],
      );
      final moved = await store.move(
        profileName: 'work',
        fromSessionId: 'chat',
        toSessionId: 'replacement',
        forNewSession: true,
      );
      expect(moved!.queuedPrompts.first.submissionUncertain, isTrue);
    },
  );

  test('damaged queue entries do not discard valid unsent work', () async {
    final store = ComposerDraftStore(
      preferences,
      connectionIdentity: 'host-auth',
    );
    await store.write(
      profileName: 'work',
      sessionId: 'chat',
      text: 'Existing composer',
      attachments: const [],
      queuedPrompts: [QueuedPromptDraft(text: 'Valid queued work')],
      queuePaused: true,
    );
    final key = preferences.getKeys().single;
    final record =
        jsonDecode(preferences.getString(key)!) as Map<String, dynamic>;
    record['queue'] = [
      null,
      'not a supported queue record',
      {'text': 42, 'attachments': []},
      ...(record['queue'] as List),
      {
        'text': 'bad uncertainty',
        'attachments': [],
        'submission_uncertain': 42,
      },
    ];
    await preferences.setString(key, jsonEncode(record));
    final restored = (await store.read(
      profileName: 'work',
      sessionId: 'chat',
    ))!;
    expect(restored.text, 'Existing composer');
    expect(restored.queuedPrompts.single.text, 'Valid queued work');
    expect(restored.queuePaused, isTrue);
  });

  test('old combined storage is not read or converted', () async {
    const oldKey = 'composer_drafts_v1_host-auth';
    final oldValue = jsonEncode([
      {
        'profile': 'work',
        'session': 'chat',
        'text': 'Old draft',
        'attachments': [],
        'queue': ['Old queued work'],
      },
    ]);
    await preferences.setString(oldKey, oldValue);
    final store = ComposerDraftStore(
      preferences,
      connectionIdentity: 'host-auth',
    );
    expect(await store.read(profileName: 'work', sessionId: 'chat'), isNull);
    expect(store.summaries(profileName: 'work'), isEmpty);
    await store.write(
      profileName: 'work',
      sessionId: 'chat',
      text: 'New draft',
      attachments: const [],
    );
    expect(
      (await store.read(profileName: 'work', sessionId: 'chat'))!.text,
      'New draft',
    );
    expect(preferences.getString(oldKey), oldValue);
  });

  test(
    'moving to a new session resets remote refs and pauses queues',
    () async {
      final store = ComposerDraftStore(
        preferences,
        connectionIdentity: 'host-auth',
      );
      final cached = await attachment('cached.txt');
      cached
        ..status = AttachmentDraftStatus.attached
        ..refText = '@cached'
        ..atlasIntakeAccepted = true;
      final missing = await attachment('missing.txt');
      missing
        ..status = AttachmentDraftStatus.attached
        ..refText = '@missing';
      await File(missing.cachedPath).delete();
      final queued = await attachment('queued.txt');
      queued
        ..status = AttachmentDraftStatus.attached
        ..refText = '@queued';
      await store.write(
        profileName: 'work',
        sessionId: 'expired',
        text: 'keep this text',
        attachments: [cached, missing],
        submissionUncertain: true,
        queuedPrompts: [
          QueuedPromptDraft(text: 'later', attachments: [queued]),
        ],
      );

      final moved = await store.move(
        profileName: 'work',
        fromSessionId: 'expired',
        toSessionId: 'new',
        forNewSession: true,
      );

      expect(moved!.text, 'keep this text');
      expect(moved.submissionUncertain, isTrue);
      expect(moved.queuePaused, isTrue);
      expect(moved.attachments.first.status, AttachmentDraftStatus.ready);
      expect(moved.attachments.first.refText, isNull);
      expect(moved.attachments.first.atlasIntakeAccepted, isNull);
      expect(moved.attachments.last.status, AttachmentDraftStatus.failed);
      expect(moved.attachments.last.refText, isNull);
      expect(moved.attachments.last.error, contains('no longer available'));
      final queuedMoved = moved.queuedPrompts.single.attachments.single;
      expect(queuedMoved.status, AttachmentDraftStatus.ready);
      expect(queuedMoved.refText, isNull);
      expect(
        await store.read(profileName: 'work', sessionId: 'expired'),
        isNull,
      );
      final durable = await store.read(profileName: 'work', sessionId: 'new');
      expect(durable!.queuePaused, isTrue);
      expect(durable.attachments.first.status, AttachmentDraftStatus.ready);
      expect(durable.attachments.last.status, AttachmentDraftStatus.failed);
    },
  );
}

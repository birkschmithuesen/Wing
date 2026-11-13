import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:wing/core/services/composer_draft_store.dart';

typedef _Operation = ({String method, String key, Object? value});

class _RecordingPreferences extends InMemorySharedPreferencesStore {
  _RecordingPreferences() : super.empty();

  final operations = <_Operation>[];
  Completer<void>? nextSetDelay;
  String? failNextRemoveKey;
  String? failNextSetKey;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    operations.add((method: 'set', key: key, value: value));
    final delay = nextSetDelay;
    nextSetDelay = null;
    if (delay != null) await delay.future;
    if (failNextSetKey == key) {
      failNextSetKey = null;
      return false;
    }
    return super.setValue(valueType, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    operations.add((method: 'remove', key: key, value: null));
    if (failNextRemoveKey == key) {
      failNextRemoveKey = null;
      return false;
    }
    return super.remove(key);
  }
}

String _key(String connection, String profile, String session) {
  String component(String value) => base64Url.encode(utf8.encode(value));
  return 'composer_work_v3.${component(connection)}.'
      '${component(profile)}.${component(session)}';
}

void main() {
  late SharedPreferences preferences;
  late _RecordingPreferences platform;
  late ComposerDraftStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    platform = _RecordingPreferences();
    SharedPreferencesStorePlatform.instance = platform;
    preferences = await SharedPreferences.getInstance();
    store = ComposerDraftStore(preferences, connectionIdentity: 'host');
  });

  tearDown(() => SharedPreferences.setMockInitialValues({}));

  Future<void> write(String session, String text, {String profile = 'work'}) =>
      store.write(
        profileName: profile,
        sessionId: session,
        text: text,
        attachments: const [],
      );

  test('empty composer creates no stored record', () async {
    await write('target', '');
    expect(platform.operations, isEmpty);
    expect(preferences.getKeys(), isEmpty);
    expect(store.revision, 0);
  });

  test('unchanged record does no platform work', () async {
    await write('target', 'First character');
    final revision = store.revision;
    platform.operations.clear();
    await write('target', 'First character');
    expect(platform.operations, isEmpty);
    expect(store.revision, revision);
  });

  test(
    'editing and deleting touch only one record despite unrelated large or corrupt records',
    () async {
      await write('target', 'After edit');
      final baseline = platform.operations.single.value;
      for (var i = 0; i < 40; i++) {
        await write('unrelated-$i', 'Large draft $i ${'x' * 65536}');
      }
      final corruptKey = _key('host', 'work', 'unrelated-corrupt');
      await preferences.setString(corruptKey, '{damaged json');
      await write('target', 'Before edit');
      final unrelated = {
        for (final key in preferences.getKeys())
          if (key != _key('host', 'work', 'target')) key: preferences.get(key),
      };
      platform.operations.clear();

      await write('target', 'After edit');
      expect(platform.operations, [
        (
          method: 'set',
          key: 'flutter.${_key('host', 'work', 'target')}',
          value: baseline,
        ),
      ]);
      expect(preferences.getString(_key('host', 'work', 'target')), baseline);
      for (final entry in unrelated.entries) {
        expect(preferences.get(entry.key), entry.value);
      }

      platform.operations.clear();
      await write('target', '');
      expect(platform.operations, [
        (
          method: 'remove',
          key: 'flutter.${_key('host', 'work', 'target')}',
          value: null,
        ),
      ]);
      expect(
        await store.read(profileName: 'work', sessionId: 'target'),
        isNull,
      );
      expect(preferences.getKeys(), unrelated.keys.toSet());
      for (final entry in unrelated.entries) {
        expect(preferences.get(entry.key), entry.value);
      }
      expect(store.summaries(profileName: 'work'), hasLength(40));
    },
  );

  test(
    'wrong-typed corrupted records are isolated and can be replaced or removed',
    () async {
      final key = _key('host', 'work', 'target');
      await preferences.setInt(key, 42);
      await write('unrelated', 'Keep this draft');
      expect(
        await store.read(profileName: 'work', sessionId: 'target'),
        isNull,
      );
      expect(
        store.summaries(profileName: 'work').map((draft) => draft.sessionId),
        ['unrelated'],
      );
      final revision = store.revision;
      platform.failNextSetKey = 'flutter.$key';
      await expectLater(
        write('target', 'Failed replacement'),
        throwsStateError,
      );
      expect(preferences.get(key), 42);
      expect(store.revision, revision);
      await preferences.reload();
      expect(preferences.get(key), 42);
      await write('target', 'Recovered draft');
      expect(
        (await store.read(profileName: 'work', sessionId: 'target'))!.text,
        'Recovered draft',
      );
      await preferences.setBool(key, true);
      await write('target', '');
      expect(preferences.containsKey(key), isFalse);
      expect(
        (await store.read(profileName: 'work', sessionId: 'unrelated'))!.text,
        'Keep this draft',
      );
    },
  );

  test(
    'record identities isolate delimiter collisions, Unicode and profiles',
    () async {
      final identities = [
        (profile: 'a.b', session: 'c'),
        (profile: 'a', session: 'b.c'),
        (profile: 'a_b', session: 'c'),
        (profile: 'a', session: 'b_c'),
        (profile: '日本語.é', session: '聊 天/🙂'),
      ];
      for (var i = 0; i < identities.length; i++) {
        await write(
          identities[i].session,
          'Draft $i',
          profile: identities[i].profile,
        );
      }
      final other = ComposerDraftStore(
        preferences,
        connectionIdentity: 'host.other',
      );
      await other.write(
        profileName: 'a',
        sessionId: 'b.c',
        text: 'Other host',
        attachments: const [],
      );
      expect(preferences.getKeys(), hasLength(identities.length + 1));
      for (var i = 0; i < identities.length; i++) {
        expect(
          (await store.read(
            profileName: identities[i].profile,
            sessionId: identities[i].session,
          ))!.text,
          'Draft $i',
        );
      }
      expect(
        store.summaries(profileName: 'a').map((draft) => draft.text),
        unorderedEquals(['Draft 1', 'Draft 3']),
      );
      expect(
        (await other.read(profileName: 'a', sessionId: 'b.c'))!.text,
        'Other host',
      );
    },
  );

  test(
    'shared stores order an older save before deletion while unrelated chat progresses',
    () async {
      final other = ComposerDraftStore(preferences, connectionIdentity: 'host');
      final delay = Completer<void>();
      platform.nextSetDelay = delay;
      final older = write('target', 'Older save');
      final deletion = other.write(
        profileName: 'work',
        sessionId: 'target',
        text: '',
        attachments: const [],
      );
      final unrelated = write('other', 'Independent');
      await unrelated;
      expect(platform.operations.map((op) => op.method), ['set', 'set']);
      expect(platform.operations.map((op) => op.key), [
        'flutter.${_key('host', 'work', 'target')}',
        'flutter.${_key('host', 'work', 'other')}',
      ]);
      delay.complete();
      await Future.wait([older, deletion]);
      expect(platform.operations.last.method, 'remove');
      expect(
        await store.read(profileName: 'work', sessionId: 'target'),
        isNull,
      );
      expect(
        (await other.read(profileName: 'work', sessionId: 'other'))!.text,
        'Independent',
      );
      expect(other.revision, store.revision);
      await preferences.reload();
      expect(
        await store.read(profileName: 'work', sessionId: 'target'),
        isNull,
      );
    },
  );

  test(
    'queued writes capture mutable attachment and queue state at invocation',
    () async {
      final delay = Completer<void>();
      platform.nextSetDelay = delay;
      final older = write('target', 'Older');
      final attachment = AttachmentDraft(
        id: 'file',
        cachedPath: '/not-read-during-save',
        name: 'file.txt',
        byteLength: 1,
        mediaType: 'text/plain',
        kind: AttachmentDraftKind.genericFile,
      );
      final queued = QueuedPromptDraft(
        text: 'Queued before mutation',
        attachments: [attachment],
      );
      final queuedRecords = [queued];
      final captured = store.write(
        profileName: 'work',
        sessionId: 'target',
        text: 'Captured',
        attachments: [attachment],
        queuedPrompts: queuedRecords,
      );
      attachment.status = AttachmentDraftStatus.uploading;
      attachment.refText = '@later';
      queuedRecords[0] = QueuedPromptDraft(
        text: queued.text,
        attachments: queued.attachments,
        submissionUncertain: true,
      );
      delay.complete();
      await Future.wait([older, captured]);
      final record =
          jsonDecode(platform.operations.last.value! as String)
              as Map<String, dynamic>;
      final files = record['attachments'] as List;
      final queue = record['queue'] as List;
      expect(files.single['status'], 'ready');
      expect(files.single['ref_text'], isNull);
      expect(queue.single['submission_uncertain'], isNull);
      expect(queue.single['attachments'].single['status'], 'ready');
    },
  );

  test(
    'queue-only record remains until its last unsent item is removed',
    () async {
      await store.write(
        profileName: 'work',
        sessionId: 'target',
        text: '',
        attachments: const [],
        queuedPrompts: [
          QueuedPromptDraft(
            text: 'Awaiting acknowledgement',
            submissionUncertain: true,
          ),
        ],
        queuePaused: true,
      );
      expect(store.summaries(profileName: 'work').single.queuedCount, 1);
      await preferences.reload();
      final recovered = (await store.read(
        profileName: 'work',
        sessionId: 'target',
      ))!;
      expect(recovered.text, isEmpty);
      expect(recovered.queuedPrompts.single.submissionUncertain, isTrue);
      await write('target', '');
      expect(preferences.getKeys(), isEmpty);
    },
  );

  test(
    'failed save restores the prior record and does not poison later writes',
    () async {
      await write('target', 'Durable original');
      final revision = store.revision;
      platform.failNextSetKey = 'flutter.${_key('host', 'work', 'target')}';
      await expectLater(write('target', 'Failed edit'), throwsStateError);
      expect(store.revision, revision);
      expect(
        (await store.read(profileName: 'work', sessionId: 'target'))!.text,
        'Durable original',
      );
      await preferences.reload();
      expect(
        (await store.read(profileName: 'work', sessionId: 'target'))!.text,
        'Durable original',
      );
      await write('target', 'Later good edit');
      expect(
        (await store.read(profileName: 'work', sessionId: 'target'))!.text,
        'Later good edit',
      );
    },
  );

  test('move reserves both records against overlapping writes', () async {
    await write('source', 'Original to move');
    platform.operations.clear();
    final delay = Completer<void>();
    platform.nextSetDelay = delay;
    final moving = store.move(
      profileName: 'work',
      fromSessionId: 'source',
      toSessionId: 'destination',
    );
    final otherStore = ComposerDraftStore(
      preferences,
      connectionIdentity: 'host',
    );
    final edit = otherStore.write(
      profileName: 'work',
      sessionId: 'destination',
      text: 'New destination edit',
      attachments: const [],
    );
    final removeOld = write('source', '');
    expect(platform.operations, hasLength(1));
    delay.complete();
    await Future.wait([moving, edit, removeOld]);
    await preferences.reload();
    expect(await store.read(profileName: 'work', sessionId: 'source'), isNull);
    expect(
      (await store.read(profileName: 'work', sessionId: 'destination'))!.text,
      'New destination edit',
    );
    expect(platform.operations.map((op) => (op.method, op.key)), [
      ('set', 'flutter.${_key('host', 'work', 'destination')}'),
      ('remove', 'flutter.${_key('host', 'work', 'source')}'),
      ('set', 'flutter.${_key('host', 'work', 'destination')}'),
    ]);
  });

  test(
    'move rejects occupied destination without changing either record',
    () async {
      await write('source', 'Source');
      await write('destination', 'Destination');
      platform.operations.clear();
      await expectLater(
        store.move(
          profileName: 'work',
          fromSessionId: 'source',
          toSessionId: 'destination',
        ),
        throwsStateError,
      );
      expect(platform.operations, isEmpty);
      expect(
        (await store.read(profileName: 'work', sessionId: 'source'))!.text,
        'Source',
      );
      expect(
        (await store.read(profileName: 'work', sessionId: 'destination'))!.text,
        'Destination',
      );
    },
  );

  test(
    'failed source removal rolls back move and preserves durable source',
    () async {
      await write('source', 'Recoverable');
      platform.operations.clear();
      platform.failNextRemoveKey = 'flutter.${_key('host', 'work', 'source')}';
      await expectLater(
        store.move(
          profileName: 'work',
          fromSessionId: 'source',
          toSessionId: 'destination',
        ),
        throwsStateError,
      );
      expect(platform.operations.map((op) => (op.method, op.key)), [
        ('set', 'flutter.${_key('host', 'work', 'destination')}'),
        ('remove', 'flutter.${_key('host', 'work', 'source')}'),
        ('set', 'flutter.${_key('host', 'work', 'source')}'),
        ('remove', 'flutter.${_key('host', 'work', 'destination')}'),
      ]);
      await preferences.reload();
      expect(
        (await store.read(profileName: 'work', sessionId: 'source'))!.text,
        'Recoverable',
      );
      expect(
        await store.read(profileName: 'work', sessionId: 'destination'),
        isNull,
      );
      await store.move(
        profileName: 'work',
        fromSessionId: 'source',
        toSessionId: 'destination',
      );
      expect(
        await store.read(profileName: 'work', sessionId: 'source'),
        isNull,
      );
      expect(
        (await store.read(profileName: 'work', sessionId: 'destination'))!.text,
        'Recoverable',
      );
    },
  );
}

import 'package:wing/core/models/canonical_session.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/models/composer_reference.dart';
import 'package:wing/core/models/composer_work.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:wing/core/services/attachment_draft_service.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:wing/core/services/composer_session.dart';

class _Store extends ComposerDraftStore {
  _Store(super.preferences)
    : super(connectionIdentity: 'steering-delivery-test');

  bool failNextWrite = false;

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
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('Draft save refused.');
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
  TestWidgetsFlutterBinding.ensureInitialized();
  final key = ProfileSessionKey(
    WorkspaceScope(
      connectionId: 'host',
      connectionIdentity: 'steering-delivery-test',
      profileName: 'default',
    ),
    'chat',
  );
  const reference = ComposerReference(
    kind: ComposerReferenceKind.file,
    token: '@file:/work/note.md',
    target: '/work/note.md',
  );
  late _Store store;
  late ComposerSession composer;
  var working = true;

  ComposerSession create() => ComposerSession(
    key: key,
    store: store,
    attachments: AttachmentDraftService(),
    ensureAvailable: () {},
    acknowledgedDeletion: () => false,
    onChanged: (_) {},
    runtime: () => ComposerRuntimeObservation(
      runtimeId: 'runtime',
      working: working,
      canSteer: working,
      attachmentBlocked: false,
      connected: true,
      automaticDrainAvailable: true,
      switching: false,
      changingAnswer: false,
      commandRunning: false,
      changingIntelligence: false,
      failedOrCancelled: false,
      historyAvailable: true,
    ),
  );
  Future<ComposerDraftSnapshot> saved() async =>
      (await store.read(profileName: 'default', sessionId: 'chat'))!;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = _Store(await SharedPreferences.getInstance());
    working = true;
    composer = create();
    await composer.restore();
  });
  tearDown(() => composer.dispose());

  CanonicalAdmission admission(
    String id, {
    String status = 'queued',
    List<String> controls = const ['steer', 'replace'],
  }) => CanonicalAdmission(
    id: id,
    inputId: 'input-$id',
    sessionId: 'runtime',
    sequence: 1,
    status: status,
    text: 'Identical text',
    generation: 2,
    controls: controls,
  );

  test('queued edit rejection reports the observed cause', () async {
    composer.observePending([admission('one', controls: [])]);
    final id = composer.observation.queue.single.id;
    await expectLater(
      composer.beginEdit(id),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Hermes does not allow editing this queued message.',
        ),
      ),
    );
    composer.observePending([
      admission('one', status: 'unknown', controls: []),
    ]);
    await expectLater(
      composer.beginEdit(id),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Hermes cannot determine whether this message ran. It cannot be changed.',
        ),
      ),
    );
    composer.observePending([]);
    await expectLater(
      composer.beginEdit(id),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'This message is no longer in the queue.',
        ),
      ),
    );
  });

  test(
    'accepted identical rows retain separate identity and server controls',
    () async {
      composer.observePending([
        admission('one'),
        admission('two', controls: []),
      ]);
      final rows = composer.observation.queue;
      expect(rows, hasLength(2));
      expect(rows.every((row) => row.serverOwned), isTrue);
      expect(rows.first.id, isNot(same(rows.last.id)));
      expect(composer.queueActions(rows.first.id).canEdit, isTrue);
      expect(composer.queueActions(rows.last.id).canEdit, isFalse);
      await expectLater(composer.beginEdit(rows.last.id), throwsStateError);
      composer.observePending([admission('two', controls: [])]);
      expect(composer.observation.queue.single.id, same(rows.last.id));
      var dispatches = 0;
      await composer.drain((_) async {
        dispatches++;
        return true;
      });
      expect(dispatches, 0);
    },
  );

  test(
    'unknown acceptance offers acknowledgment but cannot edit or steer',
    () async {
      composer.observePending([
        admission('unknown', status: 'unknown', controls: []),
      ]);
      final row = composer.observation.queue.single;
      expect(row.unknownOutcome, isTrue);
      expect(
        (
          canEdit: composer.queueActions(row.id).canEdit,
          canSteer: composer.queueActions(row.id).canSteer,
          canDelete: composer.queueActions(row.id).canDelete,
        ),
        (canEdit: false, canSteer: false, canDelete: true),
      );
    },
  );

  test(
    'a claimed steering transfer remains visible without queue controls until settled',
    () async {
      final transferred = CanonicalAdmission.fromJson({
        'admission_id': 'one',
        'input_id': 'input-one',
        'ref': {'session_id': 'runtime', 'profile_id': '/profile'},
        'sequence': 1,
        'status': 'started',
        'text': 'Identical text',
        'execution_generation': 2,
        'steering': true,
        'controls': [],
      });
      composer.observePending([admission('one')]);
      final id = composer.observation.queue.single.id;
      composer.observePending([transferred]);
      expect(composer.observation.queue.single.id, same(id));
      expect(composer.observation.queue.single.pendingSteering, isTrue);
      expect(
        (
          canEdit: composer.queueActions(id).canEdit,
          canSteer: composer.queueActions(id).canSteer,
          canDelete: composer.queueActions(id).canDelete,
        ),
        (canEdit: false, canSteer: false, canDelete: false),
      );
      composer.observePending([admission('one')]);
      expect(composer.observation.queue.single.id, same(id));
      expect(composer.queueActions(id).canEdit, isTrue);
      composer.observePending([]);
      expect(composer.observation.queue, isEmpty);
    },
  );

  test(
    'process recovery replays exact durable payload and ID, preserving newer draft',
    () async {
      await composer.editText('Original');
      final ticket = await composer.beginSubmission();
      final payload = <String, dynamic>{
        'session_id': 'runtime',
        'submission_id': ticket.submissionId,
        'text': 'Expanded skill instructions',
        'attachments': [
          {'path': '/cache/upload.png', 'mime': 'image/png'},
        ],
      };
      await composer.prepareDispatch(ticket, payload: payload);
      await composer.settle(ticket, ComposerDelivery.uncertain);
      composer.dispose();
      composer = create();
      await composer.restore();
      await composer.editText('Newer draft');
      var dispatches = 0;
      await composer.reconcileSubmissions((wire) async {
        dispatches++;
        expect(wire, payload);
        return admission('accepted', status: 'started');
      });
      expect(dispatches, 1);
      expect(composer.observation.text, 'Newer draft');
      expect(composer.observation.queue, isEmpty);
      await composer.reconcileSubmissions((_) async {
        fail('Retired input replayed twice');
      });
      expect((await saved()).queuedPrompts, isEmpty);
    },
  );

  test(
    'direct steering captures the selected entry and its references',
    () async {
      await composer.enqueue('Same');
      final text = 'Same ${reference.token}';
      await composer.editText(text, reference: reference);
      await composer.enqueue(text);
      await composer.editText('Separate draft');
      final first = composer.observation.queue.first.id;
      final selected = composer.observation.queue.last.id;
      final entered = Completer<void>();
      final receipt = Completer<bool>();
      final steering = composer.steerQueued(selected, (
        value,
        references,
      ) async {
        expect(value, text);
        expect(references, [reference]);
        final persisted = await saved();
        expect(persisted.queuedPrompts.last.submissionUncertain, isTrue);
        expect(persisted.text, 'Separate draft');
        entered.complete();
        return receipt.future;
      });
      await entered.future;
      expect(composer.observation.queue, hasLength(2));
      expect(composer.queueActions(selected).canSteer, isFalse);
      await composer.editText('Newer draft');
      receipt.complete(true);
      expect(await steering, isTrue);
      expect(composer.observation.queue.single.id, same(first));
      expect(composer.observation.text, 'Newer draft');
      expect(composer.observation.editing, isNull);
      var dispatches = 0;
      expect(
        await composer.steerQueued(selected, (_, _) async {
          dispatches++;
          return true;
        }),
        isFalse,
      );
      expect(dispatches, 0);
    },
  );

  test(
    'direct steering shares rejection and uncertain-delivery recovery',
    () async {
      await composer.enqueue('Selected');
      await composer.editText('Separate draft');
      final selected = composer.observation.queue.single.id;
      expect(
        await composer.steerQueued(selected, (_, _) async => false),
        isFalse,
      );
      expect(composer.queueActions(selected).canSteer, isTrue);
      expect(composer.observation.queue.single.submissionUncertain, isFalse);
      await expectLater(
        composer.steerQueued(selected, (_, _) async {
          throw TimeoutException('Receipt lost');
        }),
        throwsA(isA<TimeoutException>()),
      );
      expect(composer.observation.paused, isTrue);
      expect(composer.observation.queue.single.submissionUncertain, isTrue);
      expect(composer.queueActions(selected).canSteer, isFalse);
      expect(composer.observation.text, 'Separate draft');
      composer.dispose();
      composer = create();
      await composer.restore();
      expect(composer.observation.queue.single.submissionUncertain, isTrue);
      expect(
        composer.queueActions(composer.observation.queue.single.id).canSteer,
        isFalse,
      );
    },
  );

  test('edited steering is durable and uncertain before delivery', () async {
    await composer.enqueue('Original');
    await composer.editText('Separate draft');
    await composer.beginEdit(composer.observation.queue.single.id);
    final text = 'Read ${reference.token} instead';
    composer.editQueuedText(text, reference: reference);
    final dispatched = Completer<void>();
    final receipt = Completer<bool>();
    late String offeredText;
    late ComposerDraftSnapshot offered;
    final steering = composer.steerEdit((value, references) async {
      offeredText = value;
      expect(references.single, reference);
      offered = await saved();
      dispatched.complete();
      return receipt.future;
    });
    await dispatched.future;
    await composer.editText('Newer separate draft');
    receipt.complete(true);
    expect(await steering, isTrue);
    expect(offeredText, text);
    expect(offered.queuedPrompts.single.text, text);
    expect(
      offered.queuedPrompts.single.references.single.target,
      reference.target,
    );
    expect(offered.queuedPrompts.single.submissionUncertain, isTrue);
    expect(offered.queuePaused, isTrue);
    expect(offered.text, 'Separate draft');
    expect(composer.observation.queue, isEmpty);
    expect(composer.observation.text, 'Newer separate draft');
    expect((await saved()).text, 'Newer separate draft');
  });

  test(
    'lost receipt cannot resume or resend after cancellation or restart',
    () async {
      await composer.enqueue('Original');
      await composer.editText('Separate draft');
      await composer.beginEdit(composer.observation.queue.single.id);
      composer.editQueuedText('Attempted edited direction');
      var dispatches = 0;
      await expectLater(
        composer.steerEdit((_, _) async {
          dispatches++;
          throw TimeoutException('Steering receipt lost.');
        }),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        composer.observation.queue.single.text,
        'Attempted edited direction',
      );
      expect(composer.observation.queue.single.submissionUncertain, isTrue);
      await composer.cancelEdit();
      working = false;
      await expectLater(composer.resume(() async => true), throwsStateError);
      await composer.drain((_) async {
        dispatches++;
        return false;
      });
      composer.dispose();
      composer = create();
      await composer.restore();
      expect(
        composer.observation.queue.single.text,
        'Attempted edited direction',
      );
      expect(composer.observation.queue.single.submissionUncertain, isTrue);
      expect(composer.observation.text, 'Separate draft');
      expect(composer.observation.paused, isTrue);
      await expectLater(composer.resume(() async => true), throwsStateError);
      await composer.drain((_) async {
        dispatches++;
        return false;
      });
      expect(dispatches, 1);
    },
  );

  test(
    'a restarted owner cannot resend while the steering receipt is held',
    () async {
      await composer.enqueue('Original');
      await composer.beginEdit(composer.observation.queue.single.id);
      composer.editQueuedText('Attempted direction');
      final entered = Completer<void>();
      final receipt = Completer<bool>();
      final steering = composer.steerEdit((_, _) {
        entered.complete();
        return receipt.future;
      });
      await entered.future;
      final restored = create();
      addTearDown(restored.dispose);
      await restored.restore();
      working = false;
      expect(restored.observation.queue.single.text, 'Attempted direction');
      expect(restored.observation.queue.single.submissionUncertain, isTrue);
      await expectLater(restored.resume(() async => true), throwsStateError);
      var sends = 0;
      await restored.drain((_) async {
        sends++;
        return false;
      });
      expect(sends, 0);
      receipt.complete(true);
      expect(await steering, isTrue);
    },
  );

  test(
    'positive rejection restores the original queued entry and keeps the edit',
    () async {
      final original = 'Original ${reference.token}';
      await composer.editText(original, reference: reference);
      await composer.enqueue(original);
      await composer.editText('Separate draft');
      await composer.beginEdit(composer.observation.queue.single.id);
      composer.editQueuedText('Edited direction');
      expect(await composer.steerEdit((_, _) async => false), isFalse);
      expect(composer.observation.queue.single.text, original);
      expect(composer.observation.queue.single.references.single, reference);
      expect(composer.observation.queue.single.submissionUncertain, isFalse);
      expect(composer.observation.editText, 'Edited direction');
      expect(composer.observation.text, 'Separate draft');
      final record = await saved();
      expect(record.queuedPrompts.single.text, original);
      expect(record.queuedPrompts.single.submissionUncertain, isFalse);
      await composer.cancelEdit();
      working = false;
      await composer.resume(() async => true);
      var sends = 0;
      await composer.drain((_) async {
        sends++;
        return false;
      });
      expect(sends, 1);
    },
  );

  test(
    'acknowledgement retires the captured entry among identical queued texts',
    () async {
      await composer.enqueue('Same');
      await composer.enqueue('Same');
      final first = composer.observation.queue.first.id;
      final accepted = composer.observation.queue.last.id;
      await composer.beginEdit(accepted);
      expect(await composer.steerEdit((_, _) async => true), isTrue);
      expect(composer.observation.queue.single.id, same(first));
      expect(composer.observation.queue.single.submissionUncertain, isFalse);
      expect((await saved()).queuedPrompts.single.text, 'Same');
    },
  );

  test(
    'failed preflight persistence never dispatches and restores the queued entry',
    () async {
      await composer.enqueue('Original');
      await composer.editText('Separate draft');
      await composer.beginEdit(composer.observation.queue.single.id);
      composer.editQueuedText('Edited direction');
      store.failNextWrite = true;
      var dispatches = 0;
      await expectLater(
        composer.steerEdit((_, _) async {
          dispatches++;
          return true;
        }),
        throwsStateError,
      );
      expect(dispatches, 0);
      expect(composer.observation.queue.single.text, 'Original');
      expect(composer.observation.queue.single.submissionUncertain, isFalse);
      expect(composer.observation.editText, 'Edited direction');
      expect((await saved()).queuedPrompts.single.text, 'Original');
      expect((await saved()).text, 'Separate draft');
    },
  );
}

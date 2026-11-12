import 'package:wing/core/models/canonical_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/canonical_session_protocol.dart';
import 'package:wing/core/services/ws_client.dart';

Map<String, dynamic> snapshot({
  String id = 'chat',
  String epoch = 'epoch',
  int sequence = 10,
  int revision = 4,
  int generation = 2,
  List<Map<String, dynamic>> pending = const [],
}) => {
  'session_id': id,
  'revision': revision,
  'execution_generation': generation,
  'authority_epoch': 1,
  'replay_epoch': epoch,
  'last_sequence': sequence,
  'subscription_id': 'subscription-$id',
  'pending': pending,
};
Map<String, dynamic> pending(
  String id, {
  String session = 'chat',
  int sequence = 1,
  String status = 'queued',
}) => {
  'admission_id': id,
  'input_id': 'input-$id',
  'ref': {'session_id': session, 'profile_id': '/profile'},
  'sequence': sequence,
  'status': status,
  'text': 'same text',
  'execution_generation': 2,
  'controls': ['steer', 'replace'],
};
void main() {
  test(
    'a late queued ACK cannot resurrect an admission after newer settlement',
    () {
      final owner = CanonicalSessionProtocol()..snapshot(snapshot(sequence: 0));
      owner.event(
        StreamEvent(
          type: 'session.info',
          sessionId: 'chat',
          data: {'pending': []},
          envelope: {'replay_epoch': 'epoch', 'seq': 1},
        ),
      );
      owner.admission(
        CanonicalAdmission.fromJson(pending('late')),
        inputId: 'input-late',
        text: 'same text',
        observedSequence: 0,
      );
      expect(owner.session('chat')!.pending, isEmpty);
    },
  );

  test('an epoch-changing event rejects an older in-flight snapshot', () {
    final owner = CanonicalSessionProtocol()..snapshot(snapshot());
    owner.event(
      StreamEvent(
        type: 'session.info',
        sessionId: 'chat',
        data: {},
        envelope: {'replay_epoch': 'replacement', 'seq': 1},
      ),
    );
    expect(owner.snapshot(snapshot(sequence: 11)), isFalse);
    expect(owner.needsSnapshot('chat'), isTrue);
    expect(owner.snapshot(snapshot(epoch: 'replacement', sequence: 1)), isTrue);
    expect(owner.session('chat')!.replayEpoch, 'replacement');
    expect(
      owner.event(
        StreamEvent(
          type: 'message.delta',
          sessionId: 'chat',
          data: {'text': 'late'},
          envelope: {'replay_epoch': 'epoch', 'seq': 12},
        ),
      ),
      isFalse,
    );
    expect(owner.needsSnapshot('chat'), isFalse);
    expect(owner.snapshot(snapshot(sequence: 12)), isFalse);
  });

  test(
    'stock execution envelope advances Stop generation before pending publication',
    () {
      final owner = CanonicalSessionProtocol()
        ..snapshot(snapshot(sequence: 0, generation: 0));
      expect(
        owner.event(
          StreamEvent(
            type: 'message.start',
            sessionId: 'chat',
            data: {},
            envelope: {
              'replay_epoch': 'epoch',
              'seq': 1,
              'authority_epoch': 1,
              'execution_generation': 7,
              'admission_id': 'claim',
            },
          ),
        ),
        isTrue,
      );
      expect(owner.interrupt('chat')['execution_generation'], 7);
      expect(owner.snapshot(snapshot(sequence: 0, generation: 0)), isFalse);
      expect(owner.session('chat')!.sequence, 1);
      expect(owner.session('chat')!.generation, 7);
      expect(
        owner.event(
          StreamEvent(
            type: 'message.delta',
            sessionId: 'chat',
            data: {'text': 'stale'},
            envelope: {
              'replay_epoch': 'epoch',
              'seq': 2,
              'authority_epoch': 2,
              'execution_generation': 7,
            },
          ),
        ),
        isFalse,
      );
      expect(owner.needsSnapshot('chat'), isTrue);
    },
  );

  test(
    'mutations and late Stop use received generation, never a guessed zero',
    () {
      final owner = CanonicalSessionProtocol();
      expect(
        () => owner.mutation('chat', 'rewind', {'target_message_id': 9}),
        throwsStateError,
      );
      owner.snapshot(snapshot());
      final first = owner.mutation('chat', 'rewind', {'target_message_id': 9});
      expect(first, containsPair('expected_revision', 4));
      expect(first, containsPair('expected_generation', 2));
      expect(first['request_id'], isNotEmpty);
      expect(owner.interrupt('chat'), {
        'session_id': 'chat',
        'execution_generation': 2,
      });
      owner.refused(
        'chat',
        JsonRpcError(
          'session.mutate',
          'changed',
          reason: 'revision_conflict',
          data: {'revision': 8, 'execution_generation': 3},
        ),
      );
      expect(owner.interrupt('chat')['execution_generation'], 3);
      expect(
        owner.mutation('chat', 'rewind', {
          'target_message_id': 9,
        })['expected_revision'],
        8,
      );
    },
  );
  test(
    'epoch reset and missing sequence require snapshot without applying later pending',
    () {
      final owner = CanonicalSessionProtocol()
        ..snapshot(snapshot(pending: [pending('one')]));
      expect(
        owner.event(
          StreamEvent(
            type: 'session.info',
            sessionId: 'chat',
            data: {'pending': []},
            envelope: {'replay_epoch': 'epoch', 'seq': 12},
          ),
        ),
        isFalse,
      );
      expect(owner.needsSnapshot('chat'), isTrue);
      expect(owner.session('chat')!.pending.single.id, 'one');
      expect(() => owner.interrupt('chat'), throwsStateError);
      owner.snapshot(
        snapshot(epoch: 'new', sequence: 1, pending: [pending('two')]),
      );
      expect(owner.needsSnapshot('chat'), isFalse);
      expect(owner.replay('chat'), {
        'session_id': 'chat',
        'replay_epoch': 'new',
        'last_sequence': 1,
      });
      expect(
        owner.event(
          StreamEvent(
            type: 'session.info',
            sessionId: 'chat',
            data: {},
            envelope: {'replay_epoch': 'epoch', 'seq': 11},
          ),
        ),
        isFalse,
      );
    },
  );
  test(
    'duplicate event cannot retire work; same text has separate receipt identity',
    () {
      final owner = CanonicalSessionProtocol()
        ..snapshot(
          snapshot(pending: [pending('b', sequence: 2), pending('a')]),
        );
      expect(owner.session('chat')!.pending.map((row) => row.id), ['a', 'b']);
      expect(
        owner.event(
          StreamEvent(
            type: 'session.info',
            sessionId: 'chat',
            data: {'pending': []},
            envelope: {'replay_epoch': 'epoch', 'seq': 10},
          ),
        ),
        isFalse,
      );
      expect(owner.session('chat')!.pending, hasLength(2));
      expect(
        () => owner.snapshot(
          snapshot(pending: [pending('foreign', session: 'other')]),
        ),
        throwsFormatException,
      );
    },
  );
  test('named read-only refusal is scoped and retained through refresh', () {
    final owner = CanonicalSessionProtocol()
      ..snapshot(snapshot())
      ..snapshot(snapshot(id: 'other'));
    owner.refused(
      'chat',
      JsonRpcError('prompt.submit', 'read only', reason: 'session_superseded'),
    );
    owner.snapshot(snapshot());
    expect(owner.session('chat')!.readOnlyReason, 'session_superseded');
    expect(owner.session('other')!.readOnlyReason, isNull);
  });
  test(
    'subscription overflow has no sequence and still requires resnapshot',
    () {
      final owner = CanonicalSessionProtocol()..snapshot(snapshot());
      expect(
        owner.event(
          StreamEvent(
            type: 'session.replay_gap',
            sessionId: 'chat',
            data: {'latest_seq': 40},
          ),
        ),
        isFalse,
      );
      expect(owner.needsSnapshot('chat'), isTrue);
    },
  );
}

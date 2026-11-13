import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/provider_credential_edit_session.dart';
import 'support/provider_edit_fixture.dart';

void main() {
  ProviderCredentialEditSession owner(
    ProviderEditFixture f, {
    bool isSet = false,
  }) => ProviderCredentialEditSession(
    f.server.profile('personal'),
    key: 'EXAMPLE_API_KEY',
    isSet: isSet,
  );
  for (final hold in ['membership', 'physical mutation']) {
    test(
      'retirement during held $hold preserves zero credential writes',
      () async {
        final f = ProviderEditFixture();
        final gate = Completer<void>();
        if (hold == 'membership') {
          f.membershipGate = gate;
        } else {
          f.mutationGate = gate;
        }
        final edit = owner(f)..setDraft('synthetic-new-key');
        final result = edit.save(remove: false);
        await (hold == 'membership'
            ? f.membershipEntered.future
            : f.mutationEntered.future);
        edit.dispose();
        gate.complete();
        expect(await result, ProviderCredentialOutcome.retired);
        expect(f.envWrites, 0);
        expect(edit.draft, isEmpty);
      },
    );
  }
  test(
    'settled mutation timeout revokes same live command before delayed send',
    () async {
      final f = ProviderEditFixture()
        ..mutationGate = Completer<void>()
        ..timeoutMutation = true;
      final edit = owner(f)..setDraft('synthetic-new-key');
      addTearDown(edit.dispose);
      expect(await edit.save(remove: false), ProviderCredentialOutcome.failed);
      f.mutationGate!.complete();
      await f.mutationExited.future;
      expect(f.envWrites, 0);
      expect(edit.dirty, true);
    },
  );
  test(
    'dispatched save finishes after retirement without callback authority',
    () async {
      final f = ProviderEditFixture()..envWriteGate = Completer<void>();
      final edit = owner(f)..setDraft('synthetic-new-key');
      var notifications = 0;
      edit.addListener(() => notifications++);
      final result = edit.save(remove: false);
      await f.writeEntered.future;
      edit.dispose();
      final count = notifications;
      f.envWriteGate!.complete();
      expect(await result, ProviderCredentialOutcome.retired);
      expect((f.env['EXAMPLE_API_KEY'] as Map)['is_set'], true);
      expect(notifications, count);
    },
  );
  test(
    'unknown readback keeps draft and requires explicit fresh review before resend',
    () async {
      final f = ProviderEditFixture()..apply = false;
      final edit = owner(f)..setDraft('synthetic-new-key');
      addTearDown(edit.dispose);
      expect(
        await edit.save(remove: false),
        ProviderCredentialOutcome.uncertain,
      );
      expect(await edit.save(remove: false), ProviderCredentialOutcome.blocked);
      expect(f.envWrites, 1);
      await edit.review();
      expect(f.envWrites, 1);
      expect(edit.draft, 'synthetic-new-key');
      f.apply = true;
      expect(await edit.save(remove: false), ProviderCredentialOutcome.saved);
      expect(f.envWrites, 2);
    },
  );
  test(
    'fresh changed ownership and stored-state conflicts never mutate',
    () async {
      final f = ProviderEditFixture();
      final edit = owner(f)..setDraft('synthetic-new-key');
      addTearDown(edit.dispose);
      (f.env['EXAMPLE_API_KEY'] as Map)['is_set'] = true;
      expect(await edit.save(remove: false), ProviderCredentialOutcome.failed);
      expect(edit.reviewRequired, true);
      expect(f.envWrites, 0);
      await edit.review();
      (f.env['EXAMPLE_API_KEY'] as Map)['channel_managed'] = true;
      expect(await edit.save(remove: false), ProviderCredentialOutcome.failed);
      expect(f.envWrites, 0);
    },
  );
  test(
    'removal uses strict DELETE body and requires exact key acknowledgement',
    () async {
      final f = ProviderEditFixture();
      (f.env['EXAMPLE_API_KEY'] as Map)['is_set'] = true;
      final edit = owner(f, isSet: true);
      addTearDown(edit.dispose);
      expect(await edit.save(remove: true), ProviderCredentialOutcome.removed);
      final wire = f.requests.singleWhere((r) => r.$1 == 'DELETE');
      expect(wire.$3, {'profile': 'personal'});
      expect(wire.$4, {'key': 'EXAMPLE_API_KEY', 'profile': 'personal'});
      expect(edit.isSet, false);
    },
  );
  test('wrong key acknowledgement cannot confirm a credential save', () async {
    final f = ProviderEditFixture()..wrongKey = true;
    final edit = owner(f)..setDraft('synthetic-new-key');
    addTearDown(edit.dispose);
    expect(await edit.save(remove: false), ProviderCredentialOutcome.uncertain);
    expect(edit.dirty, true);
  });
}

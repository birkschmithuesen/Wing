import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/provider_inventory.dart';
import 'package:wing/core/models/provider_device_sign_in.dart';
import 'package:wing/core/services/provider_device_sign_in_session.dart';
import 'support/provider_edit_fixture.dart';

void main() {
  ProviderDeviceSignInSession owner(ProviderEditFixture f) =>
      ProviderDeviceSignInSession(
        f.server.profile('personal'),
        const ProviderSignInTarget(id: 'provider', name: 'Provider'),
      );
  test('retired membership preflight cannot start device sign-in', () async {
    final f = ProviderEditFixture()..membershipGate = Completer<void>();
    final edit = owner(f);
    final work = edit.start();
    await f.membershipEntered.future;
    edit.dispose();
    f.membershipGate!.complete();
    await work;
    expect(f.starts, 0);
    expect(edit.session, isNull);
  });
  test(
    'settled authentication-like timeout revokes live command before delayed start',
    () async {
      final f = ProviderEditFixture()
        ..mutationGate = Completer<void>()
        ..timeoutMutation = true;
      final edit = owner(f);
      await edit.start();
      expect(edit.unknownStart, false);
      expect(edit.canStart, true);
      f.mutationGate!.complete();
      await f.mutationExited.future;
      expect(f.starts, 0);
      edit.dispose();
    },
  );
  test(
    'late successful start releases exact session without publishing after retirement',
    () async {
      final f = ProviderEditFixture()..startGate = Completer<void>();
      final edit = owner(f);
      var notifications = 0;
      edit.addListener(() => notifications++);
      final work = edit.start();
      await f.startEntered.future;
      edit.dispose();
      f.server.close();
      final before = notifications;
      f.startGate!.complete();
      await work;
      expect(f.cancelled, ['owned-session']);
      expect(edit.session, isNull);
      expect(notifications, before);
    },
  );
  test('wrong session poll cannot approve or retarget owned sign-in', () async {
    final f = ProviderEditFixture();
    final edit = owner(f);
    await edit.start();
    f.pollResponse = {'session_id': 'other-session', 'status': 'approved'};
    await edit.poll();
    expect(edit.pending, true);
    expect(edit.status, ProviderDeviceStatus.pending);
    expect(edit.canRecover, false);
    expect(edit.error, isNotNull);
    edit.dispose();
    await edit.cleanup;
  });
  test(
    'overlapping manual polls are coalesced and disposal cleans pending exact session',
    () async {
      final f = ProviderEditFixture()
        ..pollGate = Completer<Map<String, dynamic>>();
      final edit = owner(f);
      await edit.start();
      final old = edit.poll();
      await f.pollEntered.future;
      await edit.poll();
      expect(f.polls, 1);
      edit.dispose();
      await edit.cleanup;
      expect(f.cancelled, ['owned-session']);
      f.pollGate!.complete({
        'session_id': 'owned-session',
        'status': 'approved',
      });
      await old;
      expect(edit.status, ProviderDeviceStatus.pending);
    },
  );
  test(
    'cancellation requires stock exact acknowledgement and permits explicit retry',
    () async {
      final f = ProviderEditFixture();
      final edit = owner(f);
      await edit.start();
      f.acknowledge = false;
      expect(await edit.cancel(), false);
      expect(edit.pending, true);
      expect(edit.error, contains('not be confirmed'));
      f.acknowledge = true;
      expect(await edit.cancel(), true);
      expect(edit.status, ProviderDeviceStatus.cancelled);
      expect(f.cancelled, ['owned-session', 'owned-session']);
      edit.dispose();
      await edit.cleanup;
      expect(f.cancelled, hasLength(2));
    },
  );
  test(
    'malformed display response cancels known current identity without permitting replay',
    () async {
      final f = ProviderEditFixture();
      f.startResponse.remove('user_code');
      final edit = owner(f);
      await edit.start();
      expect(f.cancelled, ['owned-session']);
      expect(edit.session, isNull);
      expect(edit.unknownStart, true);
      expect(edit.canStart, false);
      await edit.start();
      expect(f.starts, 1);
      expect(edit.error, contains('not be confirmed'));
      edit.dispose();
      await edit.cleanup;
      expect(f.cancelled, ['owned-session']);
    },
  );
  test(
    'late malformed display response still cleans exact returned identity after retirement',
    () async {
      final f = ProviderEditFixture()..startGate = Completer<void>();
      f.startResponse.remove('verification_url');
      final edit = owner(f);
      var notifications = 0;
      edit.addListener(() => notifications++);
      final work = edit.start();
      await f.startEntered.future;
      edit.dispose();
      f.server.close();
      final before = notifications;
      f.startGate!.complete();
      await work;
      expect(f.cancelled, ['owned-session']);
      expect(edit.session, isNull);
      expect(notifications, before);
    },
  );
  for (final invalidIdentity in <Object?>[
    null,
    7,
    '',
    '   ',
    ['owned-session'],
  ]) {
    test(
      'malformed current cleanup identity cannot produce a guessed cancellation: $invalidIdentity',
      () async {
        final f = ProviderEditFixture();
        f.startResponse['session_id'] = invalidIdentity;
        f.startResponse.remove('user_code');
        final edit = owner(f);
        await edit.start();
        expect(edit.session, isNull);
        expect(edit.unknownStart, true);
        expect(edit.canStart, false);
        expect(f.cancelled, isEmpty);
        await edit.start();
        expect(f.starts, 1);
        edit.dispose();
        await edit.cleanup;
        expect(f.cancelled, isEmpty);
      },
    );
  }
  test(
    'retirement during accepted cancellation drains its captured cleanup lease',
    () async {
      final f = ProviderEditFixture();
      final edit = owner(f);
      await edit.start();
      f.mutationGate = Completer<void>();
      f.heldMutationEntered = Completer<void>();
      final cancel = edit.cancel();
      await f.heldMutationEntered!.future;
      edit.dispose();
      f.server.close();
      f.mutationGate!.complete();
      expect(await cancel, false);
      expect(f.cancelled, ['owned-session']);
      expect(edit.status, ProviderDeviceStatus.pending);
    },
  );
  test('unknown delivered start cannot be automatically replayed', () async {
    final f = ProviderEditFixture();
    f.startResponse = {'session_id': 'owned-session', 'flow': 'unsupported'};
    final edit = owner(f);
    await edit.start();
    expect(edit.unknownStart, true);
    expect(edit.canStart, false);
    await edit.start();
    expect(f.starts, 1);
    expect(edit.error, contains('not be confirmed'));
    edit.dispose();
  });
  test(
    'approved status stops polling and restart without fabricating credential observation',
    () async {
      final f = ProviderEditFixture();
      final edit = owner(f);
      await edit.start();
      f.pollResponse = {'session_id': 'owned-session', 'status': 'approved'};
      await edit.poll();
      expect(edit.pending, false);
      expect(edit.canStart, false);
      expect(edit.canRecover, false);
      await edit.poll();
      expect(f.polls, 1);
      edit.dispose();
      await edit.cleanup;
      expect(f.cancelled, isEmpty);
    },
  );
  testWidgets(
    'absolute deadline cannot be overridden by held pending poll or spawn another request',
    (tester) async {
      final f = ProviderEditFixture()
        ..pollGate = Completer<Map<String, dynamic>>();
      final edit = owner(f);
      await edit.start();
      final poll = edit.poll();
      await f.pollEntered.future;
      await tester.pump(const Duration(minutes: 16));
      expect(edit.status, ProviderDeviceStatus.expired);
      expect(edit.busy, true);
      expect(edit.canStart, false);
      await edit.poll();
      expect(f.polls, 1);
      f.pollGate!.complete({
        'session_id': 'owned-session',
        'status': 'pending',
      });
      await poll;
      await edit.cleanup;
      expect(f.cancelled, ['owned-session']);
      expect(edit.status, ProviderDeviceStatus.expired);
      expect(edit.busy, false);
      expect(edit.canStart, true);
      edit.dispose();
    },
  );
  testWidgets('unconfirmed deadline cleanup cannot authorize another sign-in', (
    tester,
  ) async {
    final f = ProviderEditFixture();
    final edit = owner(f);
    await edit.start();
    f.acknowledge = false;
    await tester.pump(const Duration(minutes: 16));
    await edit.cleanup;
    expect(edit.status, ProviderDeviceStatus.expired);
    expect(edit.unknownStart, true);
    expect(edit.canStart, false);
    await edit.start();
    expect(f.starts, 1);
    expect(f.cancelled, ['owned-session']);
    edit.dispose();
  });
  for (final acknowledged in [true, false]) {
    testWidgets(
      'deadline shares held manual cancellation and settles occupancy: $acknowledged',
      (tester) async {
        final f = ProviderEditFixture();
        final edit = owner(f);
        await edit.start();
        f.acknowledge = acknowledged;
        f.mutationGate = Completer<void>();
        f.heldMutationEntered = Completer<void>();
        final cancellation = edit.cancel();
        await f.heldMutationEntered!.future;
        await tester.pump(const Duration(minutes: 16));
        expect(edit.status, ProviderDeviceStatus.expired);
        expect(edit.busy, true);
        expect(edit.canStart, false);
        f.mutationGate!.complete();
        await cancellation;
        await edit.cleanup;
        expect(f.cancelled, ['owned-session']);
        expect(edit.status, ProviderDeviceStatus.expired);
        expect(edit.busy, false);
        expect(edit.canClose, true);
        expect(edit.unknownStart, !acknowledged);
        expect(edit.canStart, acknowledged);
        edit.dispose();
        await edit.cleanup;
        expect(f.cancelled, ['owned-session']);
      },
    );
  }
}

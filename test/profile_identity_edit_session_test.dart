import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/profile_identity_edit.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_identity_edit_session.dart';

const _description = ProfileIdentityField.description;
const _soul = ProfileIdentityField.soul;

class _IdentityFixture {
  String description = 'Work profile', soul = 'Be precise.\n';
  bool metadataDenied = false, soulUnavailable = false;
  bool malformedSoulAck = false, applySoul = true, closed = false;
  Completer<void>? metadataDelay, authenticationDelay, acknowledgementDelay;
  Completer<void>? mutationStarted, authenticationStarted, metadataReadStarted;
  final writes = <(String, Map<String, dynamic>)>[];
  final reads = <String>[];
  final directory = '/srv/hermes/profiles/work';
  late final server = AdministrationRepository(
    connectionId: 'central',
    connectionIdentity: 'identity-test',
    connectionLabel: 'Central server',
    request: (method, endpoint, query, body) async {
      if (method != 'GET') throw StateError('Expected owned mutation');
      reads.add(endpoint);
      if (endpoint == 'profiles') {
        return {
          'profiles': [
            {'name': 'work', 'path': directory, 'description': description},
          ],
        };
      }
      if (endpoint == 'profiles/active') {
        return {'current': 'work', 'active': 'work'};
      }
      if (endpoint == 'files/read') {
        if (query['path'] != '$directory/profile.yaml') {
          throw StateError('Wrong captured metadata path');
        }
        final bytes = utf8.encode(
          jsonEncode({
            'description': description,
            'ui_meta': {
              'hermes-bots': {'title': 'Keep this title'},
            },
          }),
        );
        metadataReadStarted?.complete();
        await metadataDelay?.future;
        if (metadataDenied) {
          throw const DashboardHttpException(403, 'files/read');
        }
        return {
          'name': 'profile.yaml',
          'path': '$directory/profile.yaml',
          'size': bytes.length,
          'mime_type': 'application/yaml',
          'data_url': 'data:application/yaml;base64,${base64.encode(bytes)}',
        };
      }
      if (endpoint == 'profiles/work/soul') {
        if (soulUnavailable) {
          throw const DashboardHttpException(500, 'profiles/work/soul');
        }
        return {'content': soul, 'exists': true};
      }
      throw StateError('Unexpected read $endpoint');
    },
    settingsWrite: (_, _, _, _) => throw StateError('No config writes'),
    ownedMutation: (method, endpoint, query, body, active, dispatched) async {
      authenticationStarted?.complete();
      await authenticationDelay?.future;
      if (!active()) throw StateError('Retired before physical dispatch');
      if (method != 'PUT' || !endpoint.startsWith('profiles/work/')) {
        throw StateError('Wrong captured mutation');
      }
      dispatched();
      writes.add((endpoint, Map.of(body)));
      if (endpoint.endsWith('/description')) {
        description = body['description'] as String;
      } else if (endpoint.endsWith('/soul') && applySoul) {
        soul = body['content'] as String;
      }
      mutationStarted?.complete();
      await acknowledgementDelay?.future;
      if (endpoint.endsWith('/description')) {
        return {
          'ok': true,
          'description': description,
          'description_auto': false,
        };
      }
      return malformedSoulAck ? <String, dynamic>{} : {'ok': true};
    },
    gateway: (_) => throw StateError('Identity must not use RPC'),
    close: () => closed = true,
  );

  Future<ProfileIdentityEditSession> open() async {
    final session = ProfileIdentityEditSession(server.profile('work'));
    await settle(session);
    return session;
  }
}

Future<void> settle(ProfileIdentityEditSession session) async {
  for (var turn = 0; session.state.loading && turn < 30; turn++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(session.state.loading, isFalse);
}

void main() {
  test(
    'immutable intent trims description, omits unchanged and retains clears',
    () {
      final baseline = {_description: 'Original', _soul: 'Instructions'};
      final wanted = {_description: ' Original ', _soul: ''};
      final intent = ProfileIdentityEditIntent(
        baseline: baseline,
        wanted: wanted,
      );
      baseline[_description] = 'Changed outside intent';
      wanted[_soul] = 'Changed outside intent';
      expect(intent.wanted, {_soul: ''});
      final resolution = intent.resolve(
        ProfileIdentityObservation(
          values: {_description: 'Elsewhere', _soul: 'Instructions'},
          issues: const {},
        ),
      );
      expect(resolution.updates, {_soul: ''});
      expect(resolution.conflicts, isEmpty);
      expect(resolution.issues, isEmpty);
      expect(() => intent.wanted[_soul] = 'unsafe', throwsUnsupportedError);
      expect(
        () =>
            ProfileIdentityEditIntent(baseline: const {}, wanted: {_soul: ''}),
        throwsArgumentError,
      );
    },
  );

  test(
    'captured profile observes strict HTTP and sparse exact replacements',
    () async {
      final fixture = _IdentityFixture();
      final session = await fixture.open();
      addTearDown(session.dispose);
      expect(session.state.scopeLabel, 'Central server / work');
      session.edit(_soul, '  Exact instructions.\n\n');
      expect(await session.save(), ProfileIdentitySaveOutcome.confirmed);
      expect(fixture.writes, hasLength(1));
      expect(fixture.writes.single.$1, 'profiles/work/soul');
      expect(fixture.writes.single.$2, {
        'content': '  Exact instructions.\n\n',
      });
      expect(fixture.description, 'Work profile');
    },
  );

  test('whitespace-only description change dispatches nothing', () async {
    final fixture = _IdentityFixture();
    final session = await fixture.open();
    addTearDown(session.dispose);
    session.edit(_description, '  Work profile  ');
    expect(session.state.dirtyCount, 0);
    expect(await session.save(), ProfileIdentitySaveOutcome.blocked);
    expect(fixture.writes, isEmpty);
  });

  test('both deliberate clears are exact sparse writes', () async {
    final fixture = _IdentityFixture();
    final session = await fixture.open();
    addTearDown(session.dispose);
    session.edit(_description, '');
    session.edit(_soul, '');
    expect(await session.save(), ProfileIdentitySaveOutcome.confirmed);
    expect(fixture.description, '');
    expect(fixture.soul, '');
    expect(fixture.writes.map((write) => write.$2), [
      {'description': ''},
      {'content': ''},
    ]);
  });

  test(
    'unreadable metadata is unavailable while SOUL remains independently editable',
    () async {
      final fixture = _IdentityFixture()..metadataDenied = true;
      final session = await fixture.open();
      addTearDown(session.dispose);
      expect(session.state.description.enabled, isFalse);
      expect(session.state.description.issue, isNotNull);
      expect(session.state.soul.enabled, isTrue);
      session.edit(_soul, 'Safe SOUL edit');
      expect(await session.save(), ProfileIdentitySaveOutcome.confirmed);
      expect(fixture.writes.map((write) => write.$1), ['profiles/work/soul']);
      expect(fixture.description, 'Work profile');
    },
  );

  test(
    'same-field conflict preserves draft and requires an explicit decision',
    () async {
      final fixture = _IdentityFixture();
      final session = await fixture.open();
      addTearDown(session.dispose);
      session.edit(_description, 'My edit');
      fixture.description = 'Another editor';
      expect(await session.save(), ProfileIdentitySaveOutcome.failed);
      expect(fixture.writes, isEmpty);
      expect(session.state.description.text, 'My edit');
      expect(session.state.description.serverText, 'Another editor');
      expect(session.state.canSave, isFalse);
      session.resolve(_description, useServer: false);
      expect(await session.save(), ProfileIdentitySaveOutcome.confirmed);
      expect(fixture.description, 'My edit');
    },
  );

  test(
    'converged current text needs no PUT and does not manufacture an ACK',
    () async {
      final fixture = _IdentityFixture();
      final session = await fixture.open();
      addTearDown(session.dispose);
      session.edit(_description, 'My edit');
      fixture.description = 'My edit';
      expect(await session.save(), ProfileIdentitySaveOutcome.confirmed);
      expect(fixture.writes, isEmpty);
      expect(session.state.dirtyCount, 0);
      expect(session.requestClose().result, isTrue);
    },
  );

  test(
    'unrelated remote description change is preserved by SOUL save',
    () async {
      final fixture = _IdentityFixture();
      final session = await fixture.open();
      addTearDown(session.dispose);
      session.edit(_soul, 'My SOUL');
      fixture.description = 'Another editor';
      expect(await session.save(), ProfileIdentitySaveOutcome.confirmed);
      expect(fixture.description, 'Another editor');
      expect(fixture.writes.single.$2, {'content': 'My SOUL'});
    },
  );

  test('known description ACK survives unavailable SOUL preflight', () async {
    final fixture = _IdentityFixture();
    final session = await fixture.open();
    addTearDown(session.dispose);
    session.edit(_description, '  My description  ');
    session.edit(_soul, 'My SOUL');
    fixture.soulUnavailable = true;
    expect(await session.save(), ProfileIdentitySaveOutcome.partial);
    expect(fixture.description, 'My description');
    expect(fixture.soul, 'Be precise.\n');
    expect(fixture.writes.map((write) => write.$1), [
      'profiles/work/description',
    ]);
    expect(session.state.description.dirty, isFalse);
    expect(session.state.soul.text, 'My SOUL');
    fixture.soulUnavailable = false;
    await session.load();
    expect(fixture.writes.length, 1);
    expect(session.state.soul.text, 'My SOUL');
  });

  test(
    'uncertain SOUL is never replayed; matching read proves only convergence',
    () async {
      final fixture = _IdentityFixture()..malformedSoulAck = true;
      final session = await fixture.open();
      addTearDown(session.dispose);
      session.edit(_soul, 'My SOUL');
      expect(await session.save(), ProfileIdentitySaveOutcome.failed);
      expect(fixture.soul, 'My SOUL');
      expect(fixture.writes.length, 1);
      expect(session.state.canSave, isFalse);
      expect(await session.save(), ProfileIdentitySaveOutcome.blocked);
      await session.load();
      expect(fixture.writes.length, 1);
      expect(session.state.dirtyCount, 0);
      expect(session.state.notice, 'Current profile values checked.');
    },
  );

  test(
    'nonmatching uncertainty needs explicit read review before a new write',
    () async {
      final fixture = _IdentityFixture()
        ..malformedSoulAck = true
        ..applySoul = false;
      final session = await fixture.open();
      addTearDown(session.dispose);
      session.edit(_soul, 'My SOUL');
      await session.save();
      await session.load();
      expect(fixture.writes.length, 1);
      expect(fixture.soul, 'Be precise.\n');
      expect(session.state.soul.conflicted, isTrue);
      expect(session.state.canSave, isFalse);
      session.resolve(_soul, useServer: true);
      expect(fixture.writes.length, 1);
      expect(session.state.soul.text, 'Be precise.\n');
      expect(session.state.dirtyCount, 0);
    },
  );

  test(
    'SOUL BOM stays as an explicit invalid draft and Description can save',
    () async {
      final fixture = _IdentityFixture();
      final session = await fixture.open();
      addTearDown(session.dispose);
      session.edit(_soul, '\uFEFFMy SOUL');
      session.edit(_description, 'My description');
      expect(session.state.soul.issue, contains('byte-order mark'));
      expect(await session.save(), ProfileIdentitySaveOutcome.partial);
      expect(fixture.writes.map((write) => write.$1), [
        'profiles/work/description',
      ]);
      expect(session.state.soul.text, '\uFEFFMy SOUL');
      expect(session.state.soul.dirty, isTrue);
    },
  );

  test(
    'closure during held preflight sends no PUT and no late publication',
    () async {
      final fixture = _IdentityFixture();
      final session = await fixture.open();
      session.edit(_soul, 'My SOUL');
      final delay = Completer<void>();
      fixture.metadataDelay = delay;
      fixture.metadataReadStarted = Completer<void>();
      var published = 0;
      session.addListener(() => published++);
      final save = session.save();
      await fixture.metadataReadStarted!.future;
      session.dispose();
      final before = published;
      delay.complete();
      expect(await save, ProfileIdentitySaveOutcome.retired);
      expect(fixture.writes, isEmpty);
      expect(published, before);
    },
  );

  test(
    'closure during held authentication revokes physical PUT authority',
    () async {
      final fixture = _IdentityFixture();
      final session = await fixture.open();
      session.edit(_soul, 'My SOUL');
      final delay = Completer<void>();
      fixture.authenticationDelay = delay;
      fixture.authenticationStarted = Completer<void>();
      final save = session.save();
      await fixture.authenticationStarted!.future;
      session.dispose();
      delay.complete();
      expect(await save, ProfileIdentitySaveOutcome.retired);
      expect(fixture.writes, isEmpty);
      expect(fixture.soul, 'Be precise.\n');
    },
  );

  test(
    'already-dispatched ACK settles its retained operation after route disposal',
    () async {
      final fixture = _IdentityFixture();
      final session = await fixture.open();
      session.edit(_soul, 'My SOUL');
      final delay = Completer<void>();
      fixture.acknowledgementDelay = delay;
      fixture.mutationStarted = Completer<void>();
      var published = 0;
      session.addListener(() => published++);
      final save = session.save();
      await fixture.mutationStarted!.future;
      expect(fixture.soul, 'My SOUL');
      expect(fixture.writes.length, 1);
      session.dispose();
      fixture.server.close();
      expect(fixture.closed, isFalse);
      final before = published;
      delay.complete();
      expect(await save, ProfileIdentitySaveOutcome.retired);
      expect(fixture.closed, isTrue);
      expect(published, before);
      expect(fixture.writes.length, 1);
    },
  );

  test(
    'later successful load cannot be replaced by an older held read',
    () async {
      final fixture = _IdentityFixture();
      final delay = Completer<void>();
      fixture.metadataDelay = delay;
      fixture.metadataReadStarted = Completer<void>();
      final session = ProfileIdentityEditSession(
        fixture.server.profile('work'),
      );
      addTearDown(session.dispose);
      await fixture.metadataReadStarted!.future;
      fixture.metadataReadStarted = null;
      fixture.metadataDelay = null;
      fixture.description = 'Fresh description';
      await session.load();
      expect(session.state.description.text, 'Fresh description');
      delay.complete();
      await Future<void>.delayed(Duration.zero);
      expect(session.state.description.text, 'Fresh description');
    },
  );

  test(
    'failed retry keeps opening baseline and draft, without default replacement',
    () async {
      final fixture = _IdentityFixture();
      final session = await fixture.open();
      addTearDown(session.dispose);
      session.edit(_description, 'My draft');
      fixture.metadataDenied = true;
      await session.load();
      expect(session.state.description.text, 'My draft');
      expect(session.state.description.dirty, isTrue);
      expect(session.state.description.issue, isNotNull);
      expect(session.state.canSave, isFalse);
      expect(fixture.writes, isEmpty);
      fixture.metadataDenied = false;
      fixture.description = 'Another editor';
      await session.load();
      expect(session.state.description.text, 'My draft');
      expect(await session.save(), ProfileIdentitySaveOutcome.blocked);
      expect(session.state.description.serverText, 'Another editor');
      expect(fixture.writes, isEmpty);
    },
  );

  test(
    'read retry refreshes untouched fields while preserving edited baseline',
    () async {
      final fixture = _IdentityFixture();
      final session = await fixture.open();
      addTearDown(session.dispose);
      session.edit(_soul, 'My SOUL');
      fixture.description = 'Fresh description';
      fixture.soul = 'Another SOUL editor';
      await session.load();
      expect(fixture.writes, isEmpty);
      expect(session.state.description.text, 'Fresh description');
      expect(session.state.description.dirty, isFalse);
      expect(session.state.soul.text, 'My SOUL');
      expect(session.state.soul.serverText, 'Another SOUL editor');
      session.resolve(_soul, useServer: false);
      expect(await session.save(), ProfileIdentitySaveOutcome.confirmed);
      expect(fixture.description, 'Fresh description');
      expect(fixture.soul, 'My SOUL');
    },
  );

  test(
    'reverting an uncertain draft does not silently settle its delivery',
    () async {
      final fixture = _IdentityFixture()
        ..malformedSoulAck = true
        ..applySoul = false;
      final session = await fixture.open();
      addTearDown(session.dispose);
      session.edit(_soul, 'My SOUL');
      await session.save();
      expect(fixture.writes.length, 1);
      session.edit(_soul, 'Be precise.\n');
      session.edit(_description, 'My description');
      expect(await session.save(), ProfileIdentitySaveOutcome.partial);
      expect(fixture.writes.map((write) => write.$1), [
        'profiles/work/soul',
        'profiles/work/description',
      ]);
      expect(session.requestClose().needsDiscardConfirmation, isTrue);
      expect(session.state.dirtyCount, 1);
      await session.load();
      expect(fixture.writes.length, 2);
      expect(session.state.dirtyCount, 0);
    },
  );

  test(
    'load listener can retire owner without notifier disposal assertion',
    () async {
      final fixture = _IdentityFixture();
      final session = await fixture.open();
      final failures = <FlutterErrorDetails>[];
      final prior = FlutterError.onError;
      FlutterError.onError = failures.add;
      addTearDown(() => FlutterError.onError = prior);
      var notifications = 0;
      session.addListener(() {
        notifications++;
        session.dispose();
        fixture.server.close();
      });
      await session.load();
      expect(fixture.writes, isEmpty);
      expect(fixture.closed, isTrue);
      expect(notifications, 1);
      expect(failures, isEmpty);
    },
  );

  test(
    'save listener retirement revokes dispatch and defers notifier disposal',
    () async {
      final fixture = _IdentityFixture();
      final session = await fixture.open();
      session.edit(_soul, 'My SOUL');
      final failures = <FlutterErrorDetails>[];
      final prior = FlutterError.onError;
      FlutterError.onError = failures.add;
      addTearDown(() => FlutterError.onError = prior);
      var notifications = 0;
      session.addListener(() {
        notifications++;
        session.dispose();
      });
      expect(await session.save(), ProfileIdentitySaveOutcome.retired);
      expect(fixture.writes, isEmpty);
      expect(fixture.soul, 'Be precise.\n');
      fixture.server.close();
      expect(fixture.closed, isTrue);
      expect(notifications, 1);
      expect(failures, isEmpty);
    },
  );
}

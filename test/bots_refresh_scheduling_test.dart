import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/group_observations.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/models/bots.dart';
import 'package:wing/core/models/operational_error.dart';

import 'support/bots_fixture.dart';
import 'support/administration_fixture.dart';

void _append(BotsFixture fixture, int sequence) => fixture.events.add({
  'room_id': 'room-1',
  'seq': sequence,
  'kind': 'message.member',
  'created_at': 1700000000 + sequence,
  'actor': {'kind': 'member', 'id': 'atlas'},
  'payload': {'text': 'Answer $sequence'},
});

// Count access to the encoded payload, including accidental deep copies or
// serialization during bot metadata comparison on status-only ticks.
class _ObservedPicture extends MapBase<String, dynamic> {
  _ObservedPicture(this.valuesByKey);
  final Map<String, dynamic> valuesByKey;
  int payloadReads = 0;
  @override
  dynamic operator [](Object? key) {
    if (key == 'data') payloadReads++;
    return valuesByKey[key];
  }

  @override
  Iterable<String> get keys => valuesByKey.keys;
  @override
  void operator []=(String key, dynamic value) => valuesByKey[key] = value;
  @override
  void clear() => valuesByKey.clear();
  @override
  dynamic remove(Object? key) => valuesByKey.remove(key);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'retained roster reports one automatic issue and recovers from its own read',
    () async {
      var now = DateTime.utc(2026, 10, 13);
      final fixture = BotsFixture(now: () => now);
      final observations = <OperationalErrorObservation>[];
      final owner = BotsSession(
        (_) async => [fixture.repository],
        now: () => now,
        onOperationalError: observations.add,
      );
      addTearDown(owner.dispose);
      await owner.refresh();
      expect(owner.state.bots, isNotEmpty);
      observations.clear();
      fixture.readHook = (_, method, _) async {
        if (method == 'profiles.list') throw StateError('Roster unavailable');
        return null;
      };
      now = now.add(const Duration(seconds: 30));
      await owner.refresh(explicit: false);
      expect(owner.state.bots, isNotEmpty);
      expect(owner.state.errors, isEmpty);
      final issue = observations.where((value) => value.error != null).single;
      expect(issue.operation, startsWith('bot-roster:'));
      expect(
        issue.connectionIdentity,
        fixture.repository.scope.connectionIdentity,
      );

      fixture.readHook = null;
      observations.clear();
      now = now.add(const Duration(seconds: 30));
      await owner.refresh();
      expect(
        observations
            .singleWhere((item) => item.operation == issue.operation)
            .error,
        isNull,
      );
    },
  );

  for (final fails in [false, true]) {
    test(
      'metadata retains accepted presence until held status settles: failure=$fails',
      () async {
        var now = DateTime.utc(2026, 10, 13);
        final fixture = BotsFixture(now: () => now);
        final owner = BotsSession(
          (_) async => [fixture.repository],
          now: () => now,
        );
        addTearDown(owner.dispose);
        await owner.refresh();
        BotRecord bot(String name) =>
            owner.state.bots.singleWhere((bot) => bot.profile.name == name);
        expect(bot('forge').presence, BotPresence.working);
        expect(bot('mira').presence, BotPresence.needsInput);
        final started = Completer<void>(), release = Completer<void>();
        fixture.readHook = (_, method, _) async {
          if (method == 'session.active_list') {
            started.complete();
            await release.future;
            if (fails) throw StateError('Unavailable presence');
          }
          return null;
        };
        fixture.profiles.last['ui_meta']['hermes-bots']['title'] =
            'Forge renamed';
        fixture.profiles.add(BotsFixture.profile('newcomer', 'Newcomer'));
        now = now.add(const Duration(seconds: 30));
        final pending = owner.refresh();
        await started.future;
        expect(bot('forge').title, 'Forge renamed');
        expect(bot('forge').presence, BotPresence.working);
        expect(bot('mira').presence, BotPresence.needsInput);
        expect(bot('newcomer').presence, BotPresence.unknown);
        release.complete();
        await pending;
        expect(
          bot('forge').presence,
          fails ? BotPresence.unknown : BotPresence.working,
        );
        expect(
          bot('mira').presence,
          fails ? BotPresence.unknown : BotPresence.needsInput,
        );
        expect(
          bot('newcomer').presence,
          fails ? BotPresence.unknown : BotPresence.idle,
        );
      },
    );
  }

  for (final scenario in [
    (method: 'profiles.list', seconds: 10, botsVisible: true),
    (method: 'profiles.list', seconds: 30, botsVisible: false),
    (method: 'groups.log', seconds: 30, botsVisible: true),
  ]) {
    test(
      'held successful ${scenario.method} stays due at ${scenario.seconds}s with Bots visible=${scenario.botsVisible}',
      () async {
        final start = DateTime.utc(2026, 10, 13);
        var now = start;
        final fixture = BotsFixture(now: () => now);
        _append(fixture, 1);
        final started = Completer<void>(), release = Completer<void>();
        var reads = 0;
        fixture.readHook = (_, method, _) async {
          if (method == scenario.method && ++reads == 1) {
            started.complete();
            await release.future;
          }
          return null;
        };
        final owner = BotsSession(
          (_) async => [fixture.repository],
          now: () => now,
        );
        addTearDown(owner.dispose);
        if (scenario.botsVisible) {
          owner.setVisible(true);
        } else {
          owner.setRecentsVisible(Object(), true);
        }
        final first = owner.refresh();
        await started.future;
        now = start.add(const Duration(milliseconds: 250));
        final joined = owner.refresh();
        await Future<void>.delayed(Duration.zero);
        expect(reads, 1, reason: 'Pending work coalesces');
        now = start.add(const Duration(milliseconds: 500));
        release.complete();
        await Future.wait([first, joined]);
        _append(fixture, 2);
        now = start.add(Duration(seconds: scenario.seconds));
        await owner.refresh();
        expect(
          reads,
          2,
          reason: 'Read latency must not skip the next periodic wake',
        );
        if (scenario.method == 'groups.log') {
          expect(owner.observedGroups.single.preview, 'Answer 2');
        }
      },
    );
  }

  test('held failure cooldown starts when the failure completes', () async {
    final start = DateTime.utc(2026, 10, 13);
    var now = start;
    final fixture = BotsFixture(now: () => now);
    final started = Completer<void>(), release = Completer<void>();
    var reads = 0;
    fixture.readHook = (_, method, _) async {
      if (method == 'groups.capabilities' && ++reads == 1) {
        started.complete();
        await release.future;
        throw StateError('Unavailable');
      }
      return null;
    };
    final owner = BotsSession(
      (_) async => [fixture.repository],
      now: () => now,
    );
    addTearDown(owner.dispose);
    owner.setVisible(true);
    final first = owner.refresh();
    await started.future;
    now = start.add(const Duration(milliseconds: 500));
    release.complete();
    await first;
    now = start.add(const Duration(seconds: 30));
    await owner.refresh();
    expect(reads, 1);
    now = now.add(const Duration(milliseconds: 500));
    await owner.refresh();
    expect(reads, 2);
    expect(owner.state.groupHosts, ['instance-1']);
  });

  test('group artwork never enters bot identities or status work', () async {
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aK7sAAAAASUVORK5CYII=';
    var now = DateTime.utc(2026, 10, 13);
    final fixture = BotsFixture();
    final profile = BotsFixture.profile('default', 'Default');
    final botMetadata = profile['ui_meta']['hermes-bots'];
    final picture = _ObservedPicture({'version': 1, 'color': 3, 'data': png});
    profile['ui_meta'] = <String, Object?>{
      'hermes-bots': botMetadata,
      'wing-group-icon:room-1': picture,
    };
    profile['ui_meta_revisions']['wing-group-icon:room-1'] = 1;
    fixture.profiles.add(profile);
    var profileReads = 0, catalogReads = 0, assetReads = 0;
    final heldProfiles = Completer<void>();
    final profilesStarted = Completer<void>();
    fixture.readHook = (_, method, _) async {
      if (method == 'groups.list') catalogReads++;
      if (method == 'profiles.get_asset') assetReads++;
      if (method != 'profiles.list') return null;
      profileReads++;
      if (!profilesStarted.isCompleted) profilesStarted.complete();
      await heldProfiles.future;
      return {
        'profiles': fixture.profiles,
        'bot_mode_protocol': true,
        'install_id': 'install-1',
      };
    };
    final owner = BotsSession(
      (_) async => [fixture.repository],
      now: () => now,
    );
    addTearDown(owner.dispose);
    owner.setVisible(true);
    final initial = owner.refresh();
    await profilesStarted.future;
    expect(profileReads, 1, reason: 'Catalog joins the held status roster');
    heldProfiles.complete();
    await initial;
    final rosterBot = owner.state.bots.singleWhere(
      (bot) => bot.profile.name == 'default',
    );
    final canonical = owner.cachedAppearance(rosterBot.chat!)!;
    expect(canonical.metadata, botMetadata);
    expect(canonical.withPresence(BotPresence.working).metadata, botMetadata);
    expect(canonical.withAvatarHint(true).metadata, botMetadata);
    expect(jsonEncode(canonical.metadata), isNot(contains(png)));
    final roomPicture = owner.observedGroups.single.picture;
    expect(roomPicture, orderedEquals(base64Decode(png)));
    expect(picture.payloadReads, 1);
    picture.valuesByKey['data'] = 'invalid until the next catalog read';
    for (var tick = 1; tick <= 3; tick++) {
      now = now.add(const Duration(seconds: 10));
      await owner.refresh();
      expect(profileReads, tick + 1);
      expect(catalogReads, 1);
      expect(assetReads, 0);
      expect(
        picture.payloadReads,
        1,
        reason: 'Status neither copies nor decodes picture data',
      );
      expect(owner.cachedAppearance(rosterBot.chat!), same(canonical));
      expect(owner.observedGroups.single.picture, same(roomPicture));
    }
    picture.valuesByKey['data'] = png;
    now = now.add(const Duration(seconds: 270));
    await owner.refresh();
    expect(profileReads, 5, reason: 'Due catalog shares the status read');
    expect(catalogReads, 2);
    expect(picture.payloadReads, 2);
    expect(
      owner.observedGroups.single.picture,
      orderedEquals(base64Decode(png)),
    );
  });

  test(
    'explicit roster reread cannot join a pre-mutation wire response',
    () async {
      final fixture = BotsFixture();
      final held = Completer<void>();
      final started = Completer<void>();
      var reads = 0;
      fixture.readHook = (_, method, _) async {
        if (method != 'profiles.list') return null;
        final profiles = jsonDecode(jsonEncode(fixture.profiles));
        if (++reads == 1) {
          started.complete();
          await held.future;
        }
        return {
          'profiles': profiles,
          'bot_mode_protocol': true,
          'install_id': 'install-1',
        };
      };
      final old = fixture.repository.bots();
      await started.future;
      fixture.profiles.add(BotsFixture.profile('newbot', 'New bot'));
      final fresh = await fixture.repository.bots();
      expect(fresh.map((bot) => bot.profile.name), contains('newbot'));
      expect(reads, 2);
      held.complete();
      expect(
        (await old).map((bot) => bot.profile.name),
        isNot(contains('newbot')),
      );
    },
  );

  for (final botsVisible in [true, false]) {
    test(
      'production status counts RPC and Dashboard proof with Bots visible=$botsVisible',
      () async {
        var now = DateTime.utc(2026, 10, 13);
        final fixture = BotsFixture();
        _append(fixture, 1);
        final administration = AdministrationFixture();
        addTearDown(administration.server.close);
        var collision = false;
        administration.rpcOverride = (method, params) async {
          if (method == 'session.active_list') {
            return {
              'sessions': [
                {
                  'id': 'runtime',
                  'session_key': 'atlas-chat',
                  'status': 'working',
                },
              ],
            };
          }
          return fixture.read(params['profile'] as String, method, params);
        };
        administration.override = (method, path, query, body) async {
          if (path == 'profiles') return {'profiles': fixture.profiles};
          if (path == 'profiles/active') {
            return {'current': 'atlas', 'active': 'atlas'};
          }
          if (path != 'sessions/atlas-chat') {
            throw StateError('Unexpected Dashboard read');
          }
          final profile = query['profile'];
          if (profile == 'atlas' || (collision && profile == 'nova')) {
            return {'id': 'atlas-chat', 'profile': profile, 'hidden': true};
          }
          throw DashboardSessionNotFound(path);
        };
        final repository = BotsRepository.forServer(
          administration.server,
          groupObservations: GroupObservations(
            WorkspaceScope(
              connectionId: (administration.server).connectionId,
              connectionIdentity: (administration.server).connectionIdentity,
              profileName: 'default',
            ),
          ),
        );
        final owner = BotsSession((_) async => [repository], now: () => now);
        addTearDown(owner.dispose);
        if (botsVisible) {
          owner.setVisible(true);
        } else {
          owner.setRecentsVisible(Object(), true);
        }
        await owner.refresh();
        expect(
          owner.state.bots
              .firstWhere((bot) => bot.profile.name == 'atlas')
              .presence,
          BotPresence.working,
        );
        for (var tick = 1; tick <= 2; tick++) {
          if (tick == 2) {
            collision = true;
            fixture.profiles.add(BotsFixture.profile('nova', 'Nova'));
          }
          administration.rpcRequests.clear();
          administration.requests.clear();
          now = now.add(Duration(seconds: botsVisible ? 10 : 30));
          await owner.refresh();
          expect(
            administration.rpcRequests,
            unorderedEquals([
              ('default', 'profiles.list'),
              ('default', 'session.active_list'),
              ('default', 'groups.capabilities'),
              ('default', 'groups.state'),
            ]),
          );
          final proofProfiles = [
            'atlas',
            'mira',
            'forge',
            if (collision) 'nova',
          ];
          expect(
            administration.requests.map((request) => request.$1),
            everyElement('GET'),
          );
          expect(
            administration.requests.map(
              (request) => (request.$2, request.$3['profile']),
            ),
            [
              for (final profile in proofProfiles) ...[
                ('profiles', null),
                ('profiles/active', null),
                ('sessions/atlas-chat', profile),
                if (profile == 'mira' || profile == 'forge') ...[
                  ('profiles', null),
                  ('profiles/active', null),
                ],
              ],
            ],
          );
          expect(administration.requests, hasLength(collision ? 16 : 13));
          expect(
            owner.state.bots
                .firstWhere((bot) => bot.profile.name == 'atlas')
                .presence,
            collision ? BotPresence.unknown : BotPresence.working,
          );
          if (collision) {
            expect(
              owner.state.bots
                  .firstWhere((bot) => bot.profile.name == 'nova')
                  .presence,
              BotPresence.unknown,
            );
          }
        }
      },
    );
  }

  test(
    'malformed readiness retries after failure floor and recovery enables groups',
    () async {
      var now = DateTime.utc(2026, 10, 13);
      final fixture = BotsFixture(now: () => now);
      Object? driver = false;
      var readinessReads = 0;
      fixture.readHook = (_, method, _) async {
        if (method == 'groups.capabilities') {
          readinessReads++;
          return driver == null
              ? {}
              : {
                  'driver': driver,
                  'seatable_profiles': ['atlas', 'mira', 'forge'],
                };
        }
        return null;
      };
      final owner = BotsSession(
        (_) async => [fixture.repository],
        now: () => now,
      );
      addTearDown(owner.dispose);
      owner.setVisible(true);
      await owner.refresh();
      expect(owner.state.groupHosts, isEmpty);
      driver = null;
      now = now.add(const Duration(seconds: 10));
      await owner.refresh();
      driver = true;
      now = now.add(const Duration(seconds: 10));
      await owner.refresh();
      expect(readinessReads, 2);
      expect(owner.state.groupHosts, isEmpty);
      now = now.add(const Duration(seconds: 20));
      await owner.refresh();
      expect(readinessReads, 3);
      expect(owner.state.groupHosts, ['instance-1']);
    },
  );

  test(
    'catalog refresh preserves fresh message coverage and updates identity',
    () async {
      var now = DateTime.utc(2026, 10, 13);
      final fixture = BotsFixture(now: () => now);
      _append(fixture, 1);
      var logReads = 0;
      fixture.readHook = (_, method, _) async {
        if (method == 'groups.log') logReads++;
        return null;
      };
      final owner = BotsSession(
        (_) async => [fixture.repository],
        now: () => now,
      );
      addTearDown(owner.dispose);
      await owner.refresh();
      now = now.add(const Duration(seconds: 299));
      await owner.refresh();
      expect(logReads, 1);
      fixture.room['name'] = 'New catalog name';
      now = now.add(const Duration(seconds: 1));
      await owner.refresh();
      expect(logReads, 1);
      final room = owner.observedGroups.single;
      expect(room.name, 'New catalog name');
      expect(room.observationComplete, true);
      expect(room.messageCoverageSequence, 1);
      expect(room.preview, 'Answer 1');
    },
  );

  test(
    'Bots status is ten seconds, previews thirty, catalog five minutes',
    () async {
      var now = DateTime.utc(2026, 10, 13);
      final fixture = BotsFixture(now: () => now);
      _append(fixture, 1);
      final counts = <String, int>{};
      fixture.readHook = (_, method, params) async {
        final key = method == 'profiles.list'
            ? '$method:${params['include_sessions']}'
            : method;
        counts.update(key, (value) => value + 1, ifAbsent: () => 1);
        return null;
      };
      final owner = BotsSession(
        (_) async => [fixture.repository],
        now: () => now,
      );
      addTearDown(owner.dispose);
      owner.setVisible(true);
      await owner.refresh();
      expect(counts['profiles.list:true'], 1);
      expect(counts['profiles.list:false'], isNull);
      expect(counts['groups.list'], 1);
      expect(counts['groups.state'], 1);
      expect(counts['groups.log'], 1);
      expect(counts['groups.capabilities'], 1);

      now = now.add(const Duration(seconds: 10));
      await owner.refresh();
      expect(counts['profiles.list:true'], 2);
      expect(counts['session.active_list'], 2);
      expect(counts['groups.capabilities'], 2);
      expect(counts['groups.state'], 2);
      expect(counts['groups.list'], 1);
      expect(counts['groups.log'], 1);
      expect(counts['profiles.get_asset'], isNull);

      _append(fixture, 2);
      now = now.add(const Duration(seconds: 20));
      await owner.refresh();
      expect(counts['groups.log'], 2);
      expect(counts['groups.state'], 3);
      expect(counts['groups.list'], 1);
      expect(owner.observedGroups.single.preview, 'Answer 2');

      now = now.add(const Duration(seconds: 270));
      await owner.refresh();
      expect(counts['groups.list'], 2);
      expect(counts['profiles.list:false'], isNull);
      expect(counts['profiles.list:true'], 4);
      expect(counts['groups.state'], 4);
      expect(counts['groups.log'], 2);
    },
  );

  test('Recents alone admits status every thirty seconds', () async {
    var now = DateTime.utc(2026, 10, 13);
    final fixture = BotsFixture(now: () => now);
    _append(fixture, 1);
    final counts = <String, int>{};
    fixture.readHook = (_, method, _) async {
      counts.update(method, (value) => value + 1, ifAbsent: () => 1);
      return null;
    };
    final owner = BotsSession(
      (_) async => [fixture.repository],
      now: () => now,
    );
    addTearDown(owner.dispose);
    owner.setRecentsVisible(Object(), true);
    await owner.refresh();
    now = now.add(const Duration(seconds: 10));
    await owner.refresh();
    expect(counts['session.active_list'], 1);
    expect(counts['groups.state'], 1);
    expect(counts['groups.capabilities'], 1);
    expect(counts['groups.log'], 1);
    now = now.add(const Duration(seconds: 20));
    await owner.refresh();
    expect(counts['session.active_list'], 2);
    expect(counts['groups.state'], 2);
    expect(counts['groups.capabilities'], 2);
    expect(counts['groups.log'], 1);
    expect(counts['groups.list'], 1);
    owner.setVisible(true);
    await owner.refresh();
    now = now.add(const Duration(seconds: 10));
    await owner.refresh();
    expect(counts['session.active_list'], 3);
    expect(counts['groups.state'], 3);
    expect(counts['groups.log'], 1);
  });

  for (final failure in ['state', 'driver', 'history']) {
    test('failed $failure reads wait thirty seconds before retry', () async {
      var now = DateTime.utc(2026, 10, 13);
      final fixture = BotsFixture(now: () => now);
      _append(fixture, 1);
      var broken = true, stateReads = 0, logReads = 0;
      fixture.readHook = (_, method, _) async {
        if (method == 'groups.state') {
          stateReads++;
          if (broken && failure == 'state') throw StateError('Offline');
          if (broken && failure == 'driver') {
            return {
              'room': {...fixture.room, 'latest_seq': 1},
            };
          }
        }
        if (method == 'groups.log') {
          logReads++;
          if (broken && failure == 'history') throw StateError('Offline');
        }
        return null;
      };
      final owner = BotsSession(
        (_) async => [fixture.repository],
        now: () => now,
      );
      addTearDown(owner.dispose);
      owner.setVisible(true);
      await owner.refresh();
      expect(stateReads, 1);
      expect(logReads, failure == 'state' ? 0 : 1);
      expect(owner.observedGroups.single.activeMemberProfiles, isEmpty);
      broken = false;
      now = now.add(const Duration(seconds: 10));
      await owner.refresh();
      expect(stateReads, failure == 'history' ? 2 : 1);
      expect(logReads, failure == 'state' ? 0 : 1);
      now = now.add(const Duration(seconds: 19));
      await owner.refresh();
      expect(stateReads, failure == 'history' ? 3 : 1);
      expect(logReads, failure == 'state' ? 0 : 1);
      now = now.add(const Duration(seconds: 1));
      await owner.refresh();
      expect(stateReads, failure == 'history' ? 3 : 2);
      expect(logReads, failure == 'history' ? 2 : 1);
      expect(owner.observedGroups.single.runtimeAvailable, true);
      expect(owner.observedGroups.single.observationComplete, true);
      expect(owner.observedGroups.single.preview, 'Answer 1');
    });
  }

  test(
    'slow preview finishes across newer status observations without starvation',
    () async {
      var now = DateTime.utc(2026, 10, 13);
      final fixture = BotsFixture(now: () => now);
      _append(fixture, 1);
      final owner = BotsSession(
        (_) async => [fixture.repository],
        now: () => now,
      );
      addTearDown(owner.dispose);
      owner.setVisible(true);
      await owner.refresh();
      _append(fixture, 2);
      final logStarted = Completer<void>();
      final releaseLog = Completer<void>();
      var logReads = 0, stateReads = 0;
      var nextState = Completer<void>();
      fixture.readHook = (_, method, _) async {
        if (method == 'groups.state') {
          stateReads++;
          if (!nextState.isCompleted) nextState.complete();
          return {
            'room': {...fixture.room, 'latest_seq': fixture.events.length},
            'driver_status': {
              'working': fixture.events.length >= 3,
              'blocked': fixture.events.length >= 4,
              'member_activity': [
                if (fixture.events.length >= 3) ...[
                  {'member_id': 'atlas', 'status': 'running'},
                  {'member_id': 'mira', 'status': 'queued'},
                ],
              ],
              'pending_actions': <Map<String, dynamic>>[],
            },
          };
        }
        if (method == 'groups.log') {
          logReads++;
          logStarted.complete();
          await releaseLog.future;
        }
        return null;
      };
      now = now.add(const Duration(seconds: 30));
      final preview = owner.refresh();
      await logStarted.future;
      _append(fixture, 3);
      nextState = Completer<void>();
      now = now.add(const Duration(seconds: 10));
      final second = owner.refresh();
      await nextState.future;
      await Future<void>.delayed(Duration.zero);
      expect(owner.observedGroups.single.working, true);
      _append(fixture, 4);
      nextState = Completer<void>();
      now = now.add(const Duration(seconds: 10));
      final third = owner.refresh();
      await nextState.future;
      await Future<void>.delayed(Duration.zero);
      expect(owner.observedGroups.single.blocked, true);
      releaseLog.complete();
      await Future.wait([preview, second, third]);
      final room = owner.observedGroups.single;
      expect(logReads, 1);
      expect(stateReads, 3);
      expect(room.preview, 'Answer 2');
      expect(room.messageCoverageSequence, 2);
      expect(room.latestSequence, 4);
      expect(room.working, true);
      expect(room.blocked, true);
      expect(room.activeMemberProfiles, {'atlas', 'mira'});
    },
  );
}

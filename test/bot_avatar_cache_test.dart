import 'package:wing/core/services/group_observations.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/bot_profile_edit_session.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'support/bots_fixture.dart';

const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aK7sAAAAASUVORK5CYII=';
Future<void> settle() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

WorkspaceScope scope(String name) => WorkspaceScope(
  connectionId: 'host',
  connectionIdentity: 'instance-1',
  profileName: name,
);
ProfileSessionKey key(String name) =>
    ProfileSessionKey(scope(name), '$name-chat');
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'editor reload revalidates a fresh avatar and adopts confirmed removal',
    () async {
      final fixture = BotsFixture();
      fixture.profiles.first['has_avatar'] = true;
      var reads = 0, absent = false;
      fixture.readHook = (_, method, _) async {
        if (method != 'profiles.get_asset') return null;
        reads++;
        return absent ? {'found': false} : {'found': true, 'data': png};
      };
      final owner = BotsSession((_) async => [fixture.repository]);
      addTearDown(owner.dispose);
      final bot = (await owner.botForConversation(key('atlas')))!;
      final borrower = owner.createAvatarBorrower()..replaceDemand({bot.scope});
      await settle();
      expect(reads, 1);
      final editor = BotProfileEditSession(
        fixture.repository,
        bot,
        avatars: borrower,
        validateImage: (bot) => owner.reloadAvatar(bot.scope),
        onSaved: (bot, image, assetSaved) =>
            owner.acceptAppearance(bot, image: image, assetSaved: assetSaved),
      );
      addTearDown(editor.dispose);
      expect(editor.image, isNotNull);
      absent =
          true; // Stock hint is unchanged; the asset response proves removal.
      await editor.reload();
      expect(reads, 2);
      expect(editor.image, isNull);
      expect(editor.error, isNull);
      await owner.refresh();
      await settle();
      expect(reads, 2, reason: 'Normal wakes still respect negative freshness');
    },
  );

  test(
    'editor reload admits an externally saved photo after a classic shape',
    () async {
      final fixture = BotsFixture();
      fixture.profiles.first['has_avatar'] = true;
      fixture.profiles.first['ui_meta']['hermes-bots']['imageKind'] = 'shape';
      var reads = 0;
      fixture.readHook = (_, method, _) async {
        if (method != 'profiles.get_asset') return null;
        reads++;
        return {'found': true, 'data': png};
      };
      final owner = BotsSession((_) async => [fixture.repository]);
      addTearDown(owner.dispose);
      final bot = (await owner.botForConversation(key('atlas')))!;
      final editor = BotProfileEditSession(
        fixture.repository,
        bot,
        avatars: owner.createAvatarBorrower(),
        validateImage: (bot) => owner.reloadAvatar(bot.scope),
        onSaved: (bot, image, assetSaved) =>
            owner.acceptAppearance(bot, image: image, assetSaved: assetSaved),
      );
      addTearDown(editor.dispose);
      await settle();
      expect(reads, 0);
      expect(editor.image, isNull);
      fixture.profiles.first['ui_meta']['hermes-bots']['imageKind'] = 'photo';
      await editor.reload();
      expect(reads, 1);
      expect(editor.bot.hasExplicitClassicShape, false);
      expect(editor.image, isNotNull);
      expect(editor.error, isNull);
    },
  );

  test(
    'explicit avatar reload shares pending work and keeps failure cooldown',
    () async {
      var now = DateTime.utc(2026, 10, 13);
      final fixture = BotsFixture(now: () => now);
      fixture.profiles.first['has_avatar'] = true;
      var reads = 0;
      final started = Completer<void>(), release = Completer<void>();
      fixture.readHook = (_, method, _) async {
        if (method != 'profiles.get_asset') return null;
        reads++;
        if (reads == 2) {
          started.complete();
          await release.future;
          throw StateError('Unavailable avatar');
        }
        return {'found': true, 'data': png};
      };
      final owner = BotsSession(
        (_) async => [fixture.repository],
        now: () => now,
      );
      addTearDown(owner.dispose);
      final borrower = owner.createAvatarBorrower()
        ..replaceDemand({scope('atlas')});
      await settle();
      final original = borrower.imageFor(scope('atlas'))!;
      final version = owner.avatarContentVersion(scope('atlas'));
      final first = owner.reloadAvatar(scope('atlas'));
      await started.future;
      final joined = owner.reloadAvatar(scope('atlas'));
      await owner.refresh();
      expect(reads, 2);
      now = now.add(const Duration(seconds: 10));
      release.complete();
      await Future.wait([first, joined]);
      expect(borrower.imageFor(scope('atlas')), same(original));
      now = now.add(const Duration(seconds: 29));
      await owner.reloadAvatar(scope('atlas'));
      expect(reads, 2);
      now = now.add(const Duration(seconds: 1));
      await owner.reloadAvatar(scope('atlas'));
      expect(reads, 3);
      expect(borrower.imageFor(scope('atlas')), same(original));
      expect(owner.avatarContentVersion(scope('atlas')), version);
    },
  );

  test(
    'equal validation preserves the actual MemoryImage provider across metadata and presence',
    () async {
      var now = DateTime.utc(2026, 10, 13);
      final fixture = BotsFixture(now: () => now);
      fixture.profiles.first['has_avatar'] = true;
      var reads = 0;
      fixture.readHook = (_, method, _) async {
        if (method == 'profiles.get_asset') {
          reads++;
          return {'found': true, 'data': png};
        }
        return null;
      };
      final owner = BotsSession(
        (_) async => [fixture.repository],
        now: () => now,
      );
      addTearDown(owner.dispose);
      final borrower = owner.createAvatarBorrower()
        ..replaceDemand({scope('atlas')});
      await settle();
      final image = borrower.imageFor(scope('atlas'))!;
      final provider = MemoryImage(image);
      final version = owner.avatarContentVersion(scope('atlas'));
      expect(reads, 1);
      (fixture.profiles.first['ui_meta'] as Map)['hermes-bots']['title'] =
          'Renamed';
      now = now.add(const Duration(seconds: 30));
      await owner.refresh();
      await settle();
      expect(owner.cachedAppearance(key('atlas'))!.title, 'Renamed');
      expect(MemoryImage(borrower.imageFor(scope('atlas'))!), provider);
      expect(reads, 1);
      now = now.add(const Duration(minutes: 5));
      await owner.refresh();
      await settle();
      expect(reads, 2);
      expect(borrower.imageFor(scope('atlas')), same(image));
      expect(owner.avatarContentVersion(scope('atlas')), version);
    },
  );

  test(
    'metadata and canonical misses do not read assets or repeat complete rosters',
    () async {
      final fixture = BotsFixture();
      fixture.profiles.first['has_avatar'] = true;
      var assets = 0, rosters = 0;
      fixture.readHook = (_, method, _) async {
        if (method == 'profiles.list') rosters++;
        if (method == 'profiles.get_asset') assets++;
        return null;
      };
      final owner = BotsSession((_) async => [fixture.repository]);
      addTearDown(owner.dispose);
      for (var i = 0; i < 40; i++) {
        expect(
          await owner.botForConversation(
            ProfileSessionKey(scope('atlas'), 'ordinary-$i'),
          ),
          isNull,
        );
      }
      expect(rosters, 1);
      expect(assets, 0);
      expect((await owner.botForConversation(key('atlas')))!.title, 'Atlas');
    },
  );

  test(
    'warm selection is canonical activity plus selected priority and two transient borrowers release independently',
    () async {
      final fixture = BotsFixture();
      fixture.profiles.clear();
      for (var i = 0; i < 12; i++) {
        final row = BotsFixture.profile('bot$i', 'Bot $i')
          ..['has_avatar'] = true;
        row['canonical_session'] = <String, dynamic>{
          ...row['canonical_session'],
          'last_active': 1700000000 + i,
        };
        fixture.profiles.add(row);
      }
      var reads = 0;
      fixture.readHook = (_, method, _) async {
        if (method == 'profiles.get_asset') {
          reads++;
          return {'found': true, 'data': png};
        }
        return null;
      };
      final owner = BotsSession((_) async => [fixture.repository]);
      addTearDown(owner.dispose);
      final a = owner.createAvatarBorrower()..replaceDemand({scope('bot0')});
      final b = owner.createAvatarBorrower()..replaceDemand({scope('bot0')});
      await settle();
      expect(owner.state.bots.length, 12);
      expect(owner.warmAvatarCount, 10);
      expect(owner.retainedAvatarCount, 11);
      expect(owner.warmAvatarBytes, 10 * base64Decode(png).length);
      final image = a.imageFor(scope('bot0'));
      a.dispose();
      expect(b.imageFor(scope('bot0')), same(image));
      b.dispose();
      expect(owner.retainedAvatarCount, 10);
      final c = owner.createAvatarBorrower()..replaceDemand({scope('bot0')});
      await settle();
      expect(reads, 12); // Warm ten, first transient, reopened transient.
      owner.setSelectedAvatar(scope('bot0'));
      await settle();
      c.dispose();
      expect(owner.warmAvatarCount, 10);
      expect(owner.retainedAvatarCount, 10);
      final d = owner.createAvatarBorrower()..replaceDemand({scope('bot0')});
      await settle();
      expect(d.imageFor(scope('bot0')), isNotNull);
      expect(reads, 12);
    },
  );

  test(
    'absence and failed reads survive repeated opens with distinct validation clocks',
    () async {
      var now = DateTime.utc(2026, 10, 13);
      final fixture = BotsFixture();
      fixture.profiles.first['has_avatar'] = true;
      var reads = 0;
      var absent = false;
      fixture.readHook = (_, method, _) async {
        if (method == 'profiles.get_asset') {
          reads++;
          if (absent) return {'found': false};
          throw StateError('unavailable');
        }
        return null;
      };
      final owner = BotsSession(
        (_) async => [fixture.repository],
        now: () => now,
      );
      addTearDown(owner.dispose);
      for (var i = 0; i < 3; i++) {
        final borrower = owner.createAvatarBorrower()
          ..replaceDemand({scope('atlas')});
        await settle();
        borrower.dispose();
      }
      expect(reads, 1);
      now = now.add(const Duration(seconds: 30));
      absent = true;
      final borrower = owner.createAvatarBorrower()
        ..replaceDemand({scope('atlas')});
      await settle();
      expect(reads, 2);
      borrower.dispose();
      now = now.add(const Duration(minutes: 4));
      final next = owner.createAvatarBorrower()
        ..replaceDemand({scope('atlas')});
      await settle();
      expect(reads, 2);
      next.dispose();
      now = now.add(const Duration(minutes: 1));
      owner.createAvatarBorrower().replaceDemand({scope('atlas')});
      await settle();
      expect(reads, 3);
    },
  );

  test(
    'ambiguous no-avatar hints preserve pixels, share confirmation and respect cooldown',
    () async {
      var now = DateTime.utc(2026, 10, 13);
      final fixture = BotsFixture();
      fixture.profiles.first['has_avatar'] = true;
      var reads = 0;
      var failed = false;
      fixture.readHook = (_, method, _) async {
        if (method == 'profiles.get_asset') {
          reads++;
          if (failed) throw StateError('offline');
          return {'found': true, 'data': png};
        }
        return null;
      };
      final owner = BotsSession(
        (_) async => [fixture.repository],
        now: () => now,
      );
      addTearDown(owner.dispose);
      final borrower = owner.createAvatarBorrower()
        ..replaceDemand({scope('atlas')});
      await settle();
      final original = borrower.imageFor(scope('atlas'));
      expect(original, isNotNull);
      fixture.profiles.first['has_avatar'] = false;
      failed = true;
      now = now.add(const Duration(seconds: 30));
      await owner.refresh();
      await settle();
      expect(reads, 2);
      expect(borrower.imageFor(scope('atlas')), same(original));
      for (var i = 0; i < 2; i++) {
        now = now.add(const Duration(seconds: 10));
        await owner.refresh();
        await settle();
      }
      expect(reads, 2);
      expect(borrower.imageFor(scope('atlas')), same(original));
    },
  );

  test(
    'hint changes and exact saved values fence old asset results independently',
    () async {
      var now = DateTime.utc(2026, 10, 13);
      final fixture = BotsFixture();
      fixture.profiles.first['has_avatar'] = true;
      fixture.profiles[1]['has_avatar'] = true;
      final held = Completer<Map<String, dynamic>?>();
      var atlasReads = 0;
      fixture.readHook = (profile, method, _) async {
        if (method == 'profiles.get_asset') {
          if (profile == 'atlas' && ++atlasReads == 1) return held.future;
          return {'found': true, 'data': png};
        }
        return null;
      };
      final owner = BotsSession(
        (_) async => [fixture.repository],
        now: () => now,
      );
      addTearDown(owner.dispose);
      final borrower = owner.createAvatarBorrower()
        ..replaceDemand({scope('atlas'), scope('mira')});
      await settle();
      final bot = (await owner.identitiesForProfiles([
        scope('atlas'),
      ], canRead: () => true))[scope('atlas')]!;
      owner.acceptAppearance(bot, image: base64Decode(png), assetSaved: true);
      held.complete({'found': false});
      await settle();
      expect(borrower.imageFor(scope('atlas')), base64Decode(png));
      expect(borrower.imageFor(scope('mira')), base64Decode(png));
      now = now.add(const Duration(seconds: 30));
      fixture.profiles.first['canonical_session'] = null;
      await owner.refresh();
      await settle();
      expect(owner.cachedAppearance(key('atlas')), isNull);
      expect(borrower.imageFor(scope('atlas')), isNotNull);
    },
  );

  test(
    'removed sources reject held image publication for mounted borrowers',
    () async {
      final fixture = BotsFixture();
      fixture.profiles.first['has_avatar'] = true;
      final held = Completer<Map<String, dynamic>?>();
      fixture.readHook = (_, method, _) async =>
          method == 'profiles.get_asset' ? held.future : null;
      var connected = true;
      final owner = BotsSession(
        (_) async => connected ? [fixture.repository] : [],
      );
      addTearDown(owner.dispose);
      final borrower = owner.createAvatarBorrower()
        ..replaceDemand({scope('atlas')});
      await settle();
      connected = false;
      await owner.refresh();
      held.complete({'found': true, 'data': png});
      await settle();
      expect(owner.retainedAvatarCount, 0);
      expect(owner.cachedAppearance(key('atlas')), isNull);
      expect(borrower.imageFor(scope('atlas')), isNull);
      borrower.dispose();
    },
  );
  test('foreground wakes share a recently validated avatar', () async {
    final fixture = BotsFixture();
    fixture.profiles.first['has_avatar'] = true;
    var reads = 0;
    fixture.readHook = (_, method, _) async {
      if (method == 'profiles.get_asset') {
        reads++;
        return {'found': true, 'data': png};
      }
      return null;
    };
    final owner = BotsSession((_) async => [fixture.repository]);
    addTearDown(owner.dispose);
    owner.setVisible(true);
    await owner.refresh();
    await settle();
    await owner.refresh();
    await settle();
    expect(reads, 1);
  });

  test(
    'all mounted borrowers and sender lookup share three physical asset slots',
    () async {
      final fixture = BotsFixture()
        ..profiles.add(BotsFixture.profile('fourth', 'Fourth'));
      for (final row in fixture.profiles) {
        row['has_avatar'] = true;
      }
      final held = Completer<Map<String, dynamic>?>();
      var active = 0, peak = 0, reads = 0;
      fixture.readHook = (_, method, _) async {
        if (method != 'profiles.get_asset') return null;
        reads++;
        active++;
        if (active > peak) peak = active;
        final result = await held.future;
        active--;
        return result;
      };
      final owner = BotsSession((_) async => [fixture.repository]);
      addTearDown(owner.dispose);
      final borrower = owner.createAvatarBorrower()
        ..replaceDemand({
          for (final row in fixture.profiles) scope(row['name'] as String),
        });
      owner.createAvatarBorrower().replaceDemand({scope('atlas')});
      await settle();
      expect(
        (await owner.appearanceForSender(scope('mira'), 'atlas'))!.scope,
        scope('atlas'),
      );
      expect(reads, 3);
      expect(peak, 3);
      held.complete({'found': true, 'data': png});
      await settle();
      expect(reads, 4);
      expect(peak, 3);
      expect(borrower.imageFor(scope('atlas')), isNotNull);
    },
  );
  test(
    'one warm budget spans authenticated sources while same names stay isolated',
    () async {
      final first = BotsFixture(), second = BotsFixture();
      for (final fixture in [first, second]) {
        fixture.profiles.clear();
        for (var i = 0; i < 6; i++) {
          final row = BotsFixture.profile('bot$i', 'Bot $i')
            ..['has_avatar'] = true;
          row['canonical_session'] = <String, dynamic>{
            ...row['canonical_session'],
            'last_active':
                1700000000 + i + (identical(fixture, second) ? 10 : 0),
          };
          fixture.profiles.add(row);
        }
      }
      var reads = 0;
      for (final fixture in [first, second]) {
        fixture.readHook = (_, method, _) async {
          if (method == 'profiles.get_asset') {
            reads++;
            return {'found': true, 'data': png};
          }
          return null;
        };
      }
      final other = BotsRepository(
        groupObservations: GroupObservations(
          WorkspaceScope(
            connectionId: 'other',
            connectionIdentity: 'instance-2',
            profileName: 'default',
          ),
        ),
        scope: WorkspaceScope(
          connectionId: 'other',
          connectionIdentity: 'instance-2',
          profileName: 'default',
        ),
        instance: 'Other',
        read: second.read,
        command: second.command,
        ownership: second.ownership,

      );
      final owner = BotsSession((_) async => [first.repository, other]);
      addTearDown(owner.dispose);
      await owner.refresh();
      owner.setSelectedAvatar(scope('bot0'));
      final selected = owner.createAvatarBorrower()
        ..replaceDemand({scope('bot0')});
      await settle();
      expect(owner.state.bots, hasLength(12));
      expect(owner.warmAvatarCount, 10);
      expect(reads, 10);
      expect(selected.imageFor(scope('bot0')), isNotNull);
      final sameName = WorkspaceScope(
        connectionId: 'other',
        connectionIdentity: 'instance-2',
        profileName: 'bot0',
      );
      final otherBorrower = owner.createAvatarBorrower()
        ..replaceDemand({sameName});
      await settle();
      expect(otherBorrower.imageFor(sameName), isNotNull);
      expect(reads, 10);
      expect(otherBorrower.imageFor(scope('bot0')), isNull);
      final excluded = owner.createAvatarBorrower()
        ..replaceDemand({scope('bot1')});
      await settle();
      expect(reads, 11);
      expect(owner.retainedAvatarCount, 11);
      excluded.dispose();
      expect(owner.retainedAvatarCount, 10);
    },
  );
  test(
    'unavailable source discovery coalesces repeated opens until retry is eligible',
    () async {
      var now = DateTime.utc(2026, 10, 13);
      var reads = 0;
      var unavailable = true;
      final fixture = BotsFixture();
      final owner = BotsSession((_) async {
        reads++;
        if (unavailable) throw StateError('offline');
        return [fixture.repository];
      }, now: () => now);
      addTearDown(owner.dispose);
      for (var i = 0; i < 4; i++) {
        expect(await owner.botForConversation(key('atlas')), isNull);
      }
      expect(reads, 1);
      unavailable = false;
      now = now.add(const Duration(seconds: 30));
      expect((await owner.botForConversation(key('atlas')))!.title, 'Atlas');
      expect(reads, 2);
    },
  );
  test(
    'acknowledged procedural mode immediately clears borrowed pixels and notifies presentation',
    () async {
      final fixture = BotsFixture();
      fixture.profiles.first['has_avatar'] = true;
      fixture.readHook = (_, method, _) async =>
          method == 'profiles.get_asset' ? {'found': true, 'data': png} : null;
      final owner = BotsSession((_) async => [fixture.repository]);
      addTearDown(owner.dispose);
      final borrower = owner.createAvatarBorrower()
        ..replaceDemand({scope('atlas')});
      await settle();
      expect(borrower.imageFor(scope('atlas')), isNotNull);
      var changes = 0;
      borrower.changes.addListener(() => changes++);
      final bot = owner.cachedAppearance(key('atlas'))!;
      owner.acceptAppearance(
        bot.withMetadata(
          metadata: {...bot.metadata, 'imageKind': 'shape', 'shape': 'circle'},
          revision: 3,
          shape: 'circle',
        ),
      );
      expect(borrower.imageFor(scope('atlas')), isNull);
      expect(changes, greaterThan(0));
    },
  );
}

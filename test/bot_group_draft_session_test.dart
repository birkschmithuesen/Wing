import 'package:wing/core/services/group_observations.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_colors.dart';
import 'package:wing/core/services/bot_avatar_io.dart';
import 'package:wing/core/services/bot_group_draft_session.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/bots_preferences.dart';

import 'support/bots_fixture.dart';

class _Picker extends BotAvatarIo {
  _Picker(this.read);
  final Future<Uint8List?> Function() read;
  @override
  Future<Uint8List?> pick() => read();
}

class _PromptPreferences extends BotsPreferences {
  _PromptPreferences(super.preferences);
  bool fail = true;
  Completer<void>? held;
  @override
  Future<void> writePicturePrompt(
    String identity,
    String roomId,
    String prompt,
  ) async {
    if (fail) throw StateError('Device write failed');
    await held?.future;
    await super.writePicturePrompt(identity, roomId, prompt);
  }
}

Uint8List _photo() => Uint8List.fromList(
  image.encodePng(
    image.Image(width: 64, height: 32)..clear(image.ColorRgb8(38, 128, 119)),
  ),
);

Future<void> _awaitRoster(BotsSession session) async {
  if (!session.state.loading) return;
  final settled = Completer<void>();
  void changed() {
    if (!session.state.loading && !settled.isCompleted) settled.complete();
  }

  session.addListener(changed);
  try {
    await settled.future.timeout(const Duration(seconds: 5));
  } finally {
    session.removeListener(changed);
  }
}

/// Stock per-key merge/CAS semantics, without a device preference mirror.
class _PictureBackend {
  _PictureBackend(this.fixture) {
    fixture.profiles.add(profile);
    fixture.commandHook = command;
  }
  final BotsFixture fixture;
  final Map<String, dynamic> profile = jsonDecode(
    jsonEncode(BotsFixture.profile('default', 'Hermes')),
  );
  bool loseConfirmation = false, reject = false;
  Future<Map<String, dynamic>?> command(
    String _,
    String method,
    Map<String, dynamic> params,
  ) async {
    if (method != 'profiles.configure') return null;
    final incoming = Map<String, dynamic>.from(params['ui_meta'] as Map);
    final expected = params['ui_meta_expected_revisions'] as Map;
    final revisions = profile['ui_meta_revisions'] as Map;
    if (reject ||
        incoming.keys.any((key) => expected[key] != (revisions[key] ?? 0))) {
      return {
        'applied': {
          'ui_meta': false,
          'ui_meta_conflicts': {'changed': true},
        },
      };
    }
    (profile['ui_meta'] as Map).addAll(incoming);
    final written = <String, int>{};
    for (final key in incoming.keys) {
      written[key] = revisions[key] = (revisions[key] as int? ?? 0) + 1;
    }
    if (loseConfirmation) {
      loseConfirmation = false;
      throw StateError('Lost picture acknowledgement');
    }
    return {
      'applied': {'ui_meta': true, 'ui_meta_revisions': written},
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(BotsFixture, BotsSession)> roster({DateTime Function()? now}) async {
    final fixture = BotsFixture();
    final session = BotsSession((_) async => [fixture.repository], now: now);
    addTearDown(session.dispose);
    await session.refresh();
    return (fixture, session);
  }

  Future<(BotsFixture, BotsSession, _PictureBackend)> editingRoster({
    DateTime Function()? now,
  }) async {
    final fixture = BotsFixture();
    final backend = _PictureBackend(fixture);
    backend.profile['ui_meta']['wing-group-icon:room-1'] = {
      'version': 1,
      'color': ProfileColorChoice.cyan.slot,
      'data': base64Encode(_photo()),
    };
    backend.profile['ui_meta_revisions']['wing-group-icon:room-1'] = 3;
    final session = BotsSession((_) async => [fixture.repository], now: now);
    addTearDown(session.dispose);
    await session.refresh();
    return (fixture, session, backend);
  }

  test(
    'new group uses seatable profiles and rechecks eligibility before create',
    () async {
      var now = DateTime.utc(2026, 11, 8);
      final (fixture, session) = await roster(now: () => now);
      final capabilities = await fixture.read(
        'default',
        'groups.capabilities',
        {},
      );
      var eligible = ['atlas', 'mira'];
      fixture.readHook = (_, method, _) async => method == 'groups.capabilities'
          ? {...capabilities, 'seatable_profiles': eligible}
          : null;
      now = now.add(const Duration(seconds: 31));
      await session.refresh();
      final draft = BotGroupDraftSession(session);
      addTearDown(draft.dispose);
      expect(
        draft.bots.map((bot) => bot.profile.name),
        unorderedEquals(eligible),
      );
      final excluded = session.state.bots.firstWhere(
        (bot) => bot.profile.name == 'forge',
      );
      expect(draft.canSelect(excluded), false);
      for (final bot in draft.bots) {
        draft.select(bot, true);
      }
      expect(draft.canSave, true);
      eligible = ['atlas'];
      expect(await draft.save(canUse: () => true), false);
      expect(
        fixture.commands.where((command) => command.$2 == 'groups.create'),
        isEmpty,
      );
      expect(draft.error, contains('cannot join'));
      expect(draft.selected, hasLength(2));
      await session.refresh();
      final reopened = BotGroupDraftSession(session);
      addTearDown(reopened.dispose);
      expect(reopened.bots.map((bot) => bot.profile.name), ['atlas']);
      final editing = BotGroupDraftSession(
        session,
        existing: session.state.groups.single,
      );
      addTearDown(editing.dispose);
      expect(editing.bots.map((bot) => bot.profile.name), contains('mira'));
    },
  );

  test(
    'group create retires during eligibility read without dispatch',
    () async {
      final (fixture, session) = await roster();
      final capabilities = await fixture.read(
        'default',
        'groups.capabilities',
        {},
      );
      final held = Completer<Map<String, dynamic>>();
      fixture.readHook = (_, method, _) async =>
          method == 'groups.capabilities' ? held.future : null;
      var active = true;
      final create = fixture.repository.createGroup(
        'new-room',
        'New room',
        session.state.bots.take(2).toList(),
        () => active,
        () {},
      );
      active = false;
      held.complete(capabilities);
      await expectLater(create, throwsStateError);
      expect(fixture.commands, isEmpty);
    },
  );

  test(
    'room picture prompt survives editor and preferences reconstruction',
    () async {
      final (fixture, session, _) = await editingRoster();
      final draft = BotGroupDraftSession(
        session,
        existing: session.state.groups.single,
      );
      const prompt = '  Teal robots, paper cut shapes.\nNo letters.  ';
      draft.setPicturePrompt(prompt);
      expect(await draft.rememberPicturePrompt(), true);
      expect(
        draft.canSave,
        false,
        reason: 'Prompt edits do not change the Hermes room.',
      );
      draft.dispose();
      SharedPreferences.resetStatic();
      final reopenedRoster = BotsSession((_) async => [fixture.repository]);
      addTearDown(reopenedRoster.dispose);
      await reopenedRoster.refresh();
      final reopened = BotGroupDraftSession(
        reopenedRoster,
        existing: reopenedRoster.state.groups.single,
      );
      addTearDown(reopened.dispose);
      expect(reopened.picturePrompt, prompt);
      reopened.setName('Renamed room');
      expect(reopened.picturePrompt, prompt);
      reopened.setPicturePrompt('');
      expect(await reopened.rememberPicturePrompt(), true);
      final blank = BotGroupDraftSession(
        reopenedRoster,
        existing: reopenedRoster.state.groups.single,
      );
      addTearDown(blank.dispose);
      expect(
        blank.picturePrompt,
        isEmpty,
        reason: 'An empty edit must not restore the default.',
      );
      final preferences = await BotsPreferences.load();
      expect(preferences.picturePrompt('instance-1', 'other-room'), isNull);
      expect(preferences.picturePrompt('other-instance', 'room-1'), isNull);
      expect(fixture.commands, isEmpty);
    },
  );

  test(
    'failed generation retains the prompt for another editor visit',
    () async {
      final (fixture, session, backend) = await editingRoster();
      fixture.commandHook = (profile, method, params) =>
          method == 'image.generate'
          ? Future.error(StateError('Provider unavailable'))
          : backend.command(profile, method, params);
      final draft = BotGroupDraftSession(
        session,
        existing: session.state.groups.single,
      );
      addTearDown(draft.dispose);
      final oldPicture = draft.picture;
      await draft.generatePicture(
        'My last attempted prompt',
        canUse: () => true,
      );
      expect(draft.error, contains('could not be prepared'));
      expect(draft.picture, oldPicture);
      final reopened = BotGroupDraftSession(
        session,
        existing: session.state.groups.single,
      );
      addTearDown(reopened.dispose);
      expect(reopened.picturePrompt, 'My last attempted prompt');
      expect(fixture.commands.single.$3['prompt'], 'My last attempted prompt');
    },
  );

  test(
    'prompt persistence failure retains editable text and permits retry',
    () async {
      final fixture = BotsFixture();
      final preferences = _PromptPreferences(
        await SharedPreferences.getInstance(),
      );
      final session = BotsSession(
        (_) async => [fixture.repository],
        loadPreferences: () async => preferences,
      );
      addTearDown(session.dispose);
      await session.refresh();
      final draft = BotGroupDraftSession(session);
      addTearDown(draft.dispose);
      draft.setPicturePrompt('Keep this edit');
      expect(await draft.rememberPicturePrompt(), false);
      expect(draft.picturePrompt, 'Keep this edit');
      expect(draft.error, contains('Reopen Room picture to retry'));
      preferences.fail = false;
      expect(await draft.rememberPicturePrompt(), true);
      expect(draft.error, isNull);
      expect(fixture.commands, isEmpty);
    },
  );

  test(
    'held prompt persistence reserves generation and retires without dispatch',
    () async {
      final fixture = BotsFixture();
      final preferences =
          _PromptPreferences(await SharedPreferences.getInstance())
            ..fail = false
            ..held = Completer<void>();
      final session = BotsSession(
        (_) async => [fixture.repository],
        loadPreferences: () async => preferences,
      );
      addTearDown(session.dispose);
      await session.refresh();
      final draft = BotGroupDraftSession(session);
      for (final bot in draft.bots.take(2)) {
        draft.select(bot, true);
      }
      final pending = draft.generatePicture('First prompt', canUse: () => true);
      expect(draft.pictureBusy, true);
      await draft.generatePicture('Second prompt', canUse: () => true);
      expect(draft.picturePrompt, 'First prompt');
      draft.dispose();
      preferences.held!.complete();
      await pending;
      expect(fixture.commands, isEmpty);
    },
  );

  test(
    'existing draft retains its saved details and fixed membership without writes',
    () async {
      final (fixture, session, _) = await editingRoster();
      final group = session.state.groups.single;
      final draft = BotGroupDraftSession(session, existing: group);
      addTearDown(draft.dispose);
      expect(draft.name, group.name);
      expect(draft.picture, _photo());
      expect(draft.iconColor, ProfileColorChoice.cyan);
      expect(group.withPinned(true).iconRevision, 3);
      expect(draft.canSave, false);
      expect(await draft.save(canUse: () => true), false);
      draft.select(draft.bots.first, true);
      draft.chooseInstance('another-instance');
      expect(draft.identity, group.scope.connectionIdentity);
      expect(draft.memberCount, 2);
      expect(draft.existing!.members, group.members);
      expect(fixture.commands, isEmpty);
      draft.setName('');
      expect(draft.canSave, false);
    },
  );

  test(
    'existing room saves name, palette and picture removal to its exact backend identity',
    () async {
      final (fixture, session, backend) = await editingRoster();
      final group = session.state.groups.single;
      final draft = BotGroupDraftSession(session, existing: group);
      addTearDown(draft.dispose);
      draft.setName('Field team');
      draft.chooseColor(ProfileColorChoice.rose);
      draft.removePicture();
      expect(await draft.save(canUse: () => true), true);
      expect(fixture.commands.map((c) => c.$2), [
        'profiles.configure',
        'groups.rename',
      ]);
      final saved = session.state.groups.single;
      expect(saved.id, group.id);
      expect(saved.name, 'Field team');
      expect(saved.iconColor, ProfileColorChoice.rose);
      expect(saved.iconRevision, 4);
      expect(saved.picture, isNull);
      expect(saved.members.map((m) => m.id), group.members.map((m) => m.id));
      expect(backend.profile['ui_meta']['wing-group-icon:room-1'], {
        'version': 1,
        'color': ProfileColorChoice.rose.slot,
      });
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );

  test(
    'existing room retries a lost icon acknowledgement without creating or uploading twice',
    () async {
      final (fixture, session, backend) = await editingRoster();
      backend.loseConfirmation = true;
      final draft = BotGroupDraftSession(
        session,
        existing: session.state.groups.single,
      );
      addTearDown(draft.dispose);
      draft.setName('Evidence team');
      draft.chooseColor(ProfileColorChoice.blue);
      expect(await draft.save(canUse: () => true), false);
      expect(draft.frozen, true);
      draft.setName('Other name');
      draft.chooseColor(ProfileColorChoice.red);
      draft.removePicture();
      expect(draft.name, 'Evidence team');
      expect(draft.iconColor, ProfileColorChoice.blue);
      expect(draft.picture, _photo());
      expect(await draft.save(canUse: () => true), true);
      expect(
        fixture.commands.where((c) => c.$2 == 'profiles.configure'),
        hasLength(1),
      );
      expect(fixture.commands.where((c) => c.$2 == 'groups.create'), isEmpty);
      expect(fixture.room['name'], 'Evidence team');
    },
  );

  test(
    'existing room reuses the same rename event after a lost acknowledgement',
    () async {
      final (fixture, session, backend) = await editingRoster();
      var lost = true;
      fixture.commandHook = (profile, method, params) async {
        if (method == 'groups.rename' && lost) {
          lost = false;
          fixture.room['name'] = params['name'];
          throw StateError('Lost rename acknowledgement');
        }
        return backend.command(profile, method, params);
      };
      final draft = BotGroupDraftSession(
        session,
        existing: session.state.groups.single,
      );
      addTearDown(draft.dispose);
      draft.setName('New room name');
      expect(await draft.save(canUse: () => true), false);
      expect(await draft.save(canUse: () => true), true);
      final renames = fixture.commands
          .where((c) => c.$2 == 'groups.rename')
          .toList();
      expect(renames, hasLength(2));
      expect(renames[0].$3, renames[1].$3);
      expect(renames[0].$3['room_id'], 'room-1');
      expect(
        fixture.commands.where((c) => c.$2 == 'profiles.configure'),
        isEmpty,
      );
    },
  );

  test(
    'stale room icon and name edits never overwrite a newer backend observation',
    () async {
      final (fixture, session, backend) = await editingRoster();
      final draft = BotGroupDraftSession(
        session,
        existing: session.state.groups.single,
      );
      addTearDown(draft.dispose);
      draft.setName('My room name');
      draft.chooseColor(ProfileColorChoice.red);
      backend.profile['ui_meta']['wing-group-icon:room-1']['color'] =
          ProfileColorChoice.green.slot;
      backend.profile['ui_meta_revisions']['wing-group-icon:room-1'] = 4;
      expect(await draft.save(canUse: () => true), false);
      expect(draft.error, contains('Reopen Edit group'));
      expect(fixture.commands, isEmpty);
      expect(fixture.room['name'], 'Research team');
      expect(
        backend.profile['ui_meta']['wing-group-icon:room-1']['color'],
        ProfileColorChoice.green.slot,
      );
    },
  );

  test(
    'a concurrently renamed room is rejected before editing its icon',
    () async {
      final (fixture, session, _) = await editingRoster();
      final draft = BotGroupDraftSession(
        session,
        existing: session.state.groups.single,
      );
      addTearDown(draft.dispose);
      draft.setName('My room name');
      fixture.room['name'] = 'Changed on another device';
      expect(await draft.save(canUse: () => true), false);
      expect(fixture.commands, isEmpty);
      expect(draft.error, contains('Group changed'));
    },
  );

  test(
    'editing an undecorated stock room saves its chosen icon without recreating membership',
    () async {
      var now = DateTime.utc(2026, 10, 13);
      final (fixture, session) = await roster(now: () => now);
      _PictureBackend(fixture);
      now = now.add(const Duration(minutes: 5));
      await session.refresh();
      final draft = BotGroupDraftSession(
        session,
        existing: session.state.groups.single,
        random: Random(25),
      );
      addTearDown(draft.dispose);
      // An undecorated room can already start with the requested palette color.
      final color = draft.iconColor == ProfileColorChoice.magenta
          ? ProfileColorChoice.cyan
          : ProfileColorChoice.magenta;
      draft.chooseColor(color);
      expect(draft.hasChanges, true);
      expect(await draft.save(canUse: () => true), true);
      expect(fixture.commands.map((c) => c.$2), ['profiles.configure']);
      expect(session.state.groups.single.iconColor, color);
    },
  );

  test(
    'editing with unreadable icon metadata or a retired route cannot dispatch',
    () async {
      final (fixture, session) = await roster();
      final draft = BotGroupDraftSession(
        session,
        existing: session.state.groups.single,
      );
      addTearDown(draft.dispose);
      expect(draft.editable, false);
      expect(draft.error, contains('Refresh Bots'));
      draft.setName('Blocked');
      expect(await draft.save(canUse: () => true), false);
      expect(fixture.commands, isEmpty);
      final (readyFixture, ready, _) = await editingRoster();
      final admitted = BotGroupDraftSession(
        ready,
        existing: ready.state.groups.single,
      );
      addTearDown(admitted.dispose);
      admitted.setName('Not dispatched');
      expect(await admitted.save(canUse: () => false), false);
      expect(admitted.frozen, false);
      expect(readyFixture.commands, isEmpty);
    },
  );

  test(
    'editing a live room preserves unread message provenance in its immediate observation',
    () async {
      var now = DateTime.utc(2026, 10, 13);
      final (fixture, session, _) = await editingRoster(now: () => now);
      fixture.events.add({
        'room_id': 'room-1',
        'seq': 1,
        'kind': 'message.member',
        'actor': {'kind': 'member', 'id': 'mira', 'profile': 'mira'},
        'payload': {'text': 'The evidence is ready.'},
        'created_at': 1791756000.0,
      });
      fixture.pending.add({
        'kind': 'retry',
        'task_id': 'task-1',
        'member_id': 'atlas',
        'execution_generation': 4,
      });
      now = now.add(const Duration(seconds: 30));
      await session.refresh();
      final before = session.state.groups.single;
      expect(before.lastAnswerSequence, 1);
      expect(before.lastMessageAt, isNotNull);
      expect(before.blocked, true);
      final draft = BotGroupDraftSession(session, existing: before);
      addTearDown(draft.dispose);
      draft.setName('Evidence review');
      expect(await draft.save(canUse: () => true), true);
      final after = session.state.groups.single;
      expect(after.name, 'Evidence review');
      expect(after.preview, before.preview);
      expect(after.lastAnswerSequence, before.lastAnswerSequence);
      expect(after.lastMessageSequence, before.lastMessageSequence);
      expect(after.lastMessageAt, before.lastMessageAt);
      expect(after.blocked, before.blocked);
      expect(after.withPinned(true).lastAnswerSequence, 1);
    },
  );

  test('stock metadata adapter confirms its saved room picture', () async {
    final fixture = BotsFixture();
    _PictureBackend(fixture);
    await fixture.repository.saveGroupIcon(
      'room-1',
      0,
      ProfileColorChoice.cyan,
      _photo(),
      () => true,
      () {},
    );
    expect(
      (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).single.picture,
      _photo(),
    );
  });

  test(
    'default icon uses one random palette choice and survives backend reload without a picture',
    () async {
      final (fixture, session) = await roster();
      final backend = _PictureBackend(fixture);
      final draft = BotGroupDraftSession(session, random: Random(14));
      addTearDown(draft.dispose);
      final color = draft.iconColor;
      expect(color.slot, isNotNull);
      for (final bot in draft.bots.take(2)) {
        draft.select(bot, true);
      }
      draft.setName('  Research team');
      expect(draft.iconColor, color);
      expect(await draft.save(canUse: () => true), true);
      fixture.room['room_id'] = fixture.commands.first.$3['room_id'];
      fixture.room['name'] = 'Research team';
      final saved = (await readFixtureGroups(
        fixture.repository,
        groupMessages: null,
      )).single;
      expect(saved.iconColor, color);
      expect(saved.picture, isNull);
      expect(saved.withPinned(true).iconColor, color);
      final meta = backend.profile['ui_meta']['wing-group-icon:${saved.id}'];
      expect(meta, {'version': 1, 'color': color.slot});
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );

  test(
    'an acknowledgement without matching server readback cannot finish creation',
    () async {
      final (fixture, session) = await roster();
      final backend = _PictureBackend(fixture);
      fixture.commandHook = (profile, method, params) async {
        final result = await backend.command(profile, method, params);
        if (method == 'profiles.configure') {
          for (final key in (params['ui_meta'] as Map).keys) {
            (backend.profile['ui_meta'] as Map).remove(key);
          }
        }
        return result;
      };
      final draft = BotGroupDraftSession(
        session,
        pictureIo: _Picker(() async => _photo()),
      );
      addTearDown(draft.dispose);
      for (final bot in draft.bots.take(2)) {
        draft.select(bot, true);
      }
      await draft.pickPicture(canUse: () => true);
      expect(await draft.save(canUse: () => true), false);
      expect(draft.frozen, true);
      expect(draft.error, isNotNull);
      expect(draft.picture, isNotNull);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );

  for (final operation in ['upload', 'generate']) {
    test(
      'detailed transparent room pictures keep alpha through $operation, saving and reload',
      () async {
        final (fixture, session, backend) = await editingRoster();
        final random = Random(9);
        final source = image.Image(width: 256, height: 256, numChannels: 4);
        for (final pixel in source) {
          pixel.setRgba(
            random.nextInt(256),
            random.nextInt(256),
            random.nextInt(256),
            pixel.x < 32 || pixel.y < 32 ? 0 : (pixel.x < 64 ? 128 : 255),
          );
        }
        final bytes = image.encodePng(source);
        expect(bytes.length, greaterThan(BotsRepository.groupPictureMaxBytes));
        fixture.commandHook = (profile, method, params) async {
          if (method == 'image.generate') {
            return {'success': true, 'image_data': base64Encode(bytes)};
          }
          return backend.command(profile, method, params);
        };
        final draft = BotGroupDraftSession(
          session,
          existing: session.state.groups.single,
          pictureIo: _Picker(() async => bytes),
        );
        addTearDown(draft.dispose);
        if (operation == 'upload') {
          await draft.pickPicture(canUse: () => true);
        } else {
          await draft.generatePicture('Transparent emblem', canUse: () => true);
        }
        expect(draft.error, isNull);
        expect(
          draft.picture!.length,
          lessThanOrEqualTo(BotsRepository.groupPictureMaxBytes),
        );
        final decoded = image.decodeImage(draft.picture!)!;
        expect(decoded.getPixel(0, 0).a, 0);
        expect(
          decoded.getPixel(decoded.width * 48 ~/ 256, decoded.height ~/ 2).a,
          128,
        );
        expect(
          decoded.getPixel(decoded.width ~/ 2, decoded.height ~/ 2).a,
          255,
        );
        expect(await draft.save(canUse: () => true), true);
        await session.refresh();
        expect(
          session.state.groups.single.picture,
          orderedEquals(draft.picture!),
        );
      },
    );
  }

  test(
    'a detailed source photo is compressed below the Hermes metadata limit',
    () async {
      final (_, session) = await roster();
      final random = Random(9);
      final photo = image.Image(width: 256, height: 256);
      for (final pixel in photo) {
        pixel.setRgb(
          random.nextInt(256),
          random.nextInt(256),
          random.nextInt(256),
        );
      }
      final source = Uint8List.fromList(image.encodePng(photo));
      expect(source.length, greaterThan(BotsRepository.groupPictureMaxBytes));
      final draft = BotGroupDraftSession(
        session,
        pictureIo: _Picker(() async => source),
      );
      addTearDown(draft.dispose);
      await draft.pickPicture(canUse: () => true);
      expect(draft.error, isNull);
      expect(
        draft.picture!.length,
        lessThanOrEqualTo(BotsRepository.groupPictureMaxBytes),
      );
      final decoded = image.decodeImage(draft.picture!);
      expect((decoded!.width, decoded.height), (256, 256));
    },
  );

  Future<(BotsFixture, BotGroupDraftSession)> newDraft() async {
    final fixture = BotsFixture();
    fixture.profiles.addAll([
      for (final name in ['pace', 'butler', 'reminder', 'memory'])
        BotsFixture.profile(name, name),
    ]);
    final session = BotsSession((_) async => [fixture.repository]);
    addTearDown(session.dispose);
    await session.refresh();
    final draft = BotGroupDraftSession(session);
    addTearDown(draft.dispose);
    return (fixture, draft);
  }

  test('new groups require at least two selected members', () async {
    final (fixture, draft) = await newDraft();
    expect(draft.canSave, false);
    draft.select(draft.bots[0], true);
    expect(draft.canSave, false);
    draft.select(draft.bots[1], true);
    expect(draft.canSave, true);
    expect(fixture.commands, isEmpty);
  });
  test(
    'suggested group name follows membership until explicitly named',
    () async {
      final (_, draft) = await newDraft();
      draft.select(draft.bots[0], true);
      draft.select(draft.bots[1], true);
      expect(draft.effectiveName, 'Atlas, Mira');
      draft.select(draft.bots[0], false);
      expect(draft.effectiveName, 'Mira');
      draft.setName('  Mission team  ');
      draft.select(draft.bots[0], true);
      expect(draft.effectiveName, 'Mission team');
    },
  );
  test(
    'member search excludes already selected bots without losing selection',
    () async {
      final (_, draft) = await newDraft();
      draft.select(draft.bots[0], true);
      draft.select(draft.bots[1], true);
      draft.search('@bot_mira');
      expect(draft.matches, isEmpty);
      draft.search('@bot_forge');
      expect(draft.matches.single.profile.name, 'forge');
      expect(draft.selected, hasLength(2));
    },
  );
  test('group names are bounded in Unicode codepoints', () async {
    final (_, draft) = await newDraft();
    draft.setName('🪽' * 70);
    expect(draft.name, '🪽' * 64);
  });
  test(
    'seventh group member is refused without changing selected members',
    () async {
      final (fixture, draft) = await newDraft();
      expect(draft.bots.length, greaterThan(6));
      for (final bot in draft.bots) {
        draft.select(bot, true);
      }
      expect(draft.selected, hasLength(6));
      expect(draft.contains(draft.bots.last), false);
      expect(fixture.commands, isEmpty);
    },
  );

  for (final intent in [
    'crop',
    'cancel replacement',
    'invalid replacement',
    'remove',
  ]) {
    test(
      'room picture $intent preserves the requested draft behavior',
      () async {
        final (fixture, session) = await roster();
        Uint8List? next = _photo();
        final draft = BotGroupDraftSession(
          session,
          pictureIo: _Picker(() async => next),
        );
        addTearDown(draft.dispose);
        await draft.pickPicture(canUse: () => true);
        final saved = draft.picture;
        expect(saved, isNotNull);
        switch (intent) {
          case 'crop':
            final decoded = image.decodePng(saved!);
            expect((decoded!.width, decoded.height), (256, 256));
          case 'cancel replacement':
            next = null;
            await draft.pickPicture(canUse: () => true);
            expect(draft.picture, same(saved));
            expect(draft.pictureBusy, isFalse);
          case 'invalid replacement':
            next = Uint8List.fromList([1, 2, 3]);
            await draft.pickPicture(canUse: () => true);
            expect(draft.picture, same(saved));
            expect(draft.error, contains('could not be prepared'));
            expect(draft.pictureBusy, isFalse);
          case 'remove':
            draft.removePicture();
            expect(draft.picture, isNull);
        }
        expect(fixture.commands, isEmpty);
      },
    );
  }

  test(
    'picture preparation logs its stage while preserving the existing banner',
    () async {
      final previousPrint = debugPrint;
      final lines = <String>[];
      debugPrint = (message, {wrapWidth}) {
        if (message != null) lines.add(message);
      };
      addTearDown(() => debugPrint = previousPrint);
      final (_, session) = await roster();
      Uint8List? next = _photo();
      var readFails = false;
      final draft = BotGroupDraftSession(
        session,
        pictureIo: _Picker(() async {
          if (readFails) throw StateError('SECRET_NEVER_LOG');
          return next;
        }),
      );
      addTearDown(draft.dispose);
      await draft.pickPicture(canUse: () => true);
      final saved = draft.picture;
      for (final thumbnailFailure in [false, true]) {
        lines.clear();
        readFails = !thumbnailFailure;
        next = Uint8List.fromList([1, 2, 3]);
        await draft.pickPicture(canUse: () => true);
        expect(draft.picture, same(saved));
        expect(draft.pictureBusy, false);
        expect(
          draft.error,
          'Room picture could not be prepared. Try another image or generate again.',
        );
        final record = jsonDecode(
          lines
              .singleWhere((line) => line.contains('bots.group_picture_failed'))
              .substring('[WingConnection] '.length),
        );
        expect(record['operation'], 'upload');
        expect(record['stage'], thumbnailFailure ? 'thumbnail' : 'read');
        expect(record['elapsed_ms'], isA<int>());
        expect(record['retired'], false);
        if (thumbnailFailure) expect(record['input_bytes'], 3);
        expect(lines.join(), isNot(contains('SECRET_NEVER_LOG')));
      }
    },
  );

  test(
    'picture diagnostic printer failure leaves recovery and the banner unchanged',
    () async {
      final (_, session) = await roster();
      final draft = BotGroupDraftSession(
        session,
        pictureIo: _Picker(() async => throw StateError('Unreadable image')),
      );
      addTearDown(draft.dispose);
      final previousPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => throw StateError('Printer failed');
      try {
        await draft.pickPicture(canUse: () => true);
        expect(draft.pictureBusy, false);
        expect(
          draft.error,
          'Room picture could not be prepared. Try another image or generate again.',
        );
      } finally {
        debugPrint = previousPrint;
      }
    },
  );

  test(
    'generation targets stock default image API without changing bot assets',
    () async {
      final (fixture, session) = await roster();
      fixture.commandHook = (_, method, _) async => method == 'image.generate'
          ? {'success': true, 'image_data': base64Encode(_photo())}
          : null;
      final draft = BotGroupDraftSession(session);
      addTearDown(draft.dispose);
      for (final bot in draft.bots.take(2)) {
        draft.select(bot, true);
      }
      await draft.generatePicture('  Mint wing emblem  ', canUse: () => true);
      expect(draft.picture, isNotNull);
      expect(fixture.commands, hasLength(1));
      expect(fixture.commands.single.$1, 'default');
      expect(fixture.commands.single.$2, 'image.generate');
      expect(fixture.commands.single.$3, {
        'prompt': 'Mint wing emblem',
        'aspect_ratio': 'square',
        'max_bytes': 8000000,
      });
    },
  );

  test(
    'successive generated group pictures above 2 MB are transferred and cropped',
    () async {
      final (fixture, session) = await roster();
      final large = image.encodePng(
        image.Image(width: 1024, height: 768, numChannels: 3)
          ..clear(image.ColorRgb8(38, 128, 119)),
        level: 0,
      );
      expect(large.length, greaterThan(2000000));
      final responses = [_photo(), _photo(), large, large];
      var attempt = 0;
      fixture.commandHook = (_, method, params) async {
        if (method != 'image.generate') return null;
        final bytes = responses[attempt++];
        // Stock Hermes saves the original, then omits image_data above the cap.
        return {
          'available': true,
          'success': true,
          'image': '/generated/room.png',
          if (bytes.length <= (params['max_bytes'] as int))
            'image_data': base64Encode(bytes),
        };
      };
      final draft = BotGroupDraftSession(session);
      addTearDown(draft.dispose);
      for (final bot in draft.bots.take(2)) {
        draft.select(bot, true);
      }
      for (var i = 0; i < responses.length; i++) {
        await draft.generatePicture('Team emblem', canUse: () => true);
        expect(draft.error, isNull, reason: 'Generation ${i + 1}');
        expect(draft.pictureBusy, false);
        expect(
          draft.picture!.length,
          lessThanOrEqualTo(BotsRepository.groupPictureMaxBytes),
        );
        final decoded = image.decodeImage(draft.picture!);
        expect((decoded!.width, decoded.height), (256, 256));
      }
      expect(attempt, 4);
      expect(
        fixture.commands.every((call) => call.$2 == 'image.generate'),
        true,
      );
    },
  );

  test(
    'unconfirmed create freezes the draft and retries its original room',
    () async {
      final (fixture, session) = await roster();
      final draft = BotGroupDraftSession(
        session,
        pictureIo: _Picker(() async => _photo()),
      );
      addTearDown(draft.dispose);
      for (final bot in draft.bots.take(2)) {
        draft.select(bot, true);
      }
      await draft.pickPicture(canUse: () => true);
      final picture = draft.picture;
      fixture.commandHook = (_, method, _) async {
        if (method == 'groups.create') throw StateError('Lost confirmation');
        return null;
      };
      expect(await draft.save(canUse: () => true), false);
      final first = fixture.commands.single.$3;
      expect(first['name'], 'Atlas, Mira');
      expect(first.keys, unorderedEquals(['room_id', 'name', 'members']));
      expect(draft.frozen, true);
      draft.setName('Another team');
      draft.select(draft.bots.last, true);
      draft.removePicture();
      expect(draft.effectiveName, 'Atlas, Mira');
      expect(draft.selected, hasLength(2));
      expect(draft.picture, same(picture));
      await _awaitRoster(session);
      fixture.room['room_id'] = first['room_id'];
      fixture.room['name'] = first['name'];
      final backend = _PictureBackend(fixture);
      await session.refresh();
      expect(session.state.groups.single.picture, isNull);
      expect(await draft.save(canUse: () => true), true);
      expect(
        fixture.commands.where((cmd) => cmd.$2 == 'groups.create').last.$3,
        first,
      );
      expect(backend.profile['ui_meta']['hermes-bots']['title'], 'Hermes');
      expect(
        (await readFixtureGroups(
          fixture.repository,
          groupMessages: null,
        )).single.picture,
        picture,
      );
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );

  test(
    'lost picture ACK retries the same room and confirms remote bytes without reupload',
    () async {
      final (fixture, session) = await roster();
      final backend = _PictureBackend(fixture)..loseConfirmation = true;
      final draft = BotGroupDraftSession(
        session,
        pictureIo: _Picker(() async => _photo()),
      );
      addTearDown(draft.dispose);
      for (final bot in draft.bots.take(2)) {
        draft.select(bot, true);
      }
      await draft.pickPicture(canUse: () => true);
      expect(await draft.save(canUse: () => true), false);
      final first = fixture.commands.first.$3;
      fixture.room['room_id'] = first['room_id'];
      await _awaitRoster(session);
      expect(await draft.save(canUse: () => true), true);
      expect(
        fixture.commands.where((cmd) => cmd.$2 == 'profiles.configure'),
        hasLength(1),
      );
      expect(
        fixture.commands.where((cmd) => cmd.$2 == 'groups.create').last.$3,
        first,
      );
      final fresh = BotsSession((_) async => [fixture.repository]);
      addTearDown(fresh.dispose);
      await fresh.refresh();
      expect(fresh.state.groups.single.picture, draft.picture);
      expect(backend.profile['ui_meta']['hermes-bots']['unrelated'], isNotNull);
      final other = BotsFixture();
      expect(
        (await readFixtureGroups(
          other.repository,
          groupMessages: null,
        )).single.picture,
        isNull,
      );
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );

  test(
    'rejected picture save keeps creation open; retry uses CAS and preserves other rooms',
    () async {
      final (fixture, session) = await roster();
      final backend = _PictureBackend(fixture)..reject = true;
      backend.profile['ui_meta']['wing-group-icon:other-room'] = {
        'version': 1,
        'data': base64Encode(_photo()),
      };
      final draft = BotGroupDraftSession(
        session,
        pictureIo: _Picker(() async => _photo()),
      );
      addTearDown(draft.dispose);
      for (final bot in draft.bots.take(2)) {
        draft.select(bot, true);
      }
      await draft.pickPicture(canUse: () => true);
      expect(await draft.save(canUse: () => true), false);
      expect(draft.frozen, true);
      await _awaitRoster(session);
      backend.reject = false;
      expect(await draft.save(canUse: () => true), true);
      final write = fixture.commands.last.$3;
      expect(write['name'], 'default');
      expect((write['ui_meta'] as Map).keys, hasLength(1));
      expect((write['ui_meta_expected_revisions'] as Map).values.single, 0);
      expect(jsonEncode(write['ui_meta']).length, lessThan(65536));
      expect(
        backend.profile['ui_meta']['wing-group-icon:other-room'],
        isNotNull,
      );
      expect(
        fixture.commands.any((cmd) => cmd.$2 == 'profiles.set_asset'),
        false,
      );
    },
  );

  test(
    'route retirement during picture metadata read prevents the upload',
    () async {
      final fixture = BotsFixture();
      _PictureBackend(fixture);
      final held = Completer<Map<String, dynamic>?>();
      var active = true;
      final started = Completer<void>();
      fixture.readHook = (_, method, params) async {
        if (method == 'profiles.list' && params['include_sessions'] == false) {
          started.complete();
          return held.future;
        }
        return null;
      };
      final operation = fixture.repository.saveGroupIcon(
        'room-id',
        0,
        ProfileColorChoice.cyan,
        _photo(),
        () => active,
        () {},
      );
      await started.future;
      active = false;
      held.complete({'profiles': fixture.profiles});
      await expectLater(operation, throwsStateError);
      expect(fixture.commands, isEmpty);
    },
  );

  test(
    'preparation blocks create and discards a result after route retirement',
    () async {
      final (_, session) = await roster();
      final held = Completer<Uint8List?>();
      var current = true;
      final draft = BotGroupDraftSession(
        session,
        pictureIo: _Picker(() => held.future),
      );
      addTearDown(draft.dispose);
      for (final bot in draft.bots.take(2)) {
        draft.select(bot, true);
      }
      final operation = draft.pickPicture(canUse: () => current);
      expect(draft.pictureBusy, true);
      expect(draft.canSave, false);
      current = false;
      held.complete(_photo());
      await operation;
      expect(draft.picture, isNull);
      expect(draft.pictureBusy, false);
    },
  );

  test(
    'changing host clears members/search/picture and retires a held picker',
    () async {
      final fixture = BotsFixture();
      final second = BotsRepository(
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
        instance: 'Studio server',
        read: fixture.read,

        command: fixture.command,
        ownership: fixture.ownership,
      );
      final session = BotsSession((_) async => [fixture.repository, second]);
      addTearDown(session.dispose);
      await session.refresh();
      final held = Completer<Uint8List?>();
      final draft = BotGroupDraftSession(
        session,
        pictureIo: _Picker(() => held.future),
      );
      addTearDown(draft.dispose);
      draft.select(draft.bots.first, true);
      draft.search('atlas');
      final operation = draft.pickPicture(canUse: () => true);
      draft.chooseInstance('instance-2');
      expect(draft.instance, 'Studio server');
      expect(draft.query, isEmpty);
      expect(draft.selected, isEmpty);
      expect(draft.pictureBusy, false);
      held.complete(_photo());
      await operation;
      expect(draft.picture, isNull);
    },
  );

  test(
    'disposed generation drops late bytes and releases captured repository',
    () async {
      final (fixture, session) = await roster();
      final held = Completer<Map<String, dynamic>>();
      final started = Completer<void>();
      fixture.commandHook = (_, method, _) async {
        if (method != 'image.generate') return null;
        started.complete();
        return held.future;
      };
      final draft = BotGroupDraftSession(session);
      for (final bot in draft.bots.take(2)) {
        draft.select(bot, true);
      }
      final operation = draft.generatePicture('Team icon', canUse: () => true);
      await started.future;
      draft.dispose();
      held.complete({'success': true, 'image_data': base64Encode(_photo())});
      await operation;
      expect(draft.picture, isNull);
      expect(fixture.commands.single.$2, 'image.generate');
    },
  );
}

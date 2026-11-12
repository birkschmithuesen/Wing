import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/profile_colors.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/profile_colors_session.dart';

const _identity = 'colour-session-a';
String _key(String identity, String name) =>
    'profile_color_v1_${sha256.convert(utf8.encode(identity))}_$name';

Future<(AppPreferences, SharedPreferences, _Platform)> _fixture({
  Object? initial = 3,
}) async {
  SharedPreferences.resetStatic();
  final platform = _Platform({'flutter.${_key(_identity, 'work')}': ?initial});
  SharedPreferencesStorePlatform.instance = platform;
  final preferences = await SharedPreferences.getInstance();
  final owner = AppPreferences(preferences);
  addTearDown(() {
    if (!platform.writeRelease.isCompleted) platform.writeRelease.complete();
    if (!platform.reloadRelease.isCompleted) platform.reloadRelease.complete();
    owner.dispose();
    SharedPreferences.setMockInitialValues({});
  });
  return (owner, preferences, platform);
}

ProfileColorsSession _session(
  AppPreferences owner, {
  String identity = _identity,
}) {
  final session = ProfileColorsSession(
    preferences: owner,
    connectionIdentity: identity,
  )..updateProfiles(['work']);
  addTearDown(session.dispose);
  return session;
}

ProfileColorFact _fact(ProfileColorsSession session) =>
    session.state.value.profiles['work']!;

void main() {
  test(
    'absence selects Automatic without storing a synthetic default',
    () async {
      final (owner, preferences, platform) = await _fixture(initial: null);
      final session = _session(owner);
      expect(_fact(session).selected, ProfileColorChoice.automatic);
      expect(_fact(session).notice, isNull);
      expect(preferences.containsKey(_key(_identity, 'work')), isFalse);
      final picker = session.beginChoice('work')!;
      expect(await picker.choose(ProfileColorChoice.automatic), isNull);
      expect(platform.writes, isEmpty);
    },
  );

  for (final malformed in <Object>[
    -1,
    12,
    '3',
    3.0,
    false,
    <String>['3'],
  ]) {
    test(
      'malformed ${malformed.runtimeType} $malformed is repairable',
      () async {
        final (owner, preferences, _) = await _fixture(initial: malformed);
        final session = _session(owner);
        expect(_fact(session).selected, isNull);
        expect(_fact(session).notice, contains('invalid'));
        expect(_fact(session).canChoose, isTrue);
        final picker = session.beginChoice('work')!;
        expect(await picker.choose(ProfileColorChoice.automatic), isNull);
        expect(preferences.containsKey(_key(_identity, 'work')), isFalse);
        expect(_fact(session).selected, ProfileColorChoice.automatic);
        expect(_fact(session).notice, isNull);
      },
    );
  }

  test(
    'removal and re-addition retire a choice queued behind reload',
    () async {
      final (owner, _, platform) = await _fixture();
      final session = _session(owner);
      platform.holdReload = true;
      final reload = owner.reload();
      await platform.reloadStarted.future;
      final picker = session.beginChoice('work')!;
      final choice = picker.choose(ProfileColorChoice.blue);
      session.updateProfiles([]);
      session.updateProfiles(['work']);
      platform.reloadRelease.complete();
      await reload;
      expect(await choice, isNull);
      expect(platform.writes, isEmpty);
      expect(_fact(session).selected, ProfileColorChoice.lime);
    },
  );

  for (final retirement in ['session', 'picker', 'owner']) {
    test('$retirement closure retires a queued colour write', () async {
      final (owner, _, platform) = await _fixture();
      final session = _session(owner);
      final picker = session.beginChoice('work')!;
      final choice = picker.choose(ProfileColorChoice.blue);
      switch (retirement) {
        case 'session':
          session.dispose();
        case 'picker':
          picker.dispose();
        case 'owner':
          owner.dispose();
      }
      expect(await choice, isNull);
      expect(platform.writes, isEmpty);
    });
  }

  test('admitted storage finishes after its session closes', () async {
    final (owner, preferences, platform) = await _fixture();
    final session = _session(owner);
    platform.holdWrite = true;
    final choice = session.beginChoice('work')!.choose(ProfileColorChoice.blue);
    await platform.writeStarted.future;
    session.dispose();
    platform.writeRelease.complete();
    expect(await choice, isNull);
    expect(preferences.get(_key(_identity, 'work')), 8);
    expect((await platform.getAll())['flutter.${_key(_identity, 'work')}'], 8);
    expect(_fact(_session(owner)).selected, ProfileColorChoice.blue);
  });

  test(
    'rebinding while acknowledgement is held retains confirmed colour',
    () async {
      final (owner, _, platform) = await _fixture();
      final session = _session(owner);
      platform.holdWrite = true;
      platform.acknowledgements.addAll([false, false]);
      final choice = session
          .beginChoice('work')!
          .choose(ProfileColorChoice.blue);
      await platform.writeStarted.future;
      session.updateProfiles(['work']);
      final second = _session(owner);
      expect(_fact(session).displayChoice, ProfileColorChoice.lime);
      expect(_fact(second).displayChoice, ProfileColorChoice.lime);
      expect(_fact(session).busy, isTrue);
      platform.writeRelease.complete();
      expect(await choice, contains('verify'));
      expect(_fact(session).displayChoice, ProfileColorChoice.lime);
      expect(_fact(session).selected, isNull);
      expect(_fact(_session(owner)).displayChoice, ProfileColorChoice.lime);
      expect(_fact(session).canChoose, isFalse);
      await owner.reload();
      expect(_fact(session).selected, ProfileColorChoice.lime);
      expect(_fact(session).canChoose, isTrue);
    },
  );

  test(
    'a failed reload cannot replace confirmed colour during rebinding',
    () async {
      final (owner, _, platform) = await _fixture();
      final session = _session(owner);
      platform.failReload = true;
      await expectLater(owner.reload(), throwsStateError);
      session.updateProfiles(['work']);
      final second = _session(owner);
      expect(_fact(session).displayChoice, ProfileColorChoice.lime);
      expect(_fact(second).displayChoice, ProfileColorChoice.lime);
      expect(_fact(session).selected, isNull);
      expect(_fact(session).canChoose, isFalse);
      final before = platform.writes.length;
      expect(
        await session.beginChoice('work')!.choose(ProfileColorChoice.blue),
        matches('[Rr]eload'),
      );
      expect(platform.writes.length, before);
      await owner.reload();
      expect(_fact(session).selected, ProfileColorChoice.lime);
      expect(_fact(session).notice, isNull);
    },
  );

  test(
    'malformed fresh storage retains display with explicit repair state',
    () async {
      final (owner, _, platform) = await _fixture();
      final session = _session(owner);
      await platform.setValue(
        'String',
        'flutter.${_key(_identity, 'work')}',
        'bad',
      );
      await owner.reload();
      expect(_fact(session).displayChoice, ProfileColorChoice.lime);
      expect(_fact(session).selected, isNull);
      expect(_fact(session).notice, contains('invalid'));
      expect(_fact(session).canChoose, isTrue);
    },
  );

  test(
    'colour publication reaches shared consumers without app notifications',
    () async {
      final (owner, _, _) = await _fixture();
      final first = _session(owner);
      final second = _session(owner);
      final other = _session(owner, identity: 'colour-session-b');
      var appNotifications = 0;
      final observedChoices = <ProfileColorChoice?>[];
      var otherNotifications = 0;
      owner.state.addListener(() => appNotifications++);
      second.state.addListener(
        () => observedChoices.add(_fact(second).selected),
      );
      other.state.addListener(() => otherNotifications++);
      await first.beginChoice('work')!.choose(ProfileColorChoice.blue);
      expect(_fact(second).selected, ProfileColorChoice.blue);
      expect(observedChoices, isNotEmpty);
      expect(observedChoices.last, ProfileColorChoice.blue);
      expect(appNotifications, 0);
      expect(otherNotifications, 0);
    },
  );

  test(
    'a reentrant reload follows the already reserved colour command',
    () async {
      final (owner, _, platform) = await _fixture();
      final session = _session(owner);
      Future<void>? reload;
      var requested = false;
      session.state.addListener(() {
        if (_fact(session).busy && !requested) {
          requested = true;
          reload = owner.reload();
        }
      });
      await session.beginChoice('work')!.choose(ProfileColorChoice.blue);
      await reload;
      expect(_fact(session).selected, ProfileColorChoice.blue);
      expect(platform.events, ['write', 'reload']);
    },
  );

  test(
    'closing the owner from a colour listener safely revokes admission',
    () async {
      final (owner, _, platform) = await _fixture();
      final session = _session(owner);
      session.state.addListener(() {
        if (_fact(session).busy) owner.dispose();
      });
      expect(
        await session.beginChoice('work')!.choose(ProfileColorChoice.blue),
        isNull,
      );
      expect(platform.writes, isEmpty);
    },
  );

  test(
    'closing owner during registration retires remaining membership work',
    () async {
      final (owner, _, platform) = await _fixture();
      final session = ProfileColorsSession(
        preferences: owner,
        connectionIdentity: _identity,
      );
      addTearDown(session.dispose);
      session.state.addListener(owner.dispose);
      expect(
        () => session.updateProfiles(['work', 'personal']),
        returnsNormally,
      );
      expect(session.beginChoice('personal'), isNull);
      expect(platform.writes, isEmpty);
    },
  );

  test(
    'closing session during registration stops further colour publications',
    () async {
      final (owner, _, _) = await _fixture();
      final session = ProfileColorsSession(
        preferences: owner,
        connectionIdentity: _identity,
      );
      addTearDown(session.dispose);
      var publications = 0;
      session.state.addListener(() {
        publications++;
        session.dispose();
      });
      session.updateProfiles(['work', 'personal']);
      expect(publications, 1);
      expect(session.state.value.profiles.keys, ['work']);
    },
  );

  test(
    'backup refresh observes colours without adding them to portable fields',
    () async {
      final (owner, _, platform) = await _fixture();
      final session = _session(owner);
      await platform.setValue('int', 'flutter.${_key(_identity, 'work')}', 8);
      final snapshot = await owner.exportBackupSnapshot(connectionIds: []);
      expect(_fact(session).selected, ProfileColorChoice.blue);
      expect(snapshot.explicitlyPresent, isEmpty);
      expect(snapshot.explicitlyPresentVisibility, isEmpty);
    },
  );
}

class _Platform extends InMemorySharedPreferencesStore {
  _Platform(super.data) : super.withData();
  final acknowledgements = <bool>[];
  final writes = <(String, Object?)>[];
  final events = <String>[];
  bool holdWrite = false;
  bool holdReload = false;
  bool failReload = false;
  final writeStarted = Completer<void>();
  final writeRelease = Completer<void>();
  final reloadStarted = Completer<void>();
  final reloadRelease = Completer<void>();

  Future<bool> _acknowledge(
    String key,
    Object? value,
    Future<bool> Function() save,
  ) async {
    writes.add((key, value));
    events.add('write');
    if (holdWrite) {
      holdWrite = false;
      writeStarted.complete();
      await writeRelease.future;
    }
    if (acknowledgements.isNotEmpty && !acknowledgements.removeAt(0)) {
      return false;
    }
    return save();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) =>
      _acknowledge(key, value, () => super.setValue(valueType, key, value));

  @override
  Future<bool> remove(String key) =>
      _acknowledge(key, null, () => super.remove(key));

  @override
  Future<Map<String, Object>> getAll() async {
    if (failReload) {
      failReload = false;
      throw StateError('Held storage could not be read');
    }
    final snapshot = Map<String, Object>.of(await super.getAll());
    // The initial singleton read precedes all test event observations.
    if (writes.isNotEmpty || holdReload) events.add('reload');
    if (holdReload) {
      holdReload = false;
      reloadStarted.complete();
      await reloadRelease.future;
    }
    return snapshot;
  }
}

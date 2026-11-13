import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/profile_selection.dart';
import 'package:wing/core/services/app_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _SelectionPlatform platform;
  late SharedPreferences preferences;
  late AppPreferences owner;
  setUp(() async {
    SharedPreferences.resetStatic();
    platform = _SelectionPlatform();
    SharedPreferencesStorePlatform.instance = platform;
    preferences = await SharedPreferences.getInstance();
    owner = AppPreferences(preferences);
  });
  tearDown(() {
    platform.release.completeIfPending();
    owner.dispose();
    SharedPreferences.setMockInitialValues({});
  });

  Future<ProfileSelectionSettlement> choose(String id, String name) =>
      owner.admitProfileSelection(id, name).settled;
  ProfileSelectionFact fact([String id = 'conn']) =>
      owner.profileSelectionFor(id).value;
  String? physical(String id, Map<String, Object> values) =>
      ProfileSelectionCodec.canonicalName(
        values['flutter.${ProfileSelectionCodec.storageKey(id)}'],
      );

  test('isolates confirmed selections by exact connection identity', () async {
    await choose('prestige-lan', 'client-work');
    await choose('remote-host', 'android-qa');
    expect(fact('prestige-lan').selectedName, 'client-work');
    expect(fact('remote-host').selectedName, 'android-qa');
    expect(physical('prestige-lan', await platform.getAll()), 'client-work');
    expect(physical('remote-host', await platform.getAll()), 'android-qa');
  });

  test(
    'absent uses fresh preference, valid restores, missing requires repair',
    () async {
      const names = ['default', 'client-work', 'android-qa'];
      expect(
        owner.initialProfileSelection(
          'conn',
          availableNames: names,
          preferredName: 'client-work',
        ),
        'client-work',
      );
      expect(fact().validity, ProfileSelectionValidity.absent);
      await choose('conn', 'android-qa');
      expect(
        owner.initialProfileSelection(
          'conn',
          availableNames: names,
          preferredName: 'client-work',
        ),
        'android-qa',
      );
      await choose('conn', 'profile-that-no-longer-exists');
      final before = await platform.getAll();
      expect(
        () => owner.initialProfileSelection(
          'conn',
          availableNames: names,
          preferredName: 'client-work',
        ),
        throwsA(isA<ProfileSelectionRepairRequired>()),
      );
      expect(fact().validity, ProfileSelectionValidity.unavailable);
      expect(fact().selectedName, isNull);
      expect(await platform.getAll(), before);
      expect((await choose('conn', 'default')).confirmed, isTrue);
      expect(fact().selectedName, 'default');
    },
  );

  test('rejects noncanonical choices without writes', () {
    expect(
      () => owner.admitProfileSelection('conn', '../default'),
      throwsArgumentError,
    );
    expect(fact().validity, ProfileSelectionValidity.absent);
    expect(platform.writes, isEmpty);
  });

  for (final invalid in <Object>['../default', 7]) {
    test(
      'present invalid $invalid remains explicit until chosen repair',
      () async {
        await platform.setValue(
          invalid is int ? 'Int' : 'String',
          'flutter.${ProfileSelectionCodec.storageKey('conn')}',
          invalid,
        );
        platform.writes.clear();
        await owner.reload();
        expect(fact().validity, ProfileSelectionValidity.invalid);
        expect(fact().selectedName, isNull);
        expect(
          () => owner.initialProfileSelection(
            'conn',
            availableNames: ['default'],
            preferredName: 'default',
          ),
          throwsA(isA<ProfileSelectionRepairRequired>()),
        );
        expect(platform.writes, isEmpty);
        expect((await choose('conn', 'default')).confirmed, isTrue);
        expect(fact().selectedName, 'default');
      },
    );
  }

  test(
    'false ACK restores prior confirmed choice and exposes failed settlement',
    () async {
      await choose('conn', 'personal');
      platform.failValues.add('work');
      final settled = await choose('conn', 'work');
      expect(physical('conn', await platform.getAll()), 'personal');
      expect(settled.outcome, ProfileSelectionSaveOutcome.failedRestored);
      expect(fact().selectedName, 'personal');
      expect(fact().error, isNotNull);
      expect((await choose('conn', 'work')).confirmed, isTrue);
      expect(fact().selectedName, 'work');
      expect(fact().error, isNull);
    },
  );

  test(
    'partial false ACK and failed rollback require a fresh reload',
    () async {
      await choose('conn', 'personal');
      platform.partialValues.add('work');
      platform.failValues.add('personal');
      final settled = await choose('conn', 'work');
      expect(physical('conn', await platform.getAll()), 'work');
      expect(settled.outcome, ProfileSelectionSaveOutcome.failedUnverified);
      expect(fact().confirmedName, 'personal');
      expect(fact().validity, ProfileSelectionValidity.unverified);
      expect(fact().selectedName, isNull);
      final writes = platform.writes.length;
      expect(
        (await choose('conn', 'default')).outcome,
        ProfileSelectionSaveOutcome.failedUnverified,
      );
      expect(platform.writes, hasLength(writes));
      await owner.reload();
      expect(fact().selectedName, 'work');
      expect(fact().validity, ProfileSelectionValidity.valid);
    },
  );

  test(
    'ordered held write drains latest admission without general-settings publication',
    () async {
      await choose('conn', 'personal');
      var settingsPublications = 0;
      owner.state.addListener(() => settingsPublications++);
      platform.holdValue = 'work';
      final first = owner.admitProfileSelection('conn', 'work');
      final drain = owner.settleProfileSelection('conn');
      await platform.entered.future;
      final newer = owner.admitProfileSelection('conn', 'personal');
      expect(first.queuedBehindSelection, isFalse);
      expect(newer.queuedBehindSelection, isTrue);
      expect(fact().selectedName, 'personal');
      expect(fact().requestedName, 'personal');
      platform.release.complete();
      final result = await drain;
      expect((await first.settled).name, 'work');
      expect((await newer.settled).name, 'personal');
      expect(result.name, 'personal');
      expect(physical('conn', await platform.getAll()), 'personal');
      expect(platform.writes.map((row) => row.$2), [
        'personal',
        'work',
        'personal',
      ]);
      expect(settingsPublications, 0);
    },
  );

  test(
    'reentrant pending observer reserves physical FIFO before next admission',
    () async {
      final channel = owner.profileSelectionFor('conn');
      ProfileSelectionAdmission? newer;
      var added = false;
      channel.addListener(() {
        if (channel.value.busy && !added) {
          added = true;
          newer = owner.admitProfileSelection('conn', 'personal');
        }
      });
      final first = owner.admitProfileSelection('conn', 'work');
      final result = await owner.settleProfileSelection('conn');
      expect((await first.settled).name, 'work');
      expect((await newer!.settled).name, 'personal');
      expect(platform.writes.map((row) => row.$2), ['work', 'personal']);
      expect(physical('conn', await platform.getAll()), 'personal');
      expect(result.name, 'personal');
    },
  );

  test(
    'settlement observer admission is included in an existing drain',
    () async {
      final channel = owner.profileSelectionFor('conn');
      var added = false;
      channel.addListener(() {
        if (!added &&
            !channel.value.busy &&
            channel.value.selectedName == 'work') {
          added = true;
          owner.admitProfileSelection('conn', 'personal');
        }
      });
      owner.admitProfileSelection('conn', 'work');
      final result = await owner.settleProfileSelection('conn');
      expect(result.name, 'personal');
      expect(physical('conn', await platform.getAll()), 'personal');
      expect(platform.writes.map((row) => row.$2), ['work', 'personal']);
    },
  );

  test(
    'closing during first dispatched write settles it and retires queued choice',
    () async {
      platform.holdValue = 'work';
      final first = owner.admitProfileSelection('conn', 'work');
      await platform.entered.future;
      final newer = owner.admitProfileSelection('conn', 'personal');
      owner.dispose();
      platform.release.complete();
      expect((await first.settled).outcome, ProfileSelectionSaveOutcome.saved);
      expect(
        (await newer.settled).outcome,
        ProfileSelectionSaveOutcome.retired,
      );
      expect(platform.writes.map((row) => row.$2), ['work']);
      expect(physical('conn', await platform.getAll()), 'work');
    },
  );

  test(
    'failed fresh reload blocks selection until explicit successful verification',
    () async {
      await choose('conn', 'personal');
      platform.failRead = true;
      await expectLater(owner.reload(), throwsStateError);
      expect(fact().validity, ProfileSelectionValidity.unverified);
      final count = platform.writes.length;
      expect(
        (await choose('conn', 'work')).outcome,
        ProfileSelectionSaveOutcome.failedUnverified,
      );
      expect(platform.writes, hasLength(count));
      platform.failRead = false;
      await owner.reload();
      expect(fact().selectedName, 'personal');
      expect((await choose('conn', 'work')).confirmed, isTrue);
    },
  );

  test(
    'reentrant owner retirement during publication causes zero physical writes',
    () async {
      owner.profileSelectionFor('conn').addListener(owner.dispose);
      final admission = owner.admitProfileSelection('conn', 'work');
      expect(
        (await admission.settled).outcome,
        ProfileSelectionSaveOutcome.retired,
      );
      expect(platform.writes, isEmpty);
    },
  );
}

class _SelectionPlatform extends InMemorySharedPreferencesStore {
  _SelectionPlatform() : super.empty();
  final writes = <(String, Object)>[];
  final failValues = <Object>{};
  final partialValues = <Object>{};
  String? holdValue;
  bool failRead = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<Map<String, Object>> getAll() async {
    if (failRead) throw StateError('Controlled selection reload failure');
    return super.getAll();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.startsWith('flutter.workspace_profile_selection_v1_')) {
      writes.add((key, value));
      if (value == holdValue && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
      if (partialValues.remove(value)) {
        await super.setValue(valueType, key, value);
        return false;
      }
      if (failValues.remove(value)) return false;
    }
    return super.setValue(valueType, key, value);
  }
}

extension on Completer<void> {
  void completeIfPending() {
    if (!isCompleted) complete();
  }
}

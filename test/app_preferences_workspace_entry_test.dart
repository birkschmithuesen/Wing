import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/workspace_entry.dart';
import 'package:wing/core/services/app_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesStorePlatform previousPlatform;
  late _EntryStorage platform;
  late AppPreferences owner;

  setUp(() async {
    previousPlatform = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    platform = _EntryStorage();
    SharedPreferencesStorePlatform.instance = platform;
    owner = AppPreferences(await SharedPreferences.getInstance());
  });
  tearDown(() {
    if (!platform.release.isCompleted) {
      platform.release.complete();
    }
    owner.dispose();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = previousPlatform;
  });

  test(
    'held remembered entry joins later admission and survives actual reload',
    () async {
      final channel = owner.workspaceEntry;
      platform.hold = 'work';
      final first = owner.admitWorkspaceEntry('work');
      await platform.entered.future;
      final second = owner.admitWorkspaceEntry('personal');
      final drain = owner.settleWorkspaceEntry();
      expect(second.queuedBehindEntry, isTrue);
      expect(channel.value.confirmedId, isNull);
      expect(channel.value.requestedId, 'personal');
      expect(platform.writes, ['work']);
      platform.release.complete();
      expect((await first.settled).outcome, WorkspaceEntrySaveOutcome.saved);
      expect((await second.settled).outcome, WorkspaceEntrySaveOutcome.saved);
      expect((await drain).connectionId, 'personal');
      expect(platform.writes, ['work', 'personal']);
      expect(
        (await platform.getAll())['flutter.last_connection_id'],
        'personal',
      );
      await owner.reload();
      expect(channel.value.confirmedId, 'personal');
      expect(channel.value.busy, isFalse);
    },
  );

  test(
    'false ACK restores absence and failed rollback remains unverified',
    () async {
      final channel = owner.workspaceEntry;
      platform.failNext = true;
      expect(
        (await owner.admitWorkspaceEntry('work').settled).outcome,
        WorkspaceEntrySaveOutcome.failedRestored,
      );
      expect(
        (await platform.getAll()).containsKey('flutter.last_connection_id'),
        isFalse,
      );
      expect(channel.value.validity, WorkspaceEntryValidity.absent);
      expect(channel.value.error, isNotNull);
      platform.failNext = true;
      platform.failRemoval = true;
      expect(
        (await owner.admitWorkspaceEntry('personal').settled).outcome,
        WorkspaceEntrySaveOutcome.failedUnverified,
      );
      expect(channel.value.validity, WorkspaceEntryValidity.unverified);
      final count = platform.writes.length;
      expect(
        (await owner.admitWorkspaceEntry('work').settled).outcome,
        WorkspaceEntrySaveOutcome.failedUnverified,
      );
      expect(platform.writes.length, count);
      platform.failRemoval = false;
      await owner.reload();
      expect(channel.value.validity, WorkspaceEntryValidity.absent);
    },
  );

  test(
    'malformed present value is explicit and fresh reload repairs observation',
    () async {
      await platform.setValue('Int', 'flutter.last_connection_id', 7);
      await owner.reload();
      final channel = owner.workspaceEntry;
      expect(channel.value.validity, WorkspaceEntryValidity.invalid);
      expect((await platform.getAll())['flutter.last_connection_id'], 7);
      expect(platform.writes, [7]);
      expect(
        (await owner.admitWorkspaceEntry('selected').settled).outcome,
        WorkspaceEntrySaveOutcome.saved,
      );
      platform.failRead = true;
      await expectLater(owner.reload(), throwsStateError);
      expect(channel.value.validity, WorkspaceEntryValidity.unverified);
      platform.failRead = false;
      await owner.reload();
      expect(channel.value.validity, WorkspaceEntryValidity.valid);
      expect(channel.value.confirmedId, 'selected');
    },
  );

  test(
    'reentrant settlement admission stays inside the latest drain',
    () async {
      final channel = owner.workspaceEntry;
      var admitted = false;
      channel.addListener(() {
        if (!admitted &&
            !channel.value.busy &&
            channel.value.confirmedId == 'work') {
          admitted = true;
          owner.admitWorkspaceEntry('personal');
        }
      });
      owner.admitWorkspaceEntry('work');
      expect((await owner.settleWorkspaceEntry()).connectionId, 'personal');
      expect(platform.writes, ['work', 'personal']);
      expect(
        (await platform.getAll())['flutter.last_connection_id'],
        'personal',
      );
    },
  );

  test(
    'reentrant retirement rejects unsent choice without general preference rebuild',
    () async {
      var generalChanges = 0;
      owner.state.addListener(() => generalChanges++);
      owner.workspaceEntry.addListener(owner.dispose);
      expect(
        (await owner.admitWorkspaceEntry('work').settled).outcome,
        WorkspaceEntrySaveOutcome.retired,
      );
      expect(platform.writes, isEmpty);
      expect(generalChanges, 0);
    },
  );
}

class _EntryStorage extends InMemorySharedPreferencesStore {
  _EntryStorage() : super.empty();
  final writes = <Object>[];
  String? hold;
  bool failNext = false;
  bool failRemoval = false;
  bool failRead = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<Map<String, Object>> getAll() async {
    if (failRead) {
      throw StateError('Controlled read failure');
    }
    return super.getAll();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.last_connection_id') {
      writes.add(value);
      if (value == hold && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
      if (failNext) {
        failNext = false;
        return false;
      }
    }
    return super.setValue(valueType, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    if (key == 'flutter.last_connection_id' && failRemoval) {
      return false;
    }
    return super.remove(key);
  }
}

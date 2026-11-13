import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/backend_update.dart';
import 'package:wing/core/models/connection.dart';
import 'package:wing/core/services/backend_update_store.dart';

BackendUpdateAttempt attempt(String request) => BackendUpdateAttempt(
  requestId: request,
  installId: 'install',
  installPath: '/opt/hermes',
  home: '/state/default',
  targetSha: '2222222222222222222222222222222222222222',
  startedAt: DateTime.utc(2026, 11, 12),
);

class _Storage extends InMemorySharedPreferencesStore {
  _Storage() : super.empty();
  Completer<void>? write;
  bool rejectSave = false;
  bool rejectRemove = false;

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    await write?.future;
    return rejectSave ? false : super.setValue(type, key, value);
  }

  @override
  Future<bool> remove(String key) async =>
      rejectRemove ? false : super.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Storage platform;
  late BackendUpdateStore store;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    platform = _Storage();
    SharedPreferencesStorePlatform.instance = platform;
    store = BackendUpdateStore(SharedPreferences.getInstance(), 'update-test');
  });

  test('reservation is durable before it becomes observable', () async {
    final held = platform.write = Completer<void>();
    final saving = store.reserve(attempt('first'));
    await Future<void>.delayed(Duration.zero);
    expect(store.current, isNull);
    held.complete();
    expect(await saving, isTrue);
    final fresh = BackendUpdateStore(
      SharedPreferences.getInstance(),
      store.key,
    );
    await fresh.load();
    expect(fresh.current?.requestId, 'first');
    expect(fresh.current?.actionId, isNull);
    await store.accept('first', 'server-action', 41);
    final restarted = BackendUpdateStore(
      SharedPreferences.getInstance(),
      store.key,
    );
    await restarted.load();
    expect(restarted.current?.actionId, 'server-action');
  });

  test(
    'competing reservations and stale writes cannot replace an attempt',
    () async {
      final results = await Future.wait([
        store.reserve(attempt('first')),
        store.reserve(attempt('second')),
      ]);
      expect(results, [true, false]);
      await store.accept('second', 'wrong-action', 99);
      await store.clear('second');
      expect(store.current?.requestId, 'first');
      expect(store.current?.actionId, isNull);
    },
  );

  test('failed saves do not publish a reservation', () async {
    platform.rejectSave = true;
    await expectLater(store.reserve(attempt('first')), throwsStateError);
    expect(store.current, isNull);
    expect(
      (await SharedPreferences.getInstance()).containsKey(store.key),
      isFalse,
    );
  });

  test(
    'failed removal retains the pending marker until retry succeeds',
    () async {
      await store.reserve(attempt('first'));
      await store.accept('first', 'server-action', 41);
      final receipt = BackendUpdateReceipt.fromJson({
        'action_id': 'server-action',
        'pid': 41,
        'outcome': 'success',
        'finished_at': '2026-11-12T09:00:00Z',
      })!;
      platform.rejectRemove = true;
      await expectLater(
        store.clear('first', receipt: receipt),
        throwsStateError,
      );
      expect(store.current?.actionId, 'server-action');
      expect(store.completed, isNull);
      platform.rejectRemove = false;
      await store.clear('first', receipt: receipt);
      expect(store.current, isNull);
      expect(store.completed?.outcome, 'success');
      final restarted = BackendUpdateStore(
        SharedPreferences.getInstance(),
        store.key,
      );
      await restarted.load();
      expect(restarted.current, isNull);
    },
  );

  test('different server keys cannot observe or clear each other', () async {
    await store.reserve(attempt('first'));
    final other = BackendUpdateStore(
      SharedPreferences.getInstance(),
      'other-server',
    );
    await other.load();
    expect(other.current, isNull);
    await other.clear('first');
    expect(store.current?.requestId, 'first');
  });

  test(
    'saved connection identity shares tracking only at the same server origin',
    () async {
      final connection = SavedConnection(
        id: 'tracking-scope-test',
        label: 'Original',
        host: 'claw.example',
        port: 8642,
        dashboardPortOverride: 9120,
        apiKey: '',
      );
      final original = BackendUpdateStore.forConnection(connection);
      await original.reserve(attempt('original'));
      final renamed = BackendUpdateStore.forConnection(
        connection.copyWith(label: 'Renamed'),
      );
      expect(identical(original, renamed), isTrue);
      final moved = BackendUpdateStore.forConnection(
        connection.copyWith(dashboardPortOverride: 9121),
      );
      await moved.load();
      expect(moved.current, isNull);
      expect(original.current?.requestId, 'original');
    },
  );

  test('malformed saved tracking fails rather than being discarded', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(store.key, jsonEncode({'schema': 1}));
    await expectLater(store.load(), throwsFormatException);
    expect(store.loaded, isFalse);
    expect(preferences.containsKey(store.key), isTrue);
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import 'support/browser_mutations_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const identity = 'selection-controller';
  final key =
      'flutter.workspace_profile_selection_v1_${sha256.convert(utf8.encode(identity))}';
  late _ControllerSelectionPlatform platform;
  late SharedPreferences preferences;
  late AppPreferences owner;
  late BrowserMutationsFixture host;
  late ProfileWorkspaceController controller;
  var closed = false;
  setUp(() async {
    SharedPreferences.resetStatic();
    platform = _ControllerSelectionPlatform(key);
    SharedPreferencesStorePlatform.instance = platform;
    preferences = await SharedPreferences.getInstance();
    owner = AppPreferences(preferences);
    host = BrowserMutationsFixture();
    closed = false;
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: SavedConnection(
          id: 'host',
          label: 'Test server',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        dashboardOAuth: null,
      ),
      connectionIdentity: identity,
      preferences: preferences,
      appPreferences: owner,
      gatewayFactory: host.gateway,
    );
  });
  tearDown(() {
    if (!platform.release.isCompleted) platform.release.complete();
    if (!closed) controller.dispose();
    owner.dispose();
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'failed selection write reports restart failure while navigation remains usable',
    () async {
      await controller.initialize();
      expect(controller.current!.scope.profileName, 'personal');
      platform.failWork = true;
      expect(await controller.switchProfile('work'), isTrue);
      expect((await platform.getAll())[key], 'personal');
      expect(controller.current!.scope.profileName, 'work');
      expect(controller.initialized, isTrue);
      expect(host.updates, isEmpty);
      expect(controller.error, contains('restart profile'));
      expect(await controller.switchProfile('work'), isTrue);
      expect((await platform.getAll())[key], 'work');
      expect(controller.error, isNull);
    },
  );

  for (final raw in <Object>['../personal', 7, 'removed-profile']) {
    test(
      'saved $raw requires explicit available selection and resumes initialization',
      () async {
        await platform.setValue(raw is int ? 'Int' : 'String', key, raw);
        await owner.reload();
        platform.writes.clear();
        await controller.initialize();
        expect((await platform.getAll())[key], raw);
        expect(platform.writes, isEmpty);
        expect(controller.current, isNull);
        expect(controller.initialized, isFalse);
        expect(controller.discovery!.named('personal'), isNotNull);
        expect(controller.error, contains('Choose'));
        expect(host.reads.where((row) => row.$1 == 'sessions'), isEmpty);
        expect(host.calls.where((row) => row.$2 == 'session.resume'), isEmpty);
        expect(await controller.switchProfile('work'), isTrue);
        expect((await platform.getAll())[key], 'work');
        expect(controller.current!.scope.profileName, 'work');
        expect(controller.initialized, isTrue);
        expect(controller.error, isNull);
        final count = platform.writes.length;
        await controller.initialize();
        expect(
          platform.writes,
          hasLength(count),
          reason: 'verified selection is not written twice',
        );
      },
    );
  }

  for (final raw in ['../personal', 'removed-profile']) {
    test(
      'failed explicit repair of $raw remains required until durably saved',
      () async {
        await platform.setValue('String', key, raw);
        await owner.reload();
        await controller.initialize();
        expect(controller.initialized, isFalse);
        expect(controller.requiresProfileSelectionRepair, isTrue);
        platform.writes.clear();
        platform.failWork = true;
        expect(await controller.switchProfile('work'), isTrue);
        // Navigation succeeded, but the failed physical save and restoration
        // cannot authorize completing the required startup repair.
        expect(platform.writes, ['work', raw]);
        expect((await platform.getAll())[key], raw);
        expect(controller.current!.scope.profileName, 'work');
        expect(host.updates, isEmpty);
        expect(controller.initialized, isFalse);
        expect(controller.requiresProfileSelectionRepair, isTrue);
        expect(controller.profileSelectionRepairBusy, isFalse);
        expect(controller.error, contains('Choose'));
        expect(await controller.switchProfile('work'), isTrue);
        expect((await platform.getAll())[key], 'work');
        expect(controller.initialized, isTrue);
        expect(controller.requiresProfileSelectionRepair, isFalse);
        expect(controller.error, isNull);
      },
    );
  }

  test('unverified explicit repair requires reload before retry', () async {
    const raw = '../personal';
    await platform.setValue('String', key, raw);
    await owner.reload();
    await controller.initialize();
    platform.writes.clear();
    platform.failWork = true;
    platform.failRollback = true;
    expect(await controller.switchProfile('work'), isTrue);
    expect(platform.writes, ['work', raw]);
    expect((await platform.getAll())[key], raw);
    expect(controller.current!.scope.profileName, 'work');
    expect(controller.initialized, isFalse);
    expect(controller.requiresProfileSelectionRepair, isTrue);
    expect(controller.error, contains('Reload settings'));
    expect(await controller.switchProfile('work'), isTrue);
    expect(platform.writes, ['work', raw]);
    expect(controller.initialized, isFalse);
    await owner.reload();
    expect(controller.requiresProfileSelectionRepair, isTrue);
    expect(await controller.switchProfile('work'), isTrue);
    expect((await platform.getAll())[key], 'work');
    expect(controller.initialized, isTrue);
    expect(controller.requiresProfileSelectionRepair, isFalse);
    expect(host.updates, isEmpty);
  });

  test(
    'newer repair navigation stays available and initializes once after settlement',
    () async {
      await platform.setValue('String', key, 'removed-profile');
      await owner.reload();
      await controller.initialize();
      platform.writes.clear();
      platform.holdWork = true;
      final older = controller.switchProfile('work');
      await platform.entered.future;
      expect(controller.current!.scope.profileName, 'work');
      expect(controller.initialized, isFalse);
      expect(controller.profileSelectionRepairBusy, isTrue);
      expect(await controller.switchProfile('personal'), isTrue);
      expect(controller.current!.scope.profileName, 'personal');
      expect((await platform.getAll())[key], 'removed-profile');
      expect(platform.writes, ['work']);
      expect(controller.initialized, isFalse);
      expect(controller.requiresProfileSelectionRepair, isTrue);
      expect(platform.pendingJournalWrites, 0);
      platform.release.complete();
      expect(await older, isFalse);
      await owner.settleProfileSelection(identity);
      await platform.pendingJournalWritten.future;
      expect(platform.writes, ['work', 'personal']);
      expect((await platform.getAll())[key], 'personal');
      expect(controller.current!.scope.profileName, 'personal');
      expect(controller.initialized, isTrue);
      expect(controller.requiresProfileSelectionRepair, isFalse);
      expect(platform.pendingJournalWrites, 1);
      await controller.initialize();
      expect(platform.pendingJournalWrites, 1);
      expect(host.updates, isEmpty);
    },
  );

  test(
    'borrowed owner finishes admitted latest selection after controller closes',
    () async {
      await controller.initialize();
      platform.holdWork = true;
      final older = controller.switchProfile('work');
      await platform.entered.future;
      expect(await controller.switchProfile('personal'), isTrue);
      controller.dispose();
      closed = true;
      platform.release.complete();
      expect(await older, isFalse);
      await preferences.reload();
      expect((await platform.getAll())[key], 'personal');
      expect(
        preferences.getString(key.substring('flutter.'.length)),
        'personal',
      );
      await owner.setNotificationPreviews(false);
      expect(owner.current.notificationPreviewsAllowed, isFalse);
      expect(host.updates, isEmpty);
    },
  );
}

class _ControllerSelectionPlatform extends InMemorySharedPreferencesStore {
  _ControllerSelectionPlatform(this.key) : super.empty();
  final String key;
  final writes = <Object>[];
  bool failWork = false;
  bool failRollback = false;
  bool _awaitingRollback = false;
  bool holdWork = false;
  int pendingJournalWrites = 0;
  final pendingJournalWritten = Completer<void>();
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.startsWith('flutter.profile_pending_v2_')) {
      pendingJournalWrites++;
      final result = await super.setValue(valueType, key, value);
      if (!pendingJournalWritten.isCompleted) pendingJournalWritten.complete();
      return result;
    }
    if (key == this.key) {
      writes.add(value);
      if (_awaitingRollback) {
        _awaitingRollback = false;
        return false;
      }
      if (holdWork && value == 'work' && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
      if (failWork && value == 'work') {
        failWork = false;
        _awaitingRollback = failRollback;
        failRollback = false;
        return false;
      }
    }
    return super.setValue(valueType, key, value);
  }
}

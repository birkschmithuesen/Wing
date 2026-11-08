import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/models/app_preferences_backup.dart';
import 'package:wing/core/models/session_visibility.dart';
import 'package:wing/core/services/app_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Storage platform;
  late AppPreferences owner;
  late SharedPreferences prefs;
  Future<void> open(Map<String, Object> initial) async {
    SharedPreferences.resetStatic();
    platform = _Storage(initial);
    SharedPreferencesStorePlatform.instance = platform;
    prefs = await SharedPreferences.getInstance();
    owner = AppPreferences(prefs);
  }

  tearDown(() {
    owner.dispose();
    SharedPreferences.setMockInitialValues({});
  });
  AppPreferencesBackupPatch patch(
    Map<AppPreferenceField, Object> fields, [
    Map<String, SessionVisibility> visibility = const {},
  ]) => AppPreferencesBackupPatch(
    explicitlyPresent: fields,
    explicitlyPresentVisibility: visibility,
  );

  test('backup preserves separate GPT-Live choices', () async {
    await open({});
    await owner.setLiveSubscriptionVoice('breeze');
    await owner.setLiveApiVoice('cedar');
    final snapshot = await owner.exportBackupSnapshot(connectionIds: []);
    expect(
      snapshot.explicitlyPresent[AppPreferenceField.liveSubscriptionVoice],
      'breeze',
    );
    expect(
      snapshot.explicitlyPresent[AppPreferenceField.liveApiVoice],
      'cedar',
    );
    await owner.setLiveSubscriptionVoice('cove');
    await owner.restoreBackupPatch(patch(snapshot.explicitlyPresent));
    expect(owner.current.liveSubscriptionVoice.selected, 'breeze');
    expect(owner.current.liveApiVoice.selected, 'cedar');
  });

  test(
    'export observes fresh sparse storage and refuses malformed presence',
    () async {
      await open({'theme_mode': 'dark', 'plugin.cache': 'kept'});
      await platform.replace('theme_mode', 'light');
      final snapshot = await owner.exportBackupSnapshot(
        connectionIds: ['host'],
      );
      expect(snapshot.explicitlyPresent, {AppPreferenceField.theme: 'light'});
      expect(snapshot.explicitlyPresentVisibility, isEmpty);
      expect(platform.writes, isEmpty);
      await platform.replace('theme_mode', 7);
      await expectLater(
        owner.exportBackupSnapshot(connectionIds: ['host']),
        throwsStateError,
      );
      expect(owner.current.values.theme, AppThemePreference.light);
      expect(owner.current.theme.selected, isNull);
      expect(platform.writes, isEmpty);
    },
  );

  test(
    'restore is sparse and repairs only the imported malformed fields',
    () async {
      await open({
        'theme_mode': 7,
        'voice.output': 'invalid',
        'plugin.cache': 'kept',
      });
      final result = await owner.restoreBackupPatch(
        patch(
          {AppPreferenceField.theme: 'dark'},
          {'host': SessionVisibility.all},
        ),
      );
      expect(result.committed, isTrue);
      expect(result.attemptedFields, {AppPreferenceField.theme});
      expect(result.attemptedVisibility, {'host'});
      expect(owner.current.theme.selected, AppThemePreference.dark);
      expect(owner.current.voiceOutput.selected, isNull);
      expect(owner.visibilityFor('host').selected, SessionVisibility.all);
      expect(prefs.get('voice.output'), 'invalid');
      expect(prefs.get('plugin.cache'), 'kept');
      expect(prefs.containsKey('voice.input'), isFalse);
    },
  );

  test(
    'false write rolls back every attempted field including the failed target',
    () async {
      await open({'theme_mode': 'light'});
      platform.failKey = 'flutter.voice.output';
      platform.failValue = 'hermes';
      final result = await owner.restoreBackupPatch(
        patch(
          {
            AppPreferenceField.theme: 'dark',
            AppPreferenceField.voiceOutput: 'hermes',
          },
          {'host': SessionVisibility.all},
        ),
      );
      expect(result.committed, isFalse);
      expect(result.restorationVerified, isTrue);
      expect(result.attemptedFields, {
        AppPreferenceField.theme,
        AppPreferenceField.voiceOutput,
      });
      expect(result.attemptedVisibility, isEmpty);
      expect(platform.writes, [
        'theme_mode=dark',
        'voice.output=hermes',
        'remove:voice.output',
        'theme_mode=light',
      ]);
      expect((await platform.getAll())['flutter.theme_mode'], 'light');
      expect(
        (await platform.getAll()).containsKey('flutter.voice.output'),
        isFalse,
      );
      expect(owner.current.theme.selected, AppThemePreference.light);
    },
  );

  test(
    'failed rollback remains unverified until an actual successful fresh read',
    () async {
      await open({'theme_mode': 'light'});
      platform.failKey = 'flutter.voice.output';
      platform.failValue = 'hermes';
      platform.failRestoration = true;
      final result = await owner.restoreBackupPatch(
        patch({
          AppPreferenceField.theme: 'dark',
          AppPreferenceField.voiceOutput: 'hermes',
        }),
      );
      expect(result.unverifiedFields, {
        AppPreferenceField.theme,
        AppPreferenceField.voiceOutput,
      });
      expect(result.restorationVerified, isFalse);
      expect(owner.current.theme.selected, isNull);
      expect(owner.current.storageVerified, isFalse);
      platform.failRestoration = false;
      await owner.reload();
      expect(owner.current.theme.selected, AppThemePreference.dark);
      expect(owner.current.storageVerified, isTrue);
    },
  );

  test(
    'closed route before held fresh read settles cannot start backup writes',
    () async {
      await open({'theme_mode': 'light'});
      platform.holdRead = true;
      final operation = owner.restoreBackupPatch(
        patch({AppPreferenceField.theme: 'dark'}),
      );
      final rejection = expectLater(operation, throwsStateError);
      await platform.readStarted.future;
      owner.dispose();
      platform.readRelease.complete();
      await rejection;
      expect(platform.writes, isEmpty);
      expect((await platform.getAll())['flutter.theme_mode'], 'light');
    },
  );

  test(
    'failed fresh read starts no writes and preserves current invalid authority',
    () async {
      await open({'theme_mode': 'light'});
      platform.failRead = true;
      await expectLater(
        owner.restoreBackupPatch(patch({AppPreferenceField.theme: 'dark'})),
        throwsStateError,
      );
      expect(platform.writes, isEmpty);
      expect(owner.current.reloadFailed, isTrue);
      expect(owner.current.theme.selected, isNull);
    },
  );

  test(
    'exporting another connection verifies every already observed visibility fact',
    () async {
      await open({'session_visibility_v2_a': 'chats'});
      expect(owner.visibilityFor('a').selected, SessionVisibility.chats);
      platform.partialVisibilityFailure = true;
      await expectLater(
        owner.setConnectionVisibility('a', SessionVisibility.all),
        throwsStateError,
      );
      expect(
        (await platform.getAll())['flutter.session_visibility_v2_a'],
        'all',
      );
      expect(owner.visibilityFor('a').selected, isNull);
      final healthy = <SessionVisibility?>[];
      owner.state.addListener(() {
        final observation = owner.visibilityFor('a');
        if (observation.notice == null) healthy.add(observation.selected);
      });
      final snapshot = await owner.exportBackupSnapshot(connectionIds: ['b']);
      expect(snapshot.explicitlyPresentVisibility, isEmpty);
      expect(owner.visibilityFor('a').selected, SessionVisibility.all);
      expect(healthy, isNotEmpty);
      expect(
        healthy.every((value) => value == SessionVisibility.all),
        isTrue,
        reason:
            'fresh read must not bless an older cached choice for another connection',
      );
    },
  );

  test(
    'visibility has exact absence default and malformed presence requires repair',
    () async {
      await open({'session_visibility_v2_bad': 'automated'});
      expect(owner.visibilityFor('fresh').selected, SessionVisibility.chats);
      expect(owner.visibilityFor('bad').selected, isNull);
      expect(owner.visibilityFor('bad').notice, isNotNull);
      expect(
        owner.current.storageVerified,
        isFalse,
        reason:
            'initial malformed visibility must be current invalid authority',
      );
      expect(platform.writes, isEmpty);
      await owner.setConnectionVisibility('bad', SessionVisibility.all);
      expect(owner.visibilityFor('bad').selected, SessionVisibility.all);
      expect(prefs.get('session_visibility_v2_bad'), 'all');
    },
  );
}

class _Storage extends InMemorySharedPreferencesStore {
  _Storage(Map<String, Object> initial)
    : super.withData({
        for (final entry in initial.entries)
          'flutter.${entry.key}': entry.value,
      });
  final writes = <String>[];
  String? failKey;
  Object? failValue;
  bool failRestoration = false;
  bool partialVisibilityFailure = false;
  bool holdRead = false;
  bool failRead = false;
  final readStarted = Completer<void>();
  final readRelease = Completer<void>();
  Future<bool> replace(String key, Object value) =>
      super.setValue('String', 'flutter.$key', value);
  @override
  Future<Map<String, Object>> getAll() async {
    if (failRead) throw StateError('controlled read failure');
    if (holdRead) {
      holdRead = false;
      readStarted.complete();
      await readRelease.future;
    }
    return super.getAll();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes.add('${key.substring(8)}=$value');
    if (partialVisibilityFailure && key == 'flutter.session_visibility_v2_a') {
      if (value == 'all') await super.setValue(valueType, key, value);
      return false;
    }
    if (key == failKey && value == failValue ||
        failRestoration && value == 'light') {
      return false;
    }
    return super.setValue(valueType, key, value);
  }

  @override
  Future<bool> remove(String key) {
    writes.add('remove:${key.substring(8)}');
    if (failRestoration) return Future.value(false);
    return super.remove(key);
  }
}

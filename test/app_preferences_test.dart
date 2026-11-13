import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/composer_action.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/services/app_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(AppPreferences, SharedPreferences, _HeldPreferences)> open({
    Map<String, Object> initial = const {'composer_running_action': 'steer'},
    bool failHeld = true,
  }) async {
    SharedPreferences.resetStatic();
    final platform = _HeldPreferences(
      throwsError: false,
      initial: initial,
      failHeld: failHeld,
    );
    SharedPreferencesStorePlatform.instance = platform;
    final preferences = await SharedPreferences.getInstance();
    final owner = AppPreferences(preferences);
    addTearDown(() {
      owner.dispose();
      SharedPreferences.setMockInitialValues({});
    });
    return (owner, preferences, platform);
  }

  for (final throwsError in [false, true]) {
    test('a failed earlier save cannot replace a later confirmed setting '
        '(throws: $throwsError)', () async {
      SharedPreferences.resetStatic();
      final platform = _HeldPreferences(throwsError: throwsError);
      SharedPreferencesStorePlatform.instance = platform;
      final preferences = await SharedPreferences.getInstance();
      final owner = AppPreferences(preferences);
      addTearDown(() {
        owner.dispose();
        SharedPreferences.setMockInitialValues({});
      });

      final earlier = owner.setRunningAction(ComposerAction.queue);
      final earlierFailure = expectLater(
        earlier,
        throwsA(isA<AppPreferenceSaveException>()),
      );
      await platform.started.future;
      final later = owner.setRunningAction(ComposerAction.stop);
      await Future<void>.delayed(Duration.zero);
      expect(platform.writes, ['queue']);
      expect(owner.current.values.runningAction, ComposerAction.steer);
      expect(owner.current.storageVerified, isFalse);
      expect(owner.current.pending, {AppPreferenceField.runningAction});

      platform.release.complete();
      await earlierFailure;
      expect(await later, AppPreferenceSaveResult.saved);
      expect(platform.writes, ['queue', 'steer', 'stop']);
      expect(
        (await platform.getAll())[_HeldPreferences.storageKey],
        'stop',
        reason: 'the later choice was actually confirmed by storage',
      );
      expect(
        preferences.getString(AppPreferenceField.runningAction.storageKey),
        'stop',
        reason: 'an older failure must not roll back a confirmed choice',
      );
      expect(owner.current.pending, isEmpty);
      expect(owner.current.storageVerified, isTrue);
      await owner.reload();
      expect(
        preferences.getString(AppPreferenceField.runningAction.storageKey),
        'stop',
      );
    });
  }

  test('successful older and newer choices commit in command order', () async {
    final (owner, preferences, platform) = await open(failHeld: false);
    final earlier = owner.setRunningAction(ComposerAction.queue);
    await platform.started.future;
    final later = owner.setRunningAction(ComposerAction.stop);
    await Future<void>.delayed(Duration.zero);
    expect(platform.writes, ['queue']);
    expect(owner.current.values.runningAction, ComposerAction.steer);
    expect(owner.current.storageVerified, isFalse);
    platform.release.complete();
    expect(await earlier, AppPreferenceSaveResult.saved);
    expect(await later, AppPreferenceSaveResult.saved);
    expect(platform.writes, ['queue', 'stop']);
    await owner.reload();
    expect(owner.current.values.runningAction, ComposerAction.stop);
    expect(
      preferences.getString(AppPreferenceField.runningAction.storageKey),
      'stop',
    );
  });

  test('different fields stay sparse and share the write ordering', () async {
    final (owner, preferences, platform) = await open(
      initial: {
        AppPreferenceField.runningAction.storageKey: 'steer',
        'plugin.cache': 'kept',
      },
      failHeld: false,
    );
    final action = owner.setRunningAction(ComposerAction.queue);
    await platform.started.future;
    final input = owner.setVoiceInput(AppVoiceProcessing.hermes);
    await Future<void>.delayed(Duration.zero);
    expect(platform.writes, ['queue']);
    expect(owner.current.values.voiceInput, AppVoiceProcessing.local);
    platform.release.complete();
    await action;
    await input;
    expect(preferences.getKeys(), {
      AppPreferenceField.runningAction.storageKey,
      'voice.input',
      'plugin.cache',
    });
    expect(owner.current.values.voiceInput, AppVoiceProcessing.hermes);
    expect(owner.current.values.voiceOutput, AppVoiceProcessing.local);
    expect(preferences.get('voice.output'), isNull);
    expect(preferences.get('plugin.cache'), 'kept');
  });

  test(
    'initial invalid fields stay explicit and can be repaired individually',
    () async {
      final (owner, preferences, platform) = await open(
        initial: {
          'theme_mode': 'unknown',
          'voice.output': 'invalid',
          'plugin.cache': 'kept',
        },
      );
      expect(platform.writes, isEmpty);
      expect(owner.current.values.theme, isNull);
      expect(owner.current.values.voiceOutput, isNull);
      expect(owner.current.values.voiceInput, AppVoiceProcessing.local);
      expect(owner.current.issues.map((issue) => issue.field).toSet(), {
        AppPreferenceField.theme,
        AppPreferenceField.voiceOutput,
      });
      expect(owner.current.storageVerified, isFalse);
      await owner.setTheme(AppThemePreference.dark);
      expect(owner.current.values.theme, AppThemePreference.dark);
      expect(owner.current.issues.single.field, AppPreferenceField.voiceOutput);
      expect(preferences.get('voice.output'), 'invalid');
      expect(preferences.get('plugin.cache'), 'kept');
      expect(preferences.containsKey('workspace_accent_v1'), isFalse);
      await owner.setVoiceOutput(AppVoiceProcessing.hermes);
      expect(owner.current.storageVerified, isTrue);
      expect(owner.current.values.voiceOutput, AppVoiceProcessing.hermes);
      expect(platform.writes, ['dark', 'hermes']);
    },
  );

  test(
    'malformed reload retains history while valid observations advance',
    () async {
      final (owner, _, platform) = await open(initial: {'theme_mode': 'dark'});
      await platform.replace('theme_mode', 7);
      await platform.replace('voice.output', 'hermes');
      await owner.reload();
      expect(owner.current.values.theme, AppThemePreference.dark);
      expect(owner.current.values.voiceOutput, AppVoiceProcessing.hermes);
      expect(owner.current.issues.single.field, AppPreferenceField.theme);
      expect(owner.current.isFieldCurrent(AppPreferenceField.theme), isFalse);
      expect(
        owner.current.isFieldCurrent(AppPreferenceField.voiceOutput),
        isTrue,
      );
      expect(owner.current.storageVerified, isFalse);
      expect(platform.writes, isEmpty);
      await owner.setTheme(AppThemePreference.light);
      expect(owner.current.storageVerified, isTrue);
      expect(owner.current.values.theme, AppThemePreference.light);
    },
  );

  test(
    'failed restoration remains unverified until an explicit reload',
    () async {
      final (owner, preferences, platform) = await open();
      platform.failRestoration = true;
      final save = owner.setRunningAction(ComposerAction.queue);
      final failure = expectLater(
        save,
        throwsA(
          isA<AppPreferenceSaveException>().having(
            (e) => e.restored,
            'restored',
            false,
          ),
        ),
      );
      await platform.started.future;
      platform.release.complete();
      await failure;
      expect(owner.current.values.runningAction, ComposerAction.steer);
      expect(owner.current.unverified, {AppPreferenceField.runningAction});
      expect(owner.current.storageVerified, isFalse);
      await expectLater(
        owner.setRunningAction(ComposerAction.stop),
        throwsStateError,
      );
      expect(platform.writes, ['queue', 'steer']);
      platform.failRestoration = false;
      await owner.reload();
      expect(owner.current.storageVerified, isTrue);
      await owner.setRunningAction(ComposerAction.stop);
      await owner.reload();
      expect(
        preferences.getString(AppPreferenceField.runningAction.storageKey),
        'stop',
      );
    },
  );

  test(
    'failed reload cannot authorize writes from an emptied plugin cache',
    () async {
      final (owner, _, platform) = await open(initial: {'theme_mode': 'dark'});
      platform.failReload = true;
      await expectLater(owner.reload(), throwsStateError);
      expect(owner.current.values.theme, AppThemePreference.dark);
      expect(owner.current.reloadFailed, isTrue);
      expect(owner.current.storageVerified, isFalse);
      await expectLater(
        owner.setTheme(AppThemePreference.light),
        throwsStateError,
      );
      expect(platform.writes, isEmpty);
      platform.failReload = false;
      await owner.reload();
      expect(owner.current.storageVerified, isTrue);
      await owner.setTheme(AppThemePreference.light);
      expect(platform.writes, ['light']);
    },
  );

  test(
    'closure keeps dispatched storage work and refuses queued commands',
    () async {
      final (owner, preferences, platform) = await open(failHeld: false);
      final dispatched = owner.setRunningAction(ComposerAction.queue);
      await platform.started.future;
      final queued = owner.setRunningAction(ComposerAction.stop);
      final queuedFailure = expectLater(queued, throwsStateError);
      owner.dispose();
      platform.release.complete();
      expect(await dispatched, AppPreferenceSaveResult.saved);
      await queuedFailure;
      expect(platform.writes, ['queue']);
      await preferences.reload();
      expect(
        preferences.getString(AppPreferenceField.runningAction.storageKey),
        'queue',
      );
      await expectLater(
        owner.setTheme(AppThemePreference.dark),
        throwsStateError,
      );
      expect(platform.writes, ['queue']);
    },
  );

  test(
    'invalid running action has no storage or pending side effect',
    () async {
      final (owner, _, platform) = await open();
      await expectLater(
        owner.setRunningAction(ComposerAction.send),
        throwsArgumentError,
      );
      expect(platform.writes, isEmpty);
      expect(owner.current.pending, isEmpty);
      expect(owner.current.storageVerified, isTrue);
      expect(owner.current.values.runningAction, ComposerAction.steer);
    },
  );

  test(
    'unchanged confirmed choices avoid writes and keep value identity',
    () async {
      final (owner, _, platform) = await open();
      final before = owner.current.values;
      expect(
        await owner.setRunningAction(ComposerAction.steer),
        AppPreferenceSaveResult.unchanged,
      );
      await owner.reload();
      expect(owner.current.values, same(before));
      expect(platform.writes, isEmpty);
    },
  );
}

class _HeldPreferences extends InMemorySharedPreferencesStore {
  _HeldPreferences({
    required this.throwsError,
    Map<String, Object> initial = const {'composer_running_action': 'steer'},
    this.failHeld = true,
  }) : super.withData({
         for (final entry in initial.entries)
           'flutter.${entry.key}': entry.value,
       });

  static const storageKey = 'flutter.composer_running_action';
  final bool throwsError;
  final bool failHeld;
  final started = Completer<void>();
  final release = Completer<void>();
  var held = false;
  final writes = <Object>[];
  bool failRestoration = false;
  bool failReload = false;

  Future<bool> replace(String key, Object value) =>
      super.setValue('String', 'flutter.$key', value);

  @override
  Future<Map<String, Object>> getAll() {
    if (failReload) throw StateError('Controlled reload failure');
    return super.getAll();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes.add(value);
    if (key == storageKey && value == 'queue' && !held) {
      held = true;
      started.complete();
      await release.future;
      if (throwsError) throw StateError('Controlled storage failure');
      if (failHeld) return false;
    }
    if (key == storageKey && value == 'steer' && failRestoration) return false;
    return super.setValue(valueType, key, value);
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/models/composer_action.dart';

void main() {
  test('absent settings use declared product defaults without stored data', () {
    final read = AppPreferencesSchema.read({});
    expect(read.issues, isEmpty);
    final values = read.values;
    expect(values.theme, AppThemePreference.system);
    expect(values.accent, AppAccentPreference.teal);
    expect(values.textSize, AppTextSizePreference.system);
    expect(values.runningAction, ComposerAction.steer);
    expect(values.voiceInput, AppVoiceProcessing.local);
    expect(values.voiceOutput, AppVoiceProcessing.local);
    expect(values.voiceLanguage, '');
    expect(values.voice, '');
    expect(values.voiceRate, AppVoiceRate.normal);
    expect(values.completedNotifications, isTrue);
    expect(values.attentionNotifications, isTrue);
    expect(values.notificationPreviews, isTrue);
  });

  test('canonical fields decode independent voice choices and rates', () {
    final stored = <String, Object>{
      'theme_mode': 'dark',
      'workspace_accent_v1': 'teal',
      'app_text_size_preference': 'extra_large',
      'composer_running_action': 'queue',
      'completion_notifications': false,
      'attention_notifications': true,
      'notification_message_previews': false,
      'voice.input': 'hermes',
      'voice.output': 'local',
      'voice.android_language': 'fr-FR',
      'voice.android_voice': 'currently-unavailable-offline-voice',
      'voice.android_rate': '0.8',
    };
    final read = AppPreferencesSchema.read(stored);
    expect(read.issues, isEmpty);
    final values = read.values;
    expect(values.theme, AppThemePreference.dark);
    expect(values.accent, AppAccentPreference.teal);
    expect(values.textSize, AppTextSizePreference.extraLarge);
    expect(values.textSize!.multiplier, 1.30);
    expect(values.runningAction, ComposerAction.queue);
    expect(values.completedNotifications, isFalse);
    expect(values.attentionNotifications, isTrue);
    expect(values.notificationPreviews, isFalse);
    expect(values.voiceInput, AppVoiceProcessing.hermes);
    expect(values.voiceOutput, AppVoiceProcessing.local);
    expect(values.voiceLanguage, 'fr-FR');
    expect(values.voiceRate, AppVoiceRate.slower);
    expect(values.voiceRate!.multiplier, .8);
    expect(values.voice, 'currently-unavailable-offline-voice');
  });

  test('invalid present settings never become fresh-install defaults', () {
    final invalid = <String, Object?>{
      'theme_mode': null,
      'workspace_accent_v1': 'mint',
      'app_text_size_preference': 1.15,
      'composer_running_action': 'send',
      'completion_notifications': 'false',
      'voice.input': 'automatic',
      'voice.android_voice': true,
      'voice.android_rate': 1.0,
    };
    final read = AppPreferencesSchema.read(invalid);
    expect(read.values.theme, isNull);
    expect(read.values.accent, isNull);
    expect(read.values.textSize, isNull);
    expect(read.values.runningAction, isNull);
    expect(read.values.completedNotifications, isNull);
    expect(read.values.voiceInput, isNull);
    expect(read.values.voice, isNull);
    expect(read.values.voiceRate, isNull);
    expect(read.values.voiceOutput, AppVoiceProcessing.local);
    expect(read.issues.map((issue) => issue.field.storageKey).toSet(), {
      ...invalid.keys,
    });
    expect(invalid['workspace_accent_v1'], 'mint');
  });

  test('unowned storage is outside the canonical portable catalog', () {
    final read = AppPreferencesSchema.read({
      'verbose_mode': true,
      'connection_visibility.host': 'all',
      'profile_color_v1_identity_work': 8,
      'chat_notification_state': 'opaque journal',
    });
    expect(read.issues, isEmpty);
    expect(read.values, AppPreferencesSchema.read({}).values);
    expect(
      AppPreferenceField.values.map((field) => field.storageKey).toSet(),
      hasLength(15),
    );
    expect(
      AppPreferenceField.values.map((field) => field.storageKey).toSet(),
      isNot(contains('verbose_mode')),
    );
    expect(
      AppPreferencesSnapshot.freshInstall().toStorage().keys.toSet(),
      AppPreferenceField.values.map((field) => field.storageKey).toSet(),
    );
  });

  test('fresh default serialization remains immutable and detached', () {
    final snapshot = AppPreferencesSnapshot.freshInstall();
    final stored = snapshot.toStorage();
    expect(stored, {
      'theme_mode': 'system',
      'workspace_accent_v1': 'teal',
      'app_text_size_preference': 'system',
      'composer_running_action': 'steer',
      'completion_notifications': true,
      'attention_notifications': true,
      'notification_message_previews': true,
      'voice.live_mode': 'subscription',
      'voice.live_subscription_voice': 'cove',
      'voice.live_api_voice': 'marin',
      'voice.input': 'local',
      'voice.output': 'local',
      'voice.android_language': '',
      'voice.android_voice': '',
      'voice.android_rate': '1.0',
    });
    expect(() => stored['theme_mode'] = 'dark', throwsUnsupportedError);
    expect(snapshot.theme, AppThemePreference.system);
    final invalid = AppPreferencesSchema.read({'voice.output': 'unknown'});
    expect(() => invalid.issues.clear(), throwsUnsupportedError);
  });

  test('equivalent observations agree without losing independent choices', () {
    final original = AppPreferencesSchema.read({}).values;
    final stored = AppPreferencesSnapshot.freshInstall().toStorage();
    final same = AppPreferencesSchema.read(stored).values;
    expect(same, original);
    expect(same.hashCode, original.hashCode);
    final changed = AppPreferencesSchema.read({
      ...stored,
      'voice.output': 'hermes',
    }).values;
    expect(changed, isNot(original));
    expect(changed.voiceInput, original.voiceInput);
  });

  test('retained facts keep current invalidity separate from prior values', () {
    final previous = AppPreferencesSchema.read({
      'theme_mode': 'dark',
      'voice.output': 'hermes',
    }).values;
    final current = AppPreferencesSchema.read({
      'theme_mode': 'unknown',
      'voice.output': 'local',
    });
    final retained = AppPreferencesSchema.retainKnownValues(current, previous);
    expect(retained.theme, AppThemePreference.dark);
    expect(retained.voiceOutput, AppVoiceProcessing.local);
    expect(current.values.theme, isNull);
    expect(current.issues.single.field, AppPreferenceField.theme);
    expect(
      retained,
      AppPreferencesSchema.read({
        'theme_mode': 'dark',
        'voice.output': 'local',
      }).values,
    );
  });
}

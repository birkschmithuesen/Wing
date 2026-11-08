import 'composer_action.dart';

enum AppThemePreference { system, light, dark }

enum AppAccentPreference { teal, iris, glacier, coral, gold }

enum AppTextSizePreference {
  system('system', 1),
  small('small', .90),
  standard('default', 1),
  large('large', 1.15),
  extraLarge('extra_large', 1.30);

  const AppTextSizePreference(this.storageValue, this.multiplier);
  final String storageValue;
  final double multiplier;
}

enum AppVoiceProcessing { local, hermes }

enum LiveVoiceMode {
  subscription([
    'arbor',
    'breeze',
    'cove',
    'ember',
    'juniper',
    'maple',
    'sol',
    'spruce',
    'vale',
  ]),
  api([
    'marin',
    'cedar',
    'quartz',
    'ripple',
    'vesper',
    'willow',
    'stone',
    'gleam',
    'meridian',
    'bossa',
    'tempo',
    'beacon',
    'delta',
    'cinder',
  ]);

  const LiveVoiceMode(this.voices);

  /// Offered built-in voices; provider availability is checked at call startup.
  final List<String> voices;
}

enum AppVoiceRate {
  slower('0.8', .8),
  normal('1.0', 1),
  faster('1.2', 1.2);

  const AppVoiceRate(this.storageValue, this.multiplier);
  final String storageValue;
  final double multiplier;
}

/// Exact device-owned settings. Credentials, journals, browser arrangements,
/// profile colors and connection visibility belong to their existing owners.
enum AppPreferenceField {
  theme('theme_mode'),
  accent('workspace_accent_v1'),
  textSize('app_text_size_preference'),
  runningAction('composer_running_action'),
  completedNotifications('completion_notifications'),
  attentionNotifications('attention_notifications'),
  notificationPreviews('notification_message_previews'),
  liveVoiceMode('voice.live_mode'),
  liveSubscriptionVoice('voice.live_subscription_voice'),
  liveApiVoice('voice.live_api_voice'),
  voiceInput('voice.input'),
  voiceOutput('voice.output'),
  voiceLanguage('voice.android_language'),
  voice('voice.android_voice'),
  voiceRate('voice.android_rate');

  const AppPreferenceField(this.storageKey);
  final String storageKey;
}

class AppPreferencesSnapshot {
  AppPreferencesSnapshot({
    required this.theme,
    required this.accent,
    required this.textSize,
    required this.runningAction,
    required this.completedNotifications,
    required this.attentionNotifications,
    required this.notificationPreviews,
    required this.liveVoiceMode,
    required this.liveSubscriptionVoice,
    required this.liveApiVoice,
    required this.voiceInput,
    required this.voiceOutput,
    required this.voiceLanguage,
    required this.voice,
    required this.voiceRate,
  });

  final AppThemePreference theme;
  final AppAccentPreference accent;
  final AppTextSizePreference textSize;
  final ComposerAction runningAction;
  final bool completedNotifications;
  final bool attentionNotifications;
  final bool notificationPreviews;
  final LiveVoiceMode liveVoiceMode;
  final String liveSubscriptionVoice;
  final String liveApiVoice;
  final AppVoiceProcessing voiceInput;
  final AppVoiceProcessing voiceOutput;
  final String voiceLanguage;
  final String voice;
  final AppVoiceRate voiceRate;

  /// Product defaults apply only to absent settings, never malformed values.
  factory AppPreferencesSnapshot.freshInstall() => AppPreferencesSnapshot(
    theme: AppThemePreference.system,
    accent: AppAccentPreference.teal,
    textSize: AppTextSizePreference.system,
    runningAction: ComposerAction.steer,
    completedNotifications: true,
    attentionNotifications: true,
    notificationPreviews: true,
    liveVoiceMode: LiveVoiceMode.subscription,
    liveSubscriptionVoice: 'cove',
    liveApiVoice: 'marin',
    voiceInput: AppVoiceProcessing.local,
    voiceOutput: AppVoiceProcessing.local,
    voiceLanguage: '',
    voice: '',
    voiceRate: AppVoiceRate.normal,
  );

  Map<String, Object> toStorage() => Map.unmodifiable({
    AppPreferenceField.theme.storageKey: theme.name,
    AppPreferenceField.accent.storageKey: accent.name,
    AppPreferenceField.textSize.storageKey: textSize.storageValue,
    AppPreferenceField.runningAction.storageKey: runningAction.name,
    AppPreferenceField.completedNotifications.storageKey:
        completedNotifications,
    AppPreferenceField.attentionNotifications.storageKey:
        attentionNotifications,
    AppPreferenceField.notificationPreviews.storageKey: notificationPreviews,
    AppPreferenceField.liveVoiceMode.storageKey: liveVoiceMode.name,
    AppPreferenceField.liveSubscriptionVoice.storageKey: liveSubscriptionVoice,
    AppPreferenceField.liveApiVoice.storageKey: liveApiVoice,
    AppPreferenceField.voiceInput.storageKey: voiceInput.name,
    AppPreferenceField.voiceOutput.storageKey: voiceOutput.name,
    AppPreferenceField.voiceLanguage.storageKey: voiceLanguage,
    AppPreferenceField.voice.storageKey: voice,
    AppPreferenceField.voiceRate.storageKey: voiceRate.storageValue,
  });
}

class AppPreferenceIssue {
  const AppPreferenceIssue(this.field);
  final AppPreferenceField field;
}

class AppPreferencesRead {
  AppPreferencesRead._(this.values, Iterable<AppPreferenceIssue> issues)
    : issues = List.unmodifiable(issues);

  final AppPreferencesValues values;
  final List<AppPreferenceIssue> issues;
}

/// Typed per-field observations permit explicit repair when only some stored
/// settings are valid. Unknown fields remain null, without guessed selections.
class AppPreferencesValues {
  AppPreferencesValues._(Map<AppPreferenceField, Object> values)
    : _values = Map.unmodifiable(values);

  final Map<AppPreferenceField, Object> _values;

  T? _named<T extends Enum>(AppPreferenceField field, List<T> choices) {
    final value = _values[field];
    return value == null
        ? null
        : choices.singleWhere((choice) => choice.name == value);
  }

  AppThemePreference? get theme =>
      _named(AppPreferenceField.theme, AppThemePreference.values);
  AppAccentPreference? get accent =>
      _named(AppPreferenceField.accent, AppAccentPreference.values);
  AppTextSizePreference? get textSize {
    final value = _values[AppPreferenceField.textSize];
    return value == null
        ? null
        : AppTextSizePreference.values.singleWhere(
            (choice) => choice.storageValue == value,
          );
  }

  ComposerAction? get runningAction =>
      _named(AppPreferenceField.runningAction, ComposerAction.runningDefaults);
  bool? get completedNotifications =>
      _values[AppPreferenceField.completedNotifications] as bool?;
  bool? get attentionNotifications =>
      _values[AppPreferenceField.attentionNotifications] as bool?;
  bool? get notificationPreviews =>
      _values[AppPreferenceField.notificationPreviews] as bool?;
  LiveVoiceMode? get liveVoiceMode =>
      _named(AppPreferenceField.liveVoiceMode, LiveVoiceMode.values);
  String? get liveSubscriptionVoice =>
      _values[AppPreferenceField.liveSubscriptionVoice] as String?;
  String? get liveApiVoice =>
      _values[AppPreferenceField.liveApiVoice] as String?;
  AppVoiceProcessing? get voiceInput =>
      _named(AppPreferenceField.voiceInput, AppVoiceProcessing.values);
  AppVoiceProcessing? get voiceOutput =>
      _named(AppPreferenceField.voiceOutput, AppVoiceProcessing.values);
  String? get voiceLanguage =>
      _values[AppPreferenceField.voiceLanguage] as String?;
  String? get voice => _values[AppPreferenceField.voice] as String?;
  AppVoiceRate? get voiceRate {
    final value = _values[AppPreferenceField.voiceRate];
    return value == null
        ? null
        : AppVoiceRate.values.singleWhere(
            (choice) => choice.storageValue == value,
          );
  }

  @override
  bool operator ==(Object other) =>
      other is AppPreferencesValues &&
      AppPreferenceField.values.every(
        (field) => _values[field] == other._values[field],
      );

  @override
  int get hashCode =>
      Object.hashAll(AppPreferenceField.values.map((field) => _values[field]));
}

/// The canonical schema is shared by device reads, saves and portable backup
/// selection. Present invalid data is explicit; no aliases or coercions exist.
class AppPreferencesSchema {
  static bool accepts(AppPreferenceField field, Object? value) =>
      switch (field) {
        AppPreferenceField.theme => AppThemePreference.values.any(
          (choice) => choice.name == value,
        ),
        AppPreferenceField.accent => AppAccentPreference.values.any(
          (choice) => choice.name == value,
        ),
        AppPreferenceField.textSize => AppTextSizePreference.values.any(
          (choice) => choice.storageValue == value,
        ),
        AppPreferenceField.runningAction => ComposerAction.runningDefaults.any(
          (choice) => choice.name == value,
        ),
        AppPreferenceField.completedNotifications ||
        AppPreferenceField.attentionNotifications ||
        AppPreferenceField.notificationPreviews => value is bool,
        AppPreferenceField.liveVoiceMode => LiveVoiceMode.values.any(
          (choice) => choice.name == value,
        ),
        AppPreferenceField.liveSubscriptionVoice =>
          LiveVoiceMode.subscription.voices.contains(value),
        AppPreferenceField.liveApiVoice => LiveVoiceMode.api.voices.contains(
          value,
        ),
        AppPreferenceField.voiceInput || AppPreferenceField.voiceOutput =>
          AppVoiceProcessing.values.any((choice) => choice.name == value),
        AppPreferenceField.voiceLanguage ||
        AppPreferenceField.voice => value is String,
        AppPreferenceField.voiceRate => AppVoiceRate.values.any(
          (choice) => choice.storageValue == value,
        ),
      };

  static AppPreferencesRead read(Map<String, Object?> stored) {
    final defaults = AppPreferencesSnapshot.freshInstall().toStorage();
    final values = <AppPreferenceField, Object>{};
    final issues = <AppPreferenceIssue>[];
    for (final field in AppPreferenceField.values) {
      final value = stored.containsKey(field.storageKey)
          ? stored[field.storageKey]
          : defaults[field.storageKey];
      if (!accepts(field, value)) {
        issues.add(AppPreferenceIssue(field));
      } else {
        values[field] = value!;
      }
    }
    return AppPreferencesRead._(AppPreferencesValues._(values), issues);
  }

  /// Retention is display history, not validation of the current stored data.
  /// Initial invalid values have no prior observation to retain.
  static AppPreferencesValues retainKnownValues(
    AppPreferencesRead current,
    AppPreferencesValues? previous,
  ) => AppPreferencesValues._({
    for (final issue in current.issues)
      if (previous?._values[issue.field] case final Object value)
        issue.field: value,
    ...current.values._values,
  });
}

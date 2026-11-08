import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_preferences.dart';
import '../models/profile_colors.dart';
import '../models/profile_selection.dart';
import '../models/hermes_profile.dart';
import '../models/app_preferences_backup.dart';
import '../models/session_visibility.dart';
import '../models/composer_action.dart';
import '../models/voice_processing_settings.dart';
import '../models/chat_browser_preferences.dart';
import '../models/workspace_entry.dart';

part 'app_preferences_profile_colors.dart';
part 'app_preferences_profile_selection.dart';
part 'app_preferences_browser_preferences.dart';
part 'app_preferences_workspace_entry.dart';

enum AppPreferenceSaveResult { unchanged, saved }

enum AppPreferenceStorageFailure { saveFailed, restorationUnconfirmed }

class AppPreferenceSaveException implements Exception {
  const AppPreferenceSaveException({required this.restored});
  final bool restored;

  @override
  String toString() => restored
      ? 'The app setting could not be saved. Retry the choice.'
      : 'The app setting could not be saved or verified. Reload settings.';
}

/// Passive controls share the owner of confirmed facts and writes. A route
/// renders these facts and invokes choices without retaining another cache.
class AppPreferenceControl<T> {
  const AppPreferenceControl({
    required this.selected,
    required this.busy,
    required this.notice,
    required this.error,
    required this.choose,
  });

  final T? selected;
  final bool busy;
  final String? notice;
  final String? error;
  final Future<bool> Function(T)? choose;
}

class AppPreferencesReloadControl {
  const AppPreferencesReloadControl({
    required this.visible,
    required this.busy,
    required this.error,
    required this.invoke,
  });
  final bool visible;
  final bool busy;
  final String? error;
  final Future<bool> Function()? invoke;
}

class AppPreferencesState {
  AppPreferencesState({
    required this.values,
    required Iterable<AppPreferenceIssue> issues,
    required Iterable<AppPreferenceField> pending,
    required Map<AppPreferenceField, AppPreferenceStorageFailure> failures,
    required Iterable<AppPreferenceField> unverified,
    required this.reloadFailed,
    required this.visibilityStorageVerified,
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
    required this.reloadControl,
  }) : issues = List.unmodifiable(issues),
       pending = Set.unmodifiable(pending),
       failures = Map.unmodifiable(failures),
       unverified = Set.unmodifiable(unverified);

  /// Last confirmed per-field facts. Invalid initial fields remain null;
  /// malformed later reads can retain prior facts with explicit current issues.
  final AppPreferencesValues values;
  final List<AppPreferenceIssue> issues;
  final Set<AppPreferenceField> pending;
  final Map<AppPreferenceField, AppPreferenceStorageFailure> failures;
  final Set<AppPreferenceField> unverified;
  final bool reloadFailed;
  final bool visibilityStorageVerified;
  final AppPreferenceControl<AppThemePreference> theme;
  final AppPreferenceControl<AppAccentPreference> accent;
  final AppPreferenceControl<AppTextSizePreference> textSize;
  final AppPreferenceControl<ComposerAction> runningAction;
  final AppPreferenceControl<bool> completedNotifications;
  final AppPreferenceControl<bool> attentionNotifications;
  final AppPreferenceControl<bool> notificationPreviews;
  final AppPreferenceControl<LiveVoiceMode> liveVoiceMode;
  final AppPreferenceControl<String> liveSubscriptionVoice;
  final AppPreferenceControl<String> liveApiVoice;

  AppPreferenceControl<String> liveVoiceFor(LiveVoiceMode mode) =>
      switch (mode) {
        LiveVoiceMode.subscription => liveSubscriptionVoice,
        LiveVoiceMode.api => liveApiVoice,
      };
  final AppPreferenceControl<AppVoiceProcessing> voiceInput;
  final AppPreferenceControl<AppVoiceProcessing> voiceOutput;
  final AppPreferenceControl<String> voiceLanguage;
  final AppPreferenceControl<String> voice;
  final AppPreferenceControl<AppVoiceRate> voiceRate;
  final AppPreferencesReloadControl reloadControl;

  bool isFieldCurrent(AppPreferenceField field) =>
      !reloadFailed &&
      !unverified.contains(field) &&
      !issues.any((issue) => issue.field == field);

  bool get completedNotificationsAllowed =>
      isFieldCurrent(AppPreferenceField.completedNotifications) &&
      values.completedNotifications == true;
  bool get attentionNotificationsAllowed =>
      isFieldCurrent(AppPreferenceField.attentionNotifications) &&
      values.attentionNotifications == true;
  bool get notificationPreviewsAllowed =>
      isFieldCurrent(AppPreferenceField.notificationPreviews) &&
      values.notificationPreviews == true;
  ComposerAction? get preferredRunningAction =>
      isFieldCurrent(AppPreferenceField.runningAction)
      ? values.runningAction
      : null;

  VoiceInputSettings? get voiceInputSettings {
    if (!isFieldCurrent(AppPreferenceField.voiceInput)) return null;
    return switch (values.voiceInput) {
      AppVoiceProcessing.local =>
        isFieldCurrent(AppPreferenceField.voiceLanguage)
            ? LocalVoiceInputSettings(language: values.voiceLanguage!)
            : null,
      AppVoiceProcessing.hermes => const HermesVoiceInputSettings(),
      null => null,
    };
  }

  LocalVoiceOutputSettings? get localVoiceOutputSettings =>
      isFieldCurrent(AppPreferenceField.voice) &&
          isFieldCurrent(AppPreferenceField.voiceRate)
      ? LocalVoiceOutputSettings(voice: values.voice!, rate: values.voiceRate!)
      : null;

  VoiceOutputSettings? get voiceOutputSettings {
    if (!isFieldCurrent(AppPreferenceField.voiceOutput)) return null;
    return switch (values.voiceOutput) {
      AppVoiceProcessing.local => localVoiceOutputSettings,
      AppVoiceProcessing.hermes => const HermesVoiceOutputSettings(),
      null => null,
    };
  }

  bool get needsAppearanceRepair =>
      reloadFailed ||
      [
        AppPreferenceField.theme,
        AppPreferenceField.accent,
        AppPreferenceField.textSize,
      ].any(
        (field) =>
            unverified.contains(field) ||
            issues.any((issue) => issue.field == field),
      );

  /// Retained display facts are never proof that current storage is valid.
  bool get storageVerified =>
      issues.isEmpty &&
      unverified.isEmpty &&
      pending.isEmpty &&
      !reloadFailed &&
      !reloadControl.busy &&
      visibilityStorageVerified;
}

/// One injected owner for device settings. All feature callers and backup
/// imports share this instance; route closure never constructs another cache.
/// Writes and reloads are ordered, including a failed write's restoration.
class AppPreferences {
  AppPreferences(SharedPreferences preferences) : _preferences = preferences {
    final read = _read();
    _issues = read.issues;
    _values = read.values;
    _presentation = ValueNotifier(_state());
  }

  final SharedPreferences _preferences;
  late List<AppPreferenceIssue> _issues;
  late AppPreferencesValues _values;
  late final ValueNotifier<AppPreferencesState> _presentation;
  final _pending = <AppPreferenceField, int>{};
  final _failures = <AppPreferenceField, AppPreferenceStorageFailure>{};
  final _unverified = <AppPreferenceField>{};
  final _visibilityValues = <String, SessionVisibility?>{};
  final _visibilityInvalid = <String>{};
  final _visibilityPending = <String, int>{};
  final _visibilityFailures = <String, AppPreferenceStorageFailure>{};
  final _visibilityUnverified = <String>{};
  _ProfileColorPreferences? _profileColors;
  _ProfileSelectionPreferences? _profileSelections;
  _BrowserPreferences? _browserPreferences;
  _WorkspaceEntryPreferences? _workspaceEntry;
  Future<void>? _tail;
  bool _reloadFailed = false;
  bool _closed = false;
  int _reloadRequests = 0;

  ValueListenable<AppPreferencesState> get state => _presentation;
  AppPreferencesState get current => _presentation.value;

  Future<AppPreferenceSaveResult> setTheme(AppThemePreference value) =>
      _save(AppPreferenceField.theme, value.name);
  Future<AppPreferenceSaveResult> setAccent(AppAccentPreference value) =>
      _save(AppPreferenceField.accent, value.name);
  Future<AppPreferenceSaveResult> setTextSize(AppTextSizePreference value) =>
      _save(AppPreferenceField.textSize, value.storageValue);
  Future<AppPreferenceSaveResult> setRunningAction(ComposerAction value) =>
      _save(AppPreferenceField.runningAction, value.name);
  Future<AppPreferenceSaveResult> setCompletedNotifications(bool value) =>
      _save(AppPreferenceField.completedNotifications, value);
  Future<AppPreferenceSaveResult> setAttentionNotifications(bool value) =>
      _save(AppPreferenceField.attentionNotifications, value);
  Future<AppPreferenceSaveResult> setNotificationPreviews(bool value) =>
      _save(AppPreferenceField.notificationPreviews, value);
  Future<AppPreferenceSaveResult> setLiveVoiceMode(LiveVoiceMode value) =>
      _save(AppPreferenceField.liveVoiceMode, value.name);
  Future<AppPreferenceSaveResult> setLiveSubscriptionVoice(String value) =>
      _save(AppPreferenceField.liveSubscriptionVoice, value);
  Future<AppPreferenceSaveResult> setLiveApiVoice(String value) =>
      _save(AppPreferenceField.liveApiVoice, value);
  Future<AppPreferenceSaveResult> setVoiceInput(AppVoiceProcessing value) =>
      _save(AppPreferenceField.voiceInput, value.name);
  Future<AppPreferenceSaveResult> setVoiceOutput(AppVoiceProcessing value) =>
      _save(AppPreferenceField.voiceOutput, value.name);
  Future<AppPreferenceSaveResult> setVoiceLanguage(String value) =>
      _save(AppPreferenceField.voiceLanguage, value);
  Future<AppPreferenceSaveResult> setVoice(String value) =>
      _save(AppPreferenceField.voice, value);
  Future<AppPreferenceSaveResult> setVoiceRate(AppVoiceRate value) =>
      _save(AppPreferenceField.voiceRate, value.storageValue);

  AppPreferencesRead _read() => AppPreferencesSchema.read({
    for (final field in AppPreferenceField.values)
      if (_preferences.containsKey(field.storageKey))
        field.storageKey: _preferences.get(field.storageKey),
  });

  AppPreferencesState _state() => AppPreferencesState(
    values: _values,
    issues: _issues,
    pending: _pending.keys,
    failures: _failures,
    unverified: _unverified,
    reloadFailed: _reloadFailed,
    visibilityStorageVerified:
        _visibilityInvalid.isEmpty &&
        _visibilityUnverified.isEmpty &&
        _visibilityPending.isEmpty,
    theme: _control(AppPreferenceField.theme, _values.theme, setTheme),
    accent: _control(AppPreferenceField.accent, _values.accent, setAccent),
    textSize: _control(
      AppPreferenceField.textSize,
      _values.textSize,
      setTextSize,
    ),
    runningAction: _control(
      AppPreferenceField.runningAction,
      _values.runningAction,
      setRunningAction,
    ),
    completedNotifications: _control(
      AppPreferenceField.completedNotifications,
      _values.completedNotifications,
      setCompletedNotifications,
    ),
    attentionNotifications: _control(
      AppPreferenceField.attentionNotifications,
      _values.attentionNotifications,
      setAttentionNotifications,
    ),
    notificationPreviews: _control(
      AppPreferenceField.notificationPreviews,
      _values.notificationPreviews,
      setNotificationPreviews,
    ),
    liveVoiceMode: _control(
      AppPreferenceField.liveVoiceMode,
      _values.liveVoiceMode,
      setLiveVoiceMode,
    ),
    liveSubscriptionVoice: _control(
      AppPreferenceField.liveSubscriptionVoice,
      _values.liveSubscriptionVoice,
      setLiveSubscriptionVoice,
    ),
    liveApiVoice: _control(
      AppPreferenceField.liveApiVoice,
      _values.liveApiVoice,
      setLiveApiVoice,
    ),
    voiceInput: _control(
      AppPreferenceField.voiceInput,
      _values.voiceInput,
      setVoiceInput,
    ),
    voiceOutput: _control(
      AppPreferenceField.voiceOutput,
      _values.voiceOutput,
      setVoiceOutput,
    ),
    voiceLanguage: _control(
      AppPreferenceField.voiceLanguage,
      _values.voiceLanguage,
      setVoiceLanguage,
    ),
    voice: _control(AppPreferenceField.voice, _values.voice, setVoice),
    voiceRate: _control(
      AppPreferenceField.voiceRate,
      _values.voiceRate,
      setVoiceRate,
    ),
    reloadControl: AppPreferencesReloadControl(
      visible:
          _reloadFailed ||
          _unverified.isNotEmpty ||
          _visibilityUnverified.isNotEmpty ||
          _reloadRequests > 0,
      busy: _reloadRequests > 0,
      error: _reloadFailed ? 'Could not reload settings. Please retry.' : null,
      invoke:
          _closed ||
              _reloadRequests > 0 ||
              _pending.isNotEmpty ||
              _visibilityPending.isNotEmpty
          ? null
          : () async {
              try {
                await reload();
                return true;
              } catch (_) {
                return false;
              }
            },
    ),
  );

  AppPreferenceControl<T> _control<T>(
    AppPreferenceField field,
    T? observed,
    Future<AppPreferenceSaveResult> Function(T) save,
  ) {
    final invalid = _issues.any((issue) => issue.field == field);
    final unverified = _unverified.contains(field) || _reloadFailed;
    final busy = _pending.containsKey(field);
    return AppPreferenceControl(
      selected: invalid || unverified ? null : observed,
      busy: busy,
      notice: unverified
          ? 'Reload settings to verify this choice.'
          : invalid
          ? 'The saved setting is invalid. Choose a value to repair it.'
          : null,
      error: switch (_failures[field]) {
        AppPreferenceStorageFailure.saveFailed => switch (field) {
          AppPreferenceField.runningAction =>
            'Could not save the default action. Please retry.',
          AppPreferenceField.textSize =>
            'Could not save the text size. Please retry.',
          AppPreferenceField.liveVoiceMode ||
          AppPreferenceField.liveSubscriptionVoice ||
          AppPreferenceField.liveApiVoice ||
          AppPreferenceField.voiceInput ||
          AppPreferenceField.voiceOutput ||
          AppPreferenceField.voiceLanguage ||
          AppPreferenceField.voice ||
          AppPreferenceField.voiceRate =>
            'Could not save this voice setting. Please retry.',
          _ => 'Could not save the setting. Please retry.',
        },
        AppPreferenceStorageFailure.restorationUnconfirmed =>
          'Could not verify the saved setting. Reload settings.',
        null => null,
      },
      choose: busy || unverified || _closed || _reloadRequests > 0
          ? null
          : (value) async {
              // Failures are published by this owner, including routes that
              // close while the command is settling.
              try {
                await save(value);
                return true;
              } catch (_) {
                return false;
              }
            },
    );
  }

  void _publish() {
    if (!_closed) _presentation.value = _state();
    _profileColors?.publish();
    _profileSelections?.publish();
    _browserPreferences?.publish();
    _workspaceEntry?.publish();
  }

  _ProfileColorPreferences get _colors {
    if (_closed) throw StateError('App settings are closed');
    return _profileColors ??= _ProfileColorPreferences(this);
  }

  ValueListenable<ProfileColorsState> profileColorsFor(String identity) =>
      _colors.channel(identity);

  bool observeProfileColor(String identity, String name) {
    if (_closed) return false;
    _colors.observe(identity, name);
    _colors.publish();
    return !_closed;
  }

  Future<void> setProfileColor(
    String identity,
    String name,
    ProfileColorChoice choice, {
    required bool Function() canWrite,
  }) => _colors.choose(identity, name, choice, canWrite: canWrite);

  _ProfileSelectionPreferences get _selections {
    if (_closed) throw StateError('App settings are closed');
    return _profileSelections ??= _ProfileSelectionPreferences(this);
  }

  ValueListenable<ProfileSelectionFact> profileSelectionFor(String identity) =>
      _selections.channel(identity);

  String initialProfileSelection(
    String identity, {
    required Iterable<String> availableNames,
    required String preferredName,
  }) => _selections.initial(identity, availableNames, preferredName);

  ProfileSelectionAdmission admitProfileSelection(
    String identity,
    String name,
  ) => _selections.admit(identity, name);

  Future<ProfileSelectionSettlement> settleProfileSelection(String identity) =>
      _selections.settle(identity);

  _BrowserPreferences get _browser {
    if (_closed) throw StateError('App settings are closed');
    return _browserPreferences ??= _BrowserPreferences(this);
  }

  ValueListenable<BrowserPreferencesFact> browserPreferencesFor(
    String identity,
  ) => _browser.channel(identity);

  Future<BrowserPreferencesSaveOutcome> chooseBrowserPreferences(
    String identity,
    BrowserPreferenceIntent intent,
  ) {
    if (_closed) return Future.value(BrowserPreferencesSaveOutcome.retired);
    return _browser.choose(identity, intent);
  }

  _WorkspaceEntryPreferences get _entry {
    if (_closed) throw StateError('App settings are closed');
    return _workspaceEntry ??= _WorkspaceEntryPreferences(this);
  }

  ValueListenable<WorkspaceEntryFact> get workspaceEntry => _entry.channel;

  WorkspaceEntryAdmission admitWorkspaceEntry(String connectionId) =>
      _entry.admit(connectionId);

  Future<WorkspaceEntrySettlement> settleWorkspaceEntry() => _entry.settle();

  void _observe() {
    final read = _read();
    final values = AppPreferencesSchema.retainKnownValues(read, _values);
    _values = values == _values ? _values : values;
    _issues = read.issues;
    _profileColors?.observeAll();
    _profileSelections?.observeAll();
    _browserPreferences?.observeAll();
    _workspaceEntry?.observe();
    for (final id in _visibilityValues.keys.toList()) {
      _observeVisibility(id);
    }
    _publish();
  }

  Future<T> _ordered<T>(Future<T> Function() operation) {
    final previous = _tail;
    final result = previous == null
        ? Future<T>.microtask(operation)
        : previous.then((_) => operation());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _tail = tail;
    tail.then((_) {
      if (identical(_tail, tail)) _tail = null;
    });
    return result;
  }

  Future<bool> _writeRaw(String key, Object? value) => switch (value) {
    null => _preferences.remove(key),
    bool value => _preferences.setBool(key, value),
    String value => _preferences.setString(key, value),
    int value => _preferences.setInt(key, value),
    double value => _preferences.setDouble(key, value),
    List<String> value => _preferences.setStringList(key, value),
    _ => throw const FormatException('Unsupported stored preference type'),
  };

  Future<AppPreferenceSaveResult> _save(
    AppPreferenceField field,
    Object value,
  ) {
    if (_closed) return Future.error(StateError('App settings are closed'));
    if (!AppPreferencesSchema.accepts(field, value)) {
      return Future.error(ArgumentError('Invalid app preference choice'));
    }
    _pending.update(field, (count) => count + 1, ifAbsent: () => 1);
    _failures.remove(field);
    final result =
        _ordered(() async {
          if (_closed) throw StateError('App settings are closed');
          if (_reloadFailed || _unverified.contains(field)) {
            throw StateError('Reload app settings before saving this choice');
          }
          final previous = _preferences.get(field.storageKey);
          if (previous == value) {
            _observe();
            return AppPreferenceSaveResult.unchanged;
          }
          try {
            if (!await _writeRaw(field.storageKey, value)) {
              throw StateError('Storage did not confirm the preference');
            }
          } catch (_) {
            var restored = false;
            try {
              restored = await _writeRaw(field.storageKey, previous);
            } catch (_) {
              // The original save remains failed; verification stays explicit.
            }
            if (!restored) _unverified.add(field);
            _failures[field] = restored
                ? AppPreferenceStorageFailure.saveFailed
                : AppPreferenceStorageFailure.restorationUnconfirmed;
            _observe();
            throw AppPreferenceSaveException(restored: restored);
          }
          _unverified.remove(field);
          _failures.remove(field);
          _observe();
          return AppPreferenceSaveResult.saved;
        }).whenComplete(() {
          final count = _pending[field]! - 1;
          if (count == 0) {
            _pending.remove(field);
          } else {
            _pending[field] = count;
          }
          _publish();
        });
    _publish();
    return result;
  }

  /// An explicit fresh storage observation, ordered after pending commands.
  Future<void> reload() {
    if (_closed) return Future.error(StateError('App settings are closed'));
    _reloadRequests++;
    final result =
        _ordered(() async {
          if (_closed) throw StateError('App settings are closed');
          try {
            await _preferences.reload();
          } catch (_) {
            _reloadFailed = true;
            _publish();
            throw StateError('App settings could not be reloaded');
          }
          _reloadFailed = false;
          _unverified.clear();
          _visibilityUnverified.clear();
          _profileColors?.freshlyReloaded();
          _profileSelections?.freshlyReloaded();
          _browserPreferences?.freshlyReloaded();
          _workspaceEntry?.freshlyReloaded();
          _visibilityFailures.removeWhere(
            (_, failure) =>
                failure == AppPreferenceStorageFailure.restorationUnconfirmed,
          );
          _failures.removeWhere(
            (_, failure) =>
                failure == AppPreferenceStorageFailure.restorationUnconfirmed,
          );
          _observe();
        }).whenComplete(() {
          _reloadRequests--;
          _publish();
        });
    _publish();
    return result;
  }

  void _checkVisibilityId(String id) {
    if (id.isEmpty || id.length > 64 * 1024) {
      throw ArgumentError('Invalid connection visibility identity');
    }
  }

  void _observeVisibility(String id) {
    final key = SessionVisibility.preferenceKey(id);
    final raw = _preferences.get(key);
    final observed = !_preferences.containsKey(key)
        ? SessionVisibility.chats
        : SessionVisibility.values
              .where((value) => value.name == raw)
              .firstOrNull;
    if (observed == null) {
      _visibilityInvalid.add(id);
      _visibilityValues.putIfAbsent(id, () => null);
    } else {
      _visibilityInvalid.remove(id);
      _visibilityValues[id] = observed;
    }
  }

  /// Passive connection setting, borrowing this owner's observation and FIFO.
  /// Absence has a declared fresh default; malformed presence has no selection.
  AppPreferenceControl<SessionVisibility> visibilityFor(String id) {
    _checkVisibilityId(id);
    if (!_visibilityValues.containsKey(id)) {
      _observeVisibility(id);
      _publish();
    }
    final unverified = _reloadFailed || _visibilityUnverified.contains(id);
    final invalid = _visibilityInvalid.contains(id);
    final busy = _visibilityPending.containsKey(id);
    return AppPreferenceControl(
      selected: invalid || unverified ? null : _visibilityValues[id],
      busy: busy,
      notice: unverified
          ? 'Reload settings to verify this chat filter.'
          : invalid
          ? 'The saved chat filter is invalid. Choose a filter to repair it.'
          : null,
      error: switch (_visibilityFailures[id]) {
        AppPreferenceStorageFailure.saveFailed =>
          'Could not save the chat filter. Please retry.',
        AppPreferenceStorageFailure.restorationUnconfirmed =>
          'Could not verify the chat filter. Reload settings.',
        null => null,
      },
      choose: _closed || unverified || busy || _reloadRequests > 0
          ? null
          : (value) async {
              try {
                await setConnectionVisibility(id, value);
                return true;
              } catch (_) {
                return false;
              }
            },
    );
  }

  Future<AppPreferenceSaveResult> setConnectionVisibility(
    String id,
    SessionVisibility value,
  ) {
    _checkVisibilityId(id);
    if (_closed) return Future.error(StateError('App settings are closed'));
    if (!_visibilityValues.containsKey(id)) _observeVisibility(id);
    _visibilityPending.update(id, (count) => count + 1, ifAbsent: () => 1);
    _visibilityFailures.remove(id);
    final result =
        _ordered(() async {
          if (_closed) throw StateError('App settings are closed');
          if (_reloadFailed || _visibilityUnverified.contains(id)) {
            throw StateError('Reload settings before saving the chat filter');
          }
          final key = SessionVisibility.preferenceKey(id);
          final previous = _preferences.get(key);
          if (previous == value.name) {
            _observe();
            return AppPreferenceSaveResult.unchanged;
          }
          try {
            if (!await _writeRaw(key, value.name)) {
              throw StateError('Unconfirmed setting');
            }
          } catch (_) {
            var restored = false;
            try {
              restored = await _writeRaw(key, previous);
            } catch (_) {}
            if (!restored) _visibilityUnverified.add(id);
            _visibilityFailures[id] = restored
                ? AppPreferenceStorageFailure.saveFailed
                : AppPreferenceStorageFailure.restorationUnconfirmed;
            _observe();
            throw StateError(
              restored
                  ? 'The chat filter could not be saved.'
                  : 'The chat filter could not be verified. Reload settings.',
            );
          }
          _visibilityUnverified.remove(id);
          _visibilityFailures.remove(id);
          _observe();
          return AppPreferenceSaveResult.saved;
        }).whenComplete(() {
          final count = _visibilityPending[id]! - 1;
          if (count == 0) {
            _visibilityPending.remove(id);
          } else {
            _visibilityPending[id] = count;
          }
          _publish();
        });
    _publish();
    return result;
  }

  Future<void> _freshBackupObservation(Iterable<String> ids) async {
    try {
      await _preferences.reload();
    } catch (_) {
      _reloadFailed = true;
      _publish();
      throw StateError('App settings could not be verified');
    }
    _reloadFailed = false;
    _unverified.clear();
    _visibilityUnverified.clear();
    _profileColors?.freshlyReloaded();
    _profileSelections?.freshlyReloaded();
    _browserPreferences?.freshlyReloaded();
    _workspaceEntry?.freshlyReloaded();
    _failures.removeWhere(
      (_, failure) =>
          failure == AppPreferenceStorageFailure.restorationUnconfirmed,
    );
    _visibilityFailures.removeWhere(
      (_, failure) =>
          failure == AppPreferenceStorageFailure.restorationUnconfirmed,
    );
    for (final id in ids) {
      _observeVisibility(id);
    }
    _observe();
  }

  /// Export is a fresh sparse observation queued with all preference commands.
  Future<AppPreferencesBackupSnapshot> exportBackupSnapshot({
    required Iterable<String> connectionIds,
  }) {
    final ids = Set<String>.of(connectionIds);
    if (ids.length > 256) throw ArgumentError('Too many backup connections');
    for (final id in ids) {
      _checkVisibilityId(id);
    }
    return _ordered(() async {
      if (_closed) throw StateError('App settings are closed');
      await _freshBackupObservation(ids);
      if (_closed) throw StateError('App settings are closed');
      if (_issues.isNotEmpty || ids.any(_visibilityInvalid.contains)) {
        throw StateError('Repair invalid app settings before exporting');
      }
      return AppPreferencesBackupSnapshot(
        explicitlyPresent: {
          for (final field in AppPreferenceField.values)
            if (_preferences.containsKey(field.storageKey))
              field: _preferences.get(field.storageKey)!,
        },
        explicitlyPresentVisibility: {
          for (final id in ids)
            if (_preferences.containsKey(SessionVisibility.preferenceKey(id)))
              id: _visibilityValues[id]!,
        },
      );
    });
  }

  /// Sparse transaction over the two typed settings namespaces. Connections
  /// themselves are committed separately by their owner.
  Future<AppPreferencesRestoreResult> restoreBackupPatch(
    AppPreferencesBackupPatch patch,
  ) {
    if (_closed) return Future.error(StateError('App settings are closed'));
    final fields = patch.explicitlyPresent.keys.toSet();
    final ids = patch.explicitlyPresentVisibility.keys.toSet();
    for (final field in fields) {
      _pending.update(field, (count) => count + 1, ifAbsent: () => 1);
    }
    for (final id in ids) {
      _visibilityPending.update(id, (count) => count + 1, ifAbsent: () => 1);
    }
    final result =
        _ordered(() async {
          if (_closed) throw StateError('App settings are closed');
          await _freshBackupObservation(ids);
          if (_closed) throw StateError('App settings are closed');
          final writes =
              <
                ({
                  AppPreferenceField? field,
                  String? id,
                  String key,
                  Object value,
                })
              >[
                for (final entry in patch.explicitlyPresent.entries)
                  (
                    field: entry.key,
                    id: null,
                    key: entry.key.storageKey,
                    value: entry.value,
                  ),
                for (final entry in patch.explicitlyPresentVisibility.entries)
                  (
                    field: null,
                    id: entry.key,
                    key: SessionVisibility.preferenceKey(entry.key),
                    value: entry.value.name,
                  ),
              ];
          final before = {
            for (final write in writes) write.key: _preferences.get(write.key),
          };
          final attempted =
              <
                ({
                  AppPreferenceField? field,
                  String? id,
                  String key,
                  Object value,
                })
              >[];
          var committed = true;
          try {
            for (final write in writes) {
              if (before[write.key] == write.value) continue;
              attempted.add(write);
              if (!await _writeRaw(write.key, write.value)) {
                throw StateError('Unconfirmed backup setting');
              }
            }
          } catch (_) {
            committed = false;
            for (final write in attempted.reversed) {
              var restored = false;
              try {
                restored = await _writeRaw(write.key, before[write.key]);
              } catch (_) {}
              if (!restored) {
                if (write.field case final field?) _unverified.add(field);
                if (write.id case final id?) _visibilityUnverified.add(id);
              }
            }
          }
          for (final write in attempted) {
            if (write.field case final field?) {
              _failures[field] = _unverified.contains(field)
                  ? AppPreferenceStorageFailure.restorationUnconfirmed
                  : AppPreferenceStorageFailure.saveFailed;
              if (committed) _failures.remove(field);
            }
            if (write.id case final id?) {
              _visibilityFailures[id] = _visibilityUnverified.contains(id)
                  ? AppPreferenceStorageFailure.restorationUnconfirmed
                  : AppPreferenceStorageFailure.saveFailed;
              if (committed) _visibilityFailures.remove(id);
            }
          }
          _observe();
          final attemptedFields = {for (final write in attempted) ?write.field};
          final attemptedIds = {for (final write in attempted) ?write.id};
          return AppPreferencesRestoreResult(
            committed: committed,
            attemptedFields: attemptedFields,
            attemptedVisibility: attemptedIds,
            unverifiedFields: attemptedFields.intersection(_unverified),
            unverifiedVisibility: attemptedIds.intersection(
              _visibilityUnverified,
            ),
          );
        }).whenComplete(() {
          for (final field in fields) {
            final count = _pending[field]! - 1;
            if (count == 0) {
              _pending.remove(field);
            } else {
              _pending[field] = count;
            }
          }
          for (final id in ids) {
            final count = _visibilityPending[id]! - 1;
            if (count == 0) {
              _visibilityPending.remove(id);
            } else {
              _visibilityPending[id] = count;
            }
          }
          _publish();
        });
    _publish();
    return result;
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _presentation.dispose();
    _profileColors?.dispose();
    _profileSelections?.dispose();
    _browserPreferences?.dispose();
    _workspaceEntry?.dispose();
  }
}

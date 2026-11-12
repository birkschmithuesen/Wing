import 'app_preferences.dart';
import 'session_visibility.dart';

Map<AppPreferenceField, Object> _fixedSettings(
  Map<AppPreferenceField, Object> values,
) {
  for (final entry in values.entries) {
    if (!AppPreferencesSchema.accepts(entry.key, entry.value)) {
      throw const FormatException('Invalid backup app setting.');
    }
  }
  return Map.unmodifiable(values);
}

Map<String, SessionVisibility> _visibilitySettings(
  Map<String, SessionVisibility> values,
) {
  if (values.length > 256 ||
      values.keys.any((id) => id.isEmpty || id.length > 64 * 1024)) {
    throw const FormatException('Invalid backup connection visibility.');
  }
  return Map.unmodifiable(values);
}

/// A fresh, verified sparse observation. Absent keys remain absent; product
/// defaults and previously retained observations are not materialized here.
class AppPreferencesBackupSnapshot {
  AppPreferencesBackupSnapshot({
    required Map<AppPreferenceField, Object> explicitlyPresent,
    required Map<String, SessionVisibility> explicitlyPresentVisibility,
  }) : explicitlyPresent = _fixedSettings(explicitlyPresent),
       explicitlyPresentVisibility = _visibilitySettings(
         explicitlyPresentVisibility,
       );

  final Map<AppPreferenceField, Object> explicitlyPresent;
  final Map<String, SessionVisibility> explicitlyPresentVisibility;
}

/// A validated sparse choice; its keys cannot address credentials, journals,
/// caches or any preference outside these two named settings namespaces.
class AppPreferencesBackupPatch {
  AppPreferencesBackupPatch({
    required Map<AppPreferenceField, Object> explicitlyPresent,
    required Map<String, SessionVisibility> explicitlyPresentVisibility,
  }) : explicitlyPresent = _fixedSettings(explicitlyPresent),
       explicitlyPresentVisibility = _visibilitySettings(
         explicitlyPresentVisibility,
       );

  final Map<AppPreferenceField, Object> explicitlyPresent;
  final Map<String, SessionVisibility> explicitlyPresentVisibility;

  int get length =>
      explicitlyPresent.length + explicitlyPresentVisibility.length;
}

/// Storage truth after a sparse restore. A failed operation has restored every
/// attempted field except the explicitly unverified subset. No platform error
/// or setting value is published in this result.
class AppPreferencesRestoreResult {
  AppPreferencesRestoreResult({
    required this.committed,
    required Iterable<AppPreferenceField> attemptedFields,
    required Iterable<String> attemptedVisibility,
    required Iterable<AppPreferenceField> unverifiedFields,
    required Iterable<String> unverifiedVisibility,
  }) : attemptedFields = Set.unmodifiable(attemptedFields),
       attemptedVisibility = Set.unmodifiable(attemptedVisibility),
       unverifiedFields = Set.unmodifiable(unverifiedFields),
       unverifiedVisibility = Set.unmodifiable(unverifiedVisibility) {
    if (!this.attemptedFields.containsAll(this.unverifiedFields) ||
        !this.attemptedVisibility.containsAll(this.unverifiedVisibility) ||
        committed &&
            (this.unverifiedFields.isNotEmpty ||
                this.unverifiedVisibility.isNotEmpty)) {
      throw ArgumentError('Inconsistent backup restore outcome.');
    }
  }

  final bool committed;
  final Set<AppPreferenceField> attemptedFields;
  final Set<String> attemptedVisibility;
  final Set<AppPreferenceField> unverifiedFields;
  final Set<String> unverifiedVisibility;

  bool get restorationVerified =>
      !committed && unverifiedFields.isEmpty && unverifiedVisibility.isEmpty;
}

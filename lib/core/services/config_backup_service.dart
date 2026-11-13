import '../models/app_preferences.dart';
import '../models/app_preferences_backup.dart';
import '../models/config_backup_operation.dart';
import '../models/session_visibility.dart';
import 'app_preferences.dart';
import 'config_backup.dart';
import 'connection_manager.dart';

/// Sequences two named durable owners. Preferences never have a second writer
/// here, and a settings failure never claims to undo a confirmed connection
/// transaction.
class ConfigBackupService {
  ConfigBackupService({
    required this._connectionManager,
    required this._appPreferences,
  });

  final ConnectionManager _connectionManager;
  final AppPreferences _appPreferences;

  /// Portable visibility addresses logical connection IDs, never device HMACs.
  static const visibilityBackupPrefix = 'connection_visibility.';

  Future<ConfigBackup> export({required String appVersion}) async {
    final connections = await _connectionManager.loadConnectionsWithSecrets();
    final snapshot = await _appPreferences.exportBackupSnapshot(
      connectionIds: connections.map((connection) => connection.id),
    );
    return ConfigBackup(
      createdAt: DateTime.now().toUtc(),
      appVersion: appVersion,
      connections: connections,
      preferences: {
        for (final entry in snapshot.explicitlyPresent.entries)
          entry.key.storageKey: entry.value,
        for (final entry in snapshot.explicitlyPresentVisibility.entries)
          '$visibilityBackupPrefix${entry.key}': entry.value.name,
      },
    );
  }

  Future<ConfigImportResult> import(
    ConfigBackup backup, {
    required ConfigImportMode mode,
    required bool Function() canCommit,
  }) async {
    // Validate and detach caller-owned structures before either owner mutates.
    backup = ConfigBackup.fromJson(backup.toJson());
    final connectionIds = backup.connections.map((c) => c.id).toSet();
    final fixed = <AppPreferenceField, Object>{};
    final visibility = <String, SessionVisibility>{};
    var skipped = 0;
    for (final entry in backup.preferences.entries) {
      AppPreferenceField? field;
      for (final candidate in AppPreferenceField.values) {
        if (candidate.storageKey == entry.key) {
          field = candidate;
          break;
        }
      }
      if (field != null && AppPreferencesSchema.accepts(field, entry.value)) {
        fixed[field] = entry.value;
        continue;
      }
      if (entry.key.startsWith(visibilityBackupPrefix)) {
        final id = entry.key.substring(visibilityBackupPrefix.length);
        SessionVisibility? value;
        for (final candidate in SessionVisibility.values) {
          if (candidate.name == entry.value) {
            value = candidate;
            break;
          }
        }
        if (connectionIds.contains(id) && value != null) {
          visibility[id] = value;
          continue;
        }
      }
      skipped++;
    }
    final patch = AppPreferencesBackupPatch(
      explicitlyPresent: fixed,
      explicitlyPresentVisibility: visibility,
    );

    final membership = await _connectionManager.importConnections(
      backup.connections,
      replaceExisting: mode == ConfigImportMode.replace,
      canCommit: canCommit,
    );
    // From this point connections are confirmed. Settings settle in their
    // application-root owner even if the initiating route has since closed.
    AppPreferencesRestoreResult? settings;
    try {
      settings = await _appPreferences.restoreBackupPatch(patch);
    } catch (_) {
      // The settings owner refused admission, not the committed manager.
    }
    final state = settings == null
        ? ConfigImportSettingsState.notStarted
        : settings.committed
        ? ConfigImportSettingsState.restored
        : settings.restorationVerified
        ? ConfigImportSettingsState.rolledBack
        : ConfigImportSettingsState.unverified;
    return ConfigImportResult(
      connectionsAdded: membership.added,
      connectionsUpdated: membership.updated,
      connectionsRemoved: membership.removed,
      preferencesApplied: settings?.committed == true ? patch.length : 0,
      preferencesSkipped: skipped,
      settingsState: state,
      settingsUnverified:
          (settings?.unverifiedFields.length ?? 0) +
          (settings?.unverifiedVisibility.length ?? 0),
    );
  }
}

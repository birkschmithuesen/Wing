/// Connection membership after a successful configuration import.
enum ConfigImportMode { merge, replace }

enum ConfigImportSettingsState { restored, rolledBack, unverified, notStarted }

/// Connection counts describe the manager's confirmed transaction. Settings
/// may have failed afterwards; this value never claims cross-store atomicity.
class ConfigImportResult {
  const ConfigImportResult({
    required this.connectionsAdded,
    required this.connectionsUpdated,
    required this.connectionsRemoved,
    required this.preferencesApplied,
    required this.preferencesSkipped,
    required this.settingsState,
    required this.settingsUnverified,
  });

  final int connectionsAdded;
  final int connectionsUpdated;
  final int connectionsRemoved;
  final int preferencesApplied;
  final int preferencesSkipped;
  final ConfigImportSettingsState settingsState;
  final int settingsUnverified;

  bool get complete => settingsState == ConfigImportSettingsState.restored;

  String get summary {
    final parts = <String>[];
    if (connectionsAdded > 0) parts.add('$connectionsAdded added');
    if (connectionsUpdated > 0) parts.add('$connectionsUpdated updated');
    if (connectionsRemoved > 0) parts.add('$connectionsRemoved removed');
    final connections = parts.isEmpty
        ? 'No connection changes'
        : 'Connections: ${parts.join(', ')}';
    final settings = switch (settingsState) {
      ConfigImportSettingsState.restored =>
        '$preferencesApplied settings restored',
      ConfigImportSettingsState.rolledBack =>
        'Settings failed; previous settings restored',
      ConfigImportSettingsState.unverified =>
        'Settings failed; $settingsUnverified settings could not be verified',
      ConfigImportSettingsState.notStarted => 'Settings could not be restored',
    };
    return '$connections · $settings'
        '${preferencesSkipped > 0 ? ' · $preferencesSkipped settings skipped' : ''}';
  }
}

class BackupChoiceException implements Exception {
  const BackupChoiceException(this.message);
  final String message;
}

/// The exact export choice. Empty input explicitly chooses plaintext; encrypted
/// choices are validated at this boundary without changing their bytes.
class BackupExportIntent {
  BackupExportIntent({required String passphrase, required String confirmation})
    : passphrase = passphrase {
    if (passphrase.isEmpty && confirmation.isEmpty) return;
    if (passphrase.trim().isEmpty || passphrase.length < 8) {
      throw const BackupChoiceException('Use at least 8 characters.');
    }
    if (passphrase != confirmation) {
      throw const BackupChoiceException('The two passphrases do not match.');
    }
  }

  final String passphrase;
}

class BackupImportIntent {
  const BackupImportIntent({required this.passphrase, required this.mode});
  final String passphrase;
  final ConfigImportMode mode;
}

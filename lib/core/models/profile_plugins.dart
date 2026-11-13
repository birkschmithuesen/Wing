/// Only the current stock configuration statuses, not runtime handler liveness.
enum ProfilePluginStatus {
  enabled('enabled'),
  disabled('disabled'),
  notEnabled('not enabled');

  const ProfilePluginStatus(this.label);
  final String label;
}

final class ProfilePlugin {
  const ProfilePlugin({
    required this.key,
    required this.name,
    required this.source,
    required this.description,
    required this.status,
    required this.version,
    required this.installedSha,
    required this.catalogVersion,
    required this.catalogSha,
    required this.updateAvailable,
    required this.updateTarget,
    required this.pinnedSha,
  });
  final String key, name, source, description, version;
  final String? installedSha,
      catalogVersion,
      catalogSha,
      updateTarget,
      pinnedSha;
  final bool? updateAvailable;
  final ProfilePluginStatus status;
  bool get enabled => status == ProfilePluginStatus.enabled;
  bool sameIdentity(ProfilePlugin other) =>
      key == other.key && name == other.name && source == other.source;
  static ProfilePlugin decode(Object? value) {
    if (value is! Map ||
        value['key'] is! String ||
        (value['key'] as String).isEmpty ||
        value['name'] is! String ||
        (value['name'] as String).isEmpty ||
        value['source'] is! String ||
        value['description'] is! String ||
        value['version'] is! String ||
        value['update_available'] != null &&
            value['update_available'] is! bool) {
      throw const FormatException('Invalid plugin inventory');
    }
    final status = ProfilePluginStatus.values
        .where((status) => status.label == value['status'])
        .firstOrNull;
    if (status == null) {
      throw const FormatException('Invalid plugin status');
    }
    return ProfilePlugin(
      key: value['key'] as String,
      name: value['name'] as String,
      source: value['source'] as String,
      description: value['description'] as String,
      status: status,
      version: value['version'] as String,
      installedSha: _optionalString(value, 'installed_sha'),
      catalogVersion: _optionalString(value, 'catalog_version'),
      catalogSha: _optionalString(value, 'catalog_sha'),
      updateAvailable: value['update_available'] as bool?,
      updateTarget: _optionalString(value, 'update_target'),
      pinnedSha: _optionalString(value, 'pinned_sha'),
    );
  }

  static List<ProfilePlugin> inventory(Map<String, dynamic> response) {
    final values = response['plugins'];
    if (values is! List) {
      throw const FormatException('Invalid plugin inventory');
    }
    final rows = values.map(decode).toList();
    if (rows.map((row) => row.key).toSet().length != rows.length) {
      throw const FormatException('Duplicate plugin identity');
    }
    return List.unmodifiable(rows);
  }
}

final class ProfilePluginAcknowledgement {
  const ProfilePluginAcknowledgement({
    required this.key,
    required this.enabled,
    required this.restartRequired,
  });
  final String key;
  final bool enabled, restartRequired;
  static ProfilePluginAcknowledgement decode(
    Map<String, dynamic> response,
    String key,
    bool enabled,
  ) {
    if (response['ok'] != true ||
        response['name'] != key ||
        response['unchanged'] is! bool ||
        response['restart_required'] is! bool ||
        response['gateway_reloaded'] is! bool) {
      throw const FormatException('Plugin change was not acknowledged');
    }
    return ProfilePluginAcknowledgement(
      key: key,
      enabled: enabled,
      restartRequired: response['restart_required'] as bool,
    );
  }
}

String? _optionalString(Map value, String key) {
  final field = value[key];
  if (field != null && field is! String) {
    throw const FormatException('Invalid plugin metadata');
  }
  return field as String?;
}

enum PluginUpdateStatus {
  updated('Updated'),
  current('Already current'),
  failed('Failed'),
  needsReview('Needs review');

  const PluginUpdateStatus(this.label);
  final String label;
}

final class PluginUpdateResult {
  const PluginUpdateResult(this.name, this.status, this.detail);
  final String name, detail;
  final PluginUpdateStatus status;
}

final class PluginUpdateSkip {
  const PluginUpdateSkip(this.name, this.reason);
  final String name, reason;
}

/// A completed batch can contain failures and skipped installs. It makes no
/// promise that every plugin changed or that all new code is active now.
final class PluginMaintenanceResult {
  PluginMaintenanceResult._(this.results, this.skipped, this.current);
  final List<PluginUpdateResult> results;
  final List<PluginUpdateSkip> skipped;
  final int current;
  bool get needsReview =>
      results.any((row) => row.status == PluginUpdateStatus.needsReview);
  int get alreadyCurrent =>
      current +
      results.where((row) => row.status == PluginUpdateStatus.current).length;
  int get updated =>
      results.where((row) => row.status == PluginUpdateStatus.updated).length;

  factory PluginMaintenanceResult.decode(Map<String, dynamic> response) {
    final raw = response['results'], skipped = response['skipped'];
    final current = response['current'];
    if (raw is! List || skipped is! List || current is! int || current < 0) {
      throw const FormatException('Invalid plugin update result');
    }
    final names = <String>{};
    String name(Map row) {
      final name = row['name'];
      if (name is! String || name.isEmpty || !names.add(name)) {
        throw const FormatException('Invalid plugin update identity');
      }
      return name;
    }

    final results = <PluginUpdateResult>[];
    for (final row in raw) {
      if (row is! Map || row['detail'] is! String) {
        throw const FormatException('Invalid plugin update row');
      }
      final status = switch (row['status']) {
        'updated' => PluginUpdateStatus.updated,
        'current' => PluginUpdateStatus.current,
        'failed' => PluginUpdateStatus.failed,
        'needs_review' => PluginUpdateStatus.needsReview,
        _ => throw const FormatException('Invalid plugin update status'),
      };
      results.add(
        PluginUpdateResult(name(row), status, row['detail'] as String),
      );
    }
    final skips = <PluginUpdateSkip>[];
    for (final row in skipped) {
      if (row is! Map || row['reason'] is! String) {
        throw const FormatException('Invalid skipped plugin');
      }
      skips.add(PluginUpdateSkip(name(row), row['reason'] as String));
    }
    return PluginMaintenanceResult._(
      List.unmodifiable(results),
      List.unmodifiable(skips),
      current,
    );
  }
}

enum ProfilePluginsPhase { idle, loading, saving, updating }

final class ProfilePluginsState {
  ProfilePluginsState({
    required this.hasObservation,
    required Iterable<ProfilePlugin> rows,
    required this.phase,
    required this.verified,
    required this.error,
    required this.retryable,
    required this.acknowledgement,
    required this.maintenance,
  }) : rows = List.unmodifiable(rows);
  final List<ProfilePlugin> rows;
  final ProfilePluginsPhase phase;
  final bool verified, retryable;
  final bool hasObservation;
  final String? error;
  final ProfilePluginAcknowledgement? acknowledgement;
  final PluginMaintenanceResult? maintenance;
  bool get busy => phase != ProfilePluginsPhase.idle;
  bool get canToggle => verified && !busy;
  bool get canRefresh => !busy;
  bool get canUpdate => verified && !busy && rows.isNotEmpty;
}

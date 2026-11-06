import 'package:flutter/foundation.dart';

import '../models/model_choice.dart';
import '../models/profile_connectors.dart';
import '../models/provider_access.dart';
import 'administration_repository.dart';
import 'health_snapshot.dart';

/// Independent observations for one captured profile. A failed refresh retains
/// its previous observation, never an invented empty/default configuration.
class AdministrationObservation {
  AdministrationObservation({
    Map<String, dynamic>? data,
    this.checkedAt,
    this.error,
    this.loading = false,
  }) : data = data == null
           ? null
           : _immutableObservationValue(data) as Map<String, dynamic>;

  AdministrationObservation._retained(
    this.data,
    this.checkedAt,
    this.error,
    this.loading,
  );

  final Map<String, dynamic>? data;
  final DateTime? checkedAt;
  final String? error;
  final bool loading;
  static const _retainError = Object();

  AdministrationObservation copyWith({
    bool? loading,
    Object? error = _retainError,
  }) => AdministrationObservation._retained(
    data,
    checkedAt,
    identical(error, _retainError) ? this.error : error as String?,
    loading ?? this.loading,
  );

  Map<String, dynamic> healthSnapshot() => {
    'data': data,
    'checkedAt': checkedAt?.toUtc().toIso8601String(),
    'error': error,
  };

  factory AdministrationObservation.fromHealth(Map value) =>
      AdministrationObservation(
        data: value['data'] == null
            ? null
            : Map<String, dynamic>.from(value['data'] as Map),
        checkedAt: healthSnapshotTime(value['checkedAt']),
        error: value['error'] as String?,
      );
}

Object? _immutableObservationValue(Object? value) => switch (value) {
  Map value => Map<String, dynamic>.unmodifiable({
    for (final entry in value.entries)
      entry.key as String: _immutableObservationValue(entry.value),
  }),
  List value => List<dynamic>.unmodifiable(
    value.map(_immutableObservationValue),
  ),
  null || String() || bool() || num() => value,
  _ => throw const FormatException('Invalid observation value'),
};

/// A passive projection of the overview's single cached model observation.
/// A failed refresh can expose its last confirmed model without inventing one.
class ModelAccessObservation {
  const ModelAccessObservation({
    this.model,
    this.loading = false,
    this.unavailable = false,
  });

  final ConfiguredModel? model;
  final bool loading;
  final bool unavailable;

  static ModelAccessObservation fromObservation(
    AdministrationObservation? observation,
  ) {
    if (observation == null) return const ModelAccessObservation();
    ConfiguredModel? model;
    var unavailable = observation.error != null;
    final data = observation.data;
    if (data != null) {
      try {
        model = ConfiguredModel.fromInfo(data);
      } on FormatException {
        unavailable = true;
      }
    }
    return ModelAccessObservation(
      model: model,
      loading: observation.loading,
      unavailable: unavailable,
    );
  }
}

class AdministrationOverview extends ChangeNotifier {
  AdministrationOverview(this.profile) {
    profile.server.connectorInventory.addListener(_inventoryChanged);
  }
  final ProfileAdministration profile;
  final _observations = <String, AdministrationObservation>{};
  Map<String, AdministrationObservation> get observations =>
      Map.unmodifiable(_observations);
  ModelAccessObservation get modelAccess =>
      ModelAccessObservation.fromObservation(observations['model']);

  /// Last probe results for this profile's enabled connectors. Null means the
  /// request did not establish a result; false means Hermes reported failure.
  Map<String, bool?> _connectorChecks = const {};
  Map<String, bool?> get connectorChecks => _connectorChecks;
  String? get connectorRuntimeError =>
      profile.server.connectorInventory.runtimeError(profile.name);
  ConnectorRuntimeObservation? get connectorRuntime =>
      profile.server.connectorInventory.runtimeObservations[profile.name];
  Map<String, ConnectorRuntime> get connectorRuntimeIssues {
    final inventory =
        profile.server.connectorInventory.observations[profile.name];
    final runtime = connectorRuntime;
    return inventory == null || runtime == null
        ? const {}
        : runtime.issuesFor(inventory.connectors.values);
  }

  bool _disposed = false;
  void _inventoryChanged() {
    if (_disposed) return;
    final inventory =
        profile.server.connectorInventory.observations[profile.name];
    if (inventory == null) {
      notifyListeners();
      return;
    }
    final retained = <String, bool?>{
      for (final entry in _connectorChecks.entries)
        if (inventory.enabled[entry.key] == true) entry.key: entry.value,
    };
    _connectorChecks = Map.unmodifiable(retained);
    notifyListeners();
  }

  final _generations = <String, int>{};
  static const endpoints = {
    'config': 'config',
    'model': 'model/info',
    'skills': 'skills',
    'tools': 'tools/toolsets',
    'access': 'providers/oauth',
    'connectors': 'mcp/servers',
  };

  /// Persist only health metadata, never connector commands, environment
  /// variables, provider secrets or the full configuration response.
  Map<String, dynamic> healthSnapshot() => {
    'observations': {
      for (final entry in observations.entries)
        if ({'model', 'access', 'tools', 'connectors'}.contains(entry.key))
          entry.key: {
            ...entry.value.healthSnapshot(),
            'data': entry.value.data == null
                ? null
                : _healthData(entry.key, entry.value.data!),
          },
    },
    'connectorChecks': connectorChecks,
  };

  void restoreHealth(Map snapshot) {
    final restored = <String, AdministrationObservation>{
      for (final entry in (snapshot['observations'] as Map).entries)
        entry.key as String: AdministrationObservation.fromHealth(
          entry.value as Map,
        ),
    };
    final connectors = Map<String, bool?>.unmodifiable(
      snapshot['connectorChecks'] as Map,
    );
    _observations.addAll(restored);
    _connectorChecks = connectors;
    _inventoryChanged();
  }

  Map<String, dynamic> _healthData(String key, Map<String, dynamic> data) {
    if (key == 'model') {
      return {'model': data['model'], 'provider': data['provider']};
    }
    final collection = switch (key) {
      'access' => 'providers',
      'tools' => 'data',
      _ => 'servers',
    };
    return {
      collection: [
        for (final row in administrationRows(data[collection]))
          {
            for (final field in [
              'id',
              'name',
              'label',
              'display_name',
              'flow',
              'enabled',
              'configured',
            ])
              if (row.containsKey(field)) field: row[field],
            if (key == 'access' && row['status'] is Map)
              'status': {
                for (final field in ['logged_in', 'expires_at'])
                  field: row['status'][field],
                if (row['status']['error'] != null) 'error': true,
              },
          },
      ],
    };
  }

  Future<void> refresh({Set<String>? keys, bool testConnectors = false}) async {
    if (_disposed) return;
    await Future.wait([
      for (final entry in endpoints.entries)
        if (keys == null || keys.contains(entry.key))
          _read(
            entry.key,
            entry.value,
            _generations.update(entry.key, (n) => n + 1, ifAbsent: () => 1),
            testConnectors: testConnectors && entry.key == 'connectors',
          ),
    ]);
  }

  Future<void> _read(
    String key,
    String endpoint,
    int generation, {
    required bool testConnectors,
  }) async {
    final observation = _observations.putIfAbsent(
      key,
      AdministrationObservation.new,
    );
    _observations[key] = observation.copyWith(loading: true, error: null);
    if (!_disposed) notifyListeners();
    try {
      final data =
          _immutableObservationValue(
                key == 'connectors'
                    ? await profile.server.connectorInventory.refresh(
                        profile.name,
                      )
                    : await profile.read(endpoint),
              )
              as Map<String, dynamic>;
      if (key == 'model') ConfiguredModel.fromInfo(data);
      // Validate collection shape before replacing the last good observation.
      final collection = switch (key) {
        'skills' || 'tools' => 'data',
        'access' => 'providers',
        'connectors' => 'servers',
        _ => null,
      };
      if (collection != null) administrationRows(data[collection]);
      if (key == 'access') {
        for (final row in administrationRows(data['providers'])) {
          ProviderAccess.validateIdentity(row);
        }
      }
      if (_disposed || generation != _generations[key]) return;
      if (key == 'connectors') {
        final results = <String, bool?>{};
        if (testConnectors) {
          for (final row in administrationRows(data['servers'])) {
            if (_disposed || generation != _generations[key]) return;
            final name = row['name'];
            if (row['enabled'] != true || name is! String || name.isEmpty) {
              continue;
            }
            try {
              // Stock Hermes 783f854b0fb2bb224cedf972b40adfc77e9c818f:
              // connect, inspect capabilities and disconnect in this profile.
              final result = await profile.testConnector(name);
              results[name] = result['ok'] is bool
                  ? result['ok'] as bool
                  : null;
            } catch (_) {
              results[name] = null;
            }
          }
        }
        if (_disposed || generation != _generations[key]) return;
        if (testConnectors) _connectorChecks = Map.unmodifiable(results);
        _inventoryChanged();
      }
      _observations[key] = AdministrationObservation._retained(
        data,
        key == 'connectors' && !testConnectors && _connectorChecks.isNotEmpty
            ? observation.checkedAt
            : DateTime.now(),
        null,
        true,
      );
    } catch (error) {
      if (_disposed || generation != _generations[key]) return;
      _observations[key] = _observations[key]!.copyWith(
        error: administrationError(error),
      );
    } finally {
      if (!_disposed && generation == _generations[key]) {
        _observations[key] = _observations[key]!.copyWith(loading: false);
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    profile.server.connectorInventory.removeListener(_inventoryChanged);
    super.dispose();
  }
}

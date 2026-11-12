// Named transport functions are intentionally public injectable seams.
// ignore_for_file: prefer_initializing_formals

import '../models/hermes_profile.dart';
import '../models/model_catalog.dart';
import 'models_dev_pricing.dart';

typedef ModelCatalogRead =
    Future<Map<String, dynamic>> Function({
      required bool refresh,
      required bool explicitOnly,
    });

/// Model and subscription observations for one immutable connection/profile.
/// Reads share in-flight work per catalog policy. Every load rechecks backend
/// telemetry; refresh supersedes older work. Closing fences pending completions.
class ProfileModelCatalog {
  // Named transport seam keeps decoder and lifetime independently testable.
  ProfileModelCatalog({
    required this.scope,
    required ModelCatalogRead read,
    ApiPricingRead? apiPricing,
  }) : _read = read,
       _apiPricing = apiPricing;
  final ApiPricingRead? _apiPricing;
  final WorkspaceScope scope;
  final ModelCatalogRead _read;
  final _snapshots = <bool, ModelCatalog>{};
  final _pending = <bool, Future<ModelCatalog>>{};
  final _generations = <bool, int>{};
  bool _closed = false;
  ModelCatalog? get snapshot => _snapshots[false];

  Future<ModelCatalog> load({
    bool refresh = false,
    bool explicitOnly = false,
    bool supersede = false,
  }) {
    if (_closed) {
      return Future.error(StateError('Model catalog is closed'));
    }
    final pending = _pending[explicitOnly];
    if (!refresh && !supersede && pending != null) return pending;
    final generation = (_generations[explicitOnly] ?? 0) + 1;
    _generations[explicitOnly] = generation;
    final result = _load(generation, refresh, explicitOnly);
    _pending[explicitOnly] = result;
    return result;
  }

  Future<ModelCatalog> _load(
    int generation,
    bool refresh,
    bool explicitOnly,
  ) async {
    try {
      final response = await Future<Map<String, dynamic>>.sync(
        () => _read(refresh: refresh, explicitOnly: explicitOnly),
      );
      if (_closed || generation != _generations[explicitOnly]) {
        throw StateError('Model catalog read superseded');
      }
      final prices = await _apiPricing?.call(refresh: refresh);
      if (_closed || generation != _generations[explicitOnly]) {
        throw StateError('Model catalog read superseded');
      }
      final catalog = ModelCatalog.fromOptions(response, apiPrices: prices);
      _snapshots[explicitOnly] = catalog;
      return catalog;
    } finally {
      if (generation == _generations[explicitOnly]) {
        _pending.remove(explicitOnly);
      }
    }
  }

  void close() {
    _closed = true;
    _pending.clear();
    _generations.clear();
    _snapshots.clear();
  }
}

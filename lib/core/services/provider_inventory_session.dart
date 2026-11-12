import 'package:flutter/foundation.dart';
import '../models/provider_access.dart';
import '../models/provider_inventory.dart';
import 'administration_repository.dart';
import 'workspace_connection_failure.dart';

enum ProviderInventoryScope { inventory, catalog }

/// One route's observation. Recovery detail remains owned by ProviderRecovery;
/// this owner contains no renewal command, credential draft or runtime cache.
class ProviderInventorySession extends ChangeNotifier {
  ProviderInventorySession(this.profile, {required this.scope}) {
    profile.server.retain();
  }

  ProviderInventory? get observation => _observation;
  bool get loading => _loading;
  String? get error => _error;
  ProviderInventoryFilter get filter => _filter;
  final ProfileAdministration profile;
  final ProviderInventoryScope scope;
  ProviderInventory? _observation;
  bool _loading = true, _retryable = false, _disposed = false;
  String? _error;
  int _generation = 0;
  String _query = '';
  ProviderInventoryFilter _filter = ProviderInventoryFilter.all;
  List<ProviderInventoryEntry> get providers => List.unmodifiable(
    _observation?.providers.where((p) => p.matches(_query, _filter)) ??
        const [],
  );
  List<ProviderEnvironmentField> get keys => List.unmodifiable(
    _observation?.keys.where(
          (k) => k.matches(
            _query,
            catalog: scope == ProviderInventoryScope.catalog,
          ),
        ) ??
        const [],
  );
  bool get canRecover => !_disposed && !_loading && _retryable;
  void _changed() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void search(String value) {
    if (_disposed) {
      return;
    }
    _query = value;
    _changed();
  }

  void selectFilter(ProviderInventoryFilter value) {
    if (_disposed) {
      return;
    }
    _filter = value;
    _changed();
  }

  Future<bool> _selections() async {
    try {
      return (await profile.server.read('profiles'))['profiles'] is List;
    } catch (_) {
      return false;
    }
  }

  Future<void> refresh() async {
    if (_disposed) {
      return;
    }
    final generation = ++_generation;
    _loading = true;
    _retryable = false;
    _error = null;
    _changed();
    try {
      final now = DateTime.now();
      final reads = await Future.wait<Object>([
        profile.read('env'),
        if (scope == ProviderInventoryScope.inventory)
          profile.read('providers/oauth'),
        if (scope == ProviderInventoryScope.inventory) _selections(),
      ]);
      final fields = ProviderEnvironmentField.fromResponse(
        reads[0] as Map<String, dynamic>,
      );
      final providers = <ProviderInventoryEntry>[];
      if (scope == ProviderInventoryScope.inventory) {
        final ids = <String>{};
        for (final row in administrationRows((reads[1] as Map)['providers'])) {
          if (row['id'] is! String ||
              (row['id'] as String).isEmpty ||
              row['name'] is! String ||
              row['flow'] is! String ||
              !ids.add(row['id'] as String)) {
            throw const FormatException('Invalid provider inventory');
          }
          // Existing ProviderAccess owns status policy; only safe metadata is
          // projected, never a token preview or an arbitrary credential map.
          providers.add(ProviderInventoryEntry(ProviderAccess(row, now: now)));
        }
        providers.sort((a, b) {
          final order = a.sortOrder.compareTo(b.sortOrder);
          return order != 0 ? order : a.name.compareTo(b.name);
        });
      }
      if (_disposed || generation != _generation) {
        return;
      }
      _observation = ProviderInventory(
        providers: providers,
        keys: fields,
        selectionsAvailable:
            scope == ProviderInventoryScope.catalog || reads[2] == true,
        checkedAt: DateTime.now(),
      );
    } catch (failure) {
      if (_disposed || generation != _generation) {
        return;
      }
      _error = administrationError(failure);
      _retryable = isTemporaryWorkspaceFailure(failure);
    } finally {
      if (!_disposed && generation == _generation) {
        _loading = false;
        _changed();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation++;
    profile.server.release();
    super.dispose();
  }
}

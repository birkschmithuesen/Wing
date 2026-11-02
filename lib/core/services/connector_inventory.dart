import 'package:flutter/foundation.dart';

import '../models/profile_connectors.dart';

/// Connection-owned configuration membership, shared by editors and Health.
/// Reads do not connect to MCP servers or execute their configured programs.
class ConnectorInventory extends ChangeNotifier {
  ConnectorInventory(this._read);
  final Future<Map<String, dynamic>> Function(String profile) _read;
  final _observations = <String, ConnectorInventoryObservation>{};
  final _generations = <String, int>{};
  final _pending = <String, Future<Map<String, dynamic>>>{};
  bool _disposed = false;

  Map<String, ConnectorInventoryObservation> get observations =>
      Map.unmodifiable(_observations);

  /// Dispatching a mutation revokes reads begun before the write. Its readback
  /// must start a new read rather than joining an obsolete monitoring request.
  void invalidate(String profile) {
    _generations.update(profile, (value) => value + 1, ifAbsent: () => 1);
    _pending.remove(profile);
    _observations.remove(profile);
    if (!_disposed) notifyListeners();
  }

  Future<Map<String, dynamic>> refresh(String profile) {
    if (_disposed) return Future.error(StateError('Inventory is closed'));
    if (_pending[profile] case final pending?) return pending;
    final generation = _generations[profile] ?? 0;
    late final Future<Map<String, dynamic>> pending;
    pending = Future<Map<String, dynamic>>.microtask(() async {
      try {
        final response = await _read(profile);
        final observation = ConnectorInventoryObservation.decode(
          response,
          DateTime.now(),
        );
        if (!_disposed && generation == (_generations[profile] ?? 0)) {
          _observations[profile] = observation;
          notifyListeners();
        }
        return response;
      } catch (_) {
        if (!_disposed && generation == (_generations[profile] ?? 0)) {
          _observations.remove(profile);
          notifyListeners();
        }
        rethrow;
      } finally {
        if (identical(_pending[profile], pending)) _pending.remove(profile);
      }
    });
    _pending[profile] = pending;
    return pending;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

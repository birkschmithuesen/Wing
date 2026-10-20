import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/services/connection_manager.dart';
import 'porter_wake_api.dart';
import 'porter_wake_bridge.dart';
import 'porter_wake_dashboard.dart';
import 'porter_wake_device_id.dart';
import 'porter_wake_handler.dart';
import 'porter_wake_ledger.dart';

typedef PorterApiFactory = PorterWakeApi Function(SavedConnection connection);

/// The most recent session row (contract §6.6; Wing has no pinned chats).
String? mostRecentSessionId(List<Map<String, dynamic>> rows) {
  String? best;
  num bestTime = double.negativeInfinity;
  for (final row in rows) {
    final id = row['id'];
    final time = row['last_active'];
    if (id is String && time is num && time > bestTime) {
      best = id;
      bestTime = time;
    }
  }
  return best;
}

/// The optional porter wake module. A connection is active only after the
/// quiet-hours probe answered 200; 404/503 keep it inert for this session.
class PorterWakeModule extends ChangeNotifier {
  PorterWakeModule({
    required this.bridge,
    required this.deviceIds,
    required PorterNoticeLedger ledger,
    PorterApiFactory? apiFactory,
    PorterOpenProfile? openProfile,
    PorterShowNotice? showNotice,
  }) : _apiFactory = apiFactory ?? ((c) => PorterWakeApi(porterDashboardFor(c))) {
    handler = PorterWakeHandler(
      bridge: bridge,
      ledger: ledger,
      apiFor: (id) async => _active[id]?.api,
      openProfile: openProfile,
      showNotice: showNotice,
    );
  }

  final PorterWakeBridge bridge;
  final PorterDeviceIdStore deviceIds;
  final PorterApiFactory _apiFactory;
  late final PorterWakeHandler handler;
  final _active = <String, ({SavedConnection connection, PorterWakeApi api})>{};
  final _inert = <String>{};
  final _probing = <String>{};
  final _seen = <String>{};
  final _generation = <String, int>{};

  List<SavedConnection> get activeConnections =>
      [for (final entry in _active.values) entry.connection];

  PorterWakeApi? apiFor(String connectionId) => _active[connectionId]?.api;

  Future<void> start() => bridge.start(_onEvent, background: false);

  Future<void> sync(List<SavedConnection> connections) async {
    final ids = {for (final c in connections) c.id};
    for (final id in _probing.where((id) => !ids.contains(id)).toList()) {
      _invalidate(id);
    }
    final vanished = {
      ..._active.keys,
      ..._inert,
      ..._seen,
    }.where((id) => !ids.contains(id)).toList();
    _seen.addAll(ids);
    // Start the probes before awaiting revocations so a call that does not
    // revoke anything keeps its synchronous probe start.
    final revocations = [for (final id in vanished) _release(id)];
    final probes = [
      for (final c in connections)
        if (!_active.containsKey(c.id) && !_inert.contains(c.id) && _probing.add(c.id))
          _probe(c),
    ];
    await Future.wait([...revocations, ...probes]);
  }

  /// Marks any in-flight probe for [id] stale so its result is discarded.
  void _invalidate(String id) {
    _generation[id] = (_generation[id] ?? 0) + 1;
    _probing.remove(id);
  }

  Future<void> _probe(SavedConnection connection) async {
    final generation = _generation[connection.id] ?? 0;
    final api = _apiFactory(connection);
    final PorterProbe result;
    try {
      result = await api.probe();
    } finally {
      if ((_generation[connection.id] ?? 0) == generation) {
        _probing.remove(connection.id);
      }
    }
    if ((_generation[connection.id] ?? 0) != generation) {
      api.close();
      return;
    }
    switch (result) {
      case PorterProbe.active:
        _active[connection.id] = (connection: connection, api: api);
        notifyListeners();
        if (!await bridge.register(connection.id)) {
          debugPrint('porter_wake: no UnifiedPush distributor installed');
        }
      case PorterProbe.absent:
        api.close();
        _inert.add(connection.id);
        await bridge.unregister(connection.id);
      case PorterProbe.unknown:
        api.close();
    }
  }

  Future<void> refresh(SavedConnection connection) async {
    _invalidate(connection.id);
    _active.remove(connection.id)?.api.close();
    _inert.remove(connection.id);
    notifyListeners();
    await sync([...activeConnections, connection]);
  }

  Future<void> forget(SavedConnection connection) async {
    await _release(connection.id);
  }

  /// Revokes everything held for [id]: drops the entry first (so the native
  /// unregister event sends no second DELETE), removes the server device
  /// best-effort with the credentials still held, then unregisters natively.
  Future<void> _release(String id) async {
    _invalidate(id);
    _seen.remove(id);
    final entry = _active.remove(id);
    _inert.remove(id);
    if (entry != null) {
      notifyListeners();
      try {
        await entry.api
            .removeDevice(await deviceIds.read())
            .timeout(const Duration(seconds: 5));
      } on Object catch (error) {
        debugPrint('porter_wake: device removal failed (${error.runtimeType})');
      }
    }
    await bridge.unregister(id);
    entry?.api.close();
  }

  Future<bool> _onEvent(PorterBridgeEvent event) async {
    final api = _active[event.connectionId]?.api;
    switch (event) {
      case PorterPushEvent(:final bytes):
        await handler.onPush(event.connectionId, bytes);
        return true;
      case PorterInteractionEvent():
        return handler.onInteraction(event);
      case PorterEndpointEvent(:final url):
        if (api == null) return false;
        await api.registerDevice(
          deviceId: await deviceIds.read(),
          endpoint: url,
          label: await bridge.deviceLabel(),
        );
        return true;
      case PorterUnregisteredEvent():
        if (api == null) return false;
        await api.removeDevice(await deviceIds.read());
        return true;
      case PorterRegistrationFailedEvent():
        debugPrint('porter_wake: registration failed');
        return true;
    }
  }
}

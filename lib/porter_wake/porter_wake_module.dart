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
      apiFor: _resolveApi,
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
  final _known = <String, SavedConnection>{};
  final _inflight = <String, Future<void>>{};
  bool _synced = false;

  /// Endpoint/unregistration events whose connection has not been probed yet
  /// (native events replayed at startup arrive before the first sync).
  final _held = <String, List<PorterBridgeEvent>>{};

  List<SavedConnection> get activeConnections =>
      [for (final entry in _active.values) entry.connection];

  PorterWakeApi? apiFor(String connectionId) => _active[connectionId]?.api;

  Future<void> start() => bridge.start(_onEvent, background: false);

  Future<void> sync(List<SavedConnection> connections) async {
    final ids = {for (final c in connections) c.id};
    if (!_synced) _held.removeWhere((id, _) => !ids.contains(id));
    _synced = true;
    for (final id in _probing.where((id) => !ids.contains(id)).toList()) {
      _invalidate(id);
    }
    final vanished = {
      ..._active.keys,
      ..._inert,
      ..._seen,
    }.where((id) => !ids.contains(id)).toList();
    _seen.addAll(ids);
    for (final c in connections) {
      _known[c.id] = c;
    }
    // Start the probes before awaiting revocations so a call that does not
    // revoke anything keeps its synchronous probe start.
    final revocations = [for (final id in vanished) _release(id)];
    final probes = [
      for (final c in connections)
        if (!_active.containsKey(c.id) && !_inert.contains(c.id) && _probing.add(c.id))
          _startProbe(c),
    ];
    await Future.wait([...revocations, ...probes]);
  }

  /// Marks any in-flight probe for [id] stale so its result is discarded.
  void _invalidate(String id) {
    _generation[id] = (_generation[id] ?? 0) + 1;
    _probing.remove(id);
  }

  Future<void> _startProbe(SavedConnection connection) {
    late final Future<void> future;
    future = _probe(connection).whenComplete(() {
      if (identical(_inflight[connection.id], future)) _inflight.remove(connection.id);
    });
    _inflight[connection.id] = future;
    return future;
  }

  /// The API for [id]; re-probes a known connection whose startup probe failed
  /// transiently (neither active nor inert), awaiting a probe already running.
  Future<PorterWakeApi?> _resolveApi(String id) async {
    if (!_active.containsKey(id) && !_inert.contains(id)) {
      final known = _known[id];
      if (known != null) {
        try {
          if (_probing.add(id)) {
            await _startProbe(known);
          } else {
            await _inflight[id];
          }
        } on Object catch (error) {
          debugPrint('porter_wake: re-probe failed (${error.runtimeType})');
        }
      }
    }
    return _active[id]?.api;
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
        final held = _held.remove(connection.id) ?? const <PorterBridgeEvent>[];
        bool stale() => (_generation[connection.id] ?? 0) != generation;
        for (final event in held) {
          if (stale()) return;
          try {
            await _onEvent(event);
          } on Object catch (error) {
            debugPrint('porter_wake: held event failed (${error.runtimeType})');
          }
        }
        if (stale()) return;
        if (!await bridge.register(connection.id)) {
          debugPrint('porter_wake: no UnifiedPush distributor installed');
        }
      case PorterProbe.absent:
        api.close();
        _inert.add(connection.id);
        _held.remove(connection.id);
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
    // Always sync the full known set; a partial list would release connections
    // whose startup probe failed transiently.
    await sync([
      for (final c in _known.values)
        if (c.id != connection.id) c,
      connection,
    ]);
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
    _known.remove(id);
    _held.remove(id);
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

  /// Keeps an event for a connection whose probe has not resolved; inert
  /// connections drop it. A newer endpoint supersedes an older one.
  bool _hold(PorterBridgeEvent event) {
    final id = event.connectionId;
    if (_inert.contains(id) || (_synced && !_known.containsKey(id))) return false;
    final list = _held.putIfAbsent(id, () => []);
    if (event is PorterEndpointEvent) list.removeWhere((e) => e is PorterEndpointEvent);
    list.add(event);
    return true;
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
        if (api == null) return _hold(event);
        final deviceId = await deviceIds.read();
        final label = await bridge.deviceLabel();
        if (!identical(_active[event.connectionId]?.api, api)) return true;
        await api.registerDevice(deviceId: deviceId, endpoint: url, label: label);
        return true;
      case PorterUnregisteredEvent():
        if (api == null) return _hold(event);
        final deviceId = await deviceIds.read();
        if (!identical(_active[event.connectionId]?.api, api)) return true;
        await api.removeDevice(deviceId);
        return true;
      case PorterRegistrationFailedEvent():
        debugPrint('porter_wake: registration failed');
        return true;
    }
  }
}

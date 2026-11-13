import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/backend_update.dart';
import '../models/connection.dart';

/// Shared, durable update journal. Admission and server interpretation stay in
/// BackendUpdateController; this owner serializes one connection's saved state.
class BackendUpdateStore extends ChangeNotifier {
  BackendUpdateStore(this._preferences, this.key);

  final Future<SharedPreferences> _preferences;
  final String key;
  static final _connections = <String, BackendUpdateStore>{};

  factory BackendUpdateStore.forConnection(SavedConnection connection) {
    final origin = SavedConnection.joinBaseUrl(
      '${connection.useHttps ? 'https' : 'http'}://'
      '${connection.host.toLowerCase()}:${connection.dashboardPort}',
      connection.dashboardPrefix ?? '',
    );
    final key =
        'backend-update.${sha256.convert(utf8.encode(jsonEncode([connection.id, origin])))}';
    return _connections.putIfAbsent(
      key,
      () => BackendUpdateStore(SharedPreferences.getInstance(), key),
    );
  }

  bool _loaded = false;
  bool get loaded => _loaded;
  BackendUpdateAttempt? _current;
  // A received server identity remains known if its local save needs a retry.
  // The earlier request marker is already durable; this never permits replay.
  BackendUpdateAttempt? _acceptance;
  BackendUpdateAttempt? get current => _acceptance ?? _current;
  BackendUpdateReceipt? _completed;
  BackendUpdateReceipt? get completed => _completed;
  Future<void>? _tail;

  Future<T> _ordered<T>(Future<T> Function() action) {
    final next = (_tail ?? Future<void>.value()).then((_) => action());
    final settled = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _tail = settled;
    return next.whenComplete(() {
      if (identical(_tail, settled)) _tail = null;
    });
  }

  Future<void> _load() async {
    if (loaded) return;
    final raw = (await _preferences).getString(key);
    _current = raw == null
        ? null
        : BackendUpdateAttempt.decode(jsonDecode(raw) as Map<String, dynamic>);
    _loaded = true;
  }

  Future<void> load() => _ordered(_load);

  Future<void> _write(BackendUpdateAttempt? attempt) async {
    final preferences = await _preferences;
    final encoded = attempt == null ? null : jsonEncode(attempt.encode());
    try {
      final ok = attempt == null
          ? await preferences.remove(key)
          : await preferences.setString(key, encoded!);
      if (!ok) {
        await preferences.reload();
        if (preferences.getString(key) != encoded) {
          throw StateError('Update tracking was not saved');
        }
      }
    } catch (_) {
      // SharedPreferences may change its cache before a rejected platform write.
      await preferences.reload();
      final raw = preferences.getString(key);
      _current = raw == null
          ? null
          : BackendUpdateAttempt.decode(
              jsonDecode(raw) as Map<String, dynamic>,
            );
      notifyListeners();
      rethrow;
    }
    _current = attempt;
  }

  Future<bool> reserve(BackendUpdateAttempt attempt) => _ordered(() async {
    await _load();
    if (current != null) return false;
    _completed = null;
    await _write(attempt);
    notifyListeners();
    return true;
  });

  Future<void> accept(String requestId, String actionId, int pid) =>
      _ordered(() async {
        final attempt = current;
        if (attempt?.requestId != requestId) return;
        _acceptance = attempt!.accepted(actionId, pid);
        notifyListeners();
        await _persistAcceptance();
      });

  Future<void> _persistAcceptance() async {
    final acceptance = _acceptance;
    if (acceptance == null) return;
    await _write(acceptance);
    _acceptance = null;
  }

  Future<void> persistAcceptance() => _ordered(_persistAcceptance);

  Future<void> clear(String requestId, {BackendUpdateReceipt? receipt}) =>
      _ordered(() async {
        if (current?.requestId != requestId) return;
        // Publish completion only after durable removal succeeds.
        await _write(null);
        _acceptance = null;
        _completed = receipt;
        notifyListeners();
      });
}

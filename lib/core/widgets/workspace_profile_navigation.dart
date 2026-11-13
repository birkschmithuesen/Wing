import 'package:flutter/material.dart';

/// A successful, explicit picker selection rebuilds open profile routes. Each
/// replacement captures a fresh immutable owner; in-flight work keeps the old one.
class WorkspaceProfileNavigation extends ChangeNotifier {
  final _routes = <ModalRoute<dynamic>>{};
  final _leaveGuards = <ModalRoute<dynamic>, Future<bool> Function()>{};
  bool _preparing = false;
  String? profileName;
  bool switching = false;
  int revision = 0;
  bool _disposed = false;

  void register(ModalRoute<dynamic> route) => _routes.add(route);
  void unregister(ModalRoute<dynamic> route) {
    _routes.remove(route);
    _leaveGuards.remove(route);
  }

  void registerLeaveGuard(
    ModalRoute<dynamic> route,
    Future<bool> Function() guard,
  ) => _leaveGuards[route] = guard;
  void unregisterLeaveGuard(ModalRoute<dynamic> route) =>
      _leaveGuards.remove(route);

  Future<bool> _confirmLeave() async {
    final approved = <ModalRoute<dynamic>>{};
    for (final route in _routes.toList().reversed) {
      if (!route.isActive ||
          route.popDisposition != RoutePopDisposition.doNotPop) {
        continue;
      }
      final guard = _leaveGuards[route];
      if (guard == null || !await guard() || _disposed) return false;
      approved.add(route);
    }
    // A different route may have opened while a confirmation was shown.
    return _routes.every(
      (route) =>
          !route.isActive ||
          route.popDisposition != RoutePopDisposition.doNotPop ||
          approved.contains(route),
    );
  }

  /// Registered editors can ask to discard. Other blocking routes must finish
  /// their own operation before workspace replacement can be requested.
  bool get canRequestSwitch => _routes.every(
    (route) =>
        !route.isActive ||
        route.popDisposition != RoutePopDisposition.doNotPop ||
        _leaveGuards.containsKey(route),
  );

  Future<bool> switchTo(String name, Future<bool> Function() select) async {
    if (switching || _preparing) return false;
    _preparing = true;
    try {
      if (!await _confirmLeave() || _disposed) return false;
      switching = true;
      notifyListeners();
      if (!await select() || _disposed) return false;
      profileName = name;
      revision++;
      return true;
    } finally {
      switching = false;
      _preparing = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/health_alert.dart';
import '../models/host_thresholds.dart';
import 'health_alert_settings_store.dart';

/// Device settings owner. Edits compose against the latest selection and
/// autosave serially. Only durable settings are published to the alert evaluator.
/// Pending writes belong to this owner, independent of the settings route.
class HealthAlertSettingsSession extends ChangeNotifier {
  HealthAlertSettingsSession(this._store) {
    try {
      _settings = _store.read();
    } catch (_) {
      _settings = HealthAlertSettings(enabled: false);
      _error = 'Saved alert settings could not be read. Alerts are disabled.';
    }
    _value = _settings;
    if (_store.needsMigration) unawaited(retry());
  }
  final HealthAlertSettingsStore _store;
  late HealthAlertSettings _settings, _value;

  /// Confirmed policy consumed by collection and notification owners.
  HealthAlertSettings get settings => _settings;

  /// Latest selection displayed by settings controls, including pending edits.
  HealthAlertSettings get value => _value;
  String? _error;
  String? get error => _error;
  bool _closed = false;
  Completer<bool>? _pending;
  bool get saving => _pending != null;

  Future<bool> update(
    HealthAlertSettings Function(HealthAlertSettings current) change,
  ) {
    if (_closed) return Future.value(false);
    _value = change(_value);
    _error = null;
    if (_pending case final pending?) {
      notifyListeners();
      return pending.future;
    }
    return retry();
  }

  Future<bool> updateRule(
    HostMetric metric,
    HealthAlertRule Function(HealthAlertRule current) change,
  ) => update(
    (current) => current.copyWith(
      rules: {...current.rules, metric: change(current.rules[metric]!)},
    ),
  );

  Future<bool> retry() {
    if (_closed) return Future.value(false);
    if (_pending case final pending?) return pending.future;
    final pending = _pending = Completer<bool>();
    _error = null;
    notifyListeners();
    unawaited(_persist(pending));
    return pending.future;
  }

  Future<void> _persist(Completer<bool> pending) async {
    var saved = false;
    try {
      while (!_closed) {
        final target = _value;
        await _store.write(target);
        if (_closed) break;
        _settings = target;
        if (identical(target, _value)) {
          saved = true;
          break;
        }
        notifyListeners();
      }
    } catch (_) {
      if (!_closed) {
        _error =
            'Could not save alert settings. Previous settings remain active.';
      }
    } finally {
      _pending = null;
      pending.complete(saved);
      if (!_closed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}

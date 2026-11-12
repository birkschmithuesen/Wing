import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'app_preferences.dart';
import 'connection_diagnostics.dart';

enum BackgroundMonitoringState {
  unsupported,
  disabled,
  idle,
  permissionRequired,
  waitingForApp,
  active,
  batteryRestricted,
  failed,
}

/// Android retains the same Flutter engine and its authenticated event clients.
/// Serializing reconciliation prevents a slow start from undoing a later stop.
class BackgroundMonitoringService {
  static const channel = MethodChannel(
    'com.tarkilhk.wing/background_monitoring',
  );
  final AppPreferences preferences;
  final bool Function() hasActiveChats;
  final Future<bool?> Function() notificationsEnabled;
  final bool supported;
  final Map<String, String> Function()? summary;
  final state = ValueNotifier(BackgroundMonitoringState.idle);
  Future<void> _tail = Future.value();
  bool _disposed = false;
  bool _startupBatteryHandled = false;

  BackgroundMonitoringService({
    required this.preferences,
    required this.hasActiveChats,
    required this.notificationsEnabled,
    bool? supported,
    this.summary,
  }) : supported =
           supported ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  Future<void> sync() {
    _tail = _tail.then((_) => _sync());
    return _tail;
  }

  /// Ask once per app startup when the OS exemption is absent, even with no
  /// active chats. A backgrounded or disposed app cannot open the system prompt.
  Future<void> requestStartupBatteryExemption({
    required bool Function() canRequest,
  }) {
    _tail = _tail.then((_) async {
      if (_disposed || !supported || _startupBatteryHandled || !canRequest()) {
        return;
      }
      try {
        final unrestricted = await channel.invokeMethod<bool>(
          'batteryUnrestricted',
        );
        if (_disposed || !canRequest()) return;
        if (unrestricted == null) {
          throw const FormatException('Missing battery exemption status');
        }
        // Set before opening Android's dialog: its resume must not ask again.
        _startupBatteryHandled = true;
        if (!unrestricted) await openBatterySettings();
      } catch (error, stack) {
        _startupBatteryHandled = true;
        logConnectionDiagnostic(
          'battery.startup_request_failed',
          error: error,
          stackTrace: stack,
        );
      }
    });
    return _tail;
  }

  Future<void> _sync() async {
    if (_disposed) return;
    if (!supported) {
      state.value = BackgroundMonitoringState.unsupported;
      return;
    }
    try {
      final enabled =
          preferences.current.completedNotificationsAllowed ||
          preferences.current.attentionNotificationsAllowed;
      final activeChats = hasActiveChats();
      final allowed = await notificationsEnabled() != false;
      if (_disposed) return;
      if (!enabled || !activeChats || !allowed) {
        await channel.invokeMethod<void>('stop');
        if (_disposed) return;
        state.value = !enabled
            ? BackgroundMonitoringState.disabled
            : !allowed
            ? BackgroundMonitoringState.permissionRequired
            : BackgroundMonitoringState.idle;
        return;
      }
      final result = await channel.invokeMapMethod<String, dynamic>(
        'start',
        summary?.call(),
      );
      if (_disposed) return;
      state.value = result?['running'] != true
          ? BackgroundMonitoringState.waitingForApp
          : result?['batteryUnrestricted'] == true
          ? BackgroundMonitoringState.active
          : BackgroundMonitoringState.batteryRestricted;
    } catch (_) {
      if (!_disposed) state.value = BackgroundMonitoringState.failed;
    }
  }

  Future<void> openBatterySettings() async {
    if (supported) await channel.invokeMethod<void>('openBatterySettings');
  }

  void dispose() {
    _disposed = true;
    if (supported) {
      unawaited(
        _tail.then((_) async {
          try {
            await channel.invokeMethod<void>('stop');
          } catch (_) {
            // Engine teardown can remove the platform channel first.
          }
        }),
      );
    }
    state.dispose();
  }
}

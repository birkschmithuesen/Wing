import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/connection_manager.dart';
import 'porter_wake_api.dart';
import 'porter_wake_bridge.dart';
import 'porter_wake_dashboard.dart';
import 'porter_wake_handler.dart';
import 'porter_wake_ledger.dart';

/// Runs in a headless engine started by PorterHeadless while Wing is not
/// running: handles queued pushes and taps, then lets the engine go.
@pragma('vm:entry-point')
Future<void> porterWakeBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final bridge = MethodChannelPorterWakeBridge();
  try {
    final prefs = await SharedPreferences.getInstance();
    final connections = await ConnectionManager.create(prefs);
    final handler = PorterWakeHandler(
      bridge: bridge,
      ledger: PorterNoticeLedger(prefs),
      apiFor: (id) async {
        final connection = (await connections.loadConnectionsWithSecrets())
            .where((c) => c.id == id)
            .firstOrNull;
        return connection == null ? null : PorterWakeApi(porterDashboardFor(connection));
      },
    );
    await bridge.start((event) async {
      switch (event) {
        case PorterPushEvent(:final bytes):
          await handler.onPush(event.connectionId, bytes);
          return true;
        case PorterInteractionEvent():
          return handler.onInteraction(event);
        default:
          return false;
      }
    }, background: true);
  } on Object catch (error) {
    debugPrint('porter_wake: background run failed (${error.runtimeType})');
  } finally {
    await bridge.finished();
  }
}

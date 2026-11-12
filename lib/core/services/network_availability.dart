import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'connection_diagnostics.dart';

/// A device-network event is a reason to retry, never proof of server access.
class NetworkAvailability {
  static const _channel = MethodChannel('com.tarkilhk.wing/network');
  static final _restored = ValueNotifier<int>(0);

  /// Shared with visible read-only screens; the app owns the native handler.
  static Listenable get restored => _restored;
  void start(void Function() onAvailable, void Function() onUnavailable) {
    _channel.setMethodCallHandler((call) async {
      logConnectionDiagnostic('network.${call.method}');
      if (call.method == 'available') {
        onAvailable();
        _restored.value++;
      }
      if (call.method == 'unavailable') onUnavailable();
    });
  }

  void dispose() => _channel.setMethodCallHandler(null);
}

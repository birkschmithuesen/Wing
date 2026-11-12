import 'package:flutter/services.dart';

/// Native window bars are independent of the remote desktop/control lease.
class BotScreenWindow {
  static const channel = MethodChannel('com.tarkilhk.wing/bot_screen');
  static Future<void> setImmersive(bool enabled) =>
      channel.invokeMethod<void>('setImmersive', enabled);
}

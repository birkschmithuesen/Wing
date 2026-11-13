import 'package:flutter/services.dart';

/// Opens an email draft chooser. Success means handoff, never delivery.
class EmailComposer {
  static const channel = MethodChannel('com.tarkilhk.wing/email');

  static bool accepts(String href) => Uri.tryParse(href)?.scheme == 'mailto';

  static Future<bool> open(String href) async {
    if (!accepts(href)) return false;
    try {
      return await channel.invokeMethod<bool>('compose', href) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

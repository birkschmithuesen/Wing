import 'package:flutter/widgets.dart';

import '../models/app_preferences.dart';
import '../services/app_preferences.dart';
import '../services/web_preview.dart';

/// Reads the confirmed device preference when a link is opened.
class WebLinkScope extends InheritedWidget {
  const WebLinkScope({
    super.key,
    required this.preferences,
    required super.child,
  });

  final AppPreferences preferences;

  static WebLinkDestination? destinationOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<WebLinkScope>()
      ?.preferences
      .current
      .preferredWebLinkDestination;

  static Future<bool> open(BuildContext context, Uri uri) async {
    final destination = destinationOf(context);
    return destination != null && await openWebLink(uri, destination);
  }

  @override
  bool updateShouldNotify(WebLinkScope oldWidget) =>
      !identical(preferences, oldWidget.preferences);
}

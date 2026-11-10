import 'package:url_launcher/url_launcher.dart';

import '../models/app_preferences.dart';

Uri? externalWebLink(String href) {
  final uri = Uri.tryParse(href);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

/// Launches only the requested destination, without Hermes credentials.
Future<bool> openWebLink(Uri uri, WebLinkDestination destination) async {
  if (externalWebLink(uri.toString()) == null) return false;
  try {
    return switch (destination) {
      WebLinkDestination.wing =>
        await supportsLaunchMode(LaunchMode.inAppBrowserView) &&
            await launchUrl(
              uri,
              mode: LaunchMode.inAppBrowserView,
              browserConfiguration: const BrowserConfiguration(showTitle: true),
            ),
      WebLinkDestination.externalBrowser => await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      ),
    };
  } catch (_) {
    return false;
  }
}

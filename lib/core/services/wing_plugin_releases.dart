import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/wing_plugin.dart';

/// Safe release-check feedback, without response bodies or transport details.
final class WingPluginReleaseFailure implements Exception {
  const WingPluginReleaseFailure(this.message);
  final String message;
}

/// Public release discovery never receives a backend credential or session.
Future<WingPluginRelease> readWingPluginRelease() async {
  final client = http.Client();
  try {
    final response = await client
        .get(
          Uri.parse(
            'https://api.github.com/repos/tarkilhk/wing-hermes-plugin/releases/latest',
          ),
          headers: {'Accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      final status = response.statusCode;
      final limited =
          status == 429 ||
          (status == 403 &&
              (response.headers['x-ratelimit-remaining'] == '0' ||
                  response.headers.containsKey('retry-after')));
      throw WingPluginReleaseFailure(
        limited
            ? 'GitHub is limiting release checks. Try again later.'
            : status == 404
            ? 'The Wing plugin release could not be found on GitHub.'
            : status >= 500
            ? 'GitHub is unavailable (HTTP $status). Try again later.'
            : 'GitHub refused the release check (HTTP $status).',
      );
    }
    return WingPluginRelease.decode(jsonDecode(response.body));
  } on TimeoutException {
    throw const WingPluginReleaseFailure(
      'GitHub did not respond in time. Refresh to try again.',
    );
  } on http.ClientException {
    throw const WingPluginReleaseFailure(
      'Could not connect to GitHub. Check your connection and refresh.',
    );
  } on FormatException {
    throw const WingPluginReleaseFailure(
      'GitHub returned invalid Wing release information.',
    );
  } finally {
    client.close();
  }
}

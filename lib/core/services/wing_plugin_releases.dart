import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/wing_plugin.dart';

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
      throw StateError('GitHub release check failed (${response.statusCode}).');
    }
    return WingPluginRelease.decode(jsonDecode(response.body));
  } finally {
    client.close();
  }
}

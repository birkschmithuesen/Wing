import 'dart:convert';
import 'dart:io';

import 'package:wing/core/services/connection_manager.dart';

/// Reads private test credentials at runtime. Errors never include their input.
Future<SavedConnection> readExistingBackendConnection({
  required String url,
  required String loginFile,
  required String id,
}) async {
  final Uri address;
  try {
    address = Uri.parse(url);
  } on FormatException {
    throw StateError('Supply a valid final dashboard URL.');
  }
  if (address.host.isEmpty ||
      address.userInfo.isNotEmpty ||
      address.query.isNotEmpty ||
      address.fragment.isNotEmpty ||
      !{'http', 'https'}.contains(address.scheme)) {
    throw StateError(
      'Use the final dashboard URL without credentials or a query.',
    );
  }
  final Object? login;
  try {
    login = jsonDecode(await File(loginFile).readAsString());
  } on FormatException {
    throw StateError('The credential file must contain valid JSON.');
  }
  if (login is! Map) {
    throw StateError('The credential file must be an object.');
  }
  final username = login['username'];
  final password = login['password'];
  if (username is! String ||
      username.isEmpty ||
      password is! String ||
      password.isEmpty) {
    throw StateError('The credential file needs a username and password.');
  }
  return SavedConnection(
    id: id,
    label: 'Existing Hermes',
    host: address.host,
    port: address.port,
    dashboardPortOverride: address.port,
    useHttps: address.scheme == 'https',
    dashboardPrefix: address.path,
    apiKey: '',
    dashboardUsername: username,
    dashboardPassword: password,
  );
}

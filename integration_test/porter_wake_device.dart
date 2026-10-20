/// Isolated porter wake QA entry point. Build with -PnotificationQa=true and
/// -t integration_test/porter_wake_device.dart; never a distributed build.
/// The dashboard is fake and loopback-only; data are contract examples.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/porter_wake/porter_wake_bridge.dart';
import 'package:wing/porter_wake/porter_wake_device_id.dart';
import 'package:wing/porter_wake/porter_wake_ledger.dart';
import 'package:wing/porter_wake/porter_wake_module.dart';

import '../test/porter_wake/porter_wake_fixtures.dart';
import '../test/profile_connection_identity_test.dart' show MemoryIdentityStore;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final recorded = <Map<String, Object?>>[];
  final dashboard = await HttpServer.bind(InternetAddress.loopbackIPv4, 18767);
  dashboard.listen((request) async {
    final path = request.uri.path;
    final body = await utf8.decoder.bind(request).join();
    if (path.startsWith('/api/plugins/porter_wake')) {
      recorded.add({'method': request.method, 'path': path, 'body': body});
    }
    Object? reply;
    if (path == '/auth/password-login') {
      request.response.headers.add('set-cookie', 'hermes_session_at=qa; Path=/');
      reply = {};
    } else if (path.endsWith('/settings/quiet-hours')) {
      reply = {'enabled': true, 'from': '22:00', 'to': '08:00', 'timezone': 'Europe/Berlin'};
    } else if (path.endsWith('/feedback')) {
      reply = {'applied': true, 'result': {}};
    } else if (path.contains('/push/devices')) {
      reply = {'device_id': 'qa', 'registered': '2026-10-19T06:00:00.000Z', 'replaced': false};
    } else {
      for (var i = 0; i < porterNoticeIds.length; i++) {
        if (path.endsWith('/notices/${porterNoticeIds[i]}')) reply = jsonDecode(porterExamples[i]);
      }
    }
    request.response.statusCode = reply == null ? 404 : 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(reply ?? {'error': 'unknown notice'}));
    await request.response.close();
  });

  final prefs = await SharedPreferences.getInstance();
  final connection = SavedConnection(
    id: 'porter-qa',
    label: 'Porter QA',
    host: '127.0.0.1',
    port: 1,
    apiKey: '',
    dashboardPortOverride: 18767,
    dashboardUsername: 'qa',
    dashboardPassword: 'qa',
  );
  final module = PorterWakeModule(
    bridge: MethodChannelPorterWakeBridge(),
    deviceIds: PorterDeviceIdStore(store: MemoryIdentityStore()),
    ledger: PorterNoticeLedger(prefs),
    openProfile: (_, _) async {},
    showNotice: (_, _) async {},
  );
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('Porter QA')))));
  await module.start();
  await module.sync([connection]);

  final control = await HttpServer.bind(InternetAddress.loopbackIPv4, 18768);
  await for (final request in control) {
    switch (request.uri.path) {
      case '/push':
        final id = request.uri.queryParameters['notice']!;
        await module.handler.onPush(
          'porter-qa',
          utf8.encode(jsonEncode({'v': 1, 'type': 'porter_wake', 'notice_id': id})),
        );
      case '/reset':
        await prefs.remove(PorterNoticeLedger.key);
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'requests': recorded}));
    await request.response.close();
  }
}

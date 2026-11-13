// Isolated native share QA entry point. Never imported by lib/ or release.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('com.tarkilhk.wing/share');
const _target = <String, String>{
  'connection': 'share-intake-qa',
  'connection_identity': 'share-intake-qa',
  'profile': 'synthetic-profile',
  'session': 'synthetic-session',
};

Future<void> main() async {
  if (kReleaseMode || !const bool.fromEnvironment('WING_NATIVE_SHARE_QA')) {
    throw StateError('Enable the isolated native share QA entry point');
  }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Native share QA'))),
    ),
  );
  await _channel.invokeMethod<Object?>('getPendingShare');
  var inFlight = 0;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 19307);
  server.listen((request) async {
    if (inFlight >= 8 || request.method != 'GET') {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    inFlight++;
    try {
      Object? value;
      switch (request.uri.path) {
        case '/pending':
          value = await _channel.invokeMethod<Object?>('getPendingShare');
        case '/ack':
          final id = request.uri.queryParameters['id'] ?? '';
          if (!RegExp(
            r'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$',
          ).hasMatch(id)) {
            throw const FormatException('Synthetic share ID required');
          }
          value = await _channel.invokeMethod<Object?>('acknowledgeShare', {
            'id': id,
          });
        case '/camera':
          value = await _channel.invokeMethod<Object?>('capturePhoto', {
            'target': _target,
          });
        default:
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'ok': true, 'value': value}));
    } on PlatformException catch (error) {
      request.response.write(jsonEncode({'ok': false, 'code': error.code}));
    } catch (_) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('{"ok":false}');
    } finally {
      inFlight--;
      await request.response.close();
    }
  });
}

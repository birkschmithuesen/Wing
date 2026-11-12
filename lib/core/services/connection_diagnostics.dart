import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Internal device console only, including release builds. Never use response
/// bodies, exception prose, URLs, credentials or request parameters as details.
/// Exception prose often embeds authenticated URLs or server-returned content.
void logConnectionDiagnostic(
  String event, {
  Map<String, Object?> details = const {},
  Object? error,
  StackTrace? stackTrace,
}) {
  final causes = <Map<String, Object?>>[];
  var cause = error;
  for (var depth = 0; cause != null && depth < 4; depth++) {
    causes.add({
      'type': cause.runtimeType.toString(),
      if (cause is TimeoutException && cause.duration != null)
        'timeout_ms': cause.duration!.inMilliseconds,
      if (cause is FormatException && cause.offset != null)
        'offset': cause.offset,
      if (cause is SocketException && cause.osError != null)
        'os_error_code': cause.osError!.errorCode,
      if (cause is TlsException && cause.osError != null)
        'os_error_code': cause.osError!.errorCode,
    });
    cause = cause is WebSocketChannelException ? cause.inner : null;
  }
  // Release builds with split debug info emit PC offsets instead of names.
  // Keep only recognized frame/base fields for later symbolication.
  final frames = <String>[];
  final bases = <String>[];
  for (final line in stackTrace?.toString().split('\n') ?? const <String>[]) {
    final named = RegExp(
      r'^#\d+\s+[\w<>.$]+\s+\((?:package:wing/|dart:)[^?\s)]+\)$',
    ).hasMatch(line);
    final pc = RegExp(
      r'^\s*#\d+\s+abs\s+[0-9a-fx]+\s+virt\s+[0-9a-fx]+',
      caseSensitive: false,
    ).firstMatch(line);
    final base = RegExp(
      r'^(?:isolate_dso_base|vm_dso_base|isolate_instructions|vm_instructions):\s*[0-9a-fx]+$',
      caseSensitive: false,
    ).hasMatch(line);
    if (frames.length < 10 && (named || pc != null)) {
      frames.add(named ? line : pc!.group(0)!.trim());
    }
    if (bases.length < 4 && base) bases.add(line);
  }
  try {
    debugPrint(
      '[WingConnection] ${jsonEncode({'time': DateTime.now().toUtc().toIso8601String(), 'event': event, ...details, if (causes.isNotEmpty) 'causes': causes, if (frames.isNotEmpty) 'stack': frames, if (bases.isNotEmpty) 'stack_bases': bases})}',
    );
  } catch (_) {
    // Diagnostics must never change transport/recovery behavior.
  }
}

/// Endpoint family only: IDs, query values and authentication URLs are omitted.
String connectionDiagnosticEndpoint(String endpoint) {
  final path = Uri.tryParse(endpoint)?.path ?? '';
  final segments = path.split('/').where((part) => part.isNotEmpty).toList();
  if (segments.isEmpty) return 'unknown';
  if (segments.first == 'api') segments.removeAt(0);
  if (segments.isEmpty) return 'unknown';
  final family = segments.first;
  return {
        'profiles',
        'sessions',
        'projects',
        'auth',
        'gateway',
        'ws',
        'desktop',
        'session',
        'model',
        'models',
        'logs',
        'fs',
      }.contains(family)
      ? '$family${segments.length > 1 ? '/…' : ''}'
      : 'other';
}

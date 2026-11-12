import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/file_open_error_message.dart';
import 'package:wing/core/services/platform_share.dart';
import 'package:http/http.dart' as http;

void main() {
  test('share admission explains the active sheet without blaming Hermes', () {
    const busy = PlatformShareBusy();
    expect(
      fileOpenErrorMessage(busy),
      'Finish the current share sheet, then try again.',
    );
    expect(canRetryFileOpen(busy), isFalse);
  });

  test('classifies file-open failures without exposing exception details', () {
    expect(
      fileOpenErrorMessage(const DashboardHttpException(400, 'private/path')),
      'Hermes rejected this file path. Ask Hermes for the full path or a new link.',
    );
    expect(
      fileOpenErrorMessage(const DashboardHttpException(401, 'private/path')),
      'Hermes could not authenticate this session. Reconnect, then try again.',
    );
    expect(
      fileOpenErrorMessage(const DashboardHttpException(500, 'private/path')),
      'Hermes could not open this file right now. Try again shortly.',
    );
    expect(
      fileOpenErrorMessage(TimeoutException('private timeout details')),
      'Hermes could not be reached. Check your connection, then try again.',
    );
    expect(
      fileOpenErrorMessage(const SocketException('private socket details')),
      'Hermes could not be reached. Check your connection, then try again.',
    );
    expect(
      fileOpenErrorMessage(
        http.ClientException('private client details', Uri.parse('https://x')),
      ),
      'Hermes could not be reached. Check your connection, then try again.',
    );
    expect(
      fileOpenErrorMessage(StateError('private fallback details')),
      'This file could not be opened. Try again, or refresh the chat.',
    );
  });

  test('offers retry only for failures that may clear without a new file', () {
    expect(
      canRetryFileOpen(const DashboardHttpException(400, 'private/path')),
      isFalse,
    );
    expect(
      canRetryFileOpen(const DashboardHttpException(403, 'private/path')),
      isFalse,
    );
    expect(
      canRetryFileOpen(const DashboardHttpException(404, 'private/path')),
      isFalse,
    );
    expect(
      canRetryFileOpen(const DashboardHttpException(401, 'private/path')),
      isTrue,
    );
    expect(
      canRetryFileOpen(const DashboardHttpException(503, 'private/path')),
      isTrue,
    );
    expect(canRetryFileOpen(TimeoutException('private details')), isTrue);
  });
}

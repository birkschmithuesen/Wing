import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'connection_manager.dart';
import 'platform_share.dart';

String fileOpenErrorMessage(Object error) {
  if (error is PlatformShareBusy) return error.message;
  if (error is DashboardHttpException) {
    return switch (error.statusCode) {
      400 =>
        'Hermes rejected this file path. Ask Hermes for the full path or a new link.',
      401 =>
        'Hermes could not authenticate this session. Reconnect, then try again.',
      403 =>
        'Hermes denied access to this file. Ask Hermes for an accessible copy.',
      404 =>
        'Hermes could not find this file, or its file service is unavailable. Ask Hermes for a fresh download link.',
      >= 500 && <= 599 =>
        'Hermes could not open this file right now. Try again shortly.',
      _ => 'This file could not be opened. Try again, or refresh the chat.',
    };
  }
  if (error is TimeoutException ||
      error is SocketException ||
      error is http.ClientException) {
    return 'Hermes could not be reached. Check your connection, then try again.';
  }
  return 'This file could not be opened. Try again, or refresh the chat.';
}

bool canRetryFileOpen(Object error) {
  if (error is DashboardHttpException) {
    return error.statusCode == 401 ||
        error.statusCode >= 500 && error.statusCode <= 599;
  }
  return error is TimeoutException ||
      error is SocketException ||
      error is http.ClientException;
}

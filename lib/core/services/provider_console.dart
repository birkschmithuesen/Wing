import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/hermes_profile.dart';
import '../models/provider_recovery.dart';
import 'authenticated_web_socket.dart';
import 'connection_manager.dart';

typedef ProviderConsoleCommand =
    Future<String> Function(
      String profile,
      String command, {
      bool confirm,
      required bool Function() canDispatch,
      required void Function() onDispatched,
    });
typedef ProviderConsoleConnect =
    Future<WebSocketChannel> Function(String profile);

/// One bounded stock-console exchange. No shell, reconnection or write retries.
/// Callers authorize a specific command; confirmation must echo that command.
class ProviderConsole {
  ProviderConsole(this.connect, {this.timeout = const Duration(seconds: 80)});
  final ProviderConsoleConnect connect;
  final Duration timeout;
  final Set<WebSocketChannel> _channels = {};
  bool _closed = false;

  factory ProviderConsole.dashboard(
    DashboardClient dashboard,
    Map<String, String> headers,
  ) => ProviderConsole((profile) async {
    final credentials = await dashboard.gatewayCredentials();
    final base = Uri.parse(dashboard.baseUrl);
    final uri = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path}/api/console',
      queryParameters: {
        'profile': profile,
        if (credentials.ticket != null) 'ticket': credentials.ticket!,
        if (credentials.token != null) 'token': credentials.token!,
      },
    );
    final channel = connectAuthenticatedWebSocket(
      uri,
      headers: headers,
      connectTimeout: const Duration(seconds: 15),
    );
    try {
      await channel.ready;
      return channel;
    } catch (_) {
      unawaited(channel.sink.close());
      rethrow;
    }
  });

  Future<String> run(
    String profile,
    String command, {
    bool confirm = false,
    required bool Function() canDispatch,
    required void Function() onDispatched,
  }) async {
    if (_closed ||
        !canDispatch() ||
        !HermesProfile.isCanonicalName(profile) ||
        profile == 'current') {
      throw const ProviderRecoveryFailure(
        'The selected profile is no longer available.',
      );
    }
    final read = RegExp(
      r'^auth list (anthropic|nous|openai-codex|xai-oauth)$',
    ).hasMatch(command);
    final write = RegExp(
      r'^auth refresh (anthropic|nous|openai-codex|xai-oauth) [a-f0-9]{6}$',
    ).hasMatch(command);
    if ((!read && !write) || write != confirm) {
      throw ArgumentError('Unsupported credential command');
    }
    WebSocketChannel? channel;
    StreamSubscription<dynamic>? subscription;
    final completed = Completer<String>();
    var ready = false;
    var confirmed = false;
    var sawConfirmation = false;
    var sawError = false;
    var finished = false;
    final output = StringBuffer();
    void fail(String message) {
      if (!completed.isCompleted) {
        completed.completeError(ProviderRecoveryFailure(message));
      }
    }

    try {
      channel = await connect(profile)
          .then((connected) {
            if (finished || _closed) unawaited(connected.sink.close());
            return connected;
          })
          .timeout(const Duration(seconds: 20));
      if (_closed || !canDispatch()) {
        throw const ProviderRecoveryFailure(
          'The connection was closed. Check status before retrying.',
        );
      }
      _channels.add(channel);
      final socket = channel;
      subscription = socket.stream.listen(
        (raw) {
          if (completed.isCompleted) return;
          try {
            if (raw is! String || raw.length > 100000) {
              throw const FormatException();
            }
            final frame = jsonDecode(raw);
            if (frame is! Map) throw const FormatException();
            final type = frame['type'];
            if (type == 'ready') {
              if (ready || frame['profile'] != profile) {
                throw const FormatException();
              }
              if (_closed || !canDispatch()) {
                fail('The selected recovery route was closed before dispatch.');
                return;
              }
              ready = true;
              socket.sink.add(jsonEncode({'type': 'input', 'line': command}));
              return;
            }
            if (type == 'error') {
              sawError = true;
              if (!ready) {
                fail(
                  'The server could not open credential recovery for this profile.',
                );
              }
              return;
            }
            if (!ready || frame['command'] != command) {
              throw const FormatException();
            }
            if (type == 'output') {
              if (frame['data'] is! String) throw const FormatException();
              output.write(frame['data']);
              if (output.length > 50000) throw const FormatException();
            } else if (type == 'confirm_required') {
              if (!confirm || confirmed || sawConfirmation) {
                throw const FormatException();
              }
              sawConfirmation = true;
            } else if (type == 'complete') {
              if (frame['status'] == 'confirm_required') {
                if (!sawConfirmation || confirmed || !confirm) {
                  throw const FormatException();
                }
                if (_closed || !canDispatch()) {
                  fail(
                    'The selected recovery route was closed before renewal.',
                  );
                  return;
                }
                confirmed = true;
                onDispatched();
                socket.sink.add(
                  jsonEncode({'type': 'confirm', 'command': command}),
                );
              } else if (frame['status'] == 'ok' &&
                  !sawError &&
                  (!write || confirmed)) {
                completed.complete(output.toString());
              } else {
                fail(
                  write
                      ? 'Hermes could not confirm renewal. Check status, or sign in again.'
                      : 'Hermes could not list credentials for this profile.',
                );
              }
            } else {
              throw const FormatException();
            }
          } catch (_) {
            fail(
              'The credential response could not be verified. Check status before retrying.',
            );
          }
        },
        onError: (Object _) => fail(
          'Credential recovery lost its connection. Check status before retrying.',
        ),
        onDone: () => fail(
          'Credential recovery closed before completion. Check status before retrying.',
        ),
      );
      return await completed.future.timeout(timeout);
    } on ProviderRecoveryFailure {
      rethrow;
    } catch (_) {
      throw const ProviderRecoveryFailure(
        'Credential recovery could not be confirmed. Check the connection and status before retrying.',
      );
    } finally {
      finished = true;
      await subscription?.cancel();
      if (channel != null) {
        _channels.remove(channel);
        unawaited(channel.sink.close());
      }
    }
  }

  void close() {
    _closed = true;
    for (final channel in _channels) {
      unawaited(channel.sink.close());
    }
    _channels.clear();
  }
}

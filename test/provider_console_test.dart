import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:wing/core/models/provider_recovery.dart';
import 'package:wing/core/services/provider_console.dart';

class _Channel implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  void Function(Map<String, dynamic>)? onSend;
  late final _Sink _sink = _Sink(this);
  void frame(Map<String, dynamic> value) => incoming.add(jsonEncode(value));
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  WebSocketSink get sink => _sink;
  @override
  Future<void> get ready async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sink implements WebSocketSink {
  _Sink(this.channel);
  final _Channel channel;
  @override
  void add(dynamic data) {
    final value = Map<String, dynamic>.from(jsonDecode(data as String) as Map);
    channel.sent.add(value);
    channel.onSend?.call(value);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    unawaited(channel.incoming.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('scoped ready and exact confirmation execute a mutation once', () async {
    final channel = _Channel();
    final console = ProviderConsole((profile) async {
      expect(profile, 'personal');
      channel.frame({'type': 'ready', 'profile': profile});
      return channel;
    });
    const command = 'auth refresh anthropic 333ccc';
    channel.onSend = (frame) {
      if (frame['type'] == 'input') {
        channel.frame({'type': 'confirm_required', 'command': command});
        channel.frame({
          'type': 'complete',
          'command': command,
          'status': 'confirm_required',
        });
      } else {
        expect(frame, {'type': 'confirm', 'command': command});
        channel.frame({
          'type': 'output',
          'command': command,
          'data': 'Refreshed',
        });
        channel.frame({'type': 'complete', 'command': command, 'status': 'ok'});
      }
    };
    expect(
      await console.run(
        'personal',
        command,
        confirm: true,
        canDispatch: () => true,
        onDispatched: () {},
      ),
      'Refreshed',
    );
    expect(channel.sent.length, 2);
  });

  test('wrong profile sends no command', () async {
    final channel = _Channel();
    final console = ProviderConsole((_) async {
      channel.frame({'type': 'ready', 'profile': 'default'});
      return channel;
    });
    await expectLater(
      console.run(
        'personal',
        'auth list anthropic',
        canDispatch: () => true,
        onDispatched: () {},
      ),
      throwsA(isA<ProviderRecoveryFailure>()),
    );
    expect(channel.sent, isEmpty);
  });

  test('different confirmation command never executes', () async {
    final channel = _Channel();
    final console = ProviderConsole((profile) async {
      channel.frame({'type': 'ready', 'profile': profile});
      return channel;
    });
    channel.onSend = (_) {
      channel.frame({
        'type': 'confirm_required',
        'command': 'auth refresh anthropic 222bbb',
      });
    };
    await expectLater(
      console.run(
        'personal',
        'auth refresh anthropic 333ccc',
        confirm: true,
        canDispatch: () => true,
        onDispatched: () {},
      ),
      throwsA(isA<ProviderRecoveryFailure>()),
    );
    expect(channel.sent.length, 1);
  });

  test(
    'lost connection and unconfirmed success do not claim renewal',
    () async {
      for (final close in [true, false]) {
        final channel = _Channel();
        final console = ProviderConsole((profile) async {
          channel.frame({'type': 'ready', 'profile': profile});
          return channel;
        });
        channel.onSend = (_) {
          if (close) {
            unawaited(channel.incoming.close());
          } else {
            channel.frame({
              'type': 'complete',
              'command': 'auth refresh anthropic 333ccc',
              'status': 'ok',
            });
          }
        };
        await expectLater(
          console.run(
            'personal',
            'auth refresh anthropic 333ccc',
            confirm: true,
            canDispatch: () => true,
            onDispatched: () {},
          ),
          throwsA(isA<ProviderRecoveryFailure>()),
        );
        expect(channel.sent.length, 1);
      }
    },
  );

  test('timeout never replays the command', () async {
    final channel = _Channel();
    final console = ProviderConsole((profile) async {
      channel.frame({'type': 'ready', 'profile': profile});
      return channel;
    }, timeout: const Duration(milliseconds: 20));
    await expectLater(
      console.run(
        'personal',
        'auth list anthropic',
        canDispatch: () => true,
        onDispatched: () {},
      ),
      throwsA(isA<ProviderRecoveryFailure>()),
    );
    expect(channel.sent.length, 1);
  });

  test('only scoped credential commands are allowed', () async {
    var connections = 0;
    final console = ProviderConsole((_) async {
      connections++;
      return _Channel();
    });
    for (final command in [
      'rm -f ~/.claude/.credentials.json',
      'auth refresh anthropic 1',
      'auth refresh anthropic 333ccc; auth logout anthropic',
    ]) {
      await expectLater(
        console.run(
          'personal',
          command,
          confirm: true,
          canDispatch: () => true,
          onDispatched: () {},
        ),
        throwsArgumentError,
      );
    }
    await expectLater(
      console.run(
        'current',
        'auth list anthropic',
        canDispatch: () => true,
        onDispatched: () {},
      ),
      throwsA(isA<ProviderRecoveryFailure>()),
    );
    expect(connections, 0);
  });
  test('retired capture cannot send after held console connection', () async {
    final gate = Completer<WebSocketChannel>();
    final channel = _Channel();
    var active = true, dispatched = 0;
    final console = ProviderConsole((_) => gate.future);
    final pending = console.run(
      'personal',
      'auth refresh anthropic 333ccc',
      confirm: true,
      canDispatch: () => active,
      onDispatched: () => dispatched++,
    );
    final rejected = expectLater(
      pending,
      throwsA(isA<ProviderRecoveryFailure>()),
    );
    active = false;
    gate.complete(channel);
    await rejected;
    expect(channel.sent, isEmpty);
    expect(dispatched, 0);
    console.close();
  });

  test(
    'retirement after input prevents final physical renewal confirmation',
    () async {
      final channel = _Channel();
      var active = true, dispatched = 0;
      const command = 'auth refresh anthropic 333ccc';
      final console = ProviderConsole((profile) async {
        channel.frame({'type': 'ready', 'profile': profile});
        return channel;
      });
      channel.onSend = (frame) {
        expect(frame['type'], 'input');
        active = false;
        channel.frame({'type': 'confirm_required', 'command': command});
        channel.frame({
          'type': 'complete',
          'command': command,
          'status': 'confirm_required',
        });
      };
      await expectLater(
        console.run(
          'personal',
          command,
          confirm: true,
          canDispatch: () => active,
          onDispatched: () => dispatched++,
        ),
        throwsA(isA<ProviderRecoveryFailure>()),
      );
      expect(channel.sent, [
        {'type': 'input', 'line': command},
      ]);
      expect(dispatched, 0);
      console.close();
    },
  );
}

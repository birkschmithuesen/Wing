import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/voice_offline/background_voice.dart';

class _Host implements BackgroundVoiceHost {
  final holds = <bool>[];
  final controller = StreamController<String>.broadcast(sync: true);
  Completer<bool>? next;
  bool grant = true;
  Object? error;

  @override
  Stream<String> get stopped => controller.stream;

  @override
  Future<bool> hold(bool on) async {
    holds.add(on);
    if (error != null) throw error!;
    final pending = next;
    if (pending != null) {
      next = null;
      return pending.future;
    }
    return on && grant;
  }
}

void main() {
  late _Host host;
  late BackgroundVoice voice;
  var stops = 0;
  setUp(() {
    host = _Host();
    stops = 0;
    voice = BackgroundVoice(host, onStopped: () => stops++);
  });
  tearDown(() => host.controller.close());

  test('holds once and releases once', () async {
    voice.sync(want: true);
    voice.sync(want: true);
    await pumpEventQueue();
    expect(host.holds, [true]);
    expect(voice.held, isTrue);
    voice.sync(want: false);
    await pumpEventQueue();
    expect(host.holds, [true, false]);
    expect(voice.held, isFalse);
  });

  test('a release during a pending hold runs after it', () async {
    final pending = Completer<bool>();
    host.next = pending;
    voice.sync(want: true);
    await pumpEventQueue();
    voice.sync(want: false);
    await pumpEventQueue();
    expect(host.holds, [true]);
    pending.complete(true);
    await pumpEventQueue();
    await voice.settled;
    expect(host.holds, [true, false]);
    expect(voice.held, isFalse);
  });

  test('want and unwant before the first call never holds', () async {
    voice.sync(want: true);
    voice.sync(want: false);
    await pumpEventQueue();
    expect(host.holds, isEmpty);
  });

  test('a refused or failing hold stays unheld', () async {
    host.grant = false;
    voice.sync(want: true);
    await pumpEventQueue();
    expect(voice.held, isFalse);
    expect(voice.keepsVoice(AppLifecycleState.paused), isFalse);
    voice.sync(want: false);
    host.error = StateError('channel');
    voice.sync(want: true);
    await pumpEventQueue();
    expect(voice.held, isFalse);
  });

  test('a native stop calls onStopped once and allows a new hold', () async {
    voice.sync(want: true);
    await pumpEventQueue();
    host.controller.add('notification');
    host.controller.add('notification');
    expect(stops, 1);
    expect(voice.held, isFalse);
    voice.sync(want: true);
    await pumpEventQueue();
    expect(host.holds, [true, true]);
  });

  test('a stop while not held is ignored', () async {
    host.controller.add('call');
    expect(stops, 0);
  });

  test('keepsVoice and screenOff follow the hold and lifecycle', () async {
    expect(voice.keepsVoice(AppLifecycleState.paused), isFalse);
    voice.sync(want: true);
    await pumpEventQueue();
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      expect(voice.keepsVoice(s), isTrue, reason: s.name);
    }
    expect(voice.keepsVoice(AppLifecycleState.detached), isFalse);
    expect(voice.screenOff, isFalse);
    voice.lifecycle(AppLifecycleState.paused);
    expect(voice.screenOff, isTrue);
    voice.lifecycle(AppLifecycleState.resumed);
    expect(voice.screenOff, isFalse);
  });

  test('dispose releases a hold and ignores later syncs', () async {
    voice.sync(want: true);
    await pumpEventQueue();
    voice.dispose();
    voice.sync(want: true);
    await pumpEventQueue();
    expect(host.holds, [true, false]);
  });
}

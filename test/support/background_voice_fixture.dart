import 'dart:async';

import 'package:wing/voice_offline/background_voice.dart';

class BackgroundVoiceFixture implements BackgroundVoiceHost {
  final holds = <bool>[];
  bool grant = true;
  final _stopped = StreamController<String>.broadcast(sync: true);

  @override
  Stream<String> get stopped => _stopped.stream;

  @override
  Future<bool> hold(bool on) async {
    holds.add(on);
    return on && grant;
  }

  /// Simulates the notification Stop, a swipe or a call.
  void stop(String reason) => _stopped.add(reason);

  Future<void> close() => _stopped.close();
}

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/server_connection_status.dart';
import '../core/services/vad_endpoint.dart';
import '../core/services/voice_preferences.dart';
import 'car_mode_state.dart';

/// What car mode may do in the chat workspace. The workspace builds it from
/// closures over its private voice loop (spec §6.5).
class CarModeBridge {
  const CarModeBridge({
    required this.changes,
    required this.read,
    required this.preferences,
    required this.talk,
    required this.sendNow,
    required this.stopSpeech,
    required this.retry,
    required this.sendHeld,
    required this.leave,
  });

  /// Fires when anything in [read] may have changed.
  final Listenable changes;
  final CarSnapshot Function() read;
  final SharedPreferences preferences;

  /// Stop read-aloud and open the microphone for the chat.
  final Future<void> Function() talk;

  /// End the running round now and send what was said.
  final Future<void> Function() sendNow;
  final Future<void> Function() stopSpeech;

  /// Ask the workspace to reconnect (`controller.resumeConnection`).
  final Future<void> Function() retry;

  /// Send the held draft once through the normal hands-free send.
  final Future<void> Function() sendHeld;

  /// Cancel recording (not sent) and stop read-aloud; the turn keeps running.
  final VoidCallback leave;
}

/// Case 2 (spec §4.2): the vad pause can never end the round before the
/// limit, so only a tap (or the media key) does. Copies every field.
VoicePreferences carTapOnlySettings(VoicePreferences s) => VoicePreferences(
  input: s.input,
  output: s.output,
  language: s.language,
  voice: s.voice,
  rate: s.rate,
  autoSpeak: s.autoSpeak,
  conversation: s.conversation,
  vad: VadEndpointConfig(
    pause: s.vad.maxDuration,
    minSpeech: s.vad.minSpeech,
    preRoll: s.vad.preRoll,
    maxDuration: s.vad.maxDuration,
    noSpeechTimeout: s.vad.noSpeechTimeout,
  ),
  cues: s.cues,
  debugRecordings: s.debugRecordings,
  audioSource: s.audioSource,
);

/// Spec §4.4. [sendBlocked]: the workspace would refuse a send right now
/// (`recovering`, chat opening or offline snapshot).
CarConnection carConnectionOf(ServerConnectionPhase phase, {required bool sendBlocked}) =>
    switch (phase) {
      ServerConnectionPhase.disconnected => CarConnection.offline,
      ServerConnectionPhase.reconnecting || ServerConnectionPhase.limited => CarConnection.reconnecting,
      ServerConnectionPhase.connected ||
      ServerConnectionPhase.unchecked => sendBlocked ? CarConnection.reconnecting : CarConnection.ok,
    };

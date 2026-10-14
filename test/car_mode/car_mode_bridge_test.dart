import 'package:flutter_test/flutter_test.dart';
import 'package:wing/car_mode/car_mode_bridge.dart';
import 'package:wing/car_mode/car_mode_state.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/services/vad_endpoint.dart';
import 'package:wing/core/services/voice_preferences.dart';

void main() {
  test('carTapOnlySettings copies every field and only stretches the vad pause', () {
    const s = VoicePreferences(
      input: VoiceInputRoute.vad,
      output: VoiceProcessing.hermes,
      language: 'de-DE',
      voice: 'v1',
      rate: 1.2,
      autoSpeak: true,
      conversation: false,
      vad: VadEndpointConfig(
        pause: Duration(milliseconds: 1400),
        minSpeech: Duration(milliseconds: 150),
        preRoll: Duration(milliseconds: 500),
        maxDuration: Duration(seconds: 900),
        noSpeechTimeout: Duration(seconds: 12),
      ),
      cues: false,
      debugRecordings: true,
      audioSource: VadAudioSource.recognition,
    );
    final t = carTapOnlySettings(s);
    expect(t.input, s.input);
    expect(t.output, s.output);
    expect(t.language, s.language);
    expect(t.voice, s.voice);
    expect(t.rate, s.rate);
    expect(t.autoSpeak, s.autoSpeak);
    expect(t.conversation, s.conversation);
    expect(t.cues, s.cues);
    expect(t.debugRecordings, s.debugRecordings);
    expect(t.audioSource, s.audioSource);
    expect(t.vad.pause, const Duration(seconds: 900));
    expect(t.vad.minSpeech, s.vad.minSpeech);
    expect(t.vad.preRoll, s.vad.preRoll);
    expect(t.vad.maxDuration, s.vad.maxDuration);
    expect(t.vad.noSpeechTimeout, s.vad.noSpeechTimeout);
  });

  test('with tap-only settings the vad pause never ends a round; the default does', () {
    final normal = VadEndpointer(const VadEndpointConfig());
    expect(normal.feedAll(List.filled(30, .9)), isNull);
    expect(normal.feedAll(List.filled(60, .1))?.reason, VadEndReason.pause);

    final tapOnly = VadEndpointer(carTapOnlySettings(const VoicePreferences()).vad);
    expect(tapOnly.feedAll(List.filled(30, .9)), isNull);
    expect(tapOnly.feedAll(List.filled(200, .1)), isNull);
    expect(tapOnly.forceEnd(VadEndReason.mediaKey).reason, VadEndReason.mediaKey);
  });

  test('carConnectionOf: limited and blocked sends count as reconnecting', () {
    expect(carConnectionOf(ServerConnectionPhase.connected, sendBlocked: false), CarConnection.ok);
    expect(carConnectionOf(ServerConnectionPhase.unchecked, sendBlocked: false), CarConnection.ok);
    expect(carConnectionOf(ServerConnectionPhase.connected, sendBlocked: true), CarConnection.reconnecting);
    expect(carConnectionOf(ServerConnectionPhase.limited, sendBlocked: false), CarConnection.reconnecting);
    expect(carConnectionOf(ServerConnectionPhase.reconnecting, sendBlocked: false), CarConnection.reconnecting);
    expect(carConnectionOf(ServerConnectionPhase.disconnected, sendBlocked: false), CarConnection.offline);
  });
}

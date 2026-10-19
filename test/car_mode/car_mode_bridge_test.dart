import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/car_mode/car_mode_bridge.dart';
import 'package:wing/car_mode/car_mode_state.dart';
import 'package:wing/core/controllers/voice_input_controller.dart';
import 'package:wing/core/controllers/voice_output_controller.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/services/vad_endpoint.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'package:wing/voice_offline/barge_in_coordinator.dart';
import 'package:wing/voice_offline/turn_listener.dart';
import '../support/profile_browser_fixture.dart';
import '../support/voice_fixture.dart';

class _NoopListenTarget implements ListenTarget {
  @override
  ListenChatState get state => ListenChatState.steerable;
  @override
  Future<bool> steer(String text) async => true;
  @override
  Future<void> queue(String text) async {}
  @override
  Future<void> send(String text) async {}
}

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

  test(
    'carSnapshotOf reads the barge-in listen state only for the chat on screen',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final fixture = ProfileBrowserFixture();
      final controller = ProfileWorkspaceController(
        connection: SavedConnection(
          id: 'bridge-test',
          label: 'Bridge test',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        connectionIdentity: 'bridge-test',
        preferences: prefs,
        gatewayFactory: fixture.gateway,
      );
      await controller.initialize();
      await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'newest'),
      );
      addTearDown(controller.dispose);
      final device = VoiceDeviceFixture();
      addTearDown(() => device.stream.close());
      final input = VoiceInputController(
        device: device,
        createRemote: () => throw UnimplementedError(),
      );
      final output = VoiceOutputController(device);
      addTearDown(input.dispose);
      addTearDown(output.dispose);
      final bargeIn = BargeInCoordinator(TurnListener(device: device));
      addTearDown(bargeIn.dispose);
      final chat = controller.current!.chat!;

      expect(
        carSnapshotOf(controller, input, output, bargeIn: bargeIn).listenOpen,
        isFalse,
      );

      await bargeIn.open(
        chat.key,
        _NoopListenTarget(),
        const VoicePreferences(input: VoiceInputRoute.vad),
      );
      expect(
        carSnapshotOf(controller, input, output, bargeIn: bargeIn).listenOpen,
        isTrue,
      );

      await bargeIn.close('test');
      expect(
        carSnapshotOf(controller, input, output, bargeIn: bargeIn).listenOpen,
        isFalse,
      );
    },
  );
}

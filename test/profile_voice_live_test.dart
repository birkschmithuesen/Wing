import 'package:wing/core/services/android_voice.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/models/settings_edit.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/controllers/profile_voice_controller.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_voice_repository.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/services/voice_sample.dart';

// Opt-in only: the server must have a disposable voice_review profile.
void main() {
  const port = int.fromEnvironment('VOICE_REVIEW_PORT');
  test(
    'stock Hermes saves a profile voice and synthesizes the sample',
    () async {
      final status = ServerConnectionStatus('Local review');
      final server = AdministrationRepository.forConnection(
        ConnectionAccess(
          connection: SavedConnection(
            id: 'review',
            label: 'Local review',
            host: '127.0.0.1',
            port: port,
            dashboardPortOverride: port,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        'review',
        connectionStatus: status,
      );
      final profile = server.profile('voice_review');
      final repository = ProfileVoiceRepository(profile);
      final controller = ProfileVoiceController(
        repository,
        device: AndroidVoice.instance,
      );
      addTearDown(() {
        controller.dispose();
        server.close();
        status.dispose();
      });
      await controller.load();
      expect(controller.state.error, isNull);
      expect(controller.state.settings!.provider, 'edge');
      expect(controller.state.settings!.key, 'tts.edge.voice');
      final target = controller.state.settings!.voice == 'en-GB-SoniaNeural'
          ? 'en-US-AriaNeural'
          : 'en-GB-SoniaNeural';
      await controller.select(target);
      expect(controller.state.error, isNull);
      expect(setting(await profile.config(), 'tts.edge.voice'), target);
      final speech = repository.speech(
        controller.state.settings!,
        canDispatch: () => controller.state.fresh,
      );
      addTearDown(speech.close);
      final audio = await speech.synthesize(voiceSampleText);
      expect(audio.length, greaterThan(1000));
      await File('/tmp/wing-stock-voice-sample.mp3').writeAsBytes(audio);
    },
    skip: port == 0,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

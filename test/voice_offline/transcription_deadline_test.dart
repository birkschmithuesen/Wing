import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/controllers/voice_input_controller.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'package:wing/voice_offline/vad_input_round.dart';
import 'package:wing/voice_offline/voice_offline_prefs.dart';
import '../support/voice_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'stop() asks the native layer to wait longer for longer recordings',
    () async {
      expect(transcriptionDeadlineFor(0), const Duration(milliseconds: 5000));
      expect(
        transcriptionDeadlineFor(50),
        const Duration(milliseconds: 30000),
      );
      expect(
        transcriptionDeadlineFor(500),
        const Duration(milliseconds: 90000),
      );

      final device = VoiceDeviceFixture();
      final controller = VoiceInputController(
        device: device,
        createRemote: RemoteVoiceFixture.new,
      );
      addTearDown(controller.dispose);
      addTearDown(device.stream.close);
      await controller.start(
        const VoicePreferences(),
        const VoiceOfflinePrefs(),
        TextEditingValue.empty,
        (_) => fail('Unexpected draft edit'),
      );
      controller.seconds = 50;
      await controller.stop();
      expect(device.lastStopTimeout, const Duration(milliseconds: 30000));
    },
  );
}

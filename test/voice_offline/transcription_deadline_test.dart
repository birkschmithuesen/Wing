import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/controllers/voice_input_controller.dart';
import 'package:wing/core/models/voice_processing_settings.dart';
import 'package:wing/voice_offline/vad_input_round.dart';
import '../support/voice_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'stop() asks the native layer to wait longer for longer recordings',
    () (tester) async {
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
      final controller = VoiceInputController(device: device);
      addTearDown(controller.dispose);
      addTearDown(device.stream.close);
      await controller.start(
        const LocalVoiceInputSettings(language: ''),
        const VoiceDraft(text: '', selectionStart: -1, selectionEnd: -1),
        (_) => fail('Unexpected draft edit'),
        createRemote: RemoteVoiceFixture.new,
      );
      await tester.pump(const Duration(seconds: 50));
      await controller.stop();
      expect(device.lastStopTimeout, const Duration(milliseconds: 30000));
    },
  );
}

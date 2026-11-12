import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/controllers/voice_input_controller.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'package:wing/voice_offline/voice_offline_prefs.dart';
import '../support/voice_fixture.dart';
import '../support/voice_workspace_fixture.dart';

void main() {
  late VoiceWorkspaceHarness h;
  setUpAll(VoiceWorkspaceHarness.loadCaptureFonts);
  // SETUP
  setUp(() async {
    h = VoiceWorkspaceHarness();
    await h.setUp();
  });
  // SETUP
  tearDown(() => h.tearDown());

  group('R4 dictation limit', () {
    testWidgets(
      'R4: recording is bounded at the new maximum duration and native errors leave the draft untouched',
      (tester) async {
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
        await tester.pump(const Duration(seconds: 121));
        expect(device.calls.where((c) => c == 'stop').length, 0);
        await tester.pump(
          Duration(
            seconds: VoiceInputController.maxRecordingSeconds - 121,
          ),
        );
        expect(device.calls.where((c) => c == 'stop').length, 1);
        device.stream.add({
          'id': device.recording,
          'error': 'Recognition timed out',
        });
        expect(controller.error, 'Recognition timed out');
        expect(controller.active, false);
      },
    );

    testWidgets('R4: recording status shows the default vad limit of 10 minutes', (
      tester,
    ) async {
      await h.vadRoute();
      await h.show(tester);
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      expect(find.text('Recording · 0s / 600s'), findsOneWidget);
      expect(find.textContaining('/ 120s'), findsNothing);
      await h.screenshot(tester, 'vad-recording-light-100');
      await tester.tap(find.text('Cancel recording'));
      await h.settle(tester);
    });

    test('R4: the maximum dictation is 10 minutes', () {
      expect(VoiceInputController.maxRecordingSeconds, 600);
    });

    test('R4: the native recorder uses the 10-minute constant, never 120 s', () {
      final source = File(
        'android/app/src/main/kotlin/com/tarkilhk/wing/VoiceCapture.kt',
      ).readAsStringSync();
      expect(source, contains('MAX_RECORDING_MS = 600_000'));
      expect(source, contains('setMaxDuration(MAX_RECORDING_MS)'));
      expect(source, contains('MAX_RECORDING_MS + RECORDING_DEADLINE_BUFFER_MS'));
      expect(
        RegExp(r'\b12[05]_?000\b').hasMatch(source),
        isFalse,
        reason: 'no 120 s / 125 s literal may come back with an upstream merge',
      );
    });
  });
}

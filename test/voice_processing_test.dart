import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/controllers/voice_input_controller.dart';
import 'package:wing/core/controllers/voice_output_controller.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'support/voice_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final input in VoiceProcessing.values) {
    for (final output in VoiceProcessing.values) {
      test('independent routes: input $input and output $output', () async {
        final device = VoiceDeviceFixture();
        final remoteInput = RemoteVoiceFixture();
        final remoteOutput = RemoteVoiceFixture();
        var inputClients = 0;
        var outputClients = 0;
        final recorder = VoiceInputController(
          device: device,
          createRemote: () {
            inputClients++;
            return remoteInput;
          },
        );
        final player = VoiceOutputController(device);
        addTearDown(recorder.dispose);
        addTearDown(player.dispose);
        addTearDown(device.stream.close);
        final settings = VoicePreferences(
          input: input,
          output: output,
          language: 'fr-FR',
          voice: 'french',
          rate: 0.8,
        );
        TextEditingValue? result;
        await recorder.start(
          settings,
          const TextEditingValue(
            text: 'Draft: ',
            selection: TextSelection.collapsed(offset: 7),
          ),
          (value) => result = value,
        );
        expect(device.local, input == VoiceProcessing.local);
        expect(result, isNull);
        if (input == VoiceProcessing.local) {
          device.stream.add({
            'id': device.recording,
            'text': 'partial',
            'final': false,
          });
          expect(result, isNull);
          expect(recorder.partial, 'partial');
          await recorder.stop();
          device.stream.add({
            'id': device.recording,
            'text': 'Bonjour',
            'final': true,
          });
        } else {
          await recorder.stop();
        }
        expect(
          result!.text,
          input == VoiceProcessing.local
              ? 'Draft: Bonjour'
              : 'Draft: Hello from Hermes',
        );
        expect(inputClients, input == VoiceProcessing.local ? 0 : 1);
        expect(recorder.active, isFalse);
        await player.speak(
          'reply',
          'Hello **there**.\n\n```sh\nsecret command\n```\n\n<think>private reasoning</think>\n\n[Read more](https://example.com)',
          settings,
          () {
            outputClients++;
            return remoteOutput;
          },
        );
        expect(outputClients, output == VoiceProcessing.local ? 0 : 1);
        expect(
          device.calls,
          contains(output == VoiceProcessing.local ? 'speak' : 'play'),
        );
        final spoken = output == VoiceProcessing.local
            ? device.spoken!
            : remoteOutput.spoken!;
        expect(spoken, contains('Hello there.'));
        expect(spoken, contains('Read more'));
        expect(spoken, isNot(contains('secret')));
        expect(spoken, isNot(contains('private')));
        if (output == VoiceProcessing.local) {
          expect(device.voice, 'french');
          expect(device.rate, 0.8);
        }
      });
    }
  }
  test(
    'cancel during permission/start cannot resurrect capture or replace draft',
    () async {
      final device = VoiceDeviceFixture()..startDelay = Completer<void>();
      final controller = VoiceInputController(
        device: device,
        createRemote: RemoteVoiceFixture.new,
      );
      addTearDown(controller.dispose);
      addTearDown(device.stream.close);
      var edits = 0;
      final start = controller.start(
        const VoicePreferences(),
        TextEditingValue.empty,
        (_) => edits++,
      );
      final id = device.recording;
      await controller.cancel();
      device.startDelay!.complete();
      await start;
      device.stream.add({'id': id, 'text': 'late', 'final': true});
      expect(edits, 0);
      expect(controller.active, false);
      expect(device.cancelled, contains(id));
    },
  );
  test(
    'cancelled server transcription cannot cross into a new capture',
    () async {
      final device = VoiceDeviceFixture();
      final remote = RemoteVoiceFixture()
        ..transcriptDelay = Completer<String>();
      final controller = VoiceInputController(
        device: device,
        createRemote: () => remote,
      );
      addTearDown(controller.dispose);
      addTearDown(device.stream.close);
      var edits = 0;
      await controller.start(
        const VoicePreferences(input: VoiceProcessing.hermes),
        TextEditingValue.empty,
        (_) => edits++,
      );
      final stopping = controller.stop();
      await Future<void>.delayed(Duration.zero);
      expect(controller.phase, VoiceInputPhase.transcribing);
      await controller.cancel();
      expect(remote.closed, true);
      await controller.start(
        const VoicePreferences(),
        TextEditingValue.empty,
        (_) => edits++,
      );
      remote.transcriptDelay!.complete('stale');
      await stopping;
      expect(edits, 0);
      expect(controller.phase, VoiceInputPhase.recording);
      await controller.cancel();
    },
  );
  test(
    'permission denial and unavailable local engines never create a remote client',
    () async {
      for (final code in ['permission_denied', 'unavailable']) {
        final device = VoiceDeviceFixture()
          ..startError = PlatformException(code: code, message: code);
        final controller = VoiceInputController(
          device: device,
          createRemote: () => throw StateError('Unexpected upload'),
        );
        await controller.start(
          const VoicePreferences(),
          TextEditingValue.empty,
          (_) => fail('Unexpected draft edit'),
        );
        expect(controller.error, code);
        expect(controller.active, false);
        controller.dispose();
        await device.stream.close();
      }
    },
  );
  test(
    'provider failure is visible and releases the recording request',
    () async {
      final device = VoiceDeviceFixture();
      final remote = RemoteVoiceFixture()
        ..failure = StateError('Provider unavailable');
      final controller = VoiceInputController(
        device: device,
        createRemote: () => remote,
      );
      addTearDown(controller.dispose);
      addTearDown(device.stream.close);
      await controller.start(
        const VoicePreferences(input: VoiceProcessing.hermes),
        TextEditingValue.empty,
        (_) => fail('Unexpected draft edit'),
      );
      await controller.stop();
      expect(controller.error, 'Provider unavailable');
      expect(remote.closed, true);
      expect(controller.active, false);
    },
  );
  test('cancelled synthesis cannot start playback after navigation', () async {
    final device = VoiceDeviceFixture();
    final remote = RemoteVoiceFixture()
      ..synthesisDelay = Completer<Uint8List>();
    final controller = VoiceOutputController(device);
    addTearDown(controller.dispose);
    addTearDown(device.stream.close);
    final speaking = controller.speak(
      'old chat',
      'Hello',
      const VoicePreferences(output: VoiceProcessing.hermes),
      () => remote,
    );
    await controller.stop();
    remote.synthesisDelay!.complete(Uint8List.fromList([1]));
    await speaking;
    expect(remote.closed, true);
    expect(device.calls, isNot(contains('play')));
    expect(controller.owner, isNull);
  });
  test(
    'playback stop and late completion do not clear the next message',
    () async {
      final device = VoiceDeviceFixture()..playbackDelay = Completer<void>();
      final controller = VoiceOutputController(device);
      addTearDown(controller.dispose);
      addTearDown(device.stream.close);
      final firstDelay = device.playbackDelay!;
      final first = controller.speak(
        'first',
        'One',
        const VoicePreferences(),
        RemoteVoiceFixture.new,
      );
      final firstId = device.playing;
      await controller.stop();
      device.playbackDelay = Completer<void>();
      final second = controller.speak(
        'second',
        'Two',
        const VoicePreferences(),
        RemoteVoiceFixture.new,
      );
      firstDelay.complete();
      await first;
      expect(controller.owner, 'second');
      device.stream.add({'id': firstId, 'playing': true});
      expect(controller.preparing, true);
      device.stream.add({'id': device.playing, 'playing': true});
      expect(controller.preparing, false);
      device.playbackDelay!.complete();
      await second;
      expect(controller.owner, isNull);
    },
  );
  testWidgets(
    'recording is bounded at the new maximum duration and native errors leave the draft untouched',
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
        TextEditingValue.empty,
        (_) => fail('Unexpected draft edit'),
      );
      controller.seconds = 50;
      await controller.stop();
      expect(device.lastStopTimeout, const Duration(milliseconds: 30000));
    },
  );
  test('insertion preserves text around selected range and cursor', () {
    final result = insertVoiceTranscript(
      const TextEditingValue(
        text: 'Alpha old omega',
        selection: TextSelection(baseOffset: 6, extentOffset: 9),
      ),
      'new words',
    );
    expect(result.text, 'Alpha new words omega');
    expect(result.selection.baseOffset, 15);
    expect(
      spokenReplyText('Before\n\n    indented code\n\nAfter'),
      'Before\n\nAfter',
    );
    expect(spokenReplyText('Only `inline code` remains'), 'Only  remains');
    expect(spokenReplyText('Compare A & B: 1 < 2.'), 'Compare A & B: 1 < 2.');
  });
}

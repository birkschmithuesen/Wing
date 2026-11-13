import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/controllers/voice_input_controller.dart';
import 'package:wing/core/controllers/voice_output_controller.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/models/voice_processing_settings.dart';
import 'support/voice_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final input in AppVoiceProcessing.values) {
    for (final output in AppVoiceProcessing.values) {
      test('independent routes: input $input and output $output', () async {
        final device = VoiceDeviceFixture();
        final remoteInput = RemoteVoiceFixture();
        final remoteOutput = RemoteVoiceFixture();
        var inputClients = 0;
        var outputClients = 0;
        final recorder = VoiceInputController(device: device);
        final player = VoiceOutputController(device);
        addTearDown(recorder.dispose);
        addTearDown(player.dispose);
        addTearDown(device.stream.close);
        final inputSettings = input == AppVoiceProcessing.local
            ? const LocalVoiceInputSettings(language: 'fr-FR')
            : const HermesVoiceInputSettings();
        final outputSettings = output == AppVoiceProcessing.local
            ? const LocalVoiceOutputSettings(
                voice: 'french',
                rate: AppVoiceRate.slower,
              )
            : const HermesVoiceOutputSettings();
        VoiceDraft? result;
        await recorder.start(
          inputSettings,
          const VoiceDraft(text: 'Draft: ', selectionStart: 7, selectionEnd: 7),
          (value) => result = value,
          createRemote: () {
            inputClients++;
            return remoteInput;
          },
        );
        expect(device.local, input == AppVoiceProcessing.local);
        expect(result, isNull);
        if (input == AppVoiceProcessing.local) {
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
          input == AppVoiceProcessing.local
              ? 'Draft: Bonjour'
              : 'Draft: Hello from Hermes',
        );
        expect(inputClients, input == AppVoiceProcessing.local ? 0 : 1);
        expect(recorder.active, isFalse);
        await player.speak(
          'reply',
          'Hello **there**.\n\n```sh\nsecret command\n```\n\n<think>private reasoning</think>\n\n[Read more](https://example.com)',
          outputSettings,
          () {
            outputClients++;
            return remoteOutput;
          },
        );
        expect(outputClients, output == AppVoiceProcessing.local ? 0 : 1);
        expect(
          device.calls,
          contains(output == AppVoiceProcessing.local ? 'speak' : 'play'),
        );
        final spoken = output == AppVoiceProcessing.local
            ? device.spoken!
            : remoteOutput.spoken!;
        expect(spoken, contains('Hello there.'));
        expect(spoken, contains('Read more'));
        expect(spoken, isNot(contains('secret')));
        expect(spoken, isNot(contains('private')));
        if (output == AppVoiceProcessing.local) {
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
      final controller = VoiceInputController(device: device);
      addTearDown(controller.dispose);
      addTearDown(device.stream.close);
      var edits = 0;
      final start = controller.start(
        const LocalVoiceInputSettings(language: ''),
        const VoiceDraft(text: '', selectionStart: -1, selectionEnd: -1),
        (_) => edits++,
        createRemote: RemoteVoiceFixture.new,
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
      final controller = VoiceInputController(device: device);
      addTearDown(controller.dispose);
      addTearDown(device.stream.close);
      var edits = 0;
      await controller.start(
        const HermesVoiceInputSettings(),
        const VoiceDraft(text: '', selectionStart: -1, selectionEnd: -1),
        (_) => edits++,
        createRemote: () => remote,
      );
      final stopping = controller.stop();
      await Future<void>.delayed(Duration.zero);
      expect(controller.phase, VoiceInputPhase.transcribing);
      await controller.cancel();
      expect(remote.closed, true);
      await controller.start(
        const LocalVoiceInputSettings(language: ''),
        const VoiceDraft(text: '', selectionStart: -1, selectionEnd: -1),
        (_) => edits++,
        createRemote: () => remote,
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
        final controller = VoiceInputController(device: device);
        await controller.start(
          const LocalVoiceInputSettings(language: ''),
          const VoiceDraft(text: '', selectionStart: -1, selectionEnd: -1),
          (_) => fail('Unexpected draft edit'),
          createRemote: () => throw StateError('Unexpected upload'),
        );
        expect(controller.error, code);
        expect(controller.active, false);
        controller.dispose();
        await device.stream.close();
      }
    },
  );
  test(
    'empty recognition is a per-attempt notice while permission failure persists',
    () async {
      final device = VoiceDeviceFixture();
      final controller = VoiceInputController(device: device);
      addTearDown(controller.dispose);
      addTearDown(device.stream.close);
      Future<void> start() => controller.start(
        const LocalVoiceInputSettings(language: ''),
        const VoiceDraft(
          text: 'Keep my draft',
          selectionStart: 13,
          selectionEnd: 13,
        ),
        (_) => fail('An empty recording must not edit the draft'),
        createRemote: () => throw StateError('Unexpected upload'),
      );
      await start();
      final first = device.recording;
      device.stream.add({'id': first, 'text': ' ', 'final': true});
      expect(controller.error, isNull);
      expect(controller.notice, (
        attempt: first,
        result: VoiceInputEmptyResult.noSpeech,
      ));
      expect(controller.active, isFalse);
      await start();
      expect(controller.notice, isNull);
      final second = device.recording;
      device.stream.add({
        'id': second,
        'error': 'Native localized message',
        'code': 'no_speech',
      });
      expect(controller.notice?.attempt, second);
      expect(controller.notice?.attempt, isNot(first));
      expect(controller.error, isNull);
      await start();
      device.stream.add({
        'id': device.recording,
        'error': 'Microphone access was denied.',
        'code': 'capture_failed',
      });
      expect(controller.notice, isNull);
      expect(controller.error, 'Microphone access was denied.');
      await controller.cancel();
      expect(controller.notice, isNull);
    },
  );
  test(
    'provider failure is visible and releases the recording request',
    () async {
      final device = VoiceDeviceFixture();
      final remote = RemoteVoiceFixture()
        ..failure = StateError('Provider unavailable');
      final controller = VoiceInputController(device: device);
      addTearDown(controller.dispose);
      addTearDown(device.stream.close);
      await controller.start(
        const HermesVoiceInputSettings(),
        const VoiceDraft(text: '', selectionStart: -1, selectionEnd: -1),
        (_) => fail('Unexpected draft edit'),
        createRemote: () => remote,
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
      const HermesVoiceOutputSettings(),
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
        const LocalVoiceOutputSettings(voice: '', rate: AppVoiceRate.normal),
        RemoteVoiceFixture.new,
      );
      final firstId = device.playing;
      await controller.stop();
      device.playbackDelay = Completer<void>();
      final second = controller.speak(
        'second',
        'Two',
        const LocalVoiceOutputSettings(voice: '', rate: AppVoiceRate.normal),
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
      final controller = VoiceInputController(device: device);
      addTearDown(controller.dispose);
      addTearDown(device.stream.close);
      await controller.start(
        const LocalVoiceInputSettings(language: ''),
        const VoiceDraft(text: '', selectionStart: -1, selectionEnd: -1),
        (_) => fail('Unexpected draft edit'),
        createRemote: RemoteVoiceFixture.new,
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
  test('insertion preserves text around selected range and cursor', () {
    final result = insertVoiceTranscript(
      const VoiceDraft(
        text: 'Alpha old omega',
        selectionStart: 6,
        selectionEnd: 9,
      ),
      'new words',
    );
    expect(result.text, 'Alpha new words omega');
    expect(result.selectionStart, 15);
    expect(result.selectionEnd, 15);
  });
  test('read-aloud text excludes code while preserving prose punctuation', () {
    expect(
      spokenReplyText('Before\n\n    indented code\n\nAfter'),
      'Before\n\nAfter',
    );
    expect(spokenReplyText('Only `inline code` remains'), 'Only  remains');
    expect(spokenReplyText('Compare A & B: 1 < 2.'), 'Compare A & B: 1 < 2.');
  });
  test('MEDIA reference lines are not read aloud', () {
    expect(
      spokenReplyText('Text.\n\nMEDIA:/a/b/c.png'),
      'Text.',
    );
    expect(
      spokenReplyText('Text.\n\nMEDIA: "/a b/c.png"'),
      'Text.',
    );
    expect(
      spokenReplyText('Text.\n\n`MEDIA:/x.pdf`'),
      'Text.',
    );
    expect(
      spokenReplyText('Streaming media players are great.'),
      'Streaming media players are great.',
    );
  });
}

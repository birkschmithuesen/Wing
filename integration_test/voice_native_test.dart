import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wing/core/services/android_voice.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/services/voice_sample.dart';

/// Disposable emulator with RECORD_AUDIO granted. Synthetic audio verifies the
/// native boundary; transcription and speech intelligibility need human review.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final device = AndroidVoice.instance;

  Future<void> launch(WidgetTester tester) => tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(body: Text('Wing native voice acceptance')),
    ),
  );

  testWidgets('all subscription previews decode and complete on Android', (
    tester,
  ) async {
    await launch(tester);
    for (final voice in LiveVoiceMode.subscription.voices) {
      final owner = 'native-preview-$voice';
      var started = false;
      final subscription = device.events.listen((event) {
        if (event['id'] == owner && event['playing'] == true) started = true;
      });
      try {
        final audio = await loadVoiceSample(
          liveVoiceSampleAsset(LiveVoiceMode.subscription, voice)!,
        );
        await device.play(owner, audio).timeout(const Duration(seconds: 15));
        expect(started, isTrue, reason: voice);
      } finally {
        await device.stopPlayback(owner);
        await subscription.cancel();
      }
    }
  });

  testWidgets('stopping native capture returns recorded audio', (tester) async {
    await launch(tester);
    const owner = 'native-recording';
    addTearDown(() => device.cancel(owner));
    await device.start(owner, local: false, language: '');
    // Recording needs actual elapsed time to acquire audio samples. This is
    // stimulus duration, not a sleep guessing when an asynchronous result arrives.
    await tester.pump(const Duration(milliseconds: 700));
    final recording = await device.stop(owner);
    expect(recording, isNotNull);
    expect(recording, isNotEmpty);
  });

  testWidgets('cancelling native capture discards the recording', (
    tester,
  ) async {
    await launch(tester);
    const owner = 'native-cancel';
    addTearDown(() => device.cancel(owner));
    await device.start(owner, local: false, language: '');
    await device.cancel(owner);
    expect(await device.stop(owner), isNull);
  });

  testWidgets('native playback reports audio before completing', (
    tester,
  ) async {
    await launch(tester);
    const owner = 'native-decode';
    addTearDown(() => device.stopPlayback(owner));
    var started = false;
    final subscription = device.events.listen((event) {
      if (event['id'] == owner && event['playing'] == true) started = true;
    });
    addTearDown(subscription.cancel);
    await device.play(owner, _tone()).timeout(const Duration(seconds: 10));
    expect(started, isTrue);
  });

  testWidgets('stopping active native playback settles its operation', (
    tester,
  ) async {
    await launch(tester);
    const owner = 'native-interrupt';
    addTearDown(() => device.stopPlayback(owner));
    final started = Completer<void>();
    final subscription = device.events.listen((event) {
      if (event['id'] == owner &&
          event['playing'] == true &&
          !started.isCompleted) {
        started.complete();
      }
    });
    addTearDown(subscription.cancel);
    final playing = device.play(owner, _tone(seconds: 3));
    // Observe startup instead of hoping a 150ms sleep reaches active playback.
    await started.future.timeout(const Duration(seconds: 10));
    await device.stopPlayback(owner);
    await playing.timeout(const Duration(seconds: 10));
  });

  testWidgets('an absent offline voice reports a playback error', (
    tester,
  ) async {
    await launch(tester);
    const owner = 'native-unavailable';
    addTearDown(() => device.stopPlayback(owner));
    await expectLater(
      device.speak(
        owner,
        'Hello',
        voice: 'wing-test-voice-that-is-not-installed',
        rate: 1,
      ),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'voice_playback',
        ),
      ),
    );
  });

  const speechSamples = [
    'Your connection is ready.',
    'The task finished successfully. You can review the changes.',
    'Open the project settings and choose a profile.',
    'The server returned three results, including version two point five.',
    'Hello. This is a longer reply, with punctuation and a question. Would you like to continue?',
  ];
  for (final (index, sample) in speechSamples.indexed) {
    testWidgets('installed offline voice completes speech sample $index', (
      tester,
    ) async {
      await launch(tester);
      final capabilities = await device.capabilities().timeout(
        const Duration(seconds: 12),
      );
      if (index == 0) {
        debugPrint('VOICE_OFFLINE_VOICES ${capabilities.voices.length}');
        debugPrint(
          'VOICE_CAPABILITIES localInput=${capabilities.recognitionAvailable} languages=${capabilities.installedLanguages} offlineVoices=${capabilities.voices.length}',
        );
      }
      expect(
        capabilities.voices,
        isNotEmpty,
        reason:
            'Install an offline Android TTS voice before running speech acceptance.',
      );
      final owner = 'native-speech-$index';
      final voice = capabilities.voices.first.id;
      final elapsed = Stopwatch()..start();
      int? firstAudio;
      addTearDown(() => device.stopPlayback(owner));
      final subscription = device.events.listen((event) {
        if (event['id'] == owner && event['playing'] == true) {
          firstAudio ??= elapsed.elapsedMilliseconds;
        }
      });
      addTearDown(subscription.cancel);
      await device
          .speak(owner, sample, voice: voice, rate: 1)
          .timeout(const Duration(seconds: 40));
      expect(firstAudio, isNotNull);
      // Metrics are evidence for the native driver, not brittle timing limits.
      debugPrint(
        'VOICE_LOCAL_TTS sample=$index firstAudioMs=$firstAudio completedMs=${elapsed.elapsedMilliseconds} voice=$voice',
      );
    });
  }

  testWidgets(
    'missing local recognition reports an actionable native error',
    (tester) async {
      await launch(tester);
      final capabilities = await device.capabilities();
      debugPrint(
        'VOICE_UNAVAILABLE_LOCAL_INPUT ${capabilities.recognitionAvailable}',
      );
      expect(
        capabilities.recognitionAvailable,
        isFalse,
        reason:
            'The native driver must establish an unavailable Android recognizer.',
      );
      const owner = 'local-unavailable';
      addTearDown(() => device.cancel(owner));
      await expectLater(
        device.start(owner, local: true, language: ''),
        throwsA(
          isA<PlatformException>()
              .having((error) => error.code, 'code', 'voice_unavailable')
              .having(
                (error) => error.message,
                'actionable message',
                allOf(
                  contains('On-device recognition is unavailable'),
                  contains('Choose Hermes in App settings'),
                ),
              ),
        ),
      );
      expect(await device.stop(owner), isNull);
      debugPrint('VOICE_LOCAL_UNAVAILABLE_VERIFIED');
    },
    tags: 'recognition-unavailable',
  );

  testWidgets(
    'restored recognition matches the original Android capability',
    (tester) async {
      await launch(tester);
      expect(
        const bool.hasEnvironment('VOICE_BASELINE_LOCAL_INPUT'),
        isTrue,
        reason: 'The native driver must supply the observed baseline.',
      );
      final capabilities = await device.capabilities();
      debugPrint(
        'VOICE_RESTORED_LOCAL_INPUT ${capabilities.recognitionAvailable}',
      );
      expect(
        capabilities.recognitionAvailable,
        const bool.fromEnvironment('VOICE_BASELINE_LOCAL_INPUT'),
      );
    },
    tags: 'recognition-restored',
  );
}

Uint8List _tone({int seconds = 1}) {
  const sampleRate = 16000;
  final samples = sampleRate * seconds;
  final bytes = ByteData(44 + samples * 2);
  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + samples * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    bytes.setInt16(
      44 + i * 2,
      (1000 * sin(2 * pi * 440 * i / sampleRate)).round(),
      Endian.little,
    );
  }
  return bytes.buffer.asUint8List();
}

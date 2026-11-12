import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wing/core/services/android_voice.dart';

/// Disposable emulator/device with RECORD_AUDIO granted beforehand. Exercises
/// real capture/playback; synthetic tones do not establish transcription quality.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native capture, cancellation, decoding and installed offline voices', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('Wing native voice acceptance')),
        ),
      ),
    );
    final device = AndroidVoice.instance;
    final capabilities = await device.capabilities().timeout(
      const Duration(seconds: 12),
    );
    debugPrint(
      'VOICE_CAPABILITIES localInput=${capabilities.recognitionAvailable} languages=${capabilities.installedLanguages} offlineVoices=${capabilities.voices.length}',
    );
    await device.start('native-recording', local: false, language: '');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final recording = await device.stop('native-recording');
    expect(recording, isNotNull);
    expect(recording!.length, greaterThan(100));
    await device.start('native-cancel', local: false, language: '');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await device.cancel('native-cancel');
    expect(await device.stop('native-cancel'), isNull);
    await device
        .play('native-decode', _tone())
        .timeout(const Duration(seconds: 10));
    final playing = device.play('native-interrupt', _tone(seconds: 3));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await device.stopPlayback('native-interrupt');
    await playing;
    // The Android TTS service can finish initializing after the first probe.
    // Pin the rejection check to an absent voice rather than a stale snapshot.
    await expectLater(
      device.speak(
        'native-unavailable',
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
    final speechCapabilities = await device.capabilities().timeout(
      const Duration(seconds: 12),
    );
    debugPrint('VOICE_OFFLINE_VOICES ${speechCapabilities.voices.length}');
    if (speechCapabilities.voices.isEmpty) {
      debugPrint(
        'VOICE_LIMITATION no installed offline Android voice; speech-quality acceptance remains outstanding',
      );
    } else {
      final voice = speechCapabilities.voices.first.id;
      const samples = [
        'Your connection is ready.',
        'The task finished successfully. You can review the changes.',
        'Open the project settings and choose a profile.',
        'The server returned three results, including version two point five.',
        'Hello. This is a longer reply, with punctuation and a question. Would you like to continue?',
      ];
      for (var i = 0; i < samples.length; i++) {
        final owner = 'native-speech-$i';
        final clock = Stopwatch()..start();
        int? firstAudio;
        final events = device.events.listen((event) {
          if (event['id'] == owner && event['playing'] == true) {
            firstAudio ??= clock.elapsedMilliseconds;
          }
        });
        try {
          await device
              .speak(owner, samples[i], voice: voice, rate: 1)
              .timeout(const Duration(seconds: 40));
          expect(firstAudio, isNotNull);
          debugPrint(
            'VOICE_LOCAL_TTS sample=$i firstAudioMs=$firstAudio completedMs=${clock.elapsedMilliseconds} voice=$voice',
          );
        } finally {
          await events.cancel();
          await device.stopPlayback(owner);
        }
      }
      debugPrint(
        'VOICE_LIMITATION TTS completion/timing verified; intelligibility still requires a listener',
      );
    }
    if (!capabilities.recognitionAvailable) {
      await expectLater(
        device.start('local-unavailable', local: true, language: ''),
        throwsA(anything),
      );
    }
    await device.cancel('local-unavailable');
  });
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

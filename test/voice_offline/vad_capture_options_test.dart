import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/android_voice.dart';
import 'package:wing/core/services/voice_preferences.dart';

void main() {
  test('start cue follows cues unless set; playback is stopped by default', () {
    const options = VadCaptureOptions(
      cues: true,
      debug: false,
      source: VadAudioSource.communication,
      maxDuration: Duration(seconds: 600),
    );
    expect(options.toMap()['startCue'], isTrue);
    expect(options.toMap()['keepPlayback'], isFalse);
  });

  test('listen rounds keep playback and skip the start cue', () {
    const options = VadCaptureOptions(
      cues: true,
      debug: false,
      source: VadAudioSource.communication,
      maxDuration: Duration(seconds: 600),
      startCue: false,
      keepPlayback: true,
    );
    expect(options.toMap(), containsPair('startCue', false));
    expect(options.toMap(), containsPair('keepPlayback', true));
    expect(options.toMap(), containsPair('cues', true));
  });
}

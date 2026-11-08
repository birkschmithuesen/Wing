import 'package:flutter/services.dart';

import '../models/app_preferences.dart';

const voiceSampleText =
    'Hello, welcome to Wing. A familiar face, now with a voice to match.';

/// Packaged auditions exist only for the subscription catalog.
String? liveVoiceSampleAsset(LiveVoiceMode? mode, String? voice) =>
    mode == LiveVoiceMode.subscription && mode!.voices.contains(voice)
    ? 'assets/voice_samples/subscription/$voice.m4a'
    : null;

Future<Uint8List> loadVoiceSample(String asset) async {
  try {
    final data = await rootBundle.load(asset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (_) {
    throw StateError('Could not load this voice preview. Please try again.');
  }
}

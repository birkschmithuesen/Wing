import 'package:shared_preferences/shared_preferences.dart';
import '../../voice_offline/voice_offline_prefs.dart';

/// Output engines. Input routes are [VoiceInputRoute].
enum VoiceProcessing { local, hermes }

/// local = Android recognizer, hermes = server transcription,
/// vad = own capture + Silero end of utterance + Parakeet on this phone.
enum VoiceInputRoute { local, hermes, vad }

/// Device-owned choices. Hermes voice/provider configuration stays on its profile.
class VoicePreferences {
  static const inputKey = 'voice.input';
  static const outputKey = 'voice.output';
  static const languageKey = 'voice.android_language';
  static const voiceKey = 'voice.android_voice';
  static const rateKey = 'voice.android_rate';
  static const keys = {
    inputKey,
    outputKey,
    languageKey,
    voiceKey,
    rateKey,
    ...VoiceOfflinePrefs.keys,
  };

  static bool accepts(String key, Object value) => switch (key) {
    inputKey => value == 'local' || value == 'hermes' || value == 'vad',
    outputKey => value == 'local' || value == 'hermes',
    languageKey || voiceKey => value is String,
    rateKey => {'0.8', '1.0', '1.2'}.contains(value),
    _ => VoiceOfflinePrefs.accepts(key, value),
  };

  final VoiceInputRoute input;
  final VoiceProcessing output;
  final String language;
  final String voice;
  final double rate;

  const VoicePreferences({
    this.input = VoiceInputRoute.local,
    this.output = VoiceProcessing.local,
    this.language = '',
    this.voice = '',
    this.rate = 1,
  });

  factory VoicePreferences.read(SharedPreferences preferences) =>
      VoicePreferences(
        input: switch (preferences.getString(inputKey)) {
          null || 'local' => VoiceInputRoute.local,
          'hermes' => VoiceInputRoute.hermes,
          'vad' => VoiceInputRoute.vad,
          _ => throw const FormatException(
            'Unknown voice processing choice. Choose an engine in App settings.',
          ),
        },
        output: _engine(preferences.getString(outputKey)),
        language: preferences.getString(languageKey) ?? '',
        voice: preferences.getString(voiceKey) ?? '',
        rate: switch (preferences.getString(rateKey)) {
          '0.8' => 0.8,
          '1.2' => 1.2,
          _ => 1,
        },
      );

  static VoiceProcessing _engine(String? value) => switch (value) {
    null || 'local' => VoiceProcessing.local,
    'hermes' => VoiceProcessing.hermes,
    _ => throw const FormatException(
      'Unknown voice processing choice. Choose an engine in App settings.',
    ),
  };
}

import 'package:shared_preferences/shared_preferences.dart';

enum VoiceProcessing { local, hermes }

/// Device-owned choices. Hermes voice/provider configuration stays on its profile.
class VoicePreferences {
  static const inputKey = 'voice.input';
  static const outputKey = 'voice.output';
  static const languageKey = 'voice.android_language';
  static const voiceKey = 'voice.android_voice';
  static const rateKey = 'voice.android_rate';
  static const autoSpeakKey = 'voice.auto_speak';
  static const keys = {
    inputKey,
    outputKey,
    languageKey,
    voiceKey,
    rateKey,
    autoSpeakKey,
  };

  static bool accepts(String key, Object value) => switch (key) {
    inputKey || outputKey => value == 'local' || value == 'hermes',
    languageKey || voiceKey => value is String,
    rateKey => {'0.8', '1.0', '1.2'}.contains(value),
    autoSpeakKey => value == 'on' || value == 'off',
    _ => false,
  };

  final VoiceProcessing input;
  final VoiceProcessing output;
  final String language;
  final String voice;
  final double rate;

  /// Read each completed reply aloud automatically (hands-free voice chat).
  final bool autoSpeak;

  const VoicePreferences({
    this.input = VoiceProcessing.local,
    this.output = VoiceProcessing.local,
    this.language = '',
    this.voice = '',
    this.rate = 1,
    this.autoSpeak = false,
  });

  factory VoicePreferences.read(SharedPreferences preferences) =>
      VoicePreferences(
        input: _engine(preferences.getString(inputKey)),
        output: _engine(preferences.getString(outputKey)),
        language: preferences.getString(languageKey) ?? '',
        voice: preferences.getString(voiceKey) ?? '',
        rate: switch (preferences.getString(rateKey)) {
          '0.8' => 0.8,
          '1.2' => 1.2,
          _ => 1,
        },
        autoSpeak: preferences.getString(autoSpeakKey) == 'on',
      );

  static VoiceProcessing _engine(String? value) => switch (value) {
    null || 'local' => VoiceProcessing.local,
    'hermes' => VoiceProcessing.hermes,
    _ => throw const FormatException(
      'Unknown voice processing choice. Choose an engine in App settings.',
    ),
  };
}

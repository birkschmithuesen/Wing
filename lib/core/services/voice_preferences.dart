import 'package:shared_preferences/shared_preferences.dart';
import 'vad_endpoint.dart';

/// Output engines. Input routes are [VoiceInputRoute].
enum VoiceProcessing { local, hermes }

/// local = Android recognizer, hermes = server transcription,
/// vad = own capture + Silero end of utterance + Parakeet on this phone.
enum VoiceInputRoute { local, hermes, vad }

/// communication = platform noise/echo processing; recognition = raw-ish.
enum VadAudioSource { communication, recognition }

/// Device-owned choices. Hermes voice/provider configuration stays on its profile.
class VoicePreferences {
  static const inputKey = 'voice.input';
  static const outputKey = 'voice.output';
  static const languageKey = 'voice.android_language';
  static const voiceKey = 'voice.android_voice';
  static const rateKey = 'voice.android_rate';
  static const autoSpeakKey = 'voice.auto_speak';
  static const conversationKey = 'voice.conversation';
  static const vadPauseKey = 'voice.vad_pause_ms';
  static const vadMinSpeechKey = 'voice.vad_min_speech_ms';
  static const vadPreRollKey = 'voice.vad_preroll_ms';
  static const vadMaxKey = 'voice.vad_max_seconds';
  static const vadNoSpeechKey = 'voice.vad_no_speech_seconds';
  static const vadCuesKey = 'voice.vad_cues';
  static const vadDebugKey = 'voice.vad_debug';
  static const vadSourceKey = 'voice.vad_source';
  static const keys = {
    inputKey,
    outputKey,
    languageKey,
    voiceKey,
    rateKey,
    autoSpeakKey,
    conversationKey,
    vadPauseKey,
    vadMinSpeechKey,
    vadPreRollKey,
    vadMaxKey,
    vadNoSpeechKey,
    vadCuesKey,
    vadDebugKey,
    vadSourceKey,
  };
  static const vadPauseChoices = ['1000', '1400', '1800', '2400', '3000'];
  static const vadMinSpeechChoices = ['150', '250', '400'];
  static const vadPreRollChoices = ['200', '300', '500'];
  static const vadMaxChoices = ['30', '60', '120'];
  static const vadNoSpeechChoices = ['5', '8', '12', '20'];

  static bool accepts(String key, Object value) => switch (key) {
    inputKey => value == 'local' || value == 'hermes' || value == 'vad',
    outputKey => value == 'local' || value == 'hermes',
    languageKey || voiceKey => value is String,
    rateKey => {'0.8', '1.0', '1.2'}.contains(value),
    autoSpeakKey || conversationKey || vadCuesKey || vadDebugKey =>
      value == 'on' || value == 'off',
    vadPauseKey => vadPauseChoices.contains(value),
    vadMinSpeechKey => vadMinSpeechChoices.contains(value),
    vadPreRollKey => vadPreRollChoices.contains(value),
    vadMaxKey => vadMaxChoices.contains(value),
    vadNoSpeechKey => vadNoSpeechChoices.contains(value),
    vadSourceKey => value == 'communication' || value == 'recognition',
    _ => false,
  };

  final VoiceInputRoute input;
  final VoiceProcessing output;
  final String language;
  final String voice;
  final double rate;

  /// Read each completed reply aloud automatically (hands-free voice chat).
  final bool autoSpeak;

  /// Hands-free loop: a dictation that ends on its own is sent, the reply is
  /// read aloud (even with [autoSpeak] off) and the microphone reopens.
  final bool conversation;

  /// End-of-utterance settings for [VoiceInputRoute.vad].
  final VadEndpointConfig vad;

  /// Short tones for "listening" and "got it" on the vad route.
  final bool cues;

  /// Keep raw audio and VAD timing of each vad round on this phone.
  final bool debugRecordings;
  final VadAudioSource audioSource;

  const VoicePreferences({
    this.input = VoiceInputRoute.local,
    this.output = VoiceProcessing.local,
    this.language = '',
    this.voice = '',
    this.rate = 1,
    this.autoSpeak = false,
    this.conversation = false,
    this.vad = const VadEndpointConfig(),
    this.cues = true,
    this.debugRecordings = false,
    this.audioSource = VadAudioSource.communication,
  });

  factory VoicePreferences.read(SharedPreferences preferences) {
    int choice(String key, List<String> choices, int fallback) {
      final value = preferences.getString(key);
      return value != null && choices.contains(value)
          ? int.parse(value)
          : fallback;
    }

    return VoicePreferences(
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
      autoSpeak: preferences.getString(autoSpeakKey) == 'on',
      conversation: preferences.getString(conversationKey) == 'on',
      vad: VadEndpointConfig(
        pause: Duration(
          milliseconds: choice(vadPauseKey, vadPauseChoices, 1800),
        ),
        minSpeech: Duration(
          milliseconds: choice(vadMinSpeechKey, vadMinSpeechChoices, 250),
        ),
        preRoll: Duration(
          milliseconds: choice(vadPreRollKey, vadPreRollChoices, 300),
        ),
        maxDuration: Duration(seconds: choice(vadMaxKey, vadMaxChoices, 120)),
        noSpeechTimeout: Duration(
          seconds: choice(vadNoSpeechKey, vadNoSpeechChoices, 8),
        ),
      ),
      cues: preferences.getString(vadCuesKey) != 'off',
      debugRecordings: preferences.getString(vadDebugKey) == 'on',
      audioSource: preferences.getString(vadSourceKey) == 'recognition'
          ? VadAudioSource.recognition
          : VadAudioSource.communication,
    );
  }

  static VoiceProcessing _engine(String? value) => switch (value) {
    null || 'local' => VoiceProcessing.local,
    'hermes' => VoiceProcessing.hermes,
    _ => throw const FormatException(
      'Unknown voice processing choice. Choose an engine in App settings.',
    ),
  };
}

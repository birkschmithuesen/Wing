import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/vad_endpoint.dart';

/// communication = platform noise/echo processing; recognition = raw-ish.
enum VadAudioSource { communication, recognition }

/// Which microphone a vad round (dictation and the conversation loop's
/// re-opened rounds) records through. [auto] keeps HeadsetMicRoute's existing
/// rule: a connected headset's mic if there is one, else the phone. A manual
/// choice that is not currently available falls back to [auto] on the native
/// side and is reported once so the UI can show a hint (spec 2026-10-18).
enum VoiceMicRoute { auto, phone, bluetooth, wired }

/// Which on-phone recognizer the Local voice input uses. [parakeet] is the
/// fork's VAD + Parakeet route (formerly `voice.input = vad`).
enum VoiceLocalEngine { system, parakeet }

/// Device-owned voice choices of the offline (vad) route and the
/// hands-free conversation. Upstream's AppPreferences keeps the other choices.
class VoiceOfflinePrefs {
  static const localEngineKey = 'voice.local_engine';
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
  static const listenTurnKey = 'voice.listen_turn';
  static const listenMinSpeechKey = 'voice.listen_min_speech_ms';
  static const bargeInPlaybackKey = 'voice.barge_in_playback';
  static const micRouteKey = 'voice.mic_route';
  static const keys = {
    localEngineKey,
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
    listenTurnKey,
    listenMinSpeechKey,
    bargeInPlaybackKey,
    micRouteKey,
  };
  static const vadPauseChoices = [
    '1000',
    '1400',
    '1800',
    '2400',
    '3000',
    '4000',
    '5000',
  ];
  static const vadMinSpeechChoices = ['150', '250', '400'];
  static const vadPreRollChoices = ['200', '300', '500'];
  static const vadMaxChoices = ['600', '900', '1200', '1800'];
  static const vadNoSpeechChoices = ['5', '8', '12', '20'];
  static const listenMinSpeechChoices = ['250', '400', '600'];

  static bool accepts(String key, Object value) => switch (key) {
    localEngineKey => value == 'system' || value == 'parakeet',
    autoSpeakKey ||
    conversationKey ||
    vadCuesKey ||
    vadDebugKey ||
    listenTurnKey ||
    bargeInPlaybackKey => value == 'on' || value == 'off',
    vadPauseKey => vadPauseChoices.contains(value),
    vadMinSpeechKey => vadMinSpeechChoices.contains(value),
    vadPreRollKey => vadPreRollChoices.contains(value),
    vadMaxKey => vadMaxChoices.contains(value),
    vadNoSpeechKey => vadNoSpeechChoices.contains(value),
    vadSourceKey => value == 'communication' || value == 'recognition',
    listenMinSpeechKey => listenMinSpeechChoices.contains(value),
    micRouteKey =>
      value == 'auto' ||
          value == 'phone' ||
          value == 'bluetooth' ||
          value == 'wired',
    _ => false,
  };

  /// Read each completed reply aloud automatically (hands-free voice chat).
  final bool autoSpeak;

  /// Recognizer behind the Local voice input.
  final VoiceLocalEngine localEngine;

  /// Hands-free loop: a dictation that ends on its own is sent, the reply is
  /// read aloud (even with [autoSpeak] off) and the microphone reopens.
  final bool conversation;

  /// End-of-utterance settings for the Parakeet route.
  final VadEndpointConfig vad;

  /// Short tones for "listening" and "got it" on the vad route.
  final bool cues;

  /// Keep raw audio and VAD timing of each vad round on this phone.
  final bool debugRecordings;
  final VadAudioSource audioSource;

  /// Conversation mode on the vad route: keep listening while a turn runs
  /// and steer it with what was said.
  final bool listenTurn;

  /// Continuous speech that opens an utterance in a listen round.
  final Duration listenMinSpeech;

  /// Speaking during read-aloud stops it (offered after the echo gate).
  final bool bargeInPlayback;

  /// Microphone for vad rounds (dictation, conversation loop re-opens).
  final VoiceMicRoute micRoute;

  const VoiceOfflinePrefs({
    this.autoSpeak = false,
    this.conversation = false,
    this.vad = const VadEndpointConfig(),
    this.cues = true,
    this.debugRecordings = false,
    this.audioSource = VadAudioSource.communication,
    this.listenTurn = true,
    this.listenMinSpeech = const Duration(milliseconds: 400),
    this.bargeInPlayback = false,
    this.micRoute = VoiceMicRoute.auto,
    this.localEngine = VoiceLocalEngine.system,
  });

  /// Never throws: an unknown stored value falls back to its default.
  factory VoiceOfflinePrefs.read(SharedPreferences preferences) {
    int choice(String key, List<String> choices, int fallback) {
      final value = preferences.getString(key);
      return value != null && choices.contains(value)
          ? int.parse(value)
          : fallback;
    }

    return VoiceOfflinePrefs(
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
        maxDuration: Duration(seconds: choice(vadMaxKey, vadMaxChoices, 600)),
        noSpeechTimeout: Duration(
          seconds: choice(vadNoSpeechKey, vadNoSpeechChoices, 8),
        ),
      ),
      cues: preferences.getString(vadCuesKey) != 'off',
      debugRecordings: preferences.getString(vadDebugKey) == 'on',
      audioSource: preferences.getString(vadSourceKey) == 'recognition'
          ? VadAudioSource.recognition
          : VadAudioSource.communication,
      listenTurn: preferences.getString(listenTurnKey) != 'off',
      listenMinSpeech: Duration(
        milliseconds: choice(listenMinSpeechKey, listenMinSpeechChoices, 400),
      ),
      bargeInPlayback: preferences.getString(bargeInPlaybackKey) == 'on',
      micRoute: switch (preferences.getString(micRouteKey)) {
        'phone' => VoiceMicRoute.phone,
        'bluetooth' => VoiceMicRoute.bluetooth,
        'wired' => VoiceMicRoute.wired,
        _ => VoiceMicRoute.auto,
      },
      localEngine: preferences.getString(localEngineKey) == 'parakeet'
          ? VoiceLocalEngine.parakeet
          : VoiceLocalEngine.system,
    );
  }

  /// One-time move of the pre-merge route value `voice.input = vad`, which
  /// upstream's preference schema rejects, to `voice.input = local` plus
  /// `voice.local_engine = parakeet`. Idempotent; runs before AppPreferences
  /// reads the store.
  static Future<void> migrateLegacyVadRoute(
    SharedPreferences preferences,
  ) async {
    if (preferences.getString('voice.input') != 'vad') return;
    await preferences.setString(localEngineKey, 'parakeet');
    await preferences.setString('voice.input', 'local');
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/voice_processing_settings.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/voice_offline/voice_input_settings_for.dart';
import 'package:wing/voice_offline/voice_offline_prefs.dart';

void main() {
  test('legacy voice.input=vad migrates to local + parakeet, once', () async {
    SharedPreferences.setMockInitialValues({'voice.input': 'vad'});
    final prefs = await SharedPreferences.getInstance();
    await VoiceOfflinePrefs.migrateLegacyVadRoute(prefs);
    expect(prefs.getString('voice.input'), 'local');
    expect(prefs.getString(VoiceOfflinePrefs.localEngineKey), 'parakeet');
    await VoiceOfflinePrefs.migrateLegacyVadRoute(prefs);
    expect(prefs.getString('voice.input'), 'local');
  });

  test('migration keeps every other fork voice setting byte-identical (Q1)', () async {
    final before = <String, Object>{
      'voice.input': 'vad',
      'voice.output': 'local',
      'voice.android_language': 'de-DE',
      VoiceOfflinePrefs.autoSpeakKey: 'on',
      VoiceOfflinePrefs.conversationKey: 'on',
      VoiceOfflinePrefs.vadPauseKey: '2400',
      VoiceOfflinePrefs.vadMinSpeechKey: '400',
      VoiceOfflinePrefs.vadPreRollKey: '500',
      VoiceOfflinePrefs.vadMaxKey: '1200',
      VoiceOfflinePrefs.vadNoSpeechKey: '12',
      VoiceOfflinePrefs.vadCuesKey: 'off',
      VoiceOfflinePrefs.vadDebugKey: 'on',
      VoiceOfflinePrefs.vadSourceKey: 'recognition',
      VoiceOfflinePrefs.listenTurnKey: 'off',
      VoiceOfflinePrefs.listenMinSpeechKey: '600',
      VoiceOfflinePrefs.bargeInPlaybackKey: 'on',
      VoiceOfflinePrefs.micRouteKey: 'bluetooth',
    };
    SharedPreferences.setMockInitialValues(before);
    final prefs = await SharedPreferences.getInstance();
    final read = VoiceOfflinePrefs.read(prefs);
    await VoiceOfflinePrefs.migrateLegacyVadRoute(prefs);
    for (final entry in before.entries) {
      if (entry.key == 'voice.input') continue;
      expect(prefs.get(entry.key), entry.value, reason: entry.key);
    }
    expect(prefs.getKeys(), {...before.keys, VoiceOfflinePrefs.localEngineKey});
    final after = VoiceOfflinePrefs.read(prefs);
    expect(after.vad.pause, read.vad.pause);
    expect(after.vad.maxDuration, read.vad.maxDuration);
    expect(after.micRoute, read.micRoute);
    expect(after.conversation, read.conversation);
    expect(after.localEngine, VoiceLocalEngine.parakeet);
  });

  test('migration leaves other input values alone', () async {
    SharedPreferences.setMockInitialValues({'voice.input': 'hermes'});
    final prefs = await SharedPreferences.getInstance();
    await VoiceOfflinePrefs.migrateLegacyVadRoute(prefs);
    expect(prefs.getString('voice.input'), 'hermes');
    expect(prefs.getString(VoiceOfflinePrefs.localEngineKey), isNull);
  });

  test('local + parakeet resolves to the VAD route, system stays local', () async {
    SharedPreferences.setMockInitialValues({
      'voice.input': 'local',
      VoiceOfflinePrefs.localEngineKey: 'parakeet',
    });
    final prefs = await SharedPreferences.getInstance();
    final app = AppPreferences(prefs);
    addTearDown(app.dispose);
    expect(voiceInputSettingsFor(app, prefs), isA<VadVoiceInputSettings>());
    await prefs.setString(VoiceOfflinePrefs.localEngineKey, 'system');
    expect(voiceInputSettingsFor(app, prefs), isA<LocalVoiceInputSettings>());
  });

  test('hermes input ignores the local engine', () async {
    SharedPreferences.setMockInitialValues({
      'voice.input': 'hermes',
      VoiceOfflinePrefs.localEngineKey: 'parakeet',
    });
    final prefs = await SharedPreferences.getInstance();
    final app = AppPreferences(prefs);
    addTearDown(app.dispose);
    expect(voiceInputSettingsFor(app, prefs), isA<HermesVoiceInputSettings>());
  });

  test('local engine accepts only system and parakeet', () {
    expect(VoiceOfflinePrefs.accepts(VoiceOfflinePrefs.localEngineKey, 'parakeet'), isTrue);
    expect(VoiceOfflinePrefs.accepts(VoiceOfflinePrefs.localEngineKey, 'system'), isTrue);
    expect(VoiceOfflinePrefs.accepts(VoiceOfflinePrefs.localEngineKey, 'vad'), isFalse);
  });
}

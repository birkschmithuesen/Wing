import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/device_preference.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'package:wing/voice_offline/voice_offline_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('spoken replies toggle persists and rejects unknown values', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(VoiceOfflinePrefs.read(prefs).autoSpeak, isFalse);
    expect(VoicePreferences.keys, contains(VoiceOfflinePrefs.autoSpeakKey));
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.autoSpeakKey, 'on'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.autoSpeakKey, 'off'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.autoSpeakKey, 'yes'), isFalse);
    await saveDevicePreference(prefs, VoiceOfflinePrefs.autoSpeakKey, 'on');
    await prefs.reload();
    expect(VoiceOfflinePrefs.read(prefs).autoSpeak, isTrue);
    await saveDevicePreference(prefs, VoiceOfflinePrefs.autoSpeakKey, 'off');
    await prefs.reload();
    expect(VoiceOfflinePrefs.read(prefs).autoSpeak, isFalse);
  });

  test('conversation mode toggle persists and rejects unknown values', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(VoiceOfflinePrefs.read(prefs).conversation, isFalse);
    expect(VoicePreferences.keys, contains(VoiceOfflinePrefs.conversationKey));
    expect(
      VoicePreferences.accepts(VoiceOfflinePrefs.conversationKey, 'on'),
      isTrue,
    );
    expect(
      VoicePreferences.accepts(VoiceOfflinePrefs.conversationKey, 'yes'),
      isFalse,
    );
    await saveDevicePreference(prefs, VoiceOfflinePrefs.conversationKey, 'on');
    await prefs.reload();
    expect(VoiceOfflinePrefs.read(prefs).conversation, isTrue);
    expect(VoiceOfflinePrefs.read(prefs).autoSpeak, isFalse);
    await saveDevicePreference(prefs, VoiceOfflinePrefs.conversationKey, 'off');
    await prefs.reload();
    expect(VoiceOfflinePrefs.read(prefs).conversation, isFalse);
  });

  test('vad route and its settings persist with card defaults', () async {
    final prefs = await SharedPreferences.getInstance();
    final initial = VoicePreferences.read(prefs);
    final offline = VoiceOfflinePrefs.read(prefs);
    expect(initial.input, VoiceInputRoute.local);
    expect(offline.vad.pause, const Duration(milliseconds: 1800));
    expect(offline.vad.minSpeech, const Duration(milliseconds: 250));
    expect(offline.vad.preRoll, const Duration(milliseconds: 300));
    expect(offline.vad.maxDuration, const Duration(minutes: 10));
    expect(offline.vad.noSpeechTimeout, const Duration(seconds: 8));
    expect(offline.cues, isTrue);
    expect(offline.debugRecordings, isFalse);
    expect(offline.audioSource, VadAudioSource.communication);
    await saveDevicePreference(prefs, VoicePreferences.inputKey, 'vad');
    await saveDevicePreference(prefs, VoiceOfflinePrefs.vadPauseKey, '2400');
    await saveDevicePreference(prefs, VoiceOfflinePrefs.vadMinSpeechKey, '400');
    await saveDevicePreference(prefs, VoiceOfflinePrefs.vadPreRollKey, '500');
    await saveDevicePreference(prefs, VoiceOfflinePrefs.vadMaxKey, '900');
    await saveDevicePreference(prefs, VoiceOfflinePrefs.vadNoSpeechKey, '12');
    await saveDevicePreference(prefs, VoiceOfflinePrefs.vadCuesKey, 'off');
    await saveDevicePreference(prefs, VoiceOfflinePrefs.vadDebugKey, 'on');
    await saveDevicePreference(
      prefs,
      VoiceOfflinePrefs.vadSourceKey,
      'recognition',
    );
    await prefs.reload();
    final saved = VoicePreferences.read(prefs);
    final savedOffline = VoiceOfflinePrefs.read(prefs);
    expect(saved.input, VoiceInputRoute.vad);
    expect(saved.output, VoiceProcessing.local);
    expect(savedOffline.vad.pause, const Duration(milliseconds: 2400));
    expect(savedOffline.vad.minSpeech, const Duration(milliseconds: 400));
    expect(savedOffline.vad.preRoll, const Duration(milliseconds: 500));
    expect(savedOffline.vad.maxDuration, const Duration(minutes: 15));
    expect(savedOffline.vad.noSpeechTimeout, const Duration(seconds: 12));
    expect(savedOffline.cues, isFalse);
    expect(savedOffline.debugRecordings, isTrue);
    expect(savedOffline.audioSource, VadAudioSource.recognition);
  });

  test('vad choices are validated for backups; output never accepts vad', () {
    expect(VoicePreferences.accepts(VoicePreferences.inputKey, 'vad'), isTrue);
    expect(VoicePreferences.accepts(VoicePreferences.outputKey, 'vad'), isFalse);
    for (final key in [
      VoiceOfflinePrefs.vadPauseKey,
      VoiceOfflinePrefs.vadMinSpeechKey,
      VoiceOfflinePrefs.vadPreRollKey,
      VoiceOfflinePrefs.vadMaxKey,
      VoiceOfflinePrefs.vadNoSpeechKey,
      VoiceOfflinePrefs.vadCuesKey,
      VoiceOfflinePrefs.vadDebugKey,
      VoiceOfflinePrefs.vadSourceKey,
    ]) {
      expect(VoicePreferences.keys, contains(key));
      expect(VoicePreferences.accepts(key, '0'), isFalse, reason: key);
    }
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadPauseKey, '1800'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadPauseKey, '0'), isFalse);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadMaxKey, '1800'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadNoSpeechKey, '8'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadNoSpeechKey, '7'), isFalse);
    expect(
      VoicePreferences.accepts(VoiceOfflinePrefs.vadSourceKey, 'recognition'),
      isTrue,
    );
    expect(VoicePreferences.keys, isNot(contains('voice.vad_microphone')));
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadDebugKey, 'on'), isTrue);
  });

  test('vad pause accepts 4 s and 5 s for longer thinking pauses', () async {
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadPauseKey, '4000'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadPauseKey, '5000'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadPauseKey, '4500'), isFalse);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadPauseKey, '6000'), isFalse);
    SharedPreferences.setMockInitialValues({
      VoiceOfflinePrefs.vadPauseKey: '5000',
    });
    final prefs = await SharedPreferences.getInstance();
    expect(
      VoiceOfflinePrefs.read(prefs).vad.pause,
      const Duration(milliseconds: 5000),
    );
    SharedPreferences.setMockInitialValues({
      VoiceOfflinePrefs.vadPauseKey: '4500',
    });
    final invalid = await SharedPreferences.getInstance();
    expect(
      VoiceOfflinePrefs.read(invalid).vad.pause,
      const Duration(milliseconds: 1800),
    );
  });

  test('unknown stored vad values fall back to defaults', () async {
    SharedPreferences.setMockInitialValues({
      VoiceOfflinePrefs.vadPauseKey: '7',
      VoiceOfflinePrefs.vadNoSpeechKey: '99',
    });
    final prefs = await SharedPreferences.getInstance();
    final read = VoiceOfflinePrefs.read(prefs);
    expect(read.vad.pause, const Duration(milliseconds: 1800));
    expect(read.vad.noSpeechTimeout, const Duration(seconds: 8));
  });

  test('stored vad maximum below 10 minutes loads as the 10 minute default', () async {
    SharedPreferences.setMockInitialValues({
      VoiceOfflinePrefs.vadMaxKey: '120',
    });
    final prefs = await SharedPreferences.getInstance();
    expect(VoiceOfflinePrefs.read(prefs).vad.maxDuration, const Duration(minutes: 10));
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.vadMaxKey, '120'), isFalse);
    for (final value in VoiceOfflinePrefs.vadMaxChoices) {
      expect(int.parse(value), greaterThanOrEqualTo(600));
    }
  });

  test('barge-in preferences: defaults, parsing and validation', () async {
    SharedPreferences.setMockInitialValues({});
    var prefs = await SharedPreferences.getInstance();
    var read = VoiceOfflinePrefs.read(prefs);
    expect(read.listenTurn, isTrue);
    expect(read.listenMinSpeech, const Duration(milliseconds: 400));
    expect(read.bargeInPlayback, isFalse);
    SharedPreferences.setMockInitialValues({
      VoiceOfflinePrefs.listenTurnKey: 'off',
      VoiceOfflinePrefs.listenMinSpeechKey: '600',
      VoiceOfflinePrefs.bargeInPlaybackKey: 'on',
    });
    prefs = await SharedPreferences.getInstance();
    read = VoiceOfflinePrefs.read(prefs);
    expect(read.listenTurn, isFalse);
    expect(read.listenMinSpeech, const Duration(milliseconds: 600));
    expect(read.bargeInPlayback, isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.listenMinSpeechKey, '150'), isFalse);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.listenTurnKey, 'on'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.bargeInPlaybackKey, 'maybe'), isFalse);
    expect(VoicePreferences.keys, containsAll([
      VoiceOfflinePrefs.listenTurnKey,
      VoiceOfflinePrefs.listenMinSpeechKey,
      VoiceOfflinePrefs.bargeInPlaybackKey,
    ]));
  });

  test('mic route: defaults to automatic, persists and rejects unknown values', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(VoiceOfflinePrefs.read(prefs).micRoute, VoiceMicRoute.auto);
    expect(VoicePreferences.keys, contains(VoiceOfflinePrefs.micRouteKey));
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.micRouteKey, 'auto'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.micRouteKey, 'phone'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.micRouteKey, 'bluetooth'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.micRouteKey, 'wired'), isTrue);
    expect(VoicePreferences.accepts(VoiceOfflinePrefs.micRouteKey, 'usb'), isFalse);
    await saveDevicePreference(prefs, VoiceOfflinePrefs.micRouteKey, 'bluetooth');
    await prefs.reload();
    expect(VoiceOfflinePrefs.read(prefs).micRoute, VoiceMicRoute.bluetooth);
    await saveDevicePreference(prefs, VoiceOfflinePrefs.micRouteKey, 'wired');
    await prefs.reload();
    expect(VoiceOfflinePrefs.read(prefs).micRoute, VoiceMicRoute.wired);
  });

  test('an unknown stored mic route falls back to automatic', () async {
    SharedPreferences.setMockInitialValues({
      VoiceOfflinePrefs.micRouteKey: 'usb',
    });
    final prefs = await SharedPreferences.getInstance();
    expect(VoiceOfflinePrefs.read(prefs).micRoute, VoiceMicRoute.auto);
  });
}

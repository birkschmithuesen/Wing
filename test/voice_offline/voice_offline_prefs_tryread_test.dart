import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'package:wing/voice_offline/voice_offline_prefs.dart';

void main() {
  test('tryReadVoicePreferences returns null where read throws', () async {
    SharedPreferences.setMockInitialValues({'voice.input': 'bogus'});
    final prefs = await SharedPreferences.getInstance();
    expect(() => VoicePreferences.read(prefs), throwsFormatException);
    expect(tryReadVoicePreferences(prefs), isNull);
  });

  test('tryReadVoicePreferences reads valid values like read', () async {
    SharedPreferences.setMockInitialValues({'voice.input': 'vad'});
    final prefs = await SharedPreferences.getInstance();
    expect(tryReadVoicePreferences(prefs)?.input, VoiceInputRoute.vad);
  });

  test('fork preferences keep their defaults', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final offline = VoiceOfflinePrefs.read(prefs);
    expect(offline.listenTurn, isTrue);
    expect(offline.bargeInPlayback, isFalse);
    expect(offline.vad.pause, const Duration(milliseconds: 1800));
  });
}

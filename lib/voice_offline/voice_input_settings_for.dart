import 'package:shared_preferences/shared_preferences.dart';

import '../core/models/voice_processing_settings.dart';
import '../core/services/app_preferences.dart';
import 'voice_offline_prefs.dart';

/// Upstream's typed voice input choice, with Local narrowed to the fork's
/// Parakeet route when `voice.local_engine = parakeet`. Null means upstream
/// flags the input preference for repair.
VoiceInputSettings? voiceInputSettingsFor(
  AppPreferences app,
  SharedPreferences preferences,
) {
  final base = app.current.voiceInputSettings;
  if (base is LocalVoiceInputSettings &&
      VoiceOfflinePrefs.read(preferences).localEngine ==
          VoiceLocalEngine.parakeet) {
    return const VadVoiceInputSettings();
  }
  return base;
}

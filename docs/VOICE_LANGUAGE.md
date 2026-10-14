# Voice output language (DE/EN)

Wing reads replies sentence by sentence in German or English. Detection runs on the phone, offline.

## How it works
- `lib/voice_offline/sentence_splitter.dart` splits the spoken text into paragraphs and sentences; no word is cut.
- `lib/voice_offline/language_guess.dart` counts German and English function words per sentence
  (plus umlauts for German). English needs at least 2 hits and twice the German count. Nouns never count, so
  "Pull Request" or "Kanban" inside a German sentence stays German.
- Unsure sentences take the previous decided language, else the next, else German.
- `lib/voice_offline/speech_segments.dart` merges neighbours of the same language; `AndroidVoice.speak` sends
  them as `segments`.
- `android/.../voiceoffline/LanguageSpeech.kt` calls `setLanguage(de_DE | en_US)` before each segment and
  queues it. If English is not installed in the TTS engine, the segment is spoken with the German voice.
- The gateway output route (Hermes TTS) is not affected.

## Phone setup (SherpaTTS)
- SherpaTTS keeps one model per language. Install English via SherpaTTS → Manage languages.
- Installing a language makes it SherpaTTS's current language. Set German back as current language so the
  engine preloads German after a restart. Wing sets the language per sentence. Doing so also rewrites
  SherpaTTS's current language, which only affects which model the engine preloads after a restart. Apps that
  set no language get the system TTS locale (German).
- Default English voice: Piper `en_GB-alba-medium`. To change it, delete English in SherpaTTS and install
  another English model. Wing needs no change.

## Logs
`adb logcat -s WingTtsLang` shows one line per segment:
`segment 2/3 lang=en status=0 ms=4 chars=187`. `status` is the `setLanguage`/`setVoice` result (≥ 0 = ok);
`fallback=de` means the language was not available. Logs never contain reply text.

# Wing TTS language detection (DE/EN) — Design

Card `t_d523010d` (board `wing`), 2026-10-13. Status: design, documents only.

## 1. Problem and goal

Wing reads text replies aloud on the phone with the system's offline TTS. That engine runs only a German model,
so English replies and English quotes inside German replies come out unintelligible. Mixed replies (German
frame, English quote) are normal.

Goal: Wing detects the language **per sentence** (DE or EN) on the device and speaks each sentence with a
matching voice. There is no manual switch. When detection is unsure, Wing uses German. Speech chunks never cut
a word.

Out of scope:
- the gateway route `VoiceProcessing.hermes` (server TTS),
- the choice of the final English voice (Birk decides by ear, concept B4),
- more than two languages,
- pronunciation lexicon / number expansion (concept B2), streaming (concept B3).

## 2. Facts (with evidence)

### 2.1 Wing today (code at `voice-offline` = `7bf6c354`)

| Fact | Evidence |
|---|---|
| TTS is created without an engine argument, so the system default engine is used. | `android/app/src/main/kotlin/com/tarkilhk/wing/VoicePlayback.kt:64` `TextToSpeech(activity.applicationContext) { … }` |
| Wing never sets a TTS language. There is no `setLanguage` in any Kotlin file and no output-language setting in Dart. | `grep -rn setLanguage android/ lib/` → no hit. `voice.android_language` (`lib/core/services/voice_preferences.dart:9`) is used only for recognition (`VoiceCapture.kt:38`). |
| Voice choice: the voice chosen in settings, else an installed voice matching `Locale.getDefault()`, else the engine default. | `VoicePlayback.kt:111-115`; comment at L113: "Engines like SherpaTTS may list no Voice objects; use the engine default then." |
| Text is cut by character count, so a word can be split between two utterances. | `VoicePlayback.kt:118` `text.chunked(TextToSpeech.getMaxSpeechInputLength() - 1)` |
| Utterance contract: ids `"$owner:$index"`, last one `"$owner:last"`; all with `QUEUE_ADD`; `onDone("$owner:last")` resolves the Dart call. | `VoicePlayback.kt:119-121`, listener L68-81, `finishPlayback` L141-146 |
| Audio: `USAGE_MEDIA` + `CONTENT_TYPE_SPEECH`, transient focus. | `VoicePlayback.kt:24-25`, L94-99 |
| Channel `com.tarkilhk.wing/voice`, method `speak(id, text, voice, rate)`; no language argument. | `VoiceChannel.kt:12`, L53-54; `lib/core/services/android_voice.dart:84-94` |
| Dart prepares text with `spokenReplyText` (drops think blocks, code, images; paragraphs end with `\n`, blank line between blocks). | `lib/core/controllers/voice_output_controller.dart:10-49` |
| Local vs gateway output is decided in `VoiceOutputController.speak`. | `voice_output_controller.dart:94-106` |
| All callers of local speech (reply read-aloud, conversation mode, voice preview, admin page) go through `VoiceDevice.speak` → `AndroidVoice.speak`. | callers: `profile_workspace_screen.dart`, `voice_preferences_card.dart`, `admin_speech_synthesis_page.dart` (via `VoiceOutputController`) |
| There are no Kotlin unit tests; CI runs only `flutter analyze` + `flutter test`. | no `android/app/src/test`; `.github/workflows/pr-quality.yml:55,63`; `voice-apk.yml:37` |

### 2.2 Phone (Birk, 13.10., via `hadb`)

- System TTS engine `org.woheller69.ttsengine` (SherpaTTS 3.4, versionCode 34), the only TTS service.
- `settings secure tts_default_locale` = `org.woheller69.ttsengine:de`.
- Installed model: only `files/deuDE` (Piper thorsten-medium) + `espeak-ng-data`; engine pref `current_language = deu`.
- Wing package `com.tarkilhk.wing.voice`.

### 2.3 SherpaTTS upstream (woheller69/ttsengine, tag `V3.4` = commit `36de213`, equal to upstream main at inspection)

Paths under `app/src/main/java/com/k2fsa/sherpa/onnx/tts/engine/`.

| Fact | Evidence |
|---|---|
| `onSynthesizeText` reads `request.language` for **every** request, checks it with `onIsLanguageAvailable` and calls `TtsEngine.createTts(application, language)` before synthesis. The voice name is never read. | `TtsService.kt:68-124` |
| `onIsLanguageAvailable` compares only the ISO-3 language (`deu`, `eng`); country is ignored. | `TtsService.kt:33-40` |
| `createTts` keeps one `OfflineTts` per language in `ttsCache`; switching to a cached language is a pointer swap. The first use of a language loads the model from disk. | `TtsEngine.kt:52-65`, `initTts` L84-124; commit `638c0b2` "Caching of TtsEngines" (2025-09-09) |
| Several languages can be installed side by side (`<lang><country>/` dirs, e.g. `deuDE`, `engUS`), but **one model per language**. | `TtsEngine.kt:91`, `Downloader.java:61`; `ManageLanguagesActivity.kt:45-49`; issue #1 |
| Installing a language **sets `current_language` to it**. | `Downloader.java:118`, `ManageLanguagesActivity.kt:205` |
| The engine overrides no voice methods (`onGetVoices`, `onLoadVoice`, …); `setVoice` cannot switch its language. | `TtsService.kt` (grep) |
| No language detection in the engine. The maintainer: "the reader app has to detect the language and request from tts engine." | issue #52; open feature request #140 |
| If a request's language is not installed, the engine calls `callback.error()`. | `TtsService.kt:68-124` |

**Verdict:** SherpaTTS 3.4 can serve DE and EN per utterance when the calling app sets the language per
utterance, provided an English model is installed next to the German one. `setVoice` does not work for this;
`setLanguage` (or the request's language parameter) does.

### 2.4 Android framework (aosp-mirror/platform_frameworks_base main, `1cdfff55`)

| Fact | Evidence |
|---|---|
| `setLanguage(loc)` converts to ISO-3 on the client and writes language/country/voice name into the `TextToSpeech` object's `mParams`. | `core/java/android/speech/tts/TextToSpeech.java:1579-1655`, writes at L1648-1651 |
| `speak()` sends `getParams(params)` = the current `mParams` (copied, then per-call params on top). The language therefore binds to each utterance at `speak()` time. | `TextToSpeech.java:1228-1240`, `getParams` L2024-2045 |
| The service puts the params' language into the `SynthesisRequest`. | `TextToSpeechService.java:1047-1052`, L1084-1085 |

ANNAHME (verify on the device, Task 6): `setLanguage` on SherpaTTS returns `LANG_AVAILABLE` (≥ 0) for `de` and
`en` through the framework's default voice methods, and the model load it triggers runs in the engine's queue,
not on Wing's main thread. The acceptance logs measure the call duration.

### 2.5 sherpa-onnx (k2-fsa/sherpa-onnx, tag v1.13.8 = `11afbd00`)

`sherpa-onnx/kotlin-api/Tts.kt` provides `OfflineTts`, `OfflineTtsConfig`, `OfflineTtsVitsModelConfig(model,
tokens, dataDir=espeak-ng-data)`, `generate(text, sid, speed): GeneratedAudio(samples, sampleRate)` (L6-10, L94,
L108, L116, L141, L162). It loads the same `sherpa-onnx-jni` as VAD/ASR (L271). ANNAHME: the 1.13.8 AAR that the
VAD chain fetches contains `OfflineTts` (not unzipped).

## 3. Approaches

### A. Wing segments and detects; the system engine speaks each segment in its language (recommended)

Wing splits the reply into sentences, guesses DE/EN per sentence in Dart, merges neighbours of the same language
and sends the list over the existing channel. Kotlin calls `setLanguage` before each `speak()`. An English
Piper model is installed into SherpaTTS on the phone (no Wing download code).

- **Pro:** smallest change; no new dependency; works with any system engine that honours the request
  language (SherpaTTS, RHVoice, Google TTS on other phones). The engine's own queue plays the segments back to
  back. Logic sits in Dart, so CI tests it.
- **Con:** depends on SherpaTTS state on the phone (English installed, `current_language` back to `deu`).
  First switch to English after an engine restart pays one model load (ANNAHME 1-3 s, measured in Task 6).
  Only one English voice installed at a time (engine limit).

### B. Wing synthesizes itself with sherpa-onnx `OfflineTts`

Wing holds its own DE and EN Piper models, generates PCM and plays it via `AudioTrack`.

- **Pro:** full control (voice per segment, preload, future B4 voices like supertonic); independent of the
  system engine.
- **Con:** much larger: model download/import and storage (~2 × 67 MB archives), PCM playback, focus/stop/
  progress events and the `$owner:last` contract rebuilt; it depends on the VAD chain's AAR, and none of the
  Kotlin is CI-tested. It duplicates what the installed engine already does.

### C. A second TTS engine for English

Install another engine (e.g. RHVoice) and create a second `TextToSpeech(context, listener, enginePackage)` for
English segments.

- **Con:** two queues to keep in order (gaps, stop races); worse English quality than Piper; still needs the
  detector of A.

**Decision: A.** It meets the goal with thin hooks and keeps B open: the segment list from A is exactly the
input B would need if the voice comparison (B4) later moves synthesis into Wing.

## 4. Design

### 4.1 Units

| Unit | File | Responsibility |
|---|---|---|
| Sentence splitter | `lib/voice_offline/sentence_splitter.dart` (new) | `List<List<String>> splitSpeech(String text, {int maxLength})`: paragraphs → sentences; no word is ever cut. |
| Language guess | `lib/voice_offline/language_guess.dart` (new) | `SpeechLanguage? guessLanguage(String sentence)`: `de`, `en` or `null` (unsure). |
| Segment builder | `lib/voice_offline/speech_segments.dart` (new) | `List<SpeechSegment> speechSegments(String text)`: split, guess, resolve unsure, merge neighbours; `toChannel()` for the wire format. |
| Dart hook | `lib/core/services/android_voice.dart` (2 lines) | `AndroidVoice.speak` adds `'segments': speechSegmentsPayload(text)` to the channel arguments. `VoiceDevice` interface, controller and fixtures stay unchanged. |
| Segment queue | `android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/LanguageSpeech.kt` (new) | `LanguageSpeech.enqueue(tts, owner, text, segments, voice)`: per segment choose voice/language, `speak(QUEUE_ADD)`, keep the `$owner:last` contract, log the decision. |
| Kotlin hooks | `VoiceChannel.kt:53-54`, `VoicePlayback.kt:104,118-122` | pass `segments` through; replace the `chunked` loop with one call. |

### 4.2 Wire format

`speak` gets one new optional argument:

```
'segments': [ {'text': 'Hier ist die Bio.', 'lang': 'de'}, {'text': 'Robo is a friendly …', 'lang': 'en'} ]
```

`text` stays (old Kotlin ignores `segments`; new Kotlin without `segments` falls back to whitespace-safe
chunking of `text` in German/default behaviour).

### 4.3 Segmentation

1. Paragraphs: split on blank lines (`\n\s*\n`). Lines inside a paragraph (list items) are sentence boundaries.
2. Sentences: boundary after `.`, `!`, `?`, `…` (optionally followed by closing quotes/brackets) **plus
   whitespace**, when the next character is not lowercase. No boundary after known abbreviations (`z.B.`,
   `d.h.`, `u.a.`, `bzw.`, `ca.`, `usw.`, `vgl.`, `Nr.`, `Dr.`, `Prof.`, `e.g.`, `i.e.`, `etc.`, `vs.`, `Mr.`,
   `Mrs.`, `Ms.`), single-letter initials, or between digits (`3.4`).
3. A sentence longer than `maxLength` (default 1000 chars) is split at the last `, ; :` before the limit,
   else the last whitespace; only a single token longer than the limit is cut hard.
4. Kotlin defends against engine limits: a segment longer than `getMaxSpeechInputLength() - 1` is split at the
   last whitespace before the limit (never mid-word unless one token exceeds it).

### 4.4 Language guess (exactly DE vs EN, on-device, no cloud)

Options considered:
- **ML Kit Language ID:** the bundled variant runs without Play services, but the ML Kit SDK has its own
  usage/diagnostics logging to Google (ANNAHME, docs not reachable from this machine). That conflicts with "no US
  cloud for reply text / usage data" and adds ~1 MB model + Google dependency. Rejected.
- **Android `TextClassifier.detectLanguage`:** depends on a system lang-id model that LineageOS may not ship
  (ANNAHME); behaviour differs per device. Rejected.
- **Stopword heuristic in Dart (chosen):** two languages only, deterministic, CI-testable, zero dependencies.

Rule per sentence (lowercased words `[a-zäöüß']+`):
- `de` = number of words in the German function-word list + 1 per word containing `ä ö ü ß`.
- `en` = number of words in the English function-word list (incl. contractions `it's`, `don't`, `i'm`, …).
- Words in both languages or ambiguous are in neither list: `in`, `an`, `so`, `was`, `will`, `also`, `man`, `a`,
  `hand`, `bad`, `rat`, `gift`, `kind`, `fast`, `rock`, `still`, `top`.
- Result: `en` if `en ≥ 2` and `en ≥ 2 × de`; `de` if `de ≥ 1` and `de ≥ en`; otherwise `null` (unsure).

Consequences:
- English terms inside a German sentence stay German: "Ich habe den Pull Request für das Kanban-Board
  vorbereitet." → `de=6` (`ich habe den für das` = 5, plus 1 for the `ü` in `für`), `en=0` → `de`. Nouns are
  not in any list, so they never count as evidence.
- A one-word fragment ("Kanban.", "Thanks!") has no evidence → unsure.

Unsure sentences take the language of the **previous** decided sentence in the reply, else the next decided
one, else German. So a heading inside an English quote stays English, and a reply without evidence is German.

Finally, neighbouring sentences with the same language are merged into one segment (joined with a space inside
a paragraph, `\n` across paragraphs) up to `maxLength`. Fewer utterances mean fewer switches and gaps.

### 4.5 Voice per segment (Kotlin)

```
for each segment i:
  locale = if lang == "en" Locale.US else Locale.GERMANY
  if chosen voice != null and chosen.locale.language == locale.language -> setVoice(chosen)
  else status = setLanguage(locale)
       if status < LANG_AVAILABLE (missing/not supported):
           setLanguage(Locale.GERMANY) or setVoice(chosen) (fallback), log fallback=de
  speak(segmentText, QUEUE_ADD, null, i == last ? "$owner:last" : "$owner:$i")
  Log.i("WingTtsLang", "segment ${i+1}/$n lang=$lang status=$status ms=$elapsed chars=${text.length}")
```

- `chosen` is the voice found today at `VoicePlayback.kt:111-112` (settings voice or default-locale voice). For
  SherpaTTS it may be `null` (no voice list) or a framework-built voice; both paths end in `setLanguage`.
- The log never contains reply text (privacy), only language, status, timing and length.
- Locale per language is one constant map in `LanguageSpeech.kt`, so the English variant (US/GB) is a one-line
  change. SherpaTTS ignores the country.
- Gaps: all segments are queued at once with `QUEUE_ADD`; the engine plays them back to back. After the first
  English load, switching is a cache pointer swap.

### 4.6 Error handling

| Case | Behaviour |
|---|---|
| English not installed in the engine (`setLanguage` < 0) | Speak the segment with the German/default voice (today's behaviour), log `fallback=de`. No user-visible error. |
| Engine rejects a segment at synthesis | Existing `onError` → `finishPlayback(owner, "Android could not generate speech with this voice.")` (unchanged). |
| `segments` missing/empty (older Dart, preview edge case) | Kotlin uses `text`, split whitespace-safe, no language set (today's voice logic). |
| Stop during queueing | Unchanged: `stop()` calls `tts.stop()`, which flushes the engine queue; enqueueing runs synchronously on the main thread inside `withTts`, so it cannot interleave with `stop()`. |

### 4.7 Phone setup (Hermes worker, not code)

1. In SherpaTTS → Manage languages, install the default English voice (4.8).
2. Because install sets `current_language` to English, set the engine language back to German in SherpaTTS so
   other apps keep German. Check `tts_default_locale` is still `org.woheller69.ttsengine:de`.

### 4.8 Default English voice

Piper `en_GB-alba-medium` (sherpa-onnx archive `vits-piper-en_GB-alba-medium.tar.bz2`, 67,212,349 bytes; model
≈ 63 MB, same size class as thorsten-medium). Offered in SherpaTTS's list (`res/values/arrays.xml:35-77`).
ANNAHME (license): dataset CSTR Alba, CC BY 4.0 — check the Piper `MODEL_CARD` before relying on it. Wing does
not bundle or redistribute the model; the engine downloads it, so the license matters only for private use.

Alternatives for the listening test: `en_US-amy-medium` (67,223,746 bytes), `en_GB-cori-medium` (67,257,412
bytes); avoid `en_US-lessac` and `en_GB-jenny_dioco` (ANNAHME: restrictive licenses). Replacing the voice is an
engine action (delete language, install another); Wing code does not change.

RAM: two cached Piper medium models in the SherpaTTS process. ANNAHME ~150-250 MB; observe in Task 6.

## 5. Testing

- Dart unit tests (CI, `flutter test`):
  - splitter: abbreviations, decimals, quotes, list lines, long sentences, no word cut;
  - guess: table of German, English, mixed, English terms in German, fragments;
  - segments: unsure resolution, merge, the acceptance text gives `de, en, de`;
  - hook: `AndroidVoice.speak` sends `segments` (mocked channel).
- Kotlin has no unit tests in this repo; it compiles in `voice-apk.yml` and is verified on the device.
- On-device acceptance (Hermes worker + Birk): fixed synthetic mixed text, logcat `WingTtsLang` lines, Birk's
  by-ear confirmation.

## 6. Upstream compatibility and overlap

New logic lives in new files (`lib/voice_offline/`, `…/wing/voiceoffline/`). Upstream files get thin hooks:

| File | Change | Other chains touching it |
|---|---|---|
| `lib/core/services/android_voice.dart` | +1 import, +1 map entry in `speak` | VAD chain `t_24ef9c3d` (plan: modified); merged `t_99f481cb` |
| `android/.../VoiceChannel.kt` | `speak` passes `segments` (L53-54) | VAD chain (Task 9 etc.); `t_49d11117` (1 line, already merged) |
| `android/.../VoicePlayback.kt` | signature + replace L118-122 | none |
| new `lib/voice_offline/*`, `test/voice_offline/*`, `…/voiceoffline/LanguageSpeech.kt`, `docs/VOICE_LANGUAGE.md` | — | none |

Not touched: `voice_output_controller.dart`, `voice_fixture.dart`, `voice_processing_test.dart` (max dictation
`t_d3a672fe` and the VAD chain edit those), `build.gradle.kts`, `pubspec.yaml`, `voice-apk.yml`.

## 7. Basis / Rebase

Start from `voice-offline` **after** the VAD chain is merged (`t_24ef9c3d` → merge `t_145c5731`) and after
`t_d3a672fe`, per strategy rule 3 ("merge never into a running voice chain"): the VAD chain edits
`android_voice.dart` and `VoiceChannel.kt`. The upstream merge `t_d1d49ff1` is parked until after the VAD
merge; if it lands first, start after it too. Re-check every file:line in this document against the start
commit (plan, "Basis / Rebase").

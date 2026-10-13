# Wing Voice: input route "vad" (own capture, Silero end-of-utterance, Parakeet on the phone)

Status: design, 2026-10-13. Card t_50c3cc71 (plan); implementation card t_24ef9c3d.
Inspected: Wing fork `voice-offline` at `2154167` (code map from `3ee793e` re-checked, unchanged);
sherpa-onnx tag `v1.13.8` (sources read through the GitHub contents API, see "Verified facts").
Related: concept part A (`hermes-entities/tools/technik/wing-voice-auto-konzept.md`), measurement report
(`wing-voice-messung-2026-10.md`), handover (`hermes-android-voice-uebergabe.md`).

## 1. Goal

Wing Voice must reliably end an utterance by itself in a moving car. A new voice input route **"vad"** records
with `AudioRecord`, detects end of speech with Silero VAD and transcribes **on the phone** with Parakeet TDT 0.6B
v3 int8 (sherpa-onnx, `nemo_transducer`). No audio leaves the phone on this route. The routes **"local"**
(system `SpeechRecognizer` / Offline Voice Input) and **"hermes"** (`MediaRecorder` → gateway `transcribe`) stay
selectable and their code paths stay unchanged.

Fixed decisions (Birk, 13.10.2026, not reopened): STT on the phone with Parakeet via sherpa-onnx; model not in the
APK but downloaded once into app-private storage with a SHA256 check (alternative: pre-placed via `hadb`); visible
progress and errors; preload at app start; Silero may ship as an APK asset; Offline Voice Input untouched.
Out of scope: speech output (concept part B), barge-in, an upstream PR to tarkilhk/Wing.

Hermes constraint (AGENTS.md): the route is client-only. It uses no server endpoint at all. No backend change.

### 1.1 Scope change: microphone setting gestrichen (Birk 13.10.)

Scope item 3 of the brief ("Setting microphone: phone / Bluetooth hands-free (SCO)") is **gestrichen (Birk 13.10.)**.
The microphone is always whatever Android currently routes for recording. Wing does no own Bluetooth SCO activation
(no `startBluetoothSco`, no `setCommunicationDevice`) and has no microphone preference.

Measured finding behind it (Birk, 13.10. 16:20): the car was connected via Bluetooth, and `BT SCO Headset Mic` was
available as an input device, but `mBtScoOnByApp=false`. Playback went through the car (A2DP); recording
(`VOICE_RECOGNITION`) stayed on the built-in phone mic. With the phone far away, the level was about 1/100 of close
speech, no speech start was detected, and Offline Voice Input's 7 s emergency stop ended the round. **Consequence:
the vad chain must work with the built-in phone mic in driving noise.** The debug JSON records the actually routed
input device (`AudioRecord.getRoutedDevice()`), read-only, for diagnosis.

The 7 s emergency stop belongs to Offline Voice Input (route local). Route vad does not use it. It has its own
explicit no-speech timeout (section 4, a setting, default 8 s) and the 120 s maximum from the card.

### 1.2 Audio source (open question, decided by measurement)

`VOICE_COMMUNICATION` (platform noise suppression + echo cancellation) is the default, with `VOICE_RECOGNITION` as
the fallback when it cannot initialize. The source stays selectable through the debug-only setting "Audio source", and
the debug JSON records it. How it gets decided:
- **The car recording cannot compare sources.** `auto-2026-10-13-1528.wav` is one fixed file. It is used offline to
  tune and verify the endpoint parameters (pause, min speech, no-speech timeout) on real driving noise with the phone
  mic (plan Task 5).
- **On-device A/B** (plan Task 15): the same synthetic sentence + noise file through the phone speaker, one round per
  source, then compare the debug JSON (speech start/end windows, max p, p percentiles in the noise lead).
- Caveat, and why the A/B is not the final word: echo cancellation on `VOICE_COMMUNICATION` may treat audio the phone
  plays itself as echo and suppress it. The speaker A/B is therefore biased against `VOICE_COMMUNICATION` and cannot
  reproduce a real voice in a real car. The deciding comparison is Birk's test drive with debug on, alternating the
  source between rounds. The plan prepares this but does not perform it. Until then the default stays
  `VOICE_COMMUNICATION`. A default change is a one-line, reversible change after that drive.

## 2. Verified facts that shape the design

### 2.1 Test layers in CI (checked)

- `tools/factory/ci-suite.sh` pushes HEAD to `ci/<sha12>` and dispatches `.github/workflows/pr-quality.yml`.
  **It ignores any test-path argument**: it always runs the whole workflow.
- `pr-quality.yml` runs `python3 -m unittest discover -s scripts/tests -v`, `python3 scripts/release.py check`,
  `flutter analyze --no-pub --fatal-infos` and `flutter test --no-pub`. **No Gradle, no Kotlin compilation and no
  `testDebugUnitTest`.** `android/app/build.gradle.kts` has no test dependencies and there is no `src/test`.
- `voice-apk.yml` (push to `voice-offline` or `workflow_dispatch`) runs three voice Dart tests, builds the unsigned
  arm64 voice APK and force-pushes it to branch `voice-apk-bin`. It is the only job that compiles Kotlin.

Consequence: **the endpoint state machine is pure Dart** (`lib/core/services/vad_endpoint.dart`) and is tested by
`flutter test` in CI. Kotlin stays a thin I/O layer. Kotlin compile errors are caught by a `voice-apk.yml` run.
The plan adds a `publish` input to that workflow, so compile checks do not overwrite `voice-apk-bin`.

### 2.2 sherpa-onnx v1.13.8 (read at tag v1.13.8)

- Kotlin package `com.k2fsa.sherpa.onnx` (`sherpa-onnx/kotlin-api/`):
  - `class Vad(assetManager: AssetManager? = null, var config: VadModelConfig)` with `compute(samples: FloatArray): Float`
    (the Silero speech probability; JNI `Vad_compute` returns `-1f` on error), `acceptWaveform`, `isSpeechDetected`,
    `empty/front/pop/clear/reset/flush`, `release()`.
  - `SileroVadModelConfig(model, threshold = 0.5F, minSilenceDuration = 0.25F, minSpeechDuration = 0.25F,
    windowSize = 512, maxSpeechDuration = 5.0F)`;
    `VadModelConfig(sileroVadModelConfig, tenVadModelConfig, sampleRate = 16000, numThreads = 1, provider = "cpu", debug = false)`.
  - `OfflineRecognizer(assetManager: AssetManager? = null, val config: OfflineRecognizerConfig)` with
    `createStream()`, `decode(stream)`, `getResult(stream).text`, `release()`; `OfflineStream.acceptWaveform(samples: FloatArray, sampleRate: Int)`, `release()`.
  - `OfflineRecognizerConfig(featConfig = FeatureConfig(sampleRate = 16000, featureDim = 80), modelConfig, decodingMethod = "greedy_search", …)`;
    `OfflineModelConfig(transducer = OfflineTransducerModelConfig(encoder, decoder, joiner), numThreads = 1, provider = "cpu", modelType = "", tokens = "", …)`.
  - The official config for this model (`getOfflineModelConfig(type = 40)`) uses
    `encoder.int8.onnx / decoder.int8.onnx / joiner.int8.onnx / tokens.txt` and `modelType = "nemo_transducer"`.
  - With `assetManager = null` both classes use `newFromFile` (plain filesystem paths). With an `AssetManager` they read from APK assets.
- Silero v5 (`silero-vad-model.cc`): `window_size` must be 512 at 16 kHz, or the process **aborts**
  (`SHERPA_ONNX_EXIT`). `Run()` does not check `n`, keeps the recurrent state between calls, and
  `WindowSize()` = 512 + 64 overlap = **576** for the detector's own path. **So Wing feeds 576 samples per
  window to `compute`: the last 64 samples of the previous window followed by 512 new samples.**
- `VoiceActivityDetector::Reset()` also resets the model state. Wing nevertheless creates a **new `Vad` per round**
  (644 kB model, so creation is cheap) and never mixes `compute` with `acceptWaveform`.
- Python binding: there is **no** probability API (`VadModel.is_speech` returns a bool). The offline check on the
  vServer therefore runs `silero_vad.onnx` directly with onnxruntime (see 7.4).
- Distribution: release asset `sherpa-onnx-1.13.8.aar` (50,129,134 bytes, digest
  `633c24321e06b1fe79feafa03ea16cbc0f8a286641e2da3559bac91bdb13bd96` per the GitHub API). The official example apps
  copy the Kotlin sources and the `jniLibs` instead of using the AAR.
  `ANNAHME:` the AAR contains `classes.jar` with `com/k2fsa/sherpa/onnx/Vad.class` (including `compute`) and
  `jni/arm64-v8a/libsherpa-onnx-jni.so` (+ `libonnxruntime.so`). Plan task 1 checks this with a script on the vServer
  before anything else; if it fails, the fallback is to copy the kotlin-api sources and the AAR's `.so` files.

### 2.3 Model files (checked on the vServer)

- Parakeet archive `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2`: **487,170,055 bytes**, SHA256
  `5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf`. Content: `encoder.int8.onnx` (652 MB),
  `decoder.int8.onnx` (12 MB), `joiner.int8.onnx` (6 MB), `tokens.txt`, `test_wavs/`.
- `silero_vad.onnx`: **643,854 bytes** (not ~2 MB), SHA256 `9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6`.
- Private car recording `/home/birk/handy-builds/messung/auto-2026-10-13-1528.wav`: 2 channels, 16 bit, 44.1 kHz,
  3,021,864 frames (68.5 s). It stays where it is; only numbers derived from it may be printed.

### 2.4 Existing Wing code (at 2154167)

- `VoiceCapture.kt`: `local` = `SpeechRecognizer`; `hermes` = `MediaRecorder` (AAC, 120 s max). After `stop()` on
  `local` there is a fixed 5 s "Recognition did not finish" deadline. That deadline is not changed; the vad route has its own budget (6).
- `VoiceChannel.kt`: method channel `com.tarkilhk.wing/voice`; events go to Dart via `invokeMethod("event", map)` with an `id`.
- `VoicePreferences` uses one enum `VoiceProcessing {local, hermes}` for both input and output.
  `VoicePreferences.accepts` also validates config-backup restores (`config_backup_service.dart`).
  `voice_processing_test.dart` iterates over `VoiceProcessing.values` for input × output.
- Conversation loop in `profile_workspace_screen.dart`: `_dictate` → `VoiceInputController.start` → on a final
  result `finishedOnItsOwn` decides whether to send → `_speakCompletedReply` → `_dictate(resume: true)`.
  `_conversation` (a `ProfileSessionKey?`) marks a running conversation.
- The settings card `voice_preferences_card.dart` uses `StudioSelect` and `SwitchListTile`. The design charter asks for
  `CompactSwitchListTile` for whole-row toggles; new rows use it.

## 3. Architecture

```
            Dart (policy, tested in CI)                         Kotlin (I/O, thin)
 ┌───────────────────────────────────────────┐        ┌──────────────────────────────────────────┐
 │ VoiceInputController (route vad)           │ start  │ VadCapture                                │
 │  ├─ VadEndpointer (state machine)  ◄───────┼────────┤  AudioRecord 16k mono (VOICE_COMMUNICATION│
 │  │    windows: [p…] batches                 │ events │   → VOICE_RECOGNITION), Android's routing  │
 │  │    decision: pause | max | manual |      │        │  576-sample windows → Vad.compute → p      │
 │  │              mediaKey | noSpeech         │        │  round PCM buffer (≤ max + 5 s)            │
 │  ├─ finishVad(start,end,reason) ───────────┼───────►│  cut [start*512, end*512) → OfflineSpeech  │
 │  │    .timeout(recognitionBudget(segment)) │ ◄──text┤  "got it" cue; debug WAV + JSON            │
 │  └─ seconds / partial status / errors      │        │ OfflineSpeech (Parakeet, preloaded)        │
 │ ProfileWorkspaceScreen                     │        │ SpeechModelStore (download/verify/extract) │
 │  ├─ conversation loop (unchanged rules)    │        │ VoiceMediaKeys (MediaSession)              │
 │  ├─ media key → stop-and-send / start      │◄───────┤ keepScreenOn (FLAG_KEEP_SCREEN_ON)         │
 │  └─ keepScreenOn(conversation running)     │        │ VoiceDebugStore (files/voice-debug)        │
 │ VoicePreferencesCard (route, model, tuning)│        └──────────────────────────────────────────┘
 └───────────────────────────────────────────┘
```

Units and their single purpose:

| Unit | File | Purpose | Depends on |
|---|---|---|---|
| `VadEndpointConfig`, `VadEndpointer`, `VadDecision`, `vadRecognitionBudget` | `lib/core/services/vad_endpoint.dart` | Pure state machine: probabilities → decision. | nothing |
| `VoiceInputRoute`, new keys | `lib/core/services/voice_preferences.dart` | Persisted device choices. | shared_preferences |
| `VoiceDevice` additions, `VadModelStatus`, `VadCaptureOptions` | `lib/core/services/android_voice.dart` | Channel contract. | services |
| `VoiceInputController` (vad branch) | `lib/core/controllers/voice_input_controller.dart` | One round: start, feed, finish, budget, errors. | endpointer, device |
| Workspace integration | `lib/core/screens/profile_workspace_screen.dart` | Media key, keep-screen-on, preload. | controller |
| Settings UI | `lib/core/widgets/voice_preferences_card.dart` + `lib/core/widgets/vad_settings_section.dart` | Route, model install, tuning, cues, debug. | device, prefs |
| `VadCapture` | `android/.../VadCapture.kt` | Recording (routed input), probabilities, cut, cues. | sherpa `Vad`, `OfflineSpeech`, `VoiceDebugStore` |
| `OfflineSpeech` | `android/.../OfflineSpeech.kt` | Parakeet lifecycle and decode on one executor. | sherpa `OfflineRecognizer`, `SpeechModelStore` |
| `SpeechModelStore` | `android/.../SpeechModelStore.kt` | Download, resume, SHA256, extract, manifest, import, remove. | commons-compress |
| `VoiceDebugStore` | `android/.../VoiceDebugStore.kt` | WAV + JSON per round, keep newest 30, delete all. | — |
| `VoiceMediaKeys` | `android/.../VoiceMediaKeys.kt` | MediaSession → `{mediaKey}` events. | framework only |
| Python mirror | `tools/voice/vad_endpoint.py` | Same state machine for offline tuning. | stdlib |
| Offline check | `tools/voice/vad_offline_check.py` | Car WAV → probabilities → endpoints, numbers only. | numpy, onnxruntime (venv in `build/`) |

## 4. Endpoint logic (normative; Dart and Python must match)

Constants: sample rate 16,000 Hz; window = 512 samples = **32 ms**; window *i* covers samples
`[i*512, (i+1)*512)`. `startThreshold = 0.5`, `endThreshold = 0.35` (hysteresis, as in the Silero reference),
`tail = 250 ms`. These three are internal constants, not settings.

Settings (defaults): `pause` 1800 ms, `minSpeech` 250 ms, `preRoll` 300 ms, `maxDuration` 120 s,
`noSpeechTimeout` 8 s. `w(ms) = ceil(ms / 32)`, `maxW = floor(maxMs / 32)` and `noSpeechW = floor(noSpeechMs / 32)`.
So pauseW = 57, minSpeechW = 8, preRollW = 10, tailW = 8, maxW = 3750, noSpeechW = 250.

State: `run = 0`, `runStart = -1`, `speechStart = -1`, `lastSpeech = -1`, `silence = 0`.

`feed(p)` for the next window `i` (0-based, consecutive):

1. If no speech is confirmed yet (`speechStart < 0`):
   - `p >= startThreshold`: if `run == 0` then `runStart = i`; `run++`; if `run >= minSpeechW` then
     `speechStart = runStart`, `lastSpeech = i`, `silence = 0`.
   - `p < endThreshold`: `run = 0`.
   - otherwise: unchanged.
2. If speech is confirmed:
   - `p >= endThreshold`: `lastSpeech = i`, `silence = 0`.
   - otherwise: `silence++`. If `silence >= pauseW`, decide
     **End(reason = pause, start = max(0, speechStart − preRollW), end = min(lastSpeech + 1 + tailW, i + 1), at = i)**.
3. If no decision yet, speech is not confirmed, `run == 0` (no speech start in progress) and `i + 1 >= noSpeechW`:
   **NoSpeech(at = i)**. This ends a round in which nothing was said, after 8 s by default instead of 120 s. A speech
   start still in progress at the timeout is not cut: the check waits until that run confirms or resets.
4. If no decision yet and `i + 1 >= maxW`: speech confirmed → **End(maxDuration, start = max(0, speechStart − preRollW), end = i + 1, at = i)**;
   otherwise **NoSpeech(at = i)**.

`forceEnd(reason)` (Stop button or media key, after `n` windows have been fed): speech confirmed →
`End(reason, start = max(0, speechStart − preRollW), end = n, at = n − 1)`; else `End(reason, start = 0, end = n, at = n − 1)`.
This transcribes the whole round if the VAD has not confirmed speech yet. With `n == 0` it returns `NoSpeech`.

After a decision the endpointer is finished; further `feed` calls are ignored and return `null`.

`vadRecognitionBudget(segment) = 10 s + segment × 0.5`. This covers a cold model load (3.1 s measured) and
RTF ≤ 0.5 (measured 0.08–0.11). It replaces any fixed post-stop deadline on this route: a 2 s segment gets 11 s,
a 120 s segment 70 s.

Behaviour required by the card, all tested:
- end after the pause; a thinking pause shorter than the pause does not end the round;
- max duration ends the round (with or without speech);
- no speech start within the no-speech timeout ends the round (NoSpeech) without recognition; a speech start in
  progress at that moment is not cut;
- pre-roll is included in the cut (start = first speech window − preRollW, clamped at 0);
- speech shorter than `minSpeech` never starts a round (noise click);
- probabilities between the thresholds neither start nor end speech in the state that would need them to.

Mutation contract: setting `_pauseWindows` to `0` in `VadEndpointer` (pause threshold 0) must make
`test/vad_endpoint_test.dart` → `"a thinking pause shorter than the pause keeps the round open"` and
`"ends after the pause and keeps the tail"` fail. The Python mirror test
`scripts/tests/test_vad_endpoint_parity.py` fails on the same mutation in `tools/voice/vad_endpoint.py`.

Shared golden cases: `test/fixtures/vad_endpoint_cases.json` (run-length encoded probabilities, configs and expected
decisions) is read by both the Dart test and the Python parity test, so the two implementations cannot drift apart.

## 5. Channel contract (additions only; existing methods unchanged)

| Method | Arguments | Result |
|---|---|---|
| `startVad` | `id`, `cues` (bool), `debug` (bool), `source` (`communication`/`recognition`), `maxMs` | `null`, or error `voice_unavailable` (model missing, mic unavailable) |
| `finishVad` | `id`, `startWindow`, `endWindow`, `atWindow`, `reason`, `config` (map for debug JSON) | transcript `String` (may be empty) |
| `vadModelStatus` | — | map `{state, bytes, total, error}` |
| `installVadModel` | — | `null` (progress via events) |
| `cancelVadModelInstall` | — | `null` |
| `removeVadModel` | — | `null` |
| `prepareVad` / `releaseVad` | — | `null` (load/unload Parakeet in the background) |
| `setMediaKeys` | `on` | `null` |
| `keepScreenOn` | `on` | `null` |
| `deleteVadDebugRecordings` | — | `int` number of rounds deleted |

Events (through the existing `event` method):
- `{id, first: <int>, windows: <List<double>>}`: probability batches of 4 windows (128 ms).
- `{id, error: <String>}`: as today.
- `{model: {state, bytes, total, error}}`: no `id`. `state` is one of `absent | downloading | verifying | unpacking | installed | failed`.
- `{mediaKey: "playPause"}`: no `id`.

The existing `start`, `stop`, `cancel` handlers and `VoiceCapture.kt` remain byte-for-byte unchanged. `cancel(id)`
is extended in `VoiceChannel` to also cancel a vad round with that id.

## 6. Round lifecycle (route vad)

1. `VoiceInputController.start` with route vad: reject with "Download the speech model in App settings → Voice" if
   the model status is not `installed` (checked natively in `startVad`). Then `startVad`.
2. Kotlin: cue "listening" (`ToneGenerator`, 150 ms), then `AudioRecord` on the input Android currently routes (no
   own routing) with `VOICE_COMMUNICATION` (falls back to `VOICE_RECOGNITION` if not initialized; the debug setting
   can force `VOICE_RECOGNITION`), new `Vad` from asset `silero_vad.onnx`. The routed device
   (`AudioRecord.getRoutedDevice()`) is noted for the debug JSON. A reader thread computes p per window and posts
   batches to the main thread.
3. Dart feeds every batch into `VadEndpointer`. On `End`: `finishedOnItsOwn = reason ∈ {pause, mediaKey}`, phase
   `transcribing`, `finishVad(...)` with timeout `vadRecognitionBudget(segment)`.
   On `NoSpeech` (no-speech timeout or max without speech): cancel the capture and fail "No speech detected. Try
   again." This ends a conversation, as today. No recognition runs.
4. Kotlin `finishVad`: stop the reader, cue "got it", cut the PCM, decode on the `OfflineSpeech`
   executor (waits for a running preload), write the debug files when enabled, return the text.
5. Dart `_finish(text)`: an empty text is "No speech detected", the same as today.
6. Stop button: `forceEnd(manual)`, not sent in a conversation (unchanged rule). Media key during a round:
   `forceEnd(mediaKey)`, which **is** sent in a conversation (hands-free action). Cancel / background / chat switch:
   `cancel(id)` and the round is discarded (debug JSON with reason `cancelled` if debug is on).
7. Safety: Kotlin stops reading at `maxMs + 5 s` and emits `{id, error: "Recording reached its time limit…"}` if Dart never decided.

Media key outside a round (route vad, workspace in foreground, chat open, nothing needing input): behaves like
tapping the microphone (`_dictate(chat)`), which already stops a running reply first.

Keep screen on: `keepScreenOn(true)` while `_conversation != null`, `false` when it is cleared or the screen is disposed.

Preload: `ProfileWorkspaceScreen.initState` and a route switch to vad call `prepareVad()`. A switch away calls `releaseVad()`.

## 7. Model install, verification and storage

- Location: `filesDir/models/parakeet-tdt-0.6b-v3-int8/` containing the four files and `manifest.json`
  (`{archiveSha256, files: {name: {size, sha256}}}`). Internal storage, so it is app-private.
- Download: the phone itself fetches the pinned GitHub release URL (`HttpURLConnection`, redirects followed) into
  `filesDir/models/download/archive.tar.bz2.part`, resuming with `Range` after an interruption. Free space is checked
  before starting: ≥ remaining archive bytes + 700 MB. Progress events at most every 500 ms. The user can cancel.
- **Verification (per-file hashes are not published):** (1) SHA256 of the complete archive must equal
  `5793d0fd…16bf`, otherwise the archive is deleted and the state is `failed: "Download was corrupted…"`. (2) Streaming
  extraction (commons-compress `BZip2CompressorInputStream` + `TarArchiveInputStream`) of exactly the four expected
  entries under `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/`. Any other path is ignored, and entries containing
  `..` or absolute paths are rejected. Extraction goes into `…/staging/` while SHA256 and size are computed for each
  file. (3) `manifest.json` is written and `staging` is atomically renamed to the final directory, then the archive is
  deleted. The per-file hashes are derived from the verified archive. This makes them a tamper/corruption check for
  later loads, not an independent publisher signature.
- Every load checks that `manifest.json` exists and that the file sizes match (cheap). A full hash check runs only
  after install or import.
- Pre-placed alternative: when the user taps Download and
  `getExternalFilesDir("import")/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2` exists, it is verified and
  extracted the same way instead of downloading, then deleted. `hadb push` fails above ~100 kB, so the archive gets
  there by `curl` on the phone from a tailnet HTTP server. Over the Tailscale relay (~0.1 MB/s) that takes over an
  hour, so the in-app download over the phone's own connection is the default.
- Remove: deletes the model directory and any partial download (user action, with confirmation).

## 8. Settings UI (design per AGENTS.md)

User's task: choose how speech is recognized. When "On this phone · Parakeet" is chosen, the task is to install the
model once, then optionally tune pause detection. Primary action: **Download speech model** (only while it is not
installed). Editable controls: route, cue tones, the five tuning values, debug switch, debug-only audio source.
Passive context: model size. Temporary status: download/unpack progress, errors. There is no microphone choice
(gestrichen, Birk 13.10.; see 1.1).

Arrangements considered:
- A: all controls flat in the Voice card. That means 9+ rows under "Voice input", tuning values dominate, and
  rarely changed values push the output settings off screen.
- B (chosen): route select. Under it, only for vad: one model row (status + one action), then the "Cue tones"
  switch. Tuning and debug sit behind one collapsed disclosure, **"Pause detection"**. This means one extra tap for
  rare changes, the everyday controls stay visible, and it matches Studio's grouped-list density.

Rows (vad only):
- Model row. Not installed: "Speech model · 487 MB download" + `Download`. Downloading: determinate
  `LinearProgressIndicator` + "123 / 487 MB" + `Cancel`. Verifying/unpacking: indeterminate + "Checking…" / "Unpacking…".
  Installed: "Speech model ready" + `Remove`. Failed: `StudioError(message)` + `Retry`.
- `CompactSwitchListTile` "Cue tones" (default on).
- Disclosure "Pause detection":
  - `StudioSelect` "Pause before sending": 1.0 / 1.4 / **1.8** / 2.4 / 3.0 s.
  - "Wait for speech" (no-speech timeout): 5 / **8** / 12 / 20 s.
  - "Minimum speech": 0.15 / **0.25** / 0.4 s.
  - "Lead-in kept": 0.2 / **0.3** / 0.5 s.
  - "Longest recording": 30 / 60 / **120** s.
  - `CompactSwitchListTile` "Debug recordings" (default off; subtitle "Keeps audio and timing of each round on this
    phone. Never uploaded.").
  - When on: `StudioSelect` "Audio source" (`Call processing` = communication, `Recognition` = recognition) +
    `Delete debug recordings`.
- The existing "Recognition language" row is hidden for vad (Parakeet v3 detects the language).
- Saving follows the existing `_save` pattern (disable while saving, keep the last confirmed value after a failure).
  No permanent success text.

Rendered-screen check: `--dart-define=VOICE_REVIEW=true` captures run on GitHub (no Flutter on the vServer) in a new
`voice-review.yml` that pushes `build/voice-review/*.png` to branch `voice-review-bin`. These are synthetic fixtures
only. The coder inspects them (320 dp, 100 % and 200 % text, light and dark, states: absent, downloading,
installed, failed, disclosure open). On-device screenshots in the last task supplement them.

## 9. Error handling

| Situation | Behaviour / message |
|---|---|
| Model not installed at round start | Error "Download the speech model in App settings → Voice." The conversation ends. |
| Model files incomplete (size mismatch) | Status `failed` "Speech model is incomplete. Download it again." |
| Download network failure | `failed` with the reason. `Retry` resumes from the `.part`. |
| Archive hash mismatch | Delete the archive; `failed` "Download was corrupted. Retry." |
| Not enough space | `failed` "Needs about 1.2 GB free space." |
| `AudioRecord` cannot initialize with either source | Error "Microphone is unavailable." |
| Nothing said within "Wait for speech" | Round ends without recognition: "No speech detected. Try again." The conversation ends. |
| Parakeet load fails (OOM, corrupt) | `finishVad` error "Speech model could not be loaded (…)." The model state is kept. |
| Recognition exceeds budget | `TimeoutException` → existing "Speech processing timed out. Please retry." |
| `Vad.compute` returns −1 | Treated as p = 0, counted in the debug JSON `computeErrors`. |
| App to background | Existing `pause()` → round cancelled, media keys inactive. |

## 10. Debug recordings

- `filesDir/voice-debug/<yyyyMMdd-HHmmss>-<id8>.wav` (16 kHz mono PCM16, the whole round) and `.json`
  `{version: 1, roundId, startedAt, sampleRate, windowSamples, windowMs, source, inputDevice (routed device, read-only: product name + type), config{…}, probabilities[…3 decimals],
  computeErrors, decision{reason, startWindow, endWindow, atWindow}, recognition{segmentMs, decodeMs, modelReadyAtFinish, textLength, error}}`.
  **No transcript text** in the JSON.
- Written only when the switch is on (default off). Cancelled rounds are written too (reason `cancelled`). The newest
  30 rounds are kept. `Delete debug recordings` removes all of them. Nothing is ever uploaded by the app.
- Retrieval: `tools/voice/pull_debug_round.py` (root `su -c base64` over `hadb shell` in 48 kB chunks, SHA256 compared on
  both sides) into a directory outside the repo. The data is private and never committed.

## 11. Testing strategy

- Dart (CI, `flutter test`): `test/vad_endpoint_test.dart` (state machine + golden cases + budget),
  `test/voice_preferences_test.dart` (new keys, defaults, `accepts`, backup acceptance),
  `test/voice_vad_input_test.dart` (controller: start, feed, finish, timeout, noSpeech, manual vs media key,
  cancel), `test/voice_workspace_test.dart` (conversation with route vad sends after a pause, does not send on a thinking
  pause, media key ends and sends, media key starts a round, keep-screen-on on/off), `test/vad_settings_test.dart`
  (model states, disclosure, saving, 320 dp / 200 % in both themes).
- Python (CI, `scripts/tests`): `test_vad_endpoint_parity.py` runs the golden cases against `tools/voice/vad_endpoint.py`.
- Mutation: see section 4 (exact mutation, expected red tests).
- Offline car check (vServer, not in CI): `tools/voice/vad_offline_check.py --wav <path>` prints numbers only: the
  probability distribution, the endpoints per parameter grid and, if `--labels` is given, the end errors in ms.
- Kotlin: compiled by `voice-apk.yml` through `tools/factory/dispatch-check.sh` (no Kotlin unit tests; the logic is in Dart).
- On device (last task): signed build, install as update, in-app model download, preload/RAM, self-test with a
  synthetic sentence + noise through the phone speaker, proven by debug WAV + JSON; audio source A/B (same file,
  both sources, compare the debug JSON, see 1.2); media key via `cmd media_session dispatch play-pause`;
  keep-screen-on flag via `dumpsys window`.
- Birk's manual acceptance (not automatable here): a drive with the phone mic as Android routes it, debug on,
  alternating the audio source between rounds.

## 12. Privacy

- Route vad sends no audio or text anywhere except that the transcript goes into the chat draft/prompt as with every route.
- The car WAV and debug recordings stay out of the repo and are never uploaded. The scripts take paths as arguments
  and print only numbers. The device self-test runs **without** conversation mode, so no test prompt reaches Birk's
  Hermes. The draft is cleared afterwards.

## 13. Entscheidungen ohne Birk

Each is the smaller, reversible option.
1. **Endpoint logic in Dart**, because CI runs only `flutter test`/Python. Kotlin is I/O only. No Gradle test job added.
2. **Python mirror + shared golden JSON** for the offline car check. Parity is enforced in CI's existing Python step.
3. **New enum `VoiceInputRoute {local, hermes, vad}`** for input only. `VoiceProcessing` stays for output. Existing tests that looped over `VoiceProcessing.values` for input switch to `[local, hermes]` and keep their meaning.
4. **Separate channel methods `startVad`/`finishVad`**, so `VoiceCapture.kt`, `start`, `stop` stay untouched.
5. **sherpa-onnx from the v1.13.8 release AAR**, downloaded at build time by a Gradle task with a pinned SHA256 (not committed). Silero is downloaded the same way into a generated assets directory. Fallback if the AAR lacks the classes: copied kotlin-api sources + `.so` files.
6. **576-sample windows to `Vad.compute`** (64 context + 512 new), new `Vad` per round, own state machine (not the detector's `acceptWaveform` segmentation).
7. **Hysteresis 0.5/0.35 and a 250 ms tail as internal constants.** They are tuned with the offline check, not exposed in the UI.
8. **No-speech timeout as a setting "Wait for speech", default 8 s** (choices 5/8/12/20 s), replacing the earlier
   "ends at 120 s" decision (revised 13.10. after Birk's note: a 2-minute dead round in the car is not acceptable).
   8 s is a little longer than Offline Voice Input's 7 s emergency stop, so there is room to think after the reply.
   A speech start in progress at the timeout is not cut. Reversible: one preference key and one endpointer rule.
9. **Media key ending a round counts as hands-free (sent in conversation mode)**. The on-screen Stop keeps today's "not sent" rule. Media keys are active only on route vad and in the foreground.
10. *(gestrichen, Birk 13.10.: microphone choice removed, see 1.1. The routed input device is recorded read-only in the debug JSON instead.)*
11. **Cue tones = system `ToneGenerator` beeps** (`TONE_PROP_BEEP` "listening", `TONE_PROP_ACK` "got it"), default on. This is a placeholder until Birk picks sounds (aesthetics are his call; easy to swap).
12. **Keep screen on for conversation mode on every input route.** A screen timeout pauses the activity and kills any capture, so this fixes the loop for all routes. It does not touch the local recognizer.
13. **Debug data in internal storage, newest 30 rounds kept, manual delete, no transcript in JSON**, cancelled rounds included.
14. **Debug-only "Audio source" select** (default `VOICE_COMMUNICATION`, fallback `VOICE_RECOGNITION`), visible only with debug on. This is how the open source question gets measured (1.2): on-device A/B plus Birk's drive. It is also needed if echo cancellation removes the self-test audio played through the phone speaker.
15. **Model in internal storage, downloaded by the phone from GitHub**, resumable. Archive hash, then extraction, then a manifest with derived per-file hashes. Pre-placed archive import from the app's external files dir.
16. **Parakeet preloaded only when the route is vad**, released when switching away (≈ 800 MB RAM).
17. **Recognition budget 10 s + 0.5 × segment.**
18. **Tuning values as discrete choices** (same pattern as speaking speed).
19. **Manual stop transcribes from first speech − pre-roll**, or the whole round if no speech was confirmed.
20. **Device self-test without conversation mode** (no prompt to Hermes).
21. **`voice-apk.yml` gets a `publish` input** and a generic helper `tools/factory/dispatch-check.sh <workflow> [input=value]` (like `ci-suite.sh`), so Kotlin compile checks do not overwrite `voice-apk-bin`.
22. **Rendered screens from CI** via a new `voice-review.yml` → branch `voice-review-bin`.

## 14. ANNAHMEN (unverified, each with the check that settles it)

- `ANNAHME:` the AAR contains the Kotlin classes incl. `Vad.compute` and arm64 JNI libs. Check: plan task 1 script.
- `ANNAHME:` `implementation(files("libs/sherpa-onnx-1.13.8.aar"))` in the app module works with the Gradle fetch task hooked before `preBuild`. Check: `dispatch-check.sh` run succeeds.
- `ANNAHME:` `compute` on 576-sample windows gives usable probabilities (same layout as the offline onnxruntime check). Check: the offline positive/negative controls (plan Task 5), and the on-device debug JSON showing p > 0.5 during the self-test speech.
- `ANNAHME:` Silero separates speech from driving noise with the **built-in phone mic** at car distance (Birk's finding 1.1: level ≈ 1/100 of close speech). Check: offline on the car WAV (plan Task 5, percentiles and rounds), then Birk's drive. If p stays below 0.5 for real speech, that is a finding for Birk (thresholds/source), not something the plan changes silently.
- `ANNAHME:` the onnxruntime input names of `silero_vad.onnx` are `x`/`state`/`sr` (v5). Check: `vad_offline_check.py --inspect` prints the inputs.
- `ANNAHME:` Parakeet decodes a 120 s segment within RAM limits on the Xperia 5 IV. Check: on-device with a 100 s+ synthetic round (debug JSON `decodeMs`, `dumpsys meminfo`).
- `ANNAHME:` a `MediaSession` that is active with `STATE_PAUSED` receives play/pause from `cmd media_session dispatch` and AVRCP. Check: `dumpsys media_session` shows Wing Voice as the media button session; fallback: `STATE_PLAYING` while a conversation runs.
- `ANNAHME:` echo cancellation on `VOICE_COMMUNICATION` does not remove audio played by another app through the same phone's speaker. Check: self-test JSON max p during speech; otherwise switch the debug audio source to recognition.
- `ANNAHME:` `HttpURLConnection` follows the GitHub release redirect (https→https) and the CDN honours `Range`. Check: interrupt a download on the device (toggle airplane mode) and retry; the progress continues.
- `ANNAHME:` `hadb shell` output of base64 chunks of 48 kB is reliable over Tailscale (push is not). Check: `pull_debug_round.py` reports matching SHA256.
- `ANNAHME:` Twelve plays a WAV started via `am start -a android.intent.action.VIEW` with a `file://` or MediaStore URI and keeps playing in the background. Check: `dumpsys media_session` / `dumpsys audio` during the self-test.

## 15. Open questions for Birk

None block the implementation. Revisable later: cue sounds (13.11), debug retention of 30 rounds (13.13),
keep-screen-on for all routes (13.12), the no-speech timeout default of 8 s (13.8), and the audio source default
after the test drive (1.2).

# Wing Voice input route "vad" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new voice input route "vad" ends an utterance by itself in a moving car. It uses its own `AudioRecord`
capture, a Silero VAD end-of-utterance state machine and Parakeet TDT 0.6B v3 int8 speech-to-text on the phone.
It adds a media-key fallback, cue tones, a no-speech timeout, keep-screen-on during conversations and debug WAV/JSON
recordings. It records from whatever input Android routes (normally the built-in phone mic). The microphone setting
was gestrichen by Birk on 13.10. (spec 1.1).

**Architecture:** Kotlin does I/O only. It records 16 kHz mono, turns each 32 ms window into a Silero probability
(`Vad.compute`) and streams the probabilities in batches to Dart. On request it cuts the decided segment and decodes
it with a preloaded sherpa-onnx `OfflineRecognizer`. Dart owns the policy: a pure `VadEndpointer` state machine
decides pause, max duration, manual stop or media-key stop, and is tested by `flutter test` in CI. A Python mirror of the
state machine, kept identical through shared golden cases, tunes the parameters offline on the vServer against a
private car recording.

**Tech Stack:** Flutter 3.44 / Dart 3.12, Kotlin (Android, minSdk 24, compileSdk 36), sherpa-onnx 1.13.8 (AAR),
Apache commons-compress (bzip2/tar), Python 3.9 + numpy + onnxruntime (offline check only, venv in `build/`).

**Spec:** `docs/superpowers/specs/2026-10-13-wing-voice-vad-input-design.md`. Read sections 4 (endpoint
algorithm), 5 (channel contract) and 13 (decisions) before starting any task.

## Global Constraints

- Routes "local" and "hermes" keep their behaviour. Do **not** edit `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceCapture.kt`. Offline Voice Input (`dev.notune.transcribe`) is never touched.
- Route "vad" sends no audio anywhere. No server endpoint, no backend change, no ElevenLabs.
- The Parakeet model is **not** in the APK. Archive URL `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2`, size `487170055` bytes, SHA256 `5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf`.
- Silero VAD: `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx`, `643854` bytes, SHA256 `9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6`. Fetched at build time into generated APK assets, never committed.
- sherpa-onnx AAR: `https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-1.13.8.aar`. Its SHA256 is confirmed in Task 1 (expected `633c24321e06b1fe79feafa03ea16cbc0f8a286641e2da3559bac91bdb13bd96`). Fetched at build time, never committed.
- Endpoint constants: window 512 samples = 32 ms at 16 kHz; start threshold 0.5; end threshold 0.35; tail 250 ms. Defaults: pause 1800 ms, min speech 250 ms, pre-roll 300 ms, max 120 s, no-speech timeout 8 s.
- **Microphone: gestrichen (Birk 13.10.).** Record from whatever input Android routes. No `startBluetoothSco`, no `setCommunicationDevice`, no microphone preference, UI or test. The debug JSON records the routed device read-only (`inputDevice`).
- Audio source: default `VOICE_COMMUNICATION`, fallback `VOICE_RECOGNITION`, selectable only via the debug setting "Audio source". The default is decided by measurement (Task 15 A/B, then Birk's drive), never silently.
- No fixed 7 s emergency stop on route vad: "no speech" is the explicit, configurable no-speech timeout.
- Silero windows passed to `Vad.compute` are **576 floats**: the last 64 samples of the previous window + 512 new samples. `SileroVadModelConfig.windowSize` must stay `512` (any other value aborts the process).
- **Private data:** never copy, commit, upload or print the content of `/home/birk/handy-builds/messung/auto-2026-10-13-1528.wav`, debug recordings or transcripts. Scripts take paths as arguments and print numbers only. Debug recordings retrieved from the phone go to `build/voice-debug/` (git-ignored) and are deleted after analysis.
- Test command: `bash tools/factory/ci-suite.sh` runs the **whole** pr-quality workflow (analyze + all Flutter tests + `scripts/tests`) on GitHub Actions for **committed HEAD**. It ignores path arguments. Commit before running it. Success = exit code 0 and a last line `ci-suite: run <id> conclusion=success …`.
- Kotlin is compiled only by `voice-apk.yml`. Use `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false` (created in Task 9) for compile checks.
- `flutter analyze --fatal-infos` must stay clean: no unused imports, prefer `const`, `unawaited(...)` for fire-and-forget futures.
- UI: Studio charter (`docs/DESIGN_SYSTEM.md`). Use `StudioSelect`, `CompactSwitchListTile`, `AnchoredExpansionTile` and `StudioError`, keep 320 dp / 200 % text working in both themes, disable writes while saving, and keep the last confirmed value after a failed save.
- Commit after every task on the current branch. No merge, no push except the throwaway `ci/…` refs the scripts push and delete themselves.
- `ANNAHME:` marks an unverified assumption together with the check that settles it. Run the check; if it fails, follow the fallback given there and record the outcome in `docs/VAD_INPUT.md`.

## File map

| File | Status | Responsibility |
|---|---|---|
| `tools/voice/check_sherpa_aar.py` | create | Verify AAR hash and contents (Task 1). |
| `docs/VAD_INPUT.md` | create | Developer notes: verified facts, ANNAHME outcomes, how to tune, how to retrieve debug data. |
| `lib/core/services/vad_endpoint.dart` | create | `VadEndpointConfig`, `VadEndReason`, `VadDecision`, `VadEndpointer`, `vadWindowsFor`, `vadRecognitionBudget`. |
| `test/fixtures/vad_endpoint_cases.json` | create | Golden cases shared by Dart and Python. |
| `test/vad_endpoint_test.dart` | create | State machine tests. |
| `tools/voice/vad_endpoint.py` | create | Python mirror of the state machine. |
| `scripts/tests/test_vad_endpoint_parity.py` | create | Runs the golden cases against the mirror (CI python step). |
| `tools/voice/vad_offline_check.py` | create | Offline car/synthetic check, numbers only. |
| `tools/voice/make_selftest_audio.py` | create | Synthetic speech + noise test file for the device self-test. |
| `tools/voice/pull_debug_round.py` | create | Fetch one debug round from the phone via `hadb`. |
| `lib/core/services/voice_preferences.dart` | modify | `VoiceInputRoute`, `VadAudioSource`, new keys. |
| `lib/core/services/android_voice.dart` | modify | `VadCaptureOptions`, `VadModelState`, `VadModelStatus`, new `VoiceDevice` methods. |
| `lib/core/controllers/voice_input_controller.dart` | modify | vad branch, `stopHandsFree()`. |
| `lib/core/screens/profile_workspace_screen.dart` | modify | Media key, keep-screen-on, preload. |
| `lib/core/widgets/voice_preferences_card.dart` | modify | Input route select, vad section, hide language for vad. |
| `lib/core/widgets/vad_settings_section.dart` | create | Model row, mic, cues, "Pause detection" disclosure, debug. |
| `test/support/voice_fixture.dart` | modify | Fake for the new device methods. |
| `test/voice_preferences_test.dart`, `test/voice_processing_test.dart` | modify | Enum split; new keys. |
| `test/voice_vad_input_test.dart` | create | Controller tests for route vad. |
| `test/voice_workspace_test.dart` | modify | Conversation, media key, keep-screen-on tests. |
| `test/vad_settings_test.dart` | create | Settings section tests + renders. |
| `android/app/build.gradle.kts` | modify | Fetch tasks, AAR + commons-compress deps, proguard file. |
| `android/app/proguard-rules.pro` | create | Keep sherpa JNI classes; dontwarn for optional compress codecs. |
| `.gitignore` | modify | `/android/app/libs/`. |
| `android/app/src/main/kotlin/com/tarkilhk/wing/SpeechModelStore.kt` | create | Model download/verify/extract/import/remove. |
| `android/app/src/main/kotlin/com/tarkilhk/wing/OfflineSpeech.kt` | create | Parakeet lifecycle and decode. |
| `android/app/src/main/kotlin/com/tarkilhk/wing/VadCapture.kt` | create | Recording on the routed input, probabilities, cut, cues. |
| `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceDebugStore.kt` | create | WAV + JSON per round. |
| `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceMediaKeys.kt` | create | MediaSession → `{mediaKey}` events. |
| `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt` | modify | New methods/events; `resume()`. |
| `android/app/src/main/kotlin/com/tarkilhk/wing/MainActivity.kt` | modify | `voiceChannel?.resume()` in `onResume`. |
| `.github/workflows/voice-apk.yml` | modify | `publish` input; new voice tests. |
| `.github/workflows/voice-review.yml` | create | Renders → branch `voice-review-bin`. |
| `tools/factory/dispatch-check.sh` | create | Dispatch any workflow on a throwaway ref and wait. |
| `docs/VOICE.md`, `docs/TESTING.md` | modify | User/test docs. |

Task order: 1 → 2 → 3 → 4 → 5 (offline tooling, independent of the app) → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13 → 14 → 15.
How each task is verified:
- Tasks 2, 6, 7, 8, 10, 11: Dart, `ci-suite.sh`.
- Tasks 3–5: Python, locally on the vServer, plus `ci-suite.sh` for the parity test.
- Tasks 9, 12, 13, 14: build/Kotlin, `dispatch-check.sh voice-apk.yml publish=false`. Task 14 also adds docs and renders.
- Task 15: on-device verification.

---

### Task 1: Verify the sherpa-onnx AAR (spike, no app code)

**Files:**
- Create: `tools/voice/check_sherpa_aar.py`
- Create: `docs/VAD_INPUT.md`

**Interfaces:**
- Produces: the confirmed AAR SHA256 (used in Task 9), and the decision "AAR" vs "fallback: copied kotlin-api sources + `.so`" recorded in `docs/VAD_INPUT.md`.

- [ ] **Step 1: Write the checker**

`tools/voice/check_sherpa_aar.py`:

```python
#!/usr/bin/env python3
"""Checks a sherpa-onnx Android AAR for what Wing's vad route needs.

Usage: python3 -I tools/voice/check_sherpa_aar.py <path-to-aar> <expected-sha256>
Prints one line per check and exits 1 if any check fails.
"""
import hashlib
import io
import sys
import zipfile

NEEDED_CLASSES = {
    "com/k2fsa/sherpa/onnx/Vad.class": [b"compute", b"acceptWaveform", b"release"],
    "com/k2fsa/sherpa/onnx/SileroVadModelConfig.class": [b"windowSize"],
    "com/k2fsa/sherpa/onnx/VadModelConfig.class": [b"sileroVadModelConfig"],
    "com/k2fsa/sherpa/onnx/OfflineRecognizer.class": [b"createStream", b"decode", b"getResult"],
    "com/k2fsa/sherpa/onnx/OfflineStream.class": [b"acceptWaveform"],
    "com/k2fsa/sherpa/onnx/OfflineModelConfig.class": [b"modelType", b"transducer"],
    "com/k2fsa/sherpa/onnx/OfflineTransducerModelConfig.class": [b"encoder", b"joiner"],
    "com/k2fsa/sherpa/onnx/OfflineRecognizerConfig.class": [b"featConfig", b"decodingMethod"],
    "com/k2fsa/sherpa/onnx/FeatureConfig.class": [b"featureDim"],
}
NEEDED_LIBS = ["jni/arm64-v8a/libsherpa-onnx-jni.so"]


def main(path: str, expected: str) -> int:
    ok = True
    digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
    print(f"sha256 {digest} {'OK' if digest == expected else 'MISMATCH'}")
    ok &= digest == expected
    aar = zipfile.ZipFile(path)
    names = set(aar.namelist())
    for lib in NEEDED_LIBS:
        size = aar.getinfo(lib).file_size if lib in names else 0
        print(f"lib {lib} {'OK ' + str(size) if size else 'MISSING'}")
        ok &= bool(size)
    for name in sorted(n for n in names if n.startswith("jni/arm64-v8a/")):
        print(f"arm64 {name} {aar.getinfo(name).file_size}")
    if "classes.jar" not in names:
        print("classes.jar MISSING")
        return 1
    jar = zipfile.ZipFile(io.BytesIO(aar.read("classes.jar")))
    jar_names = set(jar.namelist())
    for cls, members in NEEDED_CLASSES.items():
        if cls not in jar_names:
            print(f"class {cls} MISSING")
            ok = False
            continue
        data = jar.read(cls)
        missing = [m.decode() for m in members if m not in data]
        print(f"class {cls} {'OK' if not missing else 'MISSING ' + ','.join(missing)}")
        ok &= not missing
    proguard = [n for n in names if n.endswith("proguard.txt")]
    print(f"consumer-proguard {'present' if proguard else 'absent'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
```

- [ ] **Step 2: Read the published digest**

Run: `gh api repos/k2-fsa/sherpa-onnx/releases/tags/v1.13.8 --jq ".assets[] | select(.name==\"sherpa-onnx-1.13.8.aar\") | .digest"`
Expected: `sha256:633c24321e06b1fe79feafa03ea16cbc0f8a286641e2da3559bac91bdb13bd96`. If it differs, use the printed value everywhere this plan names the AAR hash and note that in `docs/VAD_INPUT.md`.

- [ ] **Step 3: Download into `build/` (git-ignored)**

Run: `mkdir -p build/sherpa`
Run: `curl -L --fail -o build/sherpa/sherpa-onnx-1.13.8.aar https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-1.13.8.aar`
Expected: exit 0, file ≈ 50 MB (`ls -l build/sherpa/sherpa-onnx-1.13.8.aar` shows `50129134`).

- [ ] **Step 4: Run the checker**

Run: `python3 -I tools/voice/check_sherpa_aar.py build/sherpa/sherpa-onnx-1.13.8.aar 633c24321e06b1fe79feafa03ea16cbc0f8a286641e2da3559bac91bdb13bd96`
Expected: `sha256 … OK`, `lib jni/arm64-v8a/libsherpa-onnx-jni.so OK <size>`, every `class … OK`, exit 0.

`ANNAHME:` the AAR has `classes.jar` with these classes. If any `class … MISSING` line appears, use the
**fallback**: in Task 9, instead of `implementation(files(...aar))`, (a) extract `jni/arm64-v8a/*.so` from the AAR
into `android/app/src/main/jniLibs/arm64-v8a/` by a Gradle task (git-ignored) and (b) copy the Kotlin sources
`Vad.kt`, `OfflineRecognizer.kt`, `OfflineStream.kt`, `FeatureConfig.kt`, `QnnConfig.kt`, `HomophoneReplacerConfig.kt`
(plus any file their imports need) from `https://api.github.com/repos/k2-fsa/sherpa-onnx/contents/sherpa-onnx/kotlin-api/<file>?ref=v1.13.8`
into `android/app/src/main/kotlin/com/k2fsa/sherpa/onnx/` with their Apache-2.0 headers. The package must stay
`com.k2fsa.sherpa.onnx`, because the JNI symbol names depend on it.

- [ ] **Step 5: Record the outcome**

Create `docs/VAD_INPUT.md`:

```markdown
# Voice input route "vad" (developer notes)

Design: `docs/superpowers/specs/2026-10-13-wing-voice-vad-input-design.md`.

## sherpa-onnx dependency (checked <date>)

- AAR `sherpa-onnx-1.13.8.aar`, SHA256 `<digest from Step 2>`, checked with `tools/voice/check_sherpa_aar.py`.
- Result: <"AAR contains classes and arm64 JNI libs" | "fallback: copied kotlin-api sources + jniLibs">.
- arm64 libraries: <paste the `arm64 …` lines: names and sizes only>.
- Consumer ProGuard rules in the AAR: <present|absent>.

## ANNAHME outcomes

| Assumption | Check | Outcome |
|---|---|---|
| AAR has classes + JNI libs | Task 1 | <result> |
```

- [ ] **Step 6: Commit**

```bash
git add tools/voice/check_sherpa_aar.py docs/VAD_INPUT.md
git commit -m "chore(voice): verify sherpa-onnx 1.13.8 AAR for the vad route"
```

---

### Task 2: Endpoint state machine in Dart (+ golden cases)

**Files:**
- Create: `lib/core/services/vad_endpoint.dart`
- Create: `test/fixtures/vad_endpoint_cases.json`
- Test: `test/vad_endpoint_test.dart`

**Interfaces:**
- Produces (used by Tasks 3, 6, 7, 8, 11):
  - `const int vadWindowMs = 32; const int vadWindowSamples = 512; const double vadStartThreshold = 0.5; const double vadEndThreshold = 0.35; const Duration vadTail = Duration(milliseconds: 250);`
  - `int vadWindowsFor(Duration duration)`, which is `ceil(ms / 32)`
  - `class VadEndpointConfig { const VadEndpointConfig({Duration pause, Duration minSpeech, Duration preRoll, Duration maxDuration, Duration noSpeechTimeout}); Map<String, Object> toJson(); }` (defaults 1800 ms, 250 ms, 300 ms, 120 s, 8 s)
  - `enum VadEndReason { pause, maxDuration, manual, mediaKey, noSpeech }`
  - `class VadDecision { final VadEndReason reason; final int startWindow, endWindow, atWindow; Duration get segment; bool get hasSpeech; }`
  - `class VadEndpointer { VadEndpointer(VadEndpointConfig config); int get windows; VadDecision? get decision; VadDecision? feed(double p); VadDecision? feedAll(Iterable<double> ps); VadDecision forceEnd(VadEndReason reason); }`
  - `Duration vadRecognitionBudget(Duration segment)`, which is `10 s + segment × 0.5`

- [ ] **Step 1: Write the golden cases**

`test/fixtures/vad_endpoint_cases.json`. Every expected value follows from spec section 4 with the defaults: pauseW 57, minSpeechW 8, preRollW 10, tailW 8, maxW 3750, noSpeechW 250.

```json
{
  "comment": "Shared by test/vad_endpoint_test.dart and scripts/tests/test_vad_endpoint_parity.py. runs = [probability, windows]. force = null | manual | mediaKey, applied after all runs if no decision came. expect = null means no decision.",
  "cases": [
    {"name": "ends after the pause and keeps the tail",
     "config": {}, "runs": [[0.05, 40], [0.9, 60], [0.1, 80]], "force": null,
     "expect": {"reason": "pause", "startWindow": 30, "endWindow": 108, "atWindow": 156}},
    {"name": "a thinking pause shorter than the pause keeps the round open",
     "config": {}, "runs": [[0.05, 40], [0.9, 60], [0.1, 31], [0.9, 40], [0.1, 80]], "force": null,
     "expect": {"reason": "pause", "startWindow": 30, "endWindow": 179, "atWindow": 227}},
    {"name": "56 silent windows do not end it and pre-roll is clamped at zero",
     "config": {}, "runs": [[0.9, 20], [0.1, 56], [0.9, 10], [0.1, 60]], "force": null,
     "expect": {"reason": "pause", "startWindow": 0, "endWindow": 94, "atWindow": 142}},
    {"name": "a burst shorter than minimum speech never starts a round",
     "config": {"maxMs": 3200}, "runs": [[0.9, 7], [0.1, 100]], "force": null,
     "expect": {"reason": "noSpeech", "startWindow": 0, "endWindow": 0, "atWindow": 99}},
    {"name": "no speech start ends the round after the no-speech timeout",
     "config": {}, "runs": [[0.05, 300]], "force": null,
     "expect": {"reason": "noSpeech", "startWindow": 0, "endWindow": 0, "atWindow": 249}},
    {"name": "a speech start in progress at the no-speech timeout is not cut",
     "config": {}, "runs": [[0.05, 245], [0.9, 30], [0.1, 80]], "force": null,
     "expect": {"reason": "pause", "startWindow": 235, "endWindow": 283, "atWindow": 331}},
    {"name": "a shorter no-speech timeout setting ends earlier",
     "config": {"noSpeechMs": 5000}, "runs": [[0.05, 200]], "force": null,
     "expect": {"reason": "noSpeech", "startWindow": 0, "endWindow": 0, "atWindow": 155}},
    {"name": "max duration ends a long utterance",
     "config": {"maxMs": 3200}, "runs": [[0.9, 150]], "force": null,
     "expect": {"reason": "maxDuration", "startWindow": 0, "endWindow": 100, "atWindow": 99}},
    {"name": "probabilities between the thresholds keep speech going",
     "config": {}, "runs": [[0.9, 20], [0.4, 80], [0.1, 60]], "force": null,
     "expect": {"reason": "pause", "startWindow": 0, "endWindow": 108, "atWindow": 156}},
    {"name": "probabilities between the thresholds never start speech",
     "config": {"maxMs": 1920}, "runs": [[0.4, 50], [0.1, 10]], "force": null,
     "expect": {"reason": "noSpeech", "startWindow": 0, "endWindow": 0, "atWindow": 59}},
    {"name": "probabilities between the thresholds do not reset a starting run",
     "config": {}, "runs": [[0.9, 4], [0.4, 3], [0.9, 4], [0.1, 60]], "force": null,
     "expect": {"reason": "pause", "startWindow": 0, "endWindow": 19, "atWindow": 67}},
    {"name": "a shorter pause setting ends earlier",
     "config": {"pauseMs": 1000}, "runs": [[0.05, 40], [0.9, 60], [0.1, 80]], "force": null,
     "expect": {"reason": "pause", "startWindow": 30, "endWindow": 108, "atWindow": 131}},
    {"name": "speech still running has no decision",
     "config": {}, "runs": [[0.9, 30]], "force": null, "expect": null},
    {"name": "manual stop after speech starts at speech minus pre-roll",
     "config": {}, "runs": [[0.05, 40], [0.9, 20]], "force": "manual",
     "expect": {"reason": "manual", "startWindow": 30, "endWindow": 60, "atWindow": 59}},
    {"name": "manual stop without confirmed speech transcribes the whole round",
     "config": {}, "runs": [[0.05, 30]], "force": "manual",
     "expect": {"reason": "manual", "startWindow": 0, "endWindow": 30, "atWindow": 29}},
    {"name": "media key stop keeps speech minus pre-roll",
     "config": {}, "runs": [[0.05, 40], [0.9, 20], [0.1, 10]], "force": "mediaKey",
     "expect": {"reason": "mediaKey", "startWindow": 30, "endWindow": 70, "atWindow": 69}}
  ]
}
```

- [ ] **Step 2: Write the failing tests**

`test/vad_endpoint_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/vad_endpoint.dart';

VadEndpointConfig _config(Map<String, dynamic> raw) => VadEndpointConfig(
  pause: Duration(milliseconds: raw['pauseMs'] as int? ?? 1800),
  minSpeech: Duration(milliseconds: raw['minSpeechMs'] as int? ?? 250),
  preRoll: Duration(milliseconds: raw['preRollMs'] as int? ?? 300),
  maxDuration: Duration(milliseconds: raw['maxMs'] as int? ?? 120000),
  noSpeechTimeout: Duration(milliseconds: raw['noSpeechMs'] as int? ?? 8000),
);

Iterable<double> _expand(List<dynamic> runs) sync* {
  for (final run in runs) {
    for (var i = 0; i < (run[1] as int); i++) {
      yield (run[0] as num).toDouble();
    }
  }
}

VadDecision? _run(Map<String, dynamic> raw) {
  final endpointer = VadEndpointer(_config(raw['config'] as Map<String, dynamic>));
  final decision = endpointer.feedAll(_expand(raw['runs'] as List<dynamic>));
  if (decision != null) return decision;
  return switch (raw['force']) {
    'manual' => endpointer.forceEnd(VadEndReason.manual),
    'mediaKey' => endpointer.forceEnd(VadEndReason.mediaKey),
    _ => null,
  };
}

void main() {
  final cases = (jsonDecode(
    File('test/fixtures/vad_endpoint_cases.json').readAsStringSync(),
  ) as Map<String, dynamic>)['cases'] as List<dynamic>;

  for (final raw in cases.cast<Map<String, dynamic>>()) {
    test(raw['name'] as String, () {
      final decision = _run(raw);
      final expected = raw['expect'] as Map<String, dynamic>?;
      if (expected == null) {
        expect(decision, isNull);
        return;
      }
      expect(decision, isNotNull);
      expect(decision!.reason.name, expected['reason']);
      expect(decision.startWindow, expected['startWindow']);
      expect(decision.endWindow, expected['endWindow']);
      expect(decision.atWindow, expected['atWindow']);
    });
  }

  test('pre-roll is included in the cut', () {
    final endpointer = VadEndpointer(const VadEndpointConfig());
    final decision = endpointer.feedAll([
      for (var i = 0; i < 50; i++) 0.05,
      for (var i = 0; i < 20; i++) 0.9,
      for (var i = 0; i < 60; i++) 0.1,
    ])!;
    // Speech starts at window 50; 300 ms pre-roll = 10 windows.
    expect(decision.startWindow, 40);
    expect(decision.segment, Duration(milliseconds: (decision.endWindow - 40) * 32));
  });

  test('feeding after a decision is ignored', () {
    final endpointer = VadEndpointer(const VadEndpointConfig());
    final first = endpointer.feedAll([
      for (var i = 0; i < 20; i++) 0.9,
      for (var i = 0; i < 60; i++) 0.1,
    ]);
    expect(first, isNotNull);
    final windows = endpointer.windows;
    expect(endpointer.feed(0.9), isNull);
    expect(endpointer.windows, windows);
    expect(endpointer.decision, same(first));
  });

  test('forceEnd before any window is no speech', () {
    final decision = VadEndpointer(const VadEndpointConfig()).forceEnd(VadEndReason.manual);
    expect(decision.reason, VadEndReason.noSpeech);
    expect(decision.hasSpeech, isFalse);
  });

  test('defaults match the card', () {
    const config = VadEndpointConfig();
    expect(config.pause, const Duration(milliseconds: 1800));
    expect(config.minSpeech, const Duration(milliseconds: 250));
    expect(config.preRoll, const Duration(milliseconds: 300));
    expect(config.maxDuration, const Duration(seconds: 120));
    expect(config.noSpeechTimeout, const Duration(seconds: 8));
    expect(vadWindowsFor(config.pause), 57);
    expect(config.toJson(), {
      'pauseMs': 1800, 'minSpeechMs': 250, 'preRollMs': 300, 'maxMs': 120000,
      'noSpeechMs': 8000,
      'startThreshold': 0.5, 'endThreshold': 0.35, 'tailMs': 250, 'windowMs': 32,
    });
  });

  test('no fixed 7 s stop: silence ends only at the configured no-speech timeout', () {
    final endpointer = VadEndpointer(const VadEndpointConfig());
    // 7 s = 218 windows of noise: still recording.
    expect(endpointer.feedAll(List.filled(219, 0.05)), isNull);
    final decision = endpointer.feedAll(List.filled(40, 0.05))!;
    expect(decision.reason, VadEndReason.noSpeech);
    expect(decision.atWindow, 249);
  });

  test('recognition budget scales with the segment instead of a fixed deadline', () {
    expect(vadRecognitionBudget(const Duration(seconds: 2)), const Duration(seconds: 11));
    expect(vadRecognitionBudget(const Duration(seconds: 120)), const Duration(seconds: 70));
    expect(vadRecognitionBudget(Duration.zero), const Duration(seconds: 10));
  });
}
```

- [ ] **Step 3: Run the suite to verify it fails**

Run: `git add test/vad_endpoint_test.dart test/fixtures/vad_endpoint_cases.json`
Run: `git commit -m "test(voice): golden cases for the vad endpointer"`
Run: `bash tools/factory/ci-suite.sh`
Expected: non-zero exit, `Analyze & Test: failure`. The analyzer reports `Target of URI doesn't exist: 'package:wing/core/services/vad_endpoint.dart'`.

- [ ] **Step 4: Implement**

`lib/core/services/vad_endpoint.dart`:

```dart
/// End-of-utterance policy for the "vad" voice input route.
///
/// Kotlin streams one Silero speech probability per 32 ms window; this state
/// machine decides when the round ends and which windows go to recognition.
/// tools/voice/vad_endpoint.py mirrors it for offline tuning; both run the
/// golden cases in test/fixtures/vad_endpoint_cases.json.
library;

const int vadWindowMs = 32;
const int vadWindowSamples = 512;
const double vadStartThreshold = 0.5;
const double vadEndThreshold = 0.35;
const Duration vadTail = Duration(milliseconds: 250);

int vadWindowsFor(Duration duration) =>
    (duration.inMilliseconds / vadWindowMs).ceil();

class VadEndpointConfig {
  const VadEndpointConfig({
    this.pause = const Duration(milliseconds: 1800),
    this.minSpeech = const Duration(milliseconds: 250),
    this.preRoll = const Duration(milliseconds: 300),
    this.maxDuration = const Duration(seconds: 120),
    this.noSpeechTimeout = const Duration(seconds: 8),
  });

  /// Silence after speech that ends the round.
  final Duration pause;

  /// Continuous speech needed before a round counts as started.
  final Duration minSpeech;

  /// Audio kept before the first speech window.
  final Duration preRoll;

  /// Longest round; ends with or without speech.
  final Duration maxDuration;

  /// A round in which no speech starts ends after this (no fixed 7 s stop).
  final Duration noSpeechTimeout;

  Map<String, Object> toJson() => {
    'pauseMs': pause.inMilliseconds,
    'minSpeechMs': minSpeech.inMilliseconds,
    'preRollMs': preRoll.inMilliseconds,
    'maxMs': maxDuration.inMilliseconds,
    'noSpeechMs': noSpeechTimeout.inMilliseconds,
    'startThreshold': vadStartThreshold,
    'endThreshold': vadEndThreshold,
    'tailMs': vadTail.inMilliseconds,
    'windowMs': vadWindowMs,
  };
}

enum VadEndReason { pause, maxDuration, manual, mediaKey, noSpeech }

/// Windows `[startWindow, endWindow)` go to recognition; [atWindow] is the
/// window on which the decision fell.
class VadDecision {
  const VadDecision(this.reason, this.startWindow, this.endWindow, this.atWindow);
  final VadEndReason reason;
  final int startWindow;
  final int endWindow;
  final int atWindow;

  bool get hasSpeech => reason != VadEndReason.noSpeech;
  Duration get segment =>
      Duration(milliseconds: (endWindow - startWindow) * vadWindowMs);
}

class VadEndpointer {
  VadEndpointer(this.config)
    : _pauseWindows = vadWindowsFor(config.pause),
      _minSpeechWindows = vadWindowsFor(config.minSpeech),
      _preRollWindows = vadWindowsFor(config.preRoll),
      _tailWindows = vadWindowsFor(vadTail),
      _maxWindows = config.maxDuration.inMilliseconds ~/ vadWindowMs,
      _noSpeechWindows = config.noSpeechTimeout.inMilliseconds ~/ vadWindowMs;

  final VadEndpointConfig config;
  final int _pauseWindows;
  final int _minSpeechWindows;
  final int _preRollWindows;
  final int _tailWindows;
  final int _maxWindows;
  final int _noSpeechWindows;

  int _windows = 0;
  int _run = 0;
  int _runStart = -1;
  int _speechStart = -1;
  int _lastSpeech = -1;
  int _silence = 0;
  VadDecision? _decision;

  int get windows => _windows;
  VadDecision? get decision => _decision;

  int get _cutStart => _speechStart - _preRollWindows < 0 ? 0 : _speechStart - _preRollWindows;

  VadDecision? feed(double p) {
    if (_decision != null) return null;
    final i = _windows++;
    if (_speechStart < 0) {
      if (p >= vadStartThreshold) {
        if (_run == 0) _runStart = i;
        _run++;
        if (_run >= _minSpeechWindows) {
          _speechStart = _runStart;
          _lastSpeech = i;
          _silence = 0;
        }
      } else if (p < vadEndThreshold) {
        _run = 0;
      }
    } else if (p >= vadEndThreshold) {
      _lastSpeech = i;
      _silence = 0;
    } else {
      _silence++;
      if (_silence >= _pauseWindows) {
        final end = _lastSpeech + 1 + _tailWindows;
        return _decision = VadDecision(
          VadEndReason.pause,
          _cutStart,
          end < i + 1 ? end : i + 1,
          i,
        );
      }
    }
    // Nothing said: end after the no-speech timeout, but never cut a speech
    // start that is still being confirmed.
    if (_speechStart < 0 && _run == 0 && i + 1 >= _noSpeechWindows) {
      return _decision = VadDecision(VadEndReason.noSpeech, 0, 0, i);
    }
    if (i + 1 >= _maxWindows) {
      return _decision = _speechStart >= 0
          ? VadDecision(VadEndReason.maxDuration, _cutStart, i + 1, i)
          : VadDecision(VadEndReason.noSpeech, 0, 0, i);
    }
    return null;
  }

  /// Returns the first decision reached while feeding [probabilities].
  VadDecision? feedAll(Iterable<double> probabilities) {
    for (final p in probabilities) {
      final decision = feed(p);
      if (decision != null) return decision;
    }
    return null;
  }

  /// Stop button or media key: everything fed so far, from the first speech
  /// minus pre-roll, or the whole round when no speech was confirmed.
  VadDecision forceEnd(VadEndReason reason) {
    if (_decision != null) return _decision!;
    if (_windows == 0) {
      return _decision = const VadDecision(VadEndReason.noSpeech, 0, 0, 0);
    }
    return _decision = VadDecision(
      reason,
      _speechStart >= 0 ? _cutStart : 0,
      _windows,
      _windows - 1,
    );
  }
}

/// Time allowed for on-device recognition of [segment]: covers a cold model
/// load (3.1 s measured) and a real-time factor up to 0.5 (measured ≤ 0.11).
Duration vadRecognitionBudget(Duration segment) =>
    const Duration(seconds: 10) + segment * 0.5;
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `git add lib/core/services/vad_endpoint.dart`
Run: `git commit -m "feat(voice): vad end-of-utterance state machine"`
Run: `bash tools/factory/ci-suite.sh`
Expected: exit 0, `Analyze & Test: success`, last line `ci-suite: run <id> conclusion=success …`.

---

### Task 3: Python mirror + parity test in CI

**Files:**
- Create: `tools/voice/vad_endpoint.py`
- Test: `scripts/tests/test_vad_endpoint_parity.py`

**Interfaces:**
- Consumes: `test/fixtures/vad_endpoint_cases.json` (Task 2).
- Produces (Task 5): `class Config(pause_ms=1800, min_speech_ms=250, pre_roll_ms=300, max_ms=120000, no_speech_ms=8000)`, `class Decision(reason, start_window, end_window, at_window)`, `class Endpointer(config)` with `feed(p) -> Decision | None`, `feed_all(ps) -> Decision | None`, `force_end(reason) -> Decision`, constants `WINDOW_MS = 32`, `WINDOW_SAMPLES = 512`, `START_THRESHOLD = 0.5`, `END_THRESHOLD = 0.35`, `TAIL_MS = 250`.

- [ ] **Step 1: Write the failing test**

`scripts/tests/test_vad_endpoint_parity.py`:

```python
"""Golden cases shared with test/vad_endpoint_test.dart (Dart is the app's implementation)."""
import json
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "voice"))

import vad_endpoint  # noqa: E402


def expand(runs):
    for probability, count in runs:
        for _ in range(count):
            yield float(probability)


class VadEndpointParityTest(unittest.TestCase):
    def test_golden_cases(self):
        cases = json.loads((ROOT / "test/fixtures/vad_endpoint_cases.json").read_text())["cases"]
        self.assertGreaterEqual(len(cases), 16)
        for case in cases:
            with self.subTest(case["name"]):
                raw = case["config"]
                config = vad_endpoint.Config(
                    pause_ms=raw.get("pauseMs", 1800),
                    min_speech_ms=raw.get("minSpeechMs", 250),
                    pre_roll_ms=raw.get("preRollMs", 300),
                    max_ms=raw.get("maxMs", 120000),
                    no_speech_ms=raw.get("noSpeechMs", 8000),
                )
                endpointer = vad_endpoint.Endpointer(config)
                decision = endpointer.feed_all(expand(case["runs"]))
                if decision is None and case["force"]:
                    decision = endpointer.force_end(case["force"])
                expected = case["expect"]
                if expected is None:
                    self.assertIsNone(decision)
                    continue
                self.assertIsNotNone(decision)
                self.assertEqual(
                    (decision.reason, decision.start_window, decision.end_window, decision.at_window),
                    (expected["reason"], expected["startWindow"], expected["endWindow"], expected["atWindow"]),
                )


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 -I -m unittest discover -s scripts/tests -p test_vad_endpoint_parity.py -v`
Expected: `ModuleNotFoundError: No module named 'vad_endpoint'`, FAILED (errors=1).

- [ ] **Step 3: Implement the mirror**

`tools/voice/vad_endpoint.py`:

```python
"""Python mirror of lib/core/services/vad_endpoint.dart (spec section 4).

Used only for offline tuning on the vServer. The app's implementation is Dart;
scripts/tests/test_vad_endpoint_parity.py keeps both identical through
test/fixtures/vad_endpoint_cases.json. Change both together.
"""
import math
from dataclasses import dataclass

WINDOW_MS = 32
WINDOW_SAMPLES = 512
START_THRESHOLD = 0.5
END_THRESHOLD = 0.35
TAIL_MS = 250


def windows_for(ms):
    return math.ceil(ms / WINDOW_MS)


@dataclass(frozen=True)
class Config:
    pause_ms: int = 1800
    min_speech_ms: int = 250
    pre_roll_ms: int = 300
    max_ms: int = 120000
    no_speech_ms: int = 8000


@dataclass(frozen=True)
class Decision:
    reason: str
    start_window: int
    end_window: int
    at_window: int


class Endpointer:
    def __init__(self, config):
        self.config = config
        self._pause_windows = windows_for(config.pause_ms)
        self._min_speech_windows = windows_for(config.min_speech_ms)
        self._pre_roll_windows = windows_for(config.pre_roll_ms)
        self._tail_windows = windows_for(TAIL_MS)
        self._max_windows = config.max_ms // WINDOW_MS
        self._no_speech_windows = config.no_speech_ms // WINDOW_MS
        self.windows = 0
        self._run = 0
        self._run_start = -1
        self._speech_start = -1
        self._last_speech = -1
        self._silence = 0
        self.decision = None

    def _cut_start(self):
        return max(0, self._speech_start - self._pre_roll_windows)

    def feed(self, p):
        if self.decision is not None:
            return None
        i = self.windows
        self.windows += 1
        if self._speech_start < 0:
            if p >= START_THRESHOLD:
                if self._run == 0:
                    self._run_start = i
                self._run += 1
                if self._run >= self._min_speech_windows:
                    self._speech_start = self._run_start
                    self._last_speech = i
                    self._silence = 0
            elif p < END_THRESHOLD:
                self._run = 0
        elif p >= END_THRESHOLD:
            self._last_speech = i
            self._silence = 0
        else:
            self._silence += 1
            if self._silence >= self._pause_windows:
                end = min(self._last_speech + 1 + self._tail_windows, i + 1)
                self.decision = Decision("pause", self._cut_start(), end, i)
                return self.decision
        if self._speech_start < 0 and self._run == 0 and i + 1 >= self._no_speech_windows:
            self.decision = Decision("noSpeech", 0, 0, i)
            return self.decision
        if i + 1 >= self._max_windows:
            if self._speech_start >= 0:
                self.decision = Decision("maxDuration", self._cut_start(), i + 1, i)
            else:
                self.decision = Decision("noSpeech", 0, 0, i)
            return self.decision
        return None

    def feed_all(self, probabilities):
        for p in probabilities:
            decision = self.feed(p)
            if decision is not None:
                return decision
        return None

    def force_end(self, reason):
        if self.decision is not None:
            return self.decision
        if self.windows == 0:
            self.decision = Decision("noSpeech", 0, 0, 0)
        else:
            start = self._cut_start() if self._speech_start >= 0 else 0
            self.decision = Decision(reason, start, self.windows, self.windows - 1)
        return self.decision
```

- [ ] **Step 4: Run it to verify it passes**

Run: `python3 -I -m unittest discover -s scripts/tests -p test_vad_endpoint_parity.py -v`
Expected: `test_golden_cases ... ok`, `OK`.
Run: `python3 -I -m unittest discover -s scripts/tests -v`
Expected: `OK` (the existing release tests still pass; this is the same command CI runs).

- [ ] **Step 5: Commit**

```bash
git add tools/voice/vad_endpoint.py scripts/tests/test_vad_endpoint_parity.py
git commit -m "test(voice): python mirror of the vad endpointer with parity test"
```

---

### Task 4: Mutation check (pause threshold 0)

**Files:** none kept. This uses a throwaway branch.

**Interfaces:** none.

The mutation: in `lib/core/services/vad_endpoint.dart` replace
`: _pauseWindows = vadWindowsFor(config.pause),` with `: _pauseWindows = 0,`. In `tools/voice/vad_endpoint.py`
replace `self._pause_windows = windows_for(config.pause_ms)` with `self._pause_windows = 0`.

Expected red tests (the first silent window after speech now ends the round):
- `test/vad_endpoint_test.dart`:
  - `a thinking pause shorter than the pause keeps the round open`: atWindow 100 instead of 227. **This is the named mutation test.**
  - `ends after the pause and keeps the tail`: atWindow 100 instead of 156.
  - Also red: `56 silent windows do not end it and pre-roll is clamped at zero`, `probabilities between the thresholds keep speech going`, `probabilities between the thresholds do not reset a starting run`, `a shorter pause setting ends earlier`, `a speech start in progress at the no-speech timeout is not cut`, `media key stop keeps speech minus pre-roll` (a pause decision now comes before the forced stop).
  - Still green, as expected: the noSpeech cases (including both no-speech timeout cases), the maxDuration and manual cases, `pre-roll is included in the cut`, `no fixed 7 s stop: …`, and `defaults match the card` (it reads `vadWindowsFor`, not the field).
- `scripts/tests/test_vad_endpoint_parity.py`: `test_golden_cases` fails in the same subTests.

- [ ] **Step 1: Branch and mutate**

Run: `git switch -c mutation/vad-pause-zero`
Edit both files as described above (one line each).

- [ ] **Step 2: Python mutation is red (local)**

Run: `python3 -I -m unittest discover -s scripts/tests -p test_vad_endpoint_parity.py -v`
Expected: `FAILED (failures=…)`, with subTest names including `a thinking pause shorter than the pause keeps the round open`.

- [ ] **Step 3: Dart mutation is red (CI)**

Run: `git commit -am "test: mutation pause=0 (throwaway, never merge)"`
Run: `bash tools/factory/ci-suite.sh`
Expected: non-zero exit, `Analyze & Test: failure`, `failed step: Run tests`. The workflow summary (in the
Actions UI, run URL printed on the last line) lists `a thinking pause shorter than the pause keeps the round open`
as failed. Python `Test release tooling` fails first, so analyze/test do not run. To see the Dart failure
separately, first revert the Python line on this branch, commit, and run `bash tools/factory/ci-suite.sh` again.
Expected: `failed step: Run tests`.

- [ ] **Step 4: Back to the branch and delete the throwaway**

Run: `git switch -`
Run: `git branch -D mutation/vad-pause-zero`
Run: `git status --short`
Expected: no changes. `grep -n "_pauseWindows = vadWindowsFor" lib/core/services/vad_endpoint.dart` prints one line.

- [ ] **Step 5: Record**

Append to `docs/VAD_INPUT.md`:

```markdown
## Mutation check (pause threshold 0)

`_pauseWindows = 0` (Dart) / `self._pause_windows = 0` (Python): CI run <id> failed in
`a thinking pause shorter than the pause keeps the round open` (+ <n> more); Python parity test failed locally.
```

Run: `git add docs/VAD_INPUT.md`
Run: `git commit -m "docs(voice): record vad pause mutation check"`

---

### Task 5: Offline endpoint check on the vServer (car WAV + synthetic)

**Files:**
- Create: `tools/voice/vad_offline_check.py`
- Create: `tools/voice/make_selftest_audio.py`
- Modify: `docs/VAD_INPUT.md`

**Interfaces:**
- Consumes: `tools/voice/vad_endpoint.py` (Task 3).
- Produces (Task 15): `make_selftest_audio.py --speech A --speech B --noise N --out OUT.wav --labels-out OUT.json`; `vad_offline_check.py --model M --wav W [--labels L] [--grid] [--inspect]`.

Tools live outside CI and need numpy + onnxruntime in a venv **inside the worktree's git-ignored `build/`**. The
private car WAV is read from its path and never copied.

- [ ] **Step 1: Prepare the venv and the model**

Run: `python3 -m venv build/vad-venv`
Run: `build/vad-venv/bin/pip install --quiet numpy onnxruntime`
Expected: exit 0.
Run: `mkdir -p build/vad-check`
Run: `curl -L --fail -o build/vad-check/silero_vad.onnx https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx`
Run: `sha256sum build/vad-check/silero_vad.onnx`
Expected: `9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6  build/vad-check/silero_vad.onnx`.

- [ ] **Step 2: Write the offline checker**

`tools/voice/vad_offline_check.py`:

```python
#!/usr/bin/env python3
"""Offline check of the vad endpoint parameters. Prints numbers only.

Never copies or prints audio or text. Typical use:
  build/vad-venv/bin/python -I tools/voice/vad_offline_check.py --model build/vad-check/silero_vad.onnx --inspect
  build/vad-venv/bin/python -I tools/voice/vad_offline_check.py --model M --wav <file> [--labels L.json] [--grid]
--labels: JSON {"speech": [[start_s, end_s], ...]} with true speech intervals (for synthetic files from
make_selftest_audio.py, or hand-made for a real recording; keep such labels outside the repo).
"""
import argparse
import json
import pathlib
import sys
import wave

import numpy as np
import onnxruntime as ort

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import vad_endpoint as ve  # noqa: E402

RATE = 16000
CONTEXT = 64


def read_mono_16k(path):
    with wave.open(str(path)) as w:
        channels, width, rate, frames = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        if width != 2:
            raise SystemExit(f"only 16-bit PCM supported, got {width * 8}-bit")
        data = np.frombuffer(w.readframes(frames), dtype="<i2").astype(np.float32) / 32768.0
    data = data.reshape(-1, channels).mean(axis=1)
    if rate != RATE:
        # FFT resampling; fine for VAD purposes.
        n_out = int(round(len(data) * RATE / rate))
        spectrum = np.fft.rfft(data)
        keep = n_out // 2 + 1
        spectrum = spectrum[:keep] if len(spectrum) >= keep else np.pad(spectrum, (0, keep - len(spectrum)))
        data = np.fft.irfft(spectrum, n_out).astype(np.float32) * (n_out / len(data))
    return data, rate, channels


class Silero:
    """Same input layout as Wing: 64 context samples + 512 new ones per call."""

    def __init__(self, model):
        options = ort.SessionOptions()
        options.inter_op_num_threads = 1
        options.intra_op_num_threads = 1
        self.session = ort.InferenceSession(str(model), options, providers=["CPUExecutionProvider"])
        self.inputs = {i.name: i for i in self.session.get_inputs()}

    def probabilities(self, samples):
        state = np.zeros((2, 1, 128), dtype=np.float32)
        context = np.zeros(CONTEXT, dtype=np.float32)
        sr = np.array(RATE, dtype=np.int64)
        out = []
        for start in range(0, len(samples) - ve.WINDOW_SAMPLES + 1, ve.WINDOW_SAMPLES):
            chunk = samples[start:start + ve.WINDOW_SAMPLES]
            x = np.concatenate([context, chunk])[None, :]
            prob, state = self.session.run(None, {"x": x, "state": state, "sr": sr})[:2]
            out.append(float(np.asarray(prob).reshape(-1)[0]))
            context = chunk[-CONTEXT:]
        return out


def segments(probabilities, config):
    """Run the endpointer repeatedly like consecutive rounds; returns decisions in seconds."""
    result, offset = [], 0
    while offset < len(probabilities):
        endpointer = ve.Endpointer(config)
        decision = endpointer.feed_all(probabilities[offset:])
        if decision is None:
            decision = endpointer.force_end("endOfFile")
        w = ve.WINDOW_MS / 1000
        result.append({
            "reason": decision.reason,
            "start_s": round((offset + decision.start_window) * w, 3),
            "end_s": round((offset + decision.end_window) * w, 3),
            "decided_s": round((offset + decision.at_window + 1) * w, 3),
        })
        offset += decision.at_window + 1
    return result


def score(found, labels):
    """End error of the round covering each labeled utterance group, false rounds, splits."""
    speech = labels["speech"]
    spoken = [s for s in found if s["reason"] in ("pause", "maxDuration")]
    false_rounds = [s for s in spoken if not any(a < s["end_s"] and b > s["start_s"] for a, b in speech)]
    end_errors = []
    for s in spoken:
        inside = [b for a, b in speech if a < s["end_s"] and b > s["start_s"]]
        if inside:
            end_errors.append(round((s["end_s"] - max(inside)) * 1000))
    return {"rounds_with_speech": len(spoken), "false_rounds": len(false_rounds), "end_error_ms": end_errors}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--wav")
    parser.add_argument("--labels")
    parser.add_argument("--grid", action="store_true")
    parser.add_argument("--inspect", action="store_true")
    args = parser.parse_args()
    silero = Silero(args.model)
    if args.inspect:
        print(json.dumps({"inputs": {n: list(i.shape) for n, i in silero.inputs.items()},
                          "outputs": [o.name for o in silero.session.get_outputs()]}))
        return
    samples, rate, channels = read_mono_16k(args.wav)
    probabilities = silero.probabilities(samples)
    p = np.array(probabilities)
    report = {
        "input": {"rate": rate, "channels": channels, "seconds": round(len(samples) / RATE, 2)},
        "windows": len(p),
        "probability_percentiles": {str(q): round(float(np.percentile(p, q)), 3) for q in (10, 50, 90, 99)},
        "share_above_start": round(float((p >= ve.START_THRESHOLD).mean()), 3),
    }
    labels = json.loads(pathlib.Path(args.labels).read_text()) if args.labels else None
    pauses = (1000, 1400, 1800, 2400, 3000) if args.grid else (1800,)
    report["runs"] = []
    for pause in pauses:
        found = segments(probabilities, ve.Config(pause_ms=pause))
        run = {"pause_ms": pause, "rounds": found}
        if labels:
            run["score"] = score(found, labels)
        report["runs"].append(run)
    print(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
```

`ANNAHME:` the model's inputs are `x`, `state` (2×1×128) and `sr` (silero v5 layout). Check in Step 4 (`--inspect`). If
the names differ (e.g. `input`, `h`, `c`), adapt the `session.run` feed to the printed names and note it in `docs/VAD_INPUT.md`.

- [ ] **Step 3: Write the synthetic self-test generator**

`tools/voice/make_selftest_audio.py`:

```python
#!/usr/bin/env python3
"""Builds a synthetic test file: noise lead, sentence A, short thinking pause, sentence B, noise tail.

Inputs must be synthetic (TTS) speech, never real recordings of a person.
Writes 16 kHz mono PCM16 WAV and a labels JSON {"speech": [[s, e], ...], "thinking_pause_s": x}.
Prints only numbers.
"""
import argparse
import json
import pathlib
import sys
import wave

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from vad_offline_check import RATE, read_mono_16k  # noqa: E402


def rms(x):
    return float(np.sqrt(np.mean(np.square(x)) + 1e-12))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--speech", action="append", required=True)
    parser.add_argument("--noise", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--labels-out", required=True)
    parser.add_argument("--lead-s", type=float, default=4.0)
    parser.add_argument("--pause-s", type=float, default=1.0)
    parser.add_argument("--tail-s", type=float, default=6.0)
    parser.add_argument("--snr-db", type=float, default=10.0)
    args = parser.parse_args()
    parts, labels, cursor = [], [], 0.0
    gap = np.zeros(int(args.lead_s * RATE), dtype=np.float32)
    parts.append(gap)
    cursor += args.lead_s
    for index, path in enumerate(args.speech):
        speech, _, _ = read_mono_16k(path)
        # Trim digital silence around the TTS sentence so labels are exact.
        voiced = np.flatnonzero(np.abs(speech) > 0.01)
        speech = speech[voiced[0]:voiced[-1] + 1]
        labels.append([round(cursor, 3), round(cursor + len(speech) / RATE, 3)])
        parts.append(speech)
        cursor += len(speech) / RATE
        pause = args.pause_s if index < len(args.speech) - 1 else args.tail_s
        parts.append(np.zeros(int(pause * RATE), dtype=np.float32))
        cursor += pause
    clean = np.concatenate(parts)
    noise, _, _ = read_mono_16k(args.noise)
    noise = np.resize(noise, len(clean))
    speech_rms = rms(np.concatenate([clean[int(a * RATE):int(b * RATE)] for a, b in labels]))
    noise = noise * (speech_rms / rms(noise)) / (10 ** (args.snr_db / 20))
    mix = np.clip(clean + noise, -1, 1)
    with wave.open(args.out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((mix * 32767).astype("<i2").tobytes())
    pathlib.Path(args.labels_out).write_text(json.dumps({"speech": labels, "thinking_pause_s": args.pause_s}))
    print(json.dumps({"seconds": round(len(mix) / RATE, 2), "speech": labels, "snr_db": args.snr_db}))


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Inspect the model**

Run: `build/vad-venv/bin/python -I tools/voice/vad_offline_check.py --model build/vad-check/silero_vad.onnx --inspect`
Expected: `{"inputs": {"x": [...], "state": [2, 1, 128], "sr": []}, "outputs": [...]}`, or other names (see ANNAHME).

- [ ] **Step 5: Positive and negative control on the measured synthetic mixes (known ground truth)**

Run: `build/vad-venv/bin/python -I tools/voice/vad_offline_check.py --model build/vad-check/silero_vad.onnx --wav /mnt/HC_Volume_106183673/hermes/profiles/worker/cache/scratch/wingvoice/tts/mix_s1_snr0.wav`
Expected: `share_above_start` ≥ 0.3 (speech 1.000–4.634 s of 5.634 s per `rohdaten/ground_truth.txt`). The file
ends only 1.0 s after the speech, so the round ends with `reason` `endOfFile` (not `pause`), and `start_s` lies
between 0.5 and 1.6. The pause behaviour is checked in Step 6, where the file has a 6 s tail.
Run: `build/vad-venv/bin/python -I tools/voice/vad_offline_check.py --model build/vad-check/silero_vad.onnx --wav /mnt/HC_Volume_106183673/hermes/profiles/worker/cache/scratch/wingvoice/tts/noise_only_15s.wav`
Expected: no `pause` or `maxDuration` round (no false alarm). With the 8 s no-speech timeout the 15 s file yields
one `noSpeech` round (decided at ≈ 8.0 s) followed by an `endOfFile` round for the remaining ≈ 7 s.

- [ ] **Step 6: Thinking-pause file with labels**

Run: `build/vad-venv/bin/python -I tools/voice/make_selftest_audio.py --speech /mnt/HC_Volume_106183673/hermes/profiles/worker/cache/scratch/wingvoice/tts/s1.wav --speech /mnt/HC_Volume_106183673/hermes/profiles/worker/cache/scratch/wingvoice/tts/s2.wav --noise /mnt/HC_Volume_106183673/hermes/profiles/worker/cache/scratch/wingvoice/tts/noise_60s.wav --out build/vad-check/selftest.wav --labels-out build/vad-check/selftest.labels.json`
Expected: JSON with two `speech` intervals separated by 1.0 s.
Run: `build/vad-venv/bin/python -I tools/voice/vad_offline_check.py --model build/vad-check/silero_vad.onnx --wav build/vad-check/selftest.wav --labels build/vad-check/selftest.labels.json --grid`
Expected: for `pause_ms` 1800: `score.rounds_with_speech == 1` (the 1.0 s pause did not split), `false_rounds == 0`,
and an `end_error_ms` value between −300 and +600.

- [ ] **Step 7: Private car recording (numbers only)**

Run: `build/vad-venv/bin/python -I tools/voice/vad_offline_check.py --model build/vad-check/silero_vad.onnx --wav /home/birk/handy-builds/messung/auto-2026-10-13-1528.wav --grid`
Expected: `input` = `{"rate": 44100, "channels": 2, "seconds": 68.52}` and a report of percentiles and rounds per
pause. Without labels there is no pass/fail. Record in `docs/VAD_INPUT.md`: percentiles, `share_above_start`, and
for each pause the number of rounds with speech and their `decided_s − end_s`. **Do not** paste rounds that would
reveal what was said; times and counts only. Check by eye: driving noise alone must not produce rounds that never
end (a `maxDuration` round lasting the whole file would mean noise counted as speech). If it does, write that down as
the key tuning finding for Birk; do not change the defaults without his decision.

This recording is the real reference for the **built-in phone mic in driving noise** (Birk's finding, spec 1.1). It is
one fixed file, so it tunes and verifies the endpoint parameters but **cannot compare audio sources** (that is the
Task 15 A/B). Record two further numbers:
- `noSpeech` rounds: how many rounds end by the 8 s no-speech timeout while Birk was actually speaking. These are
  candidates for "speech not detected at phone-mic distance". Compare them with the percentiles: if the speech share
  never exceeds the start threshold, Silero does not hear the far voice. That is a finding for Birk, not a parameter
  to change silently.
- The same report with `--no-speech-ms 12000` (see the flag below) to see whether a longer wait changes the picture.

Add the flag to `vad_offline_check.py` in this step:
`parser.add_argument("--no-speech-ms", type=int, default=8000)`, then pass
`ve.Config(pause_ms=pause, no_speech_ms=args.no_speech_ms)` in the `segments(...)` call inside `main()`.
Run: `build/vad-venv/bin/python -I tools/voice/vad_offline_check.py --model build/vad-check/silero_vad.onnx --wav /home/birk/handy-builds/messung/auto-2026-10-13-1528.wav --grid --no-speech-ms 12000`
Expected: the same `input` block. Record the counts per pause.

- [ ] **Step 8: Commit**

```bash
git add tools/voice/vad_offline_check.py tools/voice/make_selftest_audio.py docs/VAD_INPUT.md
git commit -m "chore(voice): offline vad endpoint check and synthetic self-test audio"
```

---

### Task 6: Preferences: input route enum and vad settings

**Files:**
- Modify: `lib/core/services/voice_preferences.dart`
- Modify: `lib/core/controllers/voice_input_controller.dart:60` (enum rename only)
- Modify: `lib/core/widgets/voice_preferences_card.dart:146-160,239-254,376-377` (enum rename only; the UI comes in Task 10)
- Test: `test/voice_preferences_test.dart`, `test/voice_processing_test.dart`

**Interfaces:**
- Consumes: `VadEndpointConfig` (Task 2).
- Produces:
  - `enum VoiceInputRoute { local, hermes, vad }`
  - `enum VadAudioSource { communication, recognition }`
  - `VoicePreferences` fields: `final VoiceInputRoute input; final VadEndpointConfig vad; final bool cues; final bool debugRecordings; final VadAudioSource audioSource;`
  - keys: `vadPauseKey = 'voice.vad_pause_ms'`, `vadMinSpeechKey = 'voice.vad_min_speech_ms'`, `vadPreRollKey = 'voice.vad_preroll_ms'`, `vadMaxKey = 'voice.vad_max_seconds'`, `vadNoSpeechKey = 'voice.vad_no_speech_seconds'`, `vadCuesKey = 'voice.vad_cues'`, `vadDebugKey = 'voice.vad_debug'`, `vadSourceKey = 'voice.vad_source'`
  - choice lists: `static const vadPauseChoices = ['1000','1400','1800','2400','3000']`, `vadMinSpeechChoices = ['150','250','400']`, `vadPreRollChoices = ['200','300','500']`, `vadMaxChoices = ['30','60','120']`, `vadNoSpeechChoices = ['5','8','12','20']`
  - **No microphone preference** (gestrichen, Birk 13.10.): recording uses whatever input Android routes.

- [ ] **Step 1: Write the failing tests**

Append to `test/voice_preferences_test.dart` inside `main()` after the conversation-mode test:

```dart
  test('vad route and its settings persist with card defaults', () async {
    final prefs = await SharedPreferences.getInstance();
    final initial = VoicePreferences.read(prefs);
    expect(initial.input, VoiceInputRoute.local);
    expect(initial.vad.pause, const Duration(milliseconds: 1800));
    expect(initial.vad.minSpeech, const Duration(milliseconds: 250));
    expect(initial.vad.preRoll, const Duration(milliseconds: 300));
    expect(initial.vad.maxDuration, const Duration(seconds: 120));
    expect(initial.vad.noSpeechTimeout, const Duration(seconds: 8));
    expect(initial.cues, isTrue);
    expect(initial.debugRecordings, isFalse);
    expect(initial.audioSource, VadAudioSource.communication);
    await saveDevicePreference(prefs, VoicePreferences.inputKey, 'vad');
    await saveDevicePreference(prefs, VoicePreferences.vadPauseKey, '2400');
    await saveDevicePreference(prefs, VoicePreferences.vadMinSpeechKey, '400');
    await saveDevicePreference(prefs, VoicePreferences.vadPreRollKey, '500');
    await saveDevicePreference(prefs, VoicePreferences.vadMaxKey, '60');
    await saveDevicePreference(prefs, VoicePreferences.vadNoSpeechKey, '12');
    await saveDevicePreference(prefs, VoicePreferences.vadCuesKey, 'off');
    await saveDevicePreference(prefs, VoicePreferences.vadDebugKey, 'on');
    await saveDevicePreference(prefs, VoicePreferences.vadSourceKey, 'recognition');
    await prefs.reload();
    final saved = VoicePreferences.read(prefs);
    expect(saved.input, VoiceInputRoute.vad);
    expect(saved.output, VoiceProcessing.local);
    expect(saved.vad.pause, const Duration(milliseconds: 2400));
    expect(saved.vad.minSpeech, const Duration(milliseconds: 400));
    expect(saved.vad.preRoll, const Duration(milliseconds: 500));
    expect(saved.vad.maxDuration, const Duration(seconds: 60));
    expect(saved.vad.noSpeechTimeout, const Duration(seconds: 12));
    expect(saved.cues, isFalse);
    expect(saved.debugRecordings, isTrue);
    expect(saved.audioSource, VadAudioSource.recognition);
  });

  test('vad choices are validated for backups; output never accepts vad', () {
    expect(VoicePreferences.accepts(VoicePreferences.inputKey, 'vad'), isTrue);
    expect(VoicePreferences.accepts(VoicePreferences.outputKey, 'vad'), isFalse);
    for (final key in [
      VoicePreferences.vadPauseKey,
      VoicePreferences.vadMinSpeechKey,
      VoicePreferences.vadPreRollKey,
      VoicePreferences.vadMaxKey,
      VoicePreferences.vadNoSpeechKey,
      VoicePreferences.vadCuesKey,
      VoicePreferences.vadDebugKey,
      VoicePreferences.vadSourceKey,
    ]) {
      expect(VoicePreferences.keys, contains(key));
      expect(VoicePreferences.accepts(key, '0'), isFalse, reason: key);
    }
    expect(VoicePreferences.accepts(VoicePreferences.vadPauseKey, '1800'), isTrue);
    expect(VoicePreferences.accepts(VoicePreferences.vadPauseKey, '0'), isFalse);
    expect(VoicePreferences.accepts(VoicePreferences.vadMaxKey, '120'), isTrue);
    expect(VoicePreferences.accepts(VoicePreferences.vadNoSpeechKey, '8'), isTrue);
    expect(VoicePreferences.accepts(VoicePreferences.vadNoSpeechKey, '7'), isFalse);
    expect(VoicePreferences.accepts(VoicePreferences.vadSourceKey, 'recognition'), isTrue);
    expect(VoicePreferences.keys, isNot(contains('voice.vad_microphone')));
    expect(VoicePreferences.accepts(VoicePreferences.vadDebugKey, 'on'), isTrue);
  });

  test('unknown stored vad values fall back to defaults', () async {
    SharedPreferences.setMockInitialValues({
      VoicePreferences.vadPauseKey: '7',
      VoicePreferences.vadNoSpeechKey: '99',
    });
    final prefs = await SharedPreferences.getInstance();
    final read = VoicePreferences.read(prefs);
    expect(read.vad.pause, const Duration(milliseconds: 1800));
    expect(read.vad.noSpeechTimeout, const Duration(seconds: 8));
  });
```

Mechanical renames in existing tests (input only; output keeps `VoiceProcessing`):
- `test/voice_preferences_test.dart:81` `expect(VoicePreferences.read(prefs).input, VoiceInputRoute.local);`
- `:89` `expect(saved.input, VoiceInputRoute.hermes);`
- `:183` and `:217` `…input, VoiceInputRoute.local);`
- `test/voice_processing_test.dart:11` `for (final input in [VoiceInputRoute.local, VoiceInputRoute.hermes]) {`. This keeps the four existing input × output combinations; vad has its own tests in Task 8.
- `test/voice_processing_test.dart:46,48,67,71` replace `VoiceProcessing.local` with `VoiceInputRoute.local` where compared with `input`.
- `test/voice_processing_test.dart:141,197` `const VoicePreferences(input: VoiceInputRoute.hermes)`.

- [ ] **Step 2: Implement**

Replace `lib/core/services/voice_preferences.dart` with:

```dart
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
      return value != null && choices.contains(value) ? int.parse(value) : fallback;
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
        pause: Duration(milliseconds: choice(vadPauseKey, vadPauseChoices, 1800)),
        minSpeech: Duration(
          milliseconds: choice(vadMinSpeechKey, vadMinSpeechChoices, 250),
        ),
        preRoll: Duration(milliseconds: choice(vadPreRollKey, vadPreRollChoices, 300)),
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
```

`lib/core/controllers/voice_input_controller.dart:60` becomes `if (settings.input == VoiceInputRoute.hermes) _remote = createRemote();`.

`lib/core/widgets/voice_preferences_card.dart`: in `_engine(...)` change the parameter type to `Enum selected`. It
uses `selected.name` only, so it stays generic. `:242` and `:246` compare with `VoiceInputRoute.local`, and `:376`
compares with `VoiceInputRoute.hermes`. No visible change yet.

- [ ] **Step 3: Run the suite**

Run: `git add lib/core/services/voice_preferences.dart lib/core/controllers/voice_input_controller.dart lib/core/widgets/voice_preferences_card.dart test/voice_preferences_test.dart test/voice_processing_test.dart`
Run: `git commit -m "feat(voice): vad input route and its device settings"`
Run: `bash tools/factory/ci-suite.sh`
Expected: exit 0, `conclusion=success`. `test/config_backup_service_test.dart` ("rejects invalid voice choices") still passes unchanged.

---

### Task 7: Device contract for the vad route

**Files:**
- Modify: `lib/core/services/android_voice.dart`
- Modify: `test/support/voice_fixture.dart`

**Interfaces:**
- Consumes: `VadDecision`, `VadEndpointConfig` (Task 2); `VadAudioSource` (Task 6).
- Produces (Tasks 8, 10, 11). There is no microphone option: recording uses Android's routed input.

```dart
class VadCaptureOptions {
  const VadCaptureOptions({required this.cues, required this.debug, required this.source, required this.maxDuration});
  final bool cues; final bool debug; final VadAudioSource source; final Duration maxDuration;
  Map<String, Object> toMap();
}
enum VadModelState { absent, downloading, verifying, unpacking, installed, failed }
class VadModelStatus {
  const VadModelStatus({required this.state, this.bytes = 0, this.total = 0, this.error});
  factory VadModelStatus.fromMap(Map<Object?, Object?> data);
  final VadModelState state; final int bytes; final int total; final String? error;
}
// VoiceDevice additions:
Future<void> startVad(String id, VadCaptureOptions options);
Future<String> finishVad(String id, VadDecision decision, VadEndpointConfig config);
Future<VadModelStatus> vadModelStatus();
Future<void> installVadModel();
Future<void> cancelVadModelInstall();
Future<void> removeVadModel();
Future<void> prepareVad();
Future<void> releaseVad();
Future<void> setMediaKeys(bool on);
Future<void> keepScreenOn(bool on);
Future<int> deleteVadDebugRecordings();
```

Fixture additions (used by Tasks 8, 10, 11): `int vadStarts`, `VadCaptureOptions? vadOptions`, `List<VadDecision> finishes`, `String vadTranscript = 'Hello from the phone'`, `Completer<String>? finishDelay`, `Object? finishError`, `VadModelStatus modelStatus = const VadModelStatus(state: VadModelState.installed)`, `List<bool> keepScreenOnCalls`, `List<bool> mediaKeysCalls`, `int prepares`, `int releases`, `int installs`, `int cancelInstalls`, `int removals`, `int debugDeletes`, `void emitWindows(List<double> windows)`, `void emitMediaKey()`, `void emitModel(VadModelStatus status)`.

- [ ] **Step 1: Add the types and methods**

Append to `lib/core/services/android_voice.dart` (keep the existing content; add the imports at the top):

```dart
import 'vad_endpoint.dart';
import 'voice_preferences.dart';
```

```dart
class VadCaptureOptions {
  const VadCaptureOptions({
    required this.cues,
    required this.debug,
    required this.source,
    required this.maxDuration,
  });
  final bool cues;
  final bool debug;
  final VadAudioSource source;
  final Duration maxDuration;

  Map<String, Object> toMap() => {
    'cues': cues,
    'debug': debug,
    'source': source.name,
    'maxMs': maxDuration.inMilliseconds,
  };
}

enum VadModelState { absent, downloading, verifying, unpacking, installed, failed }

class VadModelStatus {
  const VadModelStatus({
    required this.state,
    this.bytes = 0,
    this.total = 0,
    this.error,
  });
  factory VadModelStatus.fromMap(Map<Object?, Object?> data) => VadModelStatus(
    state: VadModelState.values.firstWhere(
      (state) => state.name == data['state'],
      orElse: () => VadModelState.failed,
    ),
    bytes: (data['bytes'] as num?)?.toInt() ?? 0,
    total: (data['total'] as num?)?.toInt() ?? 0,
    error: data['error'] as String?,
  );
  final VadModelState state;
  final int bytes;
  final int total;
  final String? error;
}
```

Add to `abstract interface class VoiceDevice` (after `stopPlayback`):

```dart
  /// Route vad: own capture; probabilities arrive as `{id, first, windows}` events.
  Future<void> startVad(String id, VadCaptureOptions options);

  /// Ends the vad round and returns the on-device transcript of the decided windows.
  Future<String> finishVad(String id, VadDecision decision, VadEndpointConfig config);
  Future<VadModelStatus> vadModelStatus();
  Future<void> installVadModel();
  Future<void> cancelVadModelInstall();
  Future<void> removeVadModel();
  Future<void> prepareVad();
  Future<void> releaseVad();
  Future<void> setMediaKeys(bool on);
  Future<void> keepScreenOn(bool on);
  Future<int> deleteVadDebugRecordings();
```

Add to `class AndroidVoice`:

```dart
  @override
  Future<void> startVad(String id, VadCaptureOptions options) =>
      channel.invokeMethod('startVad', {'id': id, ...options.toMap()});
  @override
  Future<String> finishVad(
    String id,
    VadDecision decision,
    VadEndpointConfig config,
  ) async =>
      await channel.invokeMethod<String>('finishVad', {
        'id': id,
        'startWindow': decision.startWindow,
        'endWindow': decision.endWindow,
        'atWindow': decision.atWindow,
        'reason': decision.reason.name,
        'config': config.toJson(),
      }) ??
      '';
  @override
  Future<VadModelStatus> vadModelStatus() async => VadModelStatus.fromMap(
    await channel.invokeMapMethod<Object?, Object?>('vadModelStatus') ?? {},
  );
  @override
  Future<void> installVadModel() => channel.invokeMethod('installVadModel');
  @override
  Future<void> cancelVadModelInstall() =>
      channel.invokeMethod('cancelVadModelInstall');
  @override
  Future<void> removeVadModel() => channel.invokeMethod('removeVadModel');
  @override
  Future<void> prepareVad() => channel.invokeMethod('prepareVad');
  @override
  Future<void> releaseVad() => channel.invokeMethod('releaseVad');
  @override
  Future<void> setMediaKeys(bool on) =>
      channel.invokeMethod('setMediaKeys', {'on': on});
  @override
  Future<void> keepScreenOn(bool on) =>
      channel.invokeMethod('keepScreenOn', {'on': on});
  @override
  Future<int> deleteVadDebugRecordings() async =>
      await channel.invokeMethod<int>('deleteVadDebugRecordings') ?? 0;
```

- [ ] **Step 2: Extend the fixture**

Add to `test/support/voice_fixture.dart` (imports `package:wing/core/services/vad_endpoint.dart`; fields and methods inside `VoiceDeviceFixture`):

```dart
  int vadStarts = 0;
  VadCaptureOptions? vadOptions;
  final finishes = <VadDecision>[];
  String vadTranscript = 'Hello from the phone';
  Completer<String>? finishDelay;
  Object? finishError;
  VadModelStatus modelStatus = const VadModelStatus(state: VadModelState.installed);
  final keepScreenOnCalls = <bool>[];
  final mediaKeysCalls = <bool>[];
  int prepares = 0;
  int releases = 0;
  int installs = 0;
  int cancelInstalls = 0;
  int removals = 0;
  int debugDeletes = 0;
  int _firstWindow = 0;

  /// Sends one probability batch for the running vad round.
  void emitWindows(List<double> windows) {
    stream.add({'id': recording, 'first': _firstWindow, 'windows': windows});
    _firstWindow += windows.length;
  }

  void emitMediaKey() => stream.add({'mediaKey': 'playPause'});
  void emitModel(VadModelStatus status) {
    modelStatus = status;
    stream.add({
      'model': {
        'state': status.state.name,
        'bytes': status.bytes,
        'total': status.total,
        'error': ?status.error,
      },
    });
  }

  @override
  Future<void> startVad(String id, VadCaptureOptions options) async {
    calls.add('startVad');
    vadStarts++;
    recording = id;
    local = true;
    vadOptions = options;
    _firstWindow = 0;
    if (startError != null) throw startError!;
    await startDelay?.future;
  }

  @override
  Future<String> finishVad(
    String id,
    VadDecision decision,
    VadEndpointConfig config,
  ) async {
    calls.add('finishVad');
    finishes.add(decision);
    if (finishError != null) throw finishError!;
    return finishDelay?.future ?? vadTranscript;
  }

  @override
  Future<VadModelStatus> vadModelStatus() async => modelStatus;
  @override
  Future<void> installVadModel() async => installs++;
  @override
  Future<void> cancelVadModelInstall() async => cancelInstalls++;
  @override
  Future<void> removeVadModel() async {
    removals++;
    modelStatus = const VadModelStatus(state: VadModelState.absent);
  }
  @override
  Future<void> prepareVad() async => prepares++;
  @override
  Future<void> releaseVad() async => releases++;
  @override
  Future<void> setMediaKeys(bool on) async => mediaKeysCalls.add(on);
  @override
  Future<void> keepScreenOn(bool on) async => keepScreenOnCalls.add(on);
  @override
  Future<int> deleteVadDebugRecordings() async {
    debugDeletes++;
    return 3;
  }
```

`ANNAHME:` the null-aware map element `'error': ?status.error` needs Dart ≥ 3.8 (pubspec has `sdk: ^3.12.0`, so it is
available). If the analyzer rejects it, write `if (status.error != null) 'error': status.error!`.

- [ ] **Step 3: Run the suite**

Run: `git add lib/core/services/android_voice.dart test/support/voice_fixture.dart`
Run: `git commit -m "feat(voice): device contract for the vad route"`
Run: `bash tools/factory/ci-suite.sh`
Expected: exit 0, `conclusion=success`. There are no behaviour changes yet; all existing tests still pass.

---

### Task 8: VoiceInputController for route vad

**Files:**
- Modify: `lib/core/controllers/voice_input_controller.dart`
- Test: `test/voice_vad_input_test.dart`

**Interfaces:**
- Consumes: Tasks 2, 6, 7.
- Produces (Task 11): `Future<void> VoiceInputController.stopHandsFree()`, `int VoiceInputController.maxSeconds` (shown as "Recording · Xs / {maxSeconds}s"), `bool VoiceInputController.vad` (true while a vad round is active). `finishedOnItsOwn` is true after a `pause` or `mediaKey` decision.

- [ ] **Step 1: Write the failing tests**

`test/voice_vad_input_test.dart`:

```dart
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/controllers/voice_input_controller.dart';
import 'package:wing/core/services/android_voice.dart';
import 'package:wing/core/services/vad_endpoint.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'support/voice_fixture.dart';

List<double> _p(double value, int count) => List.filled(count, value);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VoiceDeviceFixture device;
  late VoiceInputController recorder;
  TextEditingValue? result;
  const settings = VoicePreferences(
    input: VoiceInputRoute.vad,
    cues: false,
    debugRecordings: true,
    audioSource: VadAudioSource.recognition,
    vad: VadEndpointConfig(
      maxDuration: Duration(seconds: 60),
      noSpeechTimeout: Duration(seconds: 12),
    ),
  );

  setUp(() {
    device = VoiceDeviceFixture();
    recorder = VoiceInputController(
      device: device,
      createRemote: () => throw StateError('vad never uses Hermes'),
    );
    result = null;
  });
  tearDown(() async {
    recorder.dispose();
    await device.stream.close();
  });

  Future<void> start() => recorder.start(
    settings,
    const TextEditingValue(text: ''),
    (value) => result = value,
  );

  test('starts the own capture with the saved vad options', () async {
    await start();
    expect(device.calls, ['startVad']);
    expect(device.vadOptions!.toMap().containsKey('microphone'), isFalse);
    expect(device.vadOptions!.cues, isFalse);
    expect(device.vadOptions!.debug, isTrue);
    expect(device.vadOptions!.source, VadAudioSource.recognition);
    expect(device.vadOptions!.maxDuration, const Duration(seconds: 60));
    expect(recorder.phase, VoiceInputPhase.recording);
    expect(recorder.maxSeconds, 60);
    expect(recorder.vad, isTrue);
  });

  test('a pause ends the round by itself and inserts the phone transcript', () async {
    await start();
    device.emitWindows(_p(0.05, 40));
    device.emitWindows(_p(0.9, 60));
    expect(device.finishes, isEmpty);
    device.emitWindows(_p(0.1, 80));
    await pumpEventQueue();
    expect(device.finishes.single.reason, VadEndReason.pause);
    expect(device.finishes.single.startWindow, 30);
    expect(device.finishes.single.endWindow, 108);
    expect(result!.text, 'Hello from the phone');
    expect(recorder.finishedOnItsOwn, isTrue);
    expect(recorder.active, isFalse);
  });

  test('a thinking pause shorter than the setting keeps recording', () async {
    await start();
    device.emitWindows(_p(0.9, 30));
    device.emitWindows(_p(0.1, 31));
    device.emitWindows(_p(0.9, 10));
    await pumpEventQueue();
    expect(device.finishes, isEmpty);
    expect(recorder.phase, VoiceInputPhase.recording);
  });

  test('Stop ends the round manually and is not hands-free', () async {
    await start();
    device.emitWindows(_p(0.9, 20));
    await recorder.stop();
    await pumpEventQueue();
    expect(device.finishes.single.reason, VadEndReason.manual);
    expect(device.finishes.single.endWindow, 20);
    expect(result!.text, 'Hello from the phone');
    expect(recorder.finishedOnItsOwn, isFalse);
  });

  test('the media key ends the round hands-free', () async {
    await start();
    device.emitWindows(_p(0.9, 20));
    await recorder.stopHandsFree();
    await pumpEventQueue();
    expect(device.finishes.single.reason, VadEndReason.mediaKey);
    expect(recorder.finishedOnItsOwn, isTrue);
  });

  test('no speech within the no-speech timeout ends the round without recognition', () async {
    await start();
    // 12 s timeout = 375 windows. 7 s (218 windows) is no limit on this route.
    device.emitWindows(_p(0.05, 374));
    await pumpEventQueue();
    expect(recorder.phase, VoiceInputPhase.recording);
    expect(recorder.error, isNull);
    device.emitWindows(_p(0.05, 1));
    await pumpEventQueue();
    // The phone only learns the reason (for the debug JSON); Kotlin skips recognition.
    expect(device.finishes.single.reason, VadEndReason.noSpeech);
    expect(device.finishes.single.atWindow, 374);
    expect(recorder.error, 'No speech detected. Try again.');
    expect(device.cancelled, isNotEmpty);
    expect(result, isNull);
  });

  test('an empty transcript is reported as no speech', () async {
    device.vadTranscript = '  ';
    await start();
    device.emitWindows(_p(0.9, 20));
    device.emitWindows(_p(0.1, 60));
    await pumpEventQueue();
    expect(recorder.error, 'No speech detected. Try again.');
  });

  test('a missing model is reported from start', () async {
    device.startError = PlatformException(
      code: 'voice_unavailable',
      message: 'Download the speech model in App settings → Voice.',
    );
    await start();
    expect(recorder.error, 'Download the speech model in App settings → Voice.');
    expect(recorder.active, isFalse);
  });

  test('windows after the decision are ignored', () async {
    device.finishDelay = Completer<String>();
    await start();
    device.emitWindows(_p(0.9, 20));
    device.emitWindows(_p(0.1, 60));
    device.emitWindows(_p(0.9, 60));
    device.emitWindows(_p(0.1, 60));
    await pumpEventQueue();
    expect(device.finishes, hasLength(1));
    expect(recorder.phase, VoiceInputPhase.transcribing);
    device.finishDelay!.complete('Done');
    await pumpEventQueue();
    expect(result!.text, 'Done');
  });

  testWidgets('recognition gets a budget that scales with the segment', (tester) async {
    device.finishDelay = Completer<String>();
    await start();
    // 2 s of speech + tail: budget = 10 s + half the segment (≈ 11.3 s).
    device.emitWindows(_p(0.9, 62));
    device.emitWindows(_p(0.1, 60));
    await tester.pump();
    expect(recorder.phase, VoiceInputPhase.transcribing);
    await tester.pump(const Duration(seconds: 11));
    expect(recorder.error, isNull, reason: 'still within the budget');
    await tester.pump(const Duration(seconds: 1));
    expect(recorder.error, 'Speech processing timed out. Please retry.');
    expect(device.cancelled, isNotEmpty);
  });
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `git add test/voice_vad_input_test.dart`
Run: `git commit -m "test(voice): controller behaviour on the vad route"`
Run: `bash tools/factory/ci-suite.sh`
Expected: non-zero exit; analyzer errors `The getter 'maxSeconds' isn't defined`, `The method 'stopHandsFree' isn't defined`.

- [ ] **Step 3: Implement**

In `lib/core/controllers/voice_input_controller.dart` add `import '../services/vad_endpoint.dart';` and change the class as follows.

Fields (after `RemoteVoice? _remote;`):

```dart
  VadEndpointer? _endpointer;

  /// Upper bound shown while recording ("Recording · 12s / 120s").
  int maxSeconds = 120;

  /// True while a round on the vad route is active.
  bool get vad => _endpointer != null;
```

In `start(...)`, replace the `try { … }` body up to `phase = VoiceInputPhase.recording;` with:

```dart
    try {
      if (settings.input == VoiceInputRoute.vad) {
        _endpointer = VadEndpointer(settings.vad);
        maxSeconds = settings.vad.maxDuration.inSeconds;
        await device.startVad(
          id,
          VadCaptureOptions(
            cues: settings.cues,
            debug: settings.debugRecordings,
            source: settings.audioSource,
            maxDuration: settings.vad.maxDuration,
          ),
        );
      } else {
        maxSeconds = 120;
        if (settings.input == VoiceInputRoute.hermes) _remote = createRemote();
        await device.start(
          id,
          local: _remote == null,
          language: settings.language,
        );
      }
      if (_id != id || _disposed) {
        await device.cancel(id);
        return;
      }
      phase = VoiceInputPhase.recording;
      _notify();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        seconds++;
        _notify();
        // The vad endpointer owns its own limit.
        if (_endpointer == null && seconds >= 120) unawaited(stop());
      });
    } catch (failure) {
      if (_id == id) _fail(failure);
    }
```

In `_event`, before the `if (event['text'] …` block:

```dart
    if (event['windows'] case final List<Object?> windows) {
      final endpointer = _endpointer;
      if (endpointer == null || phase != VoiceInputPhase.recording) return;
      final decision = endpointer.feedAll(
        windows.map((value) => (value as num).toDouble()),
      );
      if (decision != null) unawaited(_finishVad(decision));
      return;
    }
```

A `noSpeech` decision (from the no-speech timeout or max duration) goes through `_finishVad`, which fails with
"No speech detected. Try again." and cancels the capture without recognition.

`stop()` gets a vad branch directly after its first line `if (id == null || phase != VoiceInputPhase.recording) return;`,
**before** `_stopRequested = true;` (`_finishVad` sets `_stopRequested` and the phase itself):

```dart
    final endpointer = _endpointer;
    if (endpointer != null) {
      await _finishVad(endpointer.forceEnd(VadEndReason.manual));
      return;
    }
```

New methods:

```dart
  /// Media key: ends the round as a hands-free action (sent in conversation mode).
  Future<void> stopHandsFree() async {
    final endpointer = _endpointer;
    if (_id == null || phase != VoiceInputPhase.recording) return;
    if (endpointer == null) return stop();
    await _finishVad(endpointer.forceEnd(VadEndReason.mediaKey));
  }

  Future<void> _finishVad(VadDecision decision) async {
    final id = _id;
    final endpointer = _endpointer;
    if (id == null || endpointer == null || phase != VoiceInputPhase.recording) {
      return;
    }
    _timer?.cancel();
    if (!decision.hasSpeech) {
      // Tell the phone why the round ended (debug JSON reason "noSpeech"; Kotlin
      // skips recognition for it), then end the round. Channel calls keep their
      // order, so the following cancel finds no round left.
      unawaited(
        device
            .finishVad(id, decision, endpointer.config)
            .then((_) {}, onError: (Object _) {}),
      );
      _fail(StateError('No speech detected. Try again.'));
      return;
    }
    _stopRequested =
        decision.reason != VadEndReason.pause &&
        decision.reason != VadEndReason.mediaKey;
    phase = VoiceInputPhase.transcribing;
    _notify();
    try {
      final text = await device
          .finishVad(id, decision, endpointer.config)
          .timeout(vadRecognitionBudget(decision.segment));
      if (_id == id && !_disposed) _finish(text);
    } catch (failure) {
      if (_id == id) _fail(failure);
    }
  }
```

In `_clear()` add `_endpointer = null;`.

`_finish` is unchanged: `finishedOnItsOwn = !_stopRequested && _remote == null` is now true for `pause`/`mediaKey`.

- [ ] **Step 4: Run the suite to verify it passes**

Run: `git add lib/core/controllers/voice_input_controller.dart`
Run: `git commit -m "feat(voice): vad rounds in the voice input controller"`
Run: `bash tools/factory/ci-suite.sh`
Expected: exit 0, `conclusion=success` (including all existing `voice_processing_test.dart` cases).

---

### Task 9: Build plumbing: sherpa AAR, Silero asset, commons-compress, CI helpers

**Files:**
- Modify: `android/app/build.gradle.kts`
- Create: `android/app/proguard-rules.pro`
- Modify: `.gitignore`
- Modify: `.github/workflows/voice-apk.yml`
- Create: `tools/factory/dispatch-check.sh`

**Interfaces:**
- Produces: classes `com.k2fsa.sherpa.onnx.*` and `org.apache.commons.compress.*` on the app classpath; APK asset `silero_vad.onnx`; command `bash tools/factory/dispatch-check.sh <workflow.yml> [key=value …]`.

- [ ] **Step 1: Generic dispatch helper**

`tools/factory/dispatch-check.sh`:

```bash
#!/usr/bin/env bash
# Runs a workflow_dispatch workflow for committed HEAD on a throwaway ref and
# waits for its result (like ci-suite.sh, which stays the factory's test command).
# Usage: dispatch-check.sh <workflow.yml> [input=value ...]
#   dispatch-check.sh voice-apk.yml publish=false   # compile Kotlin, no voice-apk-bin update
#   dispatch-check.sh voice-apk.yml publish=true    # build for the phone
#   dispatch-check.sh voice-review.yml              # renders -> branch voice-review-bin
set -euo pipefail
repo=birkschmithuesen/Wing
workflow=$1; shift
sha=$(git rev-parse HEAD)
br="ci-${workflow%.yml}/${sha:0:12}"
git push -q -f origin "HEAD:refs/heads/$br"
trap 'git push -q origin --delete "$br" >/dev/null 2>&1 || true' EXIT
fields=()
for kv in "$@"; do fields+=(-f "$kv"); done
gh workflow run "$workflow" -R "$repo" --ref "$br" "${fields[@]}" >/dev/null
id=""
for _ in $(seq 1 30); do
  id=$(gh run list -R "$repo" --workflow "$workflow" --branch "$br" \
        --json databaseId,headSha --jq ".[] | select(.headSha==\"$sha\") | .databaseId" | head -1)
  [ -n "$id" ] && break
  sleep 5
done
[ -n "$id" ] || { echo "dispatch-check: no $workflow run appeared for $br" >&2; exit 2; }
echo "dispatch-check: $workflow run $id for $sha"
gh run watch "$id" -R "$repo" --interval 20 >/dev/null 2>&1 || true
concl=$(gh run view "$id" -R "$repo" --json conclusion --jq .conclusion)
gh run view "$id" -R "$repo" --json jobs \
  --jq '.jobs[] | "\(.name): \(.conclusion)" , (.steps[] | select(.conclusion=="failure") | "  failed step: \(.name)")' || true
echo "dispatch-check: $workflow run $id conclusion=$concl https://github.com/$repo/actions/runs/$id"
[ "$concl" = "success" ]
```

Run: `chmod +x tools/factory/dispatch-check.sh`

- [ ] **Step 2: Workflow: publish input and new tests**

`.github/workflows/voice-apk.yml`: replace the `on:` block and the test/publish steps:

```yaml
on:
  workflow_dispatch:
    inputs:
      publish:
        description: Update branch voice-apk-bin with this build
        type: boolean
        default: true
  push:
    branches: [voice-offline]
```

```yaml
      - name: Tests (voice)
        run: flutter test --no-pub test/voice_preferences_test.dart test/voice_processing_test.dart test/voice_workspace_test.dart test/vad_endpoint_test.dart test/voice_vad_input_test.dart
```

(Task 10 appends `test/vad_settings_test.dart` to this line when it creates that file.)

```yaml
      - name: Publish to voice-apk-bin branch
        if: github.event_name == 'push' || inputs.publish
```

- [ ] **Step 3: Gradle fetch task, dependencies, ProGuard**

In `android/app/build.gradle.kts` add, after the `GenerateLauncherShortcuts` class:

```kotlin
/** Downloads a pinned artifact once and verifies its SHA256 (never committed to git). */
abstract class FetchVerifiedFile : DefaultTask() {
    @get:Input
    abstract val url: Property<String>

    @get:Input
    abstract val sha256: Property<String>

    @get:Input
    abstract val fileName: Property<String>

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun fetch() {
        val target = outputDirectory.file(fileName).get().asFile
        if (target.isFile && digest(target) == sha256.get()) return
        target.parentFile.mkdirs()
        val part = java.io.File(target.path + ".part")
        java.net.URI(url.get()).toURL().openStream().use { input ->
            part.outputStream().use { input.copyTo(it) }
        }
        val actual = digest(part)
        check(actual == sha256.get()) { "SHA256 mismatch for ${url.get()}: $actual" }
        check(part.renameTo(target)) { "Could not move $part to $target" }
    }

    private fun digest(file: java.io.File): String {
        val md = java.security.MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(1 shl 16)
            while (true) {
                val n = stream.read(buffer)
                if (n < 0) break
                md.update(buffer, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}

val fetchSherpaOnnxAar = tasks.register<FetchVerifiedFile>("fetchSherpaOnnxAar") {
    url.set("https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-1.13.8.aar")
    sha256.set("633c24321e06b1fe79feafa03ea16cbc0f8a286641e2da3559bac91bdb13bd96")
    fileName.set("sherpa-onnx-1.13.8.aar")
    outputDirectory.set(layout.projectDirectory.dir("libs"))
}
val fetchSileroVad = tasks.register<FetchVerifiedFile>("fetchSileroVad") {
    url.set("https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx")
    sha256.set("9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6")
    fileName.set("silero_vad.onnx")
    outputDirectory.set(layout.buildDirectory.dir("generated/vadAssets"))
}
// preBuild is created by AGP per variant; match it lazily.
tasks.matching { it.name == "preBuild" }.configureEach { dependsOn(fetchSherpaOnnxAar) }
```

(Use the hash confirmed in Task 1 Step 2 if it differed.)

In the existing `androidComponents { onVariants { variant -> … } }` block, add after the shortcuts registration:

```kotlin
        variant.sources.assets?.addGeneratedSourceDirectory(
            fetchSileroVad, FetchVerifiedFile::outputDirectory
        )
```

In `buildTypes { release { … } }` add:

```kotlin
           proguardFiles("proguard-rules.pro")
```

In `dependencies { … }` add:

```kotlin
   implementation(files("libs/sherpa-onnx-1.13.8.aar"))
   implementation("org.apache.commons:commons-compress:1.27.1")
```

`ANNAHME:` `implementation(files(...aar))` works in the app module and `preBuild` runs before the AAR is needed. Check:
the Step 5 build succeeds. Fallback if Gradle complains that the file is missing at configuration: run the fetch in
voice-apk.yml before `flutter build` (`./gradlew :app:fetchSherpaOnnxAar` from `android/`) and keep the `files()` dependency.

`ANNAHME:` commons-compress 1.27.1 runs on minSdk 24 with core library desugaring. Check: Step 5 build plus Task 15
(model unpacking on the device). Fallback: 1.21 (no commons-io/lang3 dependency).

- [ ] **Step 4: ProGuard rules and gitignore**

`android/app/proguard-rules.pro`:

```
# sherpa-onnx: JNI reads Kotlin config fields and constructs result classes by name.
-keep class com.k2fsa.sherpa.onnx.** { *; }
# commons-compress optional codecs Wing never uses (only bzip2 + tar).
-dontwarn org.tukaani.xz.**
-dontwarn com.github.luben.zstd.**
-dontwarn org.brotli.dec.**
-dontwarn org.objectweb.asm.**
-dontwarn org.osgi.**
-dontwarn java.lang.invoke.**
```

If R8 still fails, it writes `build/app/outputs/mapping/release/missing_rules.txt`. Copy the `-dontwarn` lines it
lists for `commons.compress` dependencies into this file; never add rules for `com.k2fsa`.

`.gitignore`: add a line `/android/app/libs/`.

- [ ] **Step 5: Compile on CI**

Run: `git add tools/factory/dispatch-check.sh .github/workflows/voice-apk.yml android/app/build.gradle.kts android/app/proguard-rules.pro .gitignore`
Run: `git commit -m "build(voice): fetch sherpa-onnx AAR and Silero model with pinned hashes"`
Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: exit 0, `build: success`, last line `dispatch-check: voice-apk.yml run <id> conclusion=success …`.
Run: `bash tools/factory/ci-suite.sh`
Expected: exit 0 (Dart unaffected).

---

### Task 10: Settings UI for the vad route

**Files:**
- Create: `lib/core/widgets/vad_settings_section.dart`
- Modify: `lib/core/widgets/voice_preferences_card.dart`
- Test: `test/vad_settings_test.dart`
- Modify: `.github/workflows/voice-apk.yml` (add `test/vad_settings_test.dart`)

**Interfaces:**
- Consumes: Tasks 6, 7.
- Produces: `class VadSettingsSection extends StatefulWidget { const VadSettingsSection({super.key, required VoicePreferences settings, required VoiceDevice device, required bool saving, required Future<void> Function(String key, String value) onSave}); }`. Widget keys used by tests: `ValueKey('vad-model-download')`, `ValueKey('vad-model-cancel')`, `ValueKey('vad-model-remove')`, `ValueKey('vad-model-retry')`, `ValueKey('vad-cues')`, `ValueKey('vad-debug')`, `ValueKey('vad-debug-delete')`.

Design (spec 8, arrangement B): the route select's third option is `(value: 'vad', label: 'On this phone · Parakeet')`.
For vad, the input description reads "Recognize on this phone. Pauses end each message automatically." Then come the
model row and the "Cue tones" switch (there is no microphone select: gestrichen, Birk 13.10.), then the collapsed `AnchoredExpansionTile` "Pause detection"
with five selects ("Pause before sending", "Wait for speech", "Minimum speech", "Lead-in kept", "Longest
recording"), "Debug recordings", and (debug on) "Audio source" plus "Delete debug recordings". The recognition
language row is hidden for vad.

- [ ] **Step 1: Write the failing tests**

`test/vad_settings_test.dart`:

```dart
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/android_voice.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_select.dart';
import 'package:wing/core/widgets/voice_preferences_card.dart';
import 'support/voice_fixture.dart';

void main() {
  const capture = bool.fromEnvironment('VOICE_REVIEW');
  const frame = Key('vad-frame');
  setUpAll(() async {
    if (!capture) return;
    const path = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': ['Roboto-Regular.ttf'],
      'MaterialIcons': ['MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final name in entry.value) {
        loader.addFont(
          Future.value(ByteData.sublistView(File('$path/$name').readAsBytesSync())),
        );
      }
      await loader.load();
    }
  });

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(frame));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build/voice-review').createSync(recursive: true);
      await File('build/voice-review/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  late VoiceDeviceFixture device;
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({VoicePreferences.inputKey: 'vad'});
    prefs = await SharedPreferences.getInstance();
    device = VoiceDeviceFixture();
  });
  tearDown(() => device.stream.close());

  Future<void> show(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(brightness),
        home: RepaintBoundary(
          key: frame,
          child: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 900),
                textScaler: TextScaler.linear(scale),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: VoicePreferencesCard(preferences: prefs, device: device),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  StudioSelect<String> select(WidgetTester tester, String label) => tester
      .widgetList<StudioSelect<String>>(find.byType(StudioSelect<String>))
      .firstWhere((w) => w.label == label);

  testWidgets('route vad offers the model download and hides the language', (tester) async {
    device.modelStatus = const VadModelStatus(state: VadModelState.absent);
    await show(tester);
    expect(select(tester, 'Voice input').value, 'vad');
    expect(find.text('Recognition language'), findsNothing);
    expect(find.text('Speech model · 487 MB download'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('vad-model-download')));
    await tester.pump();
    expect(device.installs, 1);
    await screenshot(tester, 'vad-model-absent-light-100');
  });

  testWidgets('download progress is shown and can be cancelled', (tester) async {
    device.modelStatus = const VadModelStatus(state: VadModelState.absent);
    await show(tester);
    device.emitModel(const VadModelStatus(
      state: VadModelState.downloading,
      bytes: 123000000,
      total: 487170055,
    ));
    await tester.pump();
    expect(find.text('123 / 487 MB'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await screenshot(tester, 'vad-model-downloading-light-100');
    await tester.tap(find.byKey(const ValueKey('vad-model-cancel')));
    await tester.pump();
    expect(device.cancelInstalls, 1);
    device.emitModel(const VadModelStatus(state: VadModelState.unpacking));
    await tester.pump();
    expect(find.text('Unpacking…'), findsOneWidget);
  });

  testWidgets('a failed install shows the error and retries', (tester) async {
    device.modelStatus = const VadModelStatus(
      state: VadModelState.failed,
      error: 'Download was corrupted. Retry.',
    );
    await show(tester);
    expect(find.text('Download was corrupted. Retry.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('vad-model-retry')));
    await tester.pump();
    expect(device.installs, 1);
    await screenshot(tester, 'vad-model-failed-light-100');
  });

  testWidgets('an installed model can be removed after confirmation', (tester) async {
    await show(tester);
    expect(find.text('Speech model ready'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('vad-model-remove')));
    await tester.pumpAndSettle();
    expect(device.removals, 0);
    await tester.tap(find.byKey(const ValueKey('vad-model-remove-confirm')));
    await tester.pumpAndSettle();
    expect(device.removals, 1);
  });

  testWidgets('cues and pause detection settings persist; no microphone choice', (tester) async {
    await show(tester);
    expect(find.text('Microphone'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('vad-cues')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Pause detection'));
    await tester.tap(find.text('Pause detection'));
    await tester.pumpAndSettle();
    select(tester, 'Pause before sending').onChanged!('2400');
    await tester.pumpAndSettle();
    expect(select(tester, 'Wait for speech').value, '8');
    select(tester, 'Wait for speech').onChanged!('12');
    await tester.pumpAndSettle();
    select(tester, 'Minimum speech').onChanged!('400');
    await tester.pumpAndSettle();
    select(tester, 'Lead-in kept').onChanged!('500');
    await tester.pumpAndSettle();
    select(tester, 'Longest recording').onChanged!('60');
    await tester.pumpAndSettle();
    final saved = VoicePreferences.read(prefs);
    expect(saved.cues, isFalse);
    expect(saved.vad.pause, const Duration(milliseconds: 2400));
    expect(saved.vad.noSpeechTimeout, const Duration(seconds: 12));
    expect(saved.vad.minSpeech, const Duration(milliseconds: 400));
    expect(saved.vad.preRoll, const Duration(milliseconds: 500));
    expect(saved.vad.maxDuration, const Duration(seconds: 60));
  });

  testWidgets('debug recordings reveal the audio source and delete action', (tester) async {
    await show(tester);
    await tester.ensureVisible(find.text('Pause detection'));
    await tester.tap(find.text('Pause detection'));
    await tester.pumpAndSettle();
    expect(find.text('Audio source'), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('vad-debug')));
    await tester.tap(find.byKey(const ValueKey('vad-debug')));
    await tester.pumpAndSettle();
    expect(VoicePreferences.read(prefs).debugRecordings, isTrue);
    expect(find.text('Audio source'), findsOneWidget);
    select(tester, 'Audio source').onChanged!('recognition');
    await tester.pumpAndSettle();
    expect(VoicePreferences.read(prefs).audioSource, VadAudioSource.recognition);
    await tester.ensureVisible(find.byKey(const ValueKey('vad-debug-delete')));
    await tester.tap(find.byKey(const ValueKey('vad-debug-delete')));
    await tester.pumpAndSettle();
    expect(device.debugDeletes, 1);
    await screenshot(tester, 'vad-pause-detection-open-light-100');
  });

  testWidgets('switching the route prepares or releases the phone model', (tester) async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    await show(tester);
    select(tester, 'Voice input').onChanged!('vad');
    await tester.pumpAndSettle();
    expect(device.prepares, 1);
    expect(device.mediaKeysCalls, [true]);
    select(tester, 'Voice input').onChanged!('local');
    await tester.pumpAndSettle();
    expect(device.releases, 1);
    expect(device.mediaKeysCalls, [true, false]);
  });

  for (final brightness in Brightness.values) {
    testWidgets('vad settings fit 320dp at 200% text in $brightness', (tester) async {
      device.modelStatus = const VadModelStatus(
        state: VadModelState.downloading,
        bytes: 300000000,
        total: 487170055,
      );
      SharedPreferences.setMockInitialValues({
        VoicePreferences.inputKey: 'vad',
        VoicePreferences.vadDebugKey: 'on',
      });
      prefs = await SharedPreferences.getInstance();
      await show(tester, brightness: brightness, scale: 2);
      expect(tester.takeException(), isNull);
      await screenshot(tester, 'vad-settings-${brightness.name}-200');
      await tester.ensureVisible(find.text('Pause detection'));
      await tester.tap(find.text('Pause detection'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('vad-debug-delete')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await screenshot(tester, 'vad-settings-open-${brightness.name}-200');
    });
  }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `git add test/vad_settings_test.dart`
Run: `git commit -m "test(voice): vad settings section"`
Run: `bash tools/factory/ci-suite.sh`
Expected: non-zero exit (tests fail: `'vad'` is not an option, `Speech model · 487 MB download` not found).

- [ ] **Step 3: Implement the section**

`lib/core/widgets/vad_settings_section.dart`:

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../services/android_voice.dart';
import '../services/voice_preferences.dart';
import 'anchored_expansion_tile.dart';
import 'compact_switch.dart';
import 'studio_error.dart';
import 'studio_select.dart';

/// Settings that exist only for the vad input route: the on-phone speech
/// model, cue tones, pause detection and debug recordings. There is no
/// microphone choice: recording uses whatever input Android routes.
class VadSettingsSection extends StatefulWidget {
  const VadSettingsSection({
    super.key,
    required this.settings,
    required this.device,
    required this.saving,
    required this.onSave,
  });
  final VoicePreferences settings;
  final VoiceDevice device;
  final bool saving;
  final Future<void> Function(String key, String value) onSave;

  @override
  State<VadSettingsSection> createState() => _VadSettingsSectionState();
}

class _VadSettingsSectionState extends State<VadSettingsSection> {
  static const _archiveMb = 487;
  VadModelStatus? _status;
  late final StreamSubscription<Map<String, dynamic>> _events;

  @override
  void initState() {
    super.initState();
    _events = widget.device.events.listen((event) {
      if (event['model'] case final Map<Object?, Object?> model) {
        if (mounted) setState(() => _status = VadModelStatus.fromMap(model));
      }
    });
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final status = await widget.device.vadModelStatus();
      if (mounted) setState(() => _status = status);
    } catch (_) {
      if (mounted) {
        setState(
          () => _status = const VadModelStatus(
            state: VadModelState.failed,
            error: 'Could not read the speech model state.',
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    super.dispose();
  }

  Future<void> _confirmRemove() async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove speech model?'),
        content: const Text('Frees about 670 MB. Downloading it again takes a while.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('vad-model-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove == true) {
      await widget.device.removeVadModel();
      await _refresh();
    }
  }

  Widget _model(BuildContext context) {
    final status = _status;
    if (status == null) return const LinearProgressIndicator();
    String mb(int bytes) => (bytes / 1000000).round().toString();
    Widget row(String text, Widget? action) => Row(
      children: [
        Expanded(child: Text(text)),
        ?action,
      ],
    );
    return switch (status.state) {
      VadModelState.absent => row(
        'Speech model · $_archiveMb MB download',
        TextButton(
          key: const ValueKey('vad-model-download'),
          onPressed: () => unawaited(widget.device.installVadModel()),
          child: const Text('Download'),
        ),
      ),
      VadModelState.downloading => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row(
            '${mb(status.bytes)} / ${mb(status.total == 0 ? 487170055 : status.total)} MB',
            TextButton(
              key: const ValueKey('vad-model-cancel'),
              onPressed: () => unawaited(widget.device.cancelVadModelInstall()),
              child: const Text('Cancel'),
            ),
          ),
          LinearProgressIndicator(
            value: status.total == 0 ? null : status.bytes / status.total,
          ),
        ],
      ),
      VadModelState.verifying || VadModelState.unpacking => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(status.state == VadModelState.verifying ? 'Checking…' : 'Unpacking…'),
          const LinearProgressIndicator(),
        ],
      ),
      VadModelState.installed => row(
        'Speech model ready',
        TextButton(
          key: const ValueKey('vad-model-remove'),
          onPressed: _confirmRemove,
          child: const Text('Remove'),
        ),
      ),
      VadModelState.failed => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StudioError(status.error ?? 'Speech model is unavailable.'),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('vad-model-retry'),
              onPressed: () => unawaited(widget.device.installVadModel()),
              child: const Text('Retry'),
            ),
          ),
        ],
      ),
    };
  }

  Widget _choice(
    String label,
    String key,
    String value,
    List<({String value, String label})> options,
  ) => StudioSelect<String>(
    key: ValueKey('$key-$value'),
    label: label,
    value: value,
    options: options,
    onChanged: widget.saving
        ? null
        : (next) {
            if (next != null) unawaited(widget.onSave(key, next));
          },
  );

  /// '1800' → '1.8 s', '1000' → '1 s', '150' → '0.15 s'.
  String _secondsLabel(String ms) {
    final text = (int.parse(ms) / 1000).toString();
    return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text} s';
  }

  List<({String value, String label})> _seconds(List<String> ms) => [
    for (final value in ms) (value: value, label: _secondsLabel(value)),
  ];

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _model(context),
        const SizedBox(height: 12),
        CompactSwitchListTile(
          key: const ValueKey('vad-cues'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Cue tones'),
          value: s.cues,
          onChanged: widget.saving
              ? null
              : (value) => unawaited(
                  widget.onSave(VoicePreferences.vadCuesKey, value ? 'on' : 'off'),
                ),
        ),
        AnchoredExpansionTile(
          title: const Text('Pause detection'),
          tilePadding: EdgeInsets.zero,
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _choice(
              'Pause before sending',
              VoicePreferences.vadPauseKey,
              s.vad.pause.inMilliseconds.toString(),
              _seconds(VoicePreferences.vadPauseChoices),
            ),
            const SizedBox(height: 12),
            _choice(
              'Wait for speech',
              VoicePreferences.vadNoSpeechKey,
              s.vad.noSpeechTimeout.inSeconds.toString(),
              [
                for (final value in VoicePreferences.vadNoSpeechChoices)
                  (value: value, label: '$value s'),
              ],
            ),
            const SizedBox(height: 12),
            _choice(
              'Minimum speech',
              VoicePreferences.vadMinSpeechKey,
              s.vad.minSpeech.inMilliseconds.toString(),
              _seconds(VoicePreferences.vadMinSpeechChoices),
            ),
            const SizedBox(height: 12),
            _choice(
              'Lead-in kept',
              VoicePreferences.vadPreRollKey,
              s.vad.preRoll.inMilliseconds.toString(),
              _seconds(VoicePreferences.vadPreRollChoices),
            ),
            const SizedBox(height: 12),
            _choice(
              'Longest recording',
              VoicePreferences.vadMaxKey,
              s.vad.maxDuration.inSeconds.toString(),
              [
                for (final value in VoicePreferences.vadMaxChoices)
                  (value: value, label: '$value s'),
              ],
            ),
            CompactSwitchListTile(
              key: const ValueKey('vad-debug'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Debug recordings'),
              subtitle: const Text(
                'Keeps audio and timing of each round on this phone. Never uploaded.',
              ),
              value: s.debugRecordings,
              onChanged: widget.saving
                  ? null
                  : (value) => unawaited(
                      widget.onSave(VoicePreferences.vadDebugKey, value ? 'on' : 'off'),
                    ),
            ),
            if (s.debugRecordings) ...[
              _choice('Audio source', VoicePreferences.vadSourceKey, s.audioSource.name, const [
                (value: 'communication', label: 'Call processing'),
                (value: 'recognition', label: 'Recognition'),
              ]),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('vad-debug-delete'),
                  onPressed: () => unawaited(widget.device.deleteVadDebugRecordings()),
                  child: const Text('Delete debug recordings'),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
```

The labels are `1 s, 1.4 s, 1.8 s, 2.4 s, 3 s, 0.15 s, 0.25 s, 0.4 s, 0.2 s, 0.3 s, 0.5 s`.

`ANNAHME:` `AnchoredExpansionTile` accepts `tilePadding` and `expandedCrossAxisAlignment` (both seen in its
constructor). The null-aware list element `?action` needs Dart ≥ 3.8 (SDK ^3.12, so it is available).

- [ ] **Step 4: Wire it into the card**

In `lib/core/widgets/voice_preferences_card.dart`:
- Import `vad_settings_section.dart`.
- Replace the input `_engine('Voice input', …)` call with:

```dart
        StudioSelect<String>(
          key: ValueKey('voice-input-${_preferences.input.name}'),
          label: 'Voice input',
          value: _preferences.input.name,
          options: const [
            (value: 'local', label: 'Local · Android'),
            (value: 'hermes', label: 'Hermes · server profile'),
            (value: 'vad', label: 'On this phone · Parakeet'),
          ],
          onChanged: _saving
              ? null
              : (value) {
                  if (value != null) unawaited(_saveInput(value));
                },
        ),
```

- Add:

```dart
  Future<void> _saveInput(String value) async {
    final device = widget.device ?? AndroidVoice.instance;
    final wasVad = _preferences.input == VoiceInputRoute.vad;
    await _save(VoicePreferences.inputKey, value);
    final isVad = _preferences.input == VoiceInputRoute.vad;
    if (isVad == wasVad) return;
    try {
      await device.setMediaKeys(isVad);
      await (isVad ? device.prepareVad() : device.releaseVad());
    } catch (_) {
      // The workspace retries on resume; settings stay saved.
    }
  }
```

- Description text under the select:

```dart
        Text(switch (_preferences.input) {
          VoiceInputRoute.local => 'Transcribe on this phone. Review the text before sending.',
          VoiceInputRoute.hermes => 'Send a recording to the selected Hermes profile and its speech provider. Review the text before sending.',
          VoiceInputRoute.vad => 'Recognize on this phone. Pauses end each message automatically.',
        }),
        if (_preferences.input == VoiceInputRoute.vad) ...[
          const SizedBox(height: 12),
          VadSettingsSection(
            settings: _preferences,
            device: widget.device ?? AndroidVoice.instance,
            saving: _saving,
            onSave: _save,
          ),
        ],
```

- Keep the existing `if (_preferences.input == VoiceInputRoute.local) ...[` language block unchanged. The
  `_engine(...)` helper remains for "Voice output" only, so change its parameter back to `VoiceProcessing selected`.
- Add `import 'dart:async';` if `unawaited` is not yet imported.

- [ ] **Step 5: Add the test file to voice-apk.yml and run the suite**

In `.github/workflows/voice-apk.yml`, append ` test/vad_settings_test.dart` to the `Tests (voice)` line if it is not already there.
Run: `git add lib/core/widgets/vad_settings_section.dart lib/core/widgets/voice_preferences_card.dart .github/workflows/voice-apk.yml`
Run: `git commit -m "feat(voice): settings for the on-phone vad route"`
Run: `bash tools/factory/ci-suite.sh`
Expected: exit 0, `conclusion=success`, including the existing `voice settings fit 320dp at 200% text` cases.

---

### Task 11: Workspace: vad conversation, media key, keep screen on, preload

**Files:**
- Modify: `lib/core/screens/profile_workspace_screen.dart` (lines ~166-176 fields, 207-219 `_conversation`, 412-427 status text, 511-528 initState, 553-564 lifecycle, 587-593 dispose)
- Test: `test/voice_workspace_test.dart`

**Interfaces:**
- Consumes: `VoiceInputController.stopHandsFree()`, `.maxSeconds` (Task 8); fixture helpers (Task 7).
- Produces: behaviour only.

- [ ] **Step 1: Write the failing tests**

Append inside `main()` of `test/voice_workspace_test.dart` (after the existing conversation tests; reuse `show`, `settle`, `prompts`, `gatewayEvent`, `conversationMode`):

```dart
  int vadStarts() => device.vadStarts;
  Future<void> vadRoute() => controller.preferences.setString(
    VoicePreferences.inputKey,
    'vad',
  );
  Future<void> windows(WidgetTester tester, double p, int count) async {
    device.emitWindows(List.filled(count, p));
    await settle(tester);
  }

  testWidgets('vad conversation sends after the pause', (tester) async {
    await vadRoute();
    await conversationMode(true);
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    expect(vadStarts(), 1);
    await windows(tester, 0.9, 30);
    await windows(tester, 0.1, 60);
    expect(device.finishes.single.reason.name, 'pause');
    expect(prompts(), 1);
    expect(
      fixture.calls.lastWhere((c) => c.$2 == 'prompt.submit').$3['text'],
      'Hello from the phone',
    );
    gatewayEvent('message.complete', {'text': 'Done.'});
    await settle(tester);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
  });

  testWidgets('vad thinking pause keeps the microphone open', (tester) async {
    await vadRoute();
    await conversationMode(true);
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    await windows(tester, 0.9, 30);
    await windows(tester, 0.1, 31);
    expect(device.finishes, isEmpty);
    expect(find.textContaining('Recording ·'), findsOneWidget);
    expect(prompts(), 0);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
  });

  testWidgets('media key ends a vad round and sends it in conversation mode', (tester) async {
    await vadRoute();
    await conversationMode(true);
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    await windows(tester, 0.9, 30);
    device.emitMediaKey();
    await settle(tester);
    expect(device.finishes.single.reason.name, 'mediaKey');
    expect(prompts(), 1);
    gatewayEvent('message.complete', {'text': 'Done.'});
    await settle(tester);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
  });

  testWidgets('media key starts a vad round when idle', (tester) async {
    await vadRoute();
    await show(tester);
    device.emitMediaKey();
    await settle(tester);
    expect(vadStarts(), 1);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
  });

  testWidgets('media key is ignored on the local route', (tester) async {
    await show(tester);
    device.emitMediaKey();
    await settle(tester);
    expect(starts(), 0);
    expect(vadStarts(), 0);
  });

  testWidgets('route vad preloads the model and enables media keys', (tester) async {
    await vadRoute();
    await show(tester);
    expect(device.prepares, 1);
    expect(device.mediaKeysCalls, [true]);
  });

  testWidgets('a running conversation keeps the screen on until it ends', (tester) async {
    await conversationMode(true);
    await show(tester);
    expect(device.keepScreenOnCalls, isEmpty);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    expect(device.keepScreenOnCalls, [true]);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
    expect(device.keepScreenOnCalls, [true, false]);
  });

  testWidgets('recording status shows the vad limit', (tester) async {
    await vadRoute();
    await controller.preferences.setString(VoicePreferences.vadMaxKey, '60');
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    expect(find.text('Recording · 0s / 60s'), findsOneWidget);
    await screenshot(tester, 'vad-recording-light-100');
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
  });
```

(`starts()` already exists in this file and counts `device.calls` entries `'start'`. If it does not, define
`int starts() => device.calls.where((c) => c == 'start').length;` next to `prompts()`.)

- [ ] **Step 2: Run the suite to verify it fails**

Run: `git add test/voice_workspace_test.dart`
Run: `git commit -m "test(voice): vad route in the chat workspace"`
Run: `bash tools/factory/ci-suite.sh`
Expected: non-zero exit; failures include `media key starts a vad round when idle` (vadStarts 0) and `a running conversation keeps the screen on` (calls empty).

- [ ] **Step 3: Implement**

In `lib/core/screens/profile_workspace_screen.dart`:

1. After `_voiceOutput` (~line 176):

```dart
  VoiceDevice get _voiceDevice => widget.voiceDevice ?? AndroidVoice.instance;
  StreamSubscription<Map<String, dynamic>>? _voiceDeviceEvents;
```

2. Replace the field `ProfileSessionKey? _conversation;` (~line 210) and keep its doc comment on the getter:

```dart
  ProfileSessionKey? _conversationKey;
  ProfileSessionKey? get _conversation => _conversationKey;

  /// Keeps the display on while a hands-free conversation runs: a screen
  /// timeout would pause the activity and end any capture.
  set _conversation(ProfileSessionKey? value) {
    if ((_conversationKey == null) != (value == null)) {
      unawaited(_voiceDevice.keepScreenOn(value != null).catchError((Object _) {}));
    }
    _conversationKey = value;
  }
```

3. New methods (near `_cancelVoice`):

```dart
  /// Route vad: preload the phone model and accept media keys; other routes release them.
  void _syncVadRoute() {
    final VoiceInputRoute route;
    try {
      route = VoicePreferences.read(controller.preferences).input;
    } on FormatException {
      return;
    }
    final vad = route == VoiceInputRoute.vad;
    unawaited(_voiceDevice.setMediaKeys(vad).catchError((Object _) {}));
    if (vad) unawaited(_voiceDevice.prepareVad().catchError((Object _) {}));
  }

  void _voiceDeviceEvent(Map<String, dynamic> event) {
    if (event['mediaKey'] != 'playPause' || !mounted || !_hasChatFocus) return;
    if (VoicePreferences.read(controller.preferences).input != VoiceInputRoute.vad) {
      return;
    }
    if (_voiceInput.phase == VoiceInputPhase.recording) {
      unawaited(_voiceInput.stopHandsFree());
      return;
    }
    if (_voiceInput.active) return;
    final chat = controller.notificationChat ?? controller.current?.chat;
    if (chat == null || controller.switching || _needsUserInput(chat)) return;
    unawaited(_run(() => _dictate(chat)));
  }
```

4. `initState()` after `_voiceInput.addListener(_voiceInputChanged);`:

```dart
    _voiceDeviceEvents = _voiceDevice.events.listen(_voiceDeviceEvent);
    _syncVadRoute();
```

5. `didChangeAppLifecycleState`: after `_appIsActive = …;` add `if (state == AppLifecycleState.resumed) _syncVadRoute();`.

6. `dispose()`: before `_voiceInput.removeListener(...)`:

```dart
    unawaited(_voiceDeviceEvents?.cancel());
    if (_conversationKey != null) {
      unawaited(_voiceDevice.keepScreenOn(false).catchError((Object _) {}));
    }
```

7. Status text (~line 425): `'Recording · ${_voiceInput.seconds}s / ${_voiceInput.maxSeconds}s'`.

Imports: `../services/voice_preferences.dart` and `../services/android_voice.dart` are already imported (check; add
them if missing).

- [ ] **Step 4: Run the suite to verify it passes**

Run: `git add lib/core/screens/profile_workspace_screen.dart`
Run: `git commit -m "feat(voice): media key, keep-screen-on and model preload in the workspace"`
Run: `bash tools/factory/ci-suite.sh`
Expected: exit 0, `conclusion=success`. All earlier conversation tests (`conversation reopens the microphone …`, `Cancel ends the conversation …`) still pass.

---

### Task 12: Kotlin: model store and Parakeet recognizer

**Files:**
- Create: `android/app/src/main/kotlin/com/tarkilhk/wing/SpeechModelStore.kt`
- Create: `android/app/src/main/kotlin/com/tarkilhk/wing/OfflineSpeech.kt`
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt`

**Interfaces:**
- Consumes: sherpa classes (Task 9), channel method names (Task 7 / spec 5).
- Produces (Task 13): `SpeechModelStore.modelDir: File`, `SpeechModelStore.verifyManifest(): String?` (null = OK, else a user message), `SpeechModelStore.status(): Map<String, Any>`, `install()`, `cancel()`, `remove()`, `close()`; `OfflineSpeech.prepare()`, `OfflineSpeech.transcribe(samples: FloatArray, done: (Result<String>, decodeMs: Long, readyAtStart: Boolean) -> Unit)`, `release()`, `close()`.

- [ ] **Step 1: SpeechModelStore**

`android/app/src/main/kotlin/com/tarkilhk/wing/SpeechModelStore.kt`:

```kotlin
package com.tarkilhk.wing

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.CancellationException
import java.util.concurrent.Executors

/** Parakeet TDT 0.6B v3 int8 in app-private storage. Per-file hashes are not
 *  published, so the archive hash is verified first and the per-file hashes in
 *  manifest.json are derived from the verified archive during extraction. */
class SpeechModelStore(private val context: Context, private val emit: (Map<String, Any>) -> Unit) {
    companion object {
        const val ARCHIVE_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2"
        const val ARCHIVE_SHA256 = "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf"
        const val ARCHIVE_BYTES = 487_170_055L
        const val ARCHIVE_NAME = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2"
        const val ARCHIVE_ROOT = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/"
        val FILES = listOf("encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt")
        private const val EXTRACTED_BYTES = 700L * 1000 * 1000
    }

    private val root = File(context.filesDir, "models")
    val modelDir = File(root, "parakeet-tdt-0.6b-v3-int8")
    private val download = File(root, "download/archive.tar.bz2.part")
    private val staging = File(root, "staging")
    private val executor = Executors.newSingleThreadExecutor()
    private val handler = Handler(Looper.getMainLooper())
    @Volatile private var cancelled = false
    @Volatile private var busy = false
    @Volatile private var current: Map<String, Any> = idleStatus()

    fun status(): Map<String, Any> = current

    private fun idleStatus(): Map<String, Any> =
        if (verifyManifest() == null) mapOf("state" to "installed", "bytes" to 0L, "total" to 0L)
        else mapOf("state" to "absent", "bytes" to download.length(), "total" to ARCHIVE_BYTES)

    /** null when the model can be loaded, else a message for the user. */
    fun verifyManifest(): String? {
        val manifest = File(modelDir, "manifest.json")
        if (!manifest.isFile) return "Download the speech model in App settings → Voice."
        return try {
            val files = JSONObject(manifest.readText()).getJSONObject("files")
            val broken = FILES.any { name ->
                val file = File(modelDir, name)
                !file.isFile || file.length() != files.getJSONObject(name).getLong("size")
            }
            if (broken) "Speech model is incomplete. Download it again." else null
        } catch (_: Exception) { "Speech model is incomplete. Download it again." }
    }

    private fun publish(state: String, bytes: Long = 0, total: Long = 0, error: String? = null) {
        val status = buildMap<String, Any> {
            put("state", state); put("bytes", bytes); put("total", total)
            if (error != null) put("error", error)
        }
        current = status
        handler.post { emit(mapOf("model" to status)) }
    }

    fun install() {
        if (busy) return
        busy = true
        cancelled = false
        executor.execute {
            try {
                val imported = context.getExternalFilesDir("import")?.let { File(it, ARCHIVE_NAME) }?.takeIf { it.isFile }
                val archive = imported ?: fetch()
                publish("verifying")
                if (sha256(archive) != ARCHIVE_SHA256) {
                    archive.delete()
                    error("Download was corrupted. Retry.")
                }
                publish("unpacking")
                extract(archive)
                archive.delete()
                publish("installed")
            } catch (_: CancellationException) {
                publish("absent", download.length(), ARCHIVE_BYTES)
            } catch (error: Exception) {
                publish("failed", error = error.message ?: "Speech model download failed. Retry.")
            } finally { busy = false }
        }
    }

    fun cancel() { cancelled = true }

    fun remove() {
        cancelled = true
        executor.execute {
            modelDir.deleteRecursively(); staging.deleteRecursively(); download.delete()
            publish("absent", 0, ARCHIVE_BYTES)
        }
    }

    fun close() { cancelled = true; executor.shutdown() }

    private fun fetch(): File {
        download.parentFile?.mkdirs()
        var have = download.length()
        check(root.usableSpace >= (ARCHIVE_BYTES - have) + EXTRACTED_BYTES) { "Needs about 1.2 GB free space." }
        var connection = URL(ARCHIVE_URL).openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = true
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        if (have > 0) connection.setRequestProperty("Range", "bytes=$have-")
        val code = connection.responseCode
        if (code == 416 && have == ARCHIVE_BYTES) return download
        val append = code == HttpURLConnection.HTTP_PARTIAL
        check(code == HttpURLConnection.HTTP_OK || append) { "Download failed (HTTP $code). Retry." }
        if (!append) have = 0
        var lastReport = 0L
        connection.inputStream.use { input ->
            FileOutputStream(download, append).use { output ->
                val buffer = ByteArray(1 shl 16)
                while (true) {
                    if (cancelled) throw CancellationException()
                    val n = input.read(buffer)
                    if (n < 0) break
                    output.write(buffer, 0, n)
                    have += n
                    val now = SystemClock.elapsedRealtime()
                    if (now - lastReport >= 500) { lastReport = now; publish("downloading", have, ARCHIVE_BYTES) }
                }
            }
        }
        connection.disconnect()
        check(download.length() == ARCHIVE_BYTES) { "Download was interrupted. Retry." }
        return download
    }

    private fun sha256(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(1 shl 16)
            while (true) {
                if (cancelled) throw CancellationException()
                val n = stream.read(buffer)
                if (n < 0) break
                md.update(buffer, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun extract(archive: File) {
        staging.deleteRecursively(); staging.mkdirs()
        val manifest = JSONObject()
        TarArchiveInputStream(BZip2CompressorInputStream(BufferedInputStream(archive.inputStream(), 1 shl 16))).use { tar ->
            while (true) {
                val entry = tar.nextEntry ?: break
                val name = entry.name
                require(!name.contains("..") && !name.startsWith("/")) { "Unexpected file in the speech model archive." }
                if (!name.startsWith(ARCHIVE_ROOT)) continue
                val base = name.removePrefix(ARCHIVE_ROOT)
                if (base !in FILES) continue
                val md = MessageDigest.getInstance("SHA-256")
                var size = 0L
                FileOutputStream(File(staging, base)).use { out ->
                    val buffer = ByteArray(1 shl 16)
                    while (true) {
                        if (cancelled) throw CancellationException()
                        val n = tar.read(buffer)
                        if (n < 0) break
                        out.write(buffer, 0, n); md.update(buffer, 0, n); size += n
                    }
                }
                manifest.put(base, JSONObject().put("size", size)
                    .put("sha256", md.digest().joinToString("") { "%02x".format(it) }))
            }
        }
        val missing = FILES.filter { !manifest.has(it) }
        check(missing.isEmpty()) { "Speech model archive is missing ${missing.joinToString()}." }
        File(staging, "manifest.json").writeText(
            JSONObject().put("archiveSha256", ARCHIVE_SHA256).put("files", manifest).toString(1))
        modelDir.deleteRecursively()
        check(staging.renameTo(modelDir)) { "Could not install the speech model." }
    }
}
```

`ANNAHME:` GitHub's CDN honours `Range` after the redirect, and `HttpURLConnection` follows the https→https redirect.
Check in Task 15 Step 5 (interrupt with airplane mode, then Retry: the bytes continue rather than restart). If it
restarts from 0 every time, that is acceptable (still correct); note it in `docs/VAD_INPUT.md`.

- [ ] **Step 2: OfflineSpeech**

`android/app/src/main/kotlin/com/tarkilhk/wing/OfflineSpeech.kt`:

```kotlin
package com.tarkilhk.wing

import android.os.SystemClock
import android.util.Log
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineTransducerModelConfig
import java.io.File
import java.util.concurrent.Executors

/** Parakeet TDT 0.6B v3 int8 (sherpa-onnx nemo_transducer). Every call runs on
 *  one executor, so loading and decoding never overlap. */
class OfflineSpeech(private val store: SpeechModelStore) {
    private val executor = Executors.newSingleThreadExecutor()
    private var recognizer: OfflineRecognizer? = null
    @Volatile var ready = false
        private set

    fun prepare() { executor.execute { runCatching { load() }.onFailure { Log.w("WingVad", "preload failed: ${it.message}") } } }

    private fun load(): OfflineRecognizer {
        recognizer?.let { return it }
        store.verifyManifest()?.let { error(it) }
        val dir = store.modelDir
        val started = SystemClock.elapsedRealtime()
        val config = OfflineRecognizerConfig(
            featConfig = FeatureConfig(sampleRate = 16000, featureDim = 80),
            modelConfig = OfflineModelConfig(
                transducer = OfflineTransducerModelConfig(
                    encoder = File(dir, "encoder.int8.onnx").path,
                    decoder = File(dir, "decoder.int8.onnx").path,
                    joiner = File(dir, "joiner.int8.onnx").path,
                ),
                tokens = File(dir, "tokens.txt").path,
                numThreads = 4,
                modelType = "nemo_transducer",
            ),
            decodingMethod = "greedy_search",
        )
        return OfflineRecognizer(assetManager = null, config = config).also {
            recognizer = it
            ready = true
            Log.i("WingVad", "model loaded in ${SystemClock.elapsedRealtime() - started} ms")
        }
    }

    fun transcribe(samples: FloatArray, done: (Result<String>, Long, Boolean) -> Unit) {
        val readyAtStart = ready
        executor.execute {
            val started = SystemClock.elapsedRealtime()
            val result = runCatching {
                val model = load()
                val stream = model.createStream()
                try {
                    stream.acceptWaveform(samples, 16000)
                    model.decode(stream)
                    model.getResult(stream).text.trim()
                } finally { stream.release() }
            }
            done(result, SystemClock.elapsedRealtime() - started, readyAtStart)
        }
    }

    fun release() { executor.execute { recognizer?.release(); recognizer = null; ready = false } }

    fun close() { release(); executor.shutdown() }
}
```

`ANNAHME:` the constructor parameter names match v1.13.8 (`assetManager`, `config`; data-class fields as in spec
2.2). Check: Step 4 compile. If a named argument fails to compile, use the name the compiler error reports and note it.

- [ ] **Step 3: Channel methods for the model**

In `VoiceChannel.kt` add fields after `playback`:

```kotlin
    private val models = SpeechModelStore(activity, ::emit)
    private val speech = OfflineSpeech(models)
```

and `when` branches before `else -> result.notImplemented()`:

```kotlin
                "vadModelStatus" -> result.success(models.status())
                "installVadModel" -> { models.install(); result.success(null) }
                "cancelVadModelInstall" -> { models.cancel(); result.success(null) }
                "removeVadModel" -> { speech.release(); models.remove(); result.success(null) }
                "prepareVad" -> { if (models.verifyManifest() == null) speech.prepare(); result.success(null) }
                "releaseVad" -> { speech.release(); result.success(null) }
```

In `close()` add `speech.close(); models.close()`.

- [ ] **Step 4: Compile**

Run: `git add android/app/src/main/kotlin/com/tarkilhk/wing/SpeechModelStore.kt android/app/src/main/kotlin/com/tarkilhk/wing/OfflineSpeech.kt android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt`
Run: `git commit -m "feat(voice): on-phone speech model install and Parakeet recognizer"`
Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: exit 0, `conclusion=success`.

---

### Task 13: Kotlin: vad capture, cues, debug store

**Files:**
- Create: `android/app/src/main/kotlin/com/tarkilhk/wing/VadCapture.kt`
- Create: `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceDebugStore.kt`
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt`

**Interfaces:**
- Consumes: `OfflineSpeech`, `SpeechModelStore` (Task 12); asset `silero_vad.onnx` (Task 9); channel contract (spec 5).
- Produces: channel methods `startVad`, `finishVad`, `deleteVadDebugRecordings`; `cancel` also cancels vad rounds; events `{id, first, windows}`, `{id, error}`.
- Recording uses whatever input Android routes. There is **no own audio routing** (gestrichen, Birk 13.10.): never call
  `startBluetoothSco`, `setCommunicationDevice` or `setSpeakerphone`. The routed device is only *read*
  (`AudioRecord.getRoutedDevice()`, API 24) for the debug JSON field `inputDevice`.

- [ ] **Step 1: Debug store**

`android/app/src/main/kotlin/com/tarkilhk/wing/VoiceDebugStore.kt`:

```kotlin
package com.tarkilhk.wing

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/** Debug recordings of vad rounds (opt-in): 16 kHz mono PCM16 WAV + JSON timing.
 *  Private app storage only; the newest [KEEP] rounds are kept; never uploaded. */
class VoiceDebugStore(context: Context) {
    companion object { const val KEEP = 30 }
    private val dir = File(context.filesDir, "voice-debug")
    private val executor = Executors.newSingleThreadExecutor()

    fun write(roundId: String, startedAt: Long, pcm: ShortArray, length: Int, meta: JSONObject) {
        executor.execute {
            dir.mkdirs()
            val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date(startedAt))
            val base = "$stamp-${roundId.take(8)}"
            writeWav(File(dir, "$base.wav"), pcm, length)
            File(dir, "$base.json").writeText(meta.toString())
            prune()
        }
    }

    fun deleteAll(): Int {
        val rounds = dir.listFiles { file -> file.name.endsWith(".json") }?.size ?: 0
        dir.listFiles()?.forEach { it.delete() }
        return rounds
    }

    private fun prune() {
        val rounds = dir.listFiles { file -> file.name.endsWith(".json") }?.sortedBy { it.name } ?: return
        rounds.dropLast(KEEP).forEach { json ->
            json.delete(); File(dir, json.name.removeSuffix(".json") + ".wav").delete()
        }
    }

    private fun writeWav(file: File, pcm: ShortArray, length: Int) {
        RandomAccessFile(file, "rw").use { out ->
            out.setLength(0)
            val dataBytes = length * 2
            fun le32(v: Int) { out.write(v and 0xff); out.write(v shr 8 and 0xff); out.write(v shr 16 and 0xff); out.write(v shr 24 and 0xff) }
            fun le16(v: Int) { out.write(v and 0xff); out.write(v shr 8 and 0xff) }
            out.writeBytes("RIFF"); le32(36 + dataBytes); out.writeBytes("WAVE")
            out.writeBytes("fmt "); le32(16); le16(1); le16(1); le32(16000); le32(32000); le16(2); le16(16)
            out.writeBytes("data"); le32(dataBytes)
            val bytes = ByteArray(dataBytes)
            for (i in 0 until length) { bytes[2 * i] = (pcm[i].toInt() and 0xff).toByte(); bytes[2 * i + 1] = (pcm[i].toInt() shr 8).toByte() }
            out.write(bytes)
        }
    }

    fun close() { executor.shutdown() }
}
```

- [ ] **Step 2: Capture**

`android/app/src/main/kotlin/com/tarkilhk/wing/VadCapture.kt`:

```kotlin
package com.tarkilhk.wing

import android.app.Activity
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import com.k2fsa.sherpa.onnx.SileroVadModelConfig
import com.k2fsa.sherpa.onnx.Vad
import com.k2fsa.sherpa.onnx.VadModelConfig
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import kotlin.concurrent.thread

/** Route vad: 16 kHz mono capture, one Silero probability per 32 ms window
 *  (sent to Dart in batches of 4), cut + on-phone recognition on request.
 *  The end-of-utterance decision lives in Dart (vad_endpoint.dart).
 *  Records from whatever input Android routes; never changes audio routing. */
class VadCapture(
    private val activity: Activity,
    private val models: SpeechModelStore,
    private val speech: OfflineSpeech,
    private val debug: VoiceDebugStore,
    private val emit: (Map<String, Any>) -> Unit,
) {
    data class Options(val cues: Boolean, val debug: Boolean, val source: String, val maxMs: Int)

    private class Round(val id: String, val options: Options, val startedAt: Long, capacity: Int) {
        val pcm = ShortArray(capacity)
        @Volatile var length = 0
        val probabilities = ArrayList<Float>()
        @Volatile var stopped = false
        var computeErrors = 0
        var record: AudioRecord? = null
        var reader: Thread? = null
        var vad: Vad? = null
        var sourceName = ""
        var inputDevice = "unknown"
    }

    private val handler = Handler(Looper.getMainLooper())
    private var round: Round? = null

    fun start(id: String, options: Options) {
        cancelCurrent()
        models.verifyManifest()?.let { error(it) }
        val r = Round(id, options, System.currentTimeMillis(), (options.maxMs + 5_000) * 16)
        round = r
        try {
            if (options.cues) cue(ToneGenerator.TONE_PROP_BEEP, wait = true)
            r.vad = Vad(
                assetManager = activity.assets,
                config = VadModelConfig(
                    sileroVadModelConfig = SileroVadModelConfig(model = "silero_vad.onnx", windowSize = 512),
                    sampleRate = 16000,
                    numThreads = 1,
                ),
            )
            r.record = openRecord(r)
            r.record!!.startRecording()
            // Read-only diagnosis: which input Android routed this recording to.
            r.inputDevice = r.record!!.routedDevice?.let { "${it.productName} (type ${it.type})" } ?: "unknown"
            r.reader = thread(name = "WingVad") { read(r) }
        } catch (error: Exception) { release(r); round = null; throw error }
    }

    /** [wait] keeps the "listening" cue out of the recording (≈250 ms before capture starts). */
    private fun cue(tone: Int, wait: Boolean) {
        try {
            val generator = ToneGenerator(AudioManager.STREAM_MUSIC, 70)
            generator.startTone(tone, 150)
            handler.postDelayed({ generator.release() }, 400)
            if (wait) Thread.sleep(250)
        } catch (_: Exception) {}
    }

    // VoiceChannel only calls start() after RECORD_AUDIO was granted.
    @android.annotation.SuppressLint("MissingPermission")
    private fun openRecord(r: Round): AudioRecord {
        val minimum = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val sources = if (r.options.source == "recognition") listOf(MediaRecorder.AudioSource.VOICE_RECOGNITION)
            else listOf(MediaRecorder.AudioSource.VOICE_COMMUNICATION, MediaRecorder.AudioSource.VOICE_RECOGNITION)
        for (source in sources) {
            val record = AudioRecord(source, 16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(minimum, 16000))
            if (record.state == AudioRecord.STATE_INITIALIZED) {
                r.sourceName = if (source == MediaRecorder.AudioSource.VOICE_COMMUNICATION) "VOICE_COMMUNICATION" else "VOICE_RECOGNITION"
                return record
            }
            record.release()
        }
        error("Microphone is unavailable.")
    }

    private fun read(r: Round) {
        val frame = ShortArray(512)
        val window = FloatArray(576) // 64 context + 512 new samples (silero v5)
        val batch = ArrayList<Double>(4)
        var first = 0
        val record = r.record ?: return
        val vad = r.vad ?: return
        while (!r.stopped) {
            var filled = 0
            while (filled < 512 && !r.stopped) {
                val n = record.read(frame, filled, 512 - filled)
                if (n < 0) {
                    handler.post { if (round === r) fail(r, "Microphone recording failed. Please retry.") }
                    return
                }
                filled += n
            }
            if (r.stopped) break
            if (r.length + 512 > r.pcm.size) {
                handler.post { if (round === r) fail(r, "Recording reached its time limit. Please try a shorter recording.") }
                return
            }
            System.arraycopy(frame, 0, r.pcm, r.length, 512)
            r.length += 512
            System.arraycopy(window, 512, window, 0, 64)
            for (k in 0 until 512) window[64 + k] = frame[k] / 32768f
            val raw = vad.compute(window)
            val p = if (raw < 0f) { r.computeErrors++; 0f } else raw
            synchronized(r.probabilities) { r.probabilities.add(p) }
            batch.add(p.toDouble())
            if (batch.size == 4) {
                val send = ArrayList(batch); val at = first
                first += batch.size; batch.clear()
                handler.post { if (round === r) emit(mapOf("id" to r.id, "first" to at, "windows" to send)) }
            }
        }
    }

    fun finish(id: String, startWindow: Int, endWindow: Int, atWindow: Int, reason: String,
               config: Map<String, Any?>, response: MethodChannel.Result) {
        val r = round?.takeIf { it.id == id } ?: run { response.error("cancelled", "Recording cancelled.", null); return }
        stopReading(r)
        if (reason == "noSpeech") {
            // Nothing was said: no cue, no recognition; keep the timing for diagnosis.
            if (r.options.debug) writeDebug(r, JSONObject().put("reason", reason).put("atWindow", atWindow), config, JSONObject())
            round = null
            response.success("")
            return
        }
        if (r.options.cues) cue(ToneGenerator.TONE_PROP_ACK, wait = false)
        val start = (startWindow * 512).coerceIn(0, r.length)
        val end = (endWindow * 512).coerceIn(start, r.length)
        val samples = FloatArray(end - start) { r.pcm[start + it] / 32768f }
        speech.transcribe(samples) { result, decodeMs, readyAtStart ->
            handler.post {
                if (r.options.debug) writeDebug(r, JSONObject().put("reason", reason).put("startWindow", startWindow)
                    .put("endWindow", endWindow).put("atWindow", atWindow), config, JSONObject()
                    .put("segmentMs", (end - start) / 16).put("decodeMs", decodeMs).put("modelReadyAtFinish", readyAtStart)
                    .put("textLength", result.getOrNull()?.length ?: 0).put("error", result.exceptionOrNull()?.message ?: JSONObject.NULL))
                val current = round === r
                if (current) round = null
                result.fold(
                    onSuccess = { text -> if (current) response.success(text) else response.error("cancelled", "Recording cancelled.", null) },
                    onFailure = { failure -> response.error("voice_unavailable", "Speech model could not be loaded (${failure.message}).", null) },
                )
            }
        }
    }

    private fun stopReading(r: Round) {
        r.stopped = true
        try { r.record?.stop() } catch (_: Exception) {}
        r.reader?.join(500)
        release(r)
    }

    private fun release(r: Round) {
        r.record?.release(); r.record = null
        r.vad?.release(); r.vad = null
    }

    private fun writeDebug(r: Round, decision: JSONObject, config: Map<String, Any?>, recognition: JSONObject) {
        val probabilities = synchronized(r.probabilities) { JSONArray(r.probabilities.map { Math.round(it * 1000) / 1000.0 }) }
        debug.write(r.id, r.startedAt, r.pcm, r.length, JSONObject()
            .put("version", 1).put("roundId", r.id).put("startedAt", Instant.ofEpochMilli(r.startedAt).toString())
            .put("sampleRate", 16000).put("windowSamples", 512).put("windowMs", 32)
            .put("source", r.sourceName).put("inputDevice", r.inputDevice)
            .put("config", JSONObject(config)).put("probabilities", probabilities)
            .put("computeErrors", r.computeErrors).put("decision", decision).put("recognition", recognition))
    }

    private fun fail(r: Round, message: String) {
        stopReading(r)
        if (r.options.debug) writeDebug(r, JSONObject().put("reason", "error").put("error", message), emptyMap(), JSONObject())
        round = null
        emit(mapOf("id" to r.id, "error" to message))
    }

    fun cancel(id: String) { round?.takeIf { it.id == id }?.let { cancelRound(it) } }

    private fun cancelRound(r: Round) {
        stopReading(r)
        if (r.options.debug) writeDebug(r, JSONObject().put("reason", "cancelled"), emptyMap(), JSONObject())
        round = null
    }

    private fun cancelCurrent() { round?.let { cancelRound(it) } }

    fun pause() { round?.let { r -> fail(r, "Recording stopped because Wing left the foreground.") } }

    fun close() { cancelCurrent() }
}
```

`Instant` requires API 26 and minSdk is 24. Core library desugaring is enabled (`isCoreLibraryDesugaringEnabled = true`),
which covers `java.time`. `ANNAHME:` checked by the compile and by Task 15.

- [ ] **Step 3: Channel wiring**

In `VoiceChannel.kt`:

```kotlin
    private val debugStore = VoiceDebugStore(activity)
    private val vad = VadCapture(activity, models, speech, debugStore, ::emit)
```

`when` branches:

```kotlin
                "startVad" -> {
                    check(id.isNotEmpty()) { "Missing capture ID." }
                    if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                        check(pending == null) { "Wait for microphone permission." }
                        pending = call to result
                        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST)
                    } else start(call, result)
                }
                "finishVad" -> vad.finish(id, call.argument<Int>("startWindow") ?: 0, call.argument<Int>("endWindow") ?: 0,
                    call.argument<Int>("atWindow") ?: 0, call.argument<String>("reason").orEmpty(),
                    call.argument<Map<String, Any?>>("config") ?: emptyMap(), result)
                "deleteVadDebugRecordings" -> result.success(debugStore.deleteAll())
```

Change `"cancel"` to also call `vad.cancel(id)` before `capture.cancel(id)`.

Change `private fun start(call, result)` to branch on the method name (`VoiceCapture.start` itself stays untouched):

```kotlin
    private fun start(call: MethodCall, result: MethodChannel.Result) {
        playback.stop()
        val id = call.argument<String>("id")!!
        if (call.method == "startVad") {
            capture.cancel(id)
            vad.start(id, VadCapture.Options(
                cues = call.argument<Boolean>("cues") != false,
                debug = call.argument<Boolean>("debug") == true,
                source = call.argument<String>("source") ?: "communication",
                maxMs = call.argument<Int>("maxMs") ?: 120_000,
            ))
        } else {
            vad.cancel(id)
            capture.start(id, call.argument<Boolean>("local") == true, call.argument<String>("language").orEmpty())
        }
        result.success(null)
    }
```

`pause()` becomes `fun pause() { capture.pause(); vad.pause(); playback.stop() }`. In `close()` add `vad.close(); debugStore.close()` before `speech.close()`.

- [ ] **Step 4: Compile**

Run: `git add android/app/src/main/kotlin/com/tarkilhk/wing/VadCapture.kt android/app/src/main/kotlin/com/tarkilhk/wing/VoiceDebugStore.kt android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt`
Run: `git commit -m "feat(voice): vad capture with Silero probabilities, cues and debug recordings"`
Run: `grep -rnE "BluetoothSco|setCommunicationDevice|setSpeakerphone|TYPE_BLUETOOTH_SCO" android/app/src/main/kotlin`
Expected: no output and exit code 1 (no own audio routing, Birk 13.10.).
Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: exit 0, `conclusion=success`.

---

### Task 14: Kotlin: media keys and keep-screen-on; docs and renders

**Files:**
- Create: `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceMediaKeys.kt`
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt`
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/MainActivity.kt:294-309`
- Create: `.github/workflows/voice-review.yml`
- Create: `tools/voice/pull_debug_round.py`
- Modify: `docs/VOICE.md`, `docs/TESTING.md`, `docs/VAD_INPUT.md`

**Interfaces:**
- Consumes: channel methods `setMediaKeys`, `keepScreenOn` (Task 7).
- Produces: event `{mediaKey: "playPause"}`; `VoiceChannel.resume()`; `python3 -I tools/voice/pull_debug_round.py --list | --round <base> --out <dir>`.

- [ ] **Step 1: Media keys**

`android/app/src/main/kotlin/com/tarkilhk/wing/VoiceMediaKeys.kt`:

```kotlin
package com.tarkilhk.wing

import android.app.Activity
import android.content.Intent
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.view.KeyEvent

/** Steering-wheel / headset play-pause as a talk button on the vad route.
 *  Active only while Dart enabled it and the activity is resumed. */
class VoiceMediaKeys(activity: Activity, private val emit: (Map<String, Any>) -> Unit) {
    private val keys = setOf(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_PLAY,
        KeyEvent.KEYCODE_MEDIA_PAUSE, KeyEvent.KEYCODE_HEADSETHOOK)
    private var enabled = false
    private var resumed = true
    private val session = MediaSession(activity, "WingVoice").apply {
        setCallback(object : MediaSession.Callback() {
            override fun onMediaButtonEvent(intent: Intent): Boolean {
                val key = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
                    else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
                if (key == null || key.keyCode !in keys) return super.onMediaButtonEvent(intent)
                if (key.action == KeyEvent.ACTION_DOWN && key.repeatCount == 0) emit(mapOf("mediaKey" to "playPause"))
                return true
            }
        })
        setPlaybackState(PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE)
            .setState(PlaybackState.STATE_PAUSED, 0, 1f).build())
    }

    fun enable(on: Boolean) { enabled = on; sync() }
    fun resume() { resumed = true; sync() }
    fun pause() { resumed = false; sync() }
    private fun sync() { session.isActive = enabled && resumed }
    fun close() { session.isActive = false; session.release() }
}
```

`ANNAHME:` a session that is active with `STATE_PAUSED` becomes the media-button session. Check in Task 15 Step 8.
Fallback: in `enable(true)` set `STATE_PLAYING` instead of `STATE_PAUSED`, and record it.

- [ ] **Step 2: Channel and activity wiring**

`VoiceChannel.kt`: field `private val mediaKeys = VoiceMediaKeys(activity, ::emit)`; branches:

```kotlin
                "setMediaKeys" -> { mediaKeys.enable(call.argument<Boolean>("on") == true); result.success(null) }
                "keepScreenOn" -> {
                    if (call.argument<Boolean>("on") == true) activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    result.success(null)
                }
```

(import `android.view.WindowManager`). `pause()` also calls `mediaKeys.pause()`. Add `fun resume() { mediaKeys.resume() }`.
`close()` also calls `mediaKeys.close()` and clears the `FLAG_KEEP_SCREEN_ON` flag.

`MainActivity.onResume()`: after `activityResumed = true` add `voiceChannel?.resume()`.

- [ ] **Step 3: Debug retrieval helper**

`tools/voice/pull_debug_round.py`:

```python
#!/usr/bin/env python3
"""Fetches one debug round (WAV + JSON) of Wing Voice from the phone via hadb (root).

hadb push/pull fail above ~100 kB over Tailscale, so the file is copied to /data/local/tmp,
read as base64 in 48 kB chunks and checked against the phone's sha256. The data is private:
use an --out directory under build/ (git-ignored) and delete it after analysis.
Usage: python3 -I tools/voice/pull_debug_round.py --list
       python3 -I tools/voice/pull_debug_round.py --round 20261014-101500-abcd1234 --out build/voice-debug
"""
import argparse
import base64
import hashlib
import pathlib
import subprocess

HADB = str(pathlib.Path.home() / ".local/bin/hadb")
SRC = "/data/data/com.tarkilhk.wing.voice/files/voice-debug"
TMP = "/data/local/tmp/wingvad"
CHUNK = 49152


def shell(command):
    return subprocess.run([HADB, "shell", command], check=True, capture_output=True).stdout


def pull(name, out):
    shell(f"mkdir -p {TMP}")
    shell(f'su -c "cp {SRC}/{name} {TMP}/{name}"')
    shell(f'su -c "chmod 644 {TMP}/{name}"')
    size = int(shell(f"stat -c %s {TMP}/{name}").strip())
    expected = shell(f"sha256sum {TMP}/{name}").split()[0].decode()
    data = bytearray()
    for index in range((size + CHUNK - 1) // CHUNK):
        chunk = shell(f"dd if={TMP}/{name} bs={CHUNK} skip={index} count=1 2>/dev/null | base64")
        data += base64.b64decode(b"".join(chunk.split()))
    shell(f"rm -f {TMP}/{name}")
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        raise SystemExit(f"{name}: sha256 mismatch")
    (out / name).write_bytes(bytes(data))
    print(f"{name} {size} bytes sha256 ok")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--round")
    parser.add_argument("--out", default="build/voice-debug")
    args = parser.parse_args()
    if args.list:
        print(shell(f'su -c "ls -l {SRC}"').decode())
        return
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for suffix in (".json", ".wav"):
        pull(args.round + suffix, out)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Render workflow**

`.github/workflows/voice-review.yml`:

```yaml
name: Wing Voice review renders

# Renders voice settings/composer screens (synthetic fixtures only) and pushes
# the PNGs to branch voice-review-bin (git transport; artifact storage is
# blocked for the vServer).
on:
  workflow_dispatch:

permissions:
  contents: write

jobs:
  render:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 1
          persist-credentials: false
      - name: Set up Flutter
        uses: ./.github/actions/setup-flutter
        with:
          flutter-version: '3.44.0'
          channel: 'stable'
          cache: true
      - run: flutter pub get
      - name: Render
        run: |
          fonts="$(dirname "$(dirname "$(command -v flutter)")")/bin/cache/artifacts/material_fonts"
          flutter test --no-pub --dart-define=VOICE_REVIEW=true --dart-define=CAPTURE_FONT_DIR="$fonts" \
            test/voice_preferences_test.dart test/vad_settings_test.dart test/voice_workspace_test.dart
      - name: Publish to voice-review-bin
        env:
          TOKEN: ${{ github.token }}
        run: |
          mkdir -p /tmp/out
          cp build/voice-review/*.png /tmp/out/
          echo "${GITHUB_SHA}" > /tmp/out/SOURCE_COMMIT
          cd /tmp/out
          git init -q -b voice-review-bin
          git config user.name "ci"; git config user.email "ci@localhost"
          git add -A && git commit -q -m "voice review ${GITHUB_SHA}"
          git push -f "https://x-access-token:${TOKEN}@github.com/${GITHUB_REPOSITORY}.git" voice-review-bin
```

- [ ] **Step 5: Docs**

`docs/VOICE.md`, under "Choose where speech is processed", add a paragraph:

```markdown
**On this phone · Parakeet** records with Wing's own capture from the input Android currently routes (normally the
phone's built-in microphone), detects the end of each message with Silero VAD and recognizes the speech on the phone
with Parakeet TDT 0.6B v3 (sherpa-onnx). No audio leaves the phone. The speech model (487 MB download, about 670 MB
installed) is downloaded once in App settings → Voice and checked against its published SHA256. "Pause detection"
sets how long a pause ends a message (default 1.8 s), how long Wing waits for you to start speaking (default 8 s),
the minimum speech, the lead-in kept before speech and the longest recording. On this route the steering-wheel or
headset play/pause key ends the current message or starts a new one, and short cue tones mark "listening" and
"got it". During Conversation mode the screen stays on.
```

`docs/TESTING.md`, at the end of "Voice acceptance", add:

```markdown
The vad route's end-of-utterance logic is pure Dart (`test/vad_endpoint_test.dart`) and mirrored in Python
(`scripts/tests/test_vad_endpoint_parity.py`, same golden cases). Offline tuning against recordings runs with
`tools/voice/vad_offline_check.py` (see `docs/VAD_INPUT.md`); recordings stay outside the repository. Renders:
`bash tools/factory/dispatch-check.sh voice-review.yml`, then clone branch `voice-review-bin` into `build/`.
```

`docs/VAD_INPUT.md`: add sections "Debug recordings" (location, JSON fields per spec 10, `pull_debug_round.py`
usage, privacy rule) and "Tuning" (offline-check commands from Task 5).

- [ ] **Step 6: Compile, render and inspect**

Run: `chmod +x tools/voice/pull_debug_round.py`
Run: `git add android/app/src/main/kotlin/com/tarkilhk/wing/VoiceMediaKeys.kt android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt android/app/src/main/kotlin/com/tarkilhk/wing/MainActivity.kt .github/workflows/voice-review.yml tools/voice/pull_debug_round.py docs/VOICE.md docs/TESTING.md docs/VAD_INPUT.md`
Run: `git commit -m "feat(voice): media key talk button, keep screen on, vad docs and renders"`
Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: exit 0.
Run: `bash tools/factory/ci-suite.sh`
Expected: exit 0.
Run: `bash tools/factory/dispatch-check.sh voice-review.yml`
Expected: exit 0.
Run: `rm -rf build/voice-review-bin`
Run: `git clone -q --depth 1 -b voice-review-bin https://github.com/birkschmithuesen/Wing.git build/voice-review-bin`
Run: `ls build/voice-review-bin`
Expected: `vad-model-absent-light-100.png`, `vad-model-downloading-light-100.png`, `vad-model-failed-light-100.png`,
`vad-pause-detection-open-light-100.png`, `vad-settings-light-200.png`, `vad-settings-dark-200.png`,
`vad-settings-open-light-200.png`, `vad-settings-open-dark-200.png`, `vad-recording-light-100.png`, plus the existing
voice renders.

Open each PNG with the Read tool and check against `docs/DESIGN_SYSTEM.md`:
- The model row is subordinate to the route select.
- Exactly one primary action per model state.
- No clipped text at 200 %.
- The switch rows use the shared trailing column.
- Dark mode contrast is fine.
- No permanent success text.

Fix what looks wrong, commit, and render again. Record the review in `docs/VAD_INPUT.md` ("Render review <date>:
<findings / none>").

---

### Task 15: On-device verification (last; Birk approved access)

**Files:**
- Modify: `docs/VAD_INPUT.md` (results only, numbers, no private content)

**Interfaces:** none.

Preconditions: read the handover doc section "Zugriff aufs Handy". The phone has a screen lock: never bypass it. If
`hadb shell 'dumpsys window | grep isKeyguardShowing'` shows `true`, post a notification asking Birk to unlock
(`hadb shell "cmd notification post -S bigtext -t 'Wing Voice Test' wingvad 'Bitte entsperren für den Wing-Voice-Selbsttest'"`),
then poll until it reads `false`. **No conversation mode during the self-test**, so nothing is sent to Hermes.

- [ ] **Step 1: Build for the phone and sign**

Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=true`
Expected: exit 0. Branch `voice-apk-bin` now carries `SOURCE_COMMIT` = HEAD.
Run: `bash /home/birk/hermes-shared/hermes-entities/tools/technik/wing-voice-build.sh`
Expected: `source commit: <HEAD sha>`. The printed signer SHA-256 matches the installed one (`cae14a2c…`), and the script prints the APK path `~/handy-builds/wing-voice/wing-voice-<sha7>.apk` and its sha256.

- [ ] **Step 2: Record the current state and install as an update**

Run: `hadb shell 'dumpsys package com.tarkilhk.wing.voice | grep -E "versionName|lastUpdateTime"'`
Run: `hadb install /home/birk/handy-builds/wing-voice/wing-voice-latest.apk`
Expected: `Success`. `hadb install` uses push, which fails above ~100 kB over Tailscale. If it times out, use the tailnet
HTTP route from the handover instead:
1. `tailscale ip -4` gives the vServer IP.
2. Start `python3 -m http.server 8765 --bind <ip> --directory /home/birk/handy-builds/wing-voice` as a background command (stop it afterwards).
3. `hadb shell 'curl -s -o /data/local/tmp/wv.apk http://<ip>:8765/wing-voice-latest.apk'`, run in the foreground, not via nohup.
4. `hadb shell 'sha256sum /data/local/tmp/wv.apk'` must equal the build script's hash.
5. `hadb shell 'pm install -r /data/local/tmp/wv.apk'` gives `Success`.
6. `hadb shell 'rm /data/local/tmp/wv.apk'`.

Run: `hadb shell 'dumpsys package com.tarkilhk.wing.voice | grep -E "versionName|lastUpdateTime"'`
Expected: a newer `lastUpdateTime`. App data is kept, so saved connections are still there.

- [ ] **Step 3: Note settings to restore, switch to vad, download the model in the app**

Open Wing Voice (`hadb shell 'am start -n com.tarkilhk.wing.voice/com.tarkilhk.wing.MainActivity'`) and navigate to
App settings → Voice. Use `hadb shell 'uiautomator dump /sdcard/ui.xml'` and `hadb shell 'cat /sdcard/ui.xml'` to find
the `bounds` of texts, then `hadb shell 'input tap <x> <y>'`. Write down the current "Voice input", "Conversation
mode" and debug values for Step 10. Select "On this phone · Parakeet" and tap "Download". The phone downloads
487 MB from GitHub over its own connection.
Run every ~60 s: `hadb shell 'su -c "ls -l /data/data/com.tarkilhk.wing.voice/files/models/download /data/data/com.tarkilhk.wing.voice/files/models"'`
Expected: the `.part` file grows. Then `parakeet-tdt-0.6b-v3-int8/` appears with `encoder.int8.onnx` (≈652 MB),
`decoder.int8.onnx`, `joiner.int8.onnx`, `tokens.txt` and `manifest.json`, and the download directory is empty. The UI
shows "Speech model ready".
Run: `hadb shell 'su -c "cat /data/data/com.tarkilhk.wing.voice/files/models/parakeet-tdt-0.6b-v3-int8/manifest.json"'`
Expected: `archiveSha256` = `5793d0fd…16bf`, four file entries with sizes.

- [ ] **Step 4: Preload and memory**

Run: `hadb shell 'am force-stop com.tarkilhk.wing.voice'`
Run: `hadb shell 'logcat -c'`
Run: `hadb shell 'am start -n com.tarkilhk.wing.voice/com.tarkilhk.wing.MainActivity'`
Wait 15 s, then run: `hadb shell 'logcat -d -s WingVad'`
Expected: `model loaded in <ms> ms` with roughly 2500–6000 ms (measured CLI load: 3146 ms).
Run: `hadb shell 'dumpsys meminfo com.tarkilhk.wing.voice | grep -E "TOTAL PSS|TOTAL RSS"'`
Expected: TOTAL PSS < 1.3 GB. Record both numbers.

- [ ] **Step 5: Resume check (ANNAHME download range)**

Only if the model is not installed yet, or after **Remove** (costs another download; skip if the earlier download
already showed progress continuing after a network change). Start the download, toggle airplane mode on after
≥ 50 MB (`hadb shell 'cmd connectivity airplane-mode enable'`), wait for "failed", disable it, tap Retry.
Expected: the bytes continue from the previous value. Record the outcome.

- [ ] **Step 6: Self-test audio onto the phone**

Run: `build/vad-venv/bin/python -I tools/voice/make_selftest_audio.py --speech /mnt/HC_Volume_106183673/hermes/profiles/worker/cache/scratch/wingvoice/tts/s1.wav --speech /mnt/HC_Volume_106183673/hermes/profiles/worker/cache/scratch/wingvoice/tts/s2.wav --noise /mnt/HC_Volume_106183673/hermes/profiles/worker/cache/scratch/wingvoice/tts/noise_60s.wav --lead-s 8 --out build/vad-check/selftest.wav --labels-out build/vad-check/selftest.labels.json`
Transfer it (≈ 600 kB) via the tailnet HTTP server from Step 2 (serve `build/vad-check`), then
`hadb shell 'curl -s -o /sdcard/Music/wingvad-selftest.wav http://<ip>:8765/selftest.wav'`.
Run: `hadb shell 'sha256sum /sdcard/Music/wingvad-selftest.wav'`
Expected: equals `sha256sum build/vad-check/selftest.wav`.
Run: `hadb shell 'cmd package install-existing org.lineageos.twelve'`

- [ ] **Step 7: Self-test rounds, audio source A/B (phone speaker → built-in phone mic)**

The round records from whatever Android routes; with no headset or car connected that is the built-in mic. That is
the mic that matters (Birk's finding, spec 1.1). Run the round below **twice with the same file**: first with Audio
source "Call processing" (`VOICE_COMMUNICATION`, the default), then with "Recognition" (`VOICE_RECOGNITION`). Keep
both rounds' JSON for the comparison before deleting anything.

In Wing Voice: route vad, **Debug recordings on**, Audio source as above, "Wait for speech" **12 s** (the 8 s noise lead
plus the time to switch apps must fit inside it), Conversation mode **off**, cue tones on, an empty draft in a chat.
Then:
1. Start playback: `hadb shell 'am start -a android.intent.action.VIEW -t audio/wav -d file:///sdcard/Music/wingvad-selftest.wav org.lineageos.twelve'` (8 s noise lead).
2. Immediately bring Wing to the front: `hadb shell 'am start -n com.tarkilhk.wing.voice/com.tarkilhk.wing.MainActivity'`.
3. Tap "Dictate message" (find its bounds by `content-desc` in the uiautomator dump).

Wait 25 s, without tapping Stop.
Run: `python3 -I tools/voice/pull_debug_round.py --list`
Expected: one new `*.json`/`*.wav` pair.
Run: `python3 -I tools/voice/pull_debug_round.py --round <newest base name> --out build/voice-debug`
Expected: `… sha256 ok` twice.
Run: `python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); p=d['probabilities']; print(d['decision'], d['recognition'], d['source'], d['inputDevice'], len(p), max(p))" build/voice-debug/<base>.json`
Expected (the proof that the round ended by itself):
- `decision.reason == 'pause'`.
- `recognition.error is None` and `textLength > 0`.
- `endWindow` < the number of probabilities, and `atWindow − endWindow` = 48 (at = lastSpeech + 57, end = lastSpeech + 1 + 8).
- `inputDevice` names the built-in mic (e.g. `… (type 15)`, `TYPE_BUILTIN_MIC`).
- The two sentences are in one round: the uiautomator dump of the composer shows the words of both `s1.txt` and `s2.txt` (synthetic test sentences, allowed to read).

Clear the draft (select all + delete via uiautomator), switch Audio source to "Recognition", and repeat.

**A/B comparison** (numbers only, into `docs/VAD_INPUT.md`): for both rounds, `source`, `inputDevice`,
`decision` (start/end/at windows), max p, the median p over the noise-lead windows (first ≈ 200 windows), and the first
window with p ≥ 0.5. Align the two rounds on the labeled speech start (`build/vad-check/selftest.labels.json`, 8.0 s
into the file) using that first speech window. Better means a higher speech p, a lower noise p, and an end
decision closer to label end + 1.8 s.
`ANNAHME` echo cancellation: if "Call processing" shows `max(p) < 0.5`, the platform AEC probably removed the phone's
own playback. Record that as the reason the A/B is inconclusive for `VOICE_COMMUNICATION`, not as evidence against it
(spec 1.2). **Do not change the default source** here: the decision is Birk's, after his test drive with the
alternating source.
Then clear the draft, and delete the self-test rounds with "Delete debug recordings".
Run: `rm -r build/voice-debug`

- [ ] **Step 7b: No-speech timeout on the device**

"Wait for speech" back to **8 s**, debug on, no playback. Tap "Dictate message" and stay silent (the room may
not be perfectly quiet; that is fine).
Expected: after ≈ 8 s (not 7 s, not 120 s) the round ends with "No speech detected. Try again.", without the "got
it" cue and without "Transcribing…".
Run: `python3 -I tools/voice/pull_debug_round.py --list`, then pull the newest round as in Step 7 and print `decision`.
Expected: `decision.reason == 'noSpeech'`, `atWindow == 249`, no `recognition` timings. If someone spoke in the room
and a round with speech started instead, repeat. Delete the round afterwards ("Delete debug recordings",
`rm -r build/voice-debug`).

- [ ] **Step 8: Media key**

With route vad and an empty draft on the chat screen:
Run: `hadb shell 'cmd media_session dispatch play-pause'`
Expected: Wing shows "Recording · …" (a round started) and you hear the cue.
Run: `hadb shell 'dumpsys media_session | grep -i -A3 "media button session"'`
Expected: names `com.tarkilhk.wing.voice`.
Run: `hadb shell 'cmd media_session dispatch play-pause'`
Expected: the round ends (status "Transcribing…" then idle). With debug on, the newest JSON has `decision.reason == 'mediaKey'`.
If the first dispatch does not reach Wing, apply the Task 14 Step 1 fallback (`STATE_PLAYING`), rebuild (Steps 1–2)
and repeat. Record the outcome.

- [ ] **Step 9: Keep screen on**

Turn Conversation mode on, tap "Dictate message", then immediately run:
`hadb shell 'dumpsys window windows | grep -E "com.tarkilhk.wing.voice|KEEP_SCREEN_ON"'`
Expected: the Wing window's flags include `KEEP_SCREEN_ON`. Tap "Cancel recording" (nothing is sent: no speech
was given). Run the same command again.
Expected: no `KEEP_SCREEN_ON` for Wing. Turn Conversation mode back to its Step 3 value.

- [ ] **Step 10: Restore and clean up**

Restore the Step 3 values (input route, conversation mode, debug off).
**Leave the model installed**: it is Birk's next step to test-drive.
Run: `hadb shell 'rm /sdcard/Music/wingvad-selftest.wav /sdcard/ui.xml'`
Run: `hadb shell 'pm uninstall --user 0 org.lineageos.twelve'`
Stop the HTTP server.
Run: `hadb shell 'su -c "ls /data/data/com.tarkilhk.wing.voice/files/voice-debug"'`
Expected: empty or missing.

- [ ] **Step 11: Record and commit**

Add a section "On-device verification <date>" to `docs/VAD_INPUT.md`. It records numbers and outcomes only: APK
commit, model load ms, PSS/RSS, download resume outcome, self-test decision/recognition timings, the audio source A/B
table, routed `inputDevice`, the no-speech timeout outcome, media key outcome, keep-screen-on outcome, and every
ANNAHME row updated.
Run: `git add docs/VAD_INPUT.md`
Run: `git commit -m "docs(voice): on-device verification of the vad route"`

Open items for Birk (write them at the end of `docs/VAD_INPUT.md`, do not do them):
- a test drive with the phone mic as Android routes it (car connected as usual), debug recordings on, alternating
  the audio source "Call processing" / "Recognition" between rounds. This decides the default source (spec 1.2);
- whether 8 s "Wait for speech" fits in the car;
- the cue tone choice;
- after the drive, tuning the pause from the debug rounds with `vad_offline_check.py` and deleting the recordings.
```

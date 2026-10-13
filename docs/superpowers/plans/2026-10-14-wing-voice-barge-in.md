# Wing Voice barge-in Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In Conversation mode on the vad route, Wing keeps listening while Hermes works. Each utterance
is steered into the running turn (`session.steer`), or sent as a normal prompt when the turn has ended.
Optionally, speaking during read-aloud stops it, gated on an on-device echo measurement.

**Architecture:** A chat-agnostic `TurnListener` runs VAD "listen rounds" on the existing `VoiceDevice`
(Silero windows → `VadEndpointer` → Parakeet). A pure policy file decides thresholds and delivery. A
`BargeInCoordinator` turns transcripts into steer/queue/send calls through a small `ListenTarget`
interface. `profile_workspace_screen.dart` gets thin hooks only. Native code gets two capture options:
`keepPlayback` (do not stop TTS when capture starts) and `startCue`.

**Tech Stack:** Flutter/Dart (flutter_test), Kotlin (Android `AudioRecord`, sherpa-onnx Silero),
Hermes TUI gateway JSON-RPC (`session.steer`).

**Spec:** `docs/superpowers/specs/2026-10-14-wing-voice-barge-in-design.md` (read §1-§9 before Task 1).

## Global Constraints

- Target: latest upstream Hermes, unmodified. Steer path verified at `NousResearch/hermes-agent` `main`
  `e06df9c2eae6901f4c88f464e0ae6e753c0428b8`. No backend patches, plugins or custom endpoints.
- Base: `voice-offline` after the VAD merge (contains `4a1a86c6`) **and** after the upstream merge chain
  t_d1d49ff1 → t_6a4e1890 → t_f8523002 (strategy rule 3). Task 0 checks this.
- Strategy rule 1: new logic goes in `lib/voice_offline/`; existing files get thin hooks only.
  `lib/core/controllers/voice_input_controller.dart` and
  `android/app/src/main/kotlin/com/tarkilhk/wing/VoicePlayback.kt` are **not touched**.
- Feature active only for: input route `vad`, Conversation mode on, setting `voice.listen_turn` on (or,
  for playback mode, `voice.barge_in_playback` on and `bargeInPlaybackAvailable == true`).
- Defaults: `voice.listen_turn` **on** (ANNAHME Birk-Gate D1), `voice.listen_min_speech_ms` **400**
  (choices 250/400/600), `voice.barge_in_playback` **off**.
- Playback gate start values: `bargeGateThreshold = 0.7`, `bargeGateWindows = 16` (512 ms). Task 7
  replaces them with measured values.
- Echo pass threshold (per scenario, all runs): `run50 ≤ 6` and `p99 < 0.5`. Marginal: `run50 ≤ 15` and
  `p99 < 0.75`.
- Logs: prefix `WingBargeIn`, via `debugPrint`. **Never** transcript, reply or prompt text, or session
  ids.
- Test texts are synthetic. No session data or personal text in the repo.
- D3 (ANNAHME Birk-Gate): a reply that Birk talked over, or barged into, is not read aloud or resumed.
- One command per Bash call. No `cd`, no `&&`/`;`, no `$VAR`, no `$( )`.
- Suite: `bash tools/factory/ci-suite.sh <test path>`. It runs flutter analyze + flutter test on GitHub
  Actions; expected last line `ci-suite: run <id> conclusion=success`. The script runs the whole suite;
  the path argument only documents the target test.
- Kotlin compile: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`; expected last line
  `dispatch-check: voice-apk.yml run <id> conclusion=success …`.
- Phone steps (install, `hadb`, measurement, listening tests) are done by the **Hermes worker**, never by
  a Claude Code subagent. These tasks are marked **[WORKER]**.
- Commit after every task on the working branch. No merge, no push except what the two factory scripts
  do themselves.

## File map

| File | Status | Responsibility |
|---|---|---|
| `lib/voice_offline/barge_in_policy.dart` | new | Pure: `listenConfig`, `PlaybackGate`, `EchoStats`, `isSendableTranscript`, `ListenChatState`, `ListenDelivery`, `decideDelivery`, gate constants, `echoProbeText`, `bargeLog` |
| `lib/voice_offline/turn_listener.dart` | new | `TurnListener`: listen rounds, playback gate, silent restart, probe |
| `lib/voice_offline/barge_in_coordinator.dart` | new | `ListenTarget`, `CallbackListenTarget`, `BargeInCoordinator` |
| `lib/voice_offline/barge_in_settings.dart` | new | `BargeInSettings` widget (settings rows + debug echo probe) |
| `docs/VOICE_BARGE_IN.md` | new | Behaviour, settings, log lines, measurement results |
| `test/voice_offline/barge_in_policy_test.dart` | new | |
| `test/voice_offline/turn_listener_test.dart` | new | |
| `test/voice_offline/barge_in_coordinator_test.dart` | new | |
| `test/voice_offline/vad_capture_options_test.dart` | new | |
| `android/app/src/main/kotlin/com/tarkilhk/wing/VadCapture.kt` | hook | `Options.startCue` |
| `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt` | hook | `keepPlayback`, `startCue` args |
| `lib/core/services/android_voice.dart` | hook | `VadCaptureOptions.startCue`, `.keepPlayback` |
| `lib/core/services/vad_endpoint.dart` | hook | `VadEndpointer.speechStarted` getter |
| `lib/core/services/voice_preferences.dart` | hook | 3 keys, 3 fields |
| `lib/core/widgets/voice_preferences_card.dart` | hook | insert `BargeInSettings` |
| `lib/core/screens/profile_workspace_screen.dart` | hooks | see Tasks 9 and 10 |
| `test/support/profile_browser_fixture.dart` | test support | `rpcResponses` map |
| `test/voice_preferences_test.dart`, `test/voice_workspace_test.dart` | tests | new cases and renders |

## Task order and dependencies

0 → 1 → 2 → 3 → 4 → 5 → **6 [WORKER]** → 7. Tasks 8 → 9 may run while 6 waits for Birk (S3 in the car).
Task 10 needs 7. Then 11 → 12 → **13 [WORKER]** → **14 [WORKER + Birk]**.

---

### Task 0: Basis check (no code)

**Files:** none.

- [ ] **Step 1: VAD chain included**

Run: `git merge-base --is-ancestor 4a1a86c6 HEAD`
Expected: exit code 0, no output. If it is 1: stop and report "VAD chain not merged into base".

- [ ] **Step 2: Upstream merge chain done**

Run: `git log --oneline -20 --merges`
Expected: a merge commit for the upstream merge (card t_f8523002) newer than the VAD merge. If it is
missing: stop and report it to the architect (strategy rule 3). Do not continue on Birk's behalf.

- [ ] **Step 3: Re-verify every hook location (one command each)**

```
git grep -n "playback.stop()" -- android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt
git grep -n "data class Options" -- android/app/src/main/kotlin/com/tarkilhk/wing/VadCapture.kt
git grep -n "TONE_PROP_BEEP" -- android/app/src/main/kotlin/com/tarkilhk/wing/VadCapture.kt
git grep -n "class VadCaptureOptions" -- lib/core/services/android_voice.dart
git grep -n "VadDecision? get decision" -- lib/core/services/vad_endpoint.dart
git grep -n "static const vadSourceKey" -- lib/core/services/voice_preferences.dart
git grep -n "key: const ValueKey('voice-conversation')" -- lib/core/widgets/voice_preferences_card.dart
git grep -n "_speakCompletedReply\|_sendConversationTurn\|set _conversation\|_voiceDeviceEvent\|Widget _voiceActivity\|Future<void> _dictate\|Listenable.merge(\[controller, _voiceInput" -- lib/core/screens/profile_workspace_screen.dart
git grep -n "Future<bool> steer\|Future<void> queuePrompt\|case 'message.start'" -- lib/core/services/profile_workspace_controller.dart
git grep -n "return {};" -- test/support/profile_browser_fixture.dart
```

Expected: every command prints at least one line. Spec line numbers (wt/t_24ef9c3d @ 4a1a86c6):
VoiceChannel.kt:92 `playback.stop()`, screen :217 setter, :238 `_speakCompletedReply`, :300
`_sendConversationTurn`, :356 `_voiceDeviceEvent`, :392 `_dictate`, :464 `_voiceActivity`, :794
`Listenable.merge`. They may have shifted; use the printed lines from here on.

- [ ] **Step 4: Hermes steer path unchanged upstream**

Run: `curl -s -m 60 -H "Accept: application/vnd.github.raw" "https://api.github.com/repos/NousResearch/hermes-agent/contents/tui_gateway/methods_session_interrupt.py?ref=main" -o build/hermes-msi.py`
Then: `grep -n "\"rejected\"\|_session_compression_in_flight\|_correction_method(\"session.steer\"" build/hermes-msi.py`
Expected: the three patterns are present. `rejected` is returned when `not session.get("running")`. If
it differs: stop and report it.

No commit: nothing changed.

---

### Task 1: Capture options `keepPlayback` and `startCue`

**Files:**
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/VadCapture.kt` (`data class Options`, `start()` cue line)
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt` (`private fun start`)
- Modify: `lib/core/services/android_voice.dart` (`class VadCaptureOptions`)
- Test: `test/voice_offline/vad_capture_options_test.dart`

**Interfaces:**
- Produces: `VadCaptureOptions({required bool cues, required bool debug, required VadAudioSource source, required Duration maxDuration, bool? startCue, bool keepPlayback = false})`.
  `toMap()` adds `'startCue': startCue ?? cues` and `'keepPlayback': keepPlayback`.
- Native: `startVad` reads `startCue` (default = `cues`) and `keepPlayback` (default false).

- [ ] **Step 1: Write the failing test**

`test/voice_offline/vad_capture_options_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/android_voice.dart';
import 'package:wing/core/services/voice_preferences.dart';

void main() {
  test('start cue follows cues unless set; playback is stopped by default', () {
    const options = VadCaptureOptions(
      cues: true,
      debug: false,
      source: VadAudioSource.communication,
      maxDuration: Duration(seconds: 600),
    );
    expect(options.toMap()['startCue'], isTrue);
    expect(options.toMap()['keepPlayback'], isFalse);
  });

  test('listen rounds keep playback and skip the start cue', () {
    const options = VadCaptureOptions(
      cues: true,
      debug: false,
      source: VadAudioSource.communication,
      maxDuration: Duration(seconds: 600),
      startCue: false,
      keepPlayback: true,
    );
    expect(options.toMap(), containsPair('startCue', false));
    expect(options.toMap(), containsPair('keepPlayback', true));
    expect(options.toMap(), containsPair('cues', true));
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tools/factory/ci-suite.sh test/voice_offline/vad_capture_options_test.dart`
Expected: `conclusion=failure` (analyzer: "No named parameter with the name 'startCue'").

- [ ] **Step 3: Dart implementation**

In `lib/core/services/android_voice.dart`, replace `class VadCaptureOptions { … }` with:

```dart
class VadCaptureOptions {
  const VadCaptureOptions({
    required this.cues,
    required this.debug,
    required this.source,
    required this.maxDuration,
    this.startCue,
    this.keepPlayback = false,
  });
  final bool cues;
  final bool debug;
  final VadAudioSource source;
  final Duration maxDuration;

  /// "Listening" beep before capture; defaults to [cues]. Listen rounds that
  /// restart silently turn it off and keep the "got it" tone.
  final bool? startCue;

  /// Start capture without stopping read-aloud (barge-in listen rounds).
  final bool keepPlayback;

  Map<String, Object> toMap() => {
    'cues': cues,
    'debug': debug,
    'source': source.name,
    'maxMs': maxDuration.inMilliseconds,
    'startCue': startCue ?? cues,
    'keepPlayback': keepPlayback,
  };
}
```

- [ ] **Step 4: Kotlin implementation**

`VadCapture.kt`. Replace the `Options` line:

```kotlin
    data class Options(val cues: Boolean, val debug: Boolean, val source: String, val maxMs: Int,
                       val startCue: Boolean = cues)
```

In `start()`, replace `if (options.cues) cue(ToneGenerator.TONE_PROP_BEEP, wait = true)` with:

```kotlin
            if (options.startCue) cue(ToneGenerator.TONE_PROP_BEEP, wait = true)
```

`VoiceChannel.kt`, in `private fun start(...)`. Replace the first line `playback.stop()` with:

```kotlin
        // Barge-in listen rounds record while Wing reads aloud.
        if (call.argument<Boolean>("keepPlayback") != true) playback.stop()
```

Replace the `vad.start(id, VadCapture.Options(` block with:

```kotlin
            val cues = call.argument<Boolean>("cues") != false
            vad.start(id, VadCapture.Options(
                cues = cues,
                debug = call.argument<Boolean>("debug") == true,
                source = call.argument<String>("source") ?: "communication",
                maxMs = call.argument<Int>("maxMs") ?: 600_000,
                startCue = call.argument<Boolean>("startCue") ?: cues,
            ))
```

- [ ] **Step 5: Run tests and the Kotlin compile**

Commit first, because both scripts build the committed HEAD:

```
git add lib/core/services/android_voice.dart android/app/src/main/kotlin/com/tarkilhk/wing/VadCapture.kt android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt test/voice_offline/vad_capture_options_test.dart
git commit -m "feat(voice): capture options keepPlayback and startCue for listen rounds"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/vad_capture_options_test.dart`
Expected: `conclusion=success`.
Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: `conclusion=success`.

---

### Task 2: Preferences and pure policy

**Files:**
- Modify: `lib/core/services/voice_preferences.dart`
- Modify: `lib/core/services/vad_endpoint.dart` (one getter)
- Create: `lib/voice_offline/barge_in_policy.dart`
- Test: `test/voice_offline/barge_in_policy_test.dart`, `test/voice_preferences_test.dart` (append)

**Interfaces:**
- Produces (voice_preferences.dart): `VoicePreferences.listenTurnKey = 'voice.listen_turn'`,
  `listenMinSpeechKey = 'voice.listen_min_speech_ms'`, `bargeInPlaybackKey = 'voice.barge_in_playback'`,
  `listenMinSpeechChoices = ['250', '400', '600']`; fields `bool listenTurn` (default true),
  `Duration listenMinSpeech` (default 400 ms), `bool bargeInPlayback` (default false).
- Produces (vad_endpoint.dart): `bool get speechStarted` on `VadEndpointer`.
- Produces (barge_in_policy.dart): `const bool bargeInPlaybackAvailable`, `const String? bargeInPlaybackHint`,
  `const double bargeGateThreshold`, `const int bargeGateWindows`, `const String echoProbeText`,
  `void bargeLog(String)`, `VadEndpointConfig listenConfig(VoicePreferences)`,
  `class PlaybackGate { PlaybackGate({double threshold, int windows}); int? firedAt; int longestRun; int? feed(int window, double p); }`,
  `class EchoStats { void add(double p); int get windows; double get max; int run50; int run70; double percentile(double q); String logLine({required String source, required bool wouldTrigger}); }`,
  `bool isSendableTranscript(String)`, `enum ListenChatState { steerable, busy, idle }`,
  `enum ListenDelivery { drop, steer, queue, send }`,
  `ListenDelivery decideDelivery(ListenChatState state, String transcript, {bool steerRejected = false})`.

- [ ] **Step 1: Write the failing tests**

`test/voice_offline/barge_in_policy_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/vad_endpoint.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'package:wing/voice_offline/barge_in_policy.dart';

void main() {
  group('listenConfig', () {
    test('keeps the pause, uses the listen minimum and never times out early', () {
      const settings = VoicePreferences(
        vad: VadEndpointConfig(
          pause: Duration(milliseconds: 1400),
          maxDuration: Duration(seconds: 900),
        ),
        listenMinSpeech: Duration(milliseconds: 600),
      );
      final config = listenConfig(settings);
      expect(config.pause, const Duration(milliseconds: 1400));
      expect(config.minSpeech, const Duration(milliseconds: 600));
      expect(config.maxDuration, const Duration(seconds: 900));
      expect(config.noSpeechTimeout, const Duration(seconds: 900));
    });

    test('a cough of 10 windows does not start speech at the 400 ms default', () {
      final endpointer = VadEndpointer(listenConfig(const VoicePreferences()));
      endpointer.feedAll([...List.filled(10, 0.9), ...List.filled(5, 0.1)]);
      expect(endpointer.speechStarted, isFalse);
      endpointer.feedAll(List.filled(13, 0.9));
      expect(endpointer.speechStarted, isTrue);
    });
  });

  group('PlaybackGate', () {
    test('fires once at the start of a long enough run', () {
      final gate = PlaybackGate(threshold: 0.7, windows: 16);
      int? fired;
      for (var i = 0; i < 40; i++) {
        fired ??= gate.feed(i, i < 4 ? 0.1 : 0.9);
      }
      expect(fired, 4);
      expect(gate.firedAt, 4);
      expect(gate.longestRun, 36);
    });

    test('a cough (8 windows at 0.8) and echo bursts never fire', () {
      final gate = PlaybackGate(threshold: 0.7, windows: 16);
      final probabilities = [
        ...List.filled(8, 0.8),
        ...List.filled(20, 0.1),
        for (var i = 0; i < 60; i++) i % 7 < 6 ? 0.75 : 0.3,
      ];
      for (var i = 0; i < probabilities.length; i++) {
        expect(gate.feed(i, probabilities[i]), isNull);
      }
      expect(gate.firedAt, isNull);
      expect(gate.longestRun, 8);
    });

    test('a gap in window indices breaks the run', () {
      final gate = PlaybackGate(threshold: 0.7, windows: 3);
      expect(gate.feed(0, 0.9), isNull);
      expect(gate.feed(1, 0.9), isNull);
      expect(gate.feed(5, 0.9), isNull);
      expect(gate.feed(6, 0.9), isNull);
      expect(gate.feed(7, 0.9), 5);
    });
  });

  group('EchoStats', () {
    test('nearest-rank percentiles, maximum and runs', () {
      final stats = EchoStats();
      for (var i = 1; i <= 100; i++) {
        stats.add(i / 100);
      }
      expect(stats.windows, 100);
      expect(stats.max, 1.0);
      expect(stats.percentile(0.5), 0.5);
      expect(stats.percentile(0.99), 0.99);
      expect(stats.run50, 51);
      expect(stats.run70, 31);
      expect(
        stats.logLine(source: 'VOICE_COMMUNICATION', wouldTrigger: false),
        'probe windows=100 max=1.000 p50=0.500 p95=0.950 p99=0.990 '
        'run50=51 run70=31 wouldTrigger=0 source=VOICE_COMMUNICATION',
      );
    });

    test('empty stats log zeros', () {
      expect(EchoStats().percentile(0.99), 0);
      expect(EchoStats().max, 0);
    });
  });

  group('transcripts', () {
    for (final (text, sendable) in [
      ('', false),
      ('   ', false),
      ('.', false),
      ('Äh.', false),
      ('ähm, hm', false),
      ('Ja', true),
      ('nein', true),
      ('Äh, nimm lieber das Datum', true),
      ('Stopp', true),
    ]) {
      test('"$text" sendable: $sendable', () {
        expect(isSendableTranscript(text), sendable);
      });
    }
  });

  group('decideDelivery', () {
    test('status table', () {
      expect(decideDelivery(ListenChatState.steerable, 'Testsatz'), ListenDelivery.steer);
      expect(decideDelivery(ListenChatState.busy, 'Testsatz'), ListenDelivery.queue);
      expect(decideDelivery(ListenChatState.idle, 'Testsatz'), ListenDelivery.send);
      expect(
        decideDelivery(ListenChatState.steerable, 'Testsatz', steerRejected: true),
        ListenDelivery.queue,
      );
      expect(
        decideDelivery(ListenChatState.idle, 'Testsatz', steerRejected: true),
        ListenDelivery.send,
      );
    });

    test('unsendable text is dropped in every state', () {
      for (final state in ListenChatState.values) {
        expect(decideDelivery(state, 'hm'), ListenDelivery.drop);
      }
    });
  });

  test('gate constants stay inside the spec bounds', () {
    expect(bargeGateThreshold, inInclusiveRange(0.7, 0.9));
    expect(bargeGateWindows, inInclusiveRange(16, 31));
  });

  test('the probe text is synthetic German without digits', () {
    expect(echoProbeText, contains('Messtext'));
    expect(RegExp(r'\d').hasMatch(echoProbeText), isFalse);
  });
}
```

Append to `test/voice_preferences_test.dart`, inside `main()` (before the first `testWidgets`):

```dart
  test('barge-in preferences: defaults, parsing and validation', () async {
    SharedPreferences.setMockInitialValues({});
    var prefs = await SharedPreferences.getInstance();
    var read = VoicePreferences.read(prefs);
    expect(read.listenTurn, isTrue);
    expect(read.listenMinSpeech, const Duration(milliseconds: 400));
    expect(read.bargeInPlayback, isFalse);
    SharedPreferences.setMockInitialValues({
      VoicePreferences.listenTurnKey: 'off',
      VoicePreferences.listenMinSpeechKey: '600',
      VoicePreferences.bargeInPlaybackKey: 'on',
    });
    prefs = await SharedPreferences.getInstance();
    read = VoicePreferences.read(prefs);
    expect(read.listenTurn, isFalse);
    expect(read.listenMinSpeech, const Duration(milliseconds: 600));
    expect(read.bargeInPlayback, isTrue);
    expect(VoicePreferences.accepts(VoicePreferences.listenMinSpeechKey, '150'), isFalse);
    expect(VoicePreferences.accepts(VoicePreferences.listenTurnKey, 'on'), isTrue);
    expect(VoicePreferences.accepts(VoicePreferences.bargeInPlaybackKey, 'maybe'), isFalse);
    expect(VoicePreferences.keys, containsAll([
      VoicePreferences.listenTurnKey,
      VoicePreferences.listenMinSpeechKey,
      VoicePreferences.bargeInPlaybackKey,
    ]));
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tools/factory/ci-suite.sh test/voice_offline/barge_in_policy_test.dart`
Expected: `conclusion=failure` (missing `barge_in_policy.dart`, `listenMinSpeech`).

- [ ] **Step 3: `vad_endpoint.dart` getter**

Directly below `VadDecision? get decision => _decision;` add:

```dart
  /// True once a speech start was confirmed in this round.
  bool get speechStarted => _speechStart >= 0;
```

(The Python mirror `tools/voice/vad_endpoint.py` needs no change: the getter adds no behaviour.)

- [ ] **Step 4: `voice_preferences.dart`**

Below `static const vadSourceKey = 'voice.vad_source';` add:

```dart
  static const listenTurnKey = 'voice.listen_turn';
  static const listenMinSpeechKey = 'voice.listen_min_speech_ms';
  static const bargeInPlaybackKey = 'voice.barge_in_playback';
```

In `static const keys = { … }` append `listenTurnKey, listenMinSpeechKey, bargeInPlaybackKey,`.
Below `vadNoSpeechChoices` add:

```dart
  static const listenMinSpeechChoices = ['250', '400', '600'];
```

In `accepts`, change the on/off line to:

```dart
    autoSpeakKey ||
    conversationKey ||
    vadCuesKey ||
    vadDebugKey ||
    listenTurnKey ||
    bargeInPlaybackKey => value == 'on' || value == 'off',
```

and add before `_ => false,`:

```dart
    listenMinSpeechKey => listenMinSpeechChoices.contains(value),
```

Fields (after `final VadAudioSource audioSource;`):

```dart
  /// Conversation mode on the vad route: keep listening while a turn runs
  /// and steer it with what was said.
  final bool listenTurn;

  /// Continuous speech that opens an utterance in a listen round.
  final Duration listenMinSpeech;

  /// Speaking during read-aloud stops it (offered after the echo gate).
  final bool bargeInPlayback;
```

Constructor parameters (after `this.audioSource = VadAudioSource.communication,`):

```dart
    this.listenTurn = true,
    this.listenMinSpeech = const Duration(milliseconds: 400),
    this.bargeInPlayback = false,
```

In `VoicePreferences.read`, after `audioSource: …,` add:

```dart
      listenTurn: preferences.getString(listenTurnKey) != 'off',
      listenMinSpeech: Duration(
        milliseconds: choice(listenMinSpeechKey, listenMinSpeechChoices, 400),
      ),
      bargeInPlayback: preferences.getString(bargeInPlaybackKey) == 'on',
```

- [ ] **Step 5: `lib/voice_offline/barge_in_policy.dart`**

```dart
/// Barge-in policy: thresholds, echo statistics and what happens with an
/// utterance heard while Hermes works or reads aloud. Pure; no Flutter
/// widgets, no chat types (spec 2026-10-14-wing-voice-barge-in-design.md).
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/services/vad_endpoint.dart';
import '../core/services/voice_preferences.dart';

/// Offer "Interrupt read-aloud by speaking" (set by the echo gate, Task 7).
const bool bargeInPlaybackAvailable = false;

/// Subtitle for that switch, e.g. when only headphones passed the gate.
const String? bargeInPlaybackHint = null;

/// While Wing reads aloud, speech only counts after [bargeGateWindows]
/// consecutive windows (32 ms each) with p >= [bargeGateThreshold].
const double bargeGateThreshold = 0.7;
const int bargeGateWindows = 16;

/// Synthetic text read during the echo probe (about 30 s). Never shown.
const String echoProbeText =
    'Dies ist ein Messtext für die Echoprüfung. Er enthält keine echten '
    'Inhalte. Die Sprachausgabe liest ihn gleichmäßig vor, während das '
    'Mikrofon mithört. Eins, zwei, drei, vier, fünf, sechs, sieben, acht, '
    'neun, zehn. Der Wind weht über das flache Land, und am Horizont ziehen '
    'graue Wolken auf. Ein Zug fährt langsam durch den kleinen Bahnhof, ohne '
    'anzuhalten. Elf, zwölf, dreizehn, vierzehn, fünfzehn. Jetzt endet der '
    'Messtext.';

/// One logcat line (tag flutter). Callers pass numbers and states only,
/// never transcript, reply or prompt text.
void bargeLog(String message) => debugPrint('WingBargeIn $message');

/// Endpointing for listen rounds: same pause and lead-in as dictation, a
/// higher minimum speech, and no early no-speech stop (a tool turn can run
/// for minutes; the round restarts at its maximum duration instead).
VadEndpointConfig listenConfig(VoicePreferences settings) => VadEndpointConfig(
  pause: settings.vad.pause,
  minSpeech: settings.listenMinSpeech,
  preRoll: settings.vad.preRoll,
  maxDuration: settings.vad.maxDuration,
  noSpeechTimeout: settings.vad.maxDuration,
);

/// Confirms a barge-in during read-aloud: a run of [windows] consecutive
/// windows at or above [threshold]. Fires once; [firedAt] is the run's first
/// window.
class PlaybackGate {
  PlaybackGate({
    this.threshold = bargeGateThreshold,
    this.windows = bargeGateWindows,
  });

  final double threshold;
  final int windows;
  int? firedAt;
  int longestRun = 0;
  int _run = 0;
  int _runStart = -1;
  int _last = -2;

  /// Returns the run's first window when the gate fires, otherwise null.
  int? feed(int window, double p) {
    if (window != _last + 1) _run = 0;
    _last = window;
    if (p < threshold) {
      _run = 0;
      return null;
    }
    if (_run == 0) _runStart = window;
    _run++;
    if (_run > longestRun) longestRun = _run;
    if (firedAt == null && _run >= windows) return firedAt = _runStart;
    return null;
  }
}

/// Speech probabilities measured while Wing plays its own voice.
class EchoStats {
  final List<double> _values = [];
  int run50 = 0;
  int run70 = 0;
  int _current50 = 0;
  int _current70 = 0;

  int get windows => _values.length;
  double get max => _values.isEmpty ? 0 : _values.reduce(math.max);

  void add(double p) {
    _values.add(p);
    _current50 = p >= 0.5 ? _current50 + 1 : 0;
    _current70 = p >= 0.7 ? _current70 + 1 : 0;
    if (_current50 > run50) run50 = _current50;
    if (_current70 > run70) run70 = _current70;
  }

  /// Nearest-rank percentile; [q] in 0..1.
  double percentile(double q) {
    if (_values.isEmpty) return 0;
    final sorted = [..._values]..sort();
    final rank = (q * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
  }

  String logLine({required String source, required bool wouldTrigger}) {
    String f(double value) => value.toStringAsFixed(3);
    return 'probe windows=$windows max=${f(max)} p50=${f(percentile(0.5))} '
        'p95=${f(percentile(0.95))} p99=${f(percentile(0.99))} '
        'run50=$run50 run70=$run70 wouldTrigger=${wouldTrigger ? 1 : 0} '
        'source=$source';
  }
}

const _fillers = {'äh', 'ähm', 'öh', 'hm', 'hmm', 'mhm', 'uh', 'um', 'uhm', 'eh'};
final _letter = RegExp(r'\p{L}', unicode: true);
final _nonLetter = RegExp(r'[^\p{L}]', unicode: true);

/// False for empty text, text without letters, or fillers only. "ja" and
/// "nein" are answers, not fillers.
bool isSendableTranscript(String text) {
  final trimmed = text.trim();
  if (!_letter.hasMatch(trimmed)) return false;
  return trimmed
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .map((word) => word.replaceAll(_nonLetter, ''))
      .where((word) => word.isNotEmpty)
      .any((word) => !_fillers.contains(word));
}

/// Chat state as the listener needs it (mapped from ProfileTurnStatus by
/// the workspace screen): running/attention → steerable,
/// submitting/reconnecting → busy, everything else → idle.
enum ListenChatState { steerable, busy, idle }

enum ListenDelivery { drop, steer, queue, send }

ListenDelivery decideDelivery(
  ListenChatState state,
  String transcript, {
  bool steerRejected = false,
}) {
  if (!isSendableTranscript(transcript)) return ListenDelivery.drop;
  return switch (state) {
    ListenChatState.steerable =>
      steerRejected ? ListenDelivery.queue : ListenDelivery.steer,
    ListenChatState.busy => ListenDelivery.queue,
    ListenChatState.idle => ListenDelivery.send,
  };
}
```

- [ ] **Step 6: Commit and run**

```
git add lib/voice_offline/barge_in_policy.dart lib/core/services/vad_endpoint.dart lib/core/services/voice_preferences.dart test/voice_offline/barge_in_policy_test.dart test/voice_preferences_test.dart
git commit -m "feat(voice): barge-in preferences and pure listen policy"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/barge_in_policy_test.dart`
Expected: `conclusion=success`.

---

### Task 3: `TurnListener`

**Files:**
- Create: `lib/voice_offline/turn_listener.dart`
- Test: `test/voice_offline/turn_listener_test.dart`

**Interfaces:**
- Consumes: Task 1 `VadCaptureOptions(startCue:, keepPlayback:)`; Task 2 `listenConfig`, `PlaybackGate`,
  `EchoStats`, `bargeLog`, `VadEndpointer.speechStarted`.
- Produces:
  - `enum ListenPhase { idle, listening, transcribing }`
  - `class TurnListener extends ChangeNotifier` with:
    - `TurnListener({required VoiceDevice device, DateTime Function()? clock})`
    - `ListenPhase phase`, `bool get isOpen`, `bool get speechInProgress`
    - `void Function(String text)? onUtterance`, `Future<void> Function()? onBarge`
    - `Future<void> open(VoicePreferences settings, {bool playback = false})`
    - `void setPlayback(bool playing)`
    - `Future<void> endUtterance()`
    - `Future<void> close(String reason)`
    - `Future<EchoStats> probe(VoicePreferences settings, Future<void> Function() play)`

- [ ] **Step 1: Write the failing test**

`test/voice_offline/turn_listener_test.dart`:

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/vad_endpoint.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'package:wing/voice_offline/turn_listener.dart';
import '../support/voice_fixture.dart';

const settings = VoicePreferences(
  input: VoiceInputRoute.vad,
  conversation: true,
  vad: VadEndpointConfig(maxDuration: Duration(seconds: 2)),
);

void main() {
  late VoiceDeviceFixture device;
  late TurnListener listener;
  late List<String> heard;
  late int barges;

  setUp(() {
    device = VoiceDeviceFixture();
    listener = TurnListener(device: device);
    heard = [];
    barges = 0;
    listener.onUtterance = heard.add;
    listener.onBarge = () async => barges++;
  });
  tearDown(() async {
    listener.dispose();
    await device.stream.close();
  });

  Future<void> say(double p, int count) async {
    device.emitWindows(List.filled(count, p));
    await pumpEventQueue();
  }

  test('an utterance is transcribed, handed over and the next round starts', () async {
    await listener.open(settings);
    expect(device.vadOptions!.keepPlayback, isTrue);
    expect(device.vadOptions!.startCue, isFalse);
    expect(listener.phase, ListenPhase.listening);
    await say(0.9, 20);
    expect(listener.speechInProgress, isTrue);
    await say(0.1, 60);
    expect(device.finishes.single.reason, VadEndReason.pause);
    expect(heard, ['Hello from the phone']);
    expect(device.vadStarts, 2);
    expect(listener.isOpen, isTrue);
  });

  test('silence restarts the round at max duration without recognition', () async {
    await listener.open(settings);
    final first = device.recording;
    await say(0.1, 70);
    expect(device.finishes, isEmpty);
    expect(device.cancelled, contains(first));
    expect(device.vadStarts, 2);
    expect(heard, isEmpty);
  });

  test('during playback a cough is rejected and read-aloud continues', () async {
    await listener.open(settings, playback: true);
    await say(0.8, 14);
    await say(0.1, 60);
    expect(barges, 0);
    expect(device.finishes, isEmpty);
    expect(heard, isEmpty);
    expect(device.vadStarts, 2);
  });

  test('during playback real speech stops read-aloud once and is transcribed', () async {
    await listener.open(settings, playback: true);
    await say(0.9, 30);
    expect(barges, 1);
    await say(0.1, 60);
    expect(barges, 1);
    expect(heard, ['Hello from the phone']);
  });

  test('after playback ended the normal rules apply again', () async {
    await listener.open(settings, playback: true);
    listener.setPlayback(false);
    await say(0.8, 14);
    await say(0.1, 60);
    expect(barges, 0);
    expect(heard, ['Hello from the phone']);
  });

  test('close cancels the round and nothing restarts', () async {
    await listener.open(settings);
    final id = device.recording;
    await listener.close('test');
    expect(device.cancelled, contains(id));
    expect(listener.isOpen, isFalse);
    await say(0.9, 30);
    await say(0.1, 60);
    expect(heard, isEmpty);
    expect(device.vadStarts, 1);
  });

  test('a transcript that arrives after close is dropped', () async {
    await listener.open(settings);
    device.finishDelay = Completer<String>();
    await say(0.9, 20);
    await say(0.1, 60);
    expect(listener.phase, ListenPhase.transcribing);
    await listener.close('test');
    device.finishDelay!.complete('Late words');
    await pumpEventQueue();
    expect(heard, isEmpty);
    expect(device.vadStarts, 1);
  });

  test('media key without speech closes, with speech ends the utterance', () async {
    await listener.open(settings);
    await listener.endUtterance();
    expect(listener.isOpen, isFalse);
    await listener.open(settings);
    await say(0.9, 20);
    await listener.endUtterance();
    await pumpEventQueue();
    expect(device.finishes.single.reason, VadEndReason.mediaKey);
    expect(heard, ['Hello from the phone']);
  });

  test('probe collects statistics only and closes', () async {
    final stats = await listener.probe(settings, () async {
      device.emitWindows([0.1, 0.2, 0.6, 0.6]);
      await pumpEventQueue();
    });
    expect(stats.windows, 4);
    expect(stats.max, 0.6);
    expect(stats.run50, 2);
    expect(device.vadOptions!.cues, isFalse);
    expect(device.finishes, isEmpty);
    expect(heard, isEmpty);
    expect(listener.isOpen, isFalse);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tools/factory/ci-suite.sh test/voice_offline/turn_listener_test.dart`
Expected: `conclusion=failure` (missing `turn_listener.dart`).

- [ ] **Step 3: Implementation**

`lib/voice_offline/turn_listener.dart`:

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/services/android_voice.dart';
import '../core/services/vad_endpoint.dart';
import '../core/services/voice_preferences.dart';
import 'barge_in_policy.dart';

enum ListenPhase { idle, listening, transcribing }

/// Listen rounds on the vad route while Hermes works or reads aloud. One
/// round at a time; a round that ends without a usable utterance is replaced
/// silently. Knows nothing about chats: [onUtterance] hands every transcript
/// to the caller, [onBarge] asks it to stop read-aloud now.
class TurnListener extends ChangeNotifier {
  TurnListener({required this.device, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    _events = device.events.listen(_event);
  }

  final VoiceDevice device;
  final DateTime Function() _clock;
  late final StreamSubscription<Map<String, dynamic>> _events;

  ListenPhase phase = ListenPhase.idle;
  void Function(String text)? onUtterance;
  Future<void> Function()? onBarge;

  VoicePreferences? _settings;
  String? _id;
  VadEndpointer? _endpointer;
  PlaybackGate? _gate;
  EchoStats? _stats;
  PlaybackGate? _probeGate;
  DateTime? _roundStart;
  bool _disposed = false;

  bool get isOpen => phase != ListenPhase.idle;

  /// Speech confirmed in the current round, or its transcript still pending.
  bool get speechInProgress =>
      phase == ListenPhase.transcribing ||
      (_endpointer?.speechStarted ?? false);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> open(VoicePreferences settings, {bool playback = false}) async {
    if (_disposed) return;
    _settings = settings;
    if (isOpen) {
      setPlayback(playback);
      return;
    }
    bargeLog('listen open mode=${playback ? 'playback' : 'turn'}');
    await _startRound(playback: playback);
  }

  /// Read-aloud started or ended; only playback needs the stricter gate.
  void setPlayback(bool playing) {
    if (!isOpen) return;
    _gate = playing ? (_gate ?? PlaybackGate()) : null;
  }

  Future<void> _startRound({required bool playback, bool cues = true}) async {
    final settings = _settings;
    if (settings == null || _disposed) return;
    final id = const Uuid().v4();
    _id = id;
    _endpointer = VadEndpointer(listenConfig(settings));
    _gate = playback ? PlaybackGate() : null;
    _roundStart = null;
    phase = ListenPhase.listening;
    _notify();
    try {
      await device.startVad(
        id,
        VadCaptureOptions(
          cues: cues && settings.cues,
          startCue: false,
          keepPlayback: true,
          debug: settings.debugRecordings,
          source: settings.audioSource,
          maxDuration: settings.vad.maxDuration,
        ),
      );
      if (_id != id || _disposed) {
        await device.cancel(id);
        return;
      }
      _roundStart = _clock();
    } catch (_) {
      if (_id == id) await _close('error');
    }
  }

  void _event(Map<String, dynamic> event) {
    if (_id == null || event['id'] != _id || _disposed) return;
    if (event['error'] is String) {
      unawaited(_close('error'));
      return;
    }
    final windows = event['windows'];
    final endpointer = _endpointer;
    if (windows is! List || endpointer == null) return;
    if (phase != ListenPhase.listening) return;
    var index = (event['first'] as num?)?.toInt() ?? endpointer.windows;
    for (final value in windows) {
      final p = (value as num).toDouble();
      final window = index++;
      final stats = _stats;
      if (stats != null) {
        stats.add(p);
        _probeGate?.feed(window, p);
        continue;
      }
      final onset = _gate?.feed(window, p);
      if (onset != null) unawaited(_barge(onset));
      final decision = endpointer.feed(p);
      if (decision != null) {
        unawaited(_decided(decision));
        return;
      }
    }
  }

  Future<void> _barge(int onsetWindow) async {
    final started = _roundStart;
    final before = _clock();
    try {
      await onBarge?.call();
    } catch (_) {
      // Stopping playback is best effort; the utterance is still recorded.
    }
    final after = _clock();
    final onset = started?.add(
      Duration(milliseconds: onsetWindow * vadWindowMs),
    );
    final since = onset == null ? -1 : after.difference(onset).inMilliseconds;
    bargeLog(
      'barge trigger sinceOnsetMs=$since '
      'stopMs=${after.difference(before).inMilliseconds}',
    );
  }

  Future<void> _decided(VadDecision decision) async {
    final id = _id;
    final endpointer = _endpointer;
    if (id == null || endpointer == null) return;
    final gate = _gate;
    if (!decision.hasSpeech) {
      bargeLog('listen restart reason=${decision.reason.name}');
      await _replace(id, playback: gate != null);
      return;
    }
    if (gate != null && gate.firedAt == null) {
      bargeLog('barge reject runWindows=${gate.longestRun}');
      await _replace(id, playback: true);
      return;
    }
    phase = ListenPhase.transcribing;
    _notify();
    final String text;
    try {
      final chunks = vadChunksFor(
        endpointer.probabilities,
        decision.startWindow,
        decision.endWindow,
      );
      text = await device
          .finishVad(id, decision, endpointer.config, chunks: chunks)
          .timeout(
            vadRecognitionBudget(decision.segment, chunks: chunks.length),
          );
    } catch (_) {
      if (_id == id && !_disposed) {
        bargeLog('utterance failed');
        await _startRound(playback: false);
      }
      return;
    }
    if (_id != id || _disposed) return;
    bargeLog(
      'utterance segmentMs=${decision.segment.inMilliseconds} '
      'textLen=${text.trim().length}',
    );
    await _startRound(playback: false);
    onUtterance?.call(text);
  }

  /// Ends round [id] without recognition and starts the next one.
  Future<void> _replace(String id, {required bool playback}) async {
    await device.cancel(id).catchError((Object _) {});
    if (_id == id && !_disposed) await _startRound(playback: playback);
  }

  /// Media key: end the utterance now, or close when nothing was said.
  Future<void> endUtterance() async {
    final endpointer = _endpointer;
    if (phase != ListenPhase.listening || endpointer == null) return;
    if (!endpointer.speechStarted) {
      await _close('mediaKey');
      return;
    }
    _gate = null;
    await _decided(endpointer.forceEnd(VadEndReason.mediaKey));
  }

  Future<void> close(String reason) => _close(reason);

  Future<void> _close(String reason) async {
    final id = _id;
    if (id == null && phase == ListenPhase.idle) return;
    _id = null;
    _endpointer = null;
    _gate = null;
    _roundStart = null;
    phase = ListenPhase.idle;
    _notify();
    bargeLog('listen close reason=$reason');
    if (id != null) await device.cancel(id).catchError((Object _) {});
  }

  /// Debug: records speech probabilities while [play] runs (nobody speaking)
  /// and logs one `probe` line. No recognition, no utterances.
  Future<EchoStats> probe(
    VoicePreferences settings,
    Future<void> Function() play,
  ) async {
    await _close('probe');
    final stats = EchoStats();
    final gate = PlaybackGate();
    _settings = settings;
    _stats = stats;
    _probeGate = gate;
    try {
      await _startRound(playback: false, cues: false);
      await play();
    } finally {
      _stats = null;
      _probeGate = null;
      await _close('probe');
    }
    bargeLog(
      stats.logLine(
        source: settings.audioSource == VadAudioSource.communication
            ? 'VOICE_COMMUNICATION'
            : 'VOICE_RECOGNITION',
        wouldTrigger: gate.firedAt != null,
      ),
    );
    return stats;
  }

  @override
  void dispose() {
    unawaited(_close('dispose'));
    _disposed = true;
    unawaited(_events.cancel());
    super.dispose();
  }
}
```

Note: `source` is the *configured* source. If `VOICE_COMMUNICATION` fails to initialise, Kotlin falls
back to `VOICE_RECOGNITION` (`VadCapture.kt` `openRecord`). Task 6 reads the real source from
`dumpsys audio`.

- [ ] **Step 4: Commit and run**

```
git add lib/voice_offline/turn_listener.dart test/voice_offline/turn_listener_test.dart
git commit -m "feat(voice): turn listener with playback gate and echo probe"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/turn_listener_test.dart`
Expected: `conclusion=success`.

---

### Task 4: Settings rows and the debug echo probe

**Files:**
- Create: `lib/voice_offline/barge_in_settings.dart`
- Modify: `lib/core/widgets/voice_preferences_card.dart` (after the `voice-conversation` `SwitchListTile`)
- Test: `test/voice_preferences_test.dart` (append)

**Interfaces:**
- Consumes: Task 2 preference keys and fields, `bargeInPlaybackAvailable`, `bargeInPlaybackHint`,
  `echoProbeText`; Task 3 `TurnListener.probe`.
- Produces: `BargeInSettings({required VoicePreferences settings, required VoiceDevice device, required bool saving, required Future<void> Function(String key, String value) onSave})`.
  Widget keys: `voice-listen-turn`, `voice-barge-in-playback`, `voice-echo-probe`.

- [ ] **Step 1: Write the failing tests** (append inside `main()` of `test/voice_preferences_test.dart`,
  after the existing `show` helper)

```dart
  Future<SharedPreferences> vadConversation() async {
    SharedPreferences.setMockInitialValues({
      VoicePreferences.inputKey: 'vad',
      VoicePreferences.conversationKey: 'on',
    });
    return SharedPreferences.getInstance();
  }

  testWidgets('listen-while-working settings appear only with vad conversation', (
    tester,
  ) async {
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    SharedPreferences.setMockInitialValues({});
    await show(tester, await SharedPreferences.getInstance(), device);
    expect(find.text('Listen while Hermes works'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    final prefs = await vadConversation();
    await show(tester, prefs, device);
    await tester.ensureVisible(find.text('Listen while Hermes works'));
    expect(find.text('Speech needed to steer'), findsOneWidget);
    expect(find.text('Interrupt read-aloud by speaking'), findsNothing);
    expect(find.text('Measure speaker echo'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('voice-listen-turn')));
    await tester.pumpAndSettle();
    expect(VoicePreferences.read(prefs).listenTurn, isFalse);
    expect(find.text('Speech needed to steer'), findsNothing);
  });

  testWidgets('echo probe plays the synthetic text while a listen round records', (
    tester,
  ) async {
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    final prefs = await vadConversation();
    await prefs.setString(VoicePreferences.vadDebugKey, 'on');
    await show(tester, prefs, device);
    await tester.ensureVisible(find.text('Measure speaker echo'));
    await tester.tap(find.text('Measure speaker echo'));
    await tester.pumpAndSettle();
    expect(device.calls, containsAllInOrder(['startVad', 'speak']));
    expect(device.vadOptions!.keepPlayback, isTrue);
    expect(device.spoken, contains('Messtext'));
    expect(find.text('Measure speaker echo'), findsOneWidget);
  });
```

Add the import `import 'package:flutter/material.dart';` only if it is not already present (it is used by
`ValueKey`).

- [ ] **Step 2: Run to verify failure**

Run: `bash tools/factory/ci-suite.sh test/voice_preferences_test.dart`
Expected: `conclusion=failure` (text "Listen while Hermes works" not found).

- [ ] **Step 3: `lib/voice_offline/barge_in_settings.dart`**

```dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/controllers/voice_output_controller.dart';
import '../core/services/android_voice.dart';
import '../core/services/voice_preferences.dart';
import '../core/widgets/compact_switch.dart';
import '../core/widgets/studio_error.dart';
import '../core/widgets/studio_select.dart';
import 'barge_in_policy.dart';
import 'turn_listener.dart';

/// Conversation-mode rows for listening while Hermes works, and the debug
/// echo probe. Shown only on the vad route with Conversation mode on.
class BargeInSettings extends StatefulWidget {
  const BargeInSettings({
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
  State<BargeInSettings> createState() => _BargeInSettingsState();
}

class _BargeInSettingsState extends State<BargeInSettings> {
  TurnListener? _listener;
  VoiceOutputController? _output;
  bool _probing = false;

  @override
  void dispose() {
    _output?.dispose();
    _listener?.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    final listener = _listener ??= TurnListener(device: widget.device);
    final output = _output ??= VoiceOutputController(widget.device);
    final settings = widget.settings;
    setState(() => _probing = true);
    try {
      await listener.probe(settings, () async {
        await output.speak(
          'echo-probe',
          echoProbeText,
          VoicePreferences(voice: settings.voice, rate: settings.rate),
          () => throw StateError('The echo probe uses the Android voice.'),
        );
      });
    } catch (_) {
      if (mounted) {
        showStudioError(context, 'The echo measurement failed. Please retry.');
      }
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  /// '400' → '0.4 s'.
  String _seconds(String ms) {
    final text = (int.parse(ms) / 1000).toString();
    return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text} s';
  }

  void _toggle(String key, bool on) =>
      unawaited(widget.onSave(key, on ? 'on' : 'off'));

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    if (s.input != VoiceInputRoute.vad || !s.conversation) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CompactSwitchListTile(
          key: const ValueKey('voice-listen-turn'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Listen while Hermes works'),
          subtitle: const Text('Speak to steer the running reply'),
          value: s.listenTurn,
          onChanged: widget.saving
              ? null
              : (value) => _toggle(VoicePreferences.listenTurnKey, value),
        ),
        if (s.listenTurn) ...[
          const SizedBox(height: 12),
          StudioSelect<String>(
            key: ValueKey(
              'voice-listen-min-speech-${s.listenMinSpeech.inMilliseconds}',
            ),
            label: 'Speech needed to steer',
            value: s.listenMinSpeech.inMilliseconds.toString(),
            options: [
              for (final value in VoicePreferences.listenMinSpeechChoices)
                (value: value, label: _seconds(value)),
            ],
            onChanged: widget.saving
                ? null
                : (value) {
                    if (value != null) {
                      unawaited(
                        widget.onSave(
                          VoicePreferences.listenMinSpeechKey,
                          value,
                        ),
                      );
                    }
                  },
          ),
        ],
        if (bargeInPlaybackAvailable)
          CompactSwitchListTile(
            key: const ValueKey('voice-barge-in-playback'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Interrupt read-aloud by speaking'),
            subtitle: bargeInPlaybackHint == null
                ? null
                : const Text(bargeInPlaybackHint!),
            value: s.bargeInPlayback,
            onChanged: widget.saving
                ? null
                : (value) =>
                      _toggle(VoicePreferences.bargeInPlaybackKey, value),
          ),
        if (s.debugRecordings)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('voice-echo-probe'),
              onPressed: _probing || widget.saving
                  ? null
                  : () => unawaited(_probe()),
              child: Text(
                _probing ? 'Measuring speaker echo…' : 'Measure speaker echo',
              ),
            ),
          ),
      ],
    );
  }
}
```

If the analyzer rejects `const Text(bargeInPlaybackHint!)` (a non-constant expression in a const
constructor), use `Text(bargeInPlaybackHint!)` without `const`.

- [ ] **Step 4: Card hook**

In `lib/core/widgets/voice_preferences_card.dart` add the import
`import '../../voice_offline/barge_in_settings.dart';`. Directly after the closing `),` of the
`SwitchListTile(key: const ValueKey('voice-conversation'), …)` insert:

```dart
        BargeInSettings(
          settings: _preferences,
          device: widget.device ?? AndroidVoice.instance,
          saving: _saving,
          onSave: _save,
        ),
```

- [ ] **Step 5: Commit and run**

```
git add lib/voice_offline/barge_in_settings.dart lib/core/widgets/voice_preferences_card.dart test/voice_preferences_test.dart
git commit -m "feat(voice): listen-while-working settings and debug echo probe"
```

Run: `bash tools/factory/ci-suite.sh test/voice_preferences_test.dart`
Expected: `conclusion=success`.

---

### Task 5: Probe build for the phone

**Files:** none (build only).

- [ ] **Step 1: Publish an APK of the current HEAD**

Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=true`
Expected: `conclusion=success`. Branch `voice-apk-bin` now holds `wing-voice-unsigned.apk`,
`SHA256SUMS` and `SOURCE_COMMIT` = HEAD.

- [ ] **Step 2: Record the commit for the worker**

Run: `git rev-parse HEAD`
Note the hash in the card comment: "Probe-APK bereit: voice-apk-bin @ <hash>". No commit.

---

### Task 6 [WORKER]: Echo measurement on the device (gate for (b))

Done by the **Hermes worker** via `hadb`. Birk is needed for S2 (headset) and S3 (car). Feature (a)
(Tasks 8-9) does not wait for this task.

- [ ] **Step 1: Sign and install** the APK from `voice-apk-bin` using the sideload key (same procedure as
  every voice build). Check: `hadb shell dumpsys package com.tarkilhk.wing.voice | grep versionName`.
  Note versionName and `SOURCE_COMMIT`.
- [ ] **Step 2: Settings on the phone:** input "On this phone · Parakeet", Conversation mode on, "Debug
  recordings" on, Android voice = the normal SherpaTTS voice, speed Normal.
- [ ] **Step 3: Log forwarding check.** Run `hadb logcat -c`, tap "Measure speaker echo", wait 40 s,
  then `hadb logcat -d | grep WingBargeIn`.
  Expected: a `WingBargeIn listen close reason=probe` line and exactly one line
  `I flutter : WingBargeIn probe windows=… source=VOICE_COMMUNICATION` (no `listen open` line: the probe
  does not log one). If there is **no** line, release
  builds do not forward `debugPrint`. Stop and report it (the plan then needs a Kotlin `Log.i` bridge).
- [ ] **Step 4: Real audio source.** During a probe run: `hadb shell dumpsys audio | grep -i -A3 "rec"`.
  Note whether the active record source is VOICE_COMMUNICATION (source 7) or VOICE_RECOGNITION (6).
- [ ] **Step 5: S1 phone speaker.** Phone on the desk, quiet room, no headset. For volume
  `n` in {9, 15} (≈60 % and 100 % of 15 steps):
  `hadb shell cmd media_session volume --stream 3 --set <n>`, then three probe runs. Collect the 6
  `probe` lines.
- [ ] **Step 6: S2 headset** (Birk plugs in or pairs headphones): three probe runs at a normal volume.
- [ ] **Step 7: S3 car** (Birk in the parked car, engine idle, BT to the car speakers, normal volume):
  three probe runs. If `hadb` is unreachable from the car, Birk taps the button three times and the
  worker reads `hadb logcat -d | grep WingBargeIn` as soon as the phone is reachable. Check the log
  buffer reaches back far enough.
- [ ] **Step 8: Evaluate** per scenario with the spec §5.3 thresholds:
  - Pass: all runs `run50 ≤ 6` **and** `p99 < 0.5`.
  - Marginal: all runs `run50 ≤ 15` and `p99 < 0.75`.
  - Fail: anything else.
- [ ] **Step 9: Write the result** into `docs/VOICE_BARGE_IN.md` under "## Echo measurement" (create the
  file if Task 11 has not yet): date, versionName, SOURCE_COMMIT, real source, one table row per run
  (scenario, volume, the `probe` numbers), verdict per scenario. Numbers only; no audio files in the repo.
  Commit:
  `git add docs/VOICE_BARGE_IN.md`
  `git commit -m "docs(voice): echo measurement for barge-in"`
- [ ] **Step 10:** Delete the debug recordings on the phone (button "Delete debug recordings") and switch
  "Debug recordings" off again.

---

### Task 7: Apply the gate result

**Files:**
- Modify: `lib/voice_offline/barge_in_policy.dart` (constants only)
- Modify: `docs/VOICE_BARGE_IN.md` (decision line)

**Interfaces:** Produces final values of `bargeInPlaybackAvailable`, `bargeInPlaybackHint`,
`bargeGateThreshold`, `bargeGateWindows`.

- [ ] **Step 1: Pick the row** matching Task 6 (S1 = speaker, S3 = car):

| S1 | S3 | `bargeInPlaybackAvailable` | `bargeInPlaybackHint` | Gate constants |
|---|---|---|---|---|
| pass | pass | `true` | `null` | unchanged (0.7 / 16) |
| pass or marginal | pass or marginal, at least one marginal | `true` | `null` | formula below |
| any | fail | `true` | `'Best with headphones. In the car, use the media button.'` | formula below (S1 numbers) |
| fail | any | `false` | `null` | unchanged; (b) stays off (D2 option A) |

Formula (spec §4.2), from the worst S1/S3 run that passed or was marginal:
`bargeGateThreshold = max(0.7, ceil10(p99 + 0.15))` and
`bargeGateWindows = max(16, 2 × run70)`. `ceil10(x)` rounds up to one decimal. If the result has a
threshold > 0.9 or windows > 31, use the "fail" row for that scenario.

- [ ] **Step 2: Edit the constants** in `barge_in_policy.dart`. For example, for S1 marginal with
  p99 = 0.62 and run70 = 11: `const double bargeGateThreshold = 0.8;` and
  `const int bargeGateWindows = 22;`.
- [ ] **Step 3: Marginal re-check [WORKER]:** only if a marginal row was used. Build
  (`bash tools/factory/dispatch-check.sh voice-apk.yml publish=true`), then the worker repeats S1 (3
  runs). Every `probe` line must show `wouldTrigger=0`. If not, use the "fail" row.
- [ ] **Step 4:** Add the line "Decision: <row>, constants <values>" to `docs/VOICE_BARGE_IN.md`.
- [ ] **Step 5: Commit and run**

```
git add lib/voice_offline/barge_in_policy.dart docs/VOICE_BARGE_IN.md
git commit -m "feat(voice): barge-in gate from the echo measurement"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/barge_in_policy_test.dart`
Expected: `conclusion=success` (the bounds test still holds).

---

### Task 8: `BargeInCoordinator`

**Files:**
- Create: `lib/voice_offline/barge_in_coordinator.dart`
- Test: `test/voice_offline/barge_in_coordinator_test.dart`

**Interfaces:**
- Consumes: Task 2 `ListenChatState`, `ListenDelivery`, `decideDelivery`, `bargeLog`; Task 3 `TurnListener`.
- Produces:
  - `abstract interface class ListenTarget { ListenChatState get state; Future<bool> steer(String text); Future<void> queue(String text); Future<void> send(String text); }`
  - `class CallbackListenTarget implements ListenTarget` with constructor
    `CallbackListenTarget({required ListenChatState Function() readState, required Future<bool> Function(String) onSteer, required Future<void> Function(String) onQueue, required Future<void> Function(String) onSend})`
  - `class BargeInCoordinator extends ChangeNotifier` with:
    - `BargeInCoordinator(TurnListener listener)`
    - `TurnListener listener`, `Object? get chat`, `bool get listening`, `bool steered`
    - `void beginTurn()`
    - `Future<void> open(Object chat, ListenTarget target, VoicePreferences settings, {bool playback = false, Future<void> Function()? onBarge})`
    - `void setPlayback(bool playing)`, `Future<void> close(String reason)`, `Future<void> get settled`

- [ ] **Step 1: Write the failing test**

`test/voice_offline/barge_in_coordinator_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'package:wing/voice_offline/barge_in_coordinator.dart';
import 'package:wing/voice_offline/barge_in_policy.dart';
import 'package:wing/voice_offline/turn_listener.dart';
import '../support/voice_fixture.dart';

class _Target implements ListenTarget {
  ListenChatState current = ListenChatState.steerable;
  bool steerAnswer = true;
  ListenChatState? stateAfterSteer;
  final log = <String>[];

  @override
  ListenChatState get state => current;
  @override
  Future<bool> steer(String text) async {
    log.add('steer:$text');
    if (stateAfterSteer != null) current = stateAfterSteer!;
    return steerAnswer;
  }

  @override
  Future<void> queue(String text) async => log.add('queue:$text');
  @override
  Future<void> send(String text) async => log.add('send:$text');
}

const settings = VoicePreferences(input: VoiceInputRoute.vad, conversation: true);

void main() {
  late VoiceDeviceFixture device;
  late BargeInCoordinator coordinator;
  late _Target target;

  setUp(() async {
    device = VoiceDeviceFixture();
    coordinator = BargeInCoordinator(TurnListener(device: device));
    target = _Target();
    await coordinator.open('chat-a', target, settings);
  });
  tearDown(() async {
    coordinator.dispose();
    await device.stream.close();
  });

  Future<void> utter(String text) async {
    device.vadTranscript = text;
    device.emitWindows(List.filled(20, 0.9));
    device.emitWindows(List.filled(60, 0.1));
    await pumpEventQueue();
    await coordinator.settled;
  }

  test('a running turn is steered and remembered', () async {
    await utter('Testsatz eins');
    expect(target.log, ['steer:Testsatz eins']);
    expect(coordinator.steered, isTrue);
    coordinator.beginTurn();
    expect(coordinator.steered, isFalse);
  });

  test('a rejected steer on an ended turn becomes a normal prompt', () async {
    target.steerAnswer = false;
    target.stateAfterSteer = ListenChatState.idle;
    await utter('Testsatz zwei');
    expect(target.log, ['steer:Testsatz zwei', 'send:Testsatz zwei']);
    expect(coordinator.steered, isFalse);
  });

  test('a rejected steer on a still running turn is queued', () async {
    target.steerAnswer = false;
    await utter('Testsatz drei');
    expect(target.log, ['steer:Testsatz drei', 'queue:Testsatz drei']);
  });

  test('busy and idle chats queue or send directly', () async {
    target.current = ListenChatState.busy;
    await utter('Testsatz vier');
    target.current = ListenChatState.idle;
    await utter('Testsatz fünf');
    expect(target.log, ['queue:Testsatz vier', 'send:Testsatz fünf']);
  });

  test('fillers and empty transcripts are dropped', () async {
    await utter('ähm');
    await utter('  ');
    expect(target.log, isEmpty);
  });

  test('utterances are delivered one after another', () async {
    await utter('Testsatz sechs');
    await utter('Testsatz sieben');
    expect(target.log, ['steer:Testsatz sechs', 'steer:Testsatz sieben']);
  });

  test('close stops listening and forgets the target', () async {
    await coordinator.close('test');
    expect(coordinator.listening, isFalse);
    expect(coordinator.chat, isNull);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tools/factory/ci-suite.sh test/voice_offline/barge_in_coordinator_test.dart`
Expected: `conclusion=failure` (missing file).

- [ ] **Step 3: Implementation**

`lib/voice_offline/barge_in_coordinator.dart`:

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/services/voice_preferences.dart';
import 'barge_in_policy.dart';
import 'turn_listener.dart';

/// What the coordinator needs from one chat. The workspace screen adapts
/// its controller to this, so this file never imports the chat types.
abstract interface class ListenTarget {
  ListenChatState get state;

  /// True when the gateway queued the steer (`session.steer` → "queued").
  Future<bool> steer(String text);
  Future<void> queue(String text);

  /// Sends [text] as the conversation's next prompt.
  Future<void> send(String text);
}

class CallbackListenTarget implements ListenTarget {
  CallbackListenTarget({
    required this.readState,
    required this.onSteer,
    required this.onQueue,
    required this.onSend,
  });

  final ListenChatState Function() readState;
  final Future<bool> Function(String text) onSteer;
  final Future<void> Function(String text) onQueue;
  final Future<void> Function(String text) onSend;

  @override
  ListenChatState get state => readState();
  @override
  Future<bool> steer(String text) => onSteer(text);
  @override
  Future<void> queue(String text) => onQueue(text);
  @override
  Future<void> send(String text) => onSend(text);
}

/// Routes what the [listener] hears into one chat: steer while the turn
/// runs, otherwise queue or send (spec §4.3). Deliveries run one at a time.
class BargeInCoordinator extends ChangeNotifier {
  BargeInCoordinator(this.listener) {
    listener.onUtterance = _utterance;
    listener.addListener(notifyListeners);
  }

  final TurnListener listener;
  ListenTarget? _target;
  Object? _chat;
  Future<void> _deliveries = Future.value();

  /// A steer was accepted since [beginTurn]; the gateway may answer it with
  /// a follow-up turn after the current one (pending_steer).
  bool steered = false;

  Object? get chat => _chat;
  bool get listening => listener.isOpen;

  /// Completes when every delivery queued so far has finished.
  Future<void> get settled => _deliveries;

  /// The conversation sent a new prompt.
  void beginTurn() => steered = false;

  Future<void> open(
    Object chat,
    ListenTarget target,
    VoicePreferences settings, {
    bool playback = false,
    Future<void> Function()? onBarge,
  }) async {
    _chat = chat;
    _target = target;
    listener.onBarge = onBarge;
    await listener.open(settings, playback: playback);
  }

  void setPlayback(bool playing) => listener.setPlayback(playing);

  Future<void> close(String reason) async {
    _chat = null;
    _target = null;
    listener.onBarge = null;
    await listener.close(reason);
  }

  void _utterance(String text) {
    final target = _target;
    if (target == null) return;
    _deliveries = _deliveries
        .then((_) => _deliver(target, text))
        .catchError((Object _) => bargeLog('deliver failed'));
  }

  Future<void> _deliver(ListenTarget target, String text) async {
    var decision = decideDelivery(target.state, text);
    if (decision == ListenDelivery.steer) {
      if (await target.steer(text)) {
        steered = true;
        bargeLog('deliver kind=steer result=queued');
        return;
      }
      bargeLog('deliver kind=steer result=rejected');
      decision = decideDelivery(target.state, text, steerRejected: true);
    }
    switch (decision) {
      case ListenDelivery.drop:
        bargeLog(
          'deliver kind=drop result=${text.trim().isEmpty ? 'empty' : 'filler'}',
        );
      case ListenDelivery.queue:
        await target.queue(text);
        bargeLog('deliver kind=queue result=ok');
      case ListenDelivery.send:
        await target.send(text);
        bargeLog('deliver kind=send result=ok');
      case ListenDelivery.steer:
        // Unreachable: a rejected steer is re-decided with steerRejected.
        break;
    }
  }

  @override
  void dispose() {
    listener.removeListener(notifyListeners);
    listener.dispose();
    super.dispose();
  }
}
```

- [ ] **Step 4: Commit and run**

```
git add lib/voice_offline/barge_in_coordinator.dart test/voice_offline/barge_in_coordinator_test.dart
git commit -m "feat(voice): barge-in coordinator routes utterances to steer, queue or send"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/barge_in_coordinator_test.dart`
Expected: `conclusion=success`.

---

### Task 9: Screen hooks for (a) "listen while Hermes works"

**Files:**
- Modify: `lib/core/screens/profile_workspace_screen.dart`
- Modify: `test/support/profile_browser_fixture.dart` (`rpcResponses`)
- Test: `test/voice_workspace_test.dart` (append; adjust existing vad tests as described)

**Interfaces:**
- Consumes: Task 8 `BargeInCoordinator`, `CallbackListenTarget`; Task 3 `TurnListener`, `ListenPhase`;
  Task 2 `ListenChatState`; existing `controller.steer(chat, text, preserveComposer: true)`,
  `controller.queuePrompt(chat, text)`, `insertVoiceTranscript`, `_sendConversationTurn`, `_run`,
  `_runValue`.
- Produces (screen-private): `_bargeIn`, `_openListen(ProfileChat chat, {bool playback = false})`,
  `_listenTarget(ProfileChat chat)`, `_listenState(ProfileChat chat)`. UI text `Listening` and button
  `Stop listening` (key `voice-stop-listening`).

- [ ] **Step 1: Fixture support**

In `test/support/profile_browser_fixture.dart` add the field
`final rpcResponses = <String, Map<String, dynamic>>{};` next to the other public fields of
`ProfileBrowserFixture`. In the `rpc:` closure, directly before the final `return {};`, add:

```dart
      if (rpcResponses[method] case final response?) return response;
```

- [ ] **Step 2: Write the failing widget tests** (append inside `main()` of
  `test/voice_workspace_test.dart`, after the `windows` helper)

```dart
  Future<void> listenTurn(bool on) => controller.preferences.setString(
    VoicePreferences.listenTurnKey,
    on ? 'on' : 'off',
  );

  Future<void> vadConversationTurn(WidgetTester tester) async {
    await vadRoute();
    await conversationMode(true);
    await show(tester);
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    await windows(tester, 0.9, 30);
    await windows(tester, 0.1, 60);
    expect(prompts(), 1);
  }

  testWidgets('while Hermes works the microphone listens and steers', (
    tester,
  ) async {
    fixture.rpcResponses['session.steer'] = {
      'status': 'queued',
      'text': 'Testsatz eins',
    };
    await vadConversationTurn(tester);
    final chat = controller.current!.chat!;
    expect(chat.busy, isTrue);
    expect(vadStarts(), 2);
    expect(device.vadOptions!.keepPlayback, isTrue);
    expect(find.text('Listening'), findsOneWidget);
    device.vadTranscript = 'Testsatz eins';
    await windows(tester, 0.9, 30);
    await windows(tester, 0.1, 60);
    expect(
      fixture.calls.lastWhere((c) => c.$2 == 'session.steer').$3['text'],
      'Testsatz eins',
    );
    expect(prompts(), 1);
    expect(chat.messages.last['display_kind'], 'steer');
    expect(vadStarts(), 3);
    await completeReply(tester, 'Fertig.');
    expect(find.text('Listening'), findsNothing);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
  });

  testWidgets('words spoken as the turn ends become the next prompt (D3)', (
    tester,
  ) async {
    await vadConversationTurn(tester);
    device.vadTranscript = 'Testsatz zwei';
    await windows(tester, 0.9, 30);
    // The turn completes while the user is still speaking.
    await completeReply(tester, 'Antwort eins.');
    expect(device.spoken, isNull);
    await windows(tester, 0.1, 60);
    expect(prompts(), 2);
    expect(
      fixture.calls.lastWhere((c) => c.$2 == 'prompt.submit').$3['text'],
      'Testsatz zwei',
    );
    await tester.tap(find.text('Stop listening'));
    await settle(tester);
  });

  testWidgets('Stop listening closes the round but keeps the conversation', (
    tester,
  ) async {
    await vadConversationTurn(tester);
    await tester.tap(find.text('Stop listening'));
    await settle(tester);
    expect(find.text('Listening'), findsNothing);
    await completeReply(tester, 'Antwort.');
    expect(device.spoken, 'Antwort.');
    expect(find.textContaining('Recording ·'), findsOneWidget);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
  });

  testWidgets('an approval ends the conversation and the listen round', (
    tester,
  ) async {
    await vadConversationTurn(tester);
    gatewayEvent('approval', {'request_id': 'approve-1', 'command': 'rm -rf build'});
    await settle(tester);
    expect(find.text('Listening'), findsNothing);
    expect(device.cancelled, isNotEmpty);
  });

  testWidgets('listening is off with the setting off', (tester) async {
    await listenTurn(false);
    await vadConversationTurn(tester);
    expect(vadStarts(), 1);
    expect(find.text('Listening'), findsNothing);
    await completeReply(tester);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
  });

  testWidgets('media key ends a listen utterance and steers it', (tester) async {
    fixture.rpcResponses['session.steer'] = {'status': 'queued', 'text': 'x'};
    await vadConversationTurn(tester);
    device.vadTranscript = 'Testsatz drei';
    await windows(tester, 0.9, 30);
    device.emitMediaKey();
    await settle(tester);
    expect(
      fixture.calls.lastWhere((c) => c.$2 == 'session.steer').$3['text'],
      'Testsatz drei',
    );
    await tester.tap(find.text('Stop listening'));
    await settle(tester);
  });
```

**Existing tests:** `vad conversation sends after the pause` and
`media key ends a vad round and sends it in conversation mode` count `vadStarts()` or
`device.finishes` around an auto-send. Add `await listenTurn(false);` as their first line. Do the same
for any other pre-existing vad conversation test that fails **only** on startVad/finishVad counts.
Never change other assertions. The `listenTurn` helper must be declared above these tests; move it next
to `vadRoute()`.

- [ ] **Step 3: Run to verify failure**

Run: `bash tools/factory/ci-suite.sh test/voice_workspace_test.dart`
Expected: `conclusion=failure` ("Listening" not found).

- [ ] **Step 4: Screen hooks**

All edits are in `lib/core/screens/profile_workspace_screen.dart`.

4a. Imports (with the other imports):

```dart
import '../../voice_offline/barge_in_coordinator.dart';
import '../../voice_offline/barge_in_policy.dart';
import '../../voice_offline/turn_listener.dart';
```

4b. Field, directly after the `late final _voiceOutput = VoiceOutputController(…);` declaration:

```dart
  /// Listen rounds while Hermes works (spec 2026-10-14 barge-in).
  late final _bargeIn = BargeInCoordinator(
    TurnListener(device: widget.voiceDevice ?? AndroidVoice.instance),
  );
```

4c. `_conversation` setter. Replace its body with:

```dart
  set _conversation(ProfileSessionKey? value) {
    if ((_conversationKey == null) != (value == null)) {
      VoiceSwitchHolders.screenOn(_voiceDevice).set(this, value != null);
    }
    if (value != _conversationKey) {
      unawaited(_bargeIn.close('conversationEnd').catchError((Object _) {}));
    }
    _conversationKey = value;
  }
```

4d. New helpers, directly below `_cancelVoice()`:

```dart
  ListenChatState _listenState(ProfileChat chat) => switch (chat.status) {
    ProfileTurnStatus.running ||
    ProfileTurnStatus.attention => ListenChatState.steerable,
    ProfileTurnStatus.submitting ||
    ProfileTurnStatus.reconnecting => ListenChatState.busy,
    _ => ListenChatState.idle,
  };

  ListenTarget _listenTarget(ProfileChat chat) => CallbackListenTarget(
    readState: () => _listenState(chat),
    onSteer: (text) async =>
        await _runValue(
          () => controller.steer(chat, text, preserveComposer: true),
        ) ==
        true,
    onQueue: (text) => _run(() => controller.queuePrompt(chat, text)),
    onSend: (text) async {
      if (!mounted || _conversation != chat.key) return;
      final value = insertVoiceTranscript(_composer.value, text);
      _composer.value = value;
      await _run(() async {
        await controller.updateDraft(chat, value.text);
        await _sendConversationTurn(chat);
      });
    },
  );

  /// Opens a listen round for the conversation's chat (vad route only).
  void _openListen(ProfileChat chat, {bool playback = false}) {
    final VoicePreferences settings;
    try {
      settings = VoicePreferences.read(controller.preferences);
    } on FormatException {
      return;
    }
    if (!mounted ||
        _conversation != chat.key ||
        settings.input != VoiceInputRoute.vad ||
        !settings.conversation ||
        !(settings.listenTurn || playback)) {
      return;
    }
    unawaited(
      _bargeIn
          .open(
            chat.key,
            _listenTarget(chat),
            settings,
            playback: playback,
            onBarge: _voiceOutput.stop,
          )
          .catchError((Object _) {}),
    );
  }
```

If `_runValue`'s return type is not nullable `Future<T?>`, adapt the comparison to its actual signature
(`git grep -n "Future<T?> _runValue\|_runValue<" -- lib/core/screens/profile_workspace_screen.dart`).

4e. `_sendConversationTurn`. Insert at the top of the method body, directly after
`final text = chat.draft.trim();`:

```dart
    // A hands-free utterance that lands on a running turn steers it (also
    // covers a follow-up turn started by the gateway after a steer).
    if (mounted &&
        _conversation == chat.key &&
        text.isNotEmpty &&
        !text.startsWith('/') &&
        _listenState(chat) == ListenChatState.steerable) {
      final accepted = await _runValue(() => controller.steer(chat, text));
      if (accepted == true) {
        _composer.clear();
        await _run(() => controller.updateDraft(chat, ''));
        _openListen(chat);
        return;
      }
    }
```

Then, directly after `_conversationAwaitingReply = true;`, add `_bargeIn.beginTurn();`. After the
`await _performComposerAction(chat, ComposerAction.send, conversation: true);` statement, add:

```dart
    if (chat.busy) _openListen(chat);
```

4f. `_speakCompletedReply`. Directly after the line `_conversationAwaitingReply = false;` insert:

```dart
    if (_bargeIn.chat == chat.key && _bargeIn.listener.speechInProgress) {
      // D3: the user is already talking; the reply stays in the chat and
      // the utterance becomes the next prompt.
      return;
    }
    unawaited(_bargeIn.close('turnEnd').catchError((Object _) {}));
```

In the same method, inside the `unawaited(() async { … }())` block, directly before
`if (_canContinueConversation(chat)) {`, insert:

```dart
      if (_conversation == chat.key && chat.busy && _bargeIn.steered) {
        // The gateway runs a steer that arrived during the final answer as a
        // follow-up turn; its reply belongs to this conversation.
        _conversationAwaitingReply = true;
        _openListen(chat);
        return;
      }
```

4g. `_dictate`. Directly after `await _voiceOutput.stop();` add:

```dart
    await _bargeIn.close('dictate');
```

4h. `_voiceDeviceEvent`. Directly after the `if (_vadRoute() != true) { return; }` block add:

```dart
    if (_bargeIn.listening && _voiceOutput.owner == null) {
      unawaited(_bargeIn.listener.endUtterance());
      return;
    }
```

4i. `_voiceActivity()`. As the first entry of `children: [`:

```dart
      if (_bargeIn.listening && !_voiceInput.active)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Semantics(
                liveRegion: true,
                child: Text(
                  _bargeIn.listener.phase == ListenPhase.transcribing
                      ? 'Transcribing…'
                      : 'Listening',
                ),
              ),
              TextButton(
                key: const ValueKey('voice-stop-listening'),
                onPressed: () => unawaited(_bargeIn.close('stopButton')),
                child: const Text('Stop listening'),
              ),
            ],
          ),
        ),
```

4j. Rebuilds: change `Listenable.merge([controller, _voiceInput, _voiceOutput])` to
`Listenable.merge([controller, _voiceInput, _voiceOutput, _bargeIn])`.

4k. `dispose()`: directly after `_voiceOutput.dispose();` add `_bargeIn.dispose();`.

- [ ] **Step 5: Commit and run**

```
git add lib/core/screens/profile_workspace_screen.dart test/support/profile_browser_fixture.dart test/voice_workspace_test.dart
git commit -m "feat(voice): listen while Hermes works and steer the running turn"
```

Run: `bash tools/factory/ci-suite.sh test/voice_workspace_test.dart`
Expected: `conclusion=success`. If one of the new tests fails because of the fixture (for example
`chat.busy` false after the send), fix the hook rather than the expectation, and report the cause in the
commit message.

---

### Task 10: Screen hooks for (b) barge-in during read-aloud

Do this task only if Task 7 set `bargeInPlaybackAvailable = true`. Otherwise skip it and note "(b) not
built: echo gate failed (D2 A)" in `docs/VOICE_BARGE_IN.md`.

**Files:**
- Modify: `lib/core/screens/profile_workspace_screen.dart` (`_speakCompletedReply` only)
- Test: `test/voice_workspace_test.dart` (append)

**Interfaces:** Consumes Task 9 `_openListen(chat, playback: true)`, `_bargeIn.setPlayback`,
`VoicePreferences.bargeInPlayback`, `bargeInPlaybackAvailable`.

- [ ] **Step 1: Write the failing tests**

```dart
  Future<void> bargeInPlayback(bool on) => controller.preferences.setString(
    VoicePreferences.bargeInPlaybackKey,
    on ? 'on' : 'off',
  );

  testWidgets('speaking during read-aloud stops it and sends the words', (
    tester,
  ) async {
    await bargeInPlayback(true);
    device.playbackDelay = Completer<void>();
    await vadConversationTurn(tester);
    gatewayEvent('message.complete', {'text': 'Lange Antwort.'});
    await settle(tester);
    expect(device.spoken, 'Lange Antwort.');
    expect(find.text('Listening'), findsOneWidget);
    // speak() itself may call stopPlayback first; count only later calls.
    final stopsBefore = device.calls.where((c) => c == 'stopPlayback').length;
    device.vadTranscript = 'Testsatz zwei, stopp';
    await windows(tester, 0.95, 40);
    expect(
      device.calls.where((c) => c == 'stopPlayback').length,
      greaterThan(stopsBefore),
    );
    device.playbackDelay!.complete();
    device.playbackDelay = null;
    await windows(tester, 0.1, 60);
    expect(prompts(), 2);
    expect(
      fixture.calls.lastWhere((c) => c.$2 == 'prompt.submit').$3['text'],
      'Testsatz zwei, stopp',
    );
    await tester.tap(find.text('Stop listening'));
    await settle(tester);
  });

  testWidgets('a cough during read-aloud changes nothing', (tester) async {
    await bargeInPlayback(true);
    device.playbackDelay = Completer<void>();
    await vadConversationTurn(tester);
    gatewayEvent('message.complete', {'text': 'Lange Antwort.'});
    await settle(tester);
    final stopsBefore = device.calls.where((c) => c == 'stopPlayback').length;
    await windows(tester, 0.8, 14);
    await windows(tester, 0.1, 60);
    expect(device.calls.where((c) => c == 'stopPlayback').length, stopsBefore);
    expect(prompts(), 1);
    device.playbackDelay!.complete();
    device.playbackDelay = null;
    await settle(tester);
    // Read-aloud ended normally: the open round now listens for the next prompt.
    expect(find.text('Listening'), findsOneWidget);
    await tester.tap(find.text('Stop listening'));
    await settle(tester);
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tools/factory/ci-suite.sh test/voice_workspace_test.dart`
Expected: `conclusion=failure`.

- [ ] **Step 3: Implementation** in `_speakCompletedReply`

Replace the line added in Task 9 Step 4f
`unawaited(_bargeIn.close('turnEnd').catchError((Object _) {}));` with:

```dart
    if (settings.bargeInPlayback &&
        bargeInPlaybackAvailable &&
        _conversation == chat.key) {
      _openListen(chat, playback: true);
    } else {
      unawaited(_bargeIn.close('turnEnd').catchError((Object _) {}));
    }
```

Inside the `unawaited(() async { … }())` block, replace

```dart
      if (!finished) {
        // Stop speech, a newer playback or a failure ends the conversation,
        // unless the user already tapped the microphone again.
        if (!_voiceInput.active) _conversation = null;
        return;
      }
```

with:

```dart
      if (!finished) {
        // Stop speech, a newer playback or a failure ends the conversation,
        // unless the user already tapped the microphone again or a barge-in
        // stopped the reply (its listen round keeps the conversation).
        if (!_voiceInput.active && !_bargeIn.listening) _conversation = null;
        return;
      }
      if (_bargeIn.listening && _bargeIn.chat == chat.key) {
        // Read-aloud ended: the open round now uses the normal rules and
        // replaces the reopened dictation.
        _bargeIn.setPlayback(false);
        if (chat.busy) _conversationAwaitingReply = true;
        return;
      }
```

- [ ] **Step 4: Commit and run**

```
git add lib/core/screens/profile_workspace_screen.dart test/voice_workspace_test.dart
git commit -m "feat(voice): barge-in during read-aloud behind the echo gate"
```

Run: `bash tools/factory/ci-suite.sh test/voice_workspace_test.dart`
Expected: `conclusion=success`.

---

### Task 11: Documentation, full suite, build

**Files:**
- Create or extend: `docs/VOICE_BARGE_IN.md`

- [ ] **Step 1: Write `docs/VOICE_BARGE_IN.md`.** Keep the "Echo measurement" section from Tasks 6/7 and
  add above it:
  - "What it does": (a) and (b) in five lines each, plus D1-D3 as currently assumed.
  - "Settings": the three keys, defaults and choices from Global Constraints.
  - "Gateway": `session.steer` statuses (`queued`, `rejected`, compression → queued as a prompt) and the
    follow-up turn for a steer during the final answer, with Hermes upstream commit `e06df9c2`.
  - "Log lines": the block from spec §7 verbatim.
  - "Limits": a steer during a long tool waits for that tool; a compression-queued text shows as a steer
    row; a dropped cough still plays the "got it" tone; the probe logs the configured source.
- [ ] **Step 2: Commit**

```
git add docs/VOICE_BARGE_IN.md
git commit -m "docs(voice): barge-in behaviour, settings and logs"
```

- [ ] **Step 3: Full suite**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`.

- [ ] **Step 4: Phone build**

Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=true`
Expected: `conclusion=success`. Note `git rev-parse HEAD` in the card comment as "Abnahme-APK".

---

### Task 12: Rendered review (light/dark, 100 %/200 % text)

**Files:**
- Modify: `test/voice_workspace_test.dart`, `test/voice_preferences_test.dart` (render-only tests)

- [ ] **Step 1: Add render tests**

In `test/voice_workspace_test.dart`:

```dart
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('listening row renders in $brightness at ${scale}x', (
        tester,
      ) async {
        await vadRoute();
        await conversationMode(true);
        await show(tester, brightness: brightness, scale: scale);
        await tester.tap(find.byTooltip('Dictate message'));
        await tester.pump();
        await windows(tester, 0.9, 30);
        await windows(tester, 0.1, 60);
        expect(find.text('Stop listening'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await screenshot(
          tester,
          'listen-${brightness.name}-${(scale * 100).round()}',
        );
        await tester.tap(find.text('Stop listening'));
        await settle(tester);
      });
    }
  }
```

In `test/voice_preferences_test.dart`:

```dart
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('barge-in settings render in $brightness at ${scale}x', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 800);
        addTearDown(tester.view.reset);
        final prefs = await vadConversation();
        await prefs.setString(VoicePreferences.vadDebugKey, 'on');
        final device = VoiceDeviceFixture();
        addTearDown(device.stream.close);
        await show(tester, prefs, device, brightness: brightness, scale: scale);
        await tester.ensureVisible(find.text('Listen while Hermes works'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await screenshot(
          tester,
          'barge-settings-${brightness.name}-${(scale * 100).round()}',
        );
      });
    }
  }
```

- [ ] **Step 2: Commit and render**

```
git add test/voice_workspace_test.dart test/voice_preferences_test.dart
git commit -m "test(voice): render barge-in rows for review"
```

Run: `bash tools/factory/dispatch-check.sh voice-review.yml`
Expected: `conclusion=success`. Branch `voice-review-bin` holds the PNGs.

- [ ] **Step 3: Inspect** (one command each):

```
git fetch -q origin voice-review-bin
mkdir -p build/wing-review
git show origin/voice-review-bin:listen-light-100.png > build/wing-review/listen-light-100.png
git show origin/voice-review-bin:listen-dark-200.png > build/wing-review/listen-dark-200.png
git show origin/voice-review-bin:barge-settings-light-100.png > build/wing-review/barge-settings-light-100.png
git show origin/voice-review-bin:barge-settings-dark-200.png > build/wing-review/barge-settings-dark-200.png
```

(`build/` is git-ignored and inside the worktree.)

Open each PNG with the Read tool. Also fetch and open the other four (`listen-dark-100`,
`listen-light-200`, `barge-settings-dark-100`, `barge-settings-light-200`).

Check against `docs/DESIGN_SYSTEM.md` (charter §"Layout and controls", §"Selection controls"):
- The listening row is one line at 100 % and does not wrap the button under the text at 200 % in a
  way that hides it.
- "Stop listening" reaches 48 dp.
- The switch rows use the compact switch.
- No extra headings or cards.
- Contrast is fine in dark mode.

Fix what looks wrong, commit, render again.

---

### Task 13 [WORKER]: Install, on-device look, CPU

- [ ] **Step 1:** Sign and install the Task 11 APK. Check `versionName` and `SOURCE_COMMIT` as in
  Task 6.
- [ ] **Step 2: Screenshots** at normal text size and with Android font size at maximum
  (`hadb shell settings put system font_scale 1.3`; restore to `1.0` afterwards), light and dark
  (`hadb shell cmd uimode night yes|no`).
  - Voice settings with the new rows.
  - A chat during a listen round (start a synthetic turn: `Führe im Terminal "sleep 25" aus und
    antworte dann nur mit "fertig".`).

  Capture with `hadb exec-out screencap -p > <file>`. Check the same points as Task 12. Do not store
  the screenshots in the repo, since they show the chat list.
- [ ] **Step 3: CPU during a listen round:** while the synthetic sleep turn runs and nobody speaks:
  `hadb shell top -b -n 5 -d 2 | grep com.tarkilhk.wing.voice`. Expected: the average `%CPU` is < 10
  (one core = 100). Record the value in `docs/VOICE_BARGE_IN.md` under "Battery". Above 10: report it;
  do not tune on your own.

---

### Task 14 [WORKER + Birk]: On-device acceptance

Birk speaks; the worker drives `hadb` and collects logs. Settings: vad route, Conversation mode on,
"Listen while Hermes works" on. "Interrupt read-aloud by speaking" is on only if Task 10 was built.
`hadb logcat -c` before each scenario, `hadb logcat -d | grep WingBargeIn` after it.

- [ ] **Scenario 1: steer.** Birk dictates the synthetic prompt
  `Führe im Terminal "sleep 25" aus und antworte dann nur mit "fertig" und dem heutigen Datum, falls ich
  danach frage.` and pauses. During the sleep he says: "Testsatz eins, bitte nenne zusätzlich das heutige
  Datum".
  Pass:
  - logcat contains `WingBargeIn listen open mode=turn`, `WingBargeIn utterance segmentMs=… textLen=…`
    and `WingBargeIn deliver kind=steer result=queued`;
  - the chat shows a steer row;
  - the final reply contains a date.
- [ ] **Scenario 2: barge-in** (only if Task 10 was built). Synthetic prompt `Zähle langsam in Worten
  von eins bis vierzig.` While the reply is read aloud, Birk says "Testsatz zwei, stopp".
  Pass:
  - `WingBargeIn barge trigger sinceOnsetMs=<n> stopMs=<m>` with `n ≤ 1200`;
  - TTS audibly stops;
  - then `deliver kind=send result=ok`.
- [ ] **Scenario 3: cough.**
  - (3a) During read-aloud of the scenario 2 prompt (only if Task 10 was built), Birk coughs three
    times, about 5 s apart. Pass: no `barge trigger` line, and TTS reads to the end.
  - (3b) During a scenario 1 sleep turn, Birk coughs three times. Pass: at most
    `deliver kind=drop` lines, no `deliver kind=steer`.
- [ ] **Scenario 4: turn end while speaking.** During scenario 1, Birk starts talking about 1 s before
  "fertig" appears. Pass: the reply is not read aloud (D3), and his words arrive as the next prompt
  (`deliver kind=send` or `kind=steer`, depending on timing).
- [ ] **Scenario 5: approval.** Synthetic prompt `Lösche die Datei /tmp/wing-barge-test.txt mit rm.`
  When the approval appears: the "Listening" row disappears, and logcat shows
  `listen close reason=conversationEnd`.
- [ ] **Evidence:** paste the logcat lines (they contain no text content) into the card comment, with
  versionName, SOURCE_COMMIT, date and the scenario verdicts.
- [ ] **Birk's confirmation:** Birk writes in his own words on the card whether it works as he wished.
  Then record his answers to D1-D3 (spec "Open decisions for Birk") on the card. Any answer that differs
  from the assumption becomes a follow-up card.

---

## Self-review notes (plan author)

- Spec coverage:
  - §3.2 → Tasks 3, 8, 9
  - §3.3 → Task 9 (4e busy→steer, 4f follow-up)
  - §3.4 → Tasks 1, 3, 10
  - §3.5 → Task 9 (setter, media key, Stop listening); keep-screen-on unchanged
  - §4 → Task 2
  - §5 → Tasks 3, 4, 6, 7
  - §6 → Tasks 4, 9, 12, 13
  - §7 → Tasks 3, 8, 14
  - §8 → file map
  - §9 → Task 0
- Known fixture risk: `VoiceDeviceFixture.startVad` resets `_firstWindow`. Listen rounds rely on
  `first` restarting at 0 per round, which matches native behaviour (`VadCapture.readLoop` starts
  `first = 0` per round).

# Wing Voice Bluetooth Headset Microphone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Explicit vad recordings use the connected Bluetooth headset's microphone (WH-1000XM4 via SCO) instead of the phone mic. Wing also reads the Bluetooth class again, which fixes `bluetoothClassUnknown`.

**Architecture:** A new native unit `HeadsetMicRoute` (package `voiceoffline`) decides at round start, from fresh facts, which mic to use. When the answer is the headset, it requests the link with `AudioManager.setCommunicationDevice` and pins the `AudioRecord` with `setPreferredDevice`. It clears the request on every exit path. Dart marks listen rounds as `mic: phone` (decision E1 = A), and car mode holds a "phone mic only" switch (E2 = 1). "Nearby devices" is requested once, at the first recording with a Bluetooth audio device connected (E3 = a).

**Tech Stack:** Flutter/Dart (`lib/voice_offline`, `lib/core/services/android_voice.dart`), Kotlin (`android/.../voiceoffline`, `VadCapture.kt`, `VoiceChannel.kt`), Android `AudioManager` communication-device API (API 31+), Python 3 (`tools/voice/wer.py`).

**Spec:** `docs/superpowers/specs/2026-10-16-wing-voice-bt-headset-mic-design.md` (commit `b35b4434`).

## Global Constraints

- Rule (supersedes 13.10.): **"Mikro des verbundenen Headsets, wenn vorhanden, sonst Handy."** No microphone switch in the app.
- Client-only. No Hermes API is involved, no backend change.
- New logic lives in `lib/voice_offline/` and `com.tarkilhk.wing.voiceoffline`. Other files get thin hooks only.
  `lib/core/controllers/voice_input_controller.dart` and `android/.../VoicePlayback.kt` are **not touched**.
- Headset mic only for explicit rounds (`mic: auto`). Listen rounds and the echo probe use `mic: phone` (E1 = A).
- Car: phone mic (E2 = 1). Detection: Wing car mode holder, Android car mode, or a non-headset Bluetooth class.
- Headset classes: `0x0404` (WEARABLE_HEADSET) and `0x0418` (HEADPHONES). Unknown class means phone mic.
- No `setMode(MODE_IN_COMMUNICATION)`. That stays true unless Task 10 proves it is needed (then Task 13).
  `BackgroundVoiceService.watchCalls` would end Wing's own conversation on that mode.
- Link timeout `2500 ms`, then fall back to the phone mic.
- Permission request code `7316`. SharedPreferences file `wing_voice_route`, key `bt_connect_asked`.
- Logs: Kotlin tag `WingMic` (`android.util.Log.i`) and Dart prefix `WingBargeIn` (existing). Numbers, types and
  reasons only. **Never** transcript text, Bluetooth addresses or device names.
- Measurement texts are synthetic. Pulled files go to `build/voice-measure/` or `build/voice-debug/` (git-ignored)
  and are deleted after scoring.
- One command per Bash call. No `cd`, no `&&`/`;`, no `$VAR`, no `$( )`.
- Suite: `bash tools/factory/ci-suite.sh <test path>`. The script ignores the path argument and runs flutter analyze
  plus the whole flutter test on GitHub Actions for the committed HEAD, so commit first. Expected last line:
  `ci-suite: run <id> conclusion=success …`.
- Kotlin compile: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`. Expected last line:
  `dispatch-check: voice-apk.yml run <id> conclusion=success …`.
- Phone steps (`hadb`, install, measurement) are done by the **Hermes worker**, never by a Claude Code subagent
  ([WORKER] / [WORKER + Birk]).
- Commit after every task on the working branch. No merge, no push except what the two factory scripts do.

## Dependency on barge-in part (b) (sibling t_98e8c3c2)

The sibling coder card works in `.worktrees/t_98e8c3c2` (branch `wt/t_98e8c3c2`, head `e6880010` on 16.10.). It
adds `HeadphoneRoute.wired` and a "wired only" subtitle. Files where this plan would collide:

| File | Sibling | This plan |
|---|---|---|
| `lib/voice_offline/headphone_route.dart` | `wired` getter | Task 1 |
| `test/voice_offline/headphone_route_test.dart` | new test | Task 1 |
| `test/support/headphone_route_fixture.dart` | possibly | Task 1 (reads only) |
| `android/.../voiceoffline/HeadphoneRouteChannel.kt` | possibly | Task 1 |
| `lib/voice_offline/turn_listener.dart` | barge-in Tasks 10/17 | Task 2 |
| `test/voice_offline/turn_listener_test.dart` | barge-in Tasks 10/17 | Task 2 |

**All code tasks start after t_98e8c3c2 is merged into `voice-offline`** (Task 0 checks this). Never edit inside
`.worktrees/t_98e8c3c2`. Tasks 6 (script) and 9 (baseline measurement) do not touch those files and may run before
the merge.

## Task order

```
0 → 1 → 2 → 3 → 4 → 5 → 7 → 8 [WORKER] → 10 [WORKER + Birk] → 11 → (13 only if Task 10 "mic proof" fails) → 12 [WORKER + Birk]
6 (wer.py) — any time; needed by 9 and 10
9 [WORKER + Birk] baseline — any time after 6, runs on the installed 1.1.3
```

## Decision impact (spec §9; the plan implements the recommendations A, 1, a)

| Birk picks | Change to this plan |
|---|---|
| E1 = B | Task 2 passes `mic: auto` for listen rounds, and a new design card handles the re-acquire when read-aloud starts. Stop after Task 1 and ask. |
| E1 = C | New spec: SCO held across read-aloud, new echo series. Stop after Task 1. |
| E2 = 2 | Skip Task 3. In Task 4, `decide()` drops the `androidCarMode` and `notHeadset` checks for classes `0x0408`/`0x0420`. |
| E2 = 3 | As E2 = 1, plus a later device card (car drive, WER phone vs car mic). |
| E3 = b | In Task 5, drop the `needsPermission`/`requestOnce` step. In Task 4, `decide()` treats `noPermission`/`classUnknown` as headset unless car mode applies. |
| E3 = c | UI work: run the AGENTS.md design process first. A new task adds a settings row that calls `requestBluetooth`. Task 5 drops its own request. |

## File map

| File | Status | Task |
|---|---|---|
| `lib/voice_offline/headphone_route.dart` | change | 1 |
| `android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/HeadphoneRouteChannel.kt` | hook | 1 |
| `test/voice_offline/headphone_route_test.dart` | change | 1 |
| `lib/core/services/android_voice.dart` | hook | 2, 3 |
| `test/support/voice_fixture.dart` | change | 2, 3 |
| `lib/voice_offline/turn_listener.dart` | hook | 2 |
| `test/voice_offline/vad_capture_options_test.dart`, `test/voice_offline/turn_listener_test.dart` | change | 2 |
| `lib/car_mode/car_mode_session.dart` | hook | 3 |
| `test/car_mode/car_mode_session_test.dart` | change | 3 |
| `android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/HeadsetMicRoute.kt` | new | 4 |
| `android/app/src/main/AndroidManifest.xml` | hook | 4 |
| `android/app/src/main/kotlin/com/tarkilhk/wing/VadCapture.kt` | hook | 5 |
| `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt` | hook | 5 |
| `tools/voice/wer.py`, `tools/voice/headset_mic_reference.txt` | new | 6 |
| `docs/VAD_INPUT.md` | change | 7, 11 |

---

### Task 0: Basis check (no code)

**Files:** none.

- [ ] **Step 1: Sibling merged.** Run: `git log --oneline -30 voice-offline`
  Expected: a merge line naming `t_98e8c3c2`. If it is missing: stop and report "waiting for t_98e8c3c2". Only Task 6
  may run in the meantime.
- [ ] **Step 2: Hook anchors still match.** Run: `git grep -n "fun start(id: String, options: Options)" -- android/app/src/main/kotlin/com/tarkilhk/wing/VadCapture.kt`
  Expected: one hit. Run: `git grep -n "private fun start(call: MethodCall" -- android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt`
  Expected: one hit. Run: `git grep -n "reason: 'bluetoothClassUnknown'" -- lib/voice_offline/headphone_route.dart`
  Expected: one hit. If any anchor moved, adapt the edit locations below; do not change the interfaces.
- [ ] **Step 3: Read the sibling's merged changes** to `headphone_route.dart`, `headphone_route_test.dart` and
  `turn_listener.dart`. Keep its `wired` getter and tests untouched.

---

### Task 1: Tell "no permission" apart from "class unknown" (spec §3 F2)

**Files:**
- Modify: `lib/voice_offline/headphone_route.dart` (`OutputRoute`, `classifyRoute`, `routeLogLine`)
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/HeadphoneRouteChannel.kt` (`current()`, new `refresh()`)
- Test: `test/voice_offline/headphone_route_test.dart`

**Interfaces:**
- Produces: `OutputRoute.bluetoothAllowed` (`bool`, default `true`, map key `bluetoothAllowed`). Reason
  `'bluetoothNoPermission'`. Log suffix ` perm=0|1`. Kotlin `HeadphoneRouteChannel.refresh()` (public, pushes
  `changed`), used by Task 5.

- [ ] **Step 1: Write the failing tests.** In `test/voice_offline/headphone_route_test.dart`, add this row to `cases`
  directly after `('LE headset class unknown', …)`:

```dart
      ('A2DP without Nearby devices', OutputRoute(supported: true, type: 8, bluetoothAllowed: false), false, false, 'bluetoothNoPermission'),
```

Replace the two log expectations in `'the route log line carries numbers only'` with:

```dart
      'route headphones=1 reason=bluetoothHeadphones type=8 btClass=0x0418 androidCarMode=0 perm=1',
```

```dart
      'route headphones=0 reason=speaker type=2 btClass=none androidCarMode=0 perm=1',
```

Add at the end of `'OutputRoute reads the channel map'`:

```dart
    expect(route.bluetoothAllowed, isTrue);
    expect(
      OutputRoute.fromMap({'supported': true, 'type': 8, 'bluetoothAllowed': false}).bluetoothAllowed,
      isFalse,
    );
```

- [ ] **Step 2: Commit the tests and run the suite to see them fail.**

```
git add test/voice_offline/headphone_route_test.dart
git commit -m "test(voice): route verdict separates missing Nearby devices access"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/headphone_route_test.dart`
Expected: `conclusion=failure` (the named parameter `bluetoothAllowed` does not exist).

- [ ] **Step 3: Implement in Dart.** In `lib/voice_offline/headphone_route.dart`:

Constructor and factory of `OutputRoute`:

```dart
  const OutputRoute({
    required this.supported,
    required this.type,
    this.bluetoothClass,
    this.androidCarMode = false,
    this.bluetoothAllowed = true,
  });

  factory OutputRoute.fromMap(Map<Object?, Object?> map) => OutputRoute(
    supported: map['supported'] == true,
    type: (map['type'] as num?)?.toInt() ?? 0,
    bluetoothClass: (map['bluetoothClass'] as num?)?.toInt(),
    androidCarMode: map['androidCarMode'] == true,
    bluetoothAllowed: map['bluetoothAllowed'] != false,
  );
```

Field, below `final bool androidCarMode;`:

```dart
  /// Wing holds Nearby devices access (always true below Android 12).
  final bool bluetoothAllowed;
```

In `classifyRoute`, replace the `deviceClass == null` branch:

```dart
    if (deviceClass == null) {
      return (
        headphones: false,
        reason: route.bluetoothAllowed
            ? 'bluetoothClassUnknown'
            : 'bluetoothNoPermission',
      );
    }
```

In `routeLogLine`, replace the last line:

```dart
      'androidCarMode=${route.androidCarMode ? 1 : 0} '
      'perm=${route.bluetoothAllowed ? 1 : 0}';
```

- [ ] **Step 4: Implement in Kotlin.** In `HeadphoneRouteChannel.kt`, add to the map returned by `current()`
  after `"androidCarMode" to …`:

```kotlin
            "bluetoothAllowed" to bluetoothAllowed(),
```

Replace `private fun changed() { channel.invokeMethod("changed", current()) }` with:

```kotlin
    private fun changed() { channel.invokeMethod("changed", current()) }

    /** Nearby devices access changed elsewhere (HeadsetMicRoute): push the route again. */
    fun refresh() = changed()
```

- [ ] **Step 5: Commit and run.**

```
git add lib/voice_offline/headphone_route.dart android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/HeadphoneRouteChannel.kt
git commit -m "feat(voice): route log names missing Nearby devices access (perm=0)"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/headphone_route_test.dart`
Expected: last line `ci-suite: run <id> conclusion=success …`.

---

### Task 2: `mic` capture option; listen rounds stay on the phone mic (E1 = A)

**Files:**
- Modify: `lib/core/services/android_voice.dart` (`VadCaptureOptions` :173-202, new enum `VadMic`)
- Modify: `lib/voice_offline/turn_listener.dart` (`_startRound`, the `VadCaptureOptions(` call at :81)
- Test: `test/voice_offline/vad_capture_options_test.dart`, `test/voice_offline/turn_listener_test.dart`

**Interfaces:**
- Produces: `enum VadMic { auto, phone }`. `VadCaptureOptions.mic` (`VadMic`, default `VadMic.auto`). Map key
  `'mic'` with value `'auto'` or `'phone'` (consumed natively in Task 5).

- [ ] **Step 1: Write the failing tests.** Append inside `main()` of `test/voice_offline/vad_capture_options_test.dart`:

```dart
  test('explicit rounds let Android pick the headset mic; mic can be pinned to the phone', () {
    const explicit = VadCaptureOptions(
      cues: true,
      debug: false,
      source: VadAudioSource.communication,
      maxDuration: Duration(seconds: 600),
    );
    expect(explicit.toMap(), containsPair('mic', 'auto'));
    const listen = VadCaptureOptions(
      cues: true,
      debug: false,
      source: VadAudioSource.communication,
      maxDuration: Duration(seconds: 600),
      mic: VadMic.phone,
    );
    expect(listen.toMap(), containsPair('mic', 'phone'));
  });
```

In `test/voice_offline/turn_listener_test.dart`, in the test `'an utterance is transcribed, handed over and the
next round starts'`, add after `expect(device.vadOptions!.startCue, isFalse);`:

```dart
    expect(device.vadOptions!.mic, VadMic.phone);
```

and add the import `import 'package:wing/core/services/android_voice.dart';` if the file does not already import it.

- [ ] **Step 2: Commit the tests and run the suite to see them fail.**

```
git add test/voice_offline/vad_capture_options_test.dart test/voice_offline/turn_listener_test.dart
git commit -m "test(voice): capture option mic, listen rounds pinned to the phone mic"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/vad_capture_options_test.dart`
Expected: `conclusion=failure` (`VadMic` undefined).

- [ ] **Step 3: Implement.** In `lib/core/services/android_voice.dart`, insert above `class VadCaptureOptions {`:

```dart
/// Which microphone a vad round may use (spec 2026-10-16 bt-headset-mic §4.3).
/// [auto]: the connected headset's mic if there is one, otherwise the phone.
/// [phone]: always the phone mic (listen rounds while Hermes works or reads).
enum VadMic { auto, phone }
```

In `VadCaptureOptions`, add `this.mic = VadMic.auto,` after `this.keepPlayback = false,` in the constructor. Add the
field after `final bool keepPlayback;`:

```dart
  /// Native side decides the headset only for [VadMic.auto].
  final VadMic mic;
```

and in `toMap()` add after `'keepPlayback': keepPlayback,`:

```dart
    'mic': mic.name,
```

In `lib/voice_offline/turn_listener.dart`, in the `VadCaptureOptions(` of `_startRound`, add after
`keepPlayback: true,`:

```dart
          // Spec 2026-10-16 E1 = A: listening never holds the headset link,
          // so read-aloud stays in A2DP quality.
          mic: VadMic.phone,
```

- [ ] **Step 4: Commit and run.**

```
git add lib/core/services/android_voice.dart lib/voice_offline/turn_listener.dart
git commit -m "feat(voice): vad option mic; listen rounds use the phone mic"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/turn_listener_test.dart`
Expected: last line `ci-suite: run <id> conclusion=success …`.

---

### Task 3: Car mode holds "phone mic only" (E2 = 1)

**Files:**
- Modify: `lib/core/services/android_voice.dart` (`VoiceDevice` :64-66, `AndroidVoice` :163-167, `VoiceSwitchHolders` :240-241)
- Modify: `test/support/voice_fixture.dart` (:30-31, :101-103)
- Modify: `lib/car_mode/car_mode_session.dart` (`enter` :56, `_end` :100)
- Test: `test/car_mode/car_mode_session_test.dart` (:84, :90)

**Interfaces:**
- Produces: `VoiceDevice.setPhoneMicOnly(bool on)` sends channel method `setPhoneMicOnly` with args `{'on': bool}`
  (native side in Task 5). `VoiceSwitchHolders.phoneMic(VoiceDevice)`. Fixture `phoneMicCalls` (`List<bool>`).

- [ ] **Step 1: Write the failing test.** In `test/car_mode/car_mode_session_test.dart`, test `'enter holds the
  screen on; a swipe exit leaves and releases it'`: after `expect(device.keepScreenOnCalls, [true]);` add
  `expect(device.phoneMicCalls, [true]);`. After `expect(device.keepScreenOnCalls, [true, false]);` add
  `expect(device.phoneMicCalls, [true, false]);`.

In `test/support/voice_fixture.dart`, add after `final mediaKeysCalls = <bool>[];`:

```dart
  final phoneMicCalls = <bool>[];
```

and after the `keepScreenOn` override:

```dart
  @override
  Future<void> setPhoneMicOnly(bool on) async => phoneMicCalls.add(on);
```

- [ ] **Step 2: Commit and run to see it fail.**

```
git add test/car_mode/car_mode_session_test.dart test/support/voice_fixture.dart
git commit -m "test(car): car mode pins the phone microphone"
```

Run: `bash tools/factory/ci-suite.sh test/car_mode/car_mode_session_test.dart`
Expected: `conclusion=failure` (`setPhoneMicOnly` is not in `VoiceDevice`).

- [ ] **Step 3: Implement.** In `lib/core/services/android_voice.dart`:

`VoiceDevice`, after `Future<void> keepScreenOn(bool on);`:

```dart
  /// Car mode: never take a hands-free unit's microphone (spec 2026-10-16 E2).
  Future<void> setPhoneMicOnly(bool on);
```

`AndroidVoice`, after the `keepScreenOn` override:

```dart
  @override
  Future<void> setPhoneMicOnly(bool on) =>
      channel.invokeMethod('setPhoneMicOnly', {'on': on});
```

`VoiceSwitchHolders`, after `screenOn`:

```dart
  static VoiceSwitchHolders phoneMic(VoiceDevice device) =>
      _of(device, 'phoneMic', device.setPhoneMicOnly);
```

In `lib/car_mode/car_mode_session.dart`: in `enter`, after `VoiceSwitchHolders.screenOn(device).set(this, true);` add
`VoiceSwitchHolders.phoneMic(device).set(this, true);`. In `_end`, after
`VoiceSwitchHolders.screenOn(device).set(this, false);` add `VoiceSwitchHolders.phoneMic(device).set(this, false);`.

- [ ] **Step 4: Check that there are no other `VoiceDevice` implementations.** Run: `git grep -n "implements VoiceDevice"`
  Expected: exactly `lib/core/services/android_voice.dart` and `test/support/voice_fixture.dart`. Any further hit
  gets the same one-line override as the fixture.

- [ ] **Step 5: Commit and run.**

```
git add lib/core/services/android_voice.dart lib/car_mode/car_mode_session.dart
git commit -m "feat(car): car mode holds the phone-mic-only switch"
```

Run: `bash tools/factory/ci-suite.sh test/car_mode/car_mode_session_test.dart`
Expected: last line `ci-suite: run <id> conclusion=success …`.

---

### Task 4: `HeadsetMicRoute` (decision, link, release, one-time permission)

**Files:**
- Create: `android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/HeadsetMicRoute.kt`
- Modify: `android/app/src/main/AndroidManifest.xml` (after line 5)

**Interfaces:**
- Produces (Kotlin, used by Task 5):
  - `class HeadsetMicRoute(activity: Activity)`
  - `HeadsetMicRoute.PERMISSION_REQUEST = 7316`, `HeadsetMicRoute.TAG = "WingMic"`
  - `class Decision(val headset: Boolean, val reason: String, val link: AudioDeviceInfo?)`
  - `var phoneMicOnly: Boolean`
  - `fun decide(): Decision`. Reasons: `sdk`, `carMode`, `androidCarMode`, `noHeadsetMic`, `noPermission`,
    `classUnknown`, `notHeadset`, `headset`.
  - `fun acquire(decision: Decision, ready: (AudioDeviceInfo?) -> Unit)`. Calls `ready` exactly once on the main
    thread, with the headset input when the link is up and null for the phone mic. `release()` before ready
    answers null.
  - `fun release()` (idempotent), `fun needsPermission(): Boolean`, `fun requestOnce(then: () -> Unit)`,
    `fun permissionResult(grants: IntArray)`, `fun close()`

No Kotlin unit tests exist in this repo. The class is verified by compile here and on the device in Task 10.

- [ ] **Step 1: Manifest.** In `android/app/src/main/AndroidManifest.xml`, after the `BLUETOOTH_CONNECT` line, add:

```xml
    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
```

- [ ] **Step 2: Create `HeadsetMicRoute.kt`:**

```kotlin
package com.tarkilhk.wing.voiceoffline

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.UiModeManager
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log

/**
 * Microphone for explicit vad rounds (spec 2026-10-16 bt-headset-mic §4): the connected headset's mic if
 * there is one, otherwise the phone. Wing requests the communication route only while a round runs and
 * clears it on every exit. No audio mode change: BackgroundVoiceService treats MODE_IN_COMMUNICATION as
 * a call. Logs numbers, types and reasons only; never an address or a device name.
 */
class HeadsetMicRoute(private val activity: Activity) {
    companion object {
        const val PERMISSION_REQUEST = 7316
        const val TAG = "WingMic"
        private const val READY_TIMEOUT_MS = 2500L
        private const val ASKED_KEY = "bt_connect_asked"
        // Mirrors _headphoneClasses in lib/voice_offline/headphone_route.dart.
        private val headsetClasses = setOf(0x0404, 0x0418)
        private val bluetoothOutputs = setOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET,
        )
    }

    /** [link] is the communication sink to request; the phone mic when [headset] is false. */
    class Decision(val headset: Boolean, val reason: String, val link: AudioDeviceInfo?)

    private val audio = activity.getSystemService(AudioManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private val prefs = activity.getSharedPreferences("wing_voice_route", Context.MODE_PRIVATE)
    private val media = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()

    /** Wing car mode is active (Dart VoiceSwitchHolders.phoneMic). */
    var phoneMicOnly = false
    private var held: AudioDeviceInfo? = null
    private var heldAt = 0L
    private var ready = false
    private var onReady: ((AudioDeviceInfo?) -> Unit)? = null
    private var timeout: Runnable? = null
    private var watcher: Any? = null
    private var afterPermission: (() -> Unit)? = null

    fun bluetoothAllowed() = Build.VERSION.SDK_INT < 31 ||
        activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    fun decide(): Decision {
        if (Build.VERSION.SDK_INT < 31) return Decision(false, "sdk", null)
        val output = if (Build.VERSION.SDK_INT >= 33) {
            try { audio.getAudioDevicesForAttributes(media).firstOrNull() } catch (_: Exception) { null }
        } else null
        val links = audio.availableCommunicationDevices.filter {
            it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO || it.type == AudioDeviceInfo.TYPE_BLE_HEADSET
        }
        val link = links.firstOrNull { output != null && it.address == output.address } ?: links.firstOrNull()
        val allowed = bluetoothAllowed()
        val deviceClass = link?.let { bluetoothClass(it) }
        val reason = when {
            phoneMicOnly -> "carMode"
            androidCarMode() -> "androidCarMode"
            link == null -> "noHeadsetMic"
            !allowed -> "noPermission"
            deviceClass == null -> "classUnknown"
            deviceClass !in headsetClasses -> "notHeadset"
            else -> "headset"
        }
        val headset = reason == "headset"
        val btClass = deviceClass?.let { "0x" + it.toString(16).padStart(4, '0') } ?: "none"
        Log.i(TAG, "decide mic=${if (headset) "headset" else "phone"} reason=$reason out=${output?.type ?: 0} " +
            "comm=${link?.type ?: "none"} btClass=$btClass perm=${if (allowed) 1 else 0}")
        return Decision(headset, reason, if (headset) link else null)
    }

    private fun androidCarMode() =
        activity.getSystemService(UiModeManager::class.java)?.currentModeType == Configuration.UI_MODE_TYPE_CAR

    @SuppressLint("MissingPermission")
    private fun bluetoothClass(device: AudioDeviceInfo): Int? {
        if (!bluetoothAllowed()) return null
        return try {
            val adapter = activity.getSystemService(BluetoothManager::class.java)?.adapter ?: return null
            adapter.getRemoteDevice(device.address).bluetoothClass?.deviceClass
        } catch (_: Exception) { null }
    }

    fun acquire(decision: Decision, ready: (AudioDeviceInfo?) -> Unit) {
        release()
        val link = decision.link
        if (!decision.headset || link == null || Build.VERSION.SDK_INT < 31) { ready(null); return }
        heldAt = SystemClock.elapsedRealtime()
        onReady = ready
        val listener = AudioManager.OnCommunicationDeviceChangedListener { device -> changed(link, device) }
        audio.addOnCommunicationDeviceChangedListener(activity.mainExecutor, listener)
        watcher = listener
        val accepted = try { audio.setCommunicationDevice(link) } catch (_: Exception) { false }
        Log.i(TAG, "acquire result=$accepted")
        if (!accepted) {
            Log.i(TAG, "fallback reason=rejected")
            release()
            return
        }
        held = link
        timeout = Runnable { Log.i(TAG, "fallback reason=timeout"); release() }
            .also { handler.postDelayed(it, READY_TIMEOUT_MS) }
        if (audio.communicationDevice?.id == link.id) changed(link, link)
    }

    private fun changed(link: AudioDeviceInfo, device: AudioDeviceInfo?) {
        if (held?.id != link.id) return
        if (device?.id == link.id) {
            if (ready) return
            ready = true
            timeout?.let { handler.removeCallbacks(it) }
            timeout = null
            Log.i(TAG, "ready readyMs=${SystemClock.elapsedRealtime() - heldAt}")
            val callback = onReady
            onReady = null
            callback?.invoke(inputFor(link))
        } else if (ready) {
            Log.i(TAG, "lost")
        }
    }

    private fun inputFor(link: AudioDeviceInfo): AudioDeviceInfo? =
        audio.getDevices(AudioManager.GET_DEVICES_INPUTS)
            .firstOrNull { it.type == link.type && it.address == link.address }

    /** Idempotent. A pending [acquire] answers null (phone mic). */
    fun release() {
        timeout?.let { handler.removeCallbacks(it) }
        timeout = null
        if (Build.VERSION.SDK_INT >= 31) {
            (watcher as? AudioManager.OnCommunicationDeviceChangedListener)
                ?.let { audio.removeOnCommunicationDeviceChangedListener(it) }
        }
        watcher = null
        val link = held
        held = null
        ready = false
        if (link != null && Build.VERSION.SDK_INT >= 31) {
            // Clears Wing's own request only; other apps' requests stay.
            try { audio.clearCommunicationDevice() } catch (_: Exception) {}
            Log.i(TAG, "release heldMs=${SystemClock.elapsedRealtime() - heldAt}")
        }
        val callback = onReady
        onReady = null
        callback?.invoke(null)
    }

    /** Spec §3 F1: ask once, in the foreground, while a Bluetooth audio device is connected. */
    fun needsPermission(): Boolean = Build.VERSION.SDK_INT >= 31 && afterPermission == null &&
        !bluetoothAllowed() && !prefs.getBoolean(ASKED_KEY, false) && activity.hasWindowFocus() &&
        audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type in bluetoothOutputs }

    fun requestOnce(then: () -> Unit) {
        prefs.edit().putBoolean(ASKED_KEY, true).apply()
        afterPermission = then
        Log.i(TAG, "permission ask")
        activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), PERMISSION_REQUEST)
    }

    fun permissionResult(grants: IntArray) {
        val granted = grants.firstOrNull() == PackageManager.PERMISSION_GRANTED
        Log.i(TAG, "permission granted=${if (granted) 1 else 0}")
        val then = afterPermission
        afterPermission = null
        then?.invoke()
    }

    fun close() {
        afterPermission = null
        release()
    }
}
```

- [ ] **Step 3: Privacy check.** Run: `git grep -n "address\|productName\|\.name" -- android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/HeadsetMicRoute.kt`
  Expected: hits only in comparisons (`it.address == …`, `getRemoteDevice(device.address)`). None of them may sit
  inside a `Log.i` line.

- [ ] **Step 4: Commit and compile.**

```
git add android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/HeadsetMicRoute.kt android/app/src/main/AndroidManifest.xml
git commit -m "feat(voice): HeadsetMicRoute takes the headset mic through the communication device"
```

Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: last line `dispatch-check: voice-apk.yml run <id> conclusion=success …`.

---

### Task 5: Hook `HeadsetMicRoute` into `VadCapture` and `VoiceChannel`

**Files:**
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/VadCapture.kt` (constructor :24-30, `Options` :31-32,
  `Round` :34-45, `start` :50-71, `openRecord` :85-98, `readLoop` :130-131, `stopReading` :183-188, `writeDebug` :200)
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt` (fields :17-25, `handle` :87, `start`
  :97-116, `permissionResult` :117-118, `close` :140)

**Interfaces:**
- Consumes: Task 4 `HeadsetMicRoute` API. Task 2 map key `mic`. Task 3 channel method `setPhoneMicOnly {'on'}`.
  Task 1 `HeadphoneRouteChannel.refresh()`.
- Produces: `VadCapture.start(id: String, options: Options, started: (Exception?) -> Unit)`. `started(null)` means
  capture runs. A `java.util.concurrent.CancellationException` means the round was cancelled while it waited for the
  link. Debug JSON key `mic` = `{headset: bool, reason: String, firstSoundMs: Long}`.

- [ ] **Step 1: VadCapture constructor, options, round.** Change the constructor to take the route, after `debug`:

```kotlin
class VadCapture(
    private val activity: Activity,
    private val models: SpeechModelStore,
    private val speech: OfflineSpeech,
    private val debug: VoiceDebugStore,
    private val mic: HeadsetMicRoute,
    private val emit: (Map<String, Any>) -> Unit,
) {
    data class Options(val cues: Boolean, val debug: Boolean, val source: String, val maxMs: Int,
                       val startCue: Boolean = cues, val mic: String = "auto")
```

Update the class comment line `Records from whatever input Android routes; never changes audio routing.` to:

```kotlin
 *  Explicit rounds (mic "auto") may take the headset mic through HeadsetMicRoute (spec 2026-10-16). */
```

Add to `Round`, after `var inputDevice = "unknown"`:

```kotlin
        var micInput: android.media.AudioDeviceInfo? = null
        var micReason = "listen"
        var firstSoundMs = -1L
```

Add the import `import android.util.Log`, `import com.tarkilhk.wing.voiceoffline.HeadsetMicRoute` and
`import java.util.concurrent.CancellationException`.

- [ ] **Step 2: Asynchronous start.** Replace `fun start(id: String, options: Options) { … }` (:50-71) with:

```kotlin
    /** Answers [started] once: null when capture runs, otherwise the failure. An explicit round first waits
     *  for the headset link; the start cue plays only once the chosen mic is live (spec §5). */
    fun start(id: String, options: Options, started: (Exception?) -> Unit) {
        cancelCurrent()
        models.verifyManifest()?.let { error(it) }
        val r = Round(id, options, System.currentTimeMillis(), (options.maxMs + 5_000) * 16)
        round = r
        val decision = if (options.mic == "auto") mic.decide() else HeadsetMicRoute.Decision(false, "listen", null)
        r.micReason = decision.reason
        mic.acquire(decision) { input ->
            if (round !== r || r.stopped) { started(CancellationException("Recording cancelled.")); return@acquire }
            r.micInput = input
            try {
                begin(r)
                started(null)
            } catch (error: Exception) {
                release(r); round = null; mic.release(); started(error)
            }
        }
    }

    private fun begin(r: Round) {
        if (r.options.startCue) cue(ToneGenerator.TONE_PROP_BEEP, wait = true)
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
    }
```

- [ ] **Step 3: Pin the record.** In `openRecord`, inside `if (record.state == AudioRecord.STATE_INITIALIZED) {`, add as
  the first line:

```kotlin
                r.micInput?.let { record.setPreferredDevice(it) }
```

- [ ] **Step 4: First sound.** In `readLoop`, after `r.length += 512`, add:

```kotlin
            if (r.firstSoundMs < 0 && frame.any { it.toInt() != 0 }) {
                r.firstSoundMs = System.currentTimeMillis() - r.startedAt
                if (r.options.mic == "auto") Log.i(HeadsetMicRoute.TAG, "first firstSoundMs=${r.firstSoundMs} headset=${if (r.micInput != null) 1 else 0}")
            }
```

- [ ] **Step 5: Release on every exit.** Replace `stopReading` with:

```kotlin
    private fun stopReading(r: Round) {
        r.stopped = true
        try { r.record?.stop() } catch (_: Exception) {}
        // Never release here: the reader releases its own resources when it exits (see read).
        try { r.reader?.join(500) } catch (_: InterruptedException) {}
        // finish, cancel, fail and pause all pass here: A2DP returns before recognition starts.
        mic.release()
    }
```

- [ ] **Step 6: Debug JSON.** In `writeDebug`, after `.put("source", r.sourceName).put("inputDevice", r.inputDevice)`,
  add:

```kotlin
            .put("mic", JSONObject().put("headset", r.micInput != null).put("reason", r.micReason).put("firstSoundMs", r.firstSoundMs))
```

- [ ] **Step 7: VoiceChannel fields.** Replace the `vad` and `route` lines so that the mic route exists before
  `VadCapture`:

```kotlin
    private val micRoute = HeadsetMicRoute(activity)
    private val vad = VadCapture(activity, models, speech, debugStore, micRoute, ::emit)
```

(keep `private val route = HeadphoneRouteChannel(activity, messenger)` where it is). Add the imports
`import com.tarkilhk.wing.voiceoffline.HeadsetMicRoute` and `import java.util.concurrent.CancellationException`.

- [ ] **Step 8: Channel method.** In `handle`, after the `"setMediaKeys"` line, add:

```kotlin
                "setPhoneMicOnly" -> { micRoute.phoneMicOnly = call.argument<Boolean>("on") == true; result.success(null) }
```

- [ ] **Step 9: Start.** Replace `private fun start(call: MethodCall, result: MethodChannel.Result) { … }` with:

```kotlin
    private fun start(call: MethodCall, result: MethodChannel.Result) {
        // Barge-in listen rounds record while Wing reads aloud.
        if (call.argument<Boolean>("keepPlayback") != true) playback.stop()
        val id = call.argument<String>("id")!!
        if (call.method != "startVad") {
            vad.cancel(id)
            capture.start(id, call.argument<Boolean>("local") == true, call.argument<String>("language").orEmpty())
            result.success(null)
            return
        }
        capture.cancel(id)
        val cues = call.argument<Boolean>("cues") != false
        val options = VadCapture.Options(
            cues = cues,
            debug = call.argument<Boolean>("debug") == true,
            source = call.argument<String>("source") ?: "communication",
            maxMs = call.argument<Int>("maxMs") ?: 600_000,
            startCue = call.argument<Boolean>("startCue") ?: cues,
            mic = call.argument<String>("mic") ?: "auto",
        )
        val begin = {
            try {
                vad.start(id, options) { failure ->
                    when (failure) {
                        null -> result.success(null)
                        is CancellationException -> result.error("cancelled", "Recording cancelled.", null)
                        else -> result.error("voice_unavailable", failure.message ?: "Voice is unavailable.", null)
                    }
                }
            } catch (error: Exception) { result.error("voice_unavailable", error.message ?: "Voice is unavailable.", null) }
        }
        // Spec §3 F1: the first explicit recording with Bluetooth audio asks for Nearby devices once.
        if (options.mic == "auto" && micRoute.needsPermission()) micRoute.requestOnce(begin) else begin()
    }
```

- [ ] **Step 10: Permission result and close.** In `permissionResult`, add as the first line:

```kotlin
        if (requestCode == HeadsetMicRoute.PERMISSION_REQUEST) { micRoute.permissionResult(grants); route.refresh(); return true }
```

In `close()`, change `… vad.close(); debugStore.close(); …` to `… vad.close(); micRoute.close(); debugStore.close(); …`.

- [ ] **Step 11: Check that every exit releases.** Run: `git grep -n "mic.release()" -- android/app/src/main/kotlin/com/tarkilhk/wing/VadCapture.kt`
  Expected: two hits (`stopReading`, the `start` catch). `finish`, `cancelRound`, `fail`, `pause` and `close` all
  reach `stopReading`. Confirm with `git grep -n "stopReading(r)" -- android/app/src/main/kotlin/com/tarkilhk/wing/VadCapture.kt`:
  expected hits in `finish`, `fail` and `cancelRound` (`pause` calls `fail`, `close` calls `cancelCurrent`).

- [ ] **Step 12: Commit and compile.**

```
git add android/app/src/main/kotlin/com/tarkilhk/wing/VadCapture.kt android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt
git commit -m "feat(voice): explicit vad rounds record through the headset mic when one is connected"
```

Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: last line `dispatch-check: voice-apk.yml run <id> conclusion=success …`.

---

### Task 6: Word error rate script and reference sentences

May run before Task 0's merge condition (no shared files).

**Files:**
- Create: `tools/voice/wer.py`
- Create: `tools/voice/headset_mic_reference.txt`

**Interfaces:**
- Produces: CLI `python3 -I tools/voice/wer.py --reference <file> --line <n> (--hypothesis <file> | --ui-dump <xml>)`.
  It prints one line, `wer=<x.xxx> words=<n> sub=<n> del=<n> ins=<n>`, and never prints text. `--selftest` prints
  `selftest ok`.

- [ ] **Step 1: Reference file** `tools/voice/headset_mic_reference.txt` (synthetic, no digits, one sentence per line):

```
Der Zug nach Hamburg fährt heute am späten Nachmittag von einem anderen Gleis ab.
Bitte erinnere mich morgen früh daran, die Fenster im Wohnzimmer zu schließen.
Die Messung im Café vergleicht das Mikrofon des Telefons mit dem Mikrofon der Kopfhörer.
```

- [ ] **Step 2: Write `tools/voice/wer.py` with its self-test first:**

```python
#!/usr/bin/env python3
"""Word error rate of a dictated sentence against a fixed reference
(spec 2026-10-16 bt-headset-mic §11). Prints numbers only, never text."""
import argparse
import re
import sys
import unicodedata
import xml.etree.ElementTree as ET


def words(text):
    text = unicodedata.normalize("NFC", text).lower()
    return re.sub(r"[^\w\s]", " ", text).split()


def edits(ref, hyp):
    """Minimal (cost, sub, del, ins) alignment."""
    rows = [[(j, 0, 0, j) for j in range(len(hyp) + 1)]]
    for i in range(1, len(ref) + 1):
        row = [(i, 0, i, 0)]
        for j in range(1, len(hyp) + 1):
            if ref[i - 1] == hyp[j - 1]:
                row.append(rows[i - 1][j - 1])
                continue
            c, s, d, n = rows[i - 1][j - 1]
            best = (c + 1, s + 1, d, n)
            c, s, d, n = rows[i - 1][j]
            best = min(best, (c + 1, s, d + 1, n))
            c, s, d, n = row[j - 1]
            best = min(best, (c + 1, s, d, n + 1))
            row.append(best)
        rows.append(row)
    return rows[-1][-1]


def score(reference, hypothesis):
    ref, hyp = words(reference), words(hypothesis)
    cost, sub, dele, ins = edits(ref, hyp)
    return cost / max(len(ref), 1), len(ref), sub, dele, ins


def ui_text(path):
    """Text of the first EditText in a `uiautomator dump` file (the chat draft)."""
    for node in ET.parse(path).iter("node"):
        if node.get("class") == "android.widget.EditText":
            return node.get("text", "")
    sys.exit("no EditText in the dump")


def selftest():
    assert score("Eins, zwei, drei.", "eins zwei drei")[0] == 0.0
    wer, n, sub, dele, ins = score("eins zwei drei vier", "eins drei vier")
    assert (round(wer, 3), n, sub, dele, ins) == (0.25, 4, 0, 1, 0)
    wer, n, _, _, _ = score("der wind weht über das land", "der wind weht über land heute")
    assert (round(wer, 3), n) == (0.333, 6)
    assert words("Café Kopfhörer!") == ["café", "kopfhörer"]
    print("selftest ok")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--reference")
    parser.add_argument("--line", type=int, default=1)
    parser.add_argument("--hypothesis")
    parser.add_argument("--ui-dump")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return
    with open(args.reference, encoding="utf-8") as handle:
        reference = handle.read().splitlines()[args.line - 1]
    if args.ui_dump:
        hypothesis = ui_text(args.ui_dump)
    else:
        with open(args.hypothesis, encoding="utf-8") as handle:
            hypothesis = handle.read()
    wer, n, sub, dele, ins = score(reference, hypothesis)
    print(f"wer={wer:.3f} words={n} sub={sub} del={dele} ins={ins}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Run the self-test.** Run: `python3 -I tools/voice/wer.py --selftest`
  Expected: `selftest ok`.

- [ ] **Step 4: Run against the reference itself.** Run: `python3 -I tools/voice/wer.py --reference tools/voice/headset_mic_reference.txt --line 3 --hypothesis tools/voice/headset_mic_reference.txt`
  Expected: `wer=` greater than 0 (the hypothesis file holds all three lines). The point is that it runs; the
  measurement uses `--ui-dump`.

- [ ] **Step 5: Commit.**

```
git add tools/voice/wer.py tools/voice/headset_mic_reference.txt
git commit -m "tools(voice): word error rate script for the headset mic measurement"
```

---

### Task 7: Documentation and suite

**Files:**
- Modify: `docs/VAD_INPUT.md` (new section "## Microphone route" at the end)

- [ ] **Step 1: Append to `docs/VAD_INPUT.md`:**

```markdown
## Microphone route

Rule (Birk, 16.10.2026, supersedes 13.10.): the connected headset's microphone if there is one, otherwise the
phone. Spec: `docs/superpowers/specs/2026-10-16-wing-voice-bt-headset-mic-design.md`.

- Explicit rounds (dictation, conversation turn: `mic: auto`) ask `HeadsetMicRoute` at start. For a Bluetooth
  headset with HFP and class 0x0404/0x0418, Wing requests the link with `setCommunicationDevice`, waits up to 2.5 s,
  then plays the start cue and records from the SCO input. The link is cleared on every exit, before recognition.
- Listen rounds and the echo probe (`mic: phone`) never take the headset mic. Read-aloud stays in A2DP quality.
- Phone mic: car mode (Wing or Android), non-headset Bluetooth class (car kits), unknown class, A2DP-only devices.
  Wired headsets with a mic are routed by Android without Wing doing anything.
- Nearby devices access is asked once, at the first explicit recording while Bluetooth audio is connected.
- Logcat: `adb logcat -d | grep WingMic` → `decide`, `acquire`, `ready readyMs=`, `first firstSoundMs=`, `release`.
  Proof of the headset mic: `adev_open_input_stream … devices(0x80000008)`; the phone mic is `0x80000004`.
```

- [ ] **Step 2: Commit and run the whole suite once.**

```
git add docs/VAD_INPUT.md
git commit -m "docs(voice): microphone route rule and logs"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/headphone_route_test.dart`
Expected: last line `ci-suite: run <id> conclusion=success …`.

---

### Task 8 [WORKER]: Build and install

- [ ] **Step 1: Build.** Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=true`
  Expected: `conclusion=success`. Note `SOURCE_COMMIT`.
- [ ] **Step 2: Sign and install** with the sideload key (same procedure as every voice build). Run:
  `hadb shell dumpsys package com.tarkilhk.wing.voice | grep -E "versionName|BLUETOOTH_CONNECT|MODIFY_AUDIO_SETTINGS"`
  Expected: the new versionName, `MODIFY_AUDIO_SETTINGS: granted=true`, `BLUETOOTH_CONNECT: granted=false` (not
  asked yet).

---

### Task 9 [WORKER + Birk]: Baseline in the cafe, phone mic (before)

Runs on the installed 1.1.3 (or the Task 8 build with the Sony's "Phone calls" profile off). Needs Task 6 only.

- [ ] **Step 1: Settings.** Input "On this phone · Parakeet", Conversation mode **off** (dictation into the
  composer), "Keep voice recordings" on.
- [ ] **Step 2: Condition P0 (no headset):** Sony disconnected. For each line n = 1..3 of
  `tools/voice/headset_mic_reference.txt`, Birk opens a new empty chat, taps the mic and reads line n. The text lands
  in the draft and is **not sent**. Then run:
  `hadb shell uiautomator dump /sdcard/wing-ui.xml`
  `hadb pull /sdcard/wing-ui.xml build/voice-measure/p0-<n>.xml`
  `python3 -I tools/voice/wer.py --reference tools/voice/headset_mic_reference.txt --line <n> --ui-dump build/voice-measure/p0-<n>.xml`
  Expected: one `wer=…` line per sentence. Then Birk clears the draft. If the script says `no EditText in the dump`:
  run `grep -c EditText build/voice-measure/p0-<n>.xml`, report the count, and stop.
- [ ] **Step 3: Condition P1 (Sony connected, A2DP output, phone mic):** the same three sentences.
- [ ] **Step 4: Echo probe pair** (separates cafe noise from Sony leakage; Conversation mode on for the probe row):
  Sony connected, normal media volume, `hadb logcat -c`, tap "Measure speaker echo", wait 40 s, then
  `hadb logcat -d | grep WingBargeIn`. Then the same at media volume 0:
  `hadb shell cmd media_session volume --stream 3 --set 0`. Record both `probe` lines.
- [ ] **Step 5: Record** the numbers (no text) in the card comment: P0/P1 WER per sentence and mean, plus both probe
  lines. Then run `rm -r build/voice-measure`, "Delete debug recordings", and switch "Keep voice recordings" off.

---

### Task 10 [WORKER + Birk]: Device proof and measurement (after)

Build from Task 8. Sony WH-1000XM4 connected, Wing in the foreground.

- [ ] **Step 1: Permission once.** `hadb logcat -c`. Birk starts a dictation. Android shows "Nearby devices"; Birk
  allows it. Run: `hadb logcat -d | grep WingMic`
  Expected, in order: `WingMic permission ask`, `WingMic permission granted=1`, `WingMic decide mic=headset
  reason=headset out=8 comm=7 btClass=0x0404 perm=1`, `WingMic acquire result=true`, `WingMic ready readyMs=<n>`,
  `WingMic first firstSoundMs=<n> headset=1`, `WingMic release heldMs=<n>`. A second dictation must **not** log
  `permission ask`.
- [ ] **Step 2: Mic proof** (the central check). `hadb logcat -c`, one dictation, then:
  `hadb logcat -d -v threadtime | grep -E "WingMic|adev_open_input_stream|adev_close_input_stream"`
  Expected: `adev_open_input_stream … devices(0x80000008) … source(7)` between `WingMic ready` and `WingMic release`.
  During the round: `hadb shell dumpsys audio | grep -iE "communication device|BtSco|mode"`. Expected: the preferred
  or active communication device is `bt_sco`, and the audio mode is NORMAL (ANNAHME 3). Repeat once with the setting
  "Recognition" (`source(6)`). If `0x80000004` appears instead of `0x80000008`: go to Task 13.
- [ ] **Step 3: Codec.** During a round: `hadb shell dumpsys bluetooth_manager | grep -iE "sco|wbs|swb|msbc|lc3|codec"`.
  Record the lines (ANNAHME 4).
- [ ] **Step 4: Latency.** Five dictations. From each `WingMic` block, record `readyMs` and `firstSoundMs`. From
  `logcat -v threadtime`, record the time from `WingMic release` to the next line matching
  `grep -iE "a2dp.*(start|resume|suspend)"` (ANNAHME 9). The risk is first-syllable loss. Birk says the first word
  immediately after the cue in all five runs, and the WER script (sentence 1) shows whether "Der" survived.
- [ ] **Step 5: WER, Sony mic vs phone mic, same cafe session.** Alternate S (Sony mic, default) and P (Sony's
  "Phone calls" switched off in Android Bluetooth device settings, which forces the phone mic with A2DP still on).
  Run the three sentences per condition, twice (12 dictations). Use the commands from Task 9 Step 2 with files
  `s-<n>-<k>.xml` / `p-<n>-<k>.xml`. Expected for the P condition: `WingMic decide mic=phone reason=noHeadsetMic`.
  Acceptance (spec §11): mean Sony WER ≤ mean phone WER + 0.05.
- [ ] **Step 6: Disconnect mid-round** (ANNAHME 7). Start a dictation, speak for 3 s, switch the Sony off, keep
  speaking, stop. `hadb logcat -d | grep -E "WingMic|flutter"`. Expected: `WingMic lost` and a transcript in the
  draft, not an error. Record what happened.
- [ ] **Step 7: Media during SCO and cue audibility** (ANNAHME 8, 11). Did Birk hear the start cue in the Sony? While
  a dictation round is open, play a short clip in another app: silent, call quality, or normal? Record.
- [ ] **Step 8: Sony button** (ANNAHME 10). During a dictation round, Birk taps the Sony touch pad once. Record
  whether Wing stops the round (media key), SCO closes (`WingMic lost`), or nothing happens.
- [ ] **Step 9: Read-aloud quality after release.** Conversation mode on, one turn. The reply must sound like normal
  media (LDAC), not a phone call. Run `hadb shell dumpsys audio | grep -iE "communication device"` after the reply.
  Expected: no `bt_sco` preference from Wing.
- [ ] **Step 10: Listen rounds stay on the phone mic.** Conversation mode with "Listen while Hermes works" on, during
  a running turn: `hadb logcat -d -v threadtime | grep adev_open_input_stream`. Expected: `devices(0x80000004)` for
  the listen round, with no `WingMic decide` line for it.
- [ ] **Step 11: Car rule** (only if Birk is at the car anyway): connected to the car kit, one dictation. Expected:
  `WingMic decide mic=phone reason=notHeadset` (or `carMode` in Wing car mode). Record `btClass`.
- [ ] **Step 12: Clean up.** `rm -r build/voice-measure`, "Delete debug recordings", "Keep voice recordings" off. Post
  all numbers (no text) in the card comment.

---

### Task 11: Write the result

**Files:** Modify `docs/VAD_INPUT.md` (subsection "### Measurement 2026-10" under "## Microphone route").

- [ ] **Step 1:** Add a table with condition (P0, P1, S, P), mean WER, readyMs median, firstSoundMs median,
  A2DP-resume ms, codec line, and the outcomes of disconnect, button, media and cue. Add one line:
  "Decision: headset mic default <kept|reported to Birk>". If Sony WER > phone WER + 0.05: write "reported to Birk"
  and post the numbers on the card. Do not change the code.
- [ ] **Step 2: Commit.**

```
git add docs/VAD_INPUT.md
git commit -m "docs(voice): headset mic measurement result"
```

Verify: `git grep -c "Measurement 2026-10" -- docs/VAD_INPUT.md` → `docs/VAD_INPUT.md:1`.

---

### Task 12 [WORKER + Birk]: Acceptance in daily use

- [ ] **Step 1:** Birk uses Wing for one day with the Sony. Then `hadb logcat -d | grep -c "WingMic fallback"`.
  Record the number and the reasons (`grep "WingMic fallback"`).
- [ ] **Step 2:** Birk confirms in the card: the headset mic is used, read-aloud sounds normal, and there are no lost
  first words. A "no" on any point gets a follow-up card with the logs.

---

### Task 13 (conditional, only if Task 10 Step 2 shows `0x80000004`): Communication mode for the round

**Files:**
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/HeadsetMicRoute.kt`
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/voicebackground/BackgroundVoiceService.kt` (:85)

**Interfaces:** Produces `HeadsetMicRoute.ownsMode` (companion, `@Volatile var`, `Boolean`).

- [ ] **Step 1:** In the `HeadsetMicRoute` companion add:

```kotlin
        /** True while Wing itself holds MODE_IN_COMMUNICATION for a headset round (Task 13). */
        @Volatile var ownsMode = false
            private set
```

In `acquire`, directly before `val accepted = …`:

```kotlin
        ownsMode = true
        audio.mode = AudioManager.MODE_IN_COMMUNICATION
```

In `release`, insert directly after the closing brace of the `if (link != null && Build.VERSION.SDK_INT >= 31) { … }`
block and before `val callback = onReady`. That way it also runs when the link was rejected:

```kotlin
        if (ownsMode) {
            audio.mode = AudioManager.MODE_NORMAL
            // Late mode callbacks still see Wing as the owner.
            handler.post { ownsMode = false }
        }
```

- [ ] **Step 2:** In `BackgroundVoiceService.watchCalls`, change the listener to:

```kotlin
        val listener = AudioManager.OnModeChangedListener { mode ->
            if (mode in callModes && !com.tarkilhk.wing.voiceoffline.HeadsetMicRoute.ownsMode) finish("call")
        }
```

- [ ] **Step 3: Commit and compile.**

```
git add android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/HeadsetMicRoute.kt android/app/src/main/kotlin/com/tarkilhk/wing/voicebackground/BackgroundVoiceService.kt
git commit -m "fix(voice): headset rounds hold communication mode without ending the background conversation"
```

Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false` → `conclusion=success`. Then repeat Task 8 and
Task 10 Steps 2, 9 and 10, plus one screen-off conversation turn. Run `hadb logcat -d | grep WingBgVoice`. Expected:
no `stop reason=call`.

---

## Follow-up device card t_fabcb273 (echo S2 with Sony), not part of this plan

With E1 = A, read-aloud barge-in listens through the phone mic while the Sony plays A2DP. That is exactly what the
current probe measures. t_fabcb273 can run now, independent of this plan: S2 in a **quiet room** (three runs), plus
one run at media volume 0 as a noise-floor baseline (`hadb shell cmd media_session volume --stream 3 --set 0`). It
uses the existing thresholds (pass `run50 ≤ 6` and `p99 < 0.5`; marginal `run50 ≤ 15` and `p99 < 0.75`). A second
series with SCO open (the HFP path with the headset's own echo cancellation) is needed only if Birk picks E1 = C.

## Self-review notes (plan author)

- Spec coverage: §3 F1 → Tasks 4/5. F2 → Task 1. §4.1-4.3 → Tasks 4/5. Matrix rows "listen" → Task 2, "car" →
  Tasks 3/4. §4.4 exit paths → Task 5 Steps 5/11. Disconnect → Task 10 Step 6. §5 latency/cue → Task 5 Step 2 (cue
  after link), Task 10 Step 4. §7 car → Task 3. §10/§11 measurements → Tasks 6/9/10/11. Mode fallback → Task 13.
- `HeadphoneRouteChannel.refresh()` (Task 1) is listed in spec §6. It pushes a new route to Dart after a grant
  through the dictation path.
- Type names used across tasks: `VadMic.auto/phone`, map key `mic`, `setPhoneMicOnly {'on'}`, `HeadsetMicRoute.Decision`,
  `acquire(decision, ready)`, `VadCapture.start(id, options, started)`.

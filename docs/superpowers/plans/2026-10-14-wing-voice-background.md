# Wing Voice: Conversation Mode with the Screen Off — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On input route vad, conversation mode keeps running (read aloud → microphone → send) when the screen goes
off or Wing leaves the foreground. A microphone foreground service with a Stop notification makes this visible.

**Architecture:** The loop stays in Dart, in the retained Flutter engine. A new microphone-type foreground service
(`BackgroundVoiceService`) holds the process, CPU and while-in-use microphone access while a conversation runs. A new
Dart policy object (`BackgroundVoice`) decides when to hold. Thin hooks in three upstream files bypass the native and
Dart pause kills only while the hold is active.

**Tech Stack:** Flutter/Dart (`flutter_test`), Kotlin (Android Service, NotificationCompat, AudioManager), and a
MethodChannel `com.tarkilhk.wing/background_voice`.

**Spec:** `docs/superpowers/specs/2026-10-14-wing-voice-background-design.md` (cited below as "spec §n").

## Global Constraints

- **Client only.** No Hermes backend change, plugin or endpoint (AGENTS.md).
- **Upstream strategy.** Own logic lives in new files: `lib/voice_offline/background_voice.dart` and
  `android/app/src/main/kotlin/com/tarkilhk/wing/voicebackground/*`. Upstream files get only thin hooks with hard
  caps:

  | File | Cap |
  |---|---|
  | `lib/core/screens/profile_workspace_screen.dart` | ≤ 20 added/changed lines |
  | `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt` | ≤ 7 lines (including imports) |
  | `android/app/src/main/AndroidManifest.xml` | ≤ 8 lines |
  | `MainActivity.kt`, `VoiceCapture.kt`, `lib/core/controllers/voice_input_controller.dart`, `lib/core/services/android_voice.dart`, `VadCapture.kt`, `VoicePlayback.kt` | 0 lines |

- **Scope.** Route vad only. Routes `local`/`hermes` and car mode keep today's behaviour (the conversation ends on
  pause). Car mode is always screen-on (operator note) and never holds.
- **Logcat tag** `WingBgVoice`, Kotlin only. Log lines carry only state, reason and durations. Never transcript,
  reply, chat or profile text. The complete set of line forms:
  `hold on`, `hold refused reason=<r>`, `pause kept`, `stop reason=<r>`, `wakelock released heldMs=<n>`,
  `listening on`, `listening off`.
- **Time limit without speech.** It is the existing `voice.vad_no_speech_seconds` (default 8 s,
  `VadEndpointConfig.noSpeechTimeout`). No new timer.
- **Notification copy (exact).**

  | Element | Text |
  |---|---|
  | Channel name | "Voice conversation" |
  | Title | "Conversation mode" |
  | Text | "Microphone opens after each reply." |
  | Text while a barge-in listen round is open | "Microphone is listening." |
  | Action | "Stop" |

  Channel id `voice_conversation`, notification id `214611`, small icon `R.drawable.ic_stat_monitoring`.
- **Decisions D1–D3 (decided by Birk, 14.10.).** This plan implements them:
  - **D1-a:** no own switch. Conversation mode on route vad keeps running with the screen off automatically,
    visible through the notification with Stop.
  - **D2-b:** listening/steering while Hermes works also runs with the screen off (pocket). The only control is the
    barge-in switch "Listen while Hermes works" (`voice.listen_turn`, default on, can be switched off in the voice
    settings); there is no screen-off special rule. Interrupting read-aloud stays headphones-only (barge-in D2). The
    microphone can be open for a whole Hermes turn; the notification shows it (Task 5).
  - **D3-a:** the notification and foreground service start when conversation mode starts.
- **Test command.**
  - `bash tools/factory/ci-suite.sh <test path>` pushes HEAD to a throwaway branch and runs the **whole**
    `pr-quality.yml` suite. The path argument only documents the target; the script ignores it. Commit before
    running it.
  - Success output: last line `ci-suite: run <id> conclusion=success`, exit 0.
  - Kotlin compile check: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`. Success output:
    `dispatch-check: voice-apk.yml run <id> conclusion=success …`.
- **Shell rules.** One command per shell call. No `cd`, no `&&`, no pipes into variables. Commit after every task.
  No push except through the two factory scripts. No merge.
- **No session data.** Session data, device dumps and third-party data never go into the repo. Device results are
  recorded as pass/fail plus numbers only.

## Preconditions

Implementation starts only after **both** of these:
- the VAD merge (b4f5e4a0, done);
- the upstream merge, card t_f8523002 (not done on 2026-10-14).

Recommended order after the upstream merge:
1. TTS language t_d523010d
2. car mode t_c8de9cba
3. barge-in t_7e81e040
4. this card

If car mode or barge-in have not landed, the anchors A9/A10 say what to skip and what the later card must add.

## File Map

| File | Action | Responsibility |
|---|---|---|
| `lib/voice_offline/background_voice.dart` | Create | `BackgroundVoiceHost`, `AndroidBackgroundVoiceHost`, `BackgroundVoice` (policy/state, listening text) |
| `test/voice_offline/background_voice_test.dart` | Create | Unit tests for `BackgroundVoice` |
| `test/support/background_voice_fixture.dart` | Create | Fake host for widget tests |
| `android/app/src/main/kotlin/com/tarkilhk/wing/voicebackground/BackgroundVoiceService.kt` | Create | Microphone FGS, notification (incl. listening text), wake lock, call watch |
| `android/app/src/main/kotlin/com/tarkilhk/wing/voicebackground/BackgroundVoiceChannel.kt` | Create | MethodChannel, preconditions, start/stop, listening |
| `android/app/src/main/AndroidManifest.xml` | Modify (≤ 8) | Permission and service |
| `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt` | Modify (≤ 7) | Field, `pause()` guard, `close()` |
| `lib/core/screens/profile_workspace_screen.dart` | Modify (≤ 20) | Parameter, field, setter sync, lifecycle, `_loopFocus`, dispose; listening hook (Task 5) |
| `test/voice_workspace_test.dart` | Modify | Group "screen off"; `show()` passes the fixture |
| `docs/VOICE.md` | Modify | User-facing paragraph |

---

### Task 0: Anchor checks and basis record (no product code)

**Files:** none changed except the commit message. If the Android pages can be fetched, also
`docs/superpowers/specs/2026-10-14-wing-voice-background-design.md` §3.

**Interfaces:**
- Produces: `BASE` (SHA, used by Task 6) and the anchor results A1–A18 (used by Tasks 2–6).

- [ ] **Step 1: Record the base commit**

Run: `git rev-parse HEAD`
Expected: a SHA. Write it down as `BASE`; Task 6 measures the hook caps against it.

- [ ] **Step 2: Run each anchor from the repo root, one command at a time**

Line numbers prefixed "wt" are from the plan worktree (b4f5e4a0 + docs). The upstream merge may move them; the
command decides, not the number.

| # | Command | Expected | If moved / missing |
|---|---|---|---|
| A1 | `git merge-base --is-ancestor b4f5e4a0 HEAD` | exit 0 | **Stop**, `FRAGE:` (VAD chain missing). |
| A2 | `git merge-base --is-ancestor 1adbee5d HEAD` (upstream/main as inspected on 2026-10-14) | exit 0 | Non-zero → upstream merge not done → **stop**, `FRAGE: Upstream-Merge t_f8523002 fehlt — trotzdem starten?` Optional, informative only: `git log --merges --oneline --grep=t_f8523002 -1` may show the merge commit; an empty result is not a failure. |
| A3 | `git grep -n -A4 "fun pause()" -- android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt` | one `pause()` that stops capture, vad (`vad.pause()`), playback and media keys (wt :123, one line) | Multi-line body (upstream style, with `if (closed) return`) → put the Task 3 guard directly after `if (closed) return`. No `vad.pause()` → vad moved to another class: put the guard in front of that class's pause call instead, same condition. |
| A4 | `git grep -n "voiceChannel?.pause()\|voiceChannel?.leaveForeground()" -- android/app/src/main/kotlin/com/tarkilhk/wing/MainActivity.kt` | `onPause` → `pause()`; after the merge also `onStop` → `leaveForeground()` (up :348, :360) | If `leaveForeground()` stops capture or playback **without** calling `pause()`, add the same guard there (counts against the 7-line cap). |
| A5 | `git grep -n "class VoiceChannel(" -- android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt` | constructor has `activity: Activity, messenger: BinaryMessenger` (wt :11) | If the messenger is not a constructor parameter, take it from where `channel = MethodChannel(…)` gets it. |
| A6 | `git grep -n -A8 "void didChangeAppLifecycleState" -- lib/core/screens/profile_workspace_screen.dart` | a set `{paused, hidden, detached}.contains(state)` → `_cancelVoice();` (wt :612-619, up :912-919) | Different shape → put the `keepsVoice` guard on whatever condition calls `_cancelVoice()` for those states. |
| A7 | `git grep -n "_hasWorkspaceFocus || _destination != AppDestination.chats\|        _hasChatFocus &&" -- lib/core/screens/profile_workspace_screen.dart` | 2 hits: `_speakCompletedReply` (wt :239), `_canContinueConversation` (wt :282) | If the loop moved into another file (e.g. a conversation controller), apply the `_loopFocus` change there. If the loop is gone, **stop**, `FRAGE:`. |
| A8 | `git grep -n "set _conversation(" -- lib/core/screens/profile_workspace_screen.dart` | 1 hit (wt :217) | Missing → find where `VoiceSwitchHolders.screenOn(_voiceDevice).set(this, …)` follows the conversation key and sync there. |
| A9 | `git grep -n "_car.active" -- lib/core/screens/profile_workspace_screen.dart` | hits → car mode merged | No hits → leave out `&& !_car.active` in Task 4, and add a line to the Task 4 commit message: "car mode must add `&& !_car.active` to the `_background.sync` want". |
| A10 | `git grep -n "void _openListen\|late final _bargeIn\|void initState()" -- lib/core/screens/profile_workspace_screen.dart` | 3 hits → barge-in merged (`_openListen`, the `_bargeIn` field, `initState`) | No `_openListen` hit → run Task 5 Steps 1–7 only, skip Steps 8–11, leave out the Task 4 `listenTurn(false)` line, and add to the Task 6 commit message: "barge-in must add `_bargeIn.addListener(() => _background.listening(_bargeIn.listening));` to initState". |
| A11 | `git grep -n "_completedReplies.add" -- lib/core/services/profile_workspace_controller.dart` | 1 hit (wt :6124), no lifecycle/visibility condition in the enclosing `if` | If a foreground flag now gates it, or `setForeground`/`setActive` closes event streams in the background, the loop cannot hear replies → **stop**, `FRAGE:`. |
| A12 | `git grep -n "setForeground\|_supervision?.setActive" -- lib/main.dart lib/core/screens/profile_workspace_screen.dart lib/core/services/profile_workspace_registry.dart` | upstream `setForeground` only toggles group notifications (up registry :40-45) | Read each hit. If any closes sockets or stops turn events when not resumed → **stop**, `FRAGE:`. |
| A13 | `git grep -n "noSpeechTimeout = const Duration(seconds: 8)\|vadNoSpeechChoices" -- lib/core/services` | 2 hits (`vad_endpoint.dart:24`, `voice_preferences.dart:52`) | Changed default → update the spec §8 value and the device Step 7 expectation. |
| A14 | `git grep -n "var activityVisible" -- android/app/src/main/kotlin/com/tarkilhk/wing/MonitoringRuntime.kt` | 1 hit (wt :18) | Renamed → use the new visibility flag in Task 2 `refusal()`. Gone → use `activity.hasWindowFocus()` plus a lifecycle check. |
| A15 | `git grep -n "FOREGROUND_SERVICE_MICROPHONE\|BackgroundVoiceService" -- android lib` | no hits | Hits → someone added it; **stop**, `FRAGE:`. |
| A16 | `git grep -n "namespace = \|ic_stat_monitoring" -- android/app/build.gradle.kts android/app/src/main/kotlin/com/tarkilhk/wing/BackgroundMonitoringService.kt` | `namespace = "com.tarkilhk.wing"` and `R.drawable.ic_stat_monitoring` | Different namespace → adjust the `import …R` in Task 2. |
| A17 | `git grep -n "Future<void> show(\|Future<void> vadRoute()\|Future<void> windows(\|Future<void> settle(" -- test/voice_workspace_test.dart` | 4 hits (wt :95, :454, :458, :260) | Renamed → use the new helper names in Task 4. |
| A18 | `git grep -n "finishedOnItsOwn = " -- lib/core/controllers/voice_input_controller.dart` | `!_stopRequested && _remote == null` (wt :236) | If route hermes can now continue a conversation, it still stays excluded (spec §1); no change. |

- [ ] **Step 3: Android documentation**

Try to fetch the pages listed in spec §3 (P1–P9). For each page that loads, replace that row's "ANNAHME" with a
verbatim quote and the URL in the spec. If none load, leave §3 unchanged; the device acceptance (Task 8) proves each
row.

- [ ] **Step 4: Commit the basis**

```bash
git commit --allow-empty -m "chore(voice-bg): basis anchors A1-A18 ok / moved: <list>" -m "BASE=<sha from Step 1>"
```

(If Step 3 changed the spec, `git add` it first and drop `--allow-empty`.)

---

### Task 1: Dart `BackgroundVoice` policy and host

**Files:**
- Create: `lib/voice_offline/background_voice.dart`
- Create: `test/support/background_voice_fixture.dart`
- Test: `test/voice_offline/background_voice_test.dart`

**Interfaces:**
- Produces (used by Task 4):
  - `abstract interface class BackgroundVoiceHost { Future<bool> hold(bool on); Stream<String> get stopped; }`
  - `AndroidBackgroundVoiceHost.instance`
  - `class BackgroundVoice` with:
    - constructor `BackgroundVoice(BackgroundVoiceHost host, {required VoidCallback onStopped})`
    - `bool get held`, `bool get screenOff`
    - `void sync({required bool want})`
    - `bool keepsVoice(AppLifecycleState state)`
    - `void lifecycle(AppLifecycleState state)`
    - `void dispose()`
  - `class BackgroundVoiceFixture implements BackgroundVoiceHost` with `holds`, `grant`,
    `void stop(String reason)`, `Future<void> close()`.
- Produces (used by Task 2): the channel contract.
  - Dart → native `hold {on: bool}` → `{held: bool, reason?: String}`.
  - Native → Dart `stopped {reason: String}`.

- [ ] **Step 1: Write the failing unit tests**

`test/voice_offline/background_voice_test.dart`:

```dart
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/voice_offline/background_voice.dart';

class _Host implements BackgroundVoiceHost {
  final holds = <bool>[];
  final controller = StreamController<String>.broadcast(sync: true);
  Completer<bool>? next;
  bool grant = true;
  Object? error;

  @override
  Stream<String> get stopped => controller.stream;

  @override
  Future<bool> hold(bool on) async {
    holds.add(on);
    if (error != null) throw error!;
    final pending = next;
    if (pending != null) {
      next = null;
      return pending.future;
    }
    return on && grant;
  }
}

void main() {
  late _Host host;
  late BackgroundVoice voice;
  var stops = 0;
  setUp(() {
    host = _Host();
    stops = 0;
    voice = BackgroundVoice(host, onStopped: () => stops++);
  });
  tearDown(() => host.controller.close());

  test('holds once and releases once', () async {
    voice.sync(want: true);
    voice.sync(want: true);
    await pumpEventQueue();
    expect(host.holds, [true]);
    expect(voice.held, isTrue);
    voice.sync(want: false);
    await pumpEventQueue();
    expect(host.holds, [true, false]);
    expect(voice.held, isFalse);
  });

  test('a release during a pending hold runs after it', () async {
    host.next = Completer<bool>();
    voice.sync(want: true);
    await pumpEventQueue();
    voice.sync(want: false);
    await pumpEventQueue();
    expect(host.holds, [true]);
    host.next!.complete(true);
    await pumpEventQueue();
    expect(host.holds, [true, false]);
    expect(voice.held, isFalse);
  });

  test('want and unwant before the first call never holds', () async {
    voice.sync(want: true);
    voice.sync(want: false);
    await pumpEventQueue();
    expect(host.holds, isEmpty);
  });

  test('a refused or failing hold stays unheld', () async {
    host.grant = false;
    voice.sync(want: true);
    await pumpEventQueue();
    expect(voice.held, isFalse);
    expect(voice.keepsVoice(AppLifecycleState.paused), isFalse);
    voice.sync(want: false);
    host.error = StateError('channel');
    voice.sync(want: true);
    await pumpEventQueue();
    expect(voice.held, isFalse);
  });

  test('a native stop calls onStopped once and allows a new hold', () async {
    voice.sync(want: true);
    await pumpEventQueue();
    host.controller.add('notification');
    host.controller.add('notification');
    expect(stops, 1);
    expect(voice.held, isFalse);
    voice.sync(want: true);
    await pumpEventQueue();
    expect(host.holds, [true, true]);
  });

  test('a stop while not held is ignored', () async {
    host.controller.add('call');
    expect(stops, 0);
  });

  test('keepsVoice and screenOff follow the hold and lifecycle', () async {
    expect(voice.keepsVoice(AppLifecycleState.paused), isFalse);
    voice.sync(want: true);
    await pumpEventQueue();
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      expect(voice.keepsVoice(s), isTrue, reason: s.name);
    }
    expect(voice.keepsVoice(AppLifecycleState.detached), isFalse);
    expect(voice.screenOff, isFalse);
    voice.lifecycle(AppLifecycleState.paused);
    expect(voice.screenOff, isTrue);
    voice.lifecycle(AppLifecycleState.resumed);
    expect(voice.screenOff, isFalse);
  });

  test('dispose releases a hold and ignores later syncs', () async {
    voice.sync(want: true);
    await pumpEventQueue();
    voice.dispose();
    voice.sync(want: true);
    await pumpEventQueue();
    expect(host.holds, [true, false]);
  });
}
```

- [ ] **Step 2: Commit the test and run it to see it fail**

```bash
git add test/voice_offline/background_voice_test.dart
git commit -m "test(voice-bg): background voice policy"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/background_voice_test.dart`
Expected: `ci-suite: run <id> conclusion=failure`, because `background_voice.dart` does not exist (the analyzer
reports a missing import).

- [ ] **Step 3: Implement `lib/voice_offline/background_voice.dart`**

```dart
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Native side of a conversation that continues with the screen off
/// (spec 2026-10-14 background): a microphone foreground service.
abstract interface class BackgroundVoiceHost {
  /// Starts or stops the hold. Resolves to whether it is held.
  Future<bool> hold(bool on);

  /// Reasons the native side ended the hold on its own:
  /// notification, dismissed, call, activityClosed.
  Stream<String> get stopped;
}

class AndroidBackgroundVoiceHost implements BackgroundVoiceHost {
  AndroidBackgroundVoiceHost._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'stopped') return;
      final args = call.arguments;
      _stopped.add(args is Map ? '${args['reason']}' : 'unknown');
    });
  }

  static final instance = AndroidBackgroundVoiceHost._();
  static const _channel = MethodChannel('com.tarkilhk.wing/background_voice');
  final _stopped = StreamController<String>.broadcast();

  @override
  Stream<String> get stopped => _stopped.stream;

  @override
  Future<bool> hold(bool on) async {
    final result = await _channel.invokeMapMethod<String, Object?>('hold', {
      'on': on,
    });
    return result?['held'] == true;
  }
}

/// Holds the microphone service while a vad conversation runs, so a lifecycle
/// pause no longer ends it. Calls to the host are serialised; each one
/// applies the latest wish.
class BackgroundVoice {
  BackgroundVoice(this._host, {required VoidCallback onStopped}) {
    _subscription = _host.stopped.listen((_) {
      if (!_held) return;
      _held = false;
      _want = false;
      onStopped();
    });
  }

  final BackgroundVoiceHost _host;
  late final StreamSubscription<String> _subscription;
  Future<void> _queue = Future.value();
  bool _held = false;
  bool _want = false;
  bool _resumed = true;
  bool _disposed = false;

  bool get held => _held;

  /// Held while Wing is not in the foreground (screen off, other app).
  bool get screenOff => _held && !_resumed;

  void sync({required bool want}) {
    if (_disposed || want == _want) return;
    _want = want;
    _queue = _queue.then((_) => _apply());
  }

  Future<void> _apply() async {
    final want = _want && !_disposed;
    if (want == _held) return;
    bool held;
    try {
      held = await _host.hold(want);
    } on Object {
      held = false;
    }
    _held = want && held;
  }

  /// A detached engine loses its view: voice ends as before.
  bool keepsVoice(AppLifecycleState state) =>
      _held && state != AppLifecycleState.detached;

  void lifecycle(AppLifecycleState state) =>
      _resumed = state == AppLifecycleState.resumed;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _queue = _queue.then((_) => _apply());
    unawaited(_subscription.cancel());
  }
}
```

- [ ] **Step 4: Create the widget-test fixture `test/support/background_voice_fixture.dart`**

```dart
import 'dart:async';

import 'package:wing/voice_offline/background_voice.dart';

class BackgroundVoiceFixture implements BackgroundVoiceHost {
  final holds = <bool>[];
  bool grant = true;
  final _stopped = StreamController<String>.broadcast(sync: true);

  @override
  Stream<String> get stopped => _stopped.stream;

  @override
  Future<bool> hold(bool on) async {
    holds.add(on);
    return on && grant;
  }

  /// Simulates the notification Stop, a swipe or a call.
  void stop(String reason) => _stopped.add(reason);

  Future<void> close() => _stopped.close();
}
```

- [ ] **Step 5: Commit and run**

```bash
git add lib/voice_offline/background_voice.dart test/support/background_voice_fixture.dart
git commit -m "feat(voice-bg): background voice hold policy"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/background_voice_test.dart`
Expected: `ci-suite: run <id> conclusion=success`.

---

### Task 2: Kotlin microphone service, channel and manifest

**Files:**
- Create: `android/app/src/main/kotlin/com/tarkilhk/wing/voicebackground/BackgroundVoiceService.kt`
- Create: `android/app/src/main/kotlin/com/tarkilhk/wing/voicebackground/BackgroundVoiceChannel.kt`
- Modify: `android/app/src/main/AndroidManifest.xml` (wt: permissions :2-9, services :21-29)

**Interfaces:**
- Consumes: the Task 1 channel contract; `com.tarkilhk.wing.MonitoringRuntime.activityVisible` (A14);
  `com.tarkilhk.wing.MainActivity`; `R.drawable.ic_stat_monitoring` (A16).
- Produces (used by Task 3):
  - `BackgroundVoiceService.keepsVoice(): Boolean`, which logs `pause kept` when true;
  - `BackgroundVoiceChannel(activity: Activity, messenger: BinaryMessenger)` with `close()`.

- [ ] **Step 1: Create `BackgroundVoiceService.kt`**

```kotlin
package com.tarkilhk.wing.voicebackground

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.tarkilhk.wing.MainActivity
import com.tarkilhk.wing.R

/**
 * Microphone foreground service for a conversation that continues with the
 * screen off (spec 2026-10-14 background). It never records: it keeps the
 * process, CPU and while-in-use microphone access for the vad rounds Dart starts.
 */
class BackgroundVoiceService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var modeListener: Any? = null
    private var stopReason: String? = null
    private var heldAt = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            finish(intent.getStringExtra(EXTRA_REASON) ?: "notification")
            return START_NOT_STICKY
        }
        if (running) return START_NOT_STICKY
        val reply = pendingStart
        pendingStart = null
        try {
            val notification = notification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            if (reply == null) {
                // The caller gave up waiting: never hold a microphone nobody owns.
                stopReason = "released"
                stopSelf()
                return START_NOT_STICKY
            }
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:voice-conversation")
                .apply { setReferenceCounted(false); acquire() }
            watchCalls()
            running = true
            heldAt = SystemClock.elapsedRealtime()
            Log.i(TAG, "hold on")
            reply(true)
        } catch (_: Exception) {
            Log.i(TAG, "hold refused reason=startFailed")
            reply?.invoke(false)
            stopReason = "startFailed"
            stopSelf()
        }
        // Reopening Wing starts a new conversation; never resurrect a microphone.
        return START_NOT_STICKY
    }

    private fun finish(reason: String) {
        if (stopReason != null) return
        stopReason = reason
        Log.i(TAG, "stop reason=$reason")
        onStopped?.invoke(reason)
        stopSelf()
    }

    private fun watchCalls() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val listener = AudioManager.OnModeChangedListener { mode -> if (mode in callModes) finish("call") }
        getSystemService(AudioManager::class.java).addOnModeChangedListener(mainExecutor, listener)
        modeListener = listener
    }

    private fun notification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Voice conversation", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shows while conversation mode can open the microphone"
                    setShowBadge(false)
                },
            )
        }
        val open = PendingIntent.getActivity(
            this, NOTIFICATION_ID,
            Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
                addCategory(Intent.CATEGORY_LAUNCHER)
                this.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_monitoring)
            .setContentTitle("Conversation mode")
            .setContentText("Microphone opens after each reply.")
            .setContentIntent(open)
            .setDeleteIntent(stopIntent("dismissed", 1))
            .addAction(0, "Stop", stopIntent("notification", 2))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun stopIntent(reason: String, code: Int): PendingIntent = PendingIntent.getService(
        this, code,
        Intent(this, BackgroundVoiceService::class.java).setAction(ACTION_STOP).putExtra(EXTRA_REASON, reason),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    override fun onDestroy() {
        running = false
        if (stopReason == null) Log.i(TAG, "stop reason=released")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (modeListener as? AudioManager.OnModeChangedListener)?.let {
                getSystemService(AudioManager::class.java).removeOnModeChangedListener(it)
            }
        }
        modeListener = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        if (heldAt > 0) Log.i(TAG, "wakelock released heldMs=${SystemClock.elapsedRealtime() - heldAt}")
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    companion object {
        const val TAG = "WingBgVoice"
        const val ACTION_STOP = "com.tarkilhk.wing.voicebackground.STOP"
        private const val EXTRA_REASON = "reason"
        private const val CHANNEL_ID = "voice_conversation"
        private const val NOTIFICATION_ID = 214611
        private val callModes = setOf(
            AudioManager.MODE_RINGTONE, AudioManager.MODE_IN_CALL,
            AudioManager.MODE_IN_COMMUNICATION, AudioManager.MODE_CALL_SCREENING,
        )

        @Volatile var running = false
            private set

        /** Answer for the Dart `hold(true)` that started this service. */
        var pendingStart: ((Boolean) -> Unit)? = null

        /** Forwards a native stop (notification, dismissed, call) to Dart. */
        var onStopped: ((String) -> Unit)? = null

        /** Hook for VoiceChannel.pause(): true keeps the vad round and playback. */
        fun keepsVoice(): Boolean {
            if (running) Log.i(TAG, "pause kept")
            return running
        }

        fun notificationsAllowed(context: Context): Boolean {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
            val channel = context.getSystemService(NotificationManager::class.java).getNotificationChannel(CHANNEL_ID)
            return channel == null || channel.importance != NotificationManager.IMPORTANCE_NONE
        }
    }
}
```

- [ ] **Step 2: Create `BackgroundVoiceChannel.kt`**

```kotlin
package com.tarkilhk.wing.voicebackground

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import com.tarkilhk.wing.MonitoringRuntime
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Dart control of [BackgroundVoiceService]; a hold starts only while Wing is visible. */
class BackgroundVoiceChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.tarkilhk.wing/background_voice")
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(::handle)
        BackgroundVoiceService.onStopped = { reason -> channel.invokeMethod("stopped", mapOf("reason" to reason)) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "hold") return result.notImplemented()
        if (call.argument<Boolean>("on") != true) {
            release()
            return result.success(mapOf("held" to false))
        }
        if (BackgroundVoiceService.running) return result.success(mapOf("held" to true))
        val refused = refusal()
        if (refused != null) {
            Log.i(BackgroundVoiceService.TAG, "hold refused reason=$refused")
            return result.success(mapOf("held" to false, "reason" to refused))
        }
        val reply: (Boolean) -> Unit = { held -> result.success(mapOf("held" to held)) }
        BackgroundVoiceService.pendingStart = reply
        try {
            ContextCompat.startForegroundService(activity, Intent(activity, BackgroundVoiceService::class.java))
        } catch (_: Exception) {
            BackgroundVoiceService.pendingStart = null
            Log.i(BackgroundVoiceService.TAG, "hold refused reason=startFailed")
            return result.success(mapOf("held" to false, "reason" to "startFailed"))
        }
        main.postDelayed({
            if (BackgroundVoiceService.pendingStart === reply) {
                BackgroundVoiceService.pendingStart = null
                Log.i(BackgroundVoiceService.TAG, "hold refused reason=startTimeout")
                reply(false)
            }
        }, START_TIMEOUT_MS)
    }

    private fun refusal(): String? = when {
        !MonitoringRuntime.activityVisible -> "notVisible"
        activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED -> "permission"
        !BackgroundVoiceService.notificationsAllowed(activity) -> "notifications"
        else -> null
    }

    private fun release() {
        if (BackgroundVoiceService.running) activity.stopService(Intent(activity, BackgroundVoiceService::class.java))
    }

    fun close() {
        if (BackgroundVoiceService.running) {
            Log.i(BackgroundVoiceService.TAG, "stop reason=activityClosed")
            BackgroundVoiceService.onStopped?.invoke("activityClosed")
            release()
        }
        BackgroundVoiceService.onStopped = null
        channel.setMethodCallHandler(null)
    }

    private companion object { const val START_TIMEOUT_MS = 5_000L }
}
```

- [ ] **Step 3: Manifest (≤ 8 lines)**

After the line `<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE" />` (wt :7) add:

```xml
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
```

After the closing `</service>` of `.BackgroundMonitoringService` (wt :29) add:

```xml
        <service
            android:name=".voicebackground.BackgroundVoiceService"
            android:exported="false"
            android:foregroundServiceType="microphone" />
```

- [ ] **Step 4: Commit and run the Kotlin compile check**

```bash
git add android/app/src/main/kotlin/com/tarkilhk/wing/voicebackground android/app/src/main/AndroidManifest.xml
git commit -m "feat(voice-bg): microphone foreground service with stop notification"
```

Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: `dispatch-check: voice-apk.yml run <id> conclusion=success …`. The class is not yet constructed anywhere;
this step only proves it compiles and the manifest merges.

---

### Task 3: `VoiceChannel.kt` hook (≤ 7 lines)

**Files:**
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt` (wt: imports :3-9, field after :20, `pause` :123,
  `close` :125-129)

**Interfaces:**
- Consumes: `BackgroundVoiceService.keepsVoice()` and `BackgroundVoiceChannel(activity, messenger).close()` (Task 2).

- [ ] **Step 1: Imports (2 lines)**, next to the other imports:

```kotlin
import com.tarkilhk.wing.voicebackground.BackgroundVoiceChannel
import com.tarkilhk.wing.voicebackground.BackgroundVoiceService
```

- [ ] **Step 2: Field (1 line)**, directly after `private val mediaKeys = VoiceMediaKeys(activity, ::emit)`:

```kotlin
    private val background = BackgroundVoiceChannel(activity, messenger)
```

- [ ] **Step 3: `pause()` guard (1 line).** It must be the first statement of `pause()`; on the upstream-merged
version that is right after `if (closed) return` (A3). For the wt one-liner, replace:

```kotlin
    fun pause() { capture.pause(); vad.pause(); playback.stop(); mediaKeys.pause() }
```

with:

```kotlin
    fun pause() { if (BackgroundVoiceService.keepsVoice()) { capture.pause(); mediaKeys.pause(); return }; capture.pause(); vad.pause(); playback.stop(); mediaKeys.pause() }
```

In the multi-line upstream form, the inserted line is:

```kotlin
        if (BackgroundVoiceService.keepsVoice()) { capture.pause(); mediaKeys.pause(); return } // spec 2026-10-14 background
```

`capture.pause()` still runs: routes `local`/`hermes` are never held, and their capture keeps today's behaviour.
Media keys stay foreground-only.

- [ ] **Step 4: `close()` (1 line).** Make `background.close()` the first statement of `close()` (after
`if (closed) return` if present):

```kotlin
        background.close()
```

- [ ] **Step 5: Commit and run the compile check**

```bash
git add android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt
git commit -m "feat(voice-bg): voice channel keeps a held conversation on pause"
```

Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: `conclusion=success`.

Run: `git diff --numstat HEAD~1 HEAD -- android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt`
Expected: added ≤ 7, deleted ≤ 1.

---

### Task 4: Workspace hooks and widget tests (≤ 20 lines in the screen)

**Files:**
- Modify: `lib/core/screens/profile_workspace_screen.dart`, at these wt locations:

  | Location | wt line |
  |---|---|
  | imports | top |
  | widget field | :94 |
  | constructor | :110 |
  | state fields | after :176 |
  | setter | :217-222 |
  | `_speakCompletedReply` | :239 |
  | `_canContinueConversation` | :282 |
  | focus getters | :552-555 |
  | lifecycle | :612-620 |
  | dispose | :660 |

- Modify: `test/voice_workspace_test.dart` (setUp :70-90, tearDown :91-94, `show` :114-118, new group after the vad
  tests, ~:543)

**Interfaces:**
- Consumes: Task 1 `BackgroundVoice`, `AndroidBackgroundVoiceHost.instance`, `BackgroundVoiceFixture`.
- Produces (Task 5): the field `_background` (`BackgroundVoice`) and the test helpers `startVadConversation`,
  `speakAndSend`, `screenOff`, `screenOn` inside group "screen off".

- [ ] **Step 1: Wire the fixture into the test harness**

In `test/voice_workspace_test.dart`:
- add `import 'support/background_voice_fixture.dart';`;
- add `late BackgroundVoiceFixture background;` next to `device`;
- in `setUp` after `device = VoiceDeviceFixture();` add `background = BackgroundVoiceFixture();`;
- in `tearDown` add `await background.close();`;
- in `show()` add `backgroundVoice: background,` after `voiceDevice: device,`.

- [ ] **Step 2: Write the failing widget tests**, directly after the test
`'route vad preloads the model and enables media keys'`:

```dart
  group('screen off', () {
    Future<void> startVadConversation(WidgetTester tester) async {
      // Only if A10 found barge-in: these tests count VAD starts, so listen
      // rounds stay off here; Task 5 switches them on explicitly.
      await listenTurn(false);
      await vadRoute();
      await conversationMode(true);
      await show(tester);
      await tester.tap(find.byTooltip('Dictate message'));
      await settle(tester);
    }

    Future<void> speakAndSend(WidgetTester tester) async {
      await windows(tester, 0.9, 30);
      await windows(tester, 0.1, 60);
    }

    void screenOff(WidgetTester tester) => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.paused);

    void screenOn(WidgetTester tester) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }

    testWidgets('a vad conversation holds while it runs', (tester) async {
      await startVadConversation(tester);
      expect(background.holds, [true]);
      await tester.tap(find.text('Cancel recording'));
      await settle(tester);
      expect(background.holds, [true, false]);
    });

    testWidgets('the local route never holds and still cancels', (
      tester,
    ) async {
      await conversationMode(true);
      await show(tester);
      await tester.tap(find.byTooltip('Dictate message'));
      await settle(tester);
      final id = device.recording;
      screenOff(tester);
      await tester.pump();
      expect(background.holds, isEmpty);
      expect(device.cancelled, contains(id));
      screenOn(tester);
      await settle(tester);
    });

    testWidgets('reading continues and the microphone reopens', (
      tester,
    ) async {
      device.playbackDelay = Completer<void>();
      await startVadConversation(tester);
      await speakAndSend(tester);
      expect(prompts(), 1);
      gatewayEvent('message.complete', {'text': 'Answer.'});
      await tester.pump();
      await tester.pump();
      expect(device.calls, contains('speak'));
      screenOff(tester);
      await tester.pump();
      expect(device.calls, isNot(contains('stopPlayback')));
      device.playbackDelay!.complete();
      device.playbackDelay = null;
      await settle(tester);
      expect(vadStarts(), 2);
      await speakAndSend(tester);
      expect(prompts(), 2);
      await completeReply(tester, 'Answer two.');
      expect(vadStarts(), 3);
      screenOn(tester);
      await tester.tap(find.text('Cancel recording'));
      await settle(tester);
    });

    testWidgets('a reply that arrives with the screen off is spoken', (
      tester,
    ) async {
      await startVadConversation(tester);
      await speakAndSend(tester);
      screenOff(tester);
      await tester.pump();
      await completeReply(tester, 'Pocket answer.');
      expect(device.spoken, 'Pocket answer.');
      expect(vadStarts(), 2);
      screenOn(tester);
      await tester.tap(find.text('Cancel recording'));
      await settle(tester);
    });

    testWidgets('no speech ends the conversation and releases the hold', (
      tester,
    ) async {
      await startVadConversation(tester);
      await speakAndSend(tester);
      screenOff(tester);
      await completeReply(tester);
      expect(vadStarts(), 2);
      await windows(tester, 0.05, 251);
      expect(device.finishes.last.reason.name, 'noSpeech');
      expect(background.holds.last, isFalse);
      expect(device.keepScreenOnCalls.last, isFalse);
      screenOn(tester);
      await settle(tester);
    });

    testWidgets('notification Stop ends the conversation', (tester) async {
      await startVadConversation(tester);
      final id = device.recording;
      screenOff(tester);
      await tester.pump();
      background.stop('notification');
      await settle(tester);
      expect(device.cancelled, contains(id));
      expect(background.holds, [true]);
      expect(device.keepScreenOnCalls.last, isFalse);
      controller.current!.chat!.status = ProfileTurnStatus.running;
      await completeReply(tester, 'Late reply.');
      expect(vadStarts(), 1);
      screenOn(tester);
      await settle(tester);
    });

    testWidgets('a refused hold cancels on pause as before', (tester) async {
      background.grant = false;
      await startVadConversation(tester);
      final id = device.recording;
      screenOff(tester);
      await tester.pump();
      expect(device.cancelled, contains(id));
      screenOn(tester);
      await settle(tester);
    });
  });
```

If A10 found no barge-in, leave out the `listenTurn(false)` line and its comment (the helper does not exist). With
barge-in, `listenTurn` is the helper the barge-in plan put next to `vadRoute()`.

If car mode is merged (A9 has hits), add one more test inside the group. The car-mode test group shows how car mode
is entered (look for `group('car mode'` in the same file):

```dart
    testWidgets('car mode never holds', (tester) async {
      await vadRoute();
      await conversationMode(true);
      await show(tester);
      // Enter car mode exactly as the existing car mode tests do, then start
      // a round with the car mode microphone control.
      expect(background.holds, isEmpty);
    });
```

Replace the comment with the two statements the car-mode tests use to enter car mode and start a round. They are in
the car-mode group of the same file; copy them verbatim.

- [ ] **Step 3: Commit the tests and run them to see them fail**

```bash
git add test/voice_workspace_test.dart
git commit -m "test(voice-bg): conversation continues with the screen off"
```

Run: `bash tools/factory/ci-suite.sh test/voice_workspace_test.dart`
Expected: `conclusion=failure` (`backgroundVoice` is not a parameter of `ProfileWorkspaceScreen`).

- [ ] **Step 4: Implement the hooks** (count every added or changed line; total ≤ 20)

4a. Import (1), next to the other relative imports:

```dart
import '../../voice_offline/background_voice.dart';
```

4b. Widget field and constructor (2). After `final VoiceDevice? voiceDevice;`:

```dart
  final BackgroundVoiceHost? backgroundVoice;
```

After `this.voiceDevice,`:

```dart
    this.backgroundVoice,
```

4c. State field (4), directly after the `late final _voiceOutput = VoiceOutputController(…);` declaration:

```dart
  late final _background = BackgroundVoice(
    widget.backgroundVoice ?? AndroidBackgroundVoiceHost.instance,
    onStopped: _cancelVoice,
  );
```

4d. `_conversation` setter (1). As its last statement (after `_conversationKey = value;`):

```dart
    _background.sync(want: value != null && _vadRoute() == true);
```

With car mode merged (A9), use instead:

```dart
    _background.sync(want: value != null && _vadRoute() == true && !_car.active);
```

4e. `_loopFocus` (4), directly after the `_hasChatFocus` getter:

```dart
  /// Chat focus for the conversation loop; a held hold also counts when the app is paused (spec 2026-10-14).
  bool get _loopFocus =>
      _routeIsCurrent && _destination == AppDestination.chats &&
      (_appIsActive || _background.held);
```

4f. `_speakCompletedReply` (1). Replace:

```dart
    if (!mounted || !_hasWorkspaceFocus || _destination != AppDestination.chats) {
```

with:

```dart
    if (!mounted || !_loopFocus) {
```

4g. `_canContinueConversation` (1). Replace the line `        _hasChatFocus &&` with `        _loopFocus &&`.

4h. Lifecycle (2). Replace `    }.contains(state)) {` (the line before `_cancelVoice();` in
`didChangeAppLifecycleState`) with:

```dart
    }.contains(state) && !_background.keepsVoice(state)) {
```

Directly after the closing `}` of that `if`, add:

```dart
    _background.lifecycle(state);
```

4i. Dispose (1). Directly after `_voiceOutput.dispose();`:

```dart
    _background.dispose();
```

Total: 1 + 2 + 4 + 1 + 4 + 1 + 1 + 2 + 1 = 17 lines.

- [ ] **Step 5: Commit and run**

```bash
git add lib/core/screens/profile_workspace_screen.dart
git commit -m "feat(voice-bg): conversation keeps running while held in the background"
```

If A9 found no car mode, add a second `-m` with: `car mode must add && !_car.active to the _background.sync want`.

Run: `bash tools/factory/ci-suite.sh test/voice_workspace_test.dart`
Expected: `conclusion=success`. The existing tests stay green, including:
- `'backgrounding cancels capture without changing draft'`;
- `'backgrounding during the spoken reply ends the conversation'`;
- `'backgrounding releases media keys and resume restores them'`.

These are local or route-vad tests without a conversation, so they never hold.

Run: `git diff --numstat HEAD~1 HEAD -- lib/core/screens/profile_workspace_screen.dart`
Expected: added ≤ 20.

---

### Task 5: The notification shows an open listen round (D2-b)

D2-b lets barge-in listen rounds run with the screen off, so the microphone can stay open for a whole Hermes turn.
Nothing is gated; this task only makes that visible. While a listen round is open and the hold is active, the
notification text reads "Microphone is listening." and returns to "Microphone opens after each reply." when the round
closes. Steps 1–7 (own files) always run. Steps 8–11 (screen hook) run only if A10 found `_openListen`; otherwise the
barge-in card adds the one hook line (A10).

**Files:**
- Modify: `lib/voice_offline/background_voice.dart` (Task 1)
- Modify: `test/support/background_voice_fixture.dart` (Task 1)
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/voicebackground/BackgroundVoiceService.kt` (Task 2)
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/voicebackground/BackgroundVoiceChannel.kt` (Task 2)
- Modify (only with A10): `lib/core/screens/profile_workspace_screen.dart`, 1 line in `initState`; the screen total
  becomes 17 + 1 = 18 of ≤ 20. The cap does not move.
- Test: `test/voice_offline/background_voice_test.dart`
- Test (only with A10): `test/voice_workspace_test.dart` (group "screen off")

**Interfaces:**
- Consumes: Task 1 `BackgroundVoice`, `BackgroundVoiceHost`; Task 2 `BackgroundVoiceService`; Task 4 `_background`
  and the group "screen off" helpers; barge-in `_bargeIn` (`BargeInCoordinator extends ChangeNotifier`,
  `bool get listening`, barge-in plan Task 8/9), `listenTurn(bool)` and `fixture.rpcResponses` (barge-in plan Task 9).
- Produces:
  - `BackgroundVoiceHost.listening(bool on)` → `Future<void>`;
  - `BackgroundVoice.listening(bool on)` → `void` (deduplicated; forwarded only while held; re-applied when a hold
    starts; reset when a hold ends);
  - `BackgroundVoiceFixture.listens` (`List<bool>`);
  - channel contract: Dart → native `listening {on: bool}` → `null`;
  - `BackgroundVoiceService.listening(on: Boolean)`, which logs `listening on` / `listening off`.

- [ ] **Step 1: Write the failing unit tests**

In `test/voice_offline/background_voice_test.dart`, extend `_Host` with these members:

```dart
  final listens = <bool>[];
  Object? listenError;

  @override
  Future<void> listening(bool on) async {
    listens.add(on);
    if (listenError != null) throw listenError!;
  }
```

Append inside `main()`:

```dart
  test('listening is forwarded once per change while held', () async {
    voice.sync(want: true);
    await pumpEventQueue();
    voice.listening(true);
    voice.listening(true);
    await pumpEventQueue();
    expect(host.listens, [true]);
    voice.listening(false);
    await pumpEventQueue();
    expect(host.listens, [true, false]);
  });

  test('listening before a hold is shown once the hold starts', () async {
    voice.listening(true);
    await pumpEventQueue();
    expect(host.listens, isEmpty);
    voice.sync(want: true);
    await pumpEventQueue();
    expect(host.listens, [true]);
  });

  test('a native stop ends the listening state with the hold', () async {
    voice.sync(want: true);
    voice.listening(true);
    await pumpEventQueue();
    host.controller.add('call');
    voice.listening(false);
    await pumpEventQueue();
    expect(host.listens, [true]);
    voice.sync(want: true);
    await pumpEventQueue();
    expect(host.listens, [true]);
  });

  test('a failing listening update keeps the hold', () async {
    voice.sync(want: true);
    await pumpEventQueue();
    host.listenError = StateError('channel');
    voice.listening(true);
    await pumpEventQueue();
    expect(host.listens, [true]);
    expect(voice.held, isTrue);
  });
```

- [ ] **Step 2: Commit the tests and run them to see them fail**

```bash
git add test/voice_offline/background_voice_test.dart
git commit -m "test(voice-bg): notification shows an open listen round"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/background_voice_test.dart`
Expected: `ci-suite: run <id> conclusion=failure` (the analyzer reports that `listening` is not defined for
`BackgroundVoice` and that `_Host.listening` overrides nothing).

- [ ] **Step 3: Dart implementation in `lib/voice_offline/background_voice.dart`**

In `BackgroundVoiceHost`, after `Stream<String> get stopped;` add:

```dart

  /// Shows whether a barge-in listen round has the microphone open.
  Future<void> listening(bool on);
```

In `AndroidBackgroundVoiceHost`, after `hold`, add:

```dart

  @override
  Future<void> listening(bool on) =>
      _channel.invokeMethod<void>('listening', {'on': on});
```

In `BackgroundVoice`:
- in the `stopped` listener, after `_want = false;`, add `_shown = false;`;
- after `bool _disposed = false;` add:

```dart
  bool _listening = false;
  bool _shown = false;
```

- replace `_apply()` with:

```dart
  Future<void> _apply() async {
    final want = _want && !_disposed;
    if (want == _held) return;
    bool held;
    try {
      held = await _host.hold(want);
    } on Object {
      held = false;
    }
    _held = want && held;
    if (!_held) _shown = false;
    await _show();
  }
```

- after `sync`, add:

```dart
  /// A barge-in listen round opened or closed (spec 2026-10-14 background,
  /// D2-b). The notification says so while the hold is active.
  void listening(bool on) {
    if (_disposed || on == _listening) return;
    _listening = on;
    _queue = _queue.then((_) => _show());
  }

  Future<void> _show() async {
    final on = _listening && _held;
    if (on == _shown) return;
    _shown = on;
    try {
      await _host.listening(on);
    } on Object {
      // The text is cosmetic; the hold and the Android indicator stay.
    }
  }
```

- [ ] **Step 4: Fixture.** In `test/support/background_voice_fixture.dart`, after `bool grant = true;` add:

```dart
  final listens = <bool>[];

  @override
  Future<void> listening(bool on) async => listens.add(on);
```

- [ ] **Step 5: Kotlin service.** In `BackgroundVoiceService.kt`:

5a. In `onStartCommand`, directly after `running = true` add:

```kotlin
            instance = this
```

5b. Change `private fun notification(): Notification {` to:

```kotlin
    private fun notification(listening: Boolean = false): Notification {
```

and `.setContentText("Microphone opens after each reply.")` to:

```kotlin
            .setContentText(if (listening) "Microphone is listening." else "Microphone opens after each reply.")
```

5c. In `onDestroy`, directly after `running = false` add:

```kotlin
        instance = null
```

5d. In the companion, after `var onStopped`, add:

```kotlin
        private var instance: BackgroundVoiceService? = null

        /** Barge-in listen round open or closed: updates the notification text only. */
        fun listening(on: Boolean) {
            val service = instance ?: return
            if (!notificationsAllowed(service)) return
            Log.i(TAG, if (on) "listening on" else "listening off")
            service.getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, service.notification(on))
        }
```

- [ ] **Step 6: Kotlin channel.** In `BackgroundVoiceChannel.kt`, replace the first line of `handle`
(`if (call.method != "hold") return result.notImplemented()`) with:

```kotlin
        if (call.method == "listening") {
            BackgroundVoiceService.listening(call.argument<Boolean>("on") == true)
            return result.success(null)
        }
        if (call.method != "hold") return result.notImplemented()
```

- [ ] **Step 7: Commit and run**

```bash
git add lib/voice_offline/background_voice.dart test/support/background_voice_fixture.dart android/app/src/main/kotlin/com/tarkilhk/wing/voicebackground
git commit -m "feat(voice-bg): notification text while a listen round is open"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/background_voice_test.dart`
Expected: `ci-suite: run <id> conclusion=success`.

Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: `dispatch-check: voice-apk.yml run <id> conclusion=success …`.

If A10 found no `_openListen`, stop here and go to Task 6.

- [ ] **Step 8: Write the failing widget tests** (only with A10), inside group "screen off":

```dart
    testWidgets('a listen round with the screen off shows in the notification', (
      tester,
    ) async {
      fixture.rpcResponses['session.steer'] = {
        'status': 'queued',
        'text': 'Pocket steer',
      };
      await startVadConversation(tester);
      await listenTurn(true);
      screenOff(tester);
      await tester.pump();
      await speakAndSend(tester);
      expect(prompts(), 1);
      expect(vadStarts(), 2);
      expect(background.listens.last, isTrue);
      device.vadTranscript = 'Pocket steer';
      await speakAndSend(tester);
      expect(
        fixture.calls.lastWhere((c) => c.$2 == 'session.steer').$3['text'],
        'Pocket steer',
      );
      expect(prompts(), 1);
      await completeReply(tester, 'Done.');
      expect(background.listens.first, isTrue);
      expect(background.listens.last, isFalse);
      expect(background.holds, [true]);
      screenOn(tester);
      await tester.tap(find.text('Cancel recording'));
      await settle(tester);
    });

    testWidgets('with listening off no listen round opens with the screen off', (
      tester,
    ) async {
      await startVadConversation(tester);
      screenOff(tester);
      await tester.pump();
      await speakAndSend(tester);
      expect(prompts(), 1);
      expect(vadStarts(), 1);
      await completeReply(tester, 'Done.');
      expect(vadStarts(), 2);
      expect(background.listens, isEmpty);
      screenOn(tester);
      await tester.tap(find.text('Cancel recording'));
      await settle(tester);
    });
```

The second test guards the switch and already passes; the first fails until Step 10.

- [ ] **Step 9: Commit the tests and run them to see them fail**

```bash
git add test/voice_workspace_test.dart
git commit -m "test(voice-bg): listen round with the screen off is visible"
```

Run: `bash tools/factory/ci-suite.sh test/voice_workspace_test.dart`
Expected: `conclusion=failure` (`background.listens` is empty in the first test).

- [ ] **Step 10: Screen hook (1 line).** Find `initState` with
`git grep -n "void initState()" -- lib/core/screens/profile_workspace_screen.dart`. Directly after its
`super.initState();` add:

```dart
    _bargeIn.addListener(() => _background.listening(_bargeIn.listening));
```

`_bargeIn` notifies on every listen phase change (barge-in `TurnListener._notify`); `BackgroundVoice.listening`
deduplicates. After `_background.dispose()` the callback is a no-op.

- [ ] **Step 11: Commit and run**

```bash
git add lib/core/screens/profile_workspace_screen.dart
git commit -m "feat(voice-bg): show open listen rounds in the conversation notification"
```

Run: `bash tools/factory/ci-suite.sh test/voice_workspace_test.dart`
Expected: `conclusion=success`; the barge-in tests stay green.

Run: `git diff --numstat HEAD~1 HEAD -- lib/core/screens/profile_workspace_screen.dart`
Expected: added 1, deleted 0.

---

### Task 6: Docs, caps and log privacy check

**Files:**
- Modify: `docs/VOICE.md` (wt :17)

**Interfaces:**
- Consumes: `BASE` (Task 0); the log line forms from Global Constraints.
- Produces: none.

- [ ] **Step 1: Docs.** In `docs/VOICE.md`, replace the sentence `During Conversation mode the screen stays on.` with:

```markdown
During Conversation mode the screen stays on. On the VAD input you can also switch the screen off or
pocket the phone: the conversation continues, and a "Conversation mode" notification with Stop shows
it. With "Listen while Hermes works" on, the microphone also stays open while Hermes works with the
screen off, so you can steer from your pocket; the notification then reads "Microphone is listening."
Switch that setting off to keep the microphone closed until the reply has been read. Interrupting the
read-aloud by speaking still needs headphones. Staying silent after a reply (the "Wait for speech"
time) ends the conversation, as do a phone call, Stop and swiping the notification away. Car mode
always keeps the screen on.
```

If A10 found no barge-in, leave out the sentences about "Listen while Hermes works" and read-aloud interruption;
the barge-in card adds them.

- [ ] **Step 2: Hook caps against BASE (Task 0)**

Run: `git diff --numstat <BASE> HEAD -- android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt`
Expected: added ≤ 7.

Run: `git diff --numstat <BASE> HEAD -- lib/core/screens/profile_workspace_screen.dart`
Expected: added ≤ 20.

Run: `git diff --numstat <BASE> HEAD -- android/app/src/main/AndroidManifest.xml`
Expected: added ≤ 8.

Run: `git diff --numstat <BASE> HEAD -- android/app/src/main/kotlin/com/tarkilhk/wing/MainActivity.kt android/app/src/main/kotlin/com/tarkilhk/wing/VoiceCapture.kt lib/core/controllers/voice_input_controller.dart lib/core/services/android_voice.dart`
Expected: no output.

- [ ] **Step 3: Log privacy**

Run: `git grep -n "Log\.\|debugPrint\|print(" -- android/app/src/main/kotlin/com/tarkilhk/wing/voicebackground lib/voice_offline/background_voice.dart`
Expected: only `Log.i(TAG, …)` / `Log.i(BackgroundVoiceService.TAG, …)` lines with the literals `hold on`,
`hold refused reason=…`, `pause kept`, `stop reason=…`, `wakelock released heldMs=…`, `listening on` and
`listening off` (Global Constraints). No `text`, `transcript` or `reply` argument.

- [ ] **Step 4: Commit and run the suite**

```bash
git add docs/VOICE.md
git commit -m "docs(voice-bg): conversation with the screen off"
```

If A10 found no `_openListen`, add a second `-m` with: `barge-in must add _bargeIn.addListener(() => _background.listening(_bargeIn.listening)); to initState`.

Run: `bash tools/factory/ci-suite.sh test/voice_workspace_test.dart`
Expected: `conclusion=success`.

---

### Task 7: Phone build

**Files:** none.

**Interfaces:**
- Produces: the APK used by Task 8.

- [ ] **Step 1:** Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=true`
Expected: `conclusion=success`. The APK for `com.tarkilhk.wing.voice` is published to `voice-apk-bin`, as in the VAD
plan Task 15.

---

### Task 8: Device acceptance on hadb [WORKER]

Run this on Birk's Sony Xperia (LineageOS) through `hadb`. Claude subagents never do it. One command per call. If
the phone is locked, ask Birk to unlock it (as in the VAD plan). Package: `com.tarkilhk.wing.voice`. Record only
pass/fail and numbers, never spoken text or log dumps, in the Results section (Step 20).

**Files:**
- Modify: `docs/superpowers/plans/2026-10-14-wing-voice-background.md` (Results section, Step 20 only).

**Interfaces:**
- Consumes: the Task 7 APK; the log line forms and notification copy from Global Constraints.
- Produces: none.

- [ ] **Step 1: Device facts**

Run: `hadb shell getprop ro.build.version.sdk`. Expected: a number; record it. ≥ 31 enables call detection (Step 10);
lower means Step 10 expects the fallback behaviour.

Run: `hadb shell getprop ro.lineage.version`. Record it.

Run: `hadb shell settings get system screen_off_timeout`. Record it, to restore in Step 19.

- [ ] **Step 2: Install and set up**

Install the Task 7 APK with `hadb install -r <apk>` (large files: the curl/`pm install -r` route from the VAD plan).
In Wing, set:
- input route VAD;
- Conversation mode on;
- notifications allowed;
- if barge-in is merged: "Listen while Hermes works" off for Steps 3–15 (they count rounds and measure the plain
  loop); Steps 16–17 switch it.

Run: `hadb logcat -c`.

- [ ] **Step 3: Hold starts with the conversation (P1, D3-a)**

Tap "Dictate message", then:

Run: `hadb shell dumpsys activity services com.tarkilhk.wing.voice/com.tarkilhk.wing.voicebackground.BackgroundVoiceService`
Expected: `isForeground=true` and `foregroundServiceType=0x00000080` (microphone).

Run: `hadb logcat -d -s WingBgVoice`
Expected: `hold on`.

Observe: the notification "Conversation mode — Microphone opens after each reply." with a Stop action.

- [ ] **Step 4: Screen off while reading (P2, P4, P8)**

Ask a short question. While the reply is read aloud:

Run: `hadb shell input keyevent KEYCODE_SLEEP`
Expected:
- reading continues to the end;
- the start cue sounds;
- Birk's next question is sent;
- its reply is read aloud, all with the screen off.

Run: `hadb logcat -d -s WingBgVoice`
Expected: `pause kept`.

Run: `hadb shell dumpsys power`
Expected: `mWakefulness=Asleep`, and a wake lock line containing `voice-conversation`.

During a round, run: `hadb shell input keyevent KEYCODE_WAKEUP`
Expected: the green microphone indicator is visible on the lock screen.

Run: `hadb shell input keyevent KEYCODE_SLEEP` again.

- [ ] **Step 5: Screen off while recording**

Start a new round with the screen on. Press the power button mid-sentence and finish the sentence.
Expected: the question arrives in the chat (check after unlocking), and the reply is spoken with the screen off.

- [ ] **Step 6: Screen off while awaiting a reply, in Doze (P5)**

Ask a question that takes Hermes > 30 s. Right after sending, run these one at a time:
1. `hadb shell input keyevent KEYCODE_SLEEP`
2. `hadb shell dumpsys battery unplug`
3. `hadb shell dumpsys deviceidle force-idle`

Expected after step 3: `Now forced in to deep idle mode`. Then the reply is spoken when Hermes finishes.

Afterwards run `hadb shell dumpsys deviceidle unforce`, then `hadb shell dumpsys battery reset`.
If the reply is **not** spoken: record "P5 failed". Run `hadb shell dumpsys deviceidle whitelist`, check that
`com.tarkilhk.wing.voice` is missing, add it through Wing's battery settings link, and repeat once. Record both
results.

- [ ] **Step 7: Silence ends it (privacy §8)**

After a reply, say nothing.
Expected: within 8 s plus the cue, the notification disappears.

Run: `hadb logcat -d -s WingBgVoice`
Expected: `stop reason=released` and `wakelock released heldMs=<n>`.

Run: `hadb shell dumpsys activity services com.tarkilhk.wing.voice/com.tarkilhk.wing.voicebackground.BackgroundVoiceService`
Expected: no `ServiceRecord` for it.

- [ ] **Step 8: Notification Stop**

Start a conversation, then switch the screen off. Wake the phone and tap Stop in the notification on the lock screen.
Expected: logcat `stop reason=notification`. On unlock, Wing shows no recording, and later replies do not reopen the
microphone.

- [ ] **Step 9: Swipe the notification (P6)**

Start a conversation and try to swipe the notification away.
Expected: either it cannot be swiped (record "not dismissible"), or logcat `stop reason=dismissed` and the
conversation ends.

- [ ] **Step 10: Phone call (P7)**

Start a conversation with the screen off, during a round. Birk calls the phone from another phone.
Expected:
- SDK ≥ 31: logcat `stop reason=call`, and after the call the conversation does not resume.
- SDK < 31: the round ends with no speech (logcat `stop reason=released`).

- [ ] **Step 11: Audio focus**

While a reply is read aloud, Birk starts music in another app.
Expected: Wing's reading stops, and logcat shows `stop reason=released`.

- [ ] **Step 12: Bluetooth headset (if available)**

1. Connect the headset and start a conversation.
2. Switch the headset off during reading. Expected: reading stops, the conversation ends (`stop reason=released`).
3. Repeat, switching it off during a round. Expected: the round continues on the phone mic, and the question is sent.

- [ ] **Step 13: Notifications denied → no hold**

Run: `hadb shell pm revoke com.tarkilhk.wing.voice android.permission.POST_NOTIFICATIONS`
Start a conversation.

Run: `hadb logcat -d -s WingBgVoice`
Expected: `hold refused reason=notifications`. Switching the screen off ends the conversation, as before.

Run: `hadb shell pm grant com.tarkilhk.wing.voice android.permission.POST_NOTIFICATIONS`

- [ ] **Step 14: Routes local and car mode never hold**

1. Switch to input route local, start a conversation, then run `hadb logcat -d -s WingBgVoice`. Expected: no new
   `hold on`.
2. If car mode is merged: enter car mode and start a round. Expected: no `hold on`, and the screen stays on.

- [ ] **Step 15: Battery, CPU and 10-minute run (P9)**

Run: `hadb shell dumpsys batterystats --reset`
Then hold a 10-minute pocket conversation (≥ 5 rounds, screen off).

During one "awaiting reply" phase:
- Run `hadb shell pidof com.tarkilhk.wing.voice`.
- Then run `hadb shell top -b -n 1 -p <pid>`. Expected: CPU < 5 %.

After the conversation:
- Run `hadb shell dumpsys batterystats com.tarkilhk.wing.voice`. Record the wake lock total for `voice-conversation`
  and the foreground-service time.
- Expected: the service is not stopped by the system during the 10 min (no `stop reason` before Birk ends it).

- [ ] **Step 16: Steer from the pocket while Hermes works (D2-b)**

Only if barge-in is merged; otherwise record "n/a (barge-in not merged)". In Wing, switch "Listen while Hermes
works" on. Run: `hadb logcat -c`.

Ask a question that takes Hermes > 30 s (for example the barge-in plan's synthetic `sleep 25` prompt). Right after
sending, run: `hadb shell input keyevent KEYCODE_SLEEP`.

Run: `hadb shell input keyevent KEYCODE_WAKEUP`
Expected: on the lock screen the notification reads "Conversation mode — Microphone is listening.", and the green
microphone indicator is on.

Run: `hadb shell input keyevent KEYCODE_SLEEP`. While Hermes still works, Birk speaks a short steer.
Expected after the turn: the reply is spoken with the screen off, and the next round opens. After unlocking, the
steer is in the chat as a steer of the running turn.

Run: `hadb logcat -d -v time -s WingBgVoice`
Expected: `listening on` after the send, then `listening off` when the turn ends, with no `stop reason` in between.
Record the seconds between the first `listening on` and the last `listening off`: that is how long the microphone
indicator stayed on for the listen round.

Wake the phone after the turn. Expected: the notification reads "Conversation mode — Microphone opens after each
reply." again.

- [ ] **Step 17: "Listen while Hermes works" off → no listen round with the screen off**

Only if barge-in is merged. In Wing, switch "Listen while Hermes works" off. Run: `hadb logcat -c`.
Ask the same long question and switch the screen off right after sending (`hadb shell input keyevent KEYCODE_SLEEP`).
During the turn, run `hadb shell input keyevent KEYCODE_WAKEUP`.
Expected: no green microphone indicator; the notification reads "Microphone opens after each reply.".

Run: `hadb shell input keyevent KEYCODE_SLEEP`. After the turn:

Run: `hadb logcat -d -s WingBgVoice`
Expected: no `listening on`; the reply is spoken and the next round opens as in Step 6.

Switch "Listen while Hermes works" back on (its default).

- [ ] **Step 18: Log privacy**

Run: `hadb logcat -d -s WingBgVoice`
Expected: only the line forms from Global Constraints. No words Birk spoke and no reply text.

- [ ] **Step 19: Restore**

Run: `hadb shell settings put system screen_off_timeout <value from Step 1>`.

- [ ] **Step 20: Results**

Append a section `## Results (device)` to this plan with one line per step (Steps 1–19): pass/fail, SDK and
LineageOS version, CPU %, wake lock minutes, foreground-service minutes, and the listen-round microphone seconds from
Step 16. No logs and no spoken text. Then commit:

```bash
git add docs/superpowers/plans/2026-10-14-wing-voice-background.md
git commit -m "docs(voice-bg): device acceptance results"
```

If Step 4 shows silence instead of transcription (P2 false), stop and end the report with
`FRAGE: Android verweigert das Mikrofon bei ausgeschaltetem Bildschirm — wie weiter?`

---

## Options not chosen (history, spec §12)

Birk decided D1–D3 on 14.10. The alternatives below are recorded only so the decision is traceable; they are not
part of this plan and nothing here is to be implemented.
- D1-b (own switch "Keep going with screen off", default off): not chosen.
- D3-b (start the service only at screen-off, from `onPause`): not chosen; it relied on background-start exemptions
  (spec §3 P2/P3).

# Wing Voice: conversation mode keeps running with the screen off

Card: t_4934d7d4 (board wing). Date: 2026-10-14. Status: design, no product code. Birk's decisions D1-a, D2-b,
D3-a (14.10.) are in §12.

## 1. Goal and scope

Conversation mode is the voice loop where Wing reads the reply aloud, reopens the microphone and sends the next
dictation. That loop must keep running when the screen is switched off or the phone is in a pocket. Today, with the
screen off, only the reply notification sound arrives.

**In scope:**
- The normal conversation mode on input route **vad**.
- Starting it while Wing is visible.
- Continuing it when the activity pauses: screen off, lock screen, or another app in front.
- A persistent notification with Stop.
- Barge-in listen rounds (t_7e81e040) while Hermes works, also with the screen off (D2-b), made visible in the
  notification.
- Interruptions: call, audio focus, headset.
- Battery and Doze behaviour.
- Privacy.

**Out of scope:**
- **Car mode (t_c8de9cba).** Operator note, binding: car mode always runs with the screen on and keeps its
  keep-screen-on holder. It gets no screen-off path, and background voice is never held while car mode is active.
- **Routes `local` and `hermes`.**
  - `hermes` never continues a conversation: `finishedOnItsOwn = !_stopRequested && _remote == null`
    (`lib/core/controllers/voice_input_controller.dart:236`).
  - `local` uses an Android `SpeechRecognizer` built on the Activity (`VoiceCapture.kt:37-38`). Its background
    behaviour is unknown, and it has no Wing-controlled no-speech limit.
  - Both keep today's behaviour: the conversation ends when the activity pauses.
- **Headset media keys in the background.** They stay foreground-only, as the VAD spec decided (decision 9,
  `docs/superpowers/specs/2026-10-13-wing-voice-vad-input-design.md:404`).
- **The reply notification sound.** It is unchanged, and suppressing it while the reply is spoken is a possible
  follow-up.
- **Hermes.** No backend change, plugin or new endpoint. The loop uses the same chat and `audio/speak` calls
  conversation mode already makes (`lib/core/services/hermes_voice.dart:56-60`, `:79-94`). No Hermes API is added
  or changed, so no Hermes commit needs inspecting.

## 2. Inspected state

**Commits:**
- Base: `origin/voice-offline` b4f5e4a0 (VAD merge t_145c5731) plus the local plan docs (2742a3cb).
- Upstream: `upstream/main` 1adbee5d (tarkilhk/Wing). Merge base with HEAD is 151ee281. HEAD has 70 commits that
  upstream lacks; upstream has 383 that HEAD lacks.

Line numbers prefixed "wt" refer to this worktree. Line numbers prefixed "up" refer to upstream/main 1adbee5d.

### 2.1 Why the loop stops today: two independent kills

| # | Evidence | Effect |
|---|---|---|
| K1 | `MainActivity.kt:312-316` `onPause()` → `voiceChannel?.pause()` | Runs on every activity pause (Flutter `inactive`), before Dart notices. |
| K2 | `VoiceChannel.kt:123` `fun pause() { capture.pause(); vad.pause(); playback.stop(); mediaKeys.pause() }` | The VAD round fails with "Recording stopped because Wing left the foreground." (`VadCapture.kt:221`). Playback stops, and the MediaSession is released. |
| K3 | `profile_workspace_screen.dart:612-619` `didChangeAppLifecycleState`: on paused/hidden/detached → `_cancelVoice()` (`:324-329`) | Clears `_conversation`, cancels input and stops output. Intentional per the VAD spec: "App to background: Existing `pause()` → round cancelled, media keys inactive" (VAD spec :350). |
| K4 | `_speakCompletedReply` `:239` returns if `!_hasWorkspaceFocus`. `_canContinueConversation` `:282` requires `_hasChatFocus`. `_hasWorkspaceFocus => _routeIsCurrent && _appIsActive` (`:552`), and `_appIsActive = state == resumed` (`:620`). | Even with K1–K3 removed, a reply that arrives in the background ends the conversation, and the microphone never reopens. |

Removing K3 alone (the card's finding) is not enough. K1, K2 and K4 must be bypassed too, but only while a background
hold is active.

### 2.2 What already works in the background

- **Reply detection in the background.** `completedReplies` is emitted in `_settleTurn` without any visibility check
  (`profile_workspace_controller.dart:6123-6125`). The controller doc says: "A foreground switch never closes a socket,
  changes a chat owner, or cancels a turn." (`:364-365`).
- **Visibility only affects notifications.** `setRouteVisibility` (`:456-467`) only decides whether a notification
  alerts (`_deliverNotification` `:6285-6299`).
- **The Flutter engine is retained.**
  - Manifest comment, verbatim: `<!-- The retained Flutter engine has exactly one visible activity owner. -->`
    (`AndroidManifest.xml:35`).
  - `MainActivity.kt:54` `provideFlutterEngine(...) = MonitoringRuntime.engine` and `:56`
    `shouldDestroyEngineWithHost(): Boolean = false`.
  - `MonitoringRuntime.kt:14`: "One engine owns both the visible app and background event subscriptions."
  - While the activity is only stopped (screen off), the activity, the engine, the widget tree and `VoiceChannel` all
    stay alive. Dart keeps running; only frames stop.
- **An existing foreground service, but not a microphone one.**
  - `BackgroundMonitoringService` is the only FGS: `foregroundServiceType="specialUse"` (`AndroidManifest.xml:21-29`),
    with subtype "User-visible continuous monitoring of self-hosted Hermes chat events…".
  - It holds a `PARTIAL_WAKE_LOCK` (`BackgroundMonitoringService.kt:80-84`).
  - It starts only while `activityVisible` (`MonitoringRuntime.kt:46`), only while a chat is busy and notifications
    are on (`lib/core/services/background_monitoring_service.dart:50-85`).
  - It does not record audio, and its declared purpose does not cover the microphone.
- **Manifest permissions.** It has `RECORD_AUDIO`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`, `WAKE_LOCK`
  and `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (`:2-9`). It has **no** `FOREGROUND_SERVICE_MICROPHONE`.
- **SDK levels.** `targetSdk = 36`, `minSdk = 24` (`android/app/build.gradle.kts:142-143`).
- **The VAD route has no hard Activity dependency.** It uses `AudioRecord` plus sherpa on its own thread
  (`VadCapture.kt:68`, `:84-97`) and plays cues with `ToneGenerator`. Playback uses `TextToSpeech(activity.applicationContext)`
  (`VoicePlayback.kt:74`) or `MediaPlayer` (`:131-138`).

### 2.3 Upstream (tarkilhk/Wing, 1adbee5d)

`git grep -i -E "foreground|microphone|FOREGROUND_SERVICE|wakelock|AudioFocus" upstream/main -- android lib` finds only
the monitoring service and `VoicePlayback` audio focus. Upstream has:
- no microphone FGS;
- no background voice;
- no conversation mode;
- no VAD route;
- no `keepScreenOn` or media keys.

Upstream is **stricter** about leaving the foreground:
- up `MainActivity.kt:347-348` `onPause` → `voiceChannel?.pause()`;
- up `:359-361` `onStop` → `voiceChannel?.leaveForeground()`;
- up `VoiceChannel.kt:115-125` `leaveForeground()` cancels a pending permission request, then calls `pause()`;
- up `profile_workspace_screen.dart:912-919` keeps the same `_cancelVoice()` on paused/hidden/detached;
- up `lib/core/services/android_voice.dart:24`: "All operations are foreground-only."

The feature is therefore fork-only and must live in its own files. After the upstream merge (t_f8523002), every native
pause path (`pause()`, and `leaveForeground()` → `pause()`) still goes through `VoiceChannel.pause()`. That is the
single native hook point.

## 3. Platform constraints (Android)

The Android developer pages could not be fetched from this server: WebFetch failed and `curl developer.android.com`
timed out. Every platform statement below is therefore marked **ANNAHME**, with the page to check and the device step
that proves it. Plan Task 0 asks the implementer to fetch these pages and quote them into this section before writing
Kotlin.

| ID | ANNAHME | Verify in | Device proof (plan Task 8) |
|---|---|---|---|
| P1 | From targetSdk 34, a service that records audio must declare `foregroundServiceType="microphone"`, hold `android.permission.FOREGROUND_SERVICE_MICROPHONE`, and call `startForeground(id, n, FOREGROUND_SERVICE_TYPE_MICROPHONE)`. `RECORD_AUDIO` must already be granted, otherwise `startForeground` throws `SecurityException`. | developer.android.com/develop/background-work/services/fgs/service-types (Microphone); /about/versions/14/changes/fgs-types-required | Task 8 Step 3: `dumpsys activity services` shows `foregroundServiceType=0x00000080` (microphone). |
| P2 | Microphone is a while-in-use permission. A microphone FGS started **while the app is visible** may keep recording after the screen goes off. One started from the background gets no microphone access (silence), or the start is refused. | /develop/background-work/services/fgs/restrictions ("while-in-use permissions"); /restrictions-bg-start | Task 8 Step 4: a round recorded with the screen off is transcribed (draft text arrives in the chat). |
| P3 | From Android 12, starting any FGS from the background throws `ForegroundServiceStartNotAllowedException`, except under listed exemptions. | /develop/background-work/services/fgs/restrictions-bg-start | Covered by design: the hold is only requested while visible (§5.2). |
| P4 | Playing audio (TextToSpeech, MediaPlayer) from a process that already runs a foreground service needs no extra `mediaPlayback` type. | /develop/background-work/services/fgs/service-types (Media playback) | Task 8 Step 4: the reply is heard with the screen off. |
| P5 | In Doze, wake locks are ignored and network is deferred for ordinary apps. A process with a foreground service is exempt from these Doze restrictions. | /training/monitoring-device-state/doze-standby | Task 8 Step 6: `dumpsys deviceidle force-idle` during "awaiting reply"; the reply is still spoken. |
| P6 | From Android 14, users can swipe away an FGS notification. The service keeps running. | /develop/background-work/services/fgs/... (notification) / Android 14 behaviour changes | Task 8 Step 9: swiping it away triggers the delete intent → conversation ends (§5.4). |
| P7 | During a phone call, other apps' capture is silenced (concurrent capture policy, Android 10+). The audio mode becomes `MODE_IN_CALL` or `MODE_IN_COMMUNICATION`. `AudioManager.addOnModeChangedListener` exists from API 31. | /guide/topics/media/platform/sharing-audio-input; AudioManager reference | Task 8 Step 10: a call during a round ends the conversation; logcat shows `stop reason=call`. |
| P8 | Android 12+ shows the green microphone privacy indicator while an app records, including with the screen off once it is woken. | Android 12 privacy indicators | Task 8 Step 4: the indicator is visible on the lock screen during a round. |
| P9 | Android 15 FGS timeouts apply to `dataSync` and `mediaProcessing`, not `microphone`. | /about/versions/15/behavior-changes-15 | Task 8 Step 15: a 10 min background conversation is not stopped by the system. |

If P2 turns out false on the phone (recording is silent with the screen off), the feature cannot work client-only, and
the device acceptance stops with `FRAGE:`. There is no server-side workaround (AGENTS.md).

## 4. Approaches

**A. Move the loop into a Kotlin foreground service.** Rejected.
- Kotlin would have to re-implement the Hermes chat client: socket, send, steer, the turn state machine, completion,
  and TTS fetch through `HermesVoice`.
- That logic lives in `profile_workspace_controller.dart` (6000+ lines).
- It would duplicate the conversation guards (`_canContinueConversation`, `_sendConversationTurn`) that the car-mode
  and barge-in specs hook into.
- It would grow without bound and contradicts the upstream strategy.

**B. Keep the loop in Dart in the retained engine, and add a microphone-type FGS that only holds the process, CPU and
microphone access.** Recommended.
- The loop code stays where it is.
- New code covers: a native "hold" (service, notification, wake lock, call detection), a Dart wrapper with policy, and
  thin hooks that bypass K1–K4 only while held.
- §2.2 shows the parts this relies on already exist: background reply detection and the retained engine.

**C. "Pocket mode": keep the screen on but black, with a proximity sensor.** Rejected.
- It does not cover the power button, which is exactly what Birk does.
- It burns the display.
- It is a UI feature that is not asked for.

**Upstream:** upstream has no answer to borrow (§2.3). B keeps everything fork-specific in new files.

## 5. Design (approach B)

### 5.1 Components

| Unit | File | Purpose | Interface |
|---|---|---|---|
| `BackgroundVoiceService` | new `android/app/src/main/kotlin/com/tarkilhk/wing/voicebackground/BackgroundVoiceService.kt` | Microphone FGS: notification with Stop, partial wake lock, audio-mode watch. Stops itself on Stop, swipe or call. Switches the notification text while a listen round is open. | Intents `ACTION_HOLD`, `ACTION_STOP`. Companion `running: Boolean`, `onStopped: ((String) -> Unit)?`, `listening(on: Boolean)`. |
| `BackgroundVoiceChannel` | new `…/voicebackground/BackgroundVoiceChannel.kt` | MethodChannel `com.tarkilhk.wing/background_voice`. `hold(on)` checks the preconditions and starts or stops the service; it forwards stop reasons to Dart; `listening(on)` updates the notification text. | Dart → native `hold {on: bool}` → `{held: bool, reason: String}`; `listening {on: bool}` → `null`. Native → Dart `stopped {reason}`. |
| `BackgroundVoice` | new `lib/voice_offline/background_voice.dart` | Dart policy and state: whether to hold, whether a lifecycle pause keeps voice, stop events. | `BackgroundVoiceHost` (interface), `AndroidBackgroundVoiceHost`, `BackgroundVoice` (§5.3). |
| Test fake | new `test/support/background_voice_fixture.dart` | Records `hold` calls and emits `stopped`. | Implements `BackgroundVoiceHost`. |
| Hooks | `VoiceChannel.kt`, `profile_workspace_screen.dart`, `AndroidManifest.xml` | Bypass K1–K4 while held. | §5.5. |

### 5.2 Lifecycle of a hold

**Want.** Dart computes `want` every time `_conversation` changes:

```
want = _conversation != null && route == vad && !carModeActive
```

There is no own setting (D1-a).

**Hold (when `want` becomes true).** Dart calls `hold(true)`. Native refuses with a reason in each of these cases:

| Precondition | Reason when it fails |
|---|---|
| `MonitoringRuntime.activityVisible` | `notVisible` (P3) |
| `RECORD_AUDIO` granted | `permission` |
| `NotificationManagerCompat.areNotificationsEnabled()` and the channel is not blocked | `notifications` (privacy §8: no hidden microphone) |
| `startForeground` succeeds | `startFailed` |

On success it returns `{held: true}`. A refused hold logs `WingBgVoice hold refused reason=<r>` and leaves today's
behaviour in place: the conversation still runs while visible and ends on pause. No new UI is added.

**Release (when `want` becomes false).** Dart calls `hold(false)`, and the service stops.

**Native-initiated stops.** All of the following call `onStopped(reason)` → `stopped` → Dart `_cancelVoice()`:
- Stop button (`notification`);
- swipe (`dismissed`);
- call (`call`);
- `VoiceChannel.close()` (`activityClosed`).

**Why the service starts with the conversation and not at screen-off:** Decision D3-a. The service is already in the
foreground state when the screen turns off, so no background start is needed (P2, P3).

**Listen rounds.** While held, Dart forwards whether a barge-in listen round is open (`listening(on)`); the service
only changes the notification text (§5.4). Outside a hold nothing is forwarded.

### 5.3 Dart interface

```dart
abstract interface class BackgroundVoiceHost {
  /// Starts or stops the microphone hold. Resolves to whether it is held.
  Future<bool> hold(bool on);
  /// Reasons the native side ended the hold on its own
  /// (notification, dismissed, call, activityClosed).
  Stream<String> get stopped;
  /// Shows whether a barge-in listen round has the microphone open.
  Future<void> listening(bool on);
}

class BackgroundVoice {
  BackgroundVoice(this._host, {required VoidCallback onStopped});
  bool get held;                       // last confirmed native state
  bool get screenOff;                  // held && app not resumed
  void sync({required bool want});     // idempotent, serialised
  void listening(bool on);             // deduplicated; forwarded only while held
  bool keepsVoice(AppLifecycleState s);// held && s != detached
  void lifecycle(AppLifecycleState s); // tracks screenOff
  void dispose();                      // hold(false), cancel subscription
}
```

`sync` serialises calls: a `false` that arrives while a `true` is in flight is applied after it. `detached` always
cancels, because the engine is losing its view.

### 5.4 Notification

| Property | Value |
|---|---|
| Channel | `voice_conversation`, name "Voice conversation", `IMPORTANCE_LOW`, no badge |
| ID | 214611 (monitoring uses 214601/214602) |
| Small icon | the existing `R.drawable.ic_stat_monitoring` (no new asset, per DESIGN_SYSTEM.md:119-125 notification identity) |
| Title | "Conversation mode" |
| Text | "Microphone opens after each reply." |
| Text while a barge-in listen round is open | "Microphone is listening." (back to the text above when the round closes) |
| Action | "Stop" → `ACTION_STOP` |
| Tap | opens Wing (same `PendingIntent` pattern as `BackgroundMonitoringService.kt:50-58`) |
| Swipe | `setDeleteIntent` → `ACTION_STOP` with reason `dismissed` (P6) |
| Flags | `setOngoing(true)`, `setOnlyAlertOnce(true)`, `CATEGORY_SERVICE` |

No spoken text, transcript or reply ever appears in the notification.

### 5.5 Hook points in upstream files (line caps are acceptance criteria)

| File | Change | Cap |
|---|---|---|
| `android/.../VoiceChannel.kt` | (1) field `private val background = BackgroundVoiceChannel(activity, messenger)`. (2) First line of `pause()`: `if (BackgroundVoiceService.running) { capture.pause(); mediaKeys.pause(); return }` keeps the vad round and playback alive; the `local`/`hermes` capture is still stopped, and media keys stay foreground-only. (3) `close()`: `background.close()`, which releases the hold with reason `activityClosed`. | ≤ 7 added/changed lines including the 2 imports |
| `lib/core/screens/profile_workspace_screen.dart` | import; constructor parameter `backgroundVoice` (like `voiceDevice`); field `_background`; `_conversation` setter → `_background.sync(want: …)`; lifecycle → `if (... && !_background.keepsVoice(state)) _cancelVoice();` plus `_background.lifecycle(state)`; `_loopFocus` getter used at `:239` and `:282` instead of `_hasWorkspaceFocus`/`_hasChatFocus`; `dispose` → `_background.dispose()`; with barge-in merged, one `initState` line `_bargeIn.addListener(() => _background.listening(_bargeIn.listening));` (plan Task 5). | ≤ 20 added/changed lines (planned: 18) |
| `android/app/src/main/AndroidManifest.xml` | `FOREGROUND_SERVICE_MICROPHONE` permission; `<service android:name=".voicebackground.BackgroundVoiceService" android:exported="false" android:foregroundServiceType="microphone" />` | ≤ 8 lines |
| `MainActivity.kt`, `VoiceCapture.kt`, `voice_input_controller.dart`, `android_voice.dart`, `VadCapture.kt`, `VoicePlayback.kt` | none | 0 lines |

The `_loopFocus` getter:

```dart
bool get _loopFocus =>
    _routeIsCurrent && _destination == AppDestination.chats &&
    (_appIsActive || _background.held);
```

It replaces the focus test in `_speakCompletedReply` (`:239`) and in `_canContinueConversation` (`:282`).
`setRouteVisibility`, media keys and `_voiceDeviceEvent` keep `_hasChatFocus`, so their behaviour is unchanged.

### 5.6 Data flow, screen off in each phase

| Phase when the screen goes off | K1/K2 (native) | K3 (Dart lifecycle) | Continues because |
|---|---|---|---|
| VAD round recording | `pause()` hook keeps `vad` | `keepsVoice` → no cancel | `onResult` checks only `mounted`, owner, `current == chat` and `_destination` (`:413-419`) → `_sendConversationTurn` (no focus check, `:300-312`) |
| Awaiting reply | — | no cancel | `completedReplies` → `_speakCompletedReply` with `_loopFocus` |
| Reading aloud | hook keeps `playback` | no cancel | `speak` returns true → `_canContinueConversation` with `_loopFocus` → `_dictate(resume: true)` (`:392-400`, no focus check) |
| Barge-in listen round (t_7e81e040, if merged) | hook keeps `vad` | no cancel | D2-b: the listen round keeps running; `_openListen` checks no focus, so new listen rounds also open with the screen off when `voice.listen_turn` is on. A steer goes through barge-in's `controller.steer`. The notification reads "Microphone is listening." |

Coming back (`resumed`) changes nothing in the loop. The hold stays while the conversation runs.

## 6. Interruptions

| Event | Behaviour | Mechanism |
|---|---|---|
| Notification Stop or swipe | Conversation ends; the round is cancelled, playback stops, the service is gone. | `ACTION_STOP` → `stopped` → `_cancelVoice()` |
| Incoming or outgoing phone call, VoIP call | Conversation ends; no automatic resume. | Service: API ≥ 31 `OnModeChangedListener`, mode ∈ {`IN_CALL`, `IN_COMMUNICATION`, `RINGTONE`, `CALL_SCREENING`} → stop `call`. API < 31: playback loses focus → `speak` false → ends; a silenced round (P7) → `noSpeech` → ends. |
| Another app takes audio focus during reading | Conversation ends (existing). | `VoicePlayback.kt:37-39` `if (value < 0) stop()` → `speak` false → `_conversation = null` (`:264-268`) → `sync(false)` |
| Another app records during a round | The round hears silence → `noSpeech` → ends (existing). | P7, `voice_input_controller.dart:206` |
| Another app plays music during a round | Not detected. VAD may pick up vocals. Same as on screen today; documented risk. | VAD records "whatever input Android routes" (`VadCapture.kt:23`) |
| Bluetooth headset disconnects during reading | Playback stops → conversation ends (privacy: no surprise speaker output). | `ACTION_AUDIO_BECOMING_NOISY` receiver, `VoicePlayback.kt:40-46` |
| Bluetooth headset disconnects during a round | The round continues on the phone mic (Android re-routes). | `VadCapture.kt:23`, no routing change |
| Bluetooth headset connects | The next playback or round uses Android's new route. No action. | — |
| Activity destroyed by the system | Conversation ends; the service stops with `activityClosed`. | `VoiceChannel.close()` hook |
| Process killed | Everything ends; `START_NOT_STICKY`, no resurrection. | Same rule as `BackgroundMonitoringService.kt:90-91` |
| Approval, clarify or secure prompt arrives | Conversation ends (existing). | `_voiceWorkspaceChanged` `:188-199` |

## 7. Battery and Doze

**Wake lock.**
- A `PARTIAL_WAKE_LOCK` tagged `com.tarkilhk.wing.voice:voice-conversation` is held for exactly the service's lifetime.
  This follows the monitoring service pattern (`BackgroundMonitoringService.kt:80-84`, `:97`).
- The service lives only while the conversation runs.
- The conversation ends at most `noSpeech` seconds after a reply finishes if nobody speaks (§8). The only long
  holder is a long Hermes turn, during which the monitoring service already holds its own wake lock whenever
  notifications are on. With `voice.listen_turn` on (D2-b), a listen round also runs VAD for that whole turn; its CPU
  cost is the barge-in card's measurement, and plan Task 8 Step 16 records the open-microphone time with the screen
  off.

**Doze.**
- A walking person rarely triggers deep Doze.
- P5 is verified with `dumpsys deviceidle force-idle`.
- If P5 fails (the reply is not spoken in forced idle), the existing battery-settings link (`openBatterySettings`,
  `MonitoringRuntime.kt:34`ff) is the remedy. Wing adds no new `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` prompt.

**Measurements on hadb (plan Task 8):**
- wake lock time and FGS time from `dumpsys batterystats`;
- CPU from `top -b -n 1 -p <pid>` during "awaiting reply" (expected < 5 % of one core; Dart idle);
- battery drop over a 10 min pocket conversation, recorded, not gated.

## 8. Privacy

- **The microphone is only open during a round.** The service itself never records. `AudioRecord` runs only inside a
  VAD round started by the loop or inside a barge-in listen round.
- **A whole Hermes turn with the screen off (D2-b).** With "Listen while Hermes works" (`voice.listen_turn`, default
  on) the microphone can stay open for a whole Hermes turn while the phone is in a pocket. What it hears nearby can be
  transcribed and sent as a steer. Birk accepted this on 14.10.
- **The only control is `voice.listen_turn`.** It applies the same way with the screen on and off; there is no
  screen-off special rule and no extra setting. With it off, the microphone opens with the screen off only for the
  round after a reply, bounded by the no-speech limit below.
- **Interrupting read-aloud stays headphones-only** (barge-in D2), unchanged by this card.
- **Visibility.** While the screen is off, the microphone's state is visible only through the ongoing notification
  (§5.4) and Android's microphone indicator (P8). During a listen round the notification text reads "Microphone is
  listening."; after the round it returns to "Microphone opens after each reply.". If notifications are disabled,
  there is no hold (§5.2), so the microphone is never open unseen with the screen off.
- **Time limit without speech.** Background conversation ends when one round hears no speech for
  `voice.vad_no_speech_seconds`. The default is **8 s**: `VadEndpointConfig.noSpeechTimeout = Duration(seconds: 8)`
  (`lib/core/services/vad_endpoint.dart:24`), user choices 5/8/12/20 s (`lib/core/services/voice_preferences.dart:52`,
  default `:146`).
  - Timeout → `_fail('No speech detected. Try again.')` (`voice_input_controller.dart:206`) →
    `_voiceInputChanged` clears `_conversation` (`profile_workspace_screen.dart:230`) → `sync(false)` → the service
    stops.
  - No second timer is needed: the same value bounds open-microphone-without-speech in both foreground and
    background.
  - Barge-in listen rounds set `noSpeechTimeout = maxDuration` (barge-in spec :184) and restart silently while the
    turn runs, so this limit does not bound them; the end of the Hermes turn, Stop listening, notification Stop or
    `voice.listen_turn` off do.
- **Logs.** Tag `WingBgVoice`, Kotlin only. Lines carry only state, reason and durations: `hold on`, `hold refused
  reason=notifications`, `pause kept`, `stop reason=call`, `wakelock released heldMs=…`, `listening on`,
  `listening off`. Never text, transcript, reply, chat or profile name.
- **No data in the repo.** Device logs and battery dumps from acceptance stay on the workstation. Only the observed
  pass/fail and numbers go into the plan's results section.

## 9. Interaction with other cards; file overlaps; build order

| Card | Interaction | Resolution |
|---|---|---|
| Car mode t_c8de9cba | Car mode is always screen-on, holds `screenOn` for its whole duration (car spec :113-115), and relies on `_cancelVoice()` on pause (car spec :126-128). | `want` includes `!_car.active`. With car mode active nothing is held, so `keepsVoice` is false and car behaviour is unchanged. If car mode is not merged yet, the term is added by whichever card lands second (plan anchor A9). |
| Barge-in t_7e81e040 | Listen rounds while Hermes works (`_openListen`, barge-in plan :2059-2072), the `_conversation` setter hook (:2014-2026), the switch `voice.listen_turn` and headphones-only read-aloud interruption (barge-in D2). | D2-b: listen rounds are not gated; they run with the screen off exactly as with it on, controlled only by `voice.listen_turn`. This card adds one `initState` line that forwards `_bargeIn.listening` to the notification (plan Task 5). Read-aloud interruption is unchanged. Both setter hooks coexist (separate lines). If barge-in is not merged, it adds that line (plan anchor A10). |
| Auto-steering t_f0c1d125 | No doc exists in `docs/` (grep, 2026-10-14). The card's premise is that a second dictation during a running turn is sent as steer. | With D2-b, steers spoken with the screen off go through barge-in's `controller.steer` / `_sendConversationTurn` path, as on screen; no extra code. |
| TTS language t_d523010d | Changes `VoicePlayback.kt`, `VoiceChannel.kt:53-54` (`speak`), and adds `voiceoffline/LanguageSpeech.kt`. | Disjoint lines in `VoiceChannel.kt` (this card: field, `pause`, `close`). TTS in the background is P4 for both. |
| Upstream merge t_f8523002 | Rewrites `VoiceChannel.kt` (`leaveForeground`), `MainActivity.kt` (`onStop`), and the screen (`:912`). | The plan starts with anchor checks. The hook stays in `VoiceChannel.pause()`, which `leaveForeground()` calls. |

**File overlap:**

| File | VAD | Car | Barge-in | TTS lang | This card |
|---|---|---|---|---|---|
| `profile_workspace_screen.dart` | M | M | M | — | M (≤ 20) |
| `VoiceChannel.kt` | M | — | M | M | M (≤ 7) |
| `AndroidManifest.xml` | — | — | — | — | M (≤ 8) |
| `test/voice_workspace_test.dart` | M | M | M | — | M (new group) |
| `lib/voice_offline/` | — | — | C | C | C `background_voice.dart` |
| `test/voice_offline/` | — | — | C | C | C `background_voice_test.dart` |

**Build order:**
1. VAD (done, b4f5e4a0)
2. upstream merge t_f8523002
3. TTS language
4. car mode
5. barge-in
6. **this card**

Coming after car mode and barge-in, this card adds its terms to their hooks rather than the other way round. If it
must go earlier, the anchors A9 and A10 say which term the later card has to add.

## 10. Error handling

| Failure | Result |
|---|---|
| `hold(true)` throws (`PlatformException`) | Treated as not held. The conversation works on screen as today. |
| The service starts but `startForeground` throws (P1) | `startFailed`; the hold is reported false. |
| `stopped` arrives for a hold Dart no longer wants | Ignored (`held` already false). |
| Hold succeeded, but the screen went off before the native flag was set | The race window is between Dart `sync` and `onStartCommand`, typically < 100 ms. Today's behaviour applies (the conversation ends). Accepted. |

## 11. Testing

**Dart unit** (`test/voice_offline/background_voice_test.dart`):
- `sync` serialisation;
- a refused hold;
- a `stopped` stream entry calls `onStopped`;
- `keepsVoice` truth table (`paused`/`hidden`/`inactive` true when held, `detached` false);
- `screenOff`;
- `listening`: forwarded once per change while held, applied when a hold starts, reset by a native stop, a failing
  update keeps the hold.

**Widget** (`test/voice_workspace_test.dart`, group "screen off"), with `VoiceDeviceFixture` and
`BackgroundVoiceFixture`:
1. Route vad: starting a conversation calls `hold(true)`; ending it calls `hold(false)`.
2. Route local: no `hold` call; backgrounding still cancels (the existing test stays green).
3. Held, `paused` during reading → no `stopPlayback`; completing playback reopens the microphone (`startVad` called
   again).
4. Held, `paused` while awaiting reply → `completeReply` → `speak` is called.
5. Held, a `stopped('notification')` event → round cancelled, `hold` not re-requested, `keepScreenOnCalls` ends with
   `false`.
6. Held, no-speech failure → `hold(false)`.
7. Hold refused → `paused` cancels as today.
8. With barge-in merged: held, screen off, `voice.listen_turn` on → a listen round opens after the send, the
   notification fake records `listening(true)`, a spoken steer reaches `session.steer`, and the turn end records
   `listening(false)`.
9. With barge-in merged: `voice.listen_turn` off → no listen round with the screen off, no `listening` call.

**Kotlin:** compile check only (`dispatch-check.sh voice-apk.yml publish=false`). There are no Kotlin unit tests in
the repo (`git ls-files android/app/src/test` is empty).

**Device:** plan Task 8 on hadb, covering P1–P9 and §6.

## 12. Decisions (Birk, 14.10.)

Decided on the card on 14.10.; this spec and the plan implement them.

**D1-a — no own switch.** Birk: "(a) kein eigener Schalter. Gespraechsmodus auf Route vad laeuft mit Bildschirm aus
automatisch weiter, sichtbar ueber Benachrichtigung mit Stopp-Knopf." Conversation mode on route vad always
continues with the screen off; the notification with Stop (§5.4) and the microphone indicator show it.

**D2-b — listen while Hermes works also with the screen off.** Birk: "(b). Mithoeren/Steering waehrend Hermes
arbeitet funktioniert AUCH mit Bildschirm aus (Tasche). Es gilt derselbe Schalter 'Mithoeren' aus der
Barge-in-Karte (Standard an, in den Voice-Einstellungen abschaltbar); kein Sonderverbot fuer Bildschirm aus.
Reinreden ins Vorlesen weiterhin nur mit Kopfhoerern (Barge-in D2). Das Mikro kann damit eine ganze Hermes-Runde
offen sein; die Benachrichtigung muss das sichtbar machen (z. B. 'hoert mit')."
- Listen rounds are not gated by this card; `voice.listen_turn` is the only control (§8).
- The notification text shows an open listen round (§5.4, plan Task 5).
- Device proof: plan Task 8 Steps 16 and 17.

**D3-a — the notification starts with conversation mode.** Birk: "(a) Benachrichtigung/Vordergrunddienst startet
schon beim Start des Gespraechsmodus." Android only allows a microphone foreground service started while Wing is
visible (P2, P3), so the hold starts when a conversation starts on route vad, even with the screen on (§5.2).

Not chosen (history only): D1-b, an own switch "Keep going with screen off"; D3-b, starting the service only at
screen-off from `onPause`.

## 13. Acceptance summary

- Screen off (power button) in each phase of §5.6: the loop continues, the reply is heard, the next round is
  transcribed and sent.
- The notification with Stop is present for exactly the conversation's lifetime. Stop, swipe and calls end it.
- With barge-in merged and `voice.listen_turn` on: a steer spoken with the screen off during a Hermes turn reaches the
  chat, and the notification reads "Microphone is listening." exactly while the listen round is open. With it off,
  no listen round opens with the screen off.
- After the last reply with no speech, the conversation and service end within `noSpeech` seconds plus the cue.
- Car mode, route local and route hermes behave exactly as before. The existing lifecycle tests stay green.
- Hook-line caps from §5.5 hold (`git diff --stat` per file).
- No transcript or reply text in `logcat -s WingBgVoice`.

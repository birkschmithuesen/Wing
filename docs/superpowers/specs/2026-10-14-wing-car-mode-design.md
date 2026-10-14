# Wing Voice: car mode, one big talk button — design

Card: t_c8de9cba (board wing). Date: 2026-10-14, revised 2026-10-14 after Birk's review of the clickable draft.
Status: design decided (section "Decisions (Birk 14.10.)"). Clickable draft:
`2026-10-14-wing-car-mode-mockup.html`, screenshots in `2026-10-14-wing-car-mode-shots/`. Remaining assumptions
are marked `ANNAHME:` together with how to verify them.

## 1. The wish

Birk wants a car mode in Wing. The whole screen is one very large button for "talk" or "send". It can be hit
blind and has no small controls. Most of his cars have no media keys on the steering wheel, and he does not
want to pair the phone with the car. The media key from the VAD chain still works, but it is not his main path.

User task: hold a voice conversation with Hermes while driving, with the phone in a mount.
Primary action: **one tap anywhere on the screen** does the next sensible thing.
Editable controls: none inside car mode.
Passive context, drawn on the button: the connection state (large, coloured), what Hermes is working on (status
line), the chat title (small).
Temporary status: errors, "Waiting for connection", "needs you on screen", and the one-time hint that a sideways
swipe leaves.

## 2. What exists today (checked in code)

Line numbers: **vo** = `origin/voice-offline` @ `b4f5e4a0` (the VAD chain is merged; read via `git show`).
**up** = `upstream/main` @ `d0a0c262`. Neither `8105ab72` nor `d0a0c262` is an ancestor of vo
(`git merge-base --is-ancestor`, exit 1). The upstream merge is still pending.

### 2.1 Voice runtime (fork)

| Fact | Where |
|---|---|
| `enum VoiceInputPhase { idle, starting, recording, transcribing }` | vo `lib/core/controllers/voice_input_controller.dart:10` |
| `stopHandsFree()`: on the VAD route `forceEnd(VadEndReason.mediaKey)`, which counts as "finished on its own". Otherwise it falls back to `stop()`, which sets `_stopRequested = true` and so is **not** sent | vo `voice_input_controller.dart:183-188`, `stop()` `:150-181`, `_finishVad` `:190-227` (`_stopRequested` rule `:209-211`), `_finish` `:229-241` (`finishedOnItsOwn = !_stopRequested && _remote == null` `:236`) |
| VAD end of speech is decided in Dart: `VadEndpointer.feed` ends with `pause` after `config.pause` of silence, `noSpeech` after `noSpeechTimeout`, `maxDuration` at the limit. There is no switch to turn the pause end off; the config takes any `Duration` | vo `lib/core/services/vad_endpoint.dart:18-52` (config), `:108-150` (`feed`) |
| `VoiceInputController.start(settings, …)` builds the endpointer from `settings.vad` | vo `voice_input_controller.dart:82-92` |
| `VoicePreferences` is a const class with named fields and no `copyWith`; defaults: `pause` 1800 ms, `noSpeechTimeout` 8 s, `maxDuration` 600 s | vo `lib/core/services/voice_preferences.dart:93-105`, `read` `:107-155` |
| `local` route: Android's recognizer ends on silence by itself (final `text` event), so `finishedOnItsOwn = true`. `hermes` route: no own end; `_remote != null` makes `finishedOnItsOwn` always false | vo `voice_input_controller.dart:121-148` (`text` event `:140`), `:236` |
| `VoiceOutputController.speak(...)` returns `true` only if playback ran to the end; `stop()`; `Object? owner` | vo `lib/core/controllers/voice_output_controller.dart:74`, `:124`, `:54` |
| Auto read-aloud: `controller.completedReplies` → `_speakCompletedReply`. It speaks only if `settings.autoSpeak \|\| settings.conversation` and the workspace has focus | vo `lib/core/screens/profile_workspace_screen.dart:575` (subscription), `:238-274`, gates `:239`, `:245` |
| With conversation off, nothing reopens the microphone after read-aloud: `_canContinueConversation` needs `_conversation == chat.key` and the saved `conversation` flag | vo `:278-296`, `:281`, `:293` |
| `_dictate` sets `_conversation = settings.conversation ? chat.key : null` and sends only if `_conversation == chat.key && finishedOnItsOwn` | vo `:392-436`, `:401-402`, `:411` |
| `_sendConversationTurn` ends the loop when the chat is busy or the send action is unavailable | vo `:300-322`, busy `:306`, send action `:309` |
| `_dictate` first calls `await _voiceOutput.stop()`, so a new round always stops read-aloud | vo `:393` |
| Media-key dispatcher (VAD route): recording → `stopHandsFree()`; idle → `_dictate(chat)` | vo `:356-369` |
| Screen on: shared holder `VoiceSwitchHolders.screenOn(device).set(owner, on)` | vo `lib/core/services/android_voice.dart:218-259` (`screenOn` `:227-228`, `set` `:248-258`); `_conversation` setter vo `:217-222` |
| `_hasWorkspaceFocus => _routeIsCurrent && _appIsActive`; `_routeIsCurrent` comes from `ModalRoute.isCurrentOf(context)` | vo `:552-555`, `didChangeDependencies` `:557-564`, assignment `:561` |
| App paused, hidden or detached → `_cancelVoice()` | vo `:611-619` |
| "Chat actions" overflow menu (`PopupMenuButton<String>`, values `parent/outputs/subagents/goal/background/find/refresh`) | vo `:979-1048` (`onSelected` `:982-1022`, `itemBuilder` `:1023-1047`) |
| `_composerActions(chat)`: every action blocked while dictating, and with "Reconnecting · Your draft is kept" while `controller.recovering \|\| chat.opening \|\| chat.offlineSnapshot` | vo `:2218-2274` |
| `_performComposerAction(chat, action, {conversation})`; steer rejected → snackbar | vo `:2287-2335`, snackbar `:2327-2333` |
| `controller.steer(chat, text)` → `true` on `queued`, `false` on `rejected` | vo `lib/core/services/profile_workspace_controller.dart:4927-4970` |
| `ServerConnectionPhase { unchecked, connected, reconnecting, limited, disconnected }`; `phase` getter; `controller.connectionStatus` | vo `lib/core/services/server_connection_status.dart:7-13`, `:43`; `profile_workspace_controller.dart:474` |
| Navigation: plain `Navigator.push(MaterialPageRoute(...))` | vo `lib/core/screens/administration/voice_settings_navigation.dart:24` |
| Localization: none. All UI strings are hard-coded **English** | vo: no `*.arb`, no `flutter_localizations` |
| Orientation: no lock; MainActivity handles `orientation\|screenSize` itself | vo `android/app/src/main/AndroidManifest.xml:41` |
| VAD cue tones: `ToneGenerator` beep at start, ack at end, inside a VAD round. `cue(...)` is `private`; no channel method plays a tone on demand | vo `android/app/src/main/kotlin/com/tarkilhk/wing/VadCapture.kt:55`, `:73-80`, `:155`; channel methods `VoiceChannel.kt:31-87` |
| Haptics: only `HapticFeedback.selectionClick()` so far; no `SystemSound`, no vibration plugin | vo `lib/core/widgets/composer_action_button.dart:131`, `:257`, `workspace_action_menu.dart:30` |

### 2.2 What Hermes is working on (status line source)

| Fact | Where |
|---|---|
| `enum ProfileMainActivity { working, thinking, writing, tool }`; `ProfileChat.mainActivity`, `mainToolActivity` (`GatewayToolActivity?`), `tool` (`String?`), `commandRunning`, `status` | vo `profile_workspace_controller.dart:97`, `:100`, `:101`, `:125`, `:154`, `:221` |
| Filled from gateway events: `message.start`/`interim` → working, `message.delta` → writing, `reasoning.delta` → thinking, `tool.generating/start/progress` → tool + `mainToolActivity`, `tool.complete` re-picks the last running tool | vo `profile_workspace_controller.dart:5827-5910` (`tool.complete` `:5871`, `reasoning.delta` `:5899`) |
| `GatewayToolActivity.name` is the tool name only (≤ 120 chars, from `name`/`tool`/`label`); `displayName` turns `web_search` into `Web search`. `detail`, `arguments`, `result` carry previews, arguments and output | vo `lib/core/models/gateway_activity.dart:11`, `displayName` `:42-46`, `fromGatewayEvent` `:67-123` |
| The chat renders it in `ProfileActivityStatus.label`: `Writing response…`, `Thinking…`, `Using <displayName> · <detail>`, `Hermes is working…`, `Running command…` | vo `lib/core/widgets/profile_activity_status.dart:17-60`, placed at `profile_workspace_screen.dart:1739` |
| Upstream: `ChatMainActivity { working, thinking, writing, tool }`, `ChatRuntimeObservation.mainActivity`, `mainToolActivity`, `get tool` | up `lib/core/models/chat_runtime.dart:11`, `:141`, `:145`, `:162`; `ProfileChat.runtime` up `profile_workspace_controller.dart:117` |

Car mode shows only the **kind** (`Working`, `Thinking`, `Writing`, `Command`) or the tool's `displayName`
(`Terminal`, `Web search`). It never shows `detail`, `arguments`, `result`, command text, transcript or answer text.

### 2.3 Connection loss today

| Fact | Where |
|---|---|
| The draft is persisted on the device for every edit: `updateDraft` → `_persistDraft` → `ComposerDraftStore` (SharedPreferences) | vo `profile_workspace_controller.dart:3563`, `:3697`, `:439`; `lib/core/services/composer_draft_store.dart:35` |
| The dictation callback writes the transcript into the draft **before** it tries to send | vo `profile_workspace_screen.dart:429-434` (`updateDraft` `:431`, send `:432`) |
| `send(chat)` returns `null` without sending while `chat.opening \|\| chat.offlineSnapshot \|\| recovering` | vo `profile_workspace_controller.dart:4306-4308` |
| A failed send before the server accepted it sets `status = failed` and keeps the draft. A send whose acknowledgement was lost sets `draftSubmissionUncertain = true` and is **never resent** | vo `profile_workspace_controller.dart:4754ff` (`_sendPrompt`), `:4895` |
| `queuePrompt` + `_drainQueuedPrompts` only drain behind a running turn. **Nothing resends a held draft when the connection returns** | vo `:4972`, `:5287` |
| Network back → `recoverConnections` → `resumeConnection(networkChanged: true)`; app resumed → `resumeConnection()` | vo `lib/main.dart:397-400`, `profile_workspace_registry.dart:86-95`; `profile_workspace_screen.dart:634` |
| `failRecovery` keeps `disconnected` until the owner retries (`connectionStatus.retry = resumeConnection`) | vo `server_connection_status.dart:94-102`; `profile_workspace_controller.dart:564` |
| Upstream: `send` turns every non-slash message into a persisted outbox entry (`_enqueuePrompt(…, fromSend: true)`), and the outbox drains after reconnect | up `profile_workspace_controller.dart:6367`, `:6391`, `:7193`, `:7278` |

**Consequence:** the held recording uses the existing local draft. Car mode only adds "send it once when the
connection is back" (§4.4). After the upstream merge, the upstream outbox can take over; only the adapter changes.

### 2.4 Upstream (`d0a0c262`)

- **No car, hands-free or conversation mode, and no keep-screen-on.** The fork's loop, `autoSpeak` and
  `conversation` must be re-planted by the upstream merge chain (t_d1d49ff1 → t_6a4e1890 → t_f8523002), which
  has not run yet. `services/voice_preferences.dart` is deleted upstream; the settings live in
  `AppPreferences.voiceInputSettings` (up `lib/core/services/app_preferences.dart:137`).
- Turn state upstream: `chat.runtime` (`ChatExecution` up `chat_runtime.dart:7`, `ChatRecovery` `:9`,
  `needsInput` `:163`, `executionActive` `:165`, `offline` `:169`, `reconnecting` `:170`).
- The "Chat actions" menu still exists upstream (up `profile_workspace_screen.dart:1507-1550`, values `screen`,
  `outputs`, `find`, `parent`, `refresh`, `StudioPopupMenuItem`). `didChangeDependencies` with
  `ModalRoute.isCurrentOf` is at up `:838-843` (`_routeIsCurrent = isCurrent` `:841`); `_hasChatFocus` at up
  `:829-836` also checks `_pendingChatTitle == null` and `!_conversationObscured`.

**Consequence:** car mode does not depend on fork-only or upstream-only types in its own logic. It reads one
neutral snapshot (§5.1), filled by one adapter function, `carSnapshotOf`. After the merge only its body changes.

### 2.5 Barge-in (t_7e81e040), designed in parallel

Its spec (`f1e244da`) steers a hands-free utterance into a **running** chat (`decideDelivery` in the planned
`lib/voice_offline/barge_in_policy.dart`). `git grep -n decideDelivery origin/voice-offline -- lib` finds
nothing, so it has not landed. Car mode does not depend on it. The tap *is* a manual barge-in and uses what exists:
`_dictate` stops playback first. The shared piece is the "deliver a hands-free utterance to a busy chat" hook in
`_sendConversationTurn` (§6.4).

## 3. Approaches considered

| | A: own route on top of the workspace (**chosen**) | B: overlay layer inside the workspace | C: extract the conversation loop into its own controller |
|---|---|---|---|
| Idea | `CarModeScreen` is pushed with `Navigator.push`. The workspace stays mounted below and keeps running the loop | A `Stack` layer over the chat in `_buildWorkspace` | The loop moves out of the screen; car mode and chat both drive it |
| Hooks in `profile_workspace_screen.dart` | ~46 lines + ~23 for steering (§8) | ~50, plus a guard in every chat `PopScope`: Back would also run the chat's `_leaveChat()` (vo `:838`) | Hundreds of lines in the file upstream rewrote |
| Back, orientation, system bars | Own `PopScope` on its own route | Shared with the chat route | — |
| Risk | The workspace below thinks it lost focus (`_routeIsCurrent` false). Fixed with one line (§6.1) | Back-gesture side effects | Merge conflicts, scope creep |

**A** has the fewest and clearest hooks. C contradicts strategy rule 1 ("own code in own files, only thin hook
points in upstream files", `hermes-entities/tools/technik/wing-fork-upstream-strategie.md`).

## 4. Behaviour

### 4.1 Entering and leaving

- **Enter:** "Car mode" in the open chat's "Chat actions" menu (⋮). Car mode always talks to **this chat**.
- On entry, car mode:
  - pushes its route (no orientation lock, see 4.7);
  - takes a screen-on holder (`VoiceSwitchHolders.screenOn(device).set(session, true)`) for the **whole** visit.
    **Screen-on is a fixed part of car mode, not an option.** An idle screen must not time out either: a timeout
    pauses the activity, and `_cancelVoice()` runs (vo `:611-619`). Background operation with the screen off is
    a separate card (t_4934d7d4) and not part of car mode;
  - does **not** start the microphone. The first tap does;
  - shows, once per visit and for 6 s, the small hint "↔ Swipe to leave" at the bottom edge of the button (§4.6).
    Birk suggested the top strip as an example. In the mockup at 411 dp, the hint is cut off there next to the
    connection badge, so it sits at the bottom edge instead, still drawn on the button. `ANNAHME:` 6 s; Task 9
    step 2 checks that it is readable and then gone.
- **Leave (D2):** Android Back (the edge swipe in gesture navigation, or the Back key) leaves **directly**, with no
  hint and no confirmation. A horizontal swipe across the screen also leaves (for 3-button navigation). There is
  no exit button. Leaving:
  - cancels a running recording without sending (the draft keeps what it had before the round);
  - stops read-aloud;
  - leaves a running Hermes turn alone;
  - keeps a held recording in the chat draft, not sent (§4.4);
  - releases the screen-on holder;
  - pops the route and lands in the same chat.
- **Automatic exit:** the workspace switches chat (notification tap, profile or connection switch) → car mode
  closes itself. The chat key in the snapshot no longer matches the entry chat.
- App in the background (e.g. the navigation app in front) → the existing `_cancelVoice()` ends a round. Car mode
  stays open and shows **idle** on return. `ANNAHME:` Android split-screen keeps Wing `resumed` (multi-resume,
  Android ≥ 10). Verify on the device with Maps in split-screen (Task 9 step 12).

### 4.2 Two cases, decided by the app's own "Conversation mode" setting

Car mode does **not** override the saved setting in either direction. It reads it at the start of every round
(`VoicePreferences.read`, as `_dictate` does today). The settings page is never changed (AGENTS.md).

- **Case 1, Conversation mode on:** the existing loop runs as today. A round ends at the end of speech and is
  sent; the reply is read aloud; the microphone reopens. The big button is the fallback: a tap while listening
  sends at once, for when the end of speech is not detected.
- **Case 2, Conversation mode off — the actual car mode (push-to-talk + automatic read-aloud):**
  - tap → recording starts; tap → recording stops **and is sent**;
  - no automatic end of speech: the round ends by tap only (details per route below);
  - every reply is read aloud automatically;
  - after read-aloud: idle, microphone closed, until the next tap.

**How case 2 avoids an automatic end (checked against the code):**

- `vad` route: `VadEndpointer` has no off switch, but its pause comes from `settings.vad.pause` (vo
  `voice_input_controller.dart:82`). For a car-mode round in case 2, `_dictate` passes a copy of the preferences
  whose `vad.pause` equals `vad.maxDuration` (`carTapOnlySettings`, §5.1). At 32 ms per window the pause would
  need 18 750 silent windows, and `maxDuration` fires at window 18 750 first (vo `vad_endpoint.dart:9`, pause `:129`, limit `:144`). The pause can then never fire before the
  limit. This is one changed line in `_dictate` plus a pure function in `lib/car_mode/`. `noSpeechTimeout` (default
  8 s) stays: a tap with no speech still ends with "No speech detected. Try again." and closes the microphone.
  At `maxDuration` (default 600 s) the round ends by the limit and is **not** sent (existing rule: `_stopRequested`
  for `maxDuration`); the text stays in the draft. `ANNAHME:` this edge is acceptable; it is documented in
  `docs/CAR_MODE.md` limits.
- `local` route: Android's recognizer ends on silence by itself, and there is no Dart option to stop that. Car
  mode **sends** that result, just like a tap (`finishedOnItsOwn` is true). `ANNAHME:` acceptable, because the
  text would otherwise sit unsent in the draft; `vad` is the recommended route in the car. Documented as a limit.
- `hermes` route: there is no own end, so every round ends by tap.

**Tap = send on every route.** On VAD, `stopHandsFree()` already sends. On `local` and `hermes`, a manual stop is
never sent today. In car mode a one-shot flag `_carSend` makes the next result count as hands-free (§6.2).

**Automatic read-aloud:** today `_speakCompletedReply` speaks only if `autoSpeak || conversation` (vo `:245`). In car
mode it also speaks when `_car.active` (one condition). With conversation off, `_canContinueConversation` still
reads the saved flag (vo `:293`), so after read-aloud the microphone stays closed. In case 2 the round still needs
`_conversation == chat.key` to be sent (vo `:411`, `:303`); `_dictate` sets it when `_car.active` (vo `:402`).
`_speakCompletedReply` clears it again when conversation is off (vo `:244`).

### 4.3 States and the tap

The button covers the whole screen except the system bars. A tap anywhere on it does the following:

| Phase | Shown (UI text, English like the app) | Tap does | Source |
|---|---|---|---|
| `idle` | **Tap to talk** | start a round (`talk`) | nothing active |
| `listening` | **Listening** / "Tap to send" | end the round now **and send** (`sendNow`) | `VoiceInputPhase.starting` or `.recording` (tap ignored during `starting`) |
| `transcribing` | **Got it** / "Transcribing…" | nothing | `VoiceInputPhase.transcribing` |
| `thinking` | **Hermes is working** / "Tap to add something" | start a round; the utterance **steers** the running turn (§6.4) | chat busy |
| `speaking` | **Reading aloud** / "Tap to interrupt" | stop read-aloud **and** start a round (`_dictate` stops output first, vo `:393`) | `VoiceOutputController.owner != null` |
| `waiting` | **Waiting for connection** / "Sends when back online" | start a round; what is said is **added** to the held text | a finished recording is held (§4.4) |
| `attention` | **Needs you on screen** / "Approval or question waiting. Look when parked." | nothing (a tap must never approve anything) | approval, clarification or secure prompt |
| `error` | **Didn't work** / short error text / "Tap to try again" | `talk` | voice error, or failed turn |

Priority, when several facts are true: attention > listening > transcribing > speaking > waiting > thinking >
error > idle.

**Tap while Hermes is working (former D1 option A).** `ANNAHME:` Birk did not address it; option A stays: the tap
opens the microphone, the utterance steers the running turn (fallback: queued). Not a gate. B and C remain as
deltas in the plan's "If Birk picks another option".

**Tap during read-aloud:** stops read-aloud and starts recording (unchanged, both cases).

**Waiting:** `ANNAHME:` a tap while a recording is held starts a new round. `_dictate` inserts the new transcript
into the draft that already holds the first one (`insertVoiceTranscript`), so both are sent together, once.

**Debounce:** a tap within 600 ms after the last accepted tap is ignored (double hits on a bumpy road).
`ANNAHME:` 600 ms. Check in Task 9 step 5 that a deliberate second tap ≥ 0.7 s later is accepted; adjust between
400 and 800 ms if not. The debounce never delays an accepted tap.

**Feedback without looking:**

- `HapticFeedback.heavyImpact()` on every accepted tap; `HapticFeedback.vibrate()` when a tap is ignored.
- The VAD cue tones (start beep, "got it") stay as they are.

### 4.4 Connection: shown, signalled, and a held recording is never lost

**Shown (mandatory):** a large coloured badge at the top-left of the button, recognisable from the corner of the eye:

| `CarConnection` | Badge | Colour token | Icon | From |
|---|---|---|---|---|
| `ok` | **Connected** | `success` | cloud-done | `connected` or `unchecked` |
| `reconnecting` | **Reconnecting** | `warning` | sync | `reconnecting`, `limited`, or `controller.recovering \|\| chat.opening \|\| chat.offlineSnapshot` |
| `offline` | **Offline** | `danger` | cloud-off | `disconnected` |

`ANNAHME:` `limited` counts as reconnecting. It means one of access or live updates is down (vo
`server_connection_status.dart:48-52`), so a reply might not arrive. Check in Task 9 step 9 that a normal drive
does not sit in `limited`.

The badge is drawn **on** the button; a tap on it is a tap on the button. Badge: 56 dp high, 22 sp w600 text, a
`surface`-coloured pill with a 3 dp token-coloured border and token-coloured text and icon. It therefore stands out on
every state fill, day and night (contrast in §4.6).

**Signalled on change:** Birk asked for "tone or vibration". The existing cue tones cannot be played on demand:
`VadCapture.cue` is private and only runs inside a VAD round (§2.1). `ANNAHME:` therefore vibration only,
with no Kotlin change:

- to `offline`: `HapticFeedback.vibrate()` three times, 250 ms apart;
- back to `ok` from `offline`: `HapticFeedback.heavyImpact()` twice, 250 ms apart;
- no signal for `reconnecting` blips.

Android may suppress these when the system's touch vibration is off. Verify in Task 9 step 9 with
`dumpsys vibrator_manager`. A real tone needs a new channel method (`cue`, about 15 lines of Kotlin and Dart, no
asset). It is listed as a delta in the plan for Birk to choose.

**Held recording ("Waiting for connection"):**

1. A car-mode round finishes while `connection != ok`. The transcript is already in the chat draft (vo `:431`),
   and the draft is already stored on the device (§2.3).
2. The `_sendConversationTurn` hook asks `_car.holdForConnection()`. It returns true and marks the round as held.
   Nothing is sent. The screen shows `waiting`.
3. While held and `offline`, the session calls `bridge.retry()` (`controller.resumeConnection`) every 20 s, because
   `failRecovery` stays `disconnected` until someone retries (§2.3). `ANNAHME:` 20 s. Network-change recovery
   (`main.dart:397-400`) also runs on its own.
4. When the snapshot shows `connection == ok`, the chat is not busy and no round is running, the session clears the
   held mark **first** and calls `bridge.sendHeld()` once. That closure sets `_conversation = chat.key` and runs
   `_sendConversationTurn(chat)`, the normal send path.
5. **Exactly once:** the mark is cleared before the send, and only a new hold sets it again. The fork never resends
   a send whose acknowledgement was lost (`draftSubmissionUncertain`, vo `:4895`). If the connection drops again
   before the send starts, step 2 holds again. The draft still has the text, so nothing is duplicated or lost.
6. Leaving car mode while held: the text stays in the chat draft and is not sent automatically.

Nothing of the held text is logged. Log lines say only `hold` / `release`.

### 4.5 What is never shown

- No transcript, no partial text, no reply text. The text stays in the chat.
- No tool arguments, commands or tool output; the status line shows only the kind or the tool name (§2.2).
- No timers. The VAD maximum duration protects the round.

### 4.6 Look (D3: colour field)

The whole screen below the system status bar is the button (8 dp inset, 28 dp corners). The state colour fills
it. Everything else is drawn **on** the button and counts as button:

```
┌──────────────────────────────┐   portrait 411 × 960
│ [● Connected]   Weekend trip │   top strip: connection badge, chat title
│                              │
│          Terminal            │   status line, upper third (only while Hermes works)
│                              │
│             🎤               │
│         Tap to talk          │   icon, label, hint
│                              │
│       ↔ Swipe to leave       │   only for the first 6 s of a visit
└──────────────────────────────┘
```

- **Contrast:** full contrast in both themes.
- **Day:** a saturated state fill with white text; idle is the `raised` panel with an `accent` border.
- **Night:** the state colour mixed 28 % into the dark canvas, with state-coloured text. **No pure white** at night.
- **Theme:** follows the app theme. `ANNAHME:` no separate car-mode night switch; it would be a small control.

| Phase | Colour token (`WingTokens`) | Icon |
|---|---|---|
| idle | `raised` panel with `accent` border and icon | mic |
| listening | `danger` ("REC" convention), pulsing ring (static with reduced motion) | stop square |
| transcribing | `danger` | three dots |
| thinking | `running` | hourglass |
| speaking | `accent` | speaker |
| waiting | `muted` | schedule-send |
| attention | `warning` | eye |
| error | `warning` | alert triangle |

Colour is never the only signal: every state and every connection value has its own icon and word. Day contrast
of white on the light fills (WCAG, from vo `lib/core/theme/wing_theme.dart:192-202`): `danger` 6.5:1, `running`
6.7:1, `warning` 5.0:1, `muted` 5.7:1, accent 6.09:1 (DESIGN_SYSTEM.md). Connection badge text on the light
`surface` F7F7F4: `success` 15803D 4.7:1, `warning` B45309 4.7:1, `danger` B91C1C 6.1:1. The palette test
(plan Task 2) checks all pairs, every accent and both themes. It requires ≥ 4.5:1 for hints and the badge and ≥ 3:1
for the 40+ sp label and the 34 sp status line.

**Status line:** upper third, 34 sp w600, one line, ellipsised, in the phase's label colour. Content:

| Chat state | Status line |
|---|---|
| `submitting` | Sending |
| running, `working` | Working (only shown when the phase is not `thinking`; there the centre label already says it) |
| running, `thinking` / `writing` | Thinking / Writing |
| running, `tool` | the tool's `displayName` (`Terminal`, `Web search`), else Working |
| `commandRunning` | Command |
| otherwise | nothing (the space stays empty; the centre does not move) |

**Type:**

- State label: 44 sp in portrait, 40 sp in landscape, w600.
- Hint: 22 sp. Error detail: 20 sp.
- Title and swipe hint: 16 sp, the phase's hint colour.
- At 200 % text, the content scales down inside the button (`FittedBox`). The button keeps ≥ 90 % of the screen.

### 4.7 Orientation

`ANNAHME:` car mode follows the device rotation and does not lock it (not a gate).

- **Portrait:** as drawn above.
- **Landscape:** the top strip spans the width: badge left, status line in the middle, title right. Below it, the
  icon sits on the left and the label and hint on the right.

A later "lock landscape" option (`SystemChrome.setPreferredOrientations`) is a three-line change in
`car_mode_screen.dart`, listed under "Later".

### 4.8 Leaving by swipe: separating tap and drag

The button has one `GestureDetector` for the tap and the horizontal drag. Flutter's gesture arena decides:

- The `TapGestureRecognizer` loses as soon as the pointer moves more than `kTouchSlop` (18 dp) before lifting
  (`preAcceptSlopTolerance`). The `HorizontalDragGestureRecognizer` wins the arena once the horizontal movement
  passes `kTouchSlop`. **So a swipe never counts as a tap**: it cannot start a round or send. A vertical wobble
  beyond 18 dp also cancels the tap. That is intended on a bumpy road.
- On drag end, car mode exits if `|dx| ≥ min(96 dp, 25 % of the width)`, or if `|velocity.dx| ≥ 700 dp/s` and
  `|dx| ≥ 48 dp`. Shorter drags do nothing: no tap, no exit, log `swipe action=short`. `ANNAHME:` these numbers;
  check in Task 9 step 11 (a deliberate swipe leaves; a short slide of a finger does neither).
- While dragging, the content follows the finger at 35 % of `dx`, so the swipe visibly registers.
- The system Back gesture from the edge is handled by Android and arrives as a route pop. It is not a drag on the
  button.

## 5. Architecture (own files)

All new code lives in `lib/car_mode/`. Tests live in `test/car_mode/`.

| File | Responsibility | Depends on |
|---|---|---|
| `lib/car_mode/car_mode_state.dart` | Pure: `enum CarPhase`, `enum CarConnection`, `class CarSnapshot`, `carPhaseOf`, `enum CarTapAction { talk, sendNow, ignore }`, `carTapActionFor`, `carTextFor`, `carIconFor`, `carStatusLine`, `carConnectionText`, `carSwipeExits`, `class CarTapGate`, `enum CarDelivery`, `carDeliveryFor` | `VoiceInputPhase` only |
| `lib/car_mode/car_mode_palette.dart` | Day/night colours per phase and per connection, from `WingTokens` | `wing_theme.dart` |
| `lib/car_mode/car_mode_bridge.dart` | `class CarModeBridge` (closures into the workspace), `carSnapshotOf(...)`, `carActivityOf(ProfileChat)`, `carTapOnlySettings(VoicePreferences)`. The **only** car code that reads `ProfileChat`, controllers and `ServerConnectionStatus` | fork types; body re-adapted after the upstream merge |
| `lib/car_mode/car_mode_session.dart` | `class CarModeSession extends ChangeNotifier`: enter/exit, screen-on holder, tap dispatch, hold/release, retry timer, connection signal, auto-exit, log lines | bridge, state, `VoiceSwitchHolders` |
| `lib/car_mode/car_mode_screen.dart` | `CarModeScreen` route: one full-screen button, top strip, status line, swipe and Back, portrait/landscape, `Semantics` | session, palette, `WingTokens` |
| `docs/CAR_MODE.md` | Behaviour, log lines, limits, device checks | |

### 5.1 Interfaces

```dart
// car_mode_state.dart
enum CarPhase { idle, listening, transcribing, thinking, speaking, waiting, attention, error }
enum CarConnection { ok, reconnecting, offline }
enum CarTapAction { talk, sendNow, ignore }
enum CarDelivery { send, steer, queue, end }
typedef CarText = ({String label, String? hint, String? detail});

class CarSnapshot {
  const CarSnapshot({
    required this.chatKey,          // Object? – identity of the chat on screen
    this.title,                     // shown small, never logged
    this.input = VoiceInputPhase.idle,
    this.speaking = false,          // output owner != null
    this.working = false,           // chat.busy
    this.activity,                  // status line: kind or tool name only, never logged
    this.needsInput = false,        // approval / clarification / secure prompt
    this.connection = CarConnection.ok,
    this.error,                     // short voice/turn error text, never logged
  });
}

CarPhase carPhaseOf(CarSnapshot s, {bool held = false});
CarTapAction carTapActionFor(CarPhase phase, CarSnapshot s);
CarText carTextFor(CarPhase phase, CarSnapshot s);
IconData carIconFor(CarPhase phase);
String? carStatusLine(CarPhase phase, CarSnapshot s);   // §4.6 table
({String label, IconData icon}) carConnectionText(CarConnection c);
bool carSwipeExits({required double dx, required double velocity, required double width});
CarDelivery carDeliveryFor({required bool working, required bool steerAvailable, required bool queueAvailable});
class CarTapGate { CarTapGate({Duration gap = const Duration(milliseconds: 600)}); bool accept(); void dispose(); }

// car_mode_bridge.dart
class CarModeBridge {
  const CarModeBridge({
    required this.changes,     // Listenable: controller, connection status, voice in/out
    required this.read,        // CarSnapshot Function()
    required this.preferences, // SharedPreferences: accent theme + input route for the log
    required this.talk,        // Future<void> Function(): stop playback, open a round
    required this.sendNow,     // Future<void> Function(): end the round, deliver as hands-free
    required this.stopSpeech,  // Future<void> Function(): VoiceOutputController.stop (timed for the log)
    required this.retry,       // Future<void> Function(): controller.resumeConnection()
    required this.sendHeld,    // Future<void> Function(): send the held draft through _sendConversationTurn
    required this.leave,       // VoidCallback: cancel round + stop speech (workspace _cancelVoice)
  });
}
CarSnapshot carSnapshotOf(ProfileWorkspaceController controller,
    VoiceInputController input, VoiceOutputController output);
String? carActivityOf(ProfileChat chat);
VoicePreferences carTapOnlySettings(VoicePreferences s);   // vad.pause := vad.maxDuration

// car_mode_session.dart
class CarModeSession extends ChangeNotifier {
  CarModeSession({required VoiceDevice device, required CarModeBridge bridge,
      void Function(String line)? log, Duration retryEvery = const Duration(seconds: 20)});
  bool get active;
  bool get held;
  CarSnapshot get snapshot;
  CarPhase get phase;                          // carPhaseOf(snapshot, held: held)
  Future<void> enter(BuildContext context);    // push CarModeScreen, screen-on holder
  void exit(String reason);                    // leave(), release holder, pop
  Future<void> tap();                          // carTapActionFor → gate → bridge
  VoicePreferences roundSettings(VoicePreferences s);   // case 2 → carTapOnlySettings
  bool holdForConnection();                    // called by _sendConversationTurn
  void logDelivery(CarDelivery delivery);      // called by the steering hook (§6.4)
  void swiped({required bool exits});          // screen reports a horizontal drag
}
```

The pushed route sits outside the workspace's `Theme(profileWorkspaceTheme(...))` wrapper (vo `:680-686`).
`CarModeScreen` re-applies `profileWorkspaceTheme(Theme.of(context), accent:
WorkspaceAccent.fromName(prefs.getString(WorkspaceAccent.preferenceKey)))` (vo
`lib/core/theme/profile_workspace_theme.dart:17`, `:22`).

## 6. Hooks in `profile_workspace_screen.dart` (vo lines)

### 6.1 Focus

`didChangeDependencies` (vo `:561`): `_routeIsCurrent = isCurrent;` → `_routeIsCurrent = isCurrent || _car.active;`

`enter()` sets `active = true` **before** the push; leaving sets it false before the pop. Flutter calls
`didChangeDependencies` on both route changes, because the workspace depends on `ModalRoute.of`. With the hook,
`_hasWorkspaceFocus` stays true under car mode. Auto read-aloud (vo `:239`), the loop (vo `:282`), the media keys
(`_syncMediaKeys`, vo `:349-354`) and `setRouteVisibility` keep working.

**Upstream merge note:** upstream `_hasChatFocus` also checks `!_conversationObscured`. Car mode does not open
that card stack, so this is fine.

### 6.2 Read-aloud, round settings, tap-send

- vo `:245`: `if (!(settings.autoSpeak || settings.conversation) || …)` →
  `if (!(settings.autoSpeak || settings.conversation || _car.active) || …)`.
- vo `:401`: `final settings = VoicePreferences.read(controller.preferences);` →
  `final settings = _car.roundSettings(VoicePreferences.read(controller.preferences));`.
- vo `:402`: `_conversation = settings.conversation ? chat.key : null;` →
  `_conversation = settings.conversation || _car.active ? chat.key : null;`.
- New field `bool _carSend = false;`, reset to false in `_dictate` right after `await _voiceOutput.stop();` (vo `:393`).
- vo `:411` becomes `final send = _conversation == chat.key && (_voiceInput.finishedOnItsOwn || _carSend);`.
- Bridge `sendNow`: `_carSend = true; return _voiceInput.stopHandsFree();`.

vo `:244` and `:293` stay unchanged, so the loop still follows only the saved setting.

### 6.3 Held recording

In `_sendConversationTurn`, directly after `final text = chat.draft.trim();` (vo `:301`):

```dart
    if (_conversation == chat.key && text.isNotEmpty && _car.holdForConnection()) return;
```

Bridge `sendHeld`: look up the current chat, set `_conversation = chat.key`, `await _sendConversationTurn(chat)`.

### 6.4 Shared hook: hands-free utterance on a busy chat (= barge-in §3.3)

The user taps during `thinking` and speaks. When the transcript is ready, the chat is usually still busy. Today
`_sendConversationTurn` ends the loop there (vo `:306`).

- **If barge-in has landed** (`git grep -n "decideDelivery" -- lib`): its hook already steers/queues. Car mode adds
  no code and only tests the path.
- **If not:** car mode adds the minimal version, only while `_car.active`, before the `chat.busy` abort (full code
  in plan Task 7). It picks steer, else queue, through `_composerActions`/`_performComposerAction`, and logs
  `deliver kind=…`. `_performComposerAction` already clears the draft after an accepted steer and shows "Hermes
  rejected the steering message." on `false` (vo `:2323-2333`). `ANNAHME:` that snackbar is not visible under the
  car route. The rejection is rare: `rejected` only comes when the turn already ended. The car screen then shows
  `idle`, and the user can tap again.
- Known edge: a **queued** utterance runs as its own turn after the current one. In case 1 the microphone stays
  closed afterwards until the next tap (documented in `docs/CAR_MODE.md`).

### 6.5 Entry, field and dispose

- **Menu item:** `PopupMenuItem(value: 'car', child: Text('Car mode'))` (`StudioPopupMenuItem` after the upstream
  merge).
- **`onSelected`:** `else if (action == 'car') { unawaited(_car.enter(context)); }`.
- **Field:** `late final _car = CarModeSession(device: _voiceDevice, bridge: CarModeBridge(...))`, with closures over
  `_dictate`, `_carSend`, `_voiceInput`, `_voiceOutput`, `controller`, `_sendConversationTurn`, `_cancelVoice`.
- **`dispose`:** `_car.dispose();` (vo `:651`).

## 7. Privacy and logging

Log lines use the prefix `WingCar` via `debugPrint` and contain only events, phases, actions, enum values and
durations. They **never** contain spoken text, transcript, reply text, held text, chat title, tool name, activity
text or session id.

```
WingCar enter route=<vad|local|hermes> loop=<on|off>
WingCar tap phase=<idle|listening|…> action=<talk|sendNow|ignore|debounced>
WingCar stopSpeech ms=<n>          (tap in speaking: time from tap to VoiceOutputController.stop() returning)
WingCar deliver kind=<send|steer|queue|end>
WingCar connection state=<ok|reconnecting|offline>
WingCar hold
WingCar release
WingCar swipe action=<exit|short>
WingCar exit reason=<swipe|back|chatChanged|disposed>
```

`stopSpeech ms` is the acceptance number for "tap stops read-aloud ≤ 0.5 s". `ANNAHME:` audible silence follows
within ~50 ms of the `stopPlayback` call; Task 9 step 6 checks it by ear.

## 8. Upstream files touched

| File | Lines (estimate) | What |
|---|---|---|
| `lib/core/screens/profile_workspace_screen.dart` | **~46** (Task 6): imports 3, `_carSend` 1, `_car` field with bridge closures 29, `:245` 1, `:401` 1, `:402` 1, `_carSend` reset 1, `:411` 2, hold hook 2, focus 1, menu 3, dispose 1. **+ ~23** (Task 7) only if barge-in has not landed. Total **~69**; acceptance limit **80** (Task 6 alone ≤ 58) | thin hooks §6 |
| `.github/workflows/voice-review.yml` (fork-owned, VAD chain) | 1 | add `test/car_mode/car_mode_screen_test.dart` to the render list (vo `:34-35`) |

Not touched: `voice_input_controller.dart`, `voice_output_controller.dart`, `vad_endpoint.dart`,
`voice_preferences.dart`, `android_voice.dart`, `VoiceChannel.kt`, `VoicePlayback.kt`, `VadCapture.kt`,
`pubspec.yaml`, Kotlin. No overlap with the TTS-language plan (`android_voice.dart` `speak`, `VoicePlayback.kt`,
`VoiceChannel.kt`).

The previous estimate was ~35 + ~22. The new lines are the hold hook, `sendHeld`/`retry` closures and the
`:401`/`:402` changes for case 2. The forced loop (`_loopWanted` at four places) is gone.

## 9. Dependencies and base

- **Base:** `voice-offline` with the VAD chain (done: `b4f5e4a0`) **and** after the upstream merge chain
  (t_f8523002 done; still pending). Strategy rule 3: "never merge into a running voice chain".
- **Needs from the VAD chain:** `VoiceSwitchHolders.screenOn`, `stopHandsFree()`, the media-key dispatcher
  (unchanged, so steering-wheel keys keep working in car mode).
- **Barge-in:** optional (§6.4). Either may land first. The plan's "Basis / Rebase" section checks which is there.
- **Background voice with the screen off (t_4934d7d4):** separate case. Car mode always keeps the screen on.
- **TTS language plan:** no shared file.

## 10. Testing

- **Pure** (`test/car_mode/car_mode_state_test.dart`): phase priority incl. `waiting`; tap table; texts; status
  line table (never `detail`); connection texts; swipe thresholds; debounce; `carDeliveryFor`.
- **Palette** (`test/car_mode/car_mode_palette_test.dart`): contrast for every phase, the connection badge, every
  accent, both themes; no white at night.
- **Bridge** (`test/car_mode/car_mode_bridge_test.dart`): `carTapOnlySettings` copies every field and only sets
  `vad.pause = vad.maxDuration`; a `VadEndpointer` built from it does not end on 200 silent windows after speech;
  `carActivityOf` returns kind or display name, never `detail`.
- **Session** (`test/car_mode/car_mode_session_test.dart`) with a fake bridge and `VoiceDeviceFixture`:
  - screen-on holder on enter, off on exit/dispose (`keepScreenOnCalls`);
  - tap dispatch and debounce; auto-exit on chat change;
  - hold → connection back → `sendHeld` exactly once, even after further notifications;
  - retry timer while held and offline;
  - connection signal logged once per change to offline and back;
  - log lines contain no title, error, activity or held text (sentinels).
- **Screen** (`test/car_mode/car_mode_screen_test.dart`):
  - every phase renders its label and icon; the status line shows `Terminal`;
  - the button covers ≥ 90 % of the screen; a tap on the badge or status line reaches the session;
  - **a swipe exits** (`exit reason=swipe`, `leave` called) and **never starts a round** (no `talk`);
  - a short drag neither taps nor exits;
  - Back pops directly;
  - the swipe hint shows for 6 s, then disappears;
  - 320 dp at 200 % text and 411×960 / 960×411, light and dark, with no overflow; `VOICE_REVIEW` captures.
- **Workspace** (`test/voice_workspace_test.dart`, group "car mode"):
  - **case 2:** three rounds by tap only with conversation mode off on the `vad` route: tap → recording, silence does
    **not** end it, tap → sent, reply read aloud, then idle with the microphone closed (no new start);
  - **case 1:** conversation mode on, `local` route: tap while listening sends at once; after the reply the loop
    reopens the microphone;
  - tap during read-aloud → `stopPlayback` before `start`;
  - focus stays (media keys stay on) under the car route;
  - swipe exit cancels a recording and keeps the draft;
  - tap during thinking → steer;
  - **recording finished offline → "Waiting for connection" → sent exactly once after reconnect**;
  - approval: the tap does nothing.
- **Device:** plan Task 9, run by a separate worker card via `hadb`.

## 11. Later (not in this card)

Landscape lock, a real connection tone (delta in the plan), a car-mode shortcut (launcher shortcut / Quick
Settings tile), auto-enter on car Bluetooth or Android Auto (Birk does not pair the phone), a voice command "exit car
mode", and background operation with the screen off (t_4934d7d4).

## Mockup and screenshots

The clickable draft is `docs/superpowers/specs/2026-10-14-wing-car-mode-mockup.html`. It is a single file with no
network access. It covers:

- the state machine from §4.3, with auto-advance;
- the app's "Conversation mode" setting as a switch (case 1 / case 2); it is the app setting, not a car-mode control;
- leaving by horizontal drag (mouse or touch) and by an "Android Back" button in the side panel;
- the status line with sample activities (Working, Terminal, Web search);
- connection states connected / reconnecting / offline, and "Waiting for connection" with a held recording;
- portrait and landscape, day and night;
- a log panel with the text-free log lines from §7.

The screenshots are in `docs/superpowers/specs/2026-10-14-wing-car-mode-shots/`:

- `<state>-<portrait|landscape>-<day|night>.png` for all 8 states (32 shots);
- variants: `idle-…-entry` (swipe hint), `idle-…-reconnecting`, `idle-…-offline`, `listening-portrait-night-offline`,
  `listening-portrait-day-steer`, `thinking-portrait-day-working`, `thinking-portrait-night-websearch`.

To re-render: `python3 docs/superpowers/specs/2026-10-14-wing-car-mode-shots/render_shots.py` (Playwright +
`/usr/bin/chromium`).

## Decisions (Birk 14.10.)

1. **D1 is replaced by two cases.** Birk: „1. Gesprächsmodus an: der große Knopf ist nur Notlösung, falls das
   Satzende nicht erkannt wird (Tippen = sofort senden). 2. Automodus OHNE Gesprächsschleife: Tippen startet die
   Aufnahme, Tippen beendet sie und sendet – keine automatische Pausenerkennung nötig. Die Antwort wird automatisch
   vorgelesen, danach Leerlauf (Mikro bleibt zu), bis Birk wieder tippt. Plan anpassen: Fall 2 ist der eigentliche
   Automodus (Push-to-talk + Auto-Vorlesen), die erzwungene Gesprächsschleife entfällt dafür.“
   → §4.2. The forced loop is removed. Car mode does not override the saved setting in either direction.
   Tap while Hermes works: option A stays as `ANNAHME:` (§4.3).
2. **D2: leave by swipe / Android Back, no exit button.** Birk: „Verlassen per Wischen zur Seite (statt Antippen
   einer Beenden-Zone). Damit braucht der Bildschirm keine Beenden-Schaltfläche, der ganze Bildschirm kann
   Sprechknopf sein. Die Android-Zurück-Geste (Wischen vom Rand) verlässt den Automodus direkt, ohne
   Hinweis/Bestätigung; zusätzlich horizontales Wischen über die Fläche, falls Birk 3-Tasten-Navigation nutzt. Ein
   Wisch darf nie als Tippen (Aufnahme starten/senden) zählen.“ → §4.1, §4.8.
3. **D3: colour field (A)**, from Birk's D2 reasoning: „der ganze Bildschirm kann Sprechknopf sein.“ Two mandatory
   additions:
   - (a) a status line in the upper third showing what Hermes is working on, as the chat shows it, drawn on the
     button → §2.2, §4.6;
   - (b) a large coloured connection status, a signal on loss and return, and a recording finished while offline
     is held and sent automatically once → §2.3, §4.4.
4. **Screen always on.** Birk: „Im Autofahrmodus bleibt der Bildschirm immer an … Bildschirm-an gehört fest zum
   Autofahrmodus, nicht als Option. Hintergrundbetrieb mit Bildschirm aus (t_4934d7d4) ist ein getrennter Fall.“
   → §4.1.

Remaining assumptions, each with its check: the case-2 `local` and `maxDuration` edges (§4.2), the tap while
working and while waiting (§4.3), the debounce (§4.3), `limited` = reconnecting, vibration only, 20 s retry (§4.4),
swipe thresholds (§4.8), swipe-hint duration (§4.1), split-screen (§4.1), snackbar under the car route (§6.4),
stop latency (§7).

## Kurzfassung (für Birk)

Der Automodus ist ein eigener Vollbild-Screen über dem offenen Chat, geöffnet über das ⋮-Menü. Der **ganze
Bildschirm** ist die Taste. Darauf stehen nur: oben links groß und farbig der Verbindungsstatus
(Connected / Reconnecting / Offline), im oberen Drittel woran Hermes gerade arbeitet (z. B. „Terminal“), in der
Mitte der Zustand.

- **Gesprächsmodus aus (der eigentliche Automodus):** Tippen startet die Aufnahme, Tippen beendet und schickt ab.
  Es gibt keine Pausenerkennung. Die Antwort wird vorgelesen, danach ist Ruhe, und das Mikro bleibt zu bis zum
  nächsten Tippen.
- **Gesprächsmodus an:** Die Schleife läuft wie bisher. Tippen ist nur die Notlösung, wenn das Satzende nicht
  erkannt wird (sofort senden).
- Der Automodus ändert die gespeicherte Einstellung nie.
- **Tippen beim Vorlesen:** stoppt das Vorlesen und startet die Aufnahme.
- **Tippen, während Hermes arbeitet:** Das Gesagte steuert die laufende Runde (Annahme, wie bisher Option A).
- **Verlassen:** Android-Zurück oder seitlich wischen, ohne Rückfrage. Ein Wisch zählt nie als Tippen. Beim Start
  steht 6 s lang klein „↔ Swipe to leave“ am unteren Rand. Oben neben dem Verbindungsstatus wurde der Hinweis im
  Entwurf abgeschnitten, deshalb steht er unten.
- **Verbindung weg:** Das Handy vibriert dreimal, beim Zurückkommen zweimal. Ein Ton geht nur mit einer kleinen
  Erweiterung im Android-Teil; die ist als Option vorbereitet.
- **Aufnahme ohne Verbindung:** Das Gesagte bleibt als Entwurf auf dem Handy, und der Bildschirm zeigt „Waiting for
  connection“. Sobald die Verbindung zurück ist, wird es genau einmal abgeschickt.
- Der Bildschirm bleibt im Automodus immer an. Der Betrieb mit Bildschirm aus ist eine eigene Karte (t_4934d7d4).
- Gesprochener Text, Antworttext und Tool-Details erscheinen weder auf dem Display noch im Log.
- Im Upstream-Screen landen etwa 46 Zeilen Einhängepunkte, mit Steuern etwa 69 (Grenze 80). Alles andere liegt in
  `lib/car_mode/`.

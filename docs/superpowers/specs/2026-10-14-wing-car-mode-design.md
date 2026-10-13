# Wing Voice: car mode, one big talk button — design

Card: t_c8de9cba (board wing). Date: 2026-10-14. Status: design, waiting for Birk's go on the
clickable draft (`2026-10-14-wing-car-mode-mockup.html`, screenshots in `2026-10-14-wing-car-mode-shots/`).
Implementation starts only after his okay. Work continues with the assumptions marked
`ANNAHME (Birk-Gate):`.

## 1. The wish

Birk wants a car mode in Wing. The screen shows only one very large button for "talk" or "stop". It can be
hit blind and has no small controls. Most of his cars have no media keys on the steering wheel, and he does
not want to pair the phone with the car. The media key from the VAD chain stays available, but it is not his
main path.

User task: hold a voice conversation with Hermes while driving, with the phone in a mount.
Primary action: **one tap anywhere on the big button** does the next sensible thing.
Editable controls: none inside car mode.
Passive context: the current state in large type, plus the chat title in small type.
Temporary status: errors, offline, and "needs you on screen".

## 2. What exists today (checked in code)

Line numbers: **wt** = `wt/t_24ef9c3d` @ `4a1a86c6` (VAD chain, read via `git show`). **vo** = this branch
(`voice-offline` f2c08256 plus docs). **up** = `upstream/main` @ `8105ab72`. Merge base of vo and up:
`151ee281`.

### 2.1 Voice runtime (fork)

| Fact | Where |
|---|---|
| `enum VoiceInputPhase { idle, starting, recording, transcribing }` | wt `lib/core/controllers/voice_input_controller.dart:10` |
| `VoiceInputController.stopHandsFree()`: on the VAD route `forceEnd(VadEndReason.mediaKey)`, i.e. sent. Otherwise it falls back to `stop()`, which is **not** sent (`_stopRequested = true`) | wt `voice_input_controller.dart:165` (`_stopRequested` rule in `_finishVad`, `finishedOnItsOwn = !_stopRequested && _remote == null` in `_finish`) |
| `VoiceOutputController.speak(...)` returns `true` only if playback ran to the end; `stop()` | vo `lib/core/controllers/voice_output_controller.dart:74`, `:124` |
| Conversation loop: `_speakCompletedReply` → `_canContinueConversation` → `_dictate(chat, resume: true)` | wt `lib/core/screens/profile_workspace_screen.dart:238-274`, `:278-296`, `:392-436` |
| The loop runs only if `settings.conversation` | wt `:244`, `:245`, `:293`, `:402` |
| Auto-send only if `_conversation == chat.key && _voiceInput.finishedOnItsOwn` | wt `:411` |
| `_sendConversationTurn` ends the loop if `chat.busy` | wt `:300-322`, condition `:306` |
| `_dictate` first calls `await _voiceOutput.stop()`, so a new round always stops read-aloud | wt `:393` |
| Media-key dispatcher (VAD route only): recording → `stopHandsFree()`; idle → `_dictate(chat)` | wt `:356-369` |
| Keep screen on: shared holder set `VoiceSwitchHolders.screenOn(device).set(owner, on)` | wt `lib/core/services/android_voice.dart:215-241`; used by the `_conversation` setter wt `:217-222` |
| `_hasChatFocus = _routeIsCurrent && _appIsActive && _destination == chats`; `_routeIsCurrent` comes from `ModalRoute.isCurrentOf(context)` in `didChangeDependencies` | wt `:552-564` |
| App paused, hidden or detached → `_cancelVoice()` | wt `:611-619` |
| "Chat actions" overflow menu (`PopupMenuButton<String>`, values `parent/outputs/subagents/goal/background/find/refresh`) | wt `:979-1048` |
| Steer / queue / send while busy: `_composerActions` and `_performComposerAction(chat, action, {conversation})` | wt `:2218-2274`, `:2287-2335` |
| `controller.steer(chat, rawText)` → `true` on `queued`, `false` on `rejected` or when not running/attention | vo `lib/core/services/profile_workspace_controller.dart:4927-4970` |
| `ServerConnectionPhase { unchecked, connected, reconnecting, limited, disconnected }`, `controller.connectionStatus` | vo `lib/core/services/server_connection_status.dart:7-13`, `profile_workspace_controller.dart:474` |
| Navigation: plain `Navigator.push(MaterialPageRoute(...))`, no go_router | vo e.g. `lib/core/screens/administration/voice_settings_navigation.dart:24` |
| Localization: none. All UI strings are hard-coded **English** (`'Reading aloud'`, `'Stop speech'`) | vo: no `*.arb`, no `flutter_localizations` in `pubspec.yaml` |
| Orientation: no lock. MainActivity handles `orientation\|screenSize` itself, so rotating does not restart the activity | vo `android/app/src/main/AndroidManifest.xml:41` |
| No `SystemChrome.setPreferredOrientations` and no wakelock package anywhere | vo + up (grep) |
| VAD cue tones: `ToneGenerator` beep at start, ack at end, when `VadCaptureOptions.cues` (default on) | wt `android/.../VadCapture.kt` `cue(...)` |

### 2.2 Upstream (`8105ab72`)

- **No car, hands-free or conversation mode, and no keep-screen-on.** A grep over `lib`, `android` and
  `pubspec.yaml` for car, driving, handsfree, keepScreenOn, FLAG_KEEP, setPreferredOrientations and
  wakelock finds only the Bots screen's immersive toggle and a background `PARTIAL_WAKE_LOCK`. The plan
  therefore stands as designed.
- Upstream moved voice into controllers. `VoiceInputController.dictate(...)` only fills the draft and never
  sends (up `lib/core/controllers/voice_input_controller.dart`). `services/voice_preferences.dart` is
  **deleted** upstream; the settings live in `AppPreferences.voiceInputSettings` (up
  `lib/core/services/app_preferences.dart:137`). The fork's loop, `autoSpeak` and `conversation` have to be
  re-planted by the upstream merge chain (t_d1d49ff1 → t_6a4e1890 → t_f8523002). That merge has not been
  done yet: `wt/t_d1d49ff1` is still at `eb87b9b0`.
- Turn state upstream: `chat.runtime.execution` (`ChatExecution { idle, submitting, running, completed,
  cancelled, failed }`), `chat.runtime.needsInput`, `canSteer`, `reconnecting`, `offline` (up
  `lib/core/models/chat_runtime.dart:7-9`, getters at the end of `ChatRuntimeObservation`).
- The "Chat actions" menu still exists upstream (up `profile_workspace_screen.dart:1399-1442`, uses
  `StudioPopupMenuItem`). So does `didChangeDependencies` with `ModalRoute.isCurrentOf` (up `:776-780`),
  and `_hasChatFocus` (up `:769-773`, which additionally has `_pendingBotTitle` and
  `!_conversationObscured`).

**Consequence:** car mode must not depend on fork-only or upstream-only types in its own logic. It reads
one neutral snapshot (§5.1). The snapshot is filled by one adapter function. That function is the only car
code that knows `ProfileChat`, so after the merge only its body changes.

### 2.3 Barge-in (t_7e81e040), designed in parallel

The spec is committed as `f1e244da` (`docs/superpowers/specs/2026-10-14-wing-voice-barge-in-design.md`).
It is not on this branch yet. Relevant parts:

- §3.3/§4.3: a hands-free utterance on a **running** chat becomes `steer`. On `submitting`/`reconnecting`
  it becomes `queue`; on idle, `send`. This is the pure `decideDelivery(status, text)` in the planned
  `lib/voice_offline/barge_in_policy.dart`, hooked into `_sendConversationTurn`.
- D3: an interrupted reply is not resumed. It stays in the chat.
- Voice barge-in during read-aloud is gated by an echo measurement. The media key stays the barge-in that
  always works.

Car mode does **not** depend on voice barge-in. The tap *is* a manual barge-in, and it uses what exists
today: `_dictate` stops playback first. The only shared piece is the **"deliver a hands-free utterance to
a busy chat"** hook in `_sendConversationTurn` (§6.3).

## 3. Approaches considered

| | A: own route on top of the workspace (**chosen**) | B: overlay layer inside the workspace | C: extract the conversation loop into its own controller |
|---|---|---|---|
| Idea | `CarModeScreen` is pushed with `Navigator.push`. The workspace stays mounted below and keeps running the loop | A `Stack` layer over the chat in `_buildWorkspace` | The loop moves out of the screen; car mode and chat both drive it |
| Hooks in `profile_workspace_screen.dart` | ~30 lines (§8) | ~35 lines, plus a guard in every chat `PopScope`. All `PopScope`s on a route get `onPopInvoked`, so Back would also run the chat's `_leaveChat()` | Hundreds of lines in exactly the file upstream rewrote (±4516 lines) |
| Back, orientation, system bars | Own `PopScope` on its own route; clean | Shared with the chat route | — |
| Risk | The workspace below thinks it lost focus (`_routeIsCurrent` false), which stops the loop and media keys. Fixed with one line (§6.1) | Back-gesture side effects | Merge conflicts, scope creep |

**A** wins on the fewest and clearest hooks. B's Back handling is fragile. C contradicts strategy rule 1 ("own
code in own files, only thin hook points in upstream files",
`hermes-entities/tools/technik/wing-fork-upstream-strategie.md`).

## 4. Behaviour

### 4.1 Entering and leaving

- **Enter:** "Car mode" in the open chat's "Chat actions" menu (⋮). Car mode always talks to **this chat**.
- On entry, car mode:
  - pushes its route (no orientation lock, see 4.5);
  - takes a screen-on holder (`VoiceSwitchHolders.screenOn(device).set(session, true)`) for the **whole**
    car mode, not only while a round runs. The idle screen must not time out either: a screen timeout
    pauses the activity, and `_cancelVoice()` runs (wt `:611-619`);
  - does **not** start the microphone. The first tap does.
- **Exit:** see D2. **ANNAHME (Birk-Gate):** hold the small "Exit" pill top-left for 1 s; a ring fills while
  holding. Android Back is blocked and shows the hint "Hold Exit to leave car mode" for 3 s. Exit:
  - cancels a running recording without sending;
  - stops read-aloud;
  - leaves a running Hermes turn alone;
  - releases the screen-on holder;
  - pops the route and lands in the same chat.
- **Automatic exit:** the workspace switches chat (notification tap, profile or connection switch) → car
  mode closes itself. The chat key in the snapshot no longer matches the entry chat.
- App in the background (e.g. the navigation app in front) → the existing `_cancelVoice()` ends a round.
  Car mode stays open and shows **idle** on return. ANNAHME: Android split-screen keeps Wing `resumed`
  (multi-resume, Android ≥ 10). Verify on the device with Maps in split-screen (acceptance step 9).

### 4.2 States and the tap

The button covers almost the whole screen. A tap anywhere on it does the following:

| Phase | Shown (UI text, English like the app) | Tap does | Source |
|---|---|---|---|
| `idle` | **Tap to talk** | start a round (`talk`) | nothing active |
| `listening` | **Listening** / "Tap to send" | end the round now **and send** what was said (`sendNow`) | `VoiceInputPhase.starting` or `.recording` (tap ignored during `starting`) |
| `transcribing` | **Got it** / "Transcribing…" | nothing | `VoiceInputPhase.transcribing` |
| `thinking` | **Hermes is working** / "Tap to add something" | D1: **ANNAHME (Birk-Gate)** start a round; the utterance **steers** the running turn (§6.3) | chat busy |
| `speaking` | **Reading aloud** / "Tap to interrupt" | stop read-aloud **and** start a round (`talk`; `_dictate` stops output first, wt `:393`) | `VoiceOutputController.owner != null` |
| `attention` | **Needs you on screen** / "Approval or question waiting. Look when parked." | nothing (a tap must never approve anything) | approval, clarification or secure prompt |
| `error` | **Didn't work** / short error text / "Tap to try again" | `talk` | voice error, or failed turn |
| `offline` | **No connection** / "Reconnecting…" or "Tap to retry" | `retry` (`controller.resumeConnection()`) when disconnected; nothing while reconnecting | `connectionStatus.phase` |

Priority, when several facts are true: attention > listening > transcribing > speaking > offline > thinking >
error > idle.

**Car mode forces the conversation loop on**, without changing the saved preference. While car mode is
active, the existing checks of `settings.conversation` (wt `:244`, `:245`, `:293`, `:402`) also count as
true. Replies are therefore read aloud, and the microphone reopens after each reply. The "Conversation mode"
switch in the settings stays untouched (AGENTS.md: never silently change settings).

**Tap = send on every input route.** On VAD, `stopHandsFree()` already sends. On the `local` and `hermes`
routes, a manual stop is never sent today. In car mode a one-shot flag `_carSend` makes the next result
count as hands-free (§6.2). On the `hermes` route there is no end-of-speech detection, so every round ends
by tap. That is acceptable; VAD is the recommended route in the car.

**Debounce:** a tap within 600 ms after the last accepted tap is ignored. This covers double hits on a bumpy
road. ANNAHME: 600 ms. Check in acceptance step 4 that a deliberate second tap (e.g. talk → send) is not
lost; adjust between 400 and 800 ms if it is. The debounce never delays an accepted tap.

**Feedback without looking:**

- `HapticFeedback.heavyImpact()` on every accepted tap; `HapticFeedback.vibrate()` when a tap is ignored
  (attention/transcribing).
- The VAD cue tones (start beep, "got it") stay as they are.
- No new sounds. Cue sounds are still Birk's open choice from the VAD spec §13.11.

### 4.3 What is never shown

- No transcript, no partial text, no reply text. Reading while driving is the risk car mode removes. The
  text stays in the chat.
- No timers. The recording seconds are not shown; the VAD max duration protects the round.

### 4.4 Look

Rules for both variants (D3):

- **Contrast:** full contrast in both themes.
- **Day:** a saturated state fill with white text.
- **Night:** a dark, low-glare tinted fill (state colour mixed 28 % into the dark canvas) with state-coloured
  text. **No pure white** anywhere in night mode.
- **Theme:** follows the app's theme (light/dark, which follows Android). ANNAHME: no separate car-mode
  night switch. If Birk wants one, it would be a small control, which the wish rules out.

| Phase | Colour token (`WingTokens`) | Icon |
|---|---|---|
| idle | `raised` panel with `accent` border and icon (calm, low glare while nothing happens) | mic |
| listening | `danger` (recording convention "REC"), pulsing ring (frozen with reduced motion) | stop square |
| transcribing | `danger`, dimmed | three dots |
| thinking | `running` | hourglass |
| speaking | `accent` (the user's accent) | speaker |
| attention | `warning` | hand |
| error | `warning` | alert triangle |
| offline | `muted` | cloud-off |

Colour is never the only signal: every state has its own icon and label. Day text/fill contrast uses the
documented token pairs (DESIGN_SYSTEM.md, e.g. accent/white 6.09:1). The other day fills, computed with
the WCAG formula from the light hex values in `lib/core/theme/wing_theme.dart:196-201`, are:

- `danger` B91C1C / white: 6.5:1
- `running` 1D4ED8 / white: 6.7:1
- `warning` B45309 / white: 5.0:1
- `muted` 586970 / white: 5.7:1

The night pairs are computed by the palette test (plan Task 6), which requires ≥ 4.5:1 for the hint and
≥ 3:1 for the 40+ sp label.

**Type:**

- State label: 44 sp in portrait, 40 sp in landscape, weight 600.
- Hint: 22 sp.
- Top strip (Exit pill, chat title): 16 sp, `muted`.
- At 200 % text the label wraps, and the button keeps ≥ 70 % of the screen.

### 4.5 Orientation

ANNAHME (not a gate): car mode follows the device rotation and does not lock it. Both layouts exist:

- **Portrait:** top strip, then the button fills the rest.
- **Landscape:** a narrow strip on the left with the Exit pill, then the button fills the rest.

With Android's auto-rotate off, the phone stays in portrait. If Birk mounts the phone in landscape with
auto-rotate off, a later option "lock landscape" (`SystemChrome.setPreferredOrientations`) is a three-line
change in `car_mode_screen.dart`. It is listed under "Later", not built now.

## 5. Architecture (own files)

All new code lives in `lib/car_mode/`. Tests live in `test/car_mode/`.

| File | Responsibility | Depends on |
|---|---|---|
| `lib/car_mode/car_mode_state.dart` | Pure: `enum CarPhase`, `class CarSnapshot`, `CarPhase carPhaseOf(CarSnapshot)`, `enum CarTapAction { talk, sendNow, retry, ignore }`, `CarTapAction carTapActionFor(CarPhase, CarSnapshot)`, `class CarTapGate` (debounce, injectable clock), `enum CarDelivery { send, steer, queue, end }`, `CarDelivery carDeliveryFor({...})` | `VoiceInputPhase` only |
| `lib/car_mode/car_mode_bridge.dart` | `class CarModeBridge` (the operations the screen offers, as closures) + `CarSnapshot carSnapshotOf(...)`, the **only** car code that reads `ProfileChat`, the controllers and `ServerConnectionStatus` | fork types; body re-adapted after the upstream merge |
| `lib/car_mode/car_mode_session.dart` | `class CarModeSession extends ChangeNotifier`: `active`, `enter(BuildContext)`, `exit()`, `tap()`, screen-on holder, auto-exit on chat change, log lines | bridge, state, `VoiceSwitchHolders` |
| `lib/car_mode/car_mode_screen.dart` | `CarModeScreen` route widget: big button, hold-to-exit pill, Back hint, portrait/landscape layout, `Semantics` | session, `WingTokens` |
| `lib/car_mode/car_mode_palette.dart` | Day/night colours per phase, derived from `WingTokens` (`Color.lerp(surface, token, .28)` for night) | `wing_theme.dart` |
| `docs/CAR_MODE.md` | Behaviour, log lines, device checks | |

### 5.1 Interfaces

```dart
// car_mode_state.dart
enum CarPhase { idle, listening, transcribing, thinking, speaking, attention, error, offline }
enum CarConnection { ok, reconnecting, offline }

class CarSnapshot {
  const CarSnapshot({
    required this.chatKey,        // Object? – identity of the chat on screen
    required this.input,          // VoiceInputPhase
    required this.speaking,       // output owner != null (incl. preparing)
    required this.working,        // turn submitting/running/attention/reconnecting
    required this.steerable,      // turn running or attention (steer accepted)
    required this.needsInput,     // approval / clarification / secure prompt
    required this.connection,     // CarConnection
    this.error,                   // short voice/turn error text, or null
  });
}

CarPhase carPhaseOf(CarSnapshot s);
CarTapAction carTapActionFor(CarPhase phase, CarSnapshot s);   // see table 4.2
CarDelivery carDeliveryFor({required bool working, required bool steerable,
    required bool steerAvailable, required bool queueAvailable});

class CarTapGate {                    // debounce
  CarTapGate({Duration gap = const Duration(milliseconds: 600), DateTime Function()? now});
  bool accept();
}

// car_mode_bridge.dart
class CarModeBridge {
  const CarModeBridge({
    required this.changes,            // Listenable: controller + voice in/out
    required this.read,               // CarSnapshot Function()
    required this.talk,               // Future<void> Function(): stop playback, open a round (loop forced on)
    required this.sendNow,            // Future<void> Function(): end round, deliver as hands-free
    required this.retry,              // Future<void> Function(): controller.resumeConnection()
    required this.leave,              // VoidCallback: cancel round + stop speech (workspace _cancelVoice)
  });
}

// car_mode_session.dart
class CarModeSession extends ChangeNotifier {
  CarModeSession({required VoiceDevice device, required CarModeBridge bridge,
      void Function(String line)? log});
  bool get active;
  CarPhase get phase;
  Future<void> enter(BuildContext context);   // push CarModeScreen, screen-on holder
  void exit();                                // leave(), release holder, pop
  void tap();                                 // gate → carTapActionFor → bridge
}
```

## 6. Hooks in `profile_workspace_screen.dart` (fork lines wt)

### 6.1 Focus

`didChangeDependencies` (wt `:560-561`):
`_routeIsCurrent = isCurrent;` → `_routeIsCurrent = isCurrent || _car.active;`

`enter()` sets `active = true` **before** the push. `exit()` sets it to false **before** the pop. Flutter
calls `didChangeDependencies` on both route changes, because the workspace depends on `ModalRoute.of`.
That is the existing mechanism behind `_routeIsCurrent`. With the hook:

- `_hasChatFocus` stays true under car mode;
- the loop (`_canContinueConversation`, wt `:282`), the auto-speak check (`_hasWorkspaceFocus`, wt `:239`),
  the media keys (`_syncMediaKeys`, wt `:349-354`) and `setRouteVisibility` keep working.

**Upstream merge note:** upstream `_hasChatFocus` also checks `!_conversationObscured` (the recents card
stack). Car mode does not open that stack, so this is fine.

### 6.2 Loop forced on, tap counts as hands-free

- New getter: `bool _loopWanted(VoicePreferences s) => s.conversation || _car.active;`
- It replaces `settings.conversation` at wt `:244`, `:245` (inside `autoSpeak || …`), `:293` and `:402`.
- New field `bool _carSend = false;`:
  - reset to false at the start of `_dictate` (after `_voiceOutput.stop()`);
  - wt `:411` becomes
    `final send = _conversation == chat.key && (_voiceInput.finishedOnItsOwn || _carSend);`.
- Bridge `sendNow`: `_carSend = true; return _voiceInput.stopHandsFree();`.

### 6.3 Shared hook: hands-free utterance on a busy chat (= barge-in §3.3)

This applies when the user taps during `thinking` and then speaks. When the transcript is ready, the chat is
usually still busy. Today `_sendConversationTurn` ends the loop there (wt `:306`).

- **If barge-in has landed** (`git grep -n "decideDelivery" lib/`): its hook already steers/queues. Car mode
  adds no code and only tests the path.
- **If not:** car mode adds the minimal version, only while `_car.active`. Before the `chat.busy` abort:

  ```dart
  if (chat.busy && _car.active) {
    final delivery = carDeliveryFor(
      working: true,
      steerable: {ProfileTurnStatus.running, ProfileTurnStatus.attention}.contains(chat.status),
      steerAvailable: _composerActions(chat)[ComposerAction.steer] == null,
      queueAvailable: _composerActions(chat)[ComposerAction.queue] == null,
    );
    if (delivery != CarDelivery.end) {
      _conversationAwaitingReply = true;
      await _performComposerAction(chat,
          delivery == CarDelivery.steer ? ComposerAction.steer : ComposerAction.queue,
          conversation: true);
      return;
    }
  }
  ```

  `_performComposerAction` already clears the draft after an accepted steer and shows "Hermes rejected the
  steering message." on `false` (wt `:2323-2333`). ANNAHME: under the car route that snackbar is not
  visible. The rejection is rare: `rejected` only comes when the turn already ended (barge-in spec §2). The
  car screen then shows `idle`, and the user can tap again. When barge-in lands later, its
  `decideDelivery` replaces this block. The barge-in card must delete `carDeliveryFor` and its call
  (named in plan Task 5).

### 6.4 Entry, field and dispose

- **Menu item:** one `PopupMenuItem(value: 'car', child: Text('Car mode'))` (`StudioPopupMenuItem` after
  the upstream merge).
- **`onSelected`:** one branch `else if (action == 'car') unawaited(_car.enter(context));`.
- **Field:** `late final _car = CarModeSession(device: _voiceDevice, bridge: CarModeBridge(...))`, about 12
  lines of closures over `_dictate`, `_carSend`, `_voiceInput`, `_voiceOutput`, `controller`,
  `_cancelVoice`.
- **`dispose`:** `_car.dispose();`.

## 7. Privacy and logging

Log lines use the prefix `WingCar` via `debugPrint` and contain only events, phases, actions and durations.
They **never** contain spoken text, transcript, reply text, chat title or session id.

```
WingCar enter route=<vad|local|hermes>
WingCar tap phase=<idle|listening|…> action=<talk|sendNow|retry|ignore|debounced>
WingCar stopSpeech ms=<n>          (tap in speaking: time from tap to VoiceOutputController.stop() returning)
WingCar deliver kind=<send|steer|queue|end>
WingCar exit reason=<hold|chatChanged|disposed>
```

`stopSpeech ms` is the acceptance number for "tap stops read-aloud ≤ 0.5 s". It measures to the end of the
`stopPlayback` call. ANNAHME: audible silence follows within ~50 ms of that (`TextToSpeech.stop()` /
`MediaPlayer.stop()`). The device test checks it by ear (acceptance step 5).

## 8. Upstream files touched

| File | Lines (estimate) | What |
|---|---|---|
| `lib/core/screens/profile_workspace_screen.dart` | ~30 changed or added (import 1, field 12, dispose 1, menu 3, `onSelected` 1, focus 1, `_loopWanted` 1 + 4 replacements, `_carSend` 3); + ~14 for §6.3 only if barge-in has not landed | thin hooks §6 |
| `.github/workflows/voice-review.yml` (fork-owned, VAD chain) | 1 | add `test/car_mode/car_mode_screen_test.dart` to the render list |

Not touched: `voice_input_controller.dart`, `voice_output_controller.dart`, `android_voice.dart`,
`VoiceChannel.kt`, `VoicePlayback.kt`, `VadCapture.kt`, `voice_preferences.dart`, `pubspec.yaml`, Kotlin.
No overlap with the TTS-language plan, which touches `android_voice.dart` `speak`, `VoicePlayback.kt` and
`VoiceChannel.kt`.

The goal "only an entry point of a few lines" is not reachable. The loop, the focus rule and the auto-send
condition are private members of the screen. ~30 lines of hooks at five named spots is the minimum
without moving the loop out (approach C).

## 9. Dependencies and base

- **Base:** `voice-offline` **after** the VAD merge (t_145c5731, brings `wt/t_24ef9c3d`) **and** the
  upstream merge chain (t_f8523002 done). Strategy rule 3: "never merge into a running voice chain".
- **Needs from the VAD chain:**
  - `VoiceSwitchHolders.screenOn`;
  - `stopHandsFree()`;
  - the media-key dispatcher. It is unchanged, so steering-wheel keys keep working in car mode.
- **Barge-in:** optional (§6.3). Car mode and barge-in may land in either order. The plan's "Basis / Rebase"
  section checks which is there.
- **TTS language plan:** no shared file.

## 10. Testing

- **Pure** (`test/car_mode/car_mode_state_test.dart`):
  - phase priority table;
  - tap table per phase;
  - debounce with a fake clock;
  - `carDeliveryFor` table.
- **Session** (`test/car_mode/car_mode_session_test.dart`) with a fake bridge and `VoiceDeviceFixture`:
  - screen-on holder on enter and off on exit/dispose (`keepScreenOnCalls`);
  - auto-exit on chat change;
  - log lines contain no text (feed a snapshot whose error text is a sentinel, then assert no log line
    contains it).
- **Screen** (`test/car_mode/car_mode_screen_test.dart`):
  - every phase renders its label and icon;
  - tap anywhere on the button calls the session;
  - hold-to-exit needs ≥ 1 s;
  - Back shows the hint and does not pop;
  - 320 dp at 200 % text and 411×960 / 960×411, light and dark, with no overflow;
  - `VOICE_REVIEW` captures.
- **Workspace** (`test/voice_workspace_test.dart`, new group "car mode"):
  - three tap-only rounds with conversation mode **off** in the preferences;
  - tap during read-aloud → `stopPlayback` before `startVad`;
  - tap during recording on the `local` route → sent;
  - focus stays (media keys stay on) under the car route;
  - exit cancels recording and keeps the draft;
  - tap during thinking → steer.
- **Device:** plan Task 9, run by a separate worker card via `hadb`.

## 11. Later (not in this card)

Landscape lock, own cue sounds, a car-mode shortcut (Android launcher shortcut / Quick Settings tile),
auto-enter when a car Bluetooth or Android Auto connects (Birk does not pair the phone), and a voice command
"exit car mode".

## Open decisions for Birk

All three are switchable in the mockup (panel "Entscheidungen").

1. **D1: Tap while Hermes is working (thinking).**
   - (A) The tap opens the microphone. What Birk says is **steered** into the running turn (fallback:
     queued). This matches the composer's default running action and the barge-in plan.
   - (B) The tap **stops** the running turn (`session.interrupt`) and opens the microphone for a new message.
   - (C) The tap does nothing (vibration only); he waits for the answer.

   **Recommendation: A.** Nothing is lost, and it matches how he steers today. B throws away work with one
   accidental tap. C makes the button feel dead.
   **ANNAHME (Birk-Gate):** A.
2. **D2: How to leave car mode.**
   - (A) Hold the small "Exit" pill for 1 s (ring fills). Back is blocked and shows a hint.
   - (B) Double-tap the "Exit" pill. Back is blocked.
   - (C) A normal "Exit" button, and Back leaves.

   **Recommendation: A.** It is findable (always visible, labelled) and cannot happen by a bump or a
   brushing hand. B can be triggered by two bumps; C by one.
   **ANNAHME (Birk-Gate):** A.
3. **D3: Look of the button.**
   - (A) **Colour field:** the whole screen below a thin top strip is the button. The state colour fills it.
   - (B) **Circle:** a large round button (≈ 85 % of the width) on a dark background, with the state label
     below it.

   **Recommendation: A.** It is the largest possible target and works the same in landscape. Night glare
   is controlled by the dark tinted fill. B leaves corners that do nothing, which is bad when hitting
   blind.
   **ANNAHME (Birk-Gate):** A.

## Kurzfassung (für Birk)

Der Automodus ist ein eigener Vollbild-Screen über dem offenen Chat. Er wird über das ⋮-Menü des Chats
geöffnet. Fast der ganze Bildschirm ist eine Taste:

- **Tippen im Leerlauf:** startet die Runde.
- **Tippen während der Aufnahme:** schickt das Gesagte sofort ab.
- **Tippen beim Vorlesen:** stoppt das Vorlesen und öffnet das Mikro.
- **Tippen, während Hermes arbeitet:** öffnet das Mikro, und das Gesagte geht als Steuerung in die laufende
  Runde (D1).

Weitere Punkte:

- Der Bildschirm bleibt an, solange der Automodus offen ist.
- Gesprochener Text und Antworttext erscheinen nicht auf dem Display und nicht im Log.
- Verlassen: „Exit“ oben links 1 s halten (D2). Das Aussehen ist eine Farbfläche (D3).
- Der Gesprächsmodus wird im Automodus automatisch genutzt; die gespeicherte Einstellung bleibt unverändert.
- Upstream hat nichts Vergleichbares.
- Im Upstream-Screen landen etwa 30 Zeilen Einhängepunkte; alles andere liegt in `lib/car_mode/`.

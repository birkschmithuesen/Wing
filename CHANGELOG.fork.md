# Wing Voice — fork changelog

This file tracks what the fork `birkschmithuesen/Wing` (branch `voice-offline`,
app id `com.tarkilhk.wing.voice`) changes on top of upstream
[`tarkilhk/Wing`](https://github.com/tarkilhk/Wing). It does not replace
upstream's own `CHANGELOG.md`; that file stays upstream's.

Upstream base: commit `151ee281` (2026-09-28). Entries below cover every merge
commit between that base and `origin/voice-offline` to date, newest first.

See [AGENTS.md](AGENTS.md#fork-changelog) for the rule that keeps this file and
the README feature list current for every future change.

## 2026-11-14

### Chats no longer offers a profile the gateway permanently refused
- **What:** A profile whose connect/`session.list`/`subagent.roster` answer is a FINAL gateway
  refusal (profile mismatch or unavailable) is remembered as not served for the life of the
  connection: Wing stops polling it for detached work and canonical-chat discovery (parent card),
  and the Chats profile picker row and the header's chat profile filter now show it disabled with
  a "not served by this gateway" hint instead of a tappable choice. A served profile is
  unaffected; the status clears only on an explicit refresh or a new gateway connection.
- **Why:** The parent card stopped a retry storm against a permanently-refusing profile on the
  backend only; this card closes its acceptance criterion 1 by surfacing the same status in the
  UI, so the user is not invited to keep retapping a profile Wing already knows the gateway will
  refuse.
- **Fork edits of upstream files:** `lib/core/widgets/profile_selector.dart`,
  `lib/core/widgets/chat_profile_bar.dart`, `lib/core/models/browser_actions.dart`,
  `lib/core/services/chat_browser_data.dart`, `lib/core/screens/profile_workspace_browser.dart`.
- **Merge:** pending (branch `wt/t_0076f7aa`, not yet merged to `voice-offline`) · **Card:**
  t_0076f7aa (parent t_8cdd1adb)

## 2026-11-12 (upstream merge)

### Upstream merge: tarkilhk/Wing e8a4089c (806 commits) into the fork
- **What:** Merged tarkilhk/Wing upstream/main e8a4089c (806 commits: gateway/chat rewrite, outbox, typed
  preferences, live voice call) into the fork. Fork voice, car mode and offline features re-hung on upstream's
  new seams (spec docs/superpowers/specs/2026-11-12-wing-upstream-merge-design.md).
- **Why:** Stay upstream-compatible (fork strategy).
- **User-visible:** Parakeet is chosen as "Recognition engine" under Local voice input (stored value migrated
  automatically); the settings card still hides "Recognition language" for the Parakeet engine; empty Parakeet
  recognition shows upstream's "No speech detected" notice; upstream's live call button appears (needs the Wing
  Hermes plugin) and a running conversation loop is paused while an upstream live call is active; the
  model-removal dialog uses icon buttons with tooltips (upstream dialog rules); unsent drafts/queues from before
  the update are not carried over (upstream format change, one-time step before install). Inline chat images now
  use upstream's image box (tap opens the preview).
- **Dropped for upstream:** own queue drain loop and history-text queue-head check (upstream outbox), composer
  toolbar mic (upstream mic in the text field).
- **Fork edits of upstream files/tools:** `lib/core/widgets/voice_preferences_card.dart`
  (VoiceOfflineEngineBuilder), `lib/core/services/profile_workspace_controller.dart` (NetworkGate +
  TransientSend mark/hold hooks), `tools/architecture` roles.json/roots.json registrations, and the car_mode
  cycle break (CarModeSession screenBuilder).
- **Final review fix:** the automatic queue resume spends its hold only for a `started`/`queued` replay receipt and
  marks the chat running only for `started` (a `terminal` receipt no longer leaves the chat running); the resume
  awaits an in-flight replay first.
- **Ledger L26 (Birk 2026-11-13):** Cancel on the recording screen discards only the current recording; in
  conversation mode the loop stays active and the microphone reopens for the next turn (upstream's chrome ended
  the loop). Regression test R9 (`test/regression/daily_flow_cancel_keeps_loop_test.dart`).
- **Upstream refresh:** merged upstream/main 7a9992c4 (15 commits after e8a4089c) in `79ed5cb1`; only conflict
  was the census list `tools/architecture/roots.json` (union).
- **Merge:** `116d82f4` · **Card:** t_d1d49ff1

## 2026-11-12

### Optional "ready" beep when conversation listening starts
- **What:** A new voice setting, "Signalton, wenn Zuhören beginnt" (default **on**, including for
  existing installs), plays a short beep when a conversation listen round opens the microphone for
  the user's turn after read-aloud has fully ended. It never plays for a round this listener
  restarts for itself while read-aloud is playing or might follow next: the barge-in round that
  stays open across playback (`keepPlayback`), or the round reopened right after an utterance was
  transcribed, before the reply exists. `TurnListener.open()` is the only call site eligible for
  the cue, and only when it is not opening for playback.
- **Why:** Birk, t_4f90f54c, 2026-11-12: wants an audible cue for exactly when the mic opens for his
  turn, without a beep every time the round silently restarts or barges into a reply.
  Reason: the default is ON per Birk's explicit instruction (card t_4f90f54c, 2026-11-12), a
  deliberate behaviour change for existing installs too, since this fork had no such cue before.
- **Merge:** [t_2c3aeb29] · **Card:** t_4f90f54c

### Internal: fork code moved out of upstream files (no behaviour change)
- **What:** Fork logic that lived inside upstream-owned files moved into fork-owned files
  (`lib/voice_offline/`, `lib/fork/`, `lib/car_mode/`, `voiceoffline/VoiceOfflineHandler.kt`,
  `android/app/voice-offline.gradle`, own test files); upstream files keep thin hooks. Lines in upstream
  files: +4351/-157 (38 files) -> +753/-175 (30 files); probe-merge conflicts against `upstream/main`
  e8a4089c: 27 files / 91 blocks -> 22 files / 94 blocks (blocks did not drop: the remaining hooks sit in
  heavily edited upstream code, and test-file hooks count too). Kept open: `profile_workspace_screen.dart`
  still +179/-55 (spec target about +60/-10).
- **Why:** Birk 2026-11-11: own code in own files keeps every later upstream merge small; the upstream
  merge card t_d1d49ff1 runs after this one.
- **Merge:** [t_3b4d8603] · **Card:** t_09ff7726 (parent t_ba3601fa)

### An unsolicited reply no longer breaks conversation mode or cuts the recording
- **What:** A reply that arrives while the conversation loop is not awaiting one (e.g. a background job's own
  turn finishing) no longer ends Conversation mode. While the user is recording or a barge-in listen round is
  open, the reply is queued instead of being spoken over the open mic or silently dropped; it plays once the
  mic closes and, if a regular reply is also queued, after that one. While idle it speaks normally and the
  loop still reopens the mic afterwards, exactly as after any other reply. A solicited reply (the loop's own
  turn) is unaffected.
- **Why:** Birk, t_0179b15f, 2026-11-12: `_speakCompletedReply` treated "no awaited reply" as reason enough to
  unconditionally null the conversation key, so any reply the loop had not itself requested tore the loop down
  — or, while the mic was open for it, got silently dropped instead of queued.
- **Merge:** `57ebb941` · **Card:** t_0179b15f (review t_3d97be71 APPROVED, merge t_ac33d45c)

## 2026-11-11

### BackgroundVoiceService now releases its wakelock when the conversation loop ends
- **What:** `BackgroundVoiceService` stops itself and releases its `PARTIAL_WAKE_LOCK` on every
  path that ends the background conversation loop (stop command from the notification, silence
  or a recognizer error ending the Dart hold, a phone call starting, the notification being
  dismissed, the hosting activity closing, a failed start) instead of only on some of them. A new
  10-minute safety idle timeout force-stops the hold if no `listening()` round activity happens
  for that long, so a hold can no longer dangle for hours even if some other end-of-loop signal
  never arrives. The "first reason wins" stop bookkeeping and the idle-timeout deadline math were
  pulled into plain `StopReason`/`HoldIdleTimer` Kotlin classes with JUnit tests (no Android
  framework dependency); the Service itself still needs instrumentation to verify, since
  `PowerManager`/`Service` lifecycle calls are not unit-testable without it, and this repo's CI
  (`pr-quality.yml`) only runs `flutter test`, not a Gradle/Kotlin test task.
- **Why:** Birk's phone, 2026-11-11: last `rec stop` 20:42:49, wakelock `$packageName:voice-conversation`
  acquired ~20:37 and still held at 23:26 (2h49m); `batterystats` since charge showed Wing as the
  top consumer (435 mAh) with `wakelock:fgs` held 3h05m and ~100 mAh/h screen-off drain. Fixed
  manually on the day by `am force-stop`; this card makes the service self-terminate instead.
- **Merge:** `852642d5` · **Card:** t_8f6a3d26 (review t_fbb61043 APPROVED, merge t_26c3971a)

### Read-aloud no longer speaks MEDIA reference lines
- **What:** Voice read-aloud (`spokenReplyText`) now strips `MEDIA:/path` reference lines — quoted and
  backticked variants included — before building the spoken text, reusing the same `mediaReferencePattern`
  the chat display already parses. The image/file card or thumbnail still renders; only the path is no
  longer read aloud. A sentence that merely mentions the word "media" is unaffected.
- **Why:** Wing's voice/conversation mode read the full reply text including `MEDIA:/home/.../file.png`
  lines verbatim, which is noise for a listener who only hears the card's presence, not its path.
- **Merge:** `1b7d5295` · **Card:** t_256dcf56

## 2026-11-08

### Car kit stays on the voice channel for the whole conversation
- **What:** A connected car hands-free kit (not a headphone) now keeps its Bluetooth voice channel (SCO) open
  for the entire conversation — dictation, listening-in (Mithören) and read-aloud barge-in (Reinreden) — instead
  of opening and closing it per round. Headphones keep the previous per-round behaviour unchanged. A round whose
  SCO link is not ready within ~1.5 s falls back to the phone mic for that round only.
- **Why:** Birk, in the car, 2026-10-19 ~18:00, after a successful test: the car kit's mic is audibly better
  than the phone's, but it dropped back to the phone mic for listening and read-aloud after every dictation
  round closed the link; keeping it open for the whole conversation is worth the trade-off that read-aloud then
  also plays in telephone quality instead of A2DP.
- **Merge:** pending (this card, t_7a553554) · **Card:** t_a19f7e1c (fix t_714bfc82, review t_ca18c5b2 APPROVED)
- **Docs:** [VAD_INPUT.md — Car-kit SCO hold](docs/VAD_INPUT.md#car-kit-sco-hold-conversation-wide-birk-decision-2026-10-19)

## 2026-10-30

### Chat images now show inline with a tap-to-zoom thumbnail
- **What:** An image deliverable (`MEDIA:` reference to a `.png`/`.jpg`/`.jpeg`/`.gif`/`.webp`/`.bmp` file)
  now renders as an inline thumbnail inside the chat message — full message width, aspect ratio kept, height
  capped at about 60% of the screen — instead of only a Download/Open-preview file card. Tapping the thumbnail
  opens the existing zoom preview. The Download/Open-preview row stays underneath the thumbnail. Bytes are
  fetched through the same authenticated remote-file path the card's own actions already use, and cached in
  memory by path so that scrolling the chat does not refetch an already-shown image. The file card is still
  shown while the image is loading or if the fetch fails, and several `MEDIA:` images in one message stack as
  separate thumbnails. SVG deliverables keep the file card unchanged — the app has no SVG renderer.
- **Why:** Birk 2026-10-30, Robo-reported MEDIA images render as a file card instead of an inline thumbnail in
  Wing conversational mode.
- **Merge:** pending (branch `wt/t_3dcd191e`, not yet merged to `voice-offline`) · **Card:** t_3dcd191e
- Superseded by upstream ChatInlineImage in the upstream merge (t_d1d49ff1).

## 2026-10-20

### Barge-in into read-aloud also opens for Bluetooth headphones
- **What:** Voice barge-in into read-aloud (`voice.barge_in_playback`) now also opens on Bluetooth
  headphones (`classifyRoute` reason `bluetoothHeadphones`), not only wired headphones. Speaker,
  car (without the car-mode override), `bluetoothOther` and `bluetoothClassUnknown` stay locked
  out.
- **Why:** Birk uses a Sony WH-1000XM4 over Bluetooth and found the barge-in gate stayed closed
  even though the route was already recognised as headphones; owner decision 2026-10-20 lifted
  the Bluetooth lock without waiting for an echo probe (t_fabcb273 closed as "not needed").
- **Commit:** `ff20a7b0` (pending merge) · **Card:** t_aad98b8c
- **Docs:** [VOICE_BARGE_IN.md — Barge-in during read-aloud](docs/VOICE_BARGE_IN.md#what-it-does)

## 2026-10-19

### Auto mode shows a "Listening — just talk" hint
- **What:** Auto mode (car mode) shows a "Listening — just talk" hint while recording.
- **Why:** Clarifies that the user can just start speaking once recording has started, without another tap.
- **Merge:** `f80f3cd4` · **Card:** t_9714a628

### Microphone source is manually selectable (Automatic/Phone/Bluetooth/Wired)
- **What:** Added a manual microphone-source setting (Automatic / Phone / Bluetooth / Wired) alongside the existing automatic headset-preferred rule.
- **Why:** The automatic rule did not fit every situation; some users want to force a specific input source.
- **Merge:** `d80f694d` · **Card:** t_7fa7d867

### Bluetooth headset microphone for vad rounds, headphone-detection fix
- **What:** Explicit on-device ("vad") recording rounds now use a connected Bluetooth headset's or car hands-free kit's microphone (HFP, recognised device classes) via `setCommunicationDevice` when one is present; also fixes a headphone-detection bug.
- **Why:** Lets the user dictate through a car's hands-free mic or a Bluetooth headset instead of only the phone's built-in mic.
- **Merge:** `1a3eda76` · **Card:** t_f4447207 (review t_be5e4ace APPROVED)
- **Docs:** [VAD_INPUT.md — Microphone route](docs/VAD_INPUT.md#microphone-route)

## 2026-10-17

### Auto mode starts without Conversation mode by default
- **What:** Auto mode (car mode) now always starts with Conversation mode off; a small switch turns it on explicitly.
- **Why:** Starting a continuous listening loop by default surprised users who only wanted single-shot talk-and-send.
- **Merge:** `5b5adae1` · **Card:** t_be848f7d

### Airplane mode no longer loses an offline message
- **What:** Fixed offline/airplane-mode handling so the connection status no longer gets stuck on "Connected", and a message recorded while offline is kept and sent once the connection returns instead of being lost.
- **Why:** A status that lies about connectivity, and a silently dropped message, both discard the user's spoken input.
- **Merge:** `cf72b3e8` · **Card:** t_dd058826

### Barge-in into read-aloud stops playback (part b, gated on echo measurement)
- **What:** Speaking while Wing reads a reply aloud now stops the read-aloud, behind the "Interrupt read-aloud by speaking" setting (off by default), restricted to wired headphones after a passing echo measurement (S2: `run50=0`, `p99<0.5`).
- **Why:** Lets the user talk over a reply they have heard enough of, without Wing's own voice triggering a false interruption.
- **Merge:** `477c639e` · **Card:** t_ac14c877
- **Docs:** [VOICE_BARGE_IN.md](docs/VOICE_BARGE_IN.md)

## 2026-10-16

### Headphone detection for barge-in into read-aloud (part b, groundwork)
- **What:** Added headphone-route detection (`classifyRoute` / `HeadphoneRouteChannel`) distinguishing wired, Bluetooth and speaker/car output.
- **Why:** Barge-in into read-aloud must trigger only with headphones, never through the open phone speaker (echo); detecting the route correctly is a prerequisite.
- **Merge:** `0d9cd8fb` · **Card:** t_c9c21f6d
- **Docs:** [VOICE_BARGE_IN.md — Headphone detection](docs/VOICE_BARGE_IN.md#headphone-detection)

## 2026-10-15

### Pause-until-sentence-end selectable up to 5 s
- **What:** Added 4 s and 5 s to the selectable "pause ends a message" durations.
- **Why:** Some users pause longer mid-sentence than the previously available choices allowed before Wing cut the recording.
- **Merge:** `e00ee3c9` · **Card:** t_1ef89dd4

### Conversation mode with the screen off
- **What:** On the on-device ("vad") input route, Conversation mode can keep running with the screen off or the phone pocketed, backed by a microphone foreground service and a "Conversation mode" notification with Stop.
- **Why:** Lets the user keep talking to Wing hands-free without having to keep the screen on.
- **Merge:** `cfc6a825` · **Card:** t_7200d190
- **Docs:** [VOICE.md](docs/VOICE.md)

### Read-aloud queue: a new reply waits its turn
- **What:** A new assistant reply arriving while a previous one is still being read aloud is now queued and read after the current one finishes, instead of interrupting it.
- **Why:** Avoids cutting off read-aloud mid-sentence just because a new reply started streaming.
- **Merge:** `28c67aa6` · **Card:** t_98343b76

### TTS detects German/English per sentence
- **What:** Read-aloud now detects German vs. English per sentence (offline function-word counting) and switches the Android TTS voice/language per segment, with a short pause between paragraphs.
- **Why:** Wing's replies mix German and English sentences; reading everything in one fixed language misreads the other.
- **Merge:** `f38b00a7` · **Card:** t_de1636ce
- **Docs:** [VOICE_LANGUAGE.md](docs/VOICE_LANGUAGE.md)

### Barge-in part (a): listening while Hermes works
- **What:** On the on-device ("vad") input route, with Conversation mode and "Listen while Hermes works" on, the microphone stays open for the whole turn; a `TurnListener` runs continuous VAD listen rounds and a `BargeInCoordinator` steers each utterance into the running turn, queues it, or sends it as a new prompt.
- **Why:** Lets the user keep talking to or steering a running reply instead of waiting for it to finish before saying anything else.
- **Merge:** `fff2ed93` · **Card:** t_658ec55c (review t_a3f1f1d6 APPROVED)
- **Docs:** [VOICE_BARGE_IN.md](docs/VOICE_BARGE_IN.md)

## 2026-10-14

### Wing client source and Conversation mode default
- **What:** Set the app's own client source identifier and the default state of Conversation mode.
- **Why:** Groundwork needed before building the barge-in / listen-while-working features on top of Conversation mode.
- **Merge:** `161ea958` · **Card:** t_94f1f373 (branch t_1c5bc62e, review t_e6118441 APPROVED)

### Internal merge: fold in-progress car-mode docs before the feature merge
- **What:** Internal integration merge resolving a conflict in the voice-background design/plan docs between two in-progress branches ahead of the car-mode merge.
- **Why:** Kept the car-mode branch's design docs consistent before the feature landed on `voice-offline`.
- **Merge:** `8b408656` · **Card:** t_f0c1d125 / t_6382a14f (internal to the car-mode chain, no standalone card)

### Auto mode: full-screen talk button (car mode)
- **What:** Added car mode: opening a chat's "Car mode" turns the whole screen into one big talk button, with state-dependent tap behaviour (start/stop recording, steer a running reply, queue while offline) and large connection/activity indicators.
- **Why:** A single, large, reachable button is safer to operate while driving than the normal composer.
- **Merge:** `beba7c9e` · **Card:** t_b22000e9 (review t_654826fe APPROVED)
- **Docs:** [CAR_MODE.md](docs/CAR_MODE.md)

### Internal merge: bring the vad input route onto the car-mode branch
- **What:** Internal integration merge folding the on-device "vad" voice input route (merge `b4f5e4a0`, card t_145c5731) into the car-mode development branch before that branch's own merge into `voice-offline`.
- **Why:** Car mode needed the vad route available on its branch before it could build the full-screen talk button on top of it.
- **Merge:** `c9d9811b` · **Card:** t_145c5731 / t_c0789ae5 (internal to the car-mode chain, no standalone card)

### Bring in the on-device "vad" voice input route
- **What:** Merged in the on-device "vad" voice input route: own audio capture with Silero VAD end-of-utterance detection, media-key fallback, Bluetooth-mic source selection, listening/got-it cues, and on-device debug WAV recordings.
- **Why:** Enables fully offline speech input instead of depending on Android's or Hermes' online recognizers.
- **Merge:** `b4f5e4a0` · **Card:** t_145c5731
- **Docs:** [VAD_INPUT.md](docs/VAD_INPUT.md), [VOICE.md](docs/VOICE.md)

## 2026-10-13

### Raise the dictation cap from 120 s to 600 s
- **What:** Raised the maximum dictation/recording length from 120 seconds to 600 seconds (10 minutes).
- **Why:** 120 seconds was too short for longer dictations (brainstorming dictations run 3-6 minutes).
- **Merge:** `6fc2691f` · **Card:** t_d259c976 (implementation t_d3a672fe)

### Scale the stop() transcription deadline with recording duration
- **What:** `VoiceCapture`'s deadline after `stopListening()` now scales with recording length (`5 s + 0.5 × duration`, capped at 90 s) instead of a fixed 5000 ms timeout.
- **Why:** The fixed timeout cut off long on-device transcriptions (a ~53 s session was cut off exactly 5.054 s after capture end).
- **Merge:** `7bf6c354` · **Card:** t_99f481cb

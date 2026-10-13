# Wing Voice: barge-in and steering by voice — design

Card: t_7e81e040 (board wing). Date: 2026-10-14. Status: design, waiting for Birk's go on the
open decisions below (work continues with the marked assumptions).

## 1. The wish, and what it really asks for

Birk (paraphrased): while Hermes answers — text streams in, or the reply is read aloud — he simply talks.
Read-aloud stops, the microphone records, and what he said reaches the running turn as a **steering
message** without any tap.

His workaround today: he pauses, the sentence is sent after the pause, the turn starts. Then he taps the
mic and keeps talking, and taps the composer's primary button (default action **Steer** while the chat
is busy). Traced in code (`wt/t_24ef9c3d` @ `4a1a86c6`):

- The mic button stays enabled while a turn runs. `_dictate` writes the transcript into the composer
  (`lib/core/screens/profile_workspace_screen.dart:428-433`).
- `_sendConversationTurn` refuses to send while `chat.busy` and **ends the conversation**
  (`profile_workspace_screen.dart:300-312`, condition at :306).
- The composer's primary button while busy defaults to Steer (`lib/core/models/composer_action.dart:11-17`,
  screen :2276-2285). It calls `controller.steer` (screen :2323-2333). On `false` it shows the snackbar
  "Hermes rejected the steering message."

So the workaround costs **two taps** (mic, Steer) and drops the hands-free loop.

**Architect's hypothesis — confirmed, with one refinement.** Read-aloud starts only after the turn has
finished: `_speakCompletedReply` listens to `completedReplies` (screen :238-274, subscription :575). That
stream is fed only in `_settleTurn` (`lib/core/services/profile_workspace_controller.dart:6122-6125`).
The mic is closed during the whole turn and reopens only after read-aloud (screen :270-272). The wish
therefore splits into two features:

| | (a) **Listen while Hermes works** | (b) **Barge-in during read-aloud** |
|---|---|---|
| When | From the conversation's auto-send until the turn ends (tools, interim text, final text streaming) | While Wing reads a finished reply aloud |
| Utterance becomes | `session.steer` into the running turn. Fallback when the turn has ended: a normal prompt | Usually a **normal next prompt** (turn already finished). It becomes a steer only if a follow-up turn is running (see 3.3) |
| Echo problem | **None.** Nothing plays (cue tones only; they are outside the recording, see 5.2) | **Yes.** The mic hears Wing's own TTS |
| Delivers Birk's workaround case | **Yes.** This is exactly "pause → sent → keep talking → steer", without the taps | No. It is the "stop reading, I want to say something" case |

**Refinement (verified in Hermes upstream):** a steer that arrives while the model is writing its
**final** answer is not lost. `AIAgent` has no tool batch left to inject into. The finalizer hands the
text back as `pending_steer` (`agent/turn_finalizer.py:745-749`), and the gateway enqueues it and starts
a **follow-up turn** right after `message.complete` (`tui_gateway/prompt_turn.py:438-449`). So (a) is
useful for the *whole* running phase, including text streaming. The follow-up turn's start reaches Wing
as `message.start` with an idle chat. Wing turns that into `status = running`
(`profile_workspace_controller.dart:5827-5841`).

**Is option 3A (sentence-wise read-aloud while the turn still streams) needed?** No, for neither part.
(a) works without 3A, because steering happens while nothing is read. (b) works without 3A too and
produces a new prompt. 3A only shifts (b) into the running turn (then the utterance is a steer). It
makes the echo gate matter more, because playback and an open mic overlap for longer. **Recommended
order:** (a) first, because it delivers the workaround case and needs no echo handling. In parallel, the
echo measurement (early, cheap). Then (b), only if the measurement passes. 3A and the TTS-language plan
stay separate cards and come after (a) (see §8).

## 2. Verified stock API (Hermes)

AGENTS.md: target is **latest upstream Hermes, unmodified**.

- Upstream `NousResearch/hermes-agent` `main` = **`e06df9c2eae6901f4c88f464e0ae6e753c0428b8`**. It was
  read on 2026-10-14 via the GitHub contents API. `raw.githubusercontent.com` timed out from the vServer.
- The local reference checkout `/home/birk/.hermes/hermes-agent` (branch `birk-local`, `69723ab7`) has the
  **same steer path**. `diff` of `tui_gateway/methods_session_interrupt.py` shows differences only in
  `session.interrupt` (compute-host recovery). `_correction_method`, `session.steer` and
  `session.redirect` are identical. `agent/turn_finalizer.py`, `tui_gateway/prompt_turn.py` and
  `agent/interrupt_control.py` were fetched from upstream and grep-compared for the steer drain.

Line numbers below are **upstream `e06df9c2`** unless marked "local".

| Call / event | Behaviour | Evidence |
|---|---|---|
| `session.steer {session_id, text}` | Empty text → error **4002** | `methods_session_interrupt.py:138-139` (local :106-107) |
| | Compression in flight → `_enqueue_prompt`, status **`queued`**. It drains as a *normal prompt* after compression | :156-159 (local :124-127) |
| | Agent lacks `steer` → **4010** | local :128-129 |
| | Session not `running` → status **`rejected`** ("makes the client queue it as a normal next prompt") | :162-165 (local :130-133) |
| | Otherwise `agent.steer(text)` → **`queued`**, or `rejected` if the agent returns False. Raised → **5000** | `_apply_correction` :114-130 (local :82-98) |
| `AIAgent.steer` | Appends to `_pending_steer` (joined with `\n`). It is injected after the next tool result, or before the next API call | `agent/interrupt_control.py:267-278`; drain `agent/agent_runtime_helpers.py:3758-3795`, `agent/turn_iteration_prep.py:175-181` (local; upstream interrupt_control identical by grep) |
| Steer during a long tool | Waits until that tool returns ("Never kill a tool to deliver guidance") | upstream `interrupt_control.py:303` |
| Steer during final answer | Returned as `pending_steer` → enqueued → follow-up turn | `turn_finalizer.py:745-749`, `prompt_turn.py:438-449` |
| Turn end | `message.complete` :1193; `session["running"] = False` only later in `finally` :1210 | `prompt_turn.py` |
| `session.redirect` | Exists; cancels the current model request. **Not used** — Birk asked for steering, and steer does not interrupt | `methods_session_interrupt.py:174` |
| `session.interrupt` | Server-side TTS stop + turn interrupt; does **not** touch Wing's own TTS | local :41-79 |

No event announces an accepted steer. Wing records it itself as a `display_kind: 'steer'` user row
(`profile_workspace_controller.dart:4956-4962`). The gateway answers a compression-queued text with the
same `queued`, so Wing shows a steer row for it too. The server then runs it as the next prompt. This is
a known, accepted inaccuracy: the text still reaches the agent.

**Race:** between `message.complete` (:1193) and `running = False` (:1210), a steer would still be
accepted, after the finalizer already drained. Wing never sends one there: `steer()` returns `false`
without calling the server unless `chat.status` is `running`/`attention`
(`profile_workspace_controller.dart:4934-4940`), and Wing settles the chat on `message.complete`.
ANNAHME: network reordering cannot deliver Wing's steer *after* Wing processed `message.complete` but
*before* the server set `running = False`. Wing sends nothing after that point, so this holds by
construction.

## 3. Behaviour

### 3.1 Scope conditions

Active only when **all** hold: input route `vad`
(`lib/core/services/voice_preferences.dart:9`), Conversation mode on, the new setting "Listen while
Hermes works" on, the conversation's chat on screen (`_conversation == chat.key`).

The other routes cannot do it. `local` (Android `SpeechRecognizer`) owns the mic and has no continuous
mode. `hermes` has no end-of-utterance detection.

### 3.2 (a) Listen while Hermes works

1. The conversation auto-sends a prompt (`_sendConversationTurn`). Instead of leaving the mic closed, Wing
   opens a **listen round** for the same chat. It is a VAD round with its own policy (§4): no start
   beep, the "got it" tone on each utterance end, no no-speech timeout. The round ends at max duration
   and restarts silently.
2. Birk speaks; the round ends after the normal pause (1.8 s default). Parakeet transcribes it on the
   phone.
3. **Delivery** (pure function, §4.3), decided at the moment the transcript is ready:
   - transcript not sendable (empty, no letters, only fillers) → **drop**, log, keep listening;
   - chat `running`/`attention` → `controller.steer(chat, text, preserveComposer: true)`;
     - `true` → the steer row appears in the chat; keep listening;
     - `false` (gateway `rejected`, or the status changed meanwhile) → re-decide with the new status (next
       two lines);
   - chat busy but not steerable (`submitting`, `reconnecting`) → `controller.queuePrompt(chat, text)`;
   - chat idle (the turn ended while he spoke) → normal conversation send, exactly like a dictation that
     ended on its own (`_sendConversationTurn`). Wing then awaits that turn's reply.
4. Utterances are serialized: the next delivery waits until the previous `steer()` returned.
   `steer()` throws while `chat.steering` (:4941-4943).
5. The listen round closes when the turn completes and no speech is in progress. If speech is in
   progress at completion, the utterance finishes first. It then goes through step 3; the chat is idle,
   so it becomes a normal send. **ANNAHME (Birk-Gate) D3:** the finished reply is then **not** read
   aloud; it stays visible in the chat.
6. Anything that ends the conversation today also closes the listen round, with a single hook in the
   `_conversation` setter (screen :217-222). Today these are: approval, clarification or sensitive
   prompt (`_needsUserInput`, :204-207); chat switch; failed or cancelled turn (:188-199); voice error
   (:230); "Cancel recording"; "Stop speech"; manual composer action; Stop response (→
   `session.interrupt` → cancelled turn).

### 3.3 Follow-up turns caused by a steer

After a steer was accepted in this conversation turn, the turn completes and the reply is read aloud (if
D3 did not suppress it). If the chat is then **busy again** — the gateway started the `pending_steer`
follow-up turn — Wing does not end the conversation, as `_canContinueConversation` does today (:285). It
treats the follow-up as the conversation's own turn: `_conversationAwaitingReply = true`, and it opens a
listen round.

Race: the follow-up's `message.start` may arrive after read-aloud ended, when a normal dictation round
is already open. To cover it, `_sendConversationTurn` gets the same delivery rule: a hands-free
utterance on a `running` chat is **steered** instead of ending the conversation. This also removes the
workaround's second tap for any dictation that lands on a running turn.

### 3.4 (b) Barge-in during read-aloud — gated

Built behind a setting **"Interrupt read-aloud by speaking"** (default **off**). The setting appears only
if the echo measurement (§5) passed for the phone speaker. Flow:

1. `_speakCompletedReply` starts TTS and opens a listen round in **playback mode**. The capture must
   not stop playback: today `VoiceChannel.start()` calls `playback.stop()` first
   (`android/.../VoiceChannel.kt:92`), so `startVad` gets a `keepPlayback` flag.
2. While `_voiceOutput.owner != null`, a stricter **playback gate** (§4.2) must confirm speech before
   anything happens. A cough or short noise does not pass it. TTS continues, and the round's partial
   speech state is discarded (round cancelled and restarted).
3. Gate passes → `_voiceOutput.stop()` immediately (target: within 1.2 s of speech onset, §7). The same
   round keeps recording. The pre-roll (300 ms) plus the gate window means the beginning of the
   utterance is in the cut.
4. The utterance ends by pause → delivery rule (§4.3). Usually the chat is idle → normal conversation
   send. If a follow-up turn runs (3.3) → steer.
5. The interrupted reply is not resumed. It stays in the chat, and "Read aloud" on the message replays it
   (same as D3).
6. TTS ended without barge-in → the round switches to normal listening rules. This replaces today's
   `_dictate(resume: true)` re-open at :270-272: the round is already open, so there is no extra cue or
   gap.

The **media key** stays the hands-free barge-in that always works. Today, pressing Play/Pause while TTS
plays already calls `_dictate`, which stops output first (:356-369, :393). This is unchanged and is the
fallback if (b) fails its gate (D2).

### 3.5 Interaction with existing rules

| Rule | With this feature |
|---|---|
| Approvals / clarify / sensitive prompt end the conversation (:188-207) | Unchanged. The listen round closes with the conversation. The utterance in flight is cancelled, not sent: a steer during an approval is not what the user expects. |
| Media key (:356-369) | Listen round with speech in progress → `stopHandsFree` (ends the utterance now → delivery). Listen round without speech → closes the listen round for this turn. Read-aloud → unchanged (stop TTS, dictate). |
| Stop button "Stop response" | Interrupt → cancelled turn → conversation ends → listen round closed (no extra code). |
| "Stop speech" (:519-524) | Ends the conversation as today; this also closes a playback-mode round. |
| Keep-screen-on (:215-222) | Already on for the whole conversation, so no change. A screen timeout would pause the activity, and `VoiceChannel.pause()` fails the round (:123). |
| VAD no-speech timeout (8 s, `vad_endpoint.dart:25`) | **Not used** for listen rounds: a tool turn can last minutes (one measured turn 147 s, one tool 68.5 s; streaming-vorlage). Listen rounds set `noSpeechTimeout = maxDuration`, so `NoSpeech` only happens at max duration, which silently restarts the round. |
| VAD max duration (600 s, `vad_endpoint.dart:23`) | Caps one listen round. The PCM buffer is `(maxMs + 5000) * 16` samples ≈ 19 MB for 600 s (`VadCapture.kt` `Round` capacity). A restart reallocates it, so memory stays bounded. |
| Battery | Mic + Silero (one 32 ms window, `numThreads = 1`) run for the turn's duration. The screen is on anyway and dominates. **ANNAHME:** Wing's CPU during a listen round is < 10 % of one core; this is checked in Task 13 (`top`). |
| "Recording · 12s / 600s" status | A listen round shows its own short status row (§6), not the recording counter. |
| Composer running action (steer/queue/stop preference) | Not consulted. The wish is explicitly steering. |
| Hermes/local TTS output route | Barge-in (b) works for both. `stopPlayback` stops TTS and `MediaPlayer` alike (`VoicePlayback.kt:147-157`). |

## 4. Policies and numbers

### 4.1 Listen round endpointing (no playback)

The listen round reuses `VadEndpointer` unchanged (`lib/core/services/vad_endpoint.dart`) with this
config:

| Parameter | Dictation (VAD spec) | Listen round | Why |
|---|---|---|---|
| Start threshold / end threshold | 0.5 / 0.35 (constants) | same | Constants of the endpointer and its Python mirror; unchanged |
| Pause to end | user setting, 1.8 s default | same setting | Same speaking style as the prompt |
| Min speech | user setting, 250 ms default (choices 150/250/400) | **new setting, 400 ms default** (choices 250/400/600) | Nobody asked for the mic here. 400 ms (13 windows) rejects a single cough or throat-clear burst. ANNAHME: typically 200-350 ms above 0.5, to be checked in Task 14. A short "Stopp" still passes. |
| Pre-roll | user setting, 300 ms | same | |
| No-speech timeout | 8 s | = max duration | See 3.5 |
| Max duration | 600 s | same setting | Restart on reach |

Speech that passes the endpointer but gives garbage text is handled by the transcript filter (4.3), not
by a higher threshold.

### 4.2 Playback gate (only for (b))

While TTS plays, an onset counts only if a run of **≥ 16 consecutive windows (512 ms) with p ≥ 0.7**
occurs (constants `bargeGateThreshold`, `bargeGateWindows`). Start values are ANNAHMEN. They are replaced
by the measured numbers in Task 7, after the measurement in Task 6:

`bargeGateThreshold = max(0.7, ceil10(p99_echo + 0.15))` and
`bargeGateWindows = max(16, 2 × longestEchoRun(p ≥ bargeGateThreshold))`.

`ceil10` rounds up to one decimal, and the echo statistics come from the speaker scenario. If the
formula yields a threshold > 0.9 or windows > 31 (1 s), the gate is considered failed (5.3).

### 4.3 Delivery and transcript filter (pure)

`ListenDelivery decideDelivery(ListenChatState state, String transcript, {bool steerRejected = false})`.
The policy file does not import the 7000-line controller. The screen adapter maps `ProfileTurnStatus`
(`profile_workspace_controller.dart:86-95`) to `ListenChatState`: `running`/`attention` → `steerable`;
`submitting`/`reconnecting` → `busy`; `idle`/`completed`/`cancelled`/`failed` → `idle`.

- `drop` when the trimmed transcript has no letter (`\p{L}`), or all its words (lower-cased,
  punctuation stripped) are in the filler set `{äh, ähm, öh, hm, hmm, mhm, uh, um, uhm, eh}`. "ja" and
  "nein" are **not** fillers.
- `steer` for `steerable` (but `queue` when `steerRejected`);
- `queue` for `busy`;
- `send` for `idle`.

A `steer` result of `false` re-runs `decideDelivery` with the then-current status and
`steerRejected: true`. If the status is still `running` (a theoretical `rejected` from `agent.steer`
returning False), the second decision is `queue`.
A dropped utterance has already produced the "got it" tone. This is accepted and documented: a cough
that passed the endpointer gives a tone but sends nothing.

## 5. Echo: does the mic hear Wing's own TTS?

### 5.1 What the code says

- Capture uses `MediaRecorder.AudioSource.VOICE_COMMUNICATION`, falling back to `VOICE_RECOGNITION`
  (`VadCapture.kt` `openRecord`). No `AcousticEchoCanceler` or `NoiseSuppressor` is attached, and there
  is no `AudioManager.setMode` (git grep: none).
- TTS plays as `USAGE_MEDIA` / `CONTENT_TYPE_SPEECH` (`VoicePlayback.kt:24-25`), with focus
  `AUDIOFOCUS_GAIN_TRANSIENT` (:95-98).
- The platform AEC behind `VOICE_COMMUNICATION` is vendor-specific. Whether its reference signal
  includes the media stream in `MODE_NORMAL` is **not documented** for the Xperia 5 IV (XQ-CQ54).
  **ANNAHME, to be measured**; the VAD spec lists the same at its line 428.

### 5.2 Cue tones are not an echo problem for (a)

The "listening" beep plays before capture, with a 250 ms wait (`VadCapture.kt` `cue(…, wait = true)`),
and listen rounds do not use it. The "got it" tone plays in `finish` after the reader stopped. Neither
is inside a listen recording.

### 5.3 Measurement (Task 6, Hermes worker via `hadb`)

A debug-only **echo probe**. It is visible only when "Keep voice recordings" (`voice.vad_debug`) is on.
It opens a listen round with `keepPlayback = true`, `cues = false`, and plays a fixed **synthetic**
German text of about 30 s through the normal local TTS path. Nobody speaks. When TTS reports done, the
probe cancels the round and logs one line (numbers only):

```
WingBargeIn probe windows=<n> max=<p> p50=<p> p95=<p> p99=<p> run50=<w> run70=<w> source=<VOICE_COMMUNICATION|VOICE_RECOGNITION>
```

`runXX` is the longest run of consecutive windows with p ≥ 0.XX. Scenarios:

| ID | Setup | Who |
|---|---|---|
| S1 | Phone speaker, media volume 60 % and 100 %, phone on the desk, quiet room, 3 runs each | Hermes worker via `hadb` (volume via `cmd media_session volume --stream 3 --set <n>`, probe via UI tap) |
| S2 | Wired or BT headset | Birk plugs in or pairs; worker runs the probe and reads logcat |
| S3 | Car (BT A2DP to car speakers, phone mic), parked, engine idle, normal volume | Birk in the car; worker runs via `hadb` if reachable, else Birk taps the probe and the worker reads logcat afterwards |

**Pass threshold per scenario:** across all runs `run50 ≤ 6` (≤ 192 ms) **and** `p99 < 0.5`.
- **Pass:** echo stays far below the endpointer's own 8-window minimum, and below the gate.
- **Marginal:** `run50 ≤ 15` and `p99 < 0.75`. The gate constants come from the formula in 4.2; S1 is
  re-measured with the probe *plus* the gate counting `wouldTrigger=<0|1>`, and it must be `0` in all
  runs.
- **Fail:** anything else.

**Decision:** (b) may be enabled by default only if S1 **and** S3 pass or are marginal. S2 cannot fail
acoustically, so it is a control run (expect p99 ≈ background). If S3 fails → **ANNAHME (Birk-Gate)
D2:** in the car, read-aloud is interrupted only with the steering-wheel media key (exists today). The
setting stays off by default, with a hint "works with headset". Feature (a) is not affected by any
result.

## 6. UI (Studio charter)

User task: talk hands-free. Primary action: **none**. The feature removes taps. Editable controls: two
settings. Passive context: "listening" state. Temporary status: "steered" feedback.

Two arrangements were compared for the in-chat state:

- **A: status row in `_voiceActivity`** (screen :464-535), same place as "Recording…"/"Reading aloud":
  one line "Listening" with a single **"Stop listening"** text button. It is reached the same way as the
  existing voice controls, and adds no new surface.
- **B: mic icon state in the composer** (pulsing/tinted mic while listening). Less text, but the
  composer's mic is a dictation trigger. Overloading it with a second meaning ("tap = stop listening")
  breaks its contract and costs an extra explanation.

**Chosen: A.** No counter: seconds of silence are not useful information. No transcript preview: the
delivered text shows up as the steer row or the user message, which is the confirmation. The steer row
(existing `display_kind: 'steer'` rendering, `answer_versions.dart:13-40`) is the only success feedback;
no snackbar. On `false` after fallback there is no error, because the text was queued or sent. A
dropped utterance shows nothing.

**Settings** (voice preferences card, below "Conversation mode", `voice_preferences_card.dart:324`):

- `CompactSwitchListTile` **"Listen while Hermes works"**, subtitle "Speak to steer the running reply".
  It is shown only when the input route is vad and Conversation mode is on. Default: see D1.
- Choice row **"Speech needed to steer"** with 0.25 / 0.4 / 0.6 s (`StudioSelect`, like the existing
  VAD rows in `lib/core/widgets/vad_settings_section.dart:160-175`). It is shown under the switch.
- `CompactSwitchListTile` **"Interrupt read-aloud by speaking"**, default off. It is shown only after
  Task 7 enabled it (constant `bargeInPlaybackAvailable`), and only with Conversation mode on.
- Debug only (with "Keep voice recordings"): text button **"Measure speaker echo"**. The synthetic script
  never appears in the UI.

Rendered check (Task 13): normal phone size, enlarged text, light and dark: settings rows and the
listening row, with and without an active steer.

## 7. Logging and acceptance evidence

All logs use the prefix `WingBargeIn` via Dart `print` (release builds forward it to logcat as
`I/flutter`; checked on the device in Task 6). They **never contain transcript, reply or prompt text, or session
ids**: only events, durations, lengths and statuses.

```
WingBargeIn listen open mode=<turn|playback>
WingBargeIn listen restart reason=<maxDuration>
WingBargeIn utterance segmentMs=<n> textLen=<n>
WingBargeIn deliver kind=<steer|queue|send|drop> result=<queued|rejected|ok|filler|empty>
WingBargeIn barge trigger sinceOnsetMs=<n> stopMs=<n>
WingBargeIn barge reject runWindows=<n>
WingBargeIn probe …            (5.3)
WingBargeIn listen close reason=<turnEnd|conversationEnd|mediaKey|error>
```

`sinceOnsetMs` = wall-clock time of `stopPlayback` returning − the estimated audio time of the gate run's
first window (round start + `firstWindow × 32 ms`). `stopMs` = duration of the `stopPlayback` call.

Acceptance (Task 14) passes when, on the installed build:

1. **Steer:** the synthetic prompt `Führe im Terminal "sleep 25" aus und antworte dann nur mit "fertig".`
   runs. Birk says the synthetic sentence "Testsatz eins, bitte nenne zusätzlich das heutige Datum" during
   the sleep. Logcat shows `deliver kind=steer result=queued`, and the chat shows a steer row. The final
   reply contains a date.
2. **Barge-in (only if (b) enabled):** the reply to the synthetic prompt `Zähle langsam in Worten von
   eins bis vierzig.` is being read aloud. Birk says "Testsatz zwei, stopp". Logcat shows
   `barge trigger sinceOnsetMs ≤ 1200`, TTS stops, and a new prompt is sent (`deliver kind=send`).
3. **Cough:** during the same read-aloud, Birk coughs three times, about 5 s apart. There is no
   `barge trigger` line, and TTS continues to the end. During a listen round (scenario 1 setup), three
   coughs produce at most `deliver kind=drop`, never `steer`.
4. **Empty STT:** covered by unit tests (4.3); on device only observed.
5. Birk confirms the behaviour in his own words (card comment).

## 8. Architecture and files

Strategy rule 1 (`wing-fork-upstream-strategie.md`): own code goes in own files; upstream files get only
thin hooks. New files live under `lib/voice_offline/`, the folder the TTS-language plan also uses.

**New:**

| File | Responsibility | Depends on |
|---|---|---|
| `lib/voice_offline/barge_in_policy.dart` | Pure: `listenConfig(VoicePreferences)`, `PlaybackGate` (4.2), `EchoStats` (5.3), `isSendableTranscript`, `ListenDelivery decideDelivery(status, text)` | `vad_endpoint.dart`, `voice_preferences.dart` |
| `lib/voice_offline/turn_listener.dart` | `TurnListener extends ChangeNotifier`: owns listen rounds on a `VoiceDevice` (start with `keepPlayback`, feed windows to `VadEndpointer` + `PlaybackGate`, finish/transcribe, silent restart, close, probe). It emits `onUtterance(String)` and `onBarge()`. It does not know chats. | `android_voice.dart`, policy |
| `lib/voice_offline/barge_in_coordinator.dart` | Glue: opens and closes the listener for a chat, serializes deliveries, calls `ListenTarget` (steer/queue/send) per `decideDelivery`, logs. | `ListenTarget` interface (implemented in the screen by a 20-line adapter), `TurnListener` |
| `lib/voice_offline/barge_in_settings.dart` | `BargeInSettings` widget: the §6 setting rows and the debug echo probe button | `voice_preferences.dart`, `TurnListener`, `VoiceOutputController` |
| `docs/VOICE_BARGE_IN.md` | Behaviour, settings, log lines, measurement results | |
| tests: `test/voice_offline/barge_in_policy_test.dart`, `turn_listener_test.dart`, `barge_in_coordinator_test.dart` | | `test/support/voice_fixture.dart` |

**Thin hooks in existing files:**

| File | Hook |
|---|---|
| `android/.../VadCapture.kt` (fork-owned, VAD chain) | `Options` gets `startCue` (default = `cues`); `start()` plays the beep only if `startCue` |
| `android/.../VoiceChannel.kt` | `start()`: skip `playback.stop()` when `keepPlayback == true`; pass `startCue` |
| `lib/core/services/android_voice.dart` | `VadCaptureOptions` gets `keepPlayback` (default false) and `startCue` (default null → = cues) in `toMap` |
| `lib/core/services/vad_endpoint.dart` (fork-owned) | getter `bool get speechStarted` (no behaviour change; Python mirror unaffected) |
| `test/support/profile_browser_fixture.dart` | `rpcResponses` map so widget tests can answer `session.steer` |
| `lib/core/services/voice_preferences.dart` | 3 keys: `voice.listen_turn` (on/off), `voice.listen_min_speech_ms` (250/400/600), `voice.barge_in_playback` (on/off); 3 fields |
| `lib/core/widgets/voice_preferences_card.dart` | one line: insert `BargeInSettings` (new own file `lib/voice_offline/barge_in_settings.dart`, holds the rows from §6 and the probe button) after the Conversation mode switch |
| `lib/core/screens/profile_workspace_screen.dart` | create/dispose the coordinator; `_conversation` setter → `close()`; after `_sendConversationTurn` → `open`; `_speakCompletedReply` → playback mode / skip per D3; 3.3 re-open; media key branch; status row; `_sendConversationTurn` busy → steer |
| `test/support/voice_fixture.dart` | record `keepPlayback` / `startCue` (already records `vadOptions`) |

`voice_input_controller.dart` and `VoicePlayback.kt` are **not touched**. The listener is a separate
class on the same `VoiceDevice`. Native events are filtered by round id. Only one VAD round exists
natively at a time (`VadCapture.start` cancels the current one), and the screen never runs a dictation
round and a listen round together.

### 8.1 Overlaps with other plans

| Other work | Files it changes | Overlap with this design |
|---|---|---|
| VAD chain `wt/t_24ef9c3d` (prerequisite) | VadCapture.kt, VoiceChannel.kt, android_voice.dart, voice_input_controller.dart, voice_preferences.dart, voice_preferences_card.dart, profile_workspace_screen.dart | Everything here builds on it. Start only after it is merged |
| TTS language `docs/superpowers/plans/2026-10-13-wing-tts-language.md` (not implemented) | VoicePlayback.kt `speak()` chunking (:815-848 of the plan), VoiceChannel.kt `"speak"` args (:850-865), android_voice.dart `speak()` | VoiceChannel.kt: different branch of `handle` (`speak` vs `start()`), so a textual conflict is unlikely. android_voice.dart: different method (`speak` vs `VadCaptureOptions`). VoicePlayback.kt: not touched here |
| Upstream merge chain t_d1d49ff1 → t_6a4e1890 → t_f8523002 (parked) | Voice files with ~23 conflicts (strategy doc) | Strategy rule 3: no new voice chain before that merge |
| Max dictation `t_d3a672fe` | profile_workspace_screen.dart (per TTS-language plan :39-40) | Same file, different functions; rebase check in Task 0 |
| 3A sentence-wise read-aloud (not planned yet) | screen `_speakCompletedReply`, voice_output_controller | 3A must call the coordinator's playback mode instead of `_voiceOutput.speak` directly. Note for that card |

## 9. Basis / Rebase

The coder starts from **`voice-offline` after both** the VAD merge (card t_145c5731, which brings
`wt/t_24ef9c3d`) and the upstream merge chain (t_f8523002 done), per strategy rule 3. If Birk orders an
earlier start, the base is `voice-offline` with the VAD merge only, and this card must then merge *before*
the upstream chain resumes.

Line numbers in this spec refer to `wt/t_24ef9c3d` @ `4a1a86c6` (Wing) and Hermes upstream `e06df9c2`.
Before Task 1 the coder re-verifies (one command each, from the repo root):

```
git merge-base --is-ancestor 4a1a86c6 HEAD            # exit 0 = VAD chain included
git grep -n "playback.stop()" -- android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt
git grep -n "data class Options" -- android/app/src/main/kotlin/com/tarkilhk/wing/VadCapture.kt
git grep -n "class VadCaptureOptions" -- lib/core/services/android_voice.dart
git grep -n "_speakCompletedReply\|_sendConversationTurn\|set _conversation\|_voiceDeviceEvent\|Widget _voiceActivity" -- lib/core/screens/profile_workspace_screen.dart
git grep -n "Future<bool> steer\|Future<void> queuePrompt\|case 'message.start'" -- lib/core/services/profile_workspace_controller.dart
git grep -n "Conversation mode" -- lib/core/widgets/voice_preferences_card.dart
git grep -n "static const vadSourceKey" -- lib/core/services/voice_preferences.dart
```

Hermes: if upstream `main` moved past `e06df9c2`, re-read `tui_gateway/methods_session_interrupt.py`
(`_correction_method`) and `agent/turn_finalizer.py` (`pending_steer`) via
`curl -s -H "Accept: application/vnd.github.raw" "https://api.github.com/repos/NousResearch/hermes-agent/contents/<path>?ref=main"`
before Task 9.

## 10. Testing

- Pure policy: golden probability sequences. A cough is 8 windows at 0.8 then silence. Echo is
  alternating 0.3/0.6 runs ≤ 6. Real onset is ≥ 20 windows at 0.9. Plus transcript filter tables and
  the status → delivery table.
- `TurnListener` with `VoiceDeviceFixture`: silent restart at max duration; no restart after close;
  playback gate rejects a cough and accepts speech; `keepPlayback`/`startCue` passed; serial delivery.
- Coordinator with a fake `ListenTarget`: steer → `false` → queue/send fallback; drop; close on
  conversation end; follow-up turn (3.3).
- Screen widget tests (`test/voice_workspace_test.dart`): open on auto-send; close on approval; D3 skip;
  busy dictation → steer.
- Kotlin: compile via `dispatch-check.sh voice-apk.yml publish=false`. Behaviour on the device (Tasks 7,
  12, 13).

## Open decisions for Birk

1. **D1: Default of "Listen while Hermes works".**
   - (A) On by default when Conversation mode is on with the vad route.
   - (B) Off; Birk switches it on.

   Privacy aspect: during a turn, side conversations or a radio voice may be transcribed (on the phone)
   and steered into the agent. **Recommendation: A.** It is the requested hands-free behaviour. The
   steer row makes every delivery visible, and the media key or "Stop listening" closes it.
   **ANNAHME (Birk-Gate):** A.
2. **D2: If the echo measurement fails in the car (S3).**
   - (A) In the car, read-aloud is interrupted only with the steering-wheel media key (exists today);
     voice barge-in stays an opt-in setting with the hint "works with headset".
   - (B) Try playing TTS through the communication path (`USAGE_VOICE_COMMUNICATION` +
     `MODE_IN_COMMUNICATION`) and re-measure. It is likely to switch the car to BT-SCO (mono, phone-call
     quality) and to change routing for all Wing audio.
   - (C) Drop (b).

   **Recommendation: A.** It costs nothing, and (B) degrades every reply's sound for an uncertain gain.
   **ANNAHME (Birk-Gate):** A.
3. **D3: The finished reply after Birk talked over the turn's end or barged in.**
   - (A) It is not read aloud or resumed; it stays in the chat, and "Read aloud" replays it.
   - (B) It is read aloud anyway after his new prompt was sent (it overlaps the next turn).
   - (C) Read-aloud continues from the interrupted sentence.

   **Recommendation: A.** He chose to speak. (B) talks over his next turn. (C) needs progress callbacks
   that Wing does not have (`VoicePlayback.kt` emits only `playing:true`).
   **ANNAHME (Birk-Gate):** A.

## Kurzfassung

Birks Fall (weiterreden, während Hermes arbeitet) ist Teil (a): das Mikro bleibt während der Runde offen,
jede Äußerung geht per `session.steer` in die laufende Runde. Echo spielt dabei keine Rolle, und 3A ist
nicht nötig. Reinreden ins Vorlesen ist Teil (b) und erzeugt meist einen neuen Prompt. (b) hängt an einer
Echo-Messung auf dem Handy (Lautsprecher, Kopfhörer, Auto) mit fester Schwelle. Bis dahin unterbricht im
Auto die Lenkradtaste. Start erst nach dem VAD-Merge und dem Upstream-Merge.

## Entscheidungen fuer Birk

1. **Mithören standardmäßig an?** (A) an im Gesprächsmodus mit VAD-Route, (B) aus. Empfehlung: **A**.
   Die Steuerzeile im Chat zeigt jede gesendete Äußerung, "Zuhören beenden" schaltet ab.
2. **Wenn die Echo-Messung im Auto durchfällt:** (A) im Auto nur die Lenkradtaste (gibt es schon),
   Sprach-Unterbrechung bleibt optional für Kopfhörer, (B) TTS über den Telefonie-Pfad (schlechterer
   Klang) und neu messen, (C) Reinreden ins Vorlesen streichen. Empfehlung: **A**.
3. **Antwort nach dem Reinreden:** (A) nicht weiter vorlesen, bleibt im Chat, (B) trotzdem vorlesen,
   (C) ab dem unterbrochenen Satz fortsetzen. Empfehlung: **A**.

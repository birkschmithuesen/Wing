# Wing Voice: barge-in and steering by voice — design

Card: t_7e81e040 (board wing). Date: 2026-10-14, revised 2026-10-16. Status: Birk decided D1-D3 on
2026-10-14 (see "Decisions (Birk 14.10.)"). Part (a) is built and merged into `voice-offline`
(merge `fff2ed93`). This revision makes part (b) headphones-only (D2) and adds the interrupted-reply
hint (extension, card t_98e8c3c2).

## 1. The wish, and what it really asks for

Birk (paraphrased): while Hermes answers — text streams in, or the reply is read aloud — he simply talks.
Read-aloud stops, the microphone records, and what he said reaches the running turn as a **steering
message** without any tap.

His workaround before part (a): he pauses, the sentence is sent after the pause, the turn starts. Then he
taps the mic and keeps talking, and taps the composer's primary button (default action **Steer** while
the chat is busy). Traced in code (`wt/t_24ef9c3d` @ `4a1a86c6`):

- The mic button stays enabled while a turn runs. `_dictate` writes the transcript into the composer.
- `_sendConversationTurn` refused to send while `chat.busy` and **ended the conversation**.
- The composer's primary button while busy defaults to Steer (`lib/core/models/composer_action.dart`).
  It calls `controller.steer`. On `false` it shows the snackbar "Hermes rejected the steering message."

So the workaround cost **two taps** (mic, Steer) and dropped the hands-free loop.

**Architect's hypothesis — confirmed, with one refinement.** Read-aloud starts only after the turn has
finished: `_speakCompletedReply` listens to `controller.completedReplies`. That stream is fed only in
`_settleTurn` (`profile_workspace_controller.dart:6128` at HEAD `e00ee3c9`). The wish therefore splits
into two features:

| | (a) **Listen while Hermes works** | (b) **Barge-in during read-aloud** |
|---|---|---|
| When | From the conversation's auto-send until the turn ends (tools, interim text, final text streaming) | While Wing reads a finished reply aloud **and the output goes to headphones** (D2) |
| Utterance becomes | `session.steer` into the running turn. Fallback when the turn has ended: a normal prompt | Usually a **normal next prompt** (turn already finished), carrying the interrupted-reply hint (§3.6). It becomes a steer only if a follow-up turn is running (see 3.3) |
| Echo problem | **None.** Nothing plays (cue tones only; they are outside the recording, see 5.2) | **Small.** Headphones keep Wing's voice out of the phone mic; the gate (§4.2) still guards against leakage |
| Delivers Birk's workaround case | **Yes.** This is exactly "pause → sent → keep talking → steer", without the taps | No. It is the "stop reading, I want to say something" case |
| Status | **Built, merged in `fff2ed93`** | To build, after the headphone echo measurement (S2) passes |

**Refinement (verified in Hermes upstream):** a steer that arrives while the model is writing its
**final** answer is not lost. `AIAgent` has no tool batch left to inject into. The finalizer hands the
text back as `pending_steer` (`agent/turn_finalizer.py:745-749`), and the gateway enqueues it and starts
a **follow-up turn** right after `message.complete` (`tui_gateway/prompt_turn.py:438-449`). So (a) is
useful for the *whole* running phase, including text streaming. The follow-up turn's start reaches Wing
as `message.start` with an idle chat. Wing turns that into `status = running`.

**Is option 3A (sentence-wise read-aloud while the turn still streams) needed?** No, for neither part.
(a) works without 3A, because steering happens while nothing is read. (b) works without 3A too and
produces a new prompt. **Order:** (a) is done. (b) follows only with headphones (D2) and only if the
headphone echo measurement S2 passes (§5.3). Over the phone speaker and in the car, read-aloud is
interrupted by tapping or by the media key, as today.

## 2. Verified stock API (Hermes)

AGENTS.md: target is **latest upstream Hermes, unmodified**.

- Upstream `NousResearch/hermes-agent` `main` = **`e06df9c2eae6901f4c88f464e0ae6e753c0428b8`**. It was
  read on 2026-10-14 via the GitHub contents API. `raw.githubusercontent.com` timed out from the vServer.
- The local reference checkout `/home/birk/.hermes/hermes-agent` (branch `birk-local`, `69723ab7`) has the
  **same steer path**. `diff` of `tui_gateway/methods_session_interrupt.py` shows differences only in
  `session.interrupt` (compute-host recovery). `_correction_method`, `session.steer` and
  `session.redirect` are identical. `agent/turn_finalizer.py`, `tui_gateway/prompt_turn.py` and
  `agent/interrupt_control.py` were fetched from upstream and grep-compared for the steer drain.
- Part (b) and the interrupted-reply hint use **no new gateway call**. (b) sends a normal prompt
  (`prompt.submit`) or a `session.steer`; the hint is plain text inside that prompt. The matching
  instruction for the model lives in the profile config (`platform_hints.wing`, §3.6), which is profile
  configuration, not a backend patch.

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

No event announces an accepted steer. Wing records it itself as a `display_kind: 'steer'` user row. The
gateway answers a compression-queued text with the same `queued`, so Wing shows a steer row for it too.
The server then runs it as the next prompt. This is a known, accepted inaccuracy: the text still reaches
the agent.

**Race:** between `message.complete` (:1193) and `running = False` (:1210), a steer would still be
accepted, after the finalizer already drained. Wing never sends one there: `steer()` returns `false`
without calling the server unless `chat.status` is `running`/`attention`, and Wing settles the chat on
`message.complete`.
ANNAHME: network reordering cannot deliver Wing's steer *after* Wing processed `message.complete` but
*before* the server set `running = False`. Wing sends nothing after that point, so this holds by
construction.

## 3. Behaviour

### 3.1 Scope conditions

Active only when **all** hold: input route `vad`, Conversation mode on, the conversation's chat on screen
(`_conversation == chat.key`), and

- for (a): the setting "Listen while Hermes works" on (default **on**, D1);
- for (b): the setting "Interrupt read-aloud by speaking" on, the echo gate passed
  (`bargeInPlaybackAvailable`, Task 7), and the **routed output device is headphones** (§3.4.1, D2).

The other input routes cannot do it. `local` (Android `SpeechRecognizer`) owns the mic and has no
continuous mode. `hermes` has no end-of-utterance detection.

### 3.2 (a) Listen while Hermes works — built

1. The conversation auto-sends a prompt (`_sendConversationTurn`). Instead of leaving the mic closed, Wing
   opens a **listen round** for the same chat. It is a VAD round with its own policy (§4): no start
   beep, the "got it" tone on each utterance end, no no-speech timeout. The round ends at max duration
   and restarts silently.
2. Birk speaks; the round ends after the normal pause (1.8 s default, choices up to 5 s). Parakeet
   transcribes it on the phone.
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
5. The listen round closes when the turn completes and no speech is in progress. If speech is in
   progress at completion, the utterance finishes first. It then goes through step 3; the chat is idle,
   so it becomes a normal send. **D3 (decided):** the finished reply is then **not** read aloud; it stays
   visible in the chat.
6. Anything that ends the conversation also closes the listen round, with a single hook in the
   `_conversation` setter: approval, clarification or sensitive prompt; chat switch; failed or cancelled
   turn; voice error; "Cancel recording"; "Stop speech"; manual composer action; Stop response.
7. **D1 (decided):** with "Listen while Hermes works" off, the microphone stays closed while Hermes works
   (test `listening is off with the setting off`, `test/voice_workspace_test.dart:705`).

### 3.3 Follow-up turns caused by a steer — built

After a steer was accepted in this conversation turn, the turn completes and the reply is read aloud (if
D3 did not suppress it). If the chat is then **busy again** — the gateway started the `pending_steer`
follow-up turn — Wing does not end the conversation. It treats the follow-up as the conversation's own
turn: `_conversationAwaitingReply = true`, and it opens a listen round.

Race: the follow-up's `message.start` may arrive after read-aloud ended, when a normal dictation round
is already open. `_sendConversationTurn` therefore steers a hands-free utterance on a `running` chat
instead of ending the conversation.

### 3.4 (b) Barge-in during read-aloud — headphones only (D2)

**D2 (decided):** voice barge-in into read-aloud is allowed **only while the routed output device is
headphones**, in general, not only after a failed measurement. Over the phone speaker and in the car,
only tapping (stop button) or the media key interrupts read-aloud; both exist today
(`_voiceDeviceEvent`, `profile_workspace_screen.dart:558`; `_dictate` stops output first, :598-601).

Built behind the setting **"Interrupt read-aloud by speaking"** (default **off**). The row appears only
if the headphone echo measurement S2 passed or was marginal (§5.3, constant `bargeInPlaybackAvailable`).
Flow:

1. `_speakCompletedReply` decides once, synchronously, before the reply joins the speech queue:
   playback barge-in is on when `bargeInPlaybackAvailable && settings.bargeInPlayback &&
   _conversation == chat.key && headphones` (cached verdict, §3.4.1). Then the turn's listen round
   stays open and switches to **playback mode** (`TurnListener.open(playback: true)` → `setPlayback`).
   Otherwise the round closes (`turnEnd`), exactly as today. The capture does not stop playback: listen
   rounds already start with `keepPlayback: true` (`VoiceChannel.kt:97`).
2. While Wing reads aloud, a stricter **playback gate** (§4.2) must confirm speech before anything
   happens. A cough or short noise does not pass it. TTS continues, and the round's partial speech
   state is discarded (round cancelled and restarted).
3. Gate passes → the screen's `onBarge` clears the speech queue and stops output immediately (target:
   within 1.2 s of speech onset, §7). The same round keeps recording. The pre-roll (300 ms) plus the
   gate window means the beginning of the utterance is in the cut.
4. The utterance ends by pause → delivery rule (§4.3). Usually the chat is idle → normal conversation
   send, with the interrupted-reply hint (§3.6). If a follow-up turn runs (3.3) → steer, without hint.
5. **D3 (decided):** the interrupted reply is not resumed or read further. It stays in the chat; "Read
   aloud" on the message replays it on request. Replies still waiting in the speech queue are dropped
   too (`SpeechQueue.clear`, `lib/voice_offline/speech_queue.dart:32`).
6. TTS ended without barge-in → if nothing else waits in the speech queue, the round switches to
   normal listening rules (`setPlayback(false)`). This replaces the `_dictate(resume: true)` re-open
   for that reply: the round is already open, so there is no extra cue or gap. If another reply waits in
   the queue, the round stays in playback mode.

The **media key** stays the hands-free interruption that always works, on every output device.

#### 3.4.1 Headphone detection (Android, client-only)

Read in code (HEAD `e00ee3c9`):

- TTS and Hermes audio both play with `AudioAttributes(USAGE_MEDIA, CONTENT_TYPE_SPEECH)`
  (`VoicePlayback.kt:25-26`). The engine owns the TTS `AudioTrack`; `TextToSpeech` does not expose it, so
  "the routed device of the TTS AudioTrack" is not readable from Wing. Wing asks the audio policy instead
  which device those attributes route to.
- No Bluetooth or audio-routing API is used anywhere in Wing today (`git grep` for `BLUETOOTH`,
  `AudioDeviceInfo`, `getAudioDevicesForAttributes`, `AudioDeviceCallback`, `UiModeManager`: no hits).
  The manifest has `RECORD_AUDIO` and no Bluetooth permission (`AndroidManifest.xml:2-10`).
- `minSdk = 24`, `targetSdk = 36` (`android/app/build.gradle.kts:142-143`). The target phone (Xperia 5
  IV) runs Android 13 or later.

**API** (checked in the AOSP sources fetched on 2026-10-16 via the GitHub contents API;
`developer.android.com` was unreachable from the vServer):

| Need | API | Permission |
|---|---|---|
| Routed output device for read-aloud | `AudioManager.getAudioDevicesForAttributes(AudioAttributes)` (public since API 33; "the devices anticipated to play sound from an AudioTrack created with the specified AudioAttributes"), called with the same attributes as `VoicePlayback` | none (no `@RequiresPermission` on the public method; the change listener `addOnDevicesForAttributesChangedListener` is `@SystemApi` and therefore not usable) |
| Device kind | `AudioDeviceInfo.getType()` | none |
| Route changes | `AudioManager.registerAudioDeviceCallback` (API 23); on each add/remove Wing re-queries the routed device | none |
| Bluetooth class of an A2DP / LE headset device | `BluetoothAdapter.getRemoteDevice(AudioDeviceInfo.getAddress()).getBluetoothClass().getDeviceClass()` | **`BLUETOOTH_CONNECT`**, a runtime permission on API 31+ ("Nearby devices"). `getBluetoothClass()` is annotated `@RequiresPermission(BLUETOOTH_CONNECT)` |
| Android car mode | `UiModeManager.getCurrentModeType() == Configuration.UI_MODE_TYPE_CAR` | none |

**New runtime permission: `BLUETOOTH_CONNECT`.** Reason: the only way to tell Bluetooth headphones
from a car head unit is the remote device's Bluetooth class, and reading it requires this permission.
Wing declares it in the manifest and requests it **only when the user switches "Interrupt read-aloud by
speaking" on** (and only on API 31+). Without it, wired and USB headphones still count; Bluetooth
outputs count as "class unknown" → not headphones. Wing never scans, pairs or connects; it reads the
class of the already-routed device.

**Rule (conservative; anything not listed is "not headphones"):**

| Check, in order | Verdict | `reason` |
|---|---|---|
| Android < 13 (no `getAudioDevicesForAttributes`) or the query fails / returns nothing | no | `unsupported` |
| Wing car mode active (`CarModeSession.active`, `lib/car_mode/car_mode_session.dart:40`) | no | `carMode` |
| Android car mode (`UI_MODE_TYPE_CAR`) | no | `androidCarMode` |
| Type `TYPE_WIRED_HEADSET` (3), `TYPE_WIRED_HEADPHONES` (4), `TYPE_USB_HEADSET` (22) | **yes** | `wired` |
| Type `TYPE_BLUETOOTH_A2DP` (8) or `TYPE_BLE_HEADSET` (26), class `AUDIO_VIDEO_WEARABLE_HEADSET` (0x0404) or `AUDIO_VIDEO_HEADPHONES` (0x0418) | **yes** | `bluetoothHeadphones` |
| Same types, class unreadable (no permission, anonymised or invalid address, adapter off) | no | `bluetoothClassUnknown` |
| Same types, any other class (`CAR_AUDIO` 0x0420, `HANDSFREE` 0x0408, `LOUDSPEAKER` 0x0414, `PORTABLE_AUDIO` 0x041C, `HIFI_AUDIO` 0x0428, `UNCATEGORIZED` 0x0400, …) | no | `bluetoothOther` |
| `TYPE_BUILTIN_SPEAKER` (2) | no | `speaker` |
| Anything else (SCO 7, hearing aid 23, BLE speaker 27, USB device/accessory, HDMI, dock, …) | no | `other` |

So a car head unit on A2DP (class car audio or hands-free) is **not** headphones, and a Bluetooth device
of unknown class is not headphones either. `SCO` (call path) never counts.

- ANNAHME: `AudioDeviceInfo.getAddress()` of a Bluetooth output returns the real address when
  `BLUETOOTH_CONNECT` is granted (Android anonymises it for callers without the permission; not verified
  in source here). Check on the device: with the permission granted and Birk's headphones connected, the
  route log shows `btClass=0x…`, not `none`.
- ANNAHME: Birk's headphones report class 0x0404 or 0x0418, and his car reports a class outside that set.
  Check on the device: route log during S2 (headphones) and, optionally, in the car.
- ANNAHME: a car connected through an AUX cable appears as `TYPE_WIRED_HEADPHONES` and cannot be told
  apart from headphones; only Wing car mode or Android car mode closes the gate then. Birk's car uses
  Bluetooth (§5.3 S3). Check: Birk confirms the car connection type; documented as a limit.
- ANNAHME: `getAudioDevicesForAttributes` reports the Bluetooth or wired device (not the speaker) while
  read-aloud plays to it on the Xperia. Check on the device: route log `type=8` / `type=4` etc. with
  headphones.

#### 3.4.2 Re-evaluation when the route changes

- The verdict is cached in a `HeadphoneRoute` notifier. It is refreshed when the conversation sends a
  prompt (so it is fresh when the reply arrives), on every native audio-device add/remove, and when
  Wing car mode switches.
- **Headphones → not headphones while Wing reads aloud** (unplugged, Bluetooth dropped, car mode
  entered): a playback-mode round closes at once (`listen close reason=route`). Read-aloud itself is not
  touched by Wing; Android's `ACTION_AUDIO_BECOMING_NOISY` already stops it when headphones are unplugged
  or a Bluetooth sink drops (`VoicePlayback.kt:41-47`). If it keeps playing (for example car mode was
  entered), it plays on with the mic closed, and the conversation continues after it as today.
- **Not headphones → headphones while Wing reads aloud** in the conversation: the round opens in
  playback mode, if all other conditions of §3.4 step 1 hold.
- Order does not matter: if Android stops playback before the route event arrives, the round has
  already switched to normal listening (§3.4 step 6) and nothing plays any more.

### 3.5 Interaction with existing rules

| Rule | With this feature |
|---|---|
| Approvals / clarify / sensitive prompt end the conversation | Unchanged. The listen round closes with the conversation. The utterance in flight is cancelled, not sent: a steer during an approval is not what the user expects. |
| Media key | Listen round with speech in progress → ends the utterance now → delivery. Listen round without speech → closes the listen round for this turn. Read-aloud → unchanged (stop TTS, dictate). Works on every output device. |
| Stop button "Stop response" | Interrupt → cancelled turn → conversation ends → listen round closed (no extra code). |
| "Stop speech" | Ends the conversation as today; this also closes a playback-mode round. |
| Speech queue (`speech_queue.dart`, t_3c7b431d) | Replies queue instead of interrupting each other. A barge-in clears the queue (D3); the round leaves playback mode only once the queue is empty (§3.4 step 6). |
| Per-sentence TTS language (`LanguageSpeech.kt`, t_bee9c471) | Unchanged. Wing still sends one `speak` call per reply; the engine plays the language segments. |
| Screen off (`BackgroundVoiceService`, t_3d657c6f) | Unchanged. The foreground service keeps listen rounds alive; the notification shows "listening" via `_bargeIn.addListener` (`profile_workspace_screen.dart:813`). Route detection works without the activity in front (system services only). |
| Car mode (t_b22000e9) | Never voice barge-in into read-aloud (`carMode`). Steering while Hermes works stays as car mode built it. |
| VAD no-speech timeout | **Not used** for listen rounds: a tool turn can last minutes. Listen rounds set `noSpeechTimeout = maxDuration`, so `NoSpeech` only happens at max duration, which silently restarts the round. |
| VAD max duration (600 s) | Caps one listen round. A restart reallocates the PCM buffer, so memory stays bounded. |
| Battery | Mic + Silero run for the turn's duration. **ANNAHME:** Wing's CPU during a listen round is < 10 % of one core; checked in Task 13 (`top`). Route detection costs nothing between events. |
| Hermes/local TTS output route | Barge-in (b) works for both. Both use the same attributes, so the same route verdict applies. |

### 3.6 Interrupted-reply hint (extension, card t_98e8c3c2)

Birk thinks in stages with long pauses (10 s): he speaks, pauses, speaks on. A reply that is already
being read aloud can then be cut off by his voice (D3: not read further). Its content may still matter.
Wish: the **next** reply, the only one he then hears, takes up the content of the interrupted one.

**Can Wing know how far read-aloud got?** No, not per sentence:

- Native playback emits only `{"id", "playing": true}` when an utterance starts, without an index
  (`VoicePlayback.kt:70-73`). `VoiceOutputController` uses the first such event only to clear
  `preparing` (`voice_output_controller.dart:61-66`).
- The segments Dart sends are **language runs**, not sentences: consecutive sentences of one language
  merge into one segment of up to 1000 characters (`speech_segments.dart:36-69`). A German-only reply of
  normal length is a single segment, so even counting `playing` events would say nothing.
- The Hermes TTS route plays one audio file without segments (`VoicePlayback.kt:123-137`).
- The speech queue serializes whole replies (`speech_queue.dart`), not sentences.

A sentence-level signal would need `UtteranceProgressListener.onRangeStart` or per-sentence utterances
in `VoicePlayback.kt`, which this design keeps untouched. **The hint therefore carries no percentage.**
A progress figure can be a separate card if Birk wants it.

**Hint text** (constant `interruptedReplyHint`, German like the profile's Wing platform hint):

```
[Hinweis von Wing: Die vorige Antwort wurde beim Vorlesen abgebrochen und nicht zu Ende gehört.]
```

**When:** Wing appends it after a blank line to the text of an utterance **only** when

- that utterance's listen round fired the playback gate (a voice barge-in into read-aloud), and
- the utterance is delivered as `send` or `queue` (also after a rejected steer).

Never on a `steer` (a turn is running and nothing it produced was cut off by this utterance), never on a
listen-round utterance without barge-in, never on a manual dictation or a media-key interruption. The
hint becomes part of the user message, so it is visible in Birk's own chat row. Logs never contain it or
any other text: the delivery line gets `hint=<0|1>` only.

**Model side:** one sentence in Birk's profile config, `platform_hints.wing.append` in
`/home/birk/.hermes/profiles/birk/config.yaml` (outside this repo; how that key was added:
`docs/superpowers/plans/2026-10-13-wing-client-source.md` Task D1):

```
Steht am Ende einer Nachricht '[Hinweis von Wing: Die vorige Antwort wurde beim Vorlesen abgebrochen und nicht zu Ende gehört.]', die nicht gehörten Kernpunkte der vorigen Antwort knapp in die neue Antwort einarbeiten.
```

The Hermes worker edits that file, not Claude Code (plan Task 18). ANNAHME: `platform_hints.wing.append`
exists in Birk's config (client-source plan Task D1 was carried out); the worker checks it before
editing and stops if it is missing.

## 4. Policies and numbers

### 4.1 Listen round endpointing (no playback)

The listen round reuses `VadEndpointer` unchanged (`lib/core/services/vad_endpoint.dart`) with this
config:

| Parameter | Dictation (VAD spec) | Listen round | Why |
|---|---|---|---|
| Start threshold / end threshold | 0.5 / 0.35 (constants) | same | Constants of the endpointer and its Python mirror; unchanged |
| Pause to end | user setting, 1.8 s default (up to 5 s) | same setting | Same speaking style as the prompt |
| Min speech | user setting, 250 ms default (choices 150/250/400) | **own setting, 400 ms default** (choices 250/400/600) | Nobody asked for the mic here. 400 ms (13 windows) rejects a single cough or throat-clear burst. ANNAHME: typically 200-350 ms above 0.5, to be checked in Task 14. A short "Stopp" still passes. |
| Pre-roll | user setting, 300 ms | same | |
| No-speech timeout | 8 s | = max duration | See 3.5 |
| Max duration | 600 s | same setting | Restart on reach |

### 4.2 Playback gate (only for (b))

While TTS plays, an onset counts only if a run of **≥ 16 consecutive windows (512 ms) with p ≥ 0.7**
occurs (constants `bargeGateThreshold`, `bargeGateWindows`, `barge_in_policy.dart:21-22`). These start
values stay if S2 passes. If S2 is marginal, Task 7 replaces them from the **S2** numbers (worst run):

`bargeGateThreshold = max(0.7, ceil10(p99 + 0.15))` and `bargeGateWindows = max(16, 2 × run70)`.

`ceil10` rounds up to one decimal; `run70` is the probe's longest run with p ≥ 0.7. If the formula
yields a threshold > 0.9 or windows > 31 (1 s), S2 counts as failed (5.3).

### 4.3 Delivery and transcript filter (pure) — built

`ListenDelivery decideDelivery(ListenChatState state, String transcript, {bool steerRejected = false})`
(`barge_in_policy.dart:142`). The screen maps `ProfileTurnStatus` to `ListenChatState`:
`running`/`attention` → `steerable`; `submitting`/`reconnecting` → `busy`; everything else → `idle`.

- `drop` when the trimmed transcript has no letter (`\p{L}`), or all its words (lower-cased,
  punctuation stripped) are in the filler set `{äh, ähm, öh, hm, hmm, mhm, uh, um, uhm, eh}`. "ja" and
  "nein" are **not** fillers.
- `steer` for `steerable` (but `queue` when `steerRejected`);
- `queue` for `busy`;
- `send` for `idle`.

A dropped utterance has already produced the "got it" tone. This is accepted and documented.

## 5. Echo: does the mic hear Wing's own TTS?

### 5.1 What the code says

- Capture uses `MediaRecorder.AudioSource.VOICE_COMMUNICATION`, falling back to `VOICE_RECOGNITION`
  (`VadCapture.kt` `openRecord`). No `AcousticEchoCanceler` or `NoiseSuppressor` is attached, and there
  is no `AudioManager.setMode`.
- TTS plays as `USAGE_MEDIA` / `CONTENT_TYPE_SPEECH` (`VoicePlayback.kt:25-26`), with focus
  `AUDIOFOCUS_GAIN_TRANSIENT` (:95-98).
- With A2DP or wired headphones, playback leaves the phone; capture still uses the phone microphone (no
  SCO). The echo path is then only leakage from the ear cups. That is why D2 allows voice barge-in only
  there.

### 5.2 Cue tones are not an echo problem for (a)

The "listening" beep plays before capture, and listen rounds do not use it. The "got it" tone plays in
`finish` after the reader stopped. Neither is inside a listen recording.

### 5.3 Measurement (Task 6, Hermes worker via `hadb`)

The debug-only **echo probe** is built ("Measure speaker echo", visible with "Keep voice recordings" on;
`barge_in_settings.dart:137-149`). It opens a listen round with `keepPlayback = true`, `cues = false`,
plays a fixed **synthetic** German text of about 30 s through the normal local TTS path, and logs one
line (numbers only):

```
WingBargeIn probe windows=<n> max=<p> p50=<p> p95=<p> p99=<p> run50=<w> run70=<w> wouldTrigger=<0|1> source=<VOICE_COMMUNICATION|VOICE_RECOGNITION>
```

From plan Task 16 on, the probe first logs the route verdict (`WingBargeIn route …`, §7), so the S2
session also checks the headphone detection.

| ID | Setup | Role |
|---|---|---|
| **S2** | Headphones Birk uses, wired or Bluetooth (A2DP), normal volume, quiet room, 3 runs per headphone type he uses | **Gate.** Birk plugs in or pairs; worker runs the probe and reads logcat |
| S1 | Phone speaker, media volume 60 % and 100 % | Optional, informational only (no voice barge-in over the speaker, D2) |
| S3 | Car (BT A2DP), parked | Optional, informational only (no voice barge-in in the car, D2); useful to record the car's route verdict |

**Thresholds for S2, across all runs** (unchanged):
- **Pass:** `run50 ≤ 6` (≤ 192 ms) **and** `p99 < 0.5`.
- **Marginal:** `run50 ≤ 15` **and** `p99 < 0.75`. The gate constants come from the formula in 4.2 with
  the S2 numbers; S2 is re-measured (3 runs) with the new build, and every run must log
  `wouldTrigger=0`.
- **Fail:** anything else, or a marginal re-check with `wouldTrigger=1`.

**Decision:** pass → (b) available, gate constants unchanged. Marginal → (b) available with the formula
constants after the S2 re-check. Fail → (b) is **not built**; read-aloud is interrupted by tap and media
key only, on every device. S1 and S3 never change the decision. Feature (a) is not affected by any
result.

## 6. UI (Studio charter)

User task: talk hands-free. Primary action: **none**. The feature removes taps. Editable controls: the
settings rows. Passive context: "listening" state and the headphones-only rule. Temporary status:
"steered" feedback.

In-chat state (built, arrangement A): one status row in `_voiceActivity` — "Listening" with a single
**"Stop listening"** text button. The steer row is the only success feedback; no snackbar. A playback-
mode round shows the same row; the "Reading aloud" row stays as it is.

**Settings** (voice preferences card, `BargeInSettings` below "Conversation mode",
`voice_preferences_card.dart:338`):

- `CompactSwitchListTile` **"Listen while Hermes works"**, subtitle "Speak to steer the running reply",
  default **on** (D1). Built.
- Choice row **"Speech needed to steer"** with 0.25 / 0.4 / 0.6 s. Built.
- `CompactSwitchListTile` **"Interrupt read-aloud by speaking"**, default off, shown only when
  `bargeInPlaybackAvailable` (Task 7). New subtitle that states the D2 rule:

  | State | Subtitle (13 sp muted, one setting row) |
  |---|---|
  | normal | "Only with headphones. On the speaker or in the car, tap to stop." |
  | Bluetooth access denied (API 31+, switch on) | "Only with wired headphones. Allow Nearby devices for Bluetooth headphones." |

  Two arrangements were compared: (A) the rule as the switch's subtitle; (B) a separate info line or
  card under the switch. **Chosen: A.** The rule belongs to the setting it limits, adds no row, and
  stays in the charter's two-line switch row (56 dp minimum, wraps at 200 %). B repeats the title's
  context and adds visual weight to passive information.

  Switching it **on** requests `BLUETOOTH_CONNECT` (system dialog "Nearby devices"). The setting is
  saved either way; a denial only changes the subtitle (it helps recover: switching off and on asks
  again while Android still allows it). No snackbar, no permanent success text.
- Debug only (with "Keep voice recordings"): text button "Measure speaker echo". Built. The synthetic
  script never appears in the UI.

Rendered check: normal phone size and 200 % text, light and dark: the playback row with both subtitles.
On-device check in Task 13.

## 7. Logging and acceptance evidence

All logs use the prefix `WingBargeIn` via `debugPrint` (release builds forward it to logcat as
`I/flutter`; checked on the device in Task 6). They **never contain transcript, reply, prompt or hint
text, session ids, Bluetooth addresses or device names**: only events, durations, lengths, numeric
device types and classes, and statuses.

```
WingBargeIn listen open mode=<turn|playback>
WingBargeIn listen restart reason=<maxDuration>
WingBargeIn utterance segmentMs=<n> textLen=<n>
WingBargeIn deliver kind=<steer|queue|send|drop> result=<queued|rejected|ok|filler|empty> hint=<0|1>
WingBargeIn barge trigger sinceOnsetMs=<n> stopMs=<n>
WingBargeIn barge reject runWindows=<n>
WingBargeIn route headphones=<0|1> reason=<unsupported|carMode|androidCarMode|wired|bluetoothHeadphones|bluetoothClassUnknown|bluetoothOther|speaker|other> type=<n> btClass=<0xNNNN|none> androidCarMode=<0|1>
WingBargeIn probe …            (5.3)
WingBargeIn listen close reason=<turnEnd|conversationEnd|mediaKey|dictate|stopButton|route|probe|dispose|error>
```

`hint=` appears on `send` and `queue` lines only. A `route` line is logged when the verdict or its inputs
change, not on every refresh.

Acceptance (Task 14) passes when, on the installed build:

1. **Steer** (a): the synthetic prompt `Führe im Terminal "sleep 25" aus und antworte dann nur mit
   "fertig".` runs. Birk says "Testsatz eins, bitte nenne zusätzlich das heutige Datum" during the sleep.
   Logcat shows `deliver kind=steer result=queued`, and the chat shows a steer row. The final reply
   contains a date.
2. **D1 switch off:** with "Listen while Hermes works" off, the same turn produces no `listen open` line,
   and speaking during the sleep sends nothing.
3. **Barge-in with headphones** (only if (b) built): the reply to `Zähle langsam in Worten von eins bis
   vierzig.` is read aloud into headphones. Birk says "Testsatz zwei, stopp". Logcat shows
   `route headphones=1`, `barge trigger sinceOnsetMs ≤ 1200`; TTS stops; then
   `deliver kind=send result=ok hint=1`. The sent message in the chat ends with the hint.
4. **Cough with headphones:** during the same read-aloud, three coughs about 5 s apart: no `barge
   trigger`, TTS reads to the end. During a listen round (scenario 1 setup), three coughs produce at most
   `deliver kind=drop`, never `steer`.
5. **Speaker:** the same read-aloud over the phone speaker. Birk says "Testsatz drei, stopp". Logcat
   shows `route headphones=0 reason=speaker` and no `listen open mode=playback`; TTS reads on.
6. **Headphones removed during read-aloud:** read-aloud starts into headphones (`listen open
   mode=playback`); Birk unplugs or switches the headphones off. Logcat shows `route headphones=0`; no
   `barge trigger` follows; either Android stopped read-aloud or `listen close reason=route` appears.
7. **No hint on a steer:** the scenario 1 steer row shows only Birk's words (no hint).
8. **Empty STT:** covered by unit tests (4.3); on device only observed.
9. Birk confirms the behaviour in his own words (card comment).

## 8. Architecture and files

Strategy rule 1 (`wing-fork-upstream-strategie.md`): own code goes in own files; upstream files get only
thin hooks. New files live under `lib/voice_offline/` and the Kotlin package
`com.tarkilhk.wing.voiceoffline`.

**Built in `fff2ed93`:** `barge_in_policy.dart`, `turn_listener.dart`, `barge_in_coordinator.dart`,
`barge_in_settings.dart`, their tests, `docs/VOICE_BARGE_IN.md`, and the hooks in `VadCapture.kt`,
`VoiceChannel.kt`, `android_voice.dart`, `vad_endpoint.dart`, `voice_preferences.dart`,
`voice_preferences_card.dart`, `profile_workspace_screen.dart`.

**New for (b) and the hint:**

| File | Responsibility | Depends on |
|---|---|---|
| `android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/HeadphoneRouteChannel.kt` | Channel `com.tarkilhk.wing/headphone_route`: `current` (raw route facts), `bluetoothAllowed`, `requestBluetooth`; pushes `changed` on audio-device add/remove | `AudioManager`, `BluetoothManager`, `UiModeManager` |
| `lib/voice_offline/headphone_route.dart` | `OutputRoute` (raw facts), pure `classifyRoute` + `routeLogLine` (§3.4.1 table), `HeadphoneRouteHost` + `AndroidHeadphoneRouteHost`, `HeadphoneRoute` (cached verdict, `ChangeNotifier`) | `barge_in_policy.dart` (`bargeLog`) |
| `test/voice_offline/headphone_route_test.dart`, `test/voice_offline/barge_in_settings_test.dart` | | |
| `test/support/headphone_route_fixture.dart` | Fake host for widget tests | |

**Thin hooks (new):**

| File | Hook |
|---|---|
| `AndroidManifest.xml` | `<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />` |
| `VoiceChannel.kt` | create/close `HeadphoneRouteChannel`; forward its permission request code (3 lines) |
| `barge_in_policy.dart` | `interruptedReplyHint`, `withInterruptedReplyHint`; remove `bargeInPlaybackHint`; Task 7 constants |
| `turn_listener.dart` | `bool get playback`; `bool utteranceBarged` set before `onUtterance` |
| `barge_in_coordinator.dart` | append the hint on `send`/`queue` after a barge; `hint=` in the log |
| `barge_in_settings.dart` | subtitle (§6), permission request on switch-on, `route` and `playbackAvailable` parameters, route line before the probe |
| `profile_workspace_screen.dart` | `headphoneRoute` widget parameter; `_headphones` field; refresh on send; playback decision in `_speakCompletedReply`; `_headphoneRouteChanged`; finished/unfinished branches (§3.4 step 6) |

`voice_input_controller.dart` and `VoicePlayback.kt` stay **untouched**. The route query duplicates
`VoicePlayback`'s two attribute constants instead of reading them, and the progress question (§3.6) is
answered without a new playback event.

### 8.1 Overlaps with other work (state at `e00ee3c9`)

| Other work | Status | Overlap |
|---|---|---|
| Speech queue t_3c7b431d (`speech_queue.dart`) | merged `28c67aa6` | `_speakCompletedReply` adds replies to `_autoSpeakQueue`; (b) hooks around that call and respects `isEmpty` |
| TTS language t_bee9c471 (`LanguageSpeech.kt`, `speech_segments.dart`) | merged `f38b00a7` | No change; it answers the progress question (§3.6) |
| Screen off t_3d657c6f (`BackgroundVoiceService`) | merged `cfc6a825` | No change; `VoiceChannel.kt` gains one more sibling channel next to `BackgroundVoiceChannel` |
| VAD pause up to 5 s t_1752226c | merged `e00ee3c9` | None (listen rounds use the same pause setting) |
| Car mode t_b22000e9 | merged `beba7c9e` | `carMode` closes the gate; the car-mode steer block in `_sendConversationTurn` stays |
| 3A sentence-wise read-aloud (not planned) | — | 3A would have to call the playback-mode decision instead of `_voiceOutput.speak` directly; it could also provide the sentence progress §3.6 lacks |

## 9. Basis

The remaining work starts from `voice-offline` at or after **`e00ee3c9`** (contains `fff2ed93`). Line
numbers in this spec refer to that commit unless marked otherwise. Plan Task R0 re-verifies every hook
location with one `git grep` each before any code changes.

Hermes: if upstream `main` moved past `e06df9c2`, re-read `tui_gateway/methods_session_interrupt.py`
(`_correction_method`) via
`curl -s -H "Accept: application/vnd.github.raw" "https://api.github.com/repos/NousResearch/hermes-agent/contents/<path>?ref=main"`.
(b) adds no gateway call, so only the steer statuses matter.

## 10. Testing

- Pure: `classifyRoute` table (every row of §3.4.1, including car audio, hands-free, unknown class,
  car mode, Android < 13); `routeLogLine` format; `withInterruptedReplyHint`.
- `HeadphoneRoute` with a fake host: change events update the verdict and notify; car mode re-evaluates;
  a log line only on change.
- `TurnListener`: `playback` getter; `utteranceBarged` true only after the gate fired in that round.
- Coordinator: hint on `send` and `queue` after a barge; no hint on `steer`, on a rejected steer that
  becomes a steer again, or without a barge.
- `BargeInSettings` widget: subtitle per state; switch-on requests Bluetooth access and saves; switch-off
  does not request; render at 320 dp, 100 %/200 %, light/dark.
- Screen widget tests (`test/voice_workspace_test.dart`): headphones → barge-in stops TTS and sends
  with hint; cough changes nothing; speaker → no playback round, speech does not stop TTS; route to
  speaker during read-aloud closes the round; route to headphones during read-aloud opens it; D1 switch
  off (exists).
- Kotlin: compile via `dispatch-check.sh voice-apk.yml publish=false`. Behaviour on the device (Tasks 6,
  13, 14).

## Decisions (Birk 14.10.)

Verbatim; they replace the earlier assumptions for D1-D3.

1. **D1:** "Mithoeren standardmaessig AN, mit eigenem Schalter in den Voice-Einstellungen zum Ausschalten
   (Toggle, persistiert). Test: Schalter aus -> waehrend Hermes arbeitet bleibt das Mikro zu."
   → Built in (a): `voice.listen_turn` defaults on (`voice_preferences.dart:135`, read at :187).
2. **D2** (stricter than the old option A): "Reinreden per Stimme INS VORLESEN nur mit Kopfhoerern,
   generell (nicht erst nach durchgefallener Echo-Messung). Ueber Lautsprecher/Auto unterbricht nur
   Antippen. Die Echo-Messung braucht damit nur den Kopfhoerer-Fall (S2) als Gate; Lautsprecher/Auto
   messen ist optional. Kopfhoerer-Erkennung ueber das geroutete Ausgabegeraet (wired/BT-A2DP/BLE-Headset)."
   → §3.4, §3.4.1, §5.3, §6.
3. **D3:** "Option A. Eine Antwort, in die Birk hineingeredet hat, wird nicht weiter vorgelesen und bleibt
   im Chat stehen."
   → §3.2 step 5 (built), §3.4 step 5.

Extension (Birk 14.10., card t_98e8c3c2): the next reply takes up the content of a reply he cut off by
voice → §3.6, without a percentage because Wing has no sentence-level progress signal.

## Kurzfassung

Birks Fall (weiterreden, während Hermes arbeitet) ist Teil (a) und ist gebaut (Merge `fff2ed93`): das
Mikro bleibt während der Runde offen, jede Äußerung geht per `session.steer` in die laufende Runde;
Mithören ist standardmäßig an und abschaltbar (D1). Reinreden ins Vorlesen ist Teil (b) und geht nur mit
Kopfhörern (D2): Wing liest das geroutete Ausgabegerät; Kabel- und USB-Kopfhörer zählen, Bluetooth nur mit
Geräteklasse Kopfhörer/Headset (dafür die Berechtigung "Geräte in der Nähe"), Auto, Freisprecher,
unbekannte Klasse und Automodus nie. Über Lautsprecher und im Auto unterbricht nur Antippen oder die
Medientaste. Gate ist allein die Echo-Messung mit Kopfhörern (S2). Eine unterbrochene Antwort wird nicht
weiter vorgelesen (D3); die nächste Nachricht trägt einen Hinweis, damit Hermes die nicht gehörten
Kernpunkte nachliefert. Eine Prozentangabe gibt es nicht, weil Wing keinen Vorlese-Fortschritt pro Satz
kennt. Die passende Zeile im Profil (`platform_hints.wing`) trägt der Hermes-Worker ein.

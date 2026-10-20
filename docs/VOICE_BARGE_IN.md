# Voice barge-in: listen while Hermes works

Spec: `docs/superpowers/specs/2026-10-14-wing-voice-barge-in-design.md`. Plan:
`docs/superpowers/plans/2026-10-14-wing-voice-barge-in.md`. Card: t_7e81e040 (design),
implemented on t_ccaad8af (part a) and t_98e8c3c2 (part b, this revision).

## What it does

**(a) Listen while Hermes works — built.** On the `vad` input route, with Conversation mode
and "Listen while Hermes works" on, the microphone stays open for the whole turn instead of
closing after the auto-sent dictation. A `TurnListener` runs continuous VAD "listen rounds" on
the same `VoiceDevice`; each utterance is handed to a `BargeInCoordinator`, which steers it into
the running turn (`session.steer`), queues it while the gateway is reconnecting, or sends it as a
normal prompt once the turn has ended. The round restarts silently at `maxDuration` if nothing is
said, and closes with the conversation (approval, clarify, sensitive prompt, chat switch, Stop,
Cancel, media key without speech).

**(b) Barge-in during read-aloud — built, wired or Bluetooth headphones.** `bargeInPlaybackAvailable`
is `true` since Task 7 (S2 pass, see "Echo measurement" below). `voice.barge_in_playback` (off by
default) interrupts read-aloud while the routed output device is headphones — wired
(`classifyRoute` reason `'wired'`) or Bluetooth (`'bluetoothHeadphones'`); see "Bluetooth" below.
Over the phone speaker, in the car, or with any other Bluetooth device (`bluetoothOther`,
`bluetoothClassUnknown`), only the steering-wheel / headset media key interrupts read-aloud.

**Bluetooth:** enabled by owner decision 2026-10-20 (Birk, Sony WH-1000XM4,
`bluetoothHeadphones` route) without an echo probe — tracked as **t_fabcb273**, which is now
closed as "not needed". The echo gate itself (p ≥ 0.7, 16 windows, see "Echo measurement" below)
is unchanged.

## Decisions (Birk 14.10.)

Verbatim text in the spec, section "Decisions (Birk 14.10.)" of
`docs/superpowers/specs/2026-10-14-wing-voice-barge-in-design.md`.

- **D1:** "Listen while Hermes works" defaults on, with its own persisted switch; switching it off
  keeps the mic closed while Hermes works.
- **D2:** voice barge-in into read-aloud only with headphones, in general — not only after a failed
  echo measurement. Over the speaker or in the car, only tapping (or the media key) interrupts.
- **D3:** a reply that Birk talked over or barged into is not read further; it stays visible in the
  chat, and "Read aloud" on the message replays it on request.

## Settings

Voice preferences card, below "Conversation mode" (shown only with input route `vad` and
Conversation mode on):

| Key | Default | Choices |
|---|---|---|
| `voice.listen_turn` ("Listen while Hermes works") | `on` | `on` / `off` |
| `voice.listen_min_speech_ms` ("Speech needed to steer") | `400` | `250` / `400` / `600` |
| `voice.barge_in_playback` ("Interrupt read-aloud by speaking") | `off` | `on` / `off`; row shown since `bargeInPlaybackAvailable` is `true` (Task 7) |

The row's subtitle states the current restriction:

| State | Subtitle |
|---|---|
| switch off | "Only with headphones. On the speaker or in the car, tap to stop." |
| switch on | "Only with headphones (wired or Bluetooth). On the speaker or in the car, tap to stop." |

The on-state subtitle shows whenever the switch is on, regardless of whether the Bluetooth
"Nearby devices" permission was granted. Switching the row on still requests `BLUETOOTH_CONNECT`
so a Bluetooth headphone route is recognised without the user reinstalling the permission flow.

Debug only (with "Keep voice recordings" on): text button "Measure speaker echo" — plays a fixed
synthetic German text through the normal TTS path while a listen round records, and logs one
`probe` line (§ below), preceded by one `route` line (§ below). No recognition, no utterances,
nothing shown in the UI.

## Headphone detection

Native raw facts (`HeadphoneRouteChannel.kt`, channel `com.tarkilhk.wing/headphone_route`) feed a
pure Dart verdict (`classifyRoute`, `lib/voice_offline/headphone_route.dart`). Rule (conservative;
anything not listed is "not headphones"):

| Check, in order | Verdict | `reason` |
|---|---|---|
| Android < 13, or the query fails / returns nothing | no | `unsupported` |
| Wing car mode active | no | `carMode` |
| Android car mode (`UI_MODE_TYPE_CAR`) | no | `androidCarMode` |
| Type `TYPE_WIRED_HEADSET` (3), `TYPE_WIRED_HEADPHONES` (4), `TYPE_USB_HEADSET` (22) | **yes** | `wired` |
| Type `TYPE_BLUETOOTH_A2DP` (8) or `TYPE_BLE_HEADSET` (26), class `AUDIO_VIDEO_WEARABLE_HEADSET` (0x0404) or `AUDIO_VIDEO_HEADPHONES` (0x0418) | **yes** | `bluetoothHeadphones` |
| Same types, class unreadable (no permission, anonymised/invalid address, adapter off) | no | `bluetoothClassUnknown` |
| Same types, any other class (car audio, hands-free, uncategorized, …) | no | `bluetoothOther` |
| `TYPE_BUILTIN_SPEAKER` (2) | no | `speaker` |
| Anything else (SCO, hearing aid, BLE speaker, USB device, HDMI, dock, …) | no | `other` |

`HeadphoneRoute.headphones` is the general verdict (wired or Bluetooth headphones) and is what
opens the playback barge-in gate, per "Bluetooth" above. `HeadphoneRoute.wired`
(`reason == 'wired'`) is narrower and no longer used to gate barge-in; it is kept for routes that
still need the wired-only distinction.

The verdict is cached and refreshed when a conversation sends a prompt (so it is fresh when the
reply arrives), on every native audio-device add/remove, and when Wing car mode switches.
Headphones going away while Wing reads aloud closes the playback round
(`listen close reason=route`); headphones coming back opens one, if the other conditions in
"What it does" still hold.

## Echo measurement

S2 (headphones, the gate), measured live by Birk on 2026-10-16, wired headset only:

| Run | p99 | run50 | wouldTrigger |
|---|---|---|---|
| 1 | 0.074 | 0 | 0 |
| 2 | 0.045 | 0 | 0 |
| 3 | invalid (a cough during the run) | – | – |

`wouldTrigger=0` in both valid runs. Pass per the plan's Task 7 table (`run50 ≤ 6` and `p99 < 0.5`
in every valid run).

Decision: S2 pass, bargeInPlaybackAvailable=true, threshold 0.7, windows 16

Getestet nur mit Kabel-Headset. Bluetooth headphones: enabled by owner decision 2026-10-20
without an echo probe (t_fabcb273, closed as "not needed"); the echo gate itself (p ≥ 0.7, 16
windows) is unchanged.

S1 (speaker) and S3 (car) were not run in this session; they are optional and informational only
and do not change the S2 decision.

## Interrupted-reply hint

Birk thinks in stages with long pauses: he speaks, pauses, speaks on. A reply already being read
aloud can then be cut off by his voice (D3: not read further). Wing has no sentence-level
read-aloud progress signal — native playback emits no per-sentence event, and TTS segments are
language runs, not sentences — so the hint carries **no percentage**; a progress figure would need
a separate card.

Wing appends it after a blank line to the text of an utterance **only** when that utterance's
listen round fired the playback gate (a voice barge-in into read-aloud) and the utterance is
delivered as `send` or `queue` (also after a rejected steer). Never on a `steer`, never on a
listen-round utterance without a barge-in, never on manual dictation or a media-key interruption.

```
[Hinweis von Wing: Die vorige Antwort wurde beim Vorlesen abgebrochen und nicht zu Ende gehört.]
```

The hint becomes part of the user's own chat message, so it is visible in Birk's own row. Logs
never contain it or any other text: the delivery line only gets `hint=<0|1>`.

**Model side (Task 18, [WORKER], outside this card's scope):** one sentence appended to
`platform_hints.wing.append` in `/home/birk/.hermes/profiles/birk/config.yaml` (outside this repo),
asking Hermes to fold the unheard points of the previous reply into the next one.

## Gateway

Verified against upstream `NousResearch/hermes-agent` `main` at commit `1fdbf49b` (read via the
GitHub contents API on 2026-10-16; the three expected patterns — `"rejected"`,
`_session_compression_in_flight`, `_correction_method("session.steer"` — are present in
`tui_gateway/methods_session_interrupt.py`).

- `session.steer {session_id, text}` → `queued` while the session is `running`/`attention`, or
  `rejected` if the session is not running (Wing then re-decides and queues or sends the text as a
  normal prompt). Compression in flight queues the text as a normal prompt instead and still
  answers `queued`.
- A steer that arrives while the model writes its **final** answer is not lost: `AIAgent` hands it
  back as `pending_steer`, and the gateway enqueues it and starts a **follow-up turn** right after
  `message.complete`. Wing treats that follow-up as its own conversation turn (keeps listening,
  `_bargeIn.steered`) instead of ending the conversation.
- No event announces an accepted steer; Wing records it itself as a `display_kind: 'steer'` user
  row.

## Log lines

Prefix `WingBargeIn`, via `debugPrint`. Never transcript, reply, prompt or hint text, session ids,
Bluetooth addresses or device names — only events, durations, lengths, numeric device types and
classes, and statuses.

```
WingBargeIn listen open mode=<turn|playback>
WingBargeIn listen restart reason=<maxDuration>
WingBargeIn utterance segmentMs=<n> textLen=<n>
WingBargeIn deliver kind=<steer|queue|send|drop> result=<queued|rejected|ok|filler|empty> hint=<0|1>
WingBargeIn barge trigger sinceOnsetMs=<n> stopMs=<n>
WingBargeIn barge reject runWindows=<n>
WingBargeIn route headphones=<0|1> reason=<unsupported|carMode|androidCarMode|wired|bluetoothHeadphones|bluetoothClassUnknown|bluetoothOther|speaker|other> type=<n> btClass=<0xNNNN|none> androidCarMode=<0|1>
WingBargeIn probe windows=<n> max=<p> p50=<p> p95=<p> p99=<p> run50=<w> run70=<w> wouldTrigger=<0|1> source=<VOICE_COMMUNICATION|VOICE_RECOGNITION>
WingBargeIn listen close reason=<turnEnd|conversationEnd|mediaKey|dictate|stopButton|route|probe|dispose|error>
```

`hint=` appears on `send` and `queue` lines only. A `route` line is logged only when the verdict or
its inputs change, not on every refresh.

## Limits

- A steer that arrives during a long-running tool waits until that tool returns; Hermes never
  kills a tool to deliver guidance.
- A compression-queued text is still shown in the chat as a steer row, even though the server runs
  it as the next prompt rather than an in-flight correction. The text still reaches the agent, so
  this is a known, accepted display inaccuracy.
- A dropped utterance (empty or filler-only, e.g. "ähm") has already produced the endpointer's
  "got it" tone before the transcript filter rejects it; this is accepted and documented, not a bug.
- The echo probe logs the *configured* audio source; if `VOICE_COMMUNICATION` fails to initialise,
  Kotlin falls back to `VOICE_RECOGNITION` without telling Dart which one actually recorded.
- A car on an AUX cable looks like wired headphones; only Wing car mode or Android car mode closes
  the gate then.
- Bluetooth headphones with an unreadable or unusual class (`bluetoothClassUnknown`,
  `bluetoothOther`) still do not count as headphones and do not open the barge-in gate.
- The hint is visible in the user's own message; there is no separate system note for it.

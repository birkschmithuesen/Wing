# Voice barge-in: listen while Hermes works

Spec: `docs/superpowers/specs/2026-10-14-wing-voice-barge-in-design.md`. Plan:
`docs/superpowers/plans/2026-10-14-wing-voice-barge-in.md`. Card: t_7e81e040 (design),
implemented on t_ccaad8af.

## What it does

**(a) Listen while Hermes works — built.** On the `vad` input route, with Conversation mode
and "Listen while Hermes works" on, the microphone stays open for the whole turn instead of
closing after the auto-sent dictation. A `TurnListener` runs continuous VAD "listen rounds" on
the same `VoiceDevice`; each utterance is handed to a `BargeInCoordinator`, which steers it into
the running turn (`session.steer`), queues it while the gateway is reconnecting, or sends it as a
normal prompt once the turn has ended. The round restarts silently at `maxDuration` if nothing is
said, and closes with the conversation (approval, clarify, sensitive prompt, chat switch, Stop,
Cancel, media key without speech).

**(b) Barge-in during read-aloud — not built (gated behind Task 6/7, this card does not include
them).** `bargeInPlaybackAvailable` stays `false`, and `voice.barge_in_playback` has no effect yet.
The steering-wheel / headset media key remains the only way to interrupt read-aloud.

**D1-D3 (ANNAHME Birk-Gate, confirmed 2026-10-14):**
- D1: "Listen while Hermes works" defaults **on** for Conversation mode on the vad route.
- D2: if the echo measurement ever fails in the car, read-aloud there is interrupted only with
  the steering-wheel media key; this does not block (a).
- D3: a reply that the user talked over or barged into is **not** read aloud or resumed; it stays
  visible in the chat, and "Read aloud" on the message replays it on request.

## Settings

Voice preferences card, below "Conversation mode" (shown only with input route `vad` and
Conversation mode on):

| Key | Default | Choices |
|---|---|---|
| `voice.listen_turn` ("Listen while Hermes works") | `on` | `on` / `off` |
| `voice.listen_min_speech_ms` ("Speech needed to steer") | `400` | `250` / `400` / `600` |
| `voice.barge_in_playback` ("Interrupt read-aloud by speaking") | `off` | `on` / `off`; row hidden until `bargeInPlaybackAvailable` is `true` |

Debug only (with "Keep voice recordings" on): text button "Measure speaker echo" — plays a fixed
synthetic German text through the normal TTS path while a listen round records, and logs one
`probe` line (§ below). No recognition, no utterances, nothing shown in the UI.

## Gateway

Verified against upstream `NousResearch/hermes-agent` `main` at commit `e06df9c2` (read via the
GitHub contents API on 2026-10-14; the three expected patterns — `"rejected"`,
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

Prefix `WingBargeIn`, via `debugPrint`. Never transcript, reply or prompt text, or session ids —
only events, durations, lengths and statuses.

```
WingBargeIn listen open mode=<turn|playback>
WingBargeIn listen restart reason=<maxDuration>
WingBargeIn utterance segmentMs=<n> textLen=<n>
WingBargeIn deliver kind=<steer|queue|send|drop> result=<queued|rejected|ok|filler|empty>
WingBargeIn barge trigger sinceOnsetMs=<n> stopMs=<n>
WingBargeIn barge reject runWindows=<n>
WingBargeIn probe windows=<n> max=<p> p50=<p> p95=<p> p99=<p> run50=<w> run70=<w> wouldTrigger=<0|1> source=<VOICE_COMMUNICATION|VOICE_RECOGNITION>
WingBargeIn listen close reason=<turnEnd|conversationEnd|mediaKey|dictate|stopButton|probe|dispose|error>
```

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

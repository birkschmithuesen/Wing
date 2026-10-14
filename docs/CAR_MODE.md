# Car mode

Open a chat → ⋮ → **Car mode**. The whole screen becomes one button for the open chat. The screen stays on until
you leave; that is part of car mode, not an option.

**Conversation mode off (the usual car mode):** tap to start recording, tap again to send. There is no automatic end
of speech. Every reply is read aloud; afterwards the microphone stays closed until you tap.
**Conversation mode on:** the conversation loop runs as usual; a tap while listening sends at once.
Car mode never changes either setting.

| Shown | A tap does |
|---|---|
| Tap to talk | starts recording |
| Listening | ends the recording now and sends it |
| Got it | nothing |
| Hermes is working | starts recording; what you say steers the running reply (queued if Hermes can't take it now) |
| Reading aloud | stops reading and starts recording |
| Waiting for connection | starts recording; it is added to the waiting text and sent with it |
| Needs you on screen | nothing; approve or answer in the chat when parked |
| Didn't work | starts recording again |

On the button: the connection (Connected / Reconnecting / Offline, large and coloured) and what Hermes is working on
(e.g. "Terminal"). Tool arguments and commands are never shown. Losing the connection vibrates three times; getting
it back vibrates twice.

**Offline:** a recording finished without a connection stays as the chat draft on the phone. It is sent once when
the connection is back. Leaving car mode before that keeps it as the draft, unsent.

**Leaving:** Android Back, or swipe sideways across the screen. A swipe never starts or sends a recording. Leaving:
- cancels a recording without sending;
- stops reading aloud;
- leaves a running reply alone.

**Logs** (`adb logcat -s flutter`, prefix `WingCar`): `enter route=… loop=…`, `tap phase=… action=…`,
`stopSpeech ms=…`, `deliver kind=…`, `connection state=…`, `hold`, `release`, `swipe action=…`, `exit reason=…`.
They never contain text, titles or tool names.

**Limits:**
- Wing must be in the foreground; another app in front ends a running recording.
- `local` input route: Android's recognizer ends on silence by itself, and car mode sends that result.
- `hermes` input route: needs the connection to transcribe; offline it fails.
- A recording that reaches the maximum length (default 10 min) is not sent; it stays in the draft.
- After a queued (not steered) utterance in Conversation mode, the microphone stays closed until you tap.
- Vibration follows Android's touch-vibration setting.

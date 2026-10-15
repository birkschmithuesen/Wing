# Talk to Wing

Wing can turn speech into an editable message and read an assistant reply aloud.

## Choose where speech is processed

Open **App settings → Voice**. Choose **Local** or **Hermes** separately for dictation and read-aloud. Local dictation needs Android 12 or newer and a supported on-device recognition service and language; local reading needs an installed offline Android voice. Wing shows an error if your chosen engine is unavailable rather than switching engines without asking.

**On this phone · Parakeet** records with Wing's own capture from the input Android currently routes (normally the
phone's built-in microphone), detects the end of each message with Silero VAD and recognizes the speech on the phone
with Parakeet TDT 0.6B v3 (sherpa-onnx). No audio leaves the phone. The speech model (487 MB download, about 670 MB
installed) is downloaded once in App settings → Voice and checked against its published SHA256. "Pause detection"
sets how long a pause ends a message (default 1.8 s), how long Wing waits for you to start speaking (default 8 s),
the minimum speech, the lead-in kept before speech and the longest recording (10, 15, 20 or 30 minutes, default 10;
long dictations are recognized in pieces of up to 30 seconds, cut at pauses). On this route the steering-wheel or
headset play/pause key ends the current message or starts a new one, and short cue tones mark "listening" and
"got it". During Conversation mode the screen stays on. On the VAD input you can also switch the screen off or
pocket the phone: the conversation continues, and a "Conversation mode" notification with Stop shows
it. With "Listen while Hermes works" on, the microphone also stays open while Hermes works with the
screen off, so you can steer from your pocket; the notification then reads "Microphone is listening."
Switch that setting off to keep the microphone closed until the reply has been read. Interrupting the
read-aloud by speaking still needs headphones. Staying silent after a reply (the "Wait for speech"
time) ends the conversation, as do a phone call, Stop and swiping the notification away. Car mode
always keeps the screen on.

Hermes speech uses the selected server profile's providers and voice settings. To change those shared profile settings, follow the link from App settings to **Profile → Voice** in Administration.

## Dictate and listen

Tap the composer microphone, speak, then tap **Stop recording**. The words appear in your draft for review and editing; Wing never sends them automatically. Use **Read aloud** on an assistant reply to hear its prose, or **Stop speech** to end playback. Recording and playback stop when you leave the foreground or change chats.

[Voice setup details](PROFILE_VOICE.md) · [Privacy](../PRIVACY.md)

Car mode (one big talk button for driving): see [CAR_MODE.md](CAR_MODE.md).

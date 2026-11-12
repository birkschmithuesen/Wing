# Talk to Wing

Wing supports live conversations, speech-to-text dictation and reading replies aloud.
For live conversations, first [install and enable the Wing plugin](WING_PLUGIN.md)
in the chat's Hermes profile.

## Choose where speech is processed

Open **App settings → Voice**. Choose **Local** or **Hermes** separately for dictation and read-aloud. Local dictation needs Android 12 or newer and a supported on-device recognition service and language; local reading needs an installed offline Android voice. Wing shows an error if your chosen engine is unavailable rather than switching engines without asking.

Hermes speech uses the selected server profile's providers and voice settings. To change those shared profile settings, follow the link from App settings to **Profile → Voice** in Administration.

Fork additions (on-device VAD dictation, car mode): see [VAD_INPUT.md](VAD_INPUT.md) and [CAR_MODE.md](CAR_MODE.md).

## Dictate and listen

Tap the composer microphone, speak, then tap **Stop recording**. The words appear in your draft for review and editing; Wing never sends them automatically. Use **Read aloud** on an assistant reply to hear its prose, or **Stop speech** to end playback. Recording and playback stop when you leave the foreground or change chats.

### Wing Voice (fork)

Conversation mode (opt-in) sends dictations automatically. The system-recognizer fallback stays inside Local and never switches to Hermes. The maximum dictation duration is 10 minutes.

[Voice setup details](PROFILE_VOICE.md) · [Privacy](../PRIVACY.md)

## Live conversations

Live conversations are available in ordinary chats and Bot Chats. Group
discussions cannot start a live call; browsing a group keeps an existing call
connected to its original chat.

In **App settings → Voice → Live conversation**, choose **ChatGPT subscription**
or **OpenAI API**. Subscription uses the selected Hermes profile's ChatGPT sign-in
and plan voice limits. API uses that profile's OpenAI voice API key and bills
usage to its API account. Wing never switches billing modes automatically. A
changed choice applies to the next call.

Choose **GPT-Live voice** below the mode selector. Wing remembers separate
subscription and API voices on this phone, including in settings backups. This
choice does not change Android read-aloud voices or the Hermes profile defaults.
Use the current Wing plugin to enable voice selection.

Tap the speaker beside **GPT-Live voice** to preview any subscription voice,
then tap Stop to end the sample. These recordings use the same sentence as
Android voice previews and play offline, without a microphone, server connection
or voice usage charge. API voice previews are not available yet. Changing a
setting or leaving the page stops playback.

Both live modes require the **Wing plugin** (`wing`) installed and enabled
for the chat's Hermes profile. Enabling it in `default` does not enable it in
other profiles. The plugin uses current stock Hermes and, for subscription mode, the profile's
`openai-codex` login; it requires no core patch. Live conversations use the
standalone [Wing plugin](https://github.com/tarkilhk/wing-hermes-plugin).

API mode uses the plugin to add the native context to voice startup. Its
configuration comes from the profile's `voice.gpt_live` settings and Hermes's
supported OpenAI key resolver. Credentials stay on the server in both modes.

Open a connected chat and tap **Start voice conversation** (the waveform icon beside the microphone in the message field).
The floating call card stays above the app while you navigate. Its compact row
shows the original chat title, voice duration, mute, audio routing and End voice.
Headsets are preferred when connected; the speaker control can select the phone
speaker or return to headset/earpiece routing.

In the original chat, spoken text appears in the conversation. After you enter
another chat or group, the card adds a compact lower row with captions and
**Return to voice chat** (the speech bubble with a waveform). Captions start off;
when enabled they share the row with the controls and scroll within two lines.
Returning keeps the call connected and hides both extra controls. Captions reset
off when you return or start another call. Browsing a list or opening a menu
alone does not count as entering a different conversation.

You can switch apps or lock the phone during a call. Allow microphone and
notification access; Bluetooth access enables headset routing. The persistent
notification provides Mute and End voice. Incoming calls or loss of audio focus
end voice; start a new call when ready.

Voice requests use the original chat's queue and steering controls, preserving
any typed draft. Review approvals and other required input in that chat. Talking
over speech or ending the call leaves Hermes work running. In either mode, say
**“stop the task”**, **“cancel the task”** or **“stop working”** to explicitly request
cancellation; the chat's existing Stop control is also available. Requests delegated by GPT-Live
are passed as text to the normal Hermes agent, which owns tool execution.
Ordinary spoken exchanges do not automatically submit Hermes tasks.
New queued voice requests include recent speech through Hermes's native live-voice
context fields. Steering uses the running turn's existing context. Replies return
to the originating voice delegation; unrelated typed work is not read aloud.

Long context and result updates are split to fit the voice service's limit.
A rejected update does not end a connected call. Connection loss and session
expiry have separate messages; an unexplained closure does not imply a quota limit.

Live audio goes directly to OpenAI over WebRTC. Relevant chat context and agent
results also reach the chosen voice service. Captions stay in memory; delegated
requests and Hermes replies use the chat's normal history. The complete spoken
exchange is not yet saved there. Voice startup receives Hermes’s cached or saved profile prompt, including SOUL
and saved memory. A brand-new chat uses Hermes’s native profile inspector;
deeper memory retrieval goes through normal Hermes delegation. Saving every
spoken turn still awaits native Hermes support.

### Why the full spoken conversation is not saved

This is a current Hermes limitation: Wing needs a supported operation to record
an externally spoken user or assistant turn without generating another reply.
Hermes's normal task submission records its own work and answer, but not the
separate words GPT Live speaks. The Wing plugin does not remove this limitation.

The exact request is [Hermes issue #121045](https://github.com/NousResearch/hermes-agent/issues/121045).
Its earlier implementation, [PR #121056](https://github.com/NousResearch/hermes-agent/pull/121056),
was closed without merging. The related [PR #87053](https://github.com/NousResearch/hermes-agent/pull/87053)
proposes persisting plugin chat messages without starting a model turn and remains
open and unmerged as of 9 November 2026. It is a related proposal, not a shipped
solution to Wing's full spoken-history and memory requirements.

Live voice shows your speech and GPT-Live’s spoken replies in the original chat.
These entries are labelled “Not saved to Hermes” and can be copied. They remain
after ending the call or switching chats while Wing is running, but are lost
when Wing restarts. They do not yet update Hermes’s shared history or memory.

Hermes replies to tasks submitted by voice appear under **Hermes task details**
in the current chat reading. Expand it for the original result and its normal
actions. GPT-Live’s spoken answer remains a separate voice entry. Hermes still
saves its task results normally; the local grouping and spoken transcript do not
change shared history.

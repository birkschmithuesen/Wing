# Talk to Wing

Wing can turn speech into an editable message and read an assistant reply aloud.

## Choose where speech is processed

Open **App settings → Voice**. Choose **Local** or **Hermes** separately for dictation and read-aloud. Local dictation needs Android 12 or newer and a supported on-device recognition service and language; local reading needs an installed offline Android voice. Wing shows an error if your chosen engine is unavailable rather than switching engines without asking.

Hermes speech uses the selected server profile's providers and voice settings. To change those shared profile settings, follow the link from App settings to **Profile → Voice** in Administration.

## Dictate and listen

Tap the composer microphone, speak, then tap **Stop recording**. The words appear in your draft for review and editing; Wing never sends them automatically. Use **Read aloud** on an assistant reply to hear its prose, or **Stop speech** to end playback. Recording and playback stop when you leave the foreground or change chats.

[Voice setup details](PROFILE_VOICE.md) · [Privacy](../PRIVACY.md)

## Live conversations

In **App settings → Voice → Live conversation**, choose **ChatGPT subscription**
or **OpenAI API**. Subscription uses the selected Hermes profile's ChatGPT sign-in
and plan voice limits. API uses that profile's OpenAI voice API key and bills
usage to its API account. Wing never switches billing modes automatically. A
changed choice applies to the next call.

Both live modes require the **Wing plugin** (`wing`) installed and enabled
for the chat's Hermes profile. Enabling it in `default` does not enable it in
other profiles. The plugin uses current stock Hermes and, for subscription mode, the profile's
`openai-codex` login; it requires no core patch. Live conversations use the
standalone [Wing plugin](https://github.com/tarkilhk/wing-hermes-plugin).

API mode uses the plugin to add the native context to voice startup. Its
configuration comes from the profile's `voice.gpt_live` settings and Hermes's
supported OpenAI key resolver. Credentials stay on the server in both modes.

Open a connected chat and tap **Start voice conversation** (the waveform icon).
The call dock shows connecting, listening, muted and failure states. Use its
icons to mute, change audio routing, show captions, return to the original chat,
or end voice. Headsets are preferred when connected; the speaker control can
select the phone speaker or return to headset/earpiece routing.

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

Live voice shows your speech and GPT-Live’s spoken replies in the original chat.
These entries are labelled “Not saved to Hermes” and can be copied. They remain
after ending the call or switching chats while Wing is running, but are lost
when Wing restarts. They do not yet update Hermes’s shared history or memory.

Hermes replies to tasks submitted by voice appear under **Hermes task details**
in the current chat reading. Expand it for the original result and its normal
actions. GPT-Live’s spoken answer remains a separate voice entry. Hermes still
saves its task results normally; the local grouping and spoken transcript do not
change shared history.

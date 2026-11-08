<p align="center">
  <a href="https://tarkilhk.github.io/Wing/">
    <img src="docs/images/wing-readme-hero-tagline.png" alt="Wing: Your agent, with you. Visit the Wing website." width="1000">
  </a>
</p>

# Wing for Android

Wing is an open-source Android companion for [Hermes Agent](https://github.com/NousResearch/hermes-agent). Work with your agent from your phone while it runs on your server.

[**Download Wing**](https://github.com/tarkilhk/Wing/releases/latest) · [**Explore Wing**](https://tarkilhk.github.io/Wing/)

Requires Android 7.0 or newer and a Hermes server you can reach from your phone.

## Switch between profiles and projects

Tap a profile to focus its chats, or combine profiles in one view. Choose projects, group and sort conversations, and select the details you want to see. Wing remembers your view for each connection.

<p align="center">
  <a href="https://tarkilhk.github.io/Wing/workspaces.html">
    <img src="website/assets/screenshots/profiles-light.png" alt="Wing profile switcher with the personal profile selected and the Profile filter open" width="260">
  </a>
</p>

[Profile switching and view controls](https://tarkilhk.github.io/Wing/workspaces.html)

## Multitask with Recents

Find running chats and conversations waiting for your input across profiles. From any chat or group discussion, swipe sideways with two fingers to switch, or pinch into a card stack and tap another conversation. Unread cues help you spot new replies while working elsewhere.

<p align="center">
  <a href="https://tarkilhk.github.io/Wing/recents.html">
    <img src="website/assets/screenshots/recents-stack-dark.png" alt="Wing Recents card stack with conversation previews for switching chats" width="260">
  </a>
</p>

[Explore Recents and gestures](https://tarkilhk.github.io/Wing/recents.html)

## Bots and group discussions

Find bots across your saved connections and return to each bot's continuing chat. Pin favorites and give each one a distinct name and appearance. Bring 2–6 bots into a shared discussion with a shared purpose and routing choices. Follow member progress and extend a discussion when it needs more rounds. Hermes coordinates the work on your server, so it can continue after Wing closes.

<p align="center">
  <a href="https://tarkilhk.github.io/Wing/bots.html">
    <img src="website/assets/screenshots/bots-dark.png" alt="Wing Bots roster with distinct avatars, a pinned bot and working or needs-input states" width="260">
  </a>
</p>

[Explore Bots](https://tarkilhk.github.io/Wing/bots.html)

## Take over your agent's desktop

Open a bot's screen, take control and use your phone's keyboard, touch gestures or clipboard to finish a step yourself. Keep the conversation beside the desktop, then hand control back with a note asking the agent to continue. Requires a configured Hermes Bot Screen.

[Explore desktop control](https://tarkilhk.github.io/Wing/bots.html#screen)

## Live work

Follow reasoning and timed tool runs as an answer streams. Open Tasks or Subagents to inspect progress, read a child's conversation and use its supported controls. Steer or stop a run, queue a follow-up, or fork from a saved answer once the chat is idle. Add server files with @ and choose skills with / while composing.

<p align="center">
  <a href="https://tarkilhk.github.io/Wing/live-work.html">
    <img src="website/assets/screenshots/activity-dark.png" alt="Wing Activity with Timeline, Tasks and Agents tabs, and an expanded tool call showing its code and output" width="260">
  </a>
</p>

[Explore live work](https://tarkilhk.github.io/Wing/live-work.html)

## Talk to your agent

Talk to your agent through **GPT Live using your ChatGPT subscription**. Ask
Hermes to do work and hear the results while you move between apps or lock your
phone. Separately billed OpenAI API access is also available. Start from
an ordinary chat or a Bot Chat using the waveform beside the message microphone.
A compact floating call card keeps the duration and controls available as you
navigate. Enter another conversation to reveal captions and a return-to-chat
control; the call stays with its original chat. Group discussions do not offer
live voice.

**Requires the [Wing plugin for Hermes](docs/WING_PLUGIN.md)** installed and
enabled on your server for that profile. Updating the Android app does not
install the server plugin.

<p align="center">
  <a href="https://tarkilhk.github.io/Wing/voice.html">
    <img src="website/assets/screenshots/live-voice-dark.png" alt="Sample GPT Live conversation in Wing with spoken messages and the compact floating call card" width="260">
  </a>
</p>

Full GPT Live conversations are not yet saved to Hermes history or memory because
Hermes does not yet expose the supported recording operation Wing needs for
externally spoken turns. Delegated task results are saved normally. Follow
[the upstream request](https://github.com/NousResearch/hermes-agent/issues/121045)
and [the related persistence PR](https://github.com/NousResearch/hermes-agent/pull/87053)
(still unmerged when checked on 9 November 2026).

Choose a GPT-Live voice in App settings, with separate saved choices for
subscription and API calls. Preview subscription voices offline before calling;
API voice previews are not available yet. Changes apply to your next call.

[Explore live voice and setup](https://tarkilhk.github.io/Wing/voice.html)

## Add the Wing plugin to Hermes

The **Wing plugin for Hermes** is a separate, open-source server plugin that adds
GPT Live conversations and email draft cards to Wing. Open **App settings → Hermes
→ Wing plugin** to install, enable or update it for each profile where you want
these features. Check the result for any required restart and start a new chat
to use newly enabled tools. Ordinary chats, dictation and read-aloud work without it.

[Explore the plugin and setup](https://tarkilhk.github.io/Wing/wing-plugin.html) · [Plugin source](https://github.com/tarkilhk/wing-hermes-plugin)

## Draft an email, then send it from your phone

With the Wing plugin's email tool enabled, ask Hermes for a draft. Review its
recipients, subject and body in a native card, then open it in your chosen email
app to edit and send. Ask for revisions without changing older cards. No email
account connection to Hermes or voice subscription is required.

[Email draft cards](docs/WING_PLUGIN.md#draft-an-email)

## Answers and files

Read wide tables as grids, with horizontal scrolling when needed, or switch to stacked rows. Open reading mode or turn the phone sideways for more room. Copy highlighted code or whole replies, listen to answers, and preview, save or share files. Edit an earlier message, or restore its checkpoint after confirming removal of later history.

<p align="center">
  <a href="https://tarkilhk.github.io/Wing/results.html">
    <img src="website/assets/screenshots/results-light.png" alt="Wing answer with formatted Markdown, a table, code controls and an output file to download or preview" width="260">
  </a>
</p>

[Explore answers and files](https://tarkilhk.github.io/Wing/results.html)

## Administration

Manage models, instructions, skills, connectors and scheduled tasks for each profile.

<p align="center">
  <a href="https://tarkilhk.github.io/Wing/administration.html">
    <img src="website/assets/screenshots/administration-dark.png" alt="Wing Administration with profile switching, model settings, agent instructions, skills, connectors and scheduled tasks" width="260">
  </a>
</p>

[Explore Administration](https://tarkilhk.github.io/Wing/administration.html)

## Scheduled work

Schedule recurring or one-off work on Hermes, set its timezone and missed-run policy, and deliver results to a bot group. Stop a current run without disabling its schedule and inspect recent runs. When a task fails, open an investigation chat with the responsible profile.

[Explore scheduled tasks](https://tarkilhk.github.io/Wing/scheduled-tasks.html)

## Health

Check host resources, backend diagnostics and profiles. Set alerts for resource pressure or profile problems, then inspect notifications from any screen. Checks run while Wing is open or monitoring ongoing work.

<p align="center">
  <a href="https://tarkilhk.github.io/Wing/health.html">
    <img src="website/assets/screenshots/health-light.png" alt="Wing Health with Alert settings, host resources, server diagnostics and profile checks" width="260">
  </a>
</p>

[Explore Health](https://tarkilhk.github.io/Wing/health.html)

## Analytics

Compare activity, token usage and estimated cost across all profiles on an instance, or focus on one profile, model or time period.

<p align="center">
  <a href="https://tarkilhk.github.io/Wing/usage.html">
    <img src="website/assets/screenshots/analytics-dark.png" alt="Hermes analytics showing daily activity, token totals, model breakdowns and token trends" width="260">
  </a>
</p>

[Explore Analytics](https://tarkilhk.github.io/Wing/usage.html)

## Install and connect

1. Download the signed APK from the [latest release](https://github.com/tarkilhk/Wing/releases/latest). Choose **arm64-v8a** for most current phones.
2. Follow the [connection guide](https://tarkilhk.github.io/Wing/get-started.html) to connect your Hermes dashboard and Desktop Gateway, choose a profile and send your first message.

For server and proxy configuration, see [self-hosting](docs/SELF_HOSTING.md). Your Hermes setup needs a configured model provider; your server and providers may have their own costs.

## Help and contribute

[Report an issue](https://github.com/tarkilhk/Wing/issues) · [Contributing](CONTRIBUTING.md) · [User guides](docs/README.md) · [Changelog](CHANGELOG.md) · [Security](SECURITY.md) · [Privacy](PRIVACY.md)

## Support Wing

[Sponsor on GitHub](https://github.com/sponsors/tarkilhk) · [Buy me a coffee](https://ko-fi.com/tarkil)

[MIT license](LICENSE) · [Third-party notices](NOTICE.md)

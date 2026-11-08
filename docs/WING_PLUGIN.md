# Set up the Wing plugin for Hermes

The Wing plugin for Hermes adds live voice conversations and structured email draft cards
to Wing through your Hermes server. It is a separate, optional server plugin.
Installing or updating the Android app does not install it on Hermes. Ordinary
text chats, dictation and read-aloud work without it.

The plugin runs on current upstream Hermes (at least 0.23.0), with its
dashboard/gateway reachable from Wing. Use Wing 1.4.1 or newer and the latest
stable [Wing plugin release](https://github.com/tarkilhk/wing-hermes-plugin/releases/latest).
The plugin's version is separate from Wing's Android version.

## Install from your phone

1. Connect to the Hermes server you want to change. Open **App settings → Hermes
   → Wing plugin** to enter the dedicated manager.
2. Review the installed versions and latest release. Expand **Profiles** to see
   which profiles need installation, an update or enabling.
3. Use the action beside the profile where you want voice or email drafts. You
   can instead use the all-profiles action to install or update across the server.
   Review any confirmation before continuing.
4. Read the result for each profile. Restart the serving Hermes process if its
   result requires it. Open a new chat so newly enabled tools are available.

Install and enable the plugin in every profile where you want these features.
Enabling it in `default` alone does not enable it in your other profiles.
Opening the manager never installs or updates anything automatically.

For command-line setup, the plugin's [installation instructions](https://github.com/tarkilhk/wing-hermes-plugin#install)
include both default and named profiles. Its [source repository](https://github.com/tarkilhk/wing-hermes-plugin)
also documents requirements and credits.

## Start a live conversation

In **App settings → Voice → Live conversation**, choose the account mode:

| Mode | Required in the chat's Hermes profile | Billing |
| --- | --- | --- |
| ChatGPT subscription | OpenAI Codex sign-in with voice access | Your ChatGPT plan's voice allowance |
| OpenAI API | OpenAI voice credentials | Separate API account usage |

Both modes need the Wing plugin enabled in that same profile. Wing does not
switch modes automatically. A change applies to the next call.

Open a connected ordinary chat or Bot Chat and tap **Start voice conversation**, the waveform beside
the dictation microphone inside the message field. Allow microphone and
notification access; allow Bluetooth access if using a headset. The floating call
card shows the original chat title, duration, mute, audio routing and End voice.
Entering another conversation reveals captions and **Return to voice chat**;
returning hides those controls and resets captions off without ending the call.
Group discussions cannot start live calls.

Choose **GPT-Live voice** below the mode selector in App settings. Wing remembers
separate subscription and API choices on this phone; changes apply to the next
call. With the current plugin, the chosen voice is used without changing the
Hermes profile defaults. Preview subscription voices with the speaker beside the
picker: bundled samples play offline without microphone access, a server
connection or voice usage charges. API previews are not available yet.

The voice service can delegate tasks to your Hermes agent. Handle approvals
and questions in the originating chat. Ending voice does not stop accepted
Hermes work; say “stop the task” or use the chat's Stop control to cancel it.

Audio goes directly to OpenAI, together with relevant context and task results.
Provider credentials stay on Hermes. Local speech entries marked **Not saved
to Hermes** disappear when Wing restarts; complete spoken exchanges are not yet
saved to shared history or memory because Hermes lacks the supported recording
operation Wing needs for external voice turns. Installing the plugin does not
remove this limitation. Hermes saves its delegated task results normally.
See the [upstream proposals and their status](VOICE.md#why-the-full-spoken-conversation-is-not-saved). See the [voice guide](VOICE.md) for details and controls.

## Draft an email

Enable the plugin's **wing_email** toolset for the profile and start a new chat.
For example, ask: “Draft an email to Alex at alex@example.com asking to move
our meeting to Thursday afternoon.” Hermes needs to use the draft tool and
include its card reference for Wing to display a card.

Review the card's recipients, subject and body. Tap the envelope-arrow action
and choose an Android email app. The draft opens there with its fields filled
in, including any CC or BCC recipients. Edit and send in that app. Wing and the
plugin do not send the email or need access to your email account.

Ask Hermes to revise the draft to get a new version. Old cards keep the text
and recipients they originally showed. Drafts stay in the selected Hermes
profile. Email cards need neither an OpenAI account nor a voice subscription.

## Update and recover

Use **Refresh** to read installed state and check the latest GitHub release.
The manager explains network errors, timeouts, rate limits and invalid release
responses. A failed GitHub check keeps installed information visible and blocks
updates that cannot be verified; resolve the error and refresh before retrying.
A profile with an unknown state needs its own refresh before an action is offered.

New installations are pinned to the exact published release commit. Replacing
an existing pinned copy asks you to confirm the target and affected profiles.
An unpinned copy follows its configured branch or catalog, which may not yet
match GitHub's latest release. A current profile has no update action.

If Hermes requires a forced reinstall, read its confirmation: caution-level
scan warnings may be accepted, while dangerous findings remain blocked. A
refusal retains the server's explanation. After an uncertain write or readback,
refresh before repeating the action. Do not assume an unavailable version means
the plugin is missing.

You can return to App settings and reopen the manager to follow its progress.
Leaving settings or switching servers stops changes that have not been sent;
a command already sent to Hermes may still complete. Check each profile's
result, including any restart instruction. One failed profile does not block
maintenance of another whose state has been verified.

[All guides](README.md) · [Voice](VOICE.md) · [Privacy](../PRIVACY.md)

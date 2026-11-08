# Voice conversations, dictation and replies

Choose device or Hermes processing, dictate into an editable draft and play a reply; cancel, recover a missing capability or failure, and prevent capture/playback conflicts.

Feature ID: `voice`.

## Sub-features

- `voice.live` — Choose subscription or API GPT-Live, start in the current chat and keep an elevated compact call card above navigation. Mute, change audio routing, end voice and continue under lock. Entering another chat or group reveals captions and Return to voice chat in its lower row; returning hides them and resets captions off. Captions scroll within two lines without enlarging the normal control row.
- `voice.transcript` — Read both spoken sides in the original chat during and after a call. Local voice rows are labelled “Not saved to Hermes”, support Copy, and last until Wing restarts. They do not submit work. Hermes replies to voice-submitted tasks are collapsed under “Hermes task details”, with native actions inside.
- `voice.live-work` — Delegate once into the original chat; send recent spoken context with new work through Hermes’s native voice surface; match replies to their work admission and provider delegation. Interrupt speech independently of work.
- `voice.dictate` — Finish or cancel into the correct draft.
- `voice.speak` — Start stop or interrupt reply playback.
- `voice.recover` — Handle permission, capability and provider failure; distinguish a missing plugin from server authentication and provider access failures. Rejected provider updates remain visible without ending a connected call; closure messages describe the received reason without assuming account limits.

- `voice.live-voice` — Choose a GPT-Live voice in the existing Voice settings; retain separate subscription/API choices on the phone. Apply changes to the next call and report an unsupported plugin voice before negotiation.

- `voice.live-preview` — Play or stop a bundled sample of the selected subscription voice beside its settings picker, offline without microphone access or provider usage. API previews are explicitly unavailable. Changing settings, leaving the page or backgrounding stops playback.

## How to get to it (user POV)

In App settings → Voice choose ChatGPT subscription or OpenAI API for live conversation, choose its GPT-Live voice, then tap the waveform icon beside the microphone in a connected chat’s message field. Subscription requires the standalone Wing plugin (`wing`) enabled in the chat’s profile and that profile's Codex sign-in. Enablement in `default` does not enable other profiles. API mode also requires the Wing plugin, using Hermes’s native voice configuration and the profile’s API credentials. The app-wide floating call card and persistent Android notification expose call controls.

For dictation/read-aloud, in App settings choose device or Hermes input/output. Tap the chat or group microphone to dictate into an editable draft, and use a reply playback action to hear it. Stop or cancel explicitly.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  The controller tests cover explicit subscription/API billing modes, no billing
  fallback, profile binding, safe errors and retirement during negotiation.
  Settings checks select a voice, switch modes, reopen the page, and retain both
  choices independently of Android speech. Preview checks hold asset loading through Stop, selection, background and route closure; verify failure/retry and replacement by Android speech; inspect loading and playback through the production settings control. Startup checks capture the voice before
  a settings change and verify the selected voice in the provider request.
  They also pass the provider's native text delegation through the call owner
  into the original chat once. The protocol suite replays a real subscription
  delegation captured during the spoken tool test. It verifies lossless bounded
  context/result appends in both modes and transcript replay deduplication.
  Session checks cover rejected commands, transport send failure and actual
  closure separately. Controller checks replay null-body native completions using the accumulated message stream, with completion before acknowledgment, hangup before completion,
  multiple completed tasks and exclusion of unrelated typed work. Queue edit checks retain the original voice delegation for undispatched edits and native replacements, including completion before replacement acknowledgment, while prepared dispatches keep fresh identities. API command checks separate an earlier spoken exchange from the current stop/status request. Outbox tests
  verify recent spoken context survives reload. Startup history cannot submit
  work before fresh user speech is received. Native context tests cover cached
  prompt precedence, saved snapshots, fresh-profile inspection and cancellation
  while context is loading. Transcript tests cover replay, partial final events,
  identical distinct turns, profile isolation, hangup/disconnect retention and
  passive timeline projection. The UI suite checks both speakers, Copy, and
  departure/reopening and collapsed/expanded Hermes task details in both themes at normal and enlarged text. CI-mode checks also keep the composer reachable above the keyboard and scroll long voice errors while Dismiss stays reachable; real-font captures verify the same layouts. It also drives chat switching, the compact caption row, held return navigation and failed-return recovery while the call stays connected.

  ```sh
  flutter test --no-pub test/live_voice_session_test.dart test/live_voice_protocol_test.dart test/voice_preferences_test.dart test/voice_preferences_session_test.dart test/composer_draft_store_test.dart
  flutter test --no-pub test/live_voice_workspace_test.dart
  flutter test --no-pub --dart-define=LIVE_VOICE_REVIEW=true test/live_voice_workspace_test.dart
  flutter test --no-pub test/profile_workspace_controller_test.dart --plain-name "live voice"
  flutter test --no-pub test/profile_composer_queue_test.dart
  flutter test --no-pub test/profile_voice_test.dart test/hermes_voice_test.dart test/profile_voice_page_test.dart test/voice_arbitration_owner_test.dart
  ```

- **Android `voice`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py voice --output build/feature-verification/voice
  ```

## Gotchas

Offline recognition availability is an OS capability, not just a permission. Native offline samples do not prove live provider speech or human intelligibility. No additional charged provider calls are implied by this recipe.

The Android voice family decodes and completes all nine bundled subscription
previews through the native audio player. It also includes a local WebRTC peer: it checks real audio
packets during Home/lock, foreground-service retention without notification
monitoring, and mute/end through the Android notification. It makes no provider
calls. Host UI renders use `--dart-define=LIVE_VOICE_REVIEW=true` with
`test/live_voice_workspace_test.dart`; captures are in
`build/feature-verification/live-voice/`.
Before that render suite, copy the Flutter SDK's material fonts
`Roboto-Regular.ttf` and `MaterialIcons-Regular.otf` to
`build/studio-roboto.ttf` and `build/studio-icons.otf`. Real fonts are required for visual captures; keyboard and large-text geometry
checks run in both CI-font and real-font modes.

Real subscription entitlement, API credits, provider delegation, audible
barge-in/echo and physical headset routing still require an operator-authorized
provider/device run. Source and offline tests cannot establish those properties.

For a deployed-provider check, use the exact connection and profile of the chat
that starts voice. A successful `/api/plugins/wing/voice/v2/status?mode=subscription`
request or call in `default` does not establish readiness in a named profile.
Keep the same `profile` query on both readiness and session negotiation.
Both modes use `/api/plugins/wing/voice/v2/status` and `/session`, with the selected `mode`. No old
`talk-desktop` route is supported by this build.

Voice startup loads Hermes’s cached or saved system prompt; a fresh chat uses
Hermes’s native profile inspector. Subscription supplies the prompt as a developer
message in startup `initial_items`; API mode uses startup `instructions`.
Both modes append a handoff instruction that binds the live speaker to the native
profile identity from its first reply, including a voice name recorded in memory.
The handoff preserves the full prompt and adds no hardcoded identity or user facts.
Recent chat is passed separately as context. New-chat inspection uses profile
defaults and a temporary memory-session identity; deeper retrieval and all tool
work remain delegated to Hermes. Passive recording of all spoken turns still
awaits native Hermes integration. The local spoken transcript does not update shared chat history or memory and
is lost if Wing restarts. Hermes task requests and results remain separate saved
entries. In the current chat reading, replies to voice-submitted work appear under
“Hermes task details” using native submission/admission and saved-row identities;
similar wording is not treated as identity. Typed work that voice merely steers
keeps its ordinary display. Task provenance is local to the chat reading. Ordinary delegated work still uses Hermes's chat processing.

The Wing plugin's opt-in `tests/test_live_context.py` checks a real subscription
call with spoken input, received audio, self-identification in the first reply
and expected user facts in the first answer. The question supplies no assistant
name or context hint. Its private `WING_LIVE_CONTEXT_TEST` configuration selects
the profile, expected identity/facts and number of independent fresh calls (1–5).
Use three calls for identity changes because an unchanged prompt can sometimes
produce the correct identity. Run it only with authorization for the account; an offline
payload assertion or successful connection alone does not prove context recall.

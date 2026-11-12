# Testing and acceptance

[Contributing](../CONTRIBUTING.md) covers the toolchain and ordinary analyze/test/build commands. [Windows build workflow](LOCAL_BUILD_SETUP.md) covers cache/lock handling and data-preserving installation. Complete the [release checklist](CODE_QUALITY_CHECKLIST.md) for a fixed release candidate.

## What a passing check establishes

Host unit/widget tests establish client behavior with their supplied responses. An emulator using injected gateways adds Android keyboard, layout and lifecycle evidence. A live-backend driver exercises the deployed contract. A signed phone run adds that device's permissions, native viewers and installation behavior. These results are complementary; none certifies every environment or a Play submission.

Keep logs and generated captures under ignored `build/`. Record source revision, backend revision, device, executed scenario and remaining limit in the PR or issue. Do not create another release-by-release documentation journal. Redact evidence using [Security](../SECURITY.md).

For CPU attribution, input latency, thermal load and battery investigations, use
the [performance procedure](PERFORMANCE.md) and its repeatable phone recorder.

## Useful test entry points

For Android task reentry, run
`python3 tools/qa/check_activity_reentry.py --serial <device-id> --package <installed-package>`
on an unlocked device. It restarts Wing without clearing data, opens the Recents
shortcut with a competing-task launch flag, and resumes the original task three
times. It checks that the app content renders, the same activity and task are reused, and
Android Recents contains exactly one Wing card, including after a restart. This
native check covers engine eviction, which host widget tests cannot reproduce.
It navigates the real app but does not send messages or modify settings.

| Boundary | Entry points |
| --- | --- |
| Ownership and administration | `test/administration_*_test.dart`, `test/profile_live_contract_test.dart`, `integration_test/administration_existing_server_live_test.dart` |
| Provider recovery | `test/provider_console_test.dart`, `test/provider_recovery_test.dart`, `test/provider_recovery_screen_test.dart`, `test/workspace_picker_test.dart` |
| Notification destination recovery | `test/profile_notification_recovery_test.dart`, `test/workspace_connection_failure_test.dart`, `test/server_connection_status_test.dart`, `test/workspace_reading_snapshot_test.dart` |
| Draft/queue acknowledgements | `test/profile_composer_queue_test.dart`, `test/profile_queue_submission_ownership_test.dart`, `integration_test/profile_lost_ack_live_test.dart` |
| Native queue editing | `integration_test/queued_message_edit_test.dart`, `integration_test/queued_message_native_preview.dart` |
| Saved history and branches | `test/answer_sync_acceptance_live_test.dart`, `test/profile_live_history_test.dart`, `integration_test/answer_branch_live_test.dart` |
| Sensitive input, goals and projects | `integration_test/backend_acceptance_live_test.dart` and its profile-specific companion drivers |
| Vault, approvals, loops and child-only work | `integration_test/remaining_product_live_test.dart` |
| Notifications | `test/chat_notification_test.dart`, `test/plugin_turn_notification_sink_test.dart`, `test/profile_notification_live_test.dart`, `test/profile_notification_coverage_test.dart`, `integration_test/profile_notification_test.dart`, `tools/qa/check_background_monitoring.py` |
| Launcher shortcuts | `test/android_launcher_shortcut_contract_test.dart`, `test/android_launch_intent_service_test.dart`, `test/home_config_restore_test.dart`, `tools/qa/check_launcher_shortcut.py` |
| Slash profile scope | `test/slash_profile_live_contract_test.dart`, `integration_test/slash_commands_live_test.dart` |
| Configuration backup | `test/config_backup_service_test.dart`, `test/config_backup_test.dart`, `test/home_config_restore_test.dart`, `integration_test/config_backup_native_test.dart` |
| Connection setup | `test/connection_address_test.dart`, `test/connection_setup_probe_test.dart`, `test/connection_setup_transport_test.dart`, `test/connection_setup_screen_test.dart` |
| Scheduled tasks | `test/scheduled_tasks_*_test.dart`, `integration_test/scheduled_tasks_native_test.dart` |
| Voice | `test/voice_*_test.dart`, `test/profile_voice*_test.dart`, `test/hermes_voice_test.dart`, `test/microphone_permission_test.dart`, `test/startup_notification_permission_test.dart`, `integration_test/voice_*_test.dart`; [profile voice checks](PROFILE_VOICE.md#verification) |
| Design renders | `test/studio_layout_test.dart`, `test/studio_controls_test.dart`, `test/studio_layout_regressions_test.dart`, `test/administration_navigation_test.dart` |

Read a driver's environment flags, mutations and cleanup before running it. Use disposable profiles/chats and owned fixtures on an authorized server. Live tests may invoke models, modify profile settings or start host tools. Restore changed values and independently verify cleanup; a green assertion that records `backend_limited` is not successful feature acceptance.

After installing an APK on an emulator, run `python3 tools/qa/check_launcher_shortcut.py --serial <emulator-id> --package com.tarkilhk.wing.dev` (use `com.tarkilhk.wing` for release or signed development builds). This read-only check verifies Android's registered Quick Chat, Activity and Search chats intents and resolves their activity. Gradle generates `xml/shortcuts.xml` from `android/app/src/main/shortcuts.xml.template` using each variant's application ID; intent targets must be literal package names because Android parses them with system resources. Flutter tests cover the subsequent cold/warm launch handoff, destination routing, search focus and draft preservation.

Configuration backup's native test runs with
`flutter test integration_test/config_backup_native_test.dart -d <emulator-id> --no-uninstall --dart-define=CONFIG_BACKUP_NATIVE=true`.
Use a disposable emulator with a local file-saving share target. At each share
sheet, save the file to Downloads; at each document picker, select the file just
exported. Flutter drives the app's dialogs, including the wrong-passphrase
attempt. The test's `backup-qa-stage` file in the app's external files directory
identifies each native step for a host UI driver. It uses isolated real Android
preferences and Keystore namespaces, synthetic connection credentials and no
backend. Coverage includes plain Merge, encrypted Replace, restored settings in
the current screen, and persisted credentials read through a new storage client.

For a compatible local backend/emulator, the basic connection pattern is:

```text
adb -s <emulator-id> reverse tcp:<port> tcp:<port>
flutter test integration_test/backend_acceptance_live_test.dart -d <emulator-id> --no-uninstall --dart-define=HERMES_TEST_PORT=<port>
```

That driver requires the disposable profile/skill/provider setup documented in its source. `remaining_product_live_test.dart` additionally uses an owned empty repository through `QA_APPROVAL_REPO` and the dummy vault page in `integration_test/fixtures/vault/`. Do not point destructive approval fixtures at a real project. Serve the dummy page on loopback only. The stock secret-expiry case takes five minutes; a shorter fixture is not equivalent evidence.

For Studio captures, use `--dart-define=STUDIO_REVIEW=true` and the font setup described in the render test. Administration captures use `CAPTURE_ADMINISTRATION` and `CAPTURE_FONT_DIR`. Generated widgets and reserved keyboard insets are not screenshots of an installed app or its actual keyboard.

Connection journey renders use `test/connection_setup_screen_test.dart` with
`--dart-define=CAPTURE_CONNECTION_SETUP=true` and
`--dart-define=CAPTURE_FONT_DIR=<Flutter SDK>/bin/cache/artifacts/material_fonts`.
Captures go under `build/connection-review/`. The transport test uses a disposable
local HTTP/WebSocket server and sends no model message.

Scheduled-task renders use `test/scheduled_tasks_screens_test.dart` with
`--dart-define=CAPTURE_SCHEDULED_TASKS=true` and
`--dart-define=CAPTURE_FONT_DIR=<Flutter SDK>/bin/cache/artifacts/material_fonts`.
This renderer loads the SDK's case-sensitive `Roboto-Regular.ttf` and
`MaterialIcons-Regular.otf` files. Captures go to `build/scheduled-tasks-review/`.
It covers both themes, all five accents, and 320 dp at 200% text. The native
integration driver uses production screens with an in-memory transport on a
disposable emulator; it does not contact a real agent.

`test/scheduled_tasks_live_test.dart` is separately opt-in via
`--dart-define=SCHEDULED_TASKS_LIVE=true`. It targets loopback port 9847 (override
with `SCHEDULED_TASKS_PORT`) using the normal local dashboard handshake. Start
the unchanged Hermes server with an isolated disposable `HERMES_HOME`, a
`mobile-test` profile, and `scripts/probe.sh` inside that profile containing only
`printf 'Scheduled task acceptance passed\n'`. Headless Hermes serves the local
token handshake without a web build. The driver creates paused agent tasks,
runs only the harmless script task, briefly creates/pauses a template, then
deletes and verifies removal of its owned jobs. Do not use a production data
directory. This establishes scheduling API and script execution behavior; it
does not establish paid model inference or external messaging delivery.

The control and layout regression suites export with
`--dart-define=STUDIO_AUDIT_REVIEW=true` and
`--dart-define=CAPTURE_FONT_DIR=<Flutter SDK>/bin/cache/artifacts/material_fonts`.
They cover all five accents, pending/disabled/focus/selection states, and
320 dp layouts at 200% text with reserved keyboard space. Captures go under
`build/studio-audit/`. The native `reading_native_preview.dart` debug target
adds theme/accent switches and locally generated playback, diagram, HTML and
error fixtures. `profile_device_ui_check.dart` supplies clarification retry
and 200% text scenarios with an injected gateway. Restore the normal debug
APK after using either target.

Deliverable card renders use `test/deliverable_attachment_test.dart` with
`CAPTURE_DELIVERABLES=true` and the same `CAPTURE_FONT_DIR`. Captures cover both
themes at 320 dp with normal and 200% text under `build/deliverables-review/`.
The offline debug target `integration_test/deliverables_native_preview.dart`
uses production cards, the reader and Android's save picker with a synthetic
Markdown report. Check Rendered/Source, Back, save/cancel and the saved bytes;
restore the normal debug APK afterward. This establishes native UI and file
delivery behavior, not access to a live server's files.

Large HTML checks use `scripts/test-diagram-preview.mjs` (Node 22 or newer,
`PLAYWRIGHT_CORE_PATH` and `CHROME_PATH`) to render and interact with 2, 8 and
32 MiB documents and verify isolation. The offline Android debug entry point
`integration_test/large_html_native_preview.dart` opens a complete 32 MiB fixture
through the production HTML screen. Build it for a disposable emulator, install
with `adb install -r`, and launch `com.tarkilhk.wing.dev`.
Forward a local port to that app process's `webview_devtools_remote_<pid>` socket,
then run `scripts/check-large-html-native.mjs` with `PLAYWRIGHT_CORE_PATH` and
`WING_CDP_ENDPOINT=http://127.0.0.1:<forwarded-port>`. It verifies content at the end
of the full document, clicks a report control, checks the sandbox and captures
the actual WebView under `build/large-html-review/`. This proves native rendering
of the fixture, not access to the user's real report. Restore the normal debug
APK after using the fixture on a persistent development device.

## Voice acceptance

Voice host tests cover all four Local/Hermes input/output combinations, preference
persistence and failed saves, profile-scoped authentication, stale callbacks,
permissions, draft insertion without sending, read-aloud prose, and cancellation.
Run settings/composer renders with `--dart-define=VOICE_REVIEW=true` and
`--dart-define=CAPTURE_FONT_DIR=<Flutter SDK>/bin/cache/artifacts/material_fonts`.
Inspect `build/voice-review/` in both themes at 320 dp and 200% text.

On a disposable emulator with microphone permission granted, run
`flutter test integration_test/voice_native_test.dart -d <serial> --no-uninstall`.
It exercises real AAC recording, cancellation, MediaPlayer decoding/interruption,
and five offline TTS samples when an offline voice is installed. It reports TTS
start-callback timing, not measured speaker latency. Verify `cache/voice` is empty
afterward using `adb -s <serial> shell run-as com.tarkilhk.wing.dev ls cache/voice`.
Restore the normal debug APK after using the integration target.

`integration_test/voice_permission_native_test.dart` exercises Android's real
denial, retry/grant and background cancellation. On a disposable emulator, revoke
`RECORD_AUDIO` and clear its `user-set`/`user-fixed` permission flags before running
the driver. Follow its printed markers: deny the first dialog, grant the second,
then press Home after `VOICE_BACKGROUND_READY`. The driver expects the recorder
to stop and its file to be removed; resume the app to finish the test.

Complete separate human/native and live-provider acceptance before claiming voice
quality or full feature validation:

- On a fresh disposable install, decline notifications, then microphone. Confirm
  startup works, relaunch does not repeat either prompt, and tapping Dictate can
  request microphone access. Check denial and subsequent grant.
- Use a compatible server/profile with transcription and synthesis configured.
  Record the server revision, phone/Android version, installed voice and language,
  and provider names. The app must send no per-request remote voice override.
- Try Local/Local, Local/Hermes, Hermes/Local and Hermes/Hermes. For each input
  engine, dictate at least five samples: a short request, a longer paragraph,
  punctuation, names/numbers, and speech with background noise. Record original
  wording, returned text, corrections needed, and end-of-speech-to-final-text time.
- For each output engine, listen to at least five replies, including long prose,
  punctuation, names/numbers and Markdown/code. Check intelligibility and record
  request-to-first-audible-speech time. Android TTS callback timestamps alone do
  not establish intelligibility or audible latency.
- During capture, transcription, synthesis and playback, cancel, switch chats or
  profiles, and background the app. Verify no stale draft insertion or late audio.
  Interrupt playback with audio focus loss/headphone removal. Exercise unavailable
  local languages/voices and remote provider/network failures. Check drafts and
  temporary-file cleanup; process-death leftovers are cleared on next app launch.

Synthetic tones and mock transcripts do not satisfy these speech-quality checks.

## Administration checks

The administration fixtures establish UI
behavior without contacting real profiles, speech providers or service accounts.

```bash
flutter test test/administration_overview_test.dart test/administration_runtime_health_test.dart test/administration_comparison_test.dart test/administration_editor_experience_test.dart test/administration_navigation_test.dart
flutter test --dart-define=CAPTURE_ADMINISTRATION=true --dart-define=CAPTURE_FONT_DIR=/path/to/fonts test/administration_design_test.dart test/administration_navigation_test.dart
flutter test integration_test/administration_native_test.dart -d <disposable-emulator> --no-uninstall
```

The capture font directory contains `roboto-regular.ttf` and
`materialicons-regular.otf`. Actual Flutter captures are written to ignored
`build/administration-preview/`; the integrated project-picker test retains its
own capture switch and directory. The matrix includes twelve detail/editor
families in light/dark, 320 dp at 200% text, a standard phone and an 840 dp layout;
root checks cover all five accents, populated profile briefs and explicit attention
states. Runtime captures include retained results and supported next steps. Pending/unconfirmed settings and partially
applied Identity writes use explicit fixture responses.

Native tests exercise a semantics tap, the actual Android keyboard, deliberate
remote-conflict resolution, discard protection, long Identity drafts, a canonical
shared-account link, independent capability disclosure/toggle actions, 48 dp target
edges and keyboard focus. A fourth journey runs a fixture Doctor, returns to the
retained failed observation, and reviews the same operation without another POST. `CAPTURE_NATIVE_ADMINISTRATION=true` adds a ten-second
capture point after the capability checks for external `adb` screenshot/tree
collection. This is fixture-based Android interaction evidence, not certification
of a live backend, every installed screen reader or production account access.

## Notification checks

The production notification path has an isolated emulator fixture:

```sh
ORG_GRADLE_PROJECT_notificationQa=true flutter build apk --debug --target-platform android-x64 -t integration_test/notification_revamp_device.dart
adb -s emulator-5556 install --no-incremental -r -g build/app/outputs/flutter-apk/app-debug.apk
python3 tools/qa/check_notification_revamp.py --serial emulator-5556
```

The driver resets only `com.tarkilhk.wing.notificationqa`, rejects non-emulators,
uses fake Hermes transport data, and restores normal font size/light theme. It
checks FIFO approval identity, failed submission retention, Always confirmation,
privacy Review, watcher-only remote resolution, latest-reply reading, and native
100%/200% layouts in both themes. Screenshots are in `build/notification-review/`.

For manual checks against stock Hermes, generate supported notification events one scenario at a time. Record backend outcomes separately from observations on the phone.

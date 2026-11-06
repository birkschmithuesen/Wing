# Connected user journeys

Use several features together and retain the exact connection, profile, conversation and draft throughout a journey.

## Sub-features

- `journeys.connect-reopen` — verify and save a connection, enter its workspace, leave and reopen its credentials.
- `journeys.conversation` — find a chat, prepare a referenced/attached prompt, send or queue it, inspect Activity and revisit a saved answer.
- `journeys.restore` — restore staged work after process death without repeating a submission or upload.
- `journeys.notification` — receive, open, read or dismiss a request in the exact conversation, including cold entry. Reply alerts open at the beginning of the answer after its formatted content settles.
- `journeys.voice` — grant/refuse permission, record or cancel, play or interrupt and recover a missing capability.
- `journeys.stock` — create/edit/delete a disposable stock-Hermes profile and project through Android controls.

## How to get to it (user POV)

Start with [connection setup](connections.md), then [Chats](chat-browser.md), [conversation work](chat-inputs.md) and [Activity](chat-activity.md). For OS entry paths start from the notification shade, Android Home, share sheet or [voice controls](voice.md). [Profile administration](profiles.md) begins in the drawer or Bot settings.

## Driving it with Wing harnesses

Preconditions: [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Each command owns its disposable emulator and keeps named receipts under the supplied output directory.

```sh
python3 scripts/test_journeys.py --output build/feature-verification/journeys
python3 scripts/test_nightly_native.py notification-cold --output build/feature-verification/journeys
python3 scripts/test_nightly_native.py voice --output build/feature-verification/journeys
```

The first command requires all four critical journeys, all twelve roadmap journeys and actual outbox process-death recovery. Its named outcomes cover uncertain Send beside a newer draft; native clarification from composer text; local Git review; live progress and plan recovery; profile/project navigation; model/reference/find/output controls; approval/queue ownership; child/parent work; saved-answer edit/regenerate/fork; and scoped administration/update refusal. Read those outcomes rather than inferring coverage from the suite title.
Roadmap actions wait for route completion and reveal controls before tapping,
including when the Android keyboard reduces the viewport.
The Identity save journey waits for Android's keyboard inset before checking and
tapping Save, so its keyboard-open assertion does not race the native show animation.
After the clarification journey reopens the keyboard, it uses the visible Input
needed control to recover the full confirmation target, then checks retained
answers, the unrelated draft and held retry feedback.
Roadmap failures export their exact failure-time Flutter frame and keyboard metrics under `<suite>-frames/`
and in the suite log. Native foreground, window and keyboard diagnostics at failed
suite completion are retained under `<suite>-failure/` before cleanup; later tests
may have changed that native state.
Failure frames do not require `--capture-frames`.

The approval journey checks the immediately visible Review command panel and
exact selectable command before using its icon-only Approve once action.

For the real stock-backend boundary, prepare a clean checkout of current [official Hermes main](https://github.com/NousResearch/hermes-agent), with no project `.env` or untracked files. From that checkout, build a fresh `.venv` using `python3 -m pm.build_env --source . --out .venv --extra web`. Give preparation disposable `HERMES_HOME` and `HERMES_RUNTIME_DIR` directories, as in [nightly CI](../../.github/workflows/nightly-tests.yml). Upstream PM owns the supported interpreter, committed dependency lock and dependency overrides. Set `WING_HERMES_SOURCE` to that checkout, then run from the Wing root:

```sh
python3 scripts/test_vanilla_hermes.py --hermes-source "$WING_HERMES_SOURCE" --output build/feature-verification/stock
```

`WING_HERMES_SOURCE` must point to the inspected stock checkout. The runner starts the canonical gateway with its Webapp listener, signs in with a disposable username and password, and exercises the profile/project production UI. Its backend home, profiles, credentials and process are retired after the run. Standalone `serve` cannot establish this session boundary. The recipe does not authorize a deployed-server upgrade or provider-charged generation.

The host `flutter test --no-pub test/conversation_assembly_test.dart` recipe also exercises group discussions and read-only working histories in both themes and text sizes, including reading-mode return and retained group drafts above the landscape keyboard.

Phone reading is covered by the `transcript-expansion` family: enter table reading mode, rotate, return to the retained draft, reveal composer controls and use Back without leaving the chat.

For `journeys.conversation`, the host Send-and-return recipe in
[conversation](conversation.md) checks that a reply arriving while Wing is in the
background opens at its beginning. Reading-position tests also cover leaving a
thread and returning after new saved history arrives.

For `journeys.conversation`, the [fresh Send recipe](chat-inputs.md#gotchas) checks
that a stopped reply or an empty paused queue does not strand the next message.

For `journeys.conversation`, the [steering recipe](chat-inputs.md#gotchas) checks
compact acceptance becoming a normal saved user bubble, with the same
presentation after cached reading is restored.

## Gotchas

Fixture native journeys, stock transport and deployed-provider acceptance prove different boundaries. Android owner recreation is not process death; require the separate process-recovery verdict. Keep each failed aggregate failed even when a focused recovery passes. Do not sum overlapping case counts. Run families serially on this workspace; retain artifacts after the owned emulator and backend are retired.

For `journeys.conversation`, also use the [read-only saved-chat contract](conversation.md#read-only-saved-chat-contract-on-an-existing-server)
when session APIs change. The fixture journeys and stock profile/project runner
do not establish that existing chats reopen on the intended deployment. This
read check needs no provider turn; sending/queueing still requires its separate
authorized journey.

For attachment refusal, the [conversation recovery recipe](conversation.md#gotchas)
checks that saved messages remain visible, Send is unavailable, and Retry keeps
the draft while attachment completes. History access does not grant write authority.

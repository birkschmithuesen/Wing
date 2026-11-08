# Read and search conversation history

Open saved or streaming history, search older messages, page through a long conversation and return to the previous reading position.

Feature ID: `conversation`.

## Sub-features

- `conversation.read` — Reconcile live and saved messages. Steering becomes a normal user bubble when it appears in saved history, including on reopen and cached reading; see the [steering recipe](chat-inputs.md#gotchas). Saved history opens independently of runtime attachment; an attachment refusal keeps messages and drafts visible, with Retry to enable sending.
- Normal chats, canonical Bot Chats and group discussions share the conversation frame and reading layout. Passive Recents cards use the same frame and composer presentation.
- `conversation.reading-mode` — Use a table’s full-screen icon to hide the composer and portrait context row without leaving the conversation. The same icon or Android Back restores it; drafts remain intact. Landscape puts title and scope in one header row.
- `conversation.search` — Find and open older content.
- Async delegation completion flags keep model-facing wake text out of conversation bubbles and Find. Useful completion results remain in Activity and searchable; quoted examples stay readable.
- `conversation.position` — Page and return without losing reading position. Leaving for another thread or app keeps the current reading location, including at Latest. After sending and leaving before the reply, return to the sent message and the beginning of the reply. Opening a popup or changing a chat's decoration keeps the current viewport without starting another history restoration.
- `conversation.recovery` — Read the structured reason for a failed turn, inspect its details and use a supplied model or provider recovery action. Selecting a model preserves the draft and never resends the failed turn.
- `conversation.git-review` — Open Chat actions → Git review for a reported local terminal workspace. Read changed files, All changes (working tree versus HEAD) and Staged (index versus HEAD), then copy an exact changed-line or hunk reference.

## How to get to it (user POV)

Open a chat from Chats, Bots, Recents or a notification. Read older messages, choose Find in chat from its menu, open a result, then return to your reading position or Latest.

Opening a reply notification positions the beginning of its answer in view,
even when the answer spans several screens. This explicit destination takes
precedence over the remembered reading position.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/profile_history_search_test.dart test/conversation_routes_test.dart test/conversation_reading_position_test.dart test/conversation_assembly_test.dart test/profile_row_actions_test.dart test/connection_diagnostics_test.dart
  ```

  Internal-message visibility, saved-history refresh, Find and unchanged raw
  history identities are covered by:

  ```sh
  flutter test --no-pub test/internal_message_visibility_test.dart
  flutter test --no-pub test/profile_composer_actions_test.dart --plain-name 'automation start preserves'
  ```

  The reading-position suite covers thread departure, covered conversations,
  app return and local prompts becoming saved history. For the real Send control
  and rendered reply beginning in both themes at normal and enlarged text:

  ```sh
  flutter test --no-pub test/profile_composer_actions_test.dart --plain-name 'Send then app return'
  ```

- **Android `journeys`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py journeys --output build/feature-verification/conversation
  ```

- **Android `transcript-expansion`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py transcript-expansion --output build/feature-verification/conversation
  ```

### Read-only saved-chat contract on an existing server

With authorized diagnostic access, supply the gateway Webapp base URL, a private
username/password JSON file and a profile containing saved messages:

```sh
WING_HERMES_URL='https://<gateway-webapp-host>' WING_HERMES_LOGIN_FILE=/path/to/private-login.json WING_HERMES_PROFILE='<profile>' flutter test --no-pub test/existing_backend_readonly_live_test.dart
```

The named `existing saved chats reopen with canonical authority and readable
history` case reads up to three nonempty chats through production
`ProfileGateway`, mounts each over a fresh authenticated socket, accepts its
canonical authority and reads saved history twice. Empty seed data fails. The
suite reports the running backend commit and reopened count without printing
transcripts or credentials. It does not send messages, acknowledge reading,
change settings or update Hermes. This proves the deployed read contract;
Android navigation and composer behavior remain separate journey checks.
The gateway case also requires `session_authority == true` in the `gateway.ready` event payload.
Stock standalone Dashboard can pass login and ping while serving a different
session API; a current version or accepted subprotocol does not establish
canonical session support.

To check one reported conversation through the production workspace controller,
add `WING_HERMES_SESSION='<saved-session-id>'` to those environment variables and
select `--plain-name 'requested saved conversation'`. It requires nonempty saved
history before attachment completes, then reports whether canonical attachment
succeeded or a visible attachment failure remains. This targeted case establishes
readability, not permission to force takeover or proof of message submission.

## Gotchas

Streamed replies use Hermes turn, segment and UTF-16 offset identities. Replayed
segments appear once; identical words in different segments remain separate.
A partial reply retained across reconnect or process restoration belongs to its
execution admission, including an unknown execution. A queued successor cannot
keep an earlier reply alive. A successful saved-history read retires settled
local rows; a failed read preserves them. Command and review notices keep their
place between retained reply segments, including segments with identical text.

```sh
flutter test --no-pub test/reply_segment_identity_test.dart test/reading_snapshot_message_test.dart test/workspace_reading_snapshot_test.dart
```


When Hermes cannot confirm chat ownership, Wing shows the saved messages and
keeps the draft. Sending remains unavailable until normal attachment succeeds.
If the chat is open in another app, close it there, then use Retry. The refusal
alone does not prove another app holds it; Hermes can also fail to verify its
ownership records. Wing does not force ownership away from another process.
Retry shows the pulsating Wing in the header while messages stay usable.
Clients sharing a chat must use the same canonical gateway. A standalone
Dashboard on the same machine can hold an independent runtime over the same
saved transcript; sharing the host or database does not establish shared access.
The host recovery recipe exercises the real Recents control, readable history
during held attachment, refused sending, retained drafts and successful retry
in both themes at normal and enlarged text sizes:

```sh
flutter test --no-pub test/recent_conversation_switcher_test.dart --name 'Recents tap enters chat before held resume and history.*coordination'
```

Git review uses read-only stock Hermes endpoints. It does not stage, revert,
commit or push. SSH, Modal and per-session container paths are not treated as
host paths. An empty response says no changed files were reported, rather than
claiming the workspace is a clean Git repository. The host suites
`git_review_test.dart` and `git_review_screen_test.dart` cover read ownership,
late replies, comparisons, copy references, pending feedback and recovery.

Opening or tapping Latest does not mark a message read. Saved reading positions last until Wing restarts. Long-history host tests cover paging beyond the small Android fixture.
Pending-input navigation stays outside the form: below it at normal height,
or in a separate side gutter on short keyboard-open screens. The form and
composer retain scrollable access to their full action targets.

After reopening, use **Input needed** to reach a new question while preserving
the reading point until that action. Bot and Recents regressions verify visible
messages rather than raw scroll offsets, because restoring around a saved row
changes the scroll origin. The shared `settleTranscript` test helper waits for
rendered history restoration and real Markdown workers; advancing only the test
clock cannot complete worker I/O.

```sh
flutter test --no-pub test/bots_view_test.dart test/bot_group_view_test.dart test/recent_conversation_switcher_test.dart test/saved_message_actions_test.dart test/profile_conversation_ui_test.dart
```

Automatic read-acknowledgement failures are logged in the phone's diagnostics
without a conversation warning. Failed acknowledgement still leaves the chat
unread for retry; explicit Mark as read actions retain their failure feedback.
The row-action viewport regression checks rejection, diagnostic output and later
successful acknowledgement in both themes at normal and enlarged text sizes.

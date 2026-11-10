# Find and organize chats and projects

Filter and open the intended chat, manage its project or row actions, and return to the retained browser after a change or failed read.

Feature ID: `chat-browser`.

## Sub-features

- `chat-browser.find` — Search and filter chats and projects.
  Working status includes detached child tasks and background processes known
  to the connected gateway. Recents uses the same captured profile and saved
  conversation when opening that work; discovery does not attach the chat.
  Connection outages appear once in Alerts; Recents keeps cached chats visible
  without an inline outage message. Open the alert or status icon for connection
  details and retry. Partial refresh failures on available transports still show
  one summary. An unavailable catalog is not presented as an empty chat list.
  Recents suspends its display work while Wing is paused and catches up previews
  and unread state on resume. Repeated connection updates reuse unchanged saved
  message summaries; edits still replace them.
  Once the workspace is ready, Wing prepares Recents quietly in the background.
  Opening it reuses the shared catalog or joins preparation already underway;
  an early visit retains loading feedback until the initial read settles.
  Hidden Recents does not poll, and warm-up does not repeat on every app resume.
- `chat-browser.open` — Enter the captured row immediately.
- `chat-browser.organize` — Change a chat or project and retain browser state. The current-project card in Move to project has an icon-only cross to remove a chat from its project. Confirmation moves it to the captured profile's default folder, keeping messages and drafts. New projects start in the captured profile's default folder and propose a kebab-case subfolder as the name changes; typing or choosing a location keeps that override.

## How to get to it (user POV)

Choose Chats in the drawer. Search or filter by profile and project, tap a row to open it, use row actions to organize it, or long-press New chat to reveal New project.

Choosing a folder in Edit project and saving makes it the project's only folder association.
Chats in other folders leave that project's group, keeping their working folders
and messages. Choose the current folder again and save to remove leftover associations from
earlier edits. Name, color and icon edits leave the folder links unchanged. Failed cleanup keeps the editor open for retry.

Only saved Hermes projects appear as projects in Wing. Automatic folder groups
from Hermes, such as a group named `projects` for the profile's default folder,
are unassigned chats in Wing. Their chats remain visible; those generated groups
have no project editor or move destination.

To remove a chat from its project, open Move to project from its row actions or
tap the project in the conversation header. Tap the cross in Current project,
then confirm. Cancel keeps the assignment. Chats already in the default bucket
have no removal cross. A failed move keeps the picker open with an error and retry.
If the chat is still working, confirmation shows why it cannot move. Retry in
the same picker after the work finishes; admission uses the current chat state.
Choosing another project and tapping the removal cross use the same Move chat
confirmation, naming the destination and keeping messages and drafts.
Moving a saved chat prepares its Hermes execution policy automatically before
changing the folder; opening or sending a message in the chat first is unnecessary.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/chat_browser_transport_test.dart test/profile_workspace_browser_test.dart test/profile_row_actions_test.dart
  flutter test --no-pub test/workspace_activity_filters_test.dart test/profile_recents_test.dart test/app_shell_navigation_test.dart
  flutter test --no-pub test/profile_recents_visibility_test.dart
  flutter test --no-pub test/project_picker_design_test.dart
  flutter test --no-pub test/server_files_repository_test.dart test/profile_project_management_test.dart test/profile_project_actions_test.dart test/project_folder_picker_test.dart test/project_icon_picker_test.dart
  ```

- **Android `journeys`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py journeys --output build/feature-verification/chat-browser
  ```

The Recents outage matrix covers simultaneous chat/bot/group refresh failures,
cached content, transport-only updates, no inline outage notice and successful recovery in both
themes at normal and doubled text size. Add `--dart-define=CAPTURE_RECENTS=true`
to the activity suite to capture its rendered states. The app-shell Recents route
checks also require one summary when both profiles fail to refresh.
Run `test/profile_recents_test.dart` with
`--dart-define=WING_PERF_INSTRUMENTATION=true` to enforce the unchanged-history
summary work budget. Its lifecycle checks also verify that paused connection
updates do not rebuild the catalog and background replies appear on resume.
The visibility suite starts on Chats and opens Recents through the drawer with
startup preparation held or completed. It checks cached cards, visible pending
feedback, no duplicate chat/group reads, deferred foreground admission, failure
recovery and no hidden polling. Add `--dart-define=CAPTURE_RECENTS_LOADING=true`
to capture the rendered Recents loading and settled states.

The creation-route host checks enter New project through its FAB and menu,
verify the profile default and generated location, save the proposed path, and
retain manual locations through name edits and delayed reads. They also cover
read failure/retry, cancellation, and the existing folder and edit journeys.
The native creation journey waits for the new project's row menu to become
reachable after keyboard dismissal before verifying edit and delete actions.

Removal checks use the production picker and confirmation, holding the default
folder read, saved-chat preparation, mutation snapshot and write separately. They cover cancellation,
read/write failure and retry, immediate membership cleanup, draft preservation,
and profile retirement. The design suite inspects the assigned card and
confirmation at normal and enlarged text in both themes.
The Chats overflow checks enter through the row's trailing action button and
verify that its inherited icon styling cannot fade the filled confirmation glyph.
The project-action suite also supplies an automatic root-folder group alongside
a saved project, verifies its chats remain unassigned in the browser and header,
and excludes the generated group from project actions and move destinations.

## Gotchas

Bot chats are hidden from the ordinary list unless Show automated chats is enabled. A completed row mutation and a successful background refresh are separate observations. Move and delete use a fresh owner-issued revision and execution generation; a concurrent turn or edit can refuse the action without changing the row. Delete retires the runtime through the same stock owner transaction that removes its history.

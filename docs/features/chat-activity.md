# Inspect and supervise agent work

Open Activity during an answer, inspect tool results, answer a question or approval, and follow a child while the parent continues; retain delivered results afterward.

Feature ID: `chat-activity`.

## Sub-features

- `chat-activity.inspect` — Open the compact latest-reasoning row to inspect a newest-first Reasoning stack with title-only reasoning rows and expandable X tools groups while streaming. Past Activity retains its labels and expandable reasoning details. Expand exact requests/results; late completion keeps its original position and incoming work retains open details and the reading anchor. Streaming runs retain fixed durations across reasoning boundaries and a live counter for the current run.
- Background process completion receipts stay inside Activity’s Timeline, including batches and failures. Open Activity, then the compact Process update row to read its full update and exact command/result; no separate completion card interrupts the answer. Saved receipts have no live process controls.
- Live tools show supplied progress against their exact call identity. Progress disappears when the call settles or recovery starts; saved histories never replay a live counter.
- Active recurring work shows a next-wakeup countdown with compact days/hours for long delays and the exact scheduled time in its tooltip. Paused work, a pending response and work deferred by a goal do not show a countdown; an overdue deadline says Due now without implying execution began.
- `chat-activity.respond` — Answer the current question or approval. Live approvals in normal, bot and group chats share command-review content with notification review. The exact command starts visible; completed request receipts remain under collapsed Activity. Native prompts stay bound to their turn, while server-request prompts retain their own reply identity. Reopening keeps all waiting native questions in order and a settled request cannot close a newer one.
- `chat-activity.delegate` — Follow a child and retain its saved result. Child and nested-child traces bind images, tool file previews, skill documents and message attachments to the child chat. Preview, share and download use the same viewers and file-delivery flows as the main trace.
- `chat-activity.processes` — Discover and follow background terminal commands in the optional Background tab above the composer. Read recent output, stop a running command or dismiss an exited row during its active response. Exited rows leave the dock when that response ends and do not return on later turns; running processes remain visible until they exit. Discovery happens on entering or returning to a visible connected chat; relevant tool receipts and a five-second running-work refresh keep it current. Hidden/offline chats and settled lists do not poll. Failed reads retain the last rows; reopen Background to retry.
- `chat-activity.tasks` — Follow the current task batch above the composer. Tap anywhere on a task row's header, including its text, status, padding or chevron, to expand or collapse it. The expanded body remains selectable and scrollable. Once every task is completed or cancelled and its response ends, read the batch in that response's Activity Tasks tab. Later rounds and replayed updates do not restore it to the composer.

## How to get to it (user POV)

Open Activity from a conversation. Inspect tools, requests and saved results. During active work open the Subagents, Tasks or Background tab, inspect a child, and return while the parent continues.

Use [Alerts in Hermes health](health-alerts.md) to review failed automatic
process reads and subagent output updates. Readable content remains available
with its last-received context. Refresh in the affected view to retry.

Swipe up on a Subagents/Tasks/Background bar zone above the composer to open that
category at its compact height. Swipe upward again on the open bar or anywhere
in the drawer to maximize, or downward in the drawer to close. Diagonal swipes
follow their larger component: sideways switches pages,
vertical movement resizes or scrolls. At full height, rows scroll upward and back
down; continuing downward from their top closes the drawer. The small top handle
also toggles compact/expanded height on tap. Closing keeps the draft; reopening
by tap starts compact. Three categories share the same single bar; at enlarged text the strip scrolls horizontally and reveals the selected category. Background processes use the same bounded drawer, preserving the draft and composer position.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/profile_execution_activity_test.dart test/profile_live_execution_test.dart test/reply_duration_test.dart test/profile_live_work_route_test.dart test/profile_subagents_test.dart test/question_activity_projection_test.dart test/question_activity_test.dart test/gateway_approval_panel_test.dart test/notification_approval_review_test.dart test/profile_approval_queue_test.dart test/native_prompt_runtime_test.dart test/native_prompt_controller_test.dart
  ```

- **Compact live stack:** `profile_live_execution_test.dart` checks lazy collapse, one latest heading, reverse run/tool order, stable completion identity, joined saved/native receipts, tool expansion and reading anchors, non-expandable streamed titles, and restoration of full past reasoning details. `conversation_routes_test.dart` and `profile_live_work_route_test.dart` exercise the actual normal/Bot routes, image results, history handoffs, drafts and the adjacent Background dock. Capture the latter with `--dart-define=CAPTURE_LIVE_WORK_DOCK=true` for both themes at 390 dp and 320 dp/200% text.

- **Child trace resources:** `flutter test --no-pub test/profile_subagent_panel_test.dart test/remote_files_client_test.dart test/resource_preview_owner_test.dart` opens the production child sheet, holds and retries source-image reads, opens full file content, saves a nested child's message attachment and closes during a pending share. Requests must retain the child's profile/session and exact path. Image states run in both themes at ordinary and enlarged text. These are host fixtures; native export behavior is covered by the [output viewer recipes](outputs-and-viewers.md).

- **Task handoff across chat surfaces:** the production conversation route checks four completed tasks through streaming, held history, the original saved Activity Tasks tab, draft retention and three later rounds in both themes at normal/enlarged text. The owner suites also cover child completion, cancelled tasks, hydration and unfinished work retained after a response.

  `flutter test --no-pub test/profile_todo_icons_test.dart` checks whole-row task
  toggles, keyboard activation, scroll gesture admission, independent status
  semantics, selection and ID-bound expansion in both themes at ordinary and
  enlarged text. Its dock case checks selection without moving the composer.

  ```sh
  flutter test --no-pub test/profile_live_work_route_test.dart test/profile_execution_activity_test.dart test/subagent_timeline_session_test.dart test/saved_activity_test.dart
  ```

- **Saved completion placement:** `flutter test --no-pub test/internal_message_visibility_test.dart test/profile_transcript_test.dart test/profile_live_execution_test.dart` checks saved/live-adjacent grouping, retained identities, batches/failures, and opening process details through the conversation Activity in both themes at normal and enlarged text. The phone matrix compares the process row with its neighboring command row: equal compact height, aligned icons/text, matching typography and no inter-row gap. The live suite checks completion/watch/failure/batch/body-less details and exact-output Copy.

- **Background process discovery and live updates:** the owner tests exercise empty-list discovery, coalesced receipts and held reads, unchanged snapshots, route departure/resume, runtime replacement, failures and recovery. Lifetime regressions cover old idle registry entries, completion/error, late reads, later turns and processes that outlive their parent. The production-route matrix opens Background without preloading rows, follows output and uses Stop/Dismiss beside Tasks/Subagents at 390 dp and 320 dp/200% text, both themes, including keyboard and held/failed reads.

  ```sh
  flutter test --no-pub test/profile_background_work_test.dart test/profile_background_work_panel_test.dart test/profile_live_work_route_test.dart
  ```

  `profile_background_work_test.dart` checks that a failed automatic read
  retains the process rows and reports the incident for the exact chat.
  `subagent_timeline_session_test.dart` checks that a successful live replay
  cannot clear an unresolved saved-history failure.

- **Drawer gestures:** the shared dock and production conversation route exercise
  upward expansion and downward dismissal for both categories, fixed composer
  geometry and compact reopening. The dock suite also checks slow dragging,
  short flicks, cancellation, both bar zones, dominant diagonal direction and
  row scrolling/dismissal handoff in both themes at ordinary and enlarged text.
  The first upward swipe opens compact, matching tap height even for short
  single-category content; the next upward swipe maximizes.

  ```sh
  flutter test --no-pub test/profile_live_work_dock_test.dart test/profile_live_work_route_test.dart
  ```

- **Production Android processes:** after explicit approval for one temporary
  QA chat, bounded print-only jobs, a short subagent and model usage, run the
  existing live runner against the canonical gateway (not standalone Dashboard):

  ```sh
  python3 scripts/test_existing_hermes_next.py --suite processes --url "$WING_HERMES_URL" --login-file "$WING_HERMES_LOGIN_FILE" --output build/feature-verification/background-processes-prod
  ```

  This owns its emulator and temporary chats. Its compact-activity case sends three
sequential bounded print-only commands through the real composer, requires actual
readable reasoning, checks newest-first tool/reasoning placement and the unique
expanded header, retains open details and an unsent draft across incoming work,
and verifies the saved final answer. The process case checks discovery,
  changing output, Tasks/Subagents/Background together, native keyboard/draft
  retention, natural exit, Stop with backend readback and automatic retirement after the parent response ends. Manual Dismiss during an active response is covered by the focused panel suite. Require its
  named verdict and confirmed owned-chat cleanup; no existing chat or profile
  setting is changed. Captures and source/backend identities remain in the output.

- **Android `journeys`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py journeys --output build/feature-verification/chat-activity
  ```

## Gotchas

Progress with no supplied total or percentage stays a received value/message;
Wing does not estimate completion. `gateway_activity_test.dart` and
`profile_tool_call_test.dart` cover exact-call updates, terminal/replay fences,
phone-width wrapping and countdown lifecycle. The Android roadmap journey
“live tool progress and plan recovery use the production conversation” exercises
the production Activity and recovery controls.

Streaming durations start at the preceding user message or Reasoning block; native reasoning boundaries use their first receipt time on the phone. Missing or reversed timestamps omit the interval. Historical results have no live controls. Completed children remain current only while their parent turn is active. Task batches with unfinished work remain current after a response; fully settled batches retire when their response ends, before history finishes loading. A request must belong to the displayed chat.

Tasks are plan items, while Background contains terminal processes. An exited process remains in the dock only during the response in which its completion was observed. When that response ends, Background hides finished rows and disappears if no running work remains. Opening an idle chat does not restore old exited registry entries; saved receipts remain in Activity. Automatic refreshes stay quiet; selecting Background shows a pending cue through its read. Stop uses the exact session-owned process and requires a server acknowledgement.

Failed Steer, Interrupt and Stop actions show local recovery beside their
original controls. Steering keeps the unsent guidance and remains usable with
the keyboard open. `test/profile_subagent_panel_test.dart` and
`test/profile_background_work_panel_test.dart` exercise these failures and
retries in both themes and enlarged text. Recorded completion status stays
inside its Activity result.

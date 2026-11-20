# Connect to Hermes

Verify and save or import a connection, reopen it securely, and recover from authentication or network failure without accepting a cancelled setup.

Feature ID: `connections`.

## Sub-features

- `connections.verify` — Check credentials, the gateway Webapp address and canonical chat authority in place. Check connection updates a permanent compact status area without scrolling or moving the fields and actions. The full-width Check connection action sits above compact result LEDs, with status descriptions for accessibility. The fixed header shows checking progress even while the keyboard closes; Next opens name/save only after success. Edits invalidate the previous check.
- `connections.save` — Persist and reopen the selected connection.
- Saved instance aliases appear in workspace and conversation headers as well as
  the instance picker. Renaming an instance updates a retained workspace without
  replacing its open chat, draft or connection.
- `connections.recover` — Recover temporary connection and conversation failures automatically, with retry delays capped at 30 seconds. Foreground return, network changes and Retry bypass the delay. Authentication or configuration failures remain actionable; setup can be cancelled safely.

A failed HTTP GET gets one immediate transport retry before changing the shared
connection indicator. Cancellation, timeouts and writes are not replayed. If both
reads fail, HTTP access remains visibly limited while a healthy live chat stays
connected; that background failure does not start conversation recovery. Actual
socket loss and Android network loss still trigger recovery.
When Android changes its default network, Wing checks the existing live socket
before replacing it. A responsive socket stays connected without flashing the
recovery indicator; an unresponsive socket follows normal recovery.

## How to get to it (user POV)

Open connection setup at first launch or use Hermes instances to add or edit an instance. Use Next or swipe left/right between address, sign-in and name/save. Cards follow the swipe and settle into place; an unfinished swipe returns without changing the step. Next stays in a fixed footer. The normal phone layout fits on one screen, with scrolling retained for enlarged text and the keyboard. Check connection stays on sign-in with its results; Next or a forward swipe opens name/save after all checks pass. Completed results remain available across all three cards for five minutes from completion, unless connection details change. Returning within that window allows forward swipes without checking again. Save explicitly, or import a shared connection, then reopen it.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/studio_selection_test.dart test/connection_setup_screen_test.dart test/cloud_connection_journey_test.dart test/connection_manager_test.dart test/server_connection_status_test.dart test/live_chat_status_transport_test.dart test/administration_health_test.dart test/connection_setup_session_test.dart test/connection_setup_transport_test.dart test/connection_import_transaction_test.dart test/secure_connection_storage_test.dart test/connection_diagnostics_test.dart
  ```

- **Android `journeys`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran. The setup driver waits for each control to be reachable after keyboard or card movement; step traces and bounded settling identify stalled native actions. Focused widget checks compare control and result geometry across held checks, success, failure and retry in both themes at normal and enlarged text; gesture checks cover intermediate positions, reversal and reduced-motion navigation.

  ```sh
  python3 scripts/test_nightly_native.py journeys --output build/feature-verification/connections
  ```

For retained-alias and header regressions, run
`flutter test --no-pub test/profile_workspace_registry_test.dart test/workspace_picker_test.dart`.
The registry checks rename reconciliation and reuse without reconnecting; the
picker checks the open conversation and menu in both themes at normal and 200%
text size.

Connection interruptions also appear once in [Health alerts](health-alerts.md).
Opening that alert shows the same connection-details sheet as the status icon,
for the captured instance. It does not switch the selected workspace.

## Gotchas

A successful probe does not establish a saved connection. Reopen from Android secure storage. Cancelled or replaced setup must not acquire the next route.

Rejected HTTP writes record their method, endpoint family and status in phone
diagnostics. Logs omit authentication values, response bodies and conversation
content; diagnostics do not change write retry or error behavior.

A standalone Dashboard can pass HTTP profile/history reads but must fail the chat
check. `ProfileGateway` checks `session_authority` in the `gateway.ready` event payload
through the stock event envelope before admitting session requests. Use **Back** to correct the gateway address; sign-in fields are preserved. A known unsupported endpoint
keeps the shared connection LED and health finding failed even after HTTP success;
a fresh canonical handshake clears that observation. Webapp password sign-in keeps
the gateway-scoped session cookies and sign-in binding within the connection’s
existing origin-bound authentication owner.

For deployed chat readiness, also run the [read-only saved-chat recipe](conversation.md).
Fixture success does not prove the configured deployment can reopen chats.

Recovery continues while the saved connection is retained, including when the
server returns after the first five attempts. A healthy socket alone does not
finish conversation recovery. Newer live updates can supersede a resume snapshot;
Wing reads again without treating that race as a connection-settings failure.
Saved pending chats from a previous app process join this same recovery loop.
A temporary resume or history failure retries automatically; Retry and foreground
return immediately reattempt restoration, including chats that have not opened
yet. A newer live observation triggers a fresh read. Recovery finishes only after
the saved chat, draft and history are restored; already submitted prompts are
not sent again. A permanent refusal remains actionable and keeps its saved owner.
A gateway's own canonical refusal is never retried on the same frame unless it
is a profile still starting up or temporary storage unavailability, which keep
the capped automatic backoff above; this covers every canonical refusal reason
(profile mismatch, unavailable, not found, invalid parameters, permission
denied, unsupported, retired and any other reason the gateway returns), not
just a fixed list, so a profile the connected gateway does not serve for
shared discussions stops reconnecting on its first refusal too. A resume
refused for an invalid working directory retries at most once without it,
never in a loop.

The existing header Wing shows recovery while history and drafts remain usable.
The icon-only Retry action remains available between automatic attempts and
disables while a recovery request is running.
Leaving a notification opening or disposing its workspace cancels its retries.

Switching to an already-retained chat (its composer and history already
restored) reveals it instantly; the resume/history reconciliation that follows
is a background refresh, not an opening, so it never shows Reconnecting or
blocks voice dictation (see [Dictate, hear replies and have live
conversations](voice.md)). Fork (Wing Voice): a foreground entry or
network-restore event resumes only the selected profile, plus any other
served profile that has a turn still awaiting admission, an unrestored
pending input or a queued follow-up prompt, in small batches - not every
served profile that merely has a retained chat list or was ever connected
before. Opening every profile's gateway socket at once, or even every one of
them staggered, previously saturated the server's event loop and stretched an
unrelated profile's socket trouble into the header staying on Reconnecting
for other, healthy chats (t_a8358240); still reconnecting every served
profile on each resume event, just staggered, remained one gateway socket per
served profile per event (t_15b221a3). An idle background profile - loaded or
connected earlier in the session, but with no pending turn right now - stays
disconnected and opens its own socket lazily the next time the user actually
switches to it or opens a chat in it. The selected profile resumes first and
alone, ahead of any background batch, so its own recovery cannot be seated
behind unrelated profiles in list order; the header's Reconnecting/Connected
state and the Retry action depend only on the selected profile (plus startup and
notification-opening, which always gate the header) and never on a background
profile's own reconnect, failure or socket drop, so a stale profile the user
has not switched back to cannot keep the header orange or block new-session,
composer or dictation admission for the one actually open (t_1d748269).
Within the selected profile itself, its own visible chat (the one on screen)
resumes first and alone; the header's Reconnecting/Connected state clears as
soon as that visible chat and the socket are both live, without waiting for
any other retained chat of that same profile, the pending-restoration sweep,
the journal write or the session-list refresh. Those keep running afterward
as a bounded-concurrency background sweep (batches of 3, the same pacing as
the background-profile batches above), so the selected profile's own
recovery time no longer grows with how many other chats it is retaining
(t_edbdd961). The visible chat's own resume is also independent of that one
chat's saved content: Hermes resumes it tip-only (no stored messages over the
socket), and the chat is live and admits a new turn before its REST
transcript page - which can carry embedded image bytes - finishes
transferring; that page's refresh, and the chat's own images, continue in
the background and still complete before the overall reconnect settles
(t_0f45a26f). Phone logcat (`WingConnection`) also carries a
`workspace.recovery_step` line for each awaited step of a profile's resume
(socket connect, visible chat resumed, chat resume, pending restore, journal,
session refresh) with its cumulative `elapsed_ms`, so a slow resume can be
localized even when the socket was already open and no `ws.connect_started`
appears.

```sh
flutter test --no-pub test/profile_resume_freshness_test.dart test/profile_workspace_controller_test.dart test/profile_notification_recovery_test.dart test/profile_focus_recovery_test.dart test/profile_empty_history_test.dart test/workspace_connection_failure_test.dart test/server_connection_label_test.dart test/server_connection_status_test.dart test/connection_diagnostics_test.dart test/fork/resume_connection_burst_test.dart test/fork/visible_chat_resume_priority_test.dart test/fork/visible_chat_resume_bandwidth_test.dart
```

These regressions cover live-update and overlapping-read races, prolonged
startup/chat/notification outages, capped delays, immediate manual/foreground
recovery, permanent failures, disposal and avoiding duplicate submissions.
`connection_manager_test.dart` also covers the bounded read retry and its
cancellation/write boundaries; `profile_focus_recovery_test.dart` verifies that
an exhausted background HTTP failure leaves healthy chat recovery idle and that
subsequent network loss still recovers.
It also covers responsive route changes and failed live checks during an
overlapping conversation recovery.
`profile_resume_freshness_test.dart` also verifies that a retained chat's
instant reveal does not mark it opening, so dictation stays admitted while
its held resume is still in flight; `fork/resume_connection_burst_test.dart`
verifies a foreground/network-restore resume leaves idle background profiles
disconnected and opens at most the selected profile's socket, that a
background profile with a turn still awaiting admission is resumed too, and
that the selected profile always connects first, alone, before any
background batch starts. `fork/visible_chat_resume_priority_test.dart`
verifies that the selected profile's own visible chat resumes, and the
header leaves Reconnecting, even while several other retained chats of that
same profile are still stuck resuming - so the selected profile's recovery
time does not scale with its retained chat count and never waits on a
background chat the way it never waits on a background profile.
`fork/visible_chat_resume_bandwidth_test.dart` verifies that the visible
chat's own resume stays fast on a throttled (~0.5 MB/s) link regardless of
that chat's saved transcript length or embedded image bytes, and that it
still admits a new turn immediately rather than waiting on its transcript
page.
`server_connection_status_test.dart` verifies the
header's phase and Retry admission ignore a background profile's recovery,
failure or live-socket drop while still reacting to the selected profile's
own state and to startup/notification recovery; `connection_diagnostics_test.dart`
verifies the per-step resume timeline.
`profile_empty_history_test.dart` verifies that an HTTP history failure remains
visible and retryable while the live socket stays connected, and that an explicit
history retry clears the limited status without starting chat recovery.

A continuous backward swipe can cross both earlier setup cards. The chosen card stays visible after release; returning to the address retains completed results younger than five minutes and preserves entered fields. Navigation never extends that window; expired results require another check before advancing or saving. Leaving during a pending check still cancels it.

Transport outages use the existing Alerts presentation, so acknowledgement or
snooze does not leave a duplicate outage banner in the workspace. The status
indicator still opens connection details. A failure specific to opening a chat
keeps local recovery beside the affected view.

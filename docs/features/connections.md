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
The existing header Wing shows recovery while history and drafts remain usable.
The icon-only Retry action remains available between automatic attempts and
disables while a recovery request is running.
Leaving a notification opening or disposing its workspace cancels its retries.

```sh
flutter test --no-pub test/profile_resume_freshness_test.dart test/profile_workspace_controller_test.dart test/profile_notification_recovery_test.dart test/profile_focus_recovery_test.dart test/workspace_connection_failure_test.dart test/server_connection_label_test.dart test/server_connection_status_test.dart
```

These regressions cover live-update and overlapping-read races, prolonged
startup/chat/notification outages, capped delays, immediate manual/foreground
recovery, permanent failures, disposal and avoiding duplicate submissions.

A continuous backward swipe can cross both earlier setup cards. The chosen card stays visible after release; returning to the address retains completed results younger than five minutes and preserves entered fields. Navigation never extends that window; expired results require another check before advancing or saving. Leaving during a pending check still cancels it.

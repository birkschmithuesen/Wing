# Connect to Hermes

Verify and save or import a connection, reopen it securely, and recover from authentication or network failure without accepting a cancelled setup.

Feature ID: `connections`.

## Sub-features

- `connections.verify` — Check credentials, the gateway Webapp address and canonical chat authority in place. Check connection shows progress and results on the sign-in card; Next opens name/save only after success. Edits invalidate the previous check.
- `connections.save` — Persist and reopen the selected connection.
- Saved instance aliases appear in workspace and conversation headers as well as
  the instance picker. Renaming an instance updates a retained workspace without
  replacing its open chat, draft or connection.
- `connections.recover` — Retry authentication or cancel setup safely.

## How to get to it (user POV)

Open connection setup at first launch or use Hermes instances to add or edit an instance. Use Next or swipe left/right between address, sign-in and name/save. Check connection stays on sign-in with its results; Next or a forward swipe opens name/save after all checks pass. Returning from name/save retains verification until connection details change. Save explicitly, or import a shared connection, then reopen it.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/studio_selection_test.dart test/connection_setup_screen_test.dart test/cloud_connection_journey_test.dart test/connection_manager_test.dart test/server_connection_status_test.dart test/live_chat_status_transport_test.dart test/administration_health_test.dart test/connection_setup_session_test.dart test/connection_setup_transport_test.dart test/connection_import_transaction_test.dart test/secure_connection_storage_test.dart test/connection_diagnostics_test.dart
  ```

- **Android `journeys`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran. The setup driver waits for each control to be reachable after keyboard or card movement; step traces and bounded settling identify stalled native actions.

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
through the stock event envelope before admitting session requests. Setup offers
**Edit gateway address** and preserves sign-in fields. A known unsupported endpoint
keeps the shared connection LED and health finding failed even after HTTP success;
a fresh canonical handshake clears that observation. Webapp password sign-in keeps
the gateway-scoped session cookies and sign-in binding within the connection’s
existing origin-bound authentication owner.

For deployed chat readiness, also run the [read-only saved-chat recipe](conversation.md).
Fixture success does not prove the configured deployment can reopen chats.

# Connect apps and configure MCP connectors

Open a connector, edit its configuration or complete its authorization, save for the captured profile, and recover or cancel setup.

Hosted app accounts have their own Connected apps destination. Multiple accounts
for one app keep separate names and exact account identities.

Feature ID: `administration-connectors`.

## Sub-features

- `administration-connectors.received-request` — Resolve a received conversation
  connection request with captured account authorization, Check status and explicit
  Continue; canonical snapshots clear requests no longer pending.
- `administration-connectors.configure` — Edit the captured connector.
- `administration-connectors.authorize` — Complete or cancel its access flow.
- `administration-connectors.recover` — Reconnect or retry without a stale setup taking over.
- `administration-connectors.hosted-accounts` — Browse hosted apps; connect, name,
  reconnect or remove an exact account. Authorization progress follows the server
  operation, and an uncertain write requires refreshing accounts before retry.

## How to get to it (user POV)

Open MCP connectors from Hermes administration or Bot settings. Choose a connector, inspect setup or access, edit supported configuration, and complete its sign-in or reconnection.

For hosted apps, open Administration → Access and connectors → Connected apps,
or the Manage capabilities menu in Skills and tools. Choose the add-link action
beside an app, give the account a name, then open its authorization link. Use
Check authorization to read the result. Each account has separate rename,
reconnect and remove actions. Profile sign-in opens the existing provider-account
editor; merely opening Connected apps never creates an account.

A conversation can also show a received Connect apps request beside its other
pending input. Open the authorization icon for the named account, return and use
Check connection status, then Continue. Suggestions link to the same Connected
apps destination. Opening authorization does not mark an account connected.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/profile_connectors_session_test.dart test/mcp_setup_test.dart test/mcp_oauth_test.dart test/administration_connector_health_test.dart
  flutter test --no-pub test/hosted_connector_accounts_session_test.dart test/upstream_capabilities_ui_test.dart test/hosted_connection_request_test.dart
  ```

- **Device/external entry:** follow the user path on an authorized instance and capture its trigger/result. The host command does not establish that boundary. Report the attempted route and any missing driver or prerequisite.

- **Android administration:** `python3 scripts/test_nightly_native.py administration --output build/feature-verification/administration-connectors`
  includes the named Connected apps draft/failure/retry journey and received
  conversation request/held/failure/retry at both text scales/themes using isolated
  accounts. It verifies the production controls, exact-account save and recovery;
  it does not establish external vendor authorization.

## Gotchas

A connector test may launch its configured program. External authorization requires a real configured account; host OAuth tests do not certify that service.

Hosted connector accounts and MCP server configuration are different inventories.
An expired authorization is not an account deletion. A replaced account remains
visible but cannot be reconnected. A lost mutation response never authorizes an
automatic retry, and changing the selected profile never redirects a pending
operation into the new profile.

Confirmed connector inventories are shared with Health alerts. Removing or
disabling a failed connector clears its alert target on successful readback;
other failed connectors remain actionable. An unavailable readback retains the
last known issue until a subsequent inventory check confirms removal.

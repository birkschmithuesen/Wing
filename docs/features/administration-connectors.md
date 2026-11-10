# Connect apps and configure MCP connectors

Open a connector, edit its configuration or complete its authorization, save for the captured profile, and recover or cancel setup.

Hosted app accounts have their own Connected apps destination. Multiple accounts
for one app keep separate names and exact account identities.

Feature ID: `administration-connectors`.

## Sub-features

- `administration-connectors.received-request` — Resolve a received conversation
  connection request with browser authorization, explicit MCP enable or install
  consent, per-target Skip and Retry, Check status, and Close. Canonical
  snapshots clear requests no longer pending.
- `administration-connectors.runtime` — Read cached runtime/authentication state
  without probing or launching a connector; retain explicit-test provenance.
- `administration-connectors.configure` — Edit the captured connector.
- `administration-connectors.authorize` — Complete or cancel its access flow.
- `administration-connectors.recover` — Reconnect or retry without a stale setup taking over.
- `administration-connectors.hosted-accounts` — Browse hosted apps; connect, name,
  reconnect or remove an exact account. Authorization progress follows the server
  operation, and an uncertain write requires refreshing accounts before retry.

## How to get to it (user POV)

Open MCP connectors from Hermes administration or Bot settings. Choose a connector, inspect setup or access, edit supported configuration, and complete its sign-in or reconnection.

Connector rows and details show cached runtime status separately from the explicit
Test connection result. Sign in again identifies a cached authentication problem;
the existing sign-in action still requires a supported configured connector.
Refresh connectors reads configuration and cached status with visible progress.
A status-read failure keeps the last cached observation with an unavailable notice.

For hosted apps, open Administration → Access and connectors → Connected apps,
or the Manage capabilities menu in Skills and tools. Choose the add-link action
beside an app, give the account a name, then open its authorization link. Use
Check authorization to read the result. Each account has separate rename,
reconnect and remove actions. Profile sign-in opens the existing provider-account
editor; merely opening Connected apps never creates an account.

A conversation shows Connect apps or MCP setup beside its other pending input.
Open the sign-in icon for a named account or MCP server when the browser link is
ready. Return to Wing to see Hermes' result or use Check connection status
under More connection actions. Directory requests open Connected apps with
suggested apps first.

For a pending MCP approval, the power icon enables the named server and the
download icon installs it. Enable shows progress immediately and reports
Enabled once Hermes confirms the change. Review the server-scrubbed command or remote address,
working directory and environment-variable names before approving. If Hermes
requests install credentials, enter them in the card and confirm. Wing sends the
entered values to Hermes and keeps the draft on the current screen. More
connection actions offers Skip for each eligible target. Retry appears on a
failed or expired target. The cross closes the request and returns the
results so far to Hermes. Pending targets remain unapproved.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/profile_connectors_session_test.dart test/mcp_setup_test.dart test/mcp_oauth_test.dart test/administration_connector_health_test.dart test/connector_runtime_test.dart test/connectors_view_dependency_guard_test.dart
  flutter test --no-pub test/hosted_connector_accounts_session_test.dart test/upstream_capabilities_ui_test.dart test/hosted_connection_request_test.dart
  ```

- **Device/external entry:** follow the user path on an authorized instance and capture its trigger/result. The host command does not establish that boundary. Report the attempted route and any missing driver or prerequisite.

- **Android administration:** `python3 scripts/test_nightly_native.py administration --output build/feature-verification/administration-connectors`
  includes the named Connected apps draft/failure/retry journey and received
  conversation request and MCP enable journeys at both text scales and themes
  using isolated fixtures. It verifies the production controls, exact-account
  save, exact-target consent and recovery. External vendor authorization needs
  the separate authorized instance entry.

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

Cached runtime state is scoped by the gateway's available profile runtime. Not
loaded does not mean failed, and ready-on-first-use does not mean a connection
test passed. Cached reads never initiate a test or authorization and do not infer
local versus remote from the transport name. Host runtime tests exercise the real
connector list/detail controls, held refresh, unavailable status and recovery in
both themes at normal/enlarged text, plus cross-profile alert recovery.

Cached status belongs to the configured connector's exact source and plugin owner,
not just its name. A late observation for a replaced same-name connector cannot
appear as the replacement's status or raise/clear its runtime Health incident.

For cached connector observations through Android connected to an existing production gateway,
use the [selected Hermes production recipe](multi-surface-journeys.md#selected-hermes-features-on-an-existing-production-gateway).
Its named outcomes and stated prerequisites distinguish real production actions
from fixture recovery coverage.

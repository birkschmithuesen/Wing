# Diagnose Hermes health

Open health findings or logs, refresh diagnostics, inspect a result and retry a failed read without losing previously received findings.

Feature ID: `administration-health`.

## Sub-features

- `administration-health.inspect` — Read the right diagnostic and timestamp.
- `administration-health.refresh` — Retry while retaining earlier findings.
- `administration-health.ask` — Open a draft for the captured finding.

## How to get to it (user POV)

Choose Hermes health. Open Host, Server or Profile, inspect Doctor/security output or Logs, and use the relevant refresh or retry action. Findings can offer Ask Hermes.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/profile_diagnostics_panel_test.dart test/administration_health_entry_test.dart test/administration_health_session_test.dart test/administration_health_test.dart test/administration_retry_test.dart test/connector_runtime_test.dart
  ```

- **Android `health-entry`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py health-entry --output build/feature-verification/administration-health
  ```

- **Android `administration`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py administration --output build/feature-verification/administration-health
  ```

## Gotchas

Host Server and Profile have independent check times. Ask Hermes prepares an editable draft; it does not send or repair automatically. Configuration checks do not prove model inference or job execution.

Model access shows Access is set up when the native gateway confirms the selected
profile's credentials and resolved model/provider. Missing model/provider data
or a result explicitly naming another profile remains incomplete. The focused
suites above drive refresh/retry and profile switching through the production
Health controls, including native results that do not repeat the profile name.

Connector settings combines separately identified cached runtime/authentication
issues and explicit connection-test results. Passive cached refresh preserves the
original test results and test timestamp; it cannot turn a failed probe into a
passing one. Cached configured, connecting or ready-on-first-use states do not
claim that a probe succeeded. Opening MCP connectors exposes these separate facts
and the existing supported recovery actions.

Scheduled-task health retains an action-needs-review warning for an unconfirmed
Stop, including after a successful refresh or reopening Wing. Current execution
status and cancellation acknowledgement are separate facts; explicit request
review clears the uncertainty without sending another Stop.

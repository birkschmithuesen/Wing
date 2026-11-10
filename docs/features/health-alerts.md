# Investigate and manage health alerts

Configure local thresholds, receive an incident, acknowledge or snooze it, and observe recovery or renewed escalation at the correct time.

Feature ID: `health-alerts`.

## Sub-features

- `health-alerts.connection` — Receive one connection alert per instance when
  server access or live chat is interrupted. Open its connection details to retry;
  acknowledge or snooze it through the existing controls. Repeated failures and
  retries retain the same occurrence. Confirmed server and live recovery clear
  it; unknown observations retain it as last known. A chat-specific opening
  failure on healthy transports does not create a connection alert.
- `health-alerts.operational` — Review failed background reads and service
  updates. A fresh success for the same operation clears its issue.
- `health-alerts.configure` — Save valid local threshold rules.
- `health-alerts.respond` — Acknowledge or snooze the intended occurrence.
- `health-alerts.recover` — Clear or recur only on the qualifying observation.

## How to get to it (user POV)

Choose **Alerts** in the main menu to review active, acknowledged and snoozed
issues. The same viewer opens from **Hermes health → Health alerts** when there
are unresolved issues. The header warning triangle opens issues that need
attention. Opening the viewer dismisses any brief alert announcement.
Acknowledge or snooze an issue in the viewer, or open its recovery destination
when available. To change monitoring rules, choose **Hermes health → Alert settings**.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/health_alerts_test.dart test/health_alerts_ui_test.dart test/administration_connector_health_test.dart test/administration_health_session_test.dart test/connector_runtime_test.dart
  ```

  The two Alerts suites cover the empty main-menu viewer, retained acknowledged
  and snoozed issues, connection and operational alerts with Health monitoring
  off, and independent host-read recovery after the shared refresh settles.

- **Android `health-normal`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py health-normal --output build/feature-verification/health-alerts
  ```

- **Android `health-large`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py health-large --output build/feature-verification/health-alerts
  ```

- **Android `health-retention`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py health-retention --output build/feature-verification/health-alerts
  ```

## Gotchas

The Health alerts switch controls host threshold and profile health monitoring.
Connection and operational issues remain available with monitoring off. They
use the existing connection and read owners. Background failures covered by a
known server access outage share its connection incident. The connection status
indicator remains available when an alert is silenced. The connection outage
and recovery-control cases in the host suites cover acknowledgement,
snooze/restart, unknown and partial recovery, failed and successful retry,
both themes and enlarged text. Capture the recovery UI
with `--dart-define=CAPTURE_ALERTS=true` and
`--dart-define=CAPTURE_ALERT_DIR=build/design-previews/connection-alerts`.

These are device-local in-app alerts, distinct from Android notifications. Durations, hysteresis, snooze deadlines and fresh recovery determine the outcome; a warning icon alone is not proof.

Connector failures clear when a confirmed inventory read shows their failed
connectors removed or disabled, including readback after Remove connector.
While collection is active, unresolved connector issues get inventory-only
checks every 15 seconds and on foreground resume, using the captured profile
even when another profile is selected. This includes acknowledged and snoozed
issues. Unavailable or incomplete reads retain the issue; deleting one of several
failed connectors retains the others. Recovery persists across restart. These
checks never run connection probes or launch connector programs.

The host suites above cover the real alert → connector → Remove connector path
in both themes and text scales, automatic cross-profile checks, unavailable
reads, resume, saved-incident recovery and late inventory completions.

Cached authentication/runtime problems use a distinct Connector runtime incident
inside the same alert owner. Fresh connected, disabled or ready-on-first-use
runtime can clear that incident; it cannot clear an explicit probe failure.
Configured, connecting, missing or unavailable runtime retains an earlier issue
as last known. Confirmed membership removal/disable still retires the appropriate
target, including when another profile is selected. An older pending read cannot
revive the target after a configuration mutation.

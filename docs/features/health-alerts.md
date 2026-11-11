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
- `health-alerts.respond` — Acknowledge or snooze the intended occurrence, or undo either choice.
- `health-alerts.recover` — Clear or recur only on the qualifying observation.

## How to get to it (user POV)

Choose **Hermes health** in the main menu. The **Alerts** section lists current
issues, including acknowledged and snoozed ones, and shows **No current alerts**
when the list is empty. Tap a row to review that issue, acknowledge or snooze
it, undo a choice, or open its recovery destination when available. The header
warning triangle opens a Quick view anchored beneath it, with issues that need
attention. Both views show a tick for acknowledged issues and a snooze icon with
the expiry time. Opening either view dismisses any brief alert announcement. Tap the sliders beside **Alerts** to open
**Alert settings** and edit this device's monitoring rules.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/health_alerts_test.dart test/health_alerts_ui_test.dart test/administration_connector_health_test.dart test/administration_health_session_test.dart test/connector_runtime_test.dart
  ```

  The two Alerts suites cover drawer entry into the inline empty state, retained
  acknowledged and snoozed rows, reversal, anchored card geometry during
  saves and recovery while the selected issue is open. They also cover
  profile, connection and operational alerts with host monitoring off and
  independent host-read recovery after the shared refresh settles.

- **Android `health-normal`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py health-normal --output build/feature-verification/health-alerts
  ```

  The normal and enlarged Android scenarios open the inline list through the
  drawer, verify snoozed and acknowledged rows, and edit a threshold through
  the Alert settings icon with the Android keyboard.

- **Android `health-large`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py health-large --output build/feature-verification/health-alerts
  ```

- **Android `health-retention`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py health-retention --output build/feature-verification/health-alerts
  ```

## Gotchas

The Health monitoring switch controls CPU, memory and disk alerts. Profile
monitoring has its own switch. Profile, connection and operational issues
remain available with host monitoring off. They
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

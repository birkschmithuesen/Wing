# Inspect server resource usage

Open server CPU, memory and storage observations, refresh or revisit them, and keep received data readable if a later read fails.

Feature ID: `host-resources`.

## Sub-features

- `host-resources.read` — Inspect the captured host observations.
- `host-resources.refresh` — Request current resource samples.
- `host-resources.retain` — Keep last known data qualified after read failure.

## How to get to it (user POV)

Choose Hermes health and open Host or its machine row. Inspect CPU, memory, disk and uptime, refresh, or leave and return to the retained observations.

If a resource or pressure read fails, review the issue from the main menu's
[Alerts](health-alerts.md). The issue opens Hermes health for recovery. A fresh
success clears the issue for that reading.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/host_resources_session_test.dart test/host_health_view_test.dart test/health_alerts_test.dart
  ```

- **Android `health-normal`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py health-normal --output build/feature-verification/host-resources
  ```

## Gotchas

Unavailable measurements stay unavailable. API-process memory is not all agent memory. Controlled resource samples establish presentation and recovery, not the real server load.

Host read issues come from the shared refresh after both reads settle. A failure
can remain unresolved while the other read recovers. These issues can appear
with Health monitoring off when another view requests a read.

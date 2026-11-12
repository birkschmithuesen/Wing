# Connect through a cloud account

Discover an account, complete authorization and open its Hermes connection; cancel or retry without a late authorization taking over the new setup.

Feature ID: `cloud-access`.

## Sub-features

- `cloud-access.discover` — List the account connections.
- `cloud-access.authorize` — Complete or cancel authorization.
- `cloud-access.retire` — Leave setup without accepting a late completion.

## How to get to it (user POV)

In connection setup choose Hermes Cloud, select the cloud account and complete its authorization handoff; return to the selected Hermes workspace.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/hermes_cloud_test.dart test/cloud_connection_journey_test.dart
  ```

- **Device/external entry:** follow the user path on an authorized instance and capture its trigger/result. The host command does not establish that boundary. Report the attempted route and any missing driver or prerequisite.

## Gotchas

Host routes use a controlled authorization boundary. Actual cloud sign-in needs an account and system-browser access; a widget result is not proof of that external handoff.

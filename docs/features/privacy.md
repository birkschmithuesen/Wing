# Read the privacy policy

Open the bundled policy from Settings, read it offline at enlarged text in either theme, and return to Settings.

Feature ID: `privacy`.

## Sub-features

- `privacy.open` — Reach the bundled policy from Settings.
- `privacy.read` — Keep content readable offline at enlarged text.
- `privacy.return` — Close the policy back to Settings.

## How to get to it (user POV)

Open App settings and choose Privacy policy. Read the bundled document offline, enlarge text or switch theme, and return to Settings.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/privacy_policy_screen_test.dart
  ```

- **Device/external entry:** follow the user path on an authorized instance and capture its trigger/result. The host command does not establish that boundary. Report the attempted route and any missing driver or prerequisite.

## Gotchas

The mapped command is a real-asset widget route, not an Android device or network-policy certification. The policy is bundled; a network connection must not be needed to read it.

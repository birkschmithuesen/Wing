# Manage profiles

Create, select, edit or delete the intended profile; retain editable details after a rejected or conflicting save.

Feature ID: `profiles`.

## Sub-features

- `profiles.create` — Create or duplicate a profile.
- `profiles.identity` — Edit only the intended profile.
- `profiles.conflict` — Keep drafts after a rejected or conflicting save.

## How to get to it (user POV)

Choose a profile from the workspace profile picker. Open Hermes administration or Bot settings to edit the captured profile; use the supported profile-management actions to create, duplicate or delete it.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/profiles_management_session_test.dart test/profile_management_owned_transport_test.dart test/profile_identity_edit_session_test.dart
  ```

- **Android `journeys`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py journeys --output build/feature-verification/profiles
  ```

## Gotchas

The default profile cannot be deleted or have its underlying identity renamed. A bot display name differs from its profile identifier. Stock-backend CRUD requires the disposable stock runner.

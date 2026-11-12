# Configure provider access

Inspect and edit credentials or complete device/OAuth sign-in for the intended profile; retry, cancel or leave without a stale attempt publishing credentials.

Feature ID: `administration-providers`.

## Sub-features

- `administration-providers.metadata` — Read the selected profile credential state.
- `administration-providers.credentials` — Save or remove only an admitted key.
- `administration-providers.signin` — Complete cancel or retire provider authorization.

## How to get to it (user POV)

Open Hermes administration or Bot settings for the intended profile, then Provider access. Inspect credentials, manage a key, or start the supported sign-in/renewal flow.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/provider_credential_lifetime_test.dart test/provider_recovery_screen_test.dart test/provider_device_sign_in_session_test.dart
  ```

- **Android `administration`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py administration --output build/feature-verification/administration-providers
  ```

## Gotchas

Stored metadata is not proof of provider quota or generation. Key removal does not revoke the upstream account. Actual OAuth or device sign-in needs that provider/account and explicit mutation approval.

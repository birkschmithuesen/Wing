# Navigate and recover administration

Open the intended instance or profile administration area, inspect its data and retry a failed operation with the captured scope retained.

Feature ID: `administration`.

## Sub-features

- `administration.scope` — Open the selected instance and profile.
- `administration.navigate` — Reach a supported editor.
- `administration.recover` — Keep received data readable after failure.

## How to get to it (user POV)

Choose Hermes administration from the drawer or open Bot settings for a chosen bot. Select the intended profile and open an editor or diagnostic destination; return and retry a failed read.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/administration_health_test.dart test/server_connection_label_test.dart test/administration_transport_test.dart test/administration_navigation_test.dart test/administration_recovery_test.dart
  ```

- **Android `administration`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py administration --output build/feature-verification/administration
  ```

## Gotchas

Bot settings does not switch the chat workspace profile. Refresh reads configuration; it does not run every diagnostic or tool.

Health uses the connection owner's observed chat endpoint support. A reachable
standalone Dashboard remains a failed connection finding even when provider
configuration is healthy; HTTP success cannot clear it. The shared header LED
shows **Chat address needs changing**, and its details explain the address repair.

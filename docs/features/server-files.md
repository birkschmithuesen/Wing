# Browse and manage server files

Browse within the captured profile, create or choose a folder, upload or change a file, and recover from a failed operation.

Feature ID: `server-files`.

## Sub-features

- `server-files.browse` — List files and folders in the intended scope.
- `server-files.select` — Choose a file or project folder.
- `server-files.mutate` — Create or change an item and recover from failure.

## How to get to it (user POV)

Open the server folder browser from a composer @ reference or a project folder picker. Browse upward, create or select a folder, or choose a file for the current operation.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/server_files_repository_test.dart test/server_files_browser_test.dart
  ```

- **Android `file-transfer`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py file-transfer --output build/feature-verification/server-files
  ```

## Gotchas

Server filesystem operations belong to the captured connection/profile. Android file-transfer coverage does not by itself establish every server-folder entry point.

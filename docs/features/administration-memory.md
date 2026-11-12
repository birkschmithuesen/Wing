# Inspect retained memory

Query and filter profile memory, open a detail and retry failed reads, keeping existing observations and preventing publication from a retired visit.

Feature ID: `administration-memory`.

## Sub-features

- `administration-memory.query` — Search or filter the selected memory.
- `administration-memory.detail` — Read an admitted entry.
- `administration-memory.recover` — Retain observations and ignore a retired visit.

## How to get to it (user POV)

Open retained memory from the selected profile administration. Search or filter entries, open a detail and return; retry a failed read.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/retained_memory_session_test.dart test/retained_memory_view_test.dart
  ```

- **Device/external entry:** follow the user path on an authorized instance and capture its trigger/result. The host command does not establish that boundary. Report the attempted route and any missing driver or prerequisite.

## Gotchas

Retained memory is read-only in Wing: entry editing and deletion are unavailable. Host tests drive the widget route; a live device path requires memory supplied by its captured profile.

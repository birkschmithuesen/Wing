# Navigate and resume work

Open Wing, choose Chats or a launcher shortcut, enter a conversation, then return or reopen it with the draft retained.

Feature ID: `app-shell`.

## Sub-features

- `app-shell.enter` — Open the intended workspace.
  The first workspace frame remains independent of Recents preparation. Once
  initialization completes, its shared catalog warms quietly for later entry.
- `app-shell.return` — Return to its canonical list.
- `app-shell.restore` — Reopen with the separate draft retained.

## How to get to it (user POV)

Open the navigation drawer and choose Chats; enter a chat and choose Chats again. Also use the Android launcher Quick Chat, Recents and Search chats shortcuts.

Choose **Alerts** in the navigation drawer to review unresolved issues, including
acknowledged and snoozed ones. Close the viewer to return to the current
workspace. The [Alerts recipe](health-alerts.md) covers this entry and its empty
state.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/app_shell_navigation_test.dart test/android_launch_intent_service_test.dart
  flutter test --no-pub test/profile_recents_visibility_test.dart
  ```

- **Android `journeys`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py journeys --output build/feature-verification/app-shell
  ```

## Gotchas

Opening a chat is not permission to mark its messages read. Drawer return keeps the unsent draft.

# Keep ownership across Android transitions

Leave or reopen Wing, receive an Android intent or share, and resume the intended work while background monitors and native resources follow their owner lifetimes.

Feature ID: `platform-lifecycle`.

## Sub-features

- `platform-lifecycle.resume` — Reenter the intended captured workspace. Window focus recovery applies Android's current keyboard geometry, including when an interrupted animation never delivered its end callback. See the [keyboard regression](chat-inputs.md#driving-it-with-wing-harnesses).
- `platform-lifecycle.monitor` — Share and retire background work correctly.
  Pausing stops Recents display polling and catalog projections immediately,
  even when Android renders no final frame. Background replies and notifications
  continue; reopening catches up the preview and unread state.
- `platform-lifecycle.intent` — Handle native entry without crossing draft ownership.

## How to get to it (user POV)

Leave Wing with Android Home and reopen it, or open it through a supported launcher/share/notification intent. Observe the intended draft, work and background-monitor state.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/background_monitoring_service_test.dart test/android_share_intent_service_test.dart
  flutter test --no-pub --dart-define=WING_PERF_INSTRUMENTATION=true test/profile_recents_test.dart
  flutter test --no-pub test/recent_conversation_switcher_test.dart --plain-name 'ordinary chat pinch activates Recents and preserves draft'
  ```

  Recents checks cover five paused minutes without a final frame, late visibility
  callbacks, repeated connection-status observations and background reply delivery
  followed by fresh preview/unread state on resume.

- **Android `background`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py background --output build/feature-verification/platform-lifecycle
  ```

- **Android `platform-plugins`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py platform-plugins --output build/feature-verification/platform-lifecycle
  ```

Live voice uses a microphone/media foreground service and a separate retained-engine lease. Home and screen lock keep the call; microphone/service teardown retires the lease. Calls are not resurrected after process death. The voice native recipe verifies the call separately from notification monitoring; see [voice](voice.md).

## Gotchas

Owner recreation is not OS process death. Battery exemption, Android permissions and OEM background rules are separate boundaries. Never drive an existing physical phone for a disposable recipe.

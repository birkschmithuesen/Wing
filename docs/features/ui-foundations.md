# Use accessible and responsive controls

Use shared selection, loading, focus and recovery controls across themes and text sizes, with visible feedback while an action settles and retained reader state.

Feature ID: `ui-foundations`.

## Sub-features

- `ui-foundations.feedback` — Show immediate visible action progress through settlement. Transient failures use tinted, actionless capsules beside their source controls; persistent repair uses the same error family.
- `ui-foundations.access` — Keep selection focus and controls usable.
- `ui-foundations.phone-reading` — Open wide tables as horizontally scrolling grids, with stacked rows available from the toolbar; compact conversation controls on landscape phones. Table full screen enters reading mode directly, with no duplicate header action.
- `ui-foundations.retain` — Preserve reader and recovery state.

## How to get to it (user POV)

Use a shared selection control, form, dialog or reader in light/dark themes and enlarged text. Start and fail a refresh or save while keeping the rest of its page usable.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/phone_reading_test.dart test/studio_loading_test.dart test/studio_selection_test.dart test/profile_focus_recovery_test.dart test/studio_error_test.dart
  ```

- **Android `journeys`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py journeys --output build/feature-verification/ui-foundations
  ```

## Gotchas

A controller busy flag does not prove visible feedback. Check the immediate header/region response and reachable icon actions. Human TalkBack use is distinct from host semantics.

Transient capsules expire after four seconds, extended by Android’s accessibility
timeout (Android 10 or newer). They support swipe and accessible dismissal,
retire on departure/backgrounding, and preserve input focus. Retry clears the
previous attempt; unrelated typing does not. The shared host suite checks
source clearance, deduplication, collision, lifecycle and both themes at enlarged
text. Device accessibility timing and real keyboard behavior need Android proof.
Operational conditions use [Alerts](health-alerts.md), including acknowledgement
and snooze; local save/validation errors retain drafts and recovery controls.

Compact attachment errors use the same error family with the status icon above
the text. Long errors remain readable and their recovery controls stay reachable
at enlarged text sizes. `test/studio_error_test.dart` covers compact cards and
acknowledgement-dialog sizing alongside capsule behavior.

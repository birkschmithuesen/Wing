# Respond and return from notifications

Receive a reply or input request, act on or open the exact conversation, then read or dismiss it without reviving a settled or dismissed notice.

Feature ID: `notifications`.

## Sub-features

- `notifications.route` — Open the exact notification owner. Reply alerts show the beginning of the answer, including answers longer than the screen, after formatted content settles.
- `notifications.act` — Answer a supported request without duplication, retaining its exact request and turn identity. Command review uses the same exact-command and request-details content as normal, bot and group chats, while keeping the selected notification approval scope explicit.
- `notifications.settle` — Seeing a saved answer clears a newly recorded reply notice even when that viewport already recorded its read receipt. Keep read, dismissed and restored notices consistent.
- `notifications.monitor` — Watch ongoing work in a compact summary of up to
  three chats or discussions, followed by the remaining count. Unnamed sessions
  include a short session ID. A single watched conversation opens directly;
  multiple conversations open Recents, including when some rows are omitted.
  Initialization alone never starts work monitoring. A validated live-session
  snapshot retires watches for runtimes that have disappeared without inventing
  a completion alert; failed reads retain previously verified work.
  Detached child tasks and background processes reported for a connected
  profile also keep monitoring alive, without opening their parent chat.
  The same conversation appears once across live and detached observations.
  Failed roster reads retain its last known work as reconnecting; a successful
  empty roster retires that observation without generating a reply alert.
  Repeated observations of a certain, still-working runtime refresh its verified
  owner's metadata without checking unrelated profiles. Input, completion,
  changed identities and uncertainty keep full ownership verification. These
  observations do not save unchanged conversation history.

## How to get to it (user POV)

While Wing monitors work, receive a reply or input request in the Android notification shade. Open its exact chat, respond through supported actions, then read or dismiss the notice.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/notification_answer_visibility_test.dart test/group_notification_session_test.dart test/profile_notification_coverage_test.dart test/app_notification_routing_test.dart test/notification_approval_review_test.dart test/native_prompt_controller_test.dart
  ```

  The queued native cold-tap case includes the notification device fixture's
  restart setup. It must preserve the captured profile/chat, reuse both existing
  chats and display the answer above the remembered workspace route.
  Restored profiles must also admit a later message and publish its reply
  without changing the selected chat during recovery.
  Startup Recents reads must preserve the retained notification stream and its
  later reply events. The background device fixture supplies the independent
  Bots transport too; it must not contact a real server during catalog warming.
  Repeated questions use distinct request identities in live events and
  recovery snapshots, so a later question stops monitoring after earlier work
  was answered and completed.

  Long-answer cases verify the first line is visible after Markdown settles,
  in both themes at 390 dp/100% and 320 dp/200%. A visible latest saved
  answer is acknowledged without an extra scroll once a prepared body line is
  visible. Avatars and clipped leading space cannot acknowledge an unseen answer.
  Hidden/background readers,
  failed history and model-only rows cannot acknowledge an unseen answer.

  For monitoring summaries and outage recovery, run:

  ```sh
  flutter test --no-pub test/background_monitoring_activity_test.dart test/notification_outage_recovery_test.dart test/profile_workspace_registry_test.dart
  ```

  The many-unnamed-chats case retains twelve distinct unfinished chats through
  an outage while displaying three identifiable rows and `9 more chats`. Recovery
  updates the count, restores single-chat tap routing and removes the summary
  after all work finishes. Existing cases cover bot names, shared discussions,
  connection isolation and uncertain completion.
  The outage suite also checks that initializing twelve unopened chats and an
  idle loaded chat starts no watch, disappeared/replaced runtimes retire, and
  an unrelated metadata failure cannot retain an absent runtime. Invalid
  snapshots and unknown states preserve verified work.
  `test/detached_work_test.dart` covers profile-scoped detached discovery,
  transport reuse, overlap, failed versus empty rosters, metadata isolation,
  late responses and obsolete connection retention. It also opens the
  production Recents row in both themes at normal and enlarged text.
  A profile the connected gateway permanently refuses (profile mismatch or
  unavailable) is remembered as not served and stops being polled for
  detached work or browsed for its canonical chat on every reconciliation
  tick; a served profile keeps polling normally. Retried only after an
  explicit refresh or a new gateway connection. See the `connections`
  feature's `profile_workspace_controller_test.dart` and
  `workspace_connection_failure_test.dart` coverage for the retry-storm
  suppression and its retryable/permanent split. The same status also hides
  the profile from being a selectable chat filter; see `chat-browser.find`
  in [chat-browser](chat-browser.md) for the disabled picker treatment.
  Shared-discussion monitoring reads a dedicated profile for group chats,
  independent of which profile is connected; the same remembered-refusal
  cache applies, so a gateway that does not serve that profile stops
  reconnecting for it after the first refusal instead of reopening a socket
  on every background poll.

- **Android `notification-actions`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py notification-actions --output build/feature-verification/notifications
  ```

- **Android `notification-restore`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py notification-restore --output build/feature-verification/notifications
  ```

- **Android `notification-counts`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py notification-counts --output build/feature-verification/notifications
  ```

- **Android `notification-cold`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py notification-cold --output build/feature-verification/notifications
  ```

Active live voice has its own ongoing Android notification with Mute/Unmute, End voice and return-to-chat actions. Its service lifetime is independent of ordinary chat notification monitoring. See [voice](voice.md).

## Gotchas

Use only the owned QA package. Android notification permission and battery policy are prerequisites. Opening, reading and dismissing are different actions; verify restore and cold entry separately.

For detached work discovery through Android connected to an existing production gateway,
use the [selected Hermes production recipe](multi-surface-journeys.md#selected-hermes-features-on-an-existing-production-gateway).
Its named outcomes and stated prerequisites distinguish real production actions
from fixture recovery coverage.

App settings shows a persistent error when background notification monitoring
fails. Its Retry icon shows progress until the monitoring attempt settles and
disables duplicate taps. `test/background_monitoring_settings_test.dart` covers
failure, held retry and recovery in both themes and text sizes.

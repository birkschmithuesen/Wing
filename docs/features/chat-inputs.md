# Send, steer and revise work

Write and send, queue or steer a prompt, edit a queued or saved message, regenerate or fork an answer, and recover a draft or uncertain submission after interruption.

Feature ID: `chat-inputs`.

## Sub-features

- `chat-inputs.send` — Submit once and preserve newer unsent text. A sent message stays one bubble when Hermes begins processing it, including when processing starts before acknowledgement. Separate submissions with identical text remain separate. When leaving after Send, [conversation reading position](conversation.md) retains the sent-message boundary so the reply opens at its beginning.
- `chat-inputs.landscape` — Normal chats, Bot Chats and group discussions use the same responsive composer. Read with a one-row composer on landscape phones. Send/Stop stays visible; expand the controls to reach attachments, context and model options. With the keyboard open, the field and Send/Stop stay on one row; expanding dismisses the keyboard.
- `chat-inputs.identity` — Every writable conversation and its Recents preview uses the same message field and toolbar arrangement. Attachment controls start at the left and Send/Stop stays at the right, even when a discussion has fewer controls. Dictation stays inside the field. Attach file opens the same Camera/Photos/Files bottom sheet in normal chats, Bot Chats and discussions; Camera is disabled when capture is unavailable. Attached image thumbnails open the same viewer with visible loading and failure feedback.
- Dismissing the Android keyboard restores the composer to the bottom, including interrupted keyboard animations and returning from another app. Drafts stay intact; a still-visible keyboard retains its space.
- `chat-inputs.queue` — Hermes owns the accepted FIFO; edits retain authored text and selected references and replace a still-queued message at the tail, steering transfers that exact admission to the current turn, and cancellation names its admission. The queue starts as a compact expandable count. Unknown outcomes, unconfirmed delivery and steering failures remain visible while collapsed. Details retain complete selectable text and exact Copy. Unsupported actions are omitted; supported actions explain temporary restrictions when tapped. Notes and continuation requests from the remote screen are queued independently and preserve the main draft, references and attachments, even when the text matches.
- `chat-inputs.revise` — Edit, restore or regenerate using revision-fenced saved row targets. Deep revision explains the number of later user turns removed; harmless last-turn regeneration remains immediate. Fork requires an idle source and a saved active answer. After context compression it copies the active context, including the hidden summary, through that answer; archived turns remain in the original chat.
- `chat-inputs.clarify` — Use the explicit icon in a waiting question to answer with plain composer text. Slash commands, references and attachments retain their own submission semantics. A newer draft is never consumed by an earlier answer.

Group message Reply selects an existing discussion thread and mentions its member author. Cancel reply clears that selection. The room draft retains reply context across reopening and uncertain-send retry; see [Bots](bots.md).

## How to get to it (user POV)

Write in the chat composer and Send. The GPT-Live waveform sits beside the dictation microphone; the + attachment action stays in the toolbar. Hold the action button for steer or queue choices. Expand the queued count, then tap or long-press a message to open the same detail/action sheet and choose Edit; use saved-message actions to edit or Restore and saved-answer actions to regenerate or fork.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  `flutter test --no-pub test/conversation_assembly_test.dart` checks the actual
  attachment glyph position and target width across normal and group routes,
  both themes, enlarged text, portrait keyboard and expanded landscape states.
  It opens the attachment sheet through both production routes, checks its icon
  rows and cancellation, and verifies shared source dispatch and availability.
  `flutter test --no-pub test/recent_conversation_switcher_test.dart --name 'group passive card'`
  checks the same geometry in passive group previews without enabling actions.

  The native keyboard regression replays Android's resume sequence against
  Flutter's actual inset callback: an animation without a new inset delivery
  must not restore the previous animation's keyboard height. It also checks
  normal intermediate frames and preservation of a still-visible keyboard:

  ```sh
  (cd android && ./gradlew :app:testDebugUnitTest --tests io.flutter.plugin.editing.ImeAnimationCacheTest)
  ```

  These JVM checks establish native inset delivery. `phone_reading_test.dart`
  checks the resulting composer layout and draft retention in both themes and
  at enlarged text; physical keyboard transitions remain a separate device check.

  ```sh
  flutter test --no-pub test/phone_reading_test.dart test/profile_composer_queue_test.dart test/profile_composer_actions_test.dart test/profile_prompt_reply_transport_test.dart test/profile_vault_server_request_test.dart test/canonical_session_protocol_test.dart test/composer_steering_delivery_test.dart test/saved_message_actions_test.dart test/native_prompt_controller_test.dart test/profile_question_delivery_test.dart test/profile_references_test.dart
  ```

- **Fork after compression:** `flutter test --no-pub test/answer_versions_test.dart`
  drives the saved-answer Fork control through held preparation, creation and
  readback, failure and retry, both themes and enlarged text. It checks that a
  valid compressed fork opens, the original stays intact, an archived target is
  refused before creation, and genuinely missing, extra or changed copied
  messages still fail validation. Independent stock-shaped source/child snapshots
  verify reopen with new saved row IDs, numeric archive flags, retained tool rows,
  differing RPC display text, and compressed histories across the 500-row page
  boundary. Corrupting the hidden summary also fails validation.

- **Android `journeys`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py journeys --output build/feature-verification/chat-inputs
  ```

- **Android `queue-editing`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py queue-editing --output build/feature-verification/chat-inputs
  ```

The waveform action starts live voice using the saved subscription/API choice. New queued voice work carries Hermes’s native voice surface and recent spoken context through the durable outbox. Voice work is independently queued or steered without consuming the typed draft; dictation is unavailable during a call. See [voice](voice.md).

Secure-input replies are covered by
`flutter test --no-pub test/profile_prompt_reply_transport_test.dart test/sensitive_server_request_test.dart test/profile_sensitive_prompt_delivery_test.dart test/profile_vault_server_request_test.dart test/gateway_sensitive_prompt_panel_test.dart`.
Enter a requested secret in its dedicated masked form and use its icon-only
confirmation. The form shows submitting feedback until Hermes confirms the
original request resolved. Cancel sends an empty response. Timeout, interruption
and connection loss never imply that the password was accepted; passwords stay
outside drafts and saved history and are never replayed after reconnect.

## Gotchas

Tap and long-press share the queued-message detail/action sheet. Support,
current eligibility and rejection wording come from the queue owner and update
while the sheet is open. `profile_composer_actions_test.dart` covers the compact
count, bounded expansion, full text and exact copy with held feedback, visible
unknown/uncertain outcomes while collapsed, capability changes, temporary
restriction explanations, attachment-action omission and draft preservation.
The render matrix uses both themes at 390 dp/normal text and 320 dp/200% text.
`composer_steering_delivery_test.dart` distinguishes unsupported edits, unknown
outcomes and removed entries; `profile_composer_queue_test.dart` covers exact
server admission identity and cancellation/steering. Run:

```sh
flutter test --no-pub test/profile_composer_actions_test.dart test/composer_steering_delivery_test.dart test/profile_composer_queue_test.dart
```

The pending API has no reliable internal-message discriminator. Keep unclassified
entries inspectable without guessing from their text or missing controls. Typed
process updates already use [Activity](chat-activity.md); its existing receipt
rendering remains the destination when those facts arrive.

A clarification set appears in one form. Stage every answer, including explicit
per-question skips, then use the single confirmation action. Hermes locks answers
in order; if a later lock fails, confirmed answers stay locked and remaining
answers remain editable. Answers from another device and expired requests retire
the matching controls. Skip clarification cancels the request while retaining answers already locked by Hermes.
With the keyboard open, pending input keeps room for its actions while a tall
composer scrolls. On short screens, the input-navigation control uses a separate
side gutter so it cannot cover the form's actions. The clarification heading,
questions and partial-answer error share a scroll area above the fixed action
footer, keeping failure recovery reachable at enlarged text. The minimum and
landscape cases in `profile_question_delivery_test.dart` verify error reveal,
retained answers, held retry feedback and the unchanged composer draft.

A cut-off reply or exhausted turn budget offers an explicit Continue action.
It submits a new continuation while preserving the composer draft. Model and
provider recovery never automatically resend the failed request. Local endpoint
failures offer model recovery and endpoint guidance, without provider sign-in.

```sh
flutter test --no-pub test/gateway_clarify_test.dart test/profile_question_delivery_test.dart test/profile_prompt_reply_transport_test.dart test/turn_failure_test.dart
```


Accepted steering stays compact only until Hermes adds the message to saved
history. It then becomes a normal user bubble with formatted text and Copy;
reopened chats show saved steering in that same form. The `steer becomes a
normal bubble in saved history` cases drive Steer, acceptance, history refresh
and Copy in both themes at normal and enlarged text. Projection and cache
restoration are covered by:

```sh
flutter test --no-pub test/profile_steering_feedback_test.dart test/profile_composer_actions_test.dart test/workspace_reading_snapshot_test.dart test/reading_snapshot_message_test.dart
```

The `one sent bubble through processing start` cases in
`profile_composer_actions_test.dart` drive Send with a held acknowledgement and
check both event orders, history replacement and separate identical-text inputs
in both themes at normal and enlarged text sizes. The attachment case in
`profile_message_presentation_test.dart` checks that the original authored text,
attachment and presentation identity survive the start event:

```sh
flutter test --no-pub test/profile_composer_actions_test.dart test/profile_message_presentation_test.dart
```

Successful acceptance uses the receipt and live queue updates without an extra
conversation refresh. A newer processing event must not become a false
"Remaining unsent work could not be saved" warning or pause the queue. The same
Send cases exercise this race; `profile_composer_queue_test.dart` also verifies
that a genuine local save failure still reports the problem without resending
accepted work.

A fresh Send with an empty outbox proceeds after a stopped or failed reply,
even if an earlier empty queue was paused. Older paused or uncertain messages
stay held. Tap a queued row and use **Resume queued messages** to continue them.
The `fresh Send after` host cases cover terminal replies and removing the last
paused item. Resume-only failure and direct-error cases keep older work durably
paused until explicit Resume. `fresh Send after interruption shows delivery feedback` drives the
actual Send button with held acceptance in both themes at normal/enlarged text:

```sh
flutter test --no-pub test/profile_composer_queue_test.dart test/profile_queue_submission_ownership_test.dart test/profile_composer_actions_test.dart
```

A lost acknowledgment retains the original submission ID and exact prepared payload before dispatch. Recovery may query that same idempotent input by replaying its exact request; it never creates a fresh input from matching text. Unknown execution requires explicit acknowledgment of that admission and generation, without rerunning it. Server-accepted work survives phone process death. Local upload and unsent draft preparation remain on the phone. Secret input must not enter durable draft/history storage. Provider generation needs separately authorized disposable QA state.

For authorized Android + production acceptance, use the `sessions` suite in the
[existing-gateway journey](multi-surface-journeys.md#selected-hermes-features-on-an-existing-production-gateway).
It verifies real batch answers and a distinct model reset in owned QA chats.

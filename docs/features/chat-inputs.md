# Send, steer and revise work

Write and send, queue or steer a prompt, edit a queued or saved message, regenerate or fork an answer, and recover a draft or uncertain submission after interruption.

Feature ID: `chat-inputs`.

## Sub-features

- `chat-inputs.send` — Submit once and preserve newer unsent text. A sent message stays one bubble when Hermes begins processing it, including when processing starts before acknowledgement. Separate submissions with identical text remain separate. When leaving after Send, [conversation reading position](conversation.md) retains the sent-message boundary so the reply opens at its beginning.
- `chat-inputs.landscape` — Normal chats, Bot Chats and group discussions use the same responsive composer. Read with a one-row composer on landscape phones. Send/Stop stays visible; expand the controls to reach attachments, context and model options. With the keyboard open, the field and Send/Stop stay on one row; expanding dismisses the keyboard.
- `chat-inputs.queue` — Hermes owns the accepted FIFO; edits retain authored text and selected references and replace a still-queued message at the tail, steering transfers that exact admission to the current turn, and cancellation names its admission. Unsupported controls remain unavailable. Notes and continuation requests from the remote screen are queued independently and preserve the main draft, references and attachments, even when the text matches.
- `chat-inputs.revise` — Edit, restore or regenerate using revision-fenced saved row targets. Deep revision explains the number of later user turns removed; harmless last-turn regeneration remains immediate. Fork requires an idle source.
- `chat-inputs.clarify` — Use the explicit icon in a waiting question to answer with plain composer text. Slash commands, references and attachments retain their own submission semantics. A newer draft is never consumed by an earlier answer.

## How to get to it (user POV)

Write in the chat composer and Send. Hold the action button for steer or queue choices. Open queued work to edit it; use saved-message actions to edit or Restore and saved-answer actions to regenerate or fork.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/phone_reading_test.dart test/profile_composer_queue_test.dart test/profile_composer_actions_test.dart test/profile_prompt_reply_transport_test.dart test/profile_vault_server_request_test.dart test/canonical_session_protocol_test.dart test/composer_steering_delivery_test.dart test/saved_message_actions_test.dart test/native_prompt_controller_test.dart test/profile_question_delivery_test.dart test/profile_references_test.dart
  ```

- **Android `journeys`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py journeys --output build/feature-verification/chat-inputs
  ```

- **Android `queue-editing`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py queue-editing --output build/feature-verification/chat-inputs
  ```

## Gotchas

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

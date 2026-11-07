# Choose a model and reasoning settings

Browse provider/model choices, inspect supplied settings, apply the intended change and handle its confirmation or rejection in the captured profile.

Feature ID: `model-selection`.

## Sub-features

- `model-selection.choose` — Browse and inspect supplied model options.
- `model-selection.apply` — Confirm the captured model and reasoning in one canonical mutation. While a turn is running, an accepted deferred choice appears as Next turn; the effective model remains unchanged until the server applies it. Reopening the picker starts from the pending choice.
- `model-selection.reject` — Retain the previous setting after cancellation or rejection,
  and show the supplied managed-policy field and explanation. If the model was
  accepted but the separate Fast change was refused, identify that partial result.
- `model-selection.allowances` — Inspect supplied plan allowances and reset times, Large/Free labels and recommendations in server order. The composer shows the current task's supplied allowance; a model card shows allowances that apply to that exact route.

## How to get to it (user POV)

Tap the short model name in the composer, or open model settings for the selected profile. Choose provider/model and reasoning or fast settings, then apply or cancel the pending choice.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/model_chooser_test.dart test/profile_model_edit_session_test.dart test/chat_model_confirmation_test.dart test/profile_intelligence_test.dart
  ```

- **Android `journeys`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py journeys --output build/feature-verification/model-selection
  ```

## Gotchas

Free models do not inherit paid-model limits. Subscription-billed models also
remain exempt from window allowances, but do not carry a Free label.
The context-ring detail marks a server-confirmed configured maximum as pinned;
estimated token occupancy is a separate fact. Missing plan data is unknown;
Wing neither invents availability nor enables credit spending. A structured
allowance failure can open the picker or select a supplied alternative through
the normal confirmation flow, retaining the draft without resending it.
`profile_model_catalog_test.dart` covers plan decoding and exact-route scope;
`turn_failure_test.dart` covers held, failed and duplicate recovery actions.

Conversation model changes and profile defaults have different scopes. A selected picker row is not a confirmed backend change; handle an explicit confirmation or rejection.

In a conversation, open More model options → Use profile default to remove the
conversation's explicit model selection. Hermes resolves the current profile
default; the action retains history, draft, reasoning and fast settings and does
not edit the profile default. A running turn keeps its current model while the
resolved default is shown as Next turn. Rejection leaves the picker open.

For authorized Android + production acceptance, use the `sessions` suite in the
[existing-gateway journey](multi-surface-journeys.md#selected-hermes-features-on-an-existing-production-gateway).
It verifies real batch answers and a distinct model reset in owned QA chats.

The same existing-gateway recipe’s `context` suite verifies a configured maximum
with actual provider usage and the context detail’s visible pinned label.

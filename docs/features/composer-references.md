# Reference files, skills and commands

Choose a filesystem reference or skill while writing, or invoke a command, with the separate editable draft retained through loading and failure.

Feature ID: `composer-references`.

## Sub-features

- `composer-references.files` — Choose a filesystem reference.
- `composer-references.skills` — Inspect or insert a skill.
- `composer-references.commands` — Select and dispatch a supported command.
- `composer-references.compress` — Preview or apply conversation compression
  with `/compress` or `/compact`, using the captured idle conversation.

## How to get to it (user POV)

Type @ for server references or bot mentions. Type / while writing for skills, or at the start for commands. Use a skill eye icon to inspect instructions without altering the draft.

Send `/compress --preview` to inspect the server's plan. `here N` keeps the newest
N messages and `focus TOPIC` supplies a focus; Wing forwards the arguments exactly.
Send without `--preview` to apply. The command shows progress, then the supplied
preview, no-change result or compression summary. A newer draft stays intact.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.
  The workspace matrix checks that bot and file suggestions can be tapped above
  the composer at 320 dp/200% text with the portrait keyboard open, retaining
  the selected reference, authored draft and cleared IME composition.

  ```sh
  flutter test --no-pub test/composer_references_test.dart test/profile_references_test.dart
  flutter test --no-pub test/slash_commands_test.dart
  ```

- **Android `slash`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.
  Each theme/text-scale case also sends a held compression preview through the
  production composer, checks visible progress and the retained pending command,
  then authors a new draft after acknowledgement. Owner tests separately cover
  a newer draft revision arriving before the command response.

  ```sh
  python3 scripts/test_nightly_native.py slash --output build/feature-verification/composer-references
  ```

## Gotchas

The same slash behaves differently at the start and inside a message. Wait for received suggestions rather than a fixed delay. A command with an uncertain result must not be repeated blindly.

Compression requires an idle, writable conversation. Hermes may refuse a runtime
that requires checkpoint coordination, including some provider-managed sessions.
A preview changes no history. Unsupported options, refusals and uncertain results
keep the command draft; Wing never retries through a different command handler.

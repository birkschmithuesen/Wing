# Inspect and configure skills and tools

Browse skills, read instructions or references, inspect tool readiness, and save supported configuration with confirmed readback.

Feature ID: `administration-skills-tools`.

## Sub-features

- `administration-skills-tools.lock` — Lock or unlock a skill against agent edits
  from its existing detail actions, with captured-profile acknowledgement and readback.
- `administration-skills-tools.library` — Browse and read skill instructions.
- `administration-skills-tools.readiness` — Inspect setup requirements and capability state.
- `administration-skills-tools.configure` — Save supported tool settings with confirmed readback.
- `administration-skills-tools.filter` — Find enabled capabilities or setup gaps,
  and reach hosted app accounts or MCP configuration from the same menu.

## How to get to it (user POV)

Open Skills and tools in profile administration. Browse installed skills or discovery, read instructions, inspect capability readiness, and open supported tool setup. A composer skill eye also opens its reader.

Use Show capabilities to narrow the list to Enabled or Needs setup. These filters
keep enabled and configured separate; neither asserts that a tool successfully
executed. Manage capabilities opens the skill library, discovery, agent plugins,
Connected apps or MCP connectors. Returning refreshes the selected inventory.
The tool row's icon-only setup action opens its owning editor.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/profile_skills_session_test.dart test/administration_tool_setup_test.dart test/skill_reader_session_test.dart
  flutter test --no-pub test/profile_capabilities_screen_test.dart test/studio_selection_test.dart
  ```

- **Android `slash`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py slash --output build/feature-verification/administration-skills-tools
  ```

## Gotchas

Enabled does not mean ready. Bundled instructions are read-only. A successful skill reader does not establish that an external tool can execute.

Skill documents opened from a completed tool call preserve the instructions that
call actually received. Updating installed instructions must not rewrite that
historical document. Hermes can reload changed instructions during a chat; Wing's
library re-reads saved content and no new-chat step is required.

Skill lock state is separate from provenance and enablement. Locking leaves the
user’s existing manual editing rights intact. The lock action shows progress
through readback; an uncertain response requires refreshing before another write.
`hermes023_administration_test.dart` covers these boundaries, refusal after a
changed observation, and both themes at normal and enlarged text.

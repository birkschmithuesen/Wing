# Wing feature map

**Golden product reference.** This is Wing’s independent, maintained map of user-visible behaviour: what exists, how to reach it, how to drive it and what proves it worked. Read this index, then only the feature files relevant to the change. For implementation ownership and design, follow [the agent instructions](../AGENTS.md).

## Baseline preconditions

- Run commands from the Wing app checkout with its configured Flutter, Java17 and Android36 toolchain and resolved dependencies. The [verification workflow](../.agents/skills/verify-wing/SKILL.md) explains launch, doctor, driving, evidence and teardown.
- The default Android recipes use owned disposable API36 emulators, production controls and isolated fixture responses. They do not authorize access to a physical phone or mutations on a deployed Hermes server.
- Stock/live execution needs its exact backend revision, accounts, seed state and explicit mutation authorization. A fixture, a provider login or a read-only health check does not establish successful real inference.
- Preserve each recipe’s theme, text scale, permissions, data and entry-point prerequisites. An unavailable prerequisite is an unexecuted path, not a passing substitute.

## Driving and proof

- Use stable visible labels, tooltips and semantics; wait for observed state changes rather than coordinates or fixed sleeps.
- Show the user action and result, including side effects or reopen/readback where persistence matters. Keep source/backend/device identity with the artifacts.
- Existing drivers define their own strict named verdicts. Require nonempty completed outcomes, no hidden failures/skips and the unchanged source fingerprint; a screenshot or process exit alone is insufficient.
- Keep evidence in ignored `build/feature-verification/` after teardown. Results belong to the task’s report; this map describes product behaviour and repeatable recipes.
- Combine overlapping recipes before a broad pass. Run a shared native family once, then use its named outcomes for each relevant feature at unchanged inputs; listing the same command in several feature files does not require repeated runs.
- For affected features exercise the reachable entry points and relevant success, cancellation, failure, empty, retry and persistence paths. An alternate entry does not prove the original path.

## Maintain a feature

1. Before planning a feature, fix, refactor or test change, read the relevant entries and connected journeys. Use stable feature IDs in plans and handoffs.
2. Maintain this map by default in the same PR as code that adds, changes or removes a feature, including fixes and refactors that alter user behaviour. Update affected user paths, sub-features, preconditions, exact driver commands, observable outcomes and gotchas. Add a feature file and index entry for a new capability; remove retired paths and repair inbound references when removing one. Keep the index and feature files aligned; preserve stable IDs through renames. Internal changes whose entries remain accurate need no cosmetic map edit.
3. Keep feature descriptions at user level. Link the architecture and verification workflow for their own responsibilities. Task plans and reports may reference this map; this independent map contains no task-progress links.
4. Distinguish documentation drift, a missing harness capability and a broken supported behaviour. Confirm drift against source or the running app; record product defects without weakening the expected result.
5. Before completion, reconcile every affected feature entry and connected journey against the delivered source and regressions; check links and recipe commands against the final diff. For behaviour or harness changes, exercise the affected real entry path; documentation-only changes validate wording, targets and commands while reusing valid unchanged runtime evidence. Report affected feature IDs and any unexecuted prerequisites separately from the maintained map. For a broad maintenance pass, source-check every feature, drive every reachable feature, retain evidence after cleanup and finish with the connected journeys. Reuse valid unchanged evidence according to the [verification policy](../.agents/skills/verify-wing/references/verification-policy.md).

## Feature sweep

Use the order below for a broad pass; finish with [connected journeys](features/multi-surface-journeys.md). Each feature file has the same four sections: `Sub-features`, `How to get to it (user POV)`, `Driving it with Wing harnesses`, and `Gotchas`.

<a id="app-shell"></a>

- [Navigate and resume work](features/app-shell.md) — `app-shell`.

<a id="bots"></a>

- [Chat with bots and coordinate discussions](features/bots.md) — `bots`.

<a id="connections"></a>

- [Connect to Hermes](features/connections.md) — `connections`.

<a id="cloud-access"></a>

- [Connect through a cloud account](features/cloud-access.md) — `cloud-access`.

<a id="profiles"></a>

- [Manage profiles](features/profiles.md) — `profiles`.

<a id="server-files"></a>

- [Browse and manage server files](features/server-files.md) — `server-files`.

<a id="chat-browser"></a>

- [Find and organize chats and projects](features/chat-browser.md) — `chat-browser`.

<a id="conversation"></a>

- [Read and search conversation history](features/conversation.md) — `conversation`.

<a id="chat-activity"></a>

- [Inspect and supervise agent work](features/chat-activity.md) — `chat-activity`.

<a id="chat-inputs"></a>

- [Send, steer and revise work](features/chat-inputs.md) — `chat-inputs`.

<a id="composer-references"></a>

- [Reference files, skills and commands](features/composer-references.md) — `composer-references`.

<a id="notifications"></a>

- [Respond and return from notifications](features/notifications.md) — `notifications`.

<a id="attachments-and-sharing"></a>

- [Bring files into a conversation](features/attachments-and-sharing.md) — `attachments-and-sharing`.

<a id="outputs-and-viewers"></a>

- [Open, save and share results](features/outputs-and-viewers.md) — `outputs-and-viewers`.

<a id="markdown"></a>

- [Read and copy formatted content](features/markdown.md) — `markdown`.

<a id="model-selection"></a>

- [Choose a model and reasoning settings](features/model-selection.md) — `model-selection`.

<a id="voice"></a>

- [Dictate, hear replies and have live conversations](features/voice.md) — `voice`.

<a id="administration"></a>

- [Navigate and recover administration](features/administration.md) — `administration`.

<a id="administration-health"></a>

- [Diagnose Hermes health](features/administration-health.md) — `administration-health`.

<a id="host-resources"></a>

- [Inspect server resource usage](features/host-resources.md) — `host-resources`.

<a id="health-alerts"></a>

- [Investigate and manage health alerts](features/health-alerts.md) — `health-alerts`.

<a id="administration-providers"></a>

- [Configure provider access](features/administration-providers.md) — `administration-providers`.

<a id="administration-connectors"></a>

- [Connect apps and configure MCP connectors](features/administration-connectors.md) — `administration-connectors`.

<a id="administration-behavior"></a>

- [Edit bot identity and behaviour](features/administration-behavior.md) — `administration-behavior`.

<a id="administration-memory"></a>

- [Inspect retained memory](features/administration-memory.md) — `administration-memory`.

<a id="administration-skills-tools"></a>

- [Inspect and configure skills and tools](features/administration-skills-tools.md) — `administration-skills-tools`; includes locks against agent edits.

<a id="scheduled-tasks"></a>

- [Schedule and inspect recurring work](features/scheduled-tasks.md) — `scheduled-tasks`.

<a id="usage-analytics"></a>

- [Understand usage and cost](features/usage-analytics.md) — `usage-analytics`.

<a id="versions-updates"></a>

- [Inspect versions and control updates](features/versions-updates.md) — `versions-updates`; Cloud-managed identity and self-hosted update controls.

<a id="app-preferences-backup"></a>

- [Personalize and back up Wing](features/app-preferences-backup.md) — `app-preferences-backup`.

<a id="privacy"></a>

- [Read the privacy policy](features/privacy.md) — `privacy`.

<a id="platform-lifecycle"></a>

- [Keep ownership across Android transitions](features/platform-lifecycle.md) — `platform-lifecycle`.

<a id="ui-foundations"></a>

- [Use accessible and responsive controls](features/ui-foundations.md) — `ui-foundations`.

<a id="performance-tooling"></a>

- [Keep work responsive and measurable](features/performance-tooling.md) — `performance-tooling`.

## Connected journeys

[Cross-feature user journeys](features/multi-surface-journeys.md) cover connection-to-reopen, conversation work, process restoration, notifications, voice and stock administration.

## Method

Adapted to Wing’s existing Android harnesses and in-repository feature documentation from [Poteto’s original feature-map example](https://github.com/poteto/verification-skill-example) and the official [pstack verification guidance](https://github.com/cursor/plugins/tree/main/pstack/skills/create-verification-skill).

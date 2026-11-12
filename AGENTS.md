# Wing workspace

Before planning or editing Wing, read [the internal working instructions](internal/AGENTS.md)
and the [Wing feature map](docs/FEATURE_MAP.md), the golden product reference.
Read the affected feature files and connected journeys before changing code.

Feature-map maintenance is part of every feature implementation, behaviour fix,
refactor or removal by default. Follow the map’s
[maintenance contract](docs/FEATURE_MAP.md#maintain-a-feature) in the same PR;
before marking work complete, reconcile every affected entry with the delivered
source and verification, and report the checked feature IDs. If the map remains
accurate, state why no update was needed.

- Before implementing app, native or tooling changes, use
  [maintain-feature-architecture](internal/tools/agent_skills/maintain-feature-architecture/SKILL.md)
  for ownership, interfaces, coupling and the final design review.
- For feature verification or map upkeep, use
  [verify-wing](.agents/skills/verify-wing/SKILL.md) for harness launch, user-path
  driving, evidence, cleanup and recipe maintenance.

For every feature or fix that changes a visible control, navigation, action
admission or asynchronous UI behavior, follow the [UI workflow](internal/AGENTS.md#ui-design)
before planning or editing, even when the implementation is mostly controller code.

The private `wing-internal` repository must be cloned into `internal/` for
engineering work. If it is missing, obtain its clone URL and access from the
project owner before proceeding. The feature map and verification skill are
self-contained in app Git; public CI runs from the app source alone.

For commit/push requests, stage only the completed task's app changes and run
`python3 scripts/wing_save.py "<message>"`. Use `--commit-only` for local commits
and `--push-only` to retry publication. The full save and recovery workflow is in
[internal contributor instructions](internal/CONTRIBUTING.md#workspace-saves).

Keep plans, specs, architecture, research, design decisions, audit evidence and
other development procedures under `internal/`. The canonical `docs/FEATURE_MAP.md`,
`docs/features/` and `.agents/skills/verify-wing/` belong in app Git alongside code
so feature changes and their recipes are reviewed in the same PR. Public Git also
contains executable checks/build configuration, user guides, release notes and legal assets.

Wing targets the latest upstream, unmodified Hermes. Integrations belong entirely
in the Android client; backend patches, forks, plugins and custom endpoints are
out of scope. Compatibility behavior requires the user's explicit approval.

# Fork changelog

This repo is the fork `birkschmithuesen/Wing`, tracked separately from
upstream `tarkilhk/Wing` in [`CHANGELOG.fork.md`](CHANGELOG.fork.md) and the
"Wing Voice (fork)" block at the top of [`README.md`](README.md).

Every feat/fix change on `voice-offline` must, in the same commit, add an
entry to `CHANGELOG.fork.md` (What, Why, merge commit hash, card number) and,
if it is a new user-visible feature, a line in the README feature list
linking to its docs file. This is checked at review/merge time; a card
without both is not done.

# Fork notes

- Wing Voice targets stock Hermes. Upstream's live voice call needs the Wing Hermes plugin; fork work does
  not depend on or extend it.
- `docs/DESIGN_SYSTEM.md` and the administration handoff were removed upstream (moved to a private
  workspace). Public UI references: `docs/features/ui-foundations.md`, `docs/FEATURE_MAP.md`.
- Upstream's `scripts/wing_save.py` and private `internal/` workflow do not apply to the fork factory.

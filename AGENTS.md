# Hermes deployment constraint

Wing targets **the latest upstream, unmodified Hermes**, including changes on
upstream main. Before designing or implementing an integration, verify the current
stock API and record the inspected commit; a local checkout or an older deployed
server does not define the target. Implement features entirely in the Android
client. Backward compatibility requires the user's explicit approval.

Backend patches, forks, plugins and custom endpoints are out of scope. Backend
checkouts are read-only references. Updating a deployed server is a separate
deployment action; targeting current upstream does not authorize an upgrade.

Verify the stock API before designing a feature. If it cannot support the requested
behavior, state that limitation and discuss a client-only design. Never silently
change shared profile settings to simulate an unsaved voice preview.

# UI design

For UI work, read [the Studio design charter](docs/DESIGN_SYSTEM.md) before changing screens, components, themes, or interaction layouts. It owns the selected appearance, component rules, and behavior-preservation contract. Use its shared tokens for new and existing controls, including light and dark states.

For administration UI, also read [the ownership handoff](docs/design/2026-09-14-administration-handoff.md). It defines profile-owned provider credentials and defaults, server operations, and runtime versus profile health. Planned capabilities and generated mockups are not evidence that a backend operation is implemented.

## Design before implementation

For new screens and layout changes, apply the frontend-design skill's planning
and critique process within Studio's established visual language.

1. State the user's task and primary action. Separate editable controls, passive
   context and temporary status before choosing components.
2. Sketch at least two plausible arrangements; compare visual weight, repeated
   information, taps and reachability. Present the recommended design when the
   user asks for a proposal; a proposal request authorizes design work only.
3. Challenge every heading, card, label and sentence: retain it only if it helps
   the user decide, act or recover. Keep provider/context metadata subordinate
   to controls. Show sample speech through playback; keep its script out of the
   ordinary UI. Give transient saving feedback without permanent success clutter.
4. Before declaring UI complete, inspect actual rendered screens at normal phone
   size, then enlarged text in both themes. Check hierarchy and density as well
   as selection, loading, errors and action reachability. Revise what looks or
   feels wrong; passing widget tests alone does not establish design quality.

# Fork changelog

This repo is the fork `birkschmithuesen/Wing`, tracked separately from
upstream `tarkilhk/Wing` in [`CHANGELOG.fork.md`](CHANGELOG.fork.md) and the
"Wing Voice (fork)" block at the top of [`README.md`](README.md).

Every feat/fix change on `voice-offline` must, in the same commit, add an
entry to `CHANGELOG.fork.md` (What, Why, merge commit hash, card number) and,
if it is a new user-visible feature, a line in the README feature list
linking to its docs file. This is checked at review/merge time; a card
without both is not done.

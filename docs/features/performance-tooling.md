# Keep work responsive and measurable

Read and stream long content with preparation bounded by observed demand; enable diagnostic instrumentation explicitly and keep it out of release builds.

Feature ID: `performance-tooling`.

## Sub-features

- `performance-tooling.bound` — Prepare only work required by observed demand.
  Workspace startup warms the existing Recents catalog once after initialization,
  sharing pending reads and freshness with later navigation. Hidden warm-up does
  not start polling, avatar demand or rendered conversation previews; see the
  [Recents startup regression](chat-browser.md#driving-it-with-wing-harnesses).
  Background notification, group and detached-work observations publish their
  current state without saving unchanged reading history. An already verified,
  still-working runtime refreshes metadata only in its known profile; input,
  completion and uncertain ownership still require full verification.
- `performance-tooling.measure` — Enable diagnostics explicitly for a selected question.
- `performance-tooling.release` — Refuse instrumentation in release execution.

## How to get to it (user POV)

Open a long conversation, scroll and stream while continuing to type. For a measurement task use the repository performance procedure and its explicitly enabled diagnostic entry point.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/performance_instrumentation_test.dart test/transcript_preparation_work_budget_test.dart test/markdown_render_reuse_test.dart test/workspace_streaming_replay_test.dart
  flutter test --no-pub test/scroll_capture_viewport_test.dart test/slash_commands_test.dart test/growing_markdown_text_test.dart
  flutter test --no-pub test/notification_outage_recovery_test.dart
  ```

  Replay readiness checks exact logical prose/code segments in document order,
  excluding their nested table-cell renderers. Missing or stale segments must
  prevent measurement even when the composer is ready.
  Capture checks require streamed content and scrolling to preserve the native
  screenshot registration while capture receives fresh bounds and offsets.
  Resizing and returning from another capture owner still update registration.
  Command checks preserve inline skill, argument and literal-path behavior while
  ordinary drafts avoid command-pattern scanning. Growing Markdown checks count
  native text-control initialization alongside selection and current-link behavior.
  Device replays should count backend requests and native calls separately from
  build/raster timing, so host contention cannot hide redundant work.
  The background-work regression keeps a retained conversation while repeating
  unchanged work observations across seven profiles. It requires zero reading
  snapshot writes, one exact-owner metadata read per observation, continued
  detached-work discovery, and successful persistence of a later history change.
  Metadata failure and ambiguous completion must retain monitoring without a
  guessed reply alert.

- **Device/external entry:** follow the user path on an authorized instance and capture its trigger/result. The host command does not establish that boundary. Report the attempted route and any missing driver or prerequisite.

## Gotchas

Work-budget and instrumentation tests do not certify phone frame time, latency, energy or speech quality. Diagnostic builds and release builds have different admitted instrumentation.

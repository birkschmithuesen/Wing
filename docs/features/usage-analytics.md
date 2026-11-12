# Understand usage and cost

Choose an instance, profile set and time window, inspect token/model/cost totals, and recover one failed section while other received sections stay usable.

Feature ID: `usage-analytics`.

## Sub-features

- `usage-analytics.scope` — Select instance profile set and time window.
- `usage-analytics.inspect` — Read usage and estimated cost breakdown.
- `usage-analytics.recover` — Refresh independent sections without losing valid data.

## How to get to it (user POV)

Choose Hermes analytics in the drawer. Change instance or the separate All/profile picker, choose a period, inspect Tokens/Cost and model breakdown, then refresh.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/usage_analytics_session_test.dart test/analytics_content_test.dart test/models_dev_pricing_test.dart
  ```

- **Android `journeys`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py journeys --output build/feature-verification/usage-analytics
  ```

## Gotchas

The analytics profile picker does not switch the chat workspace. API-equivalent cost is an estimate, not an invoice. Missing or incomplete sections must remain qualified.

Current plan allowance is separate from historical token/cost analytics. It is
shown in the conversation composer and model chooser through
[model selection](model-selection.md); those observations do not alter usage
history or imply an invoice amount.

A failed chart or activity-calendar read shows recovery at that section. Other
sections and retained chart data stay usable; retained data keeps its freshness
qualification. `test/administration_usage_test.dart` checks initial failures,
retained-data errors and recovery in both themes and text sizes.

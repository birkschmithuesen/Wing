# Personalize and back up Wing

Change appearance or device preferences, export connections and settings, then restore them with the intended passphrase and credential retention.

Feature ID: `app-preferences-backup`.

## Sub-features

- `app-preferences-backup.wing-plugin` — See the latest GitHub release and each backend profile’s installed Wing plugin version. Install, update and enable Wing across all profiles through Hermes.
- `app-preferences-backup.personalize` — Save and preview device preferences.
- `app-preferences-backup.export` — Write the chosen backup through Android.
- `app-preferences-backup.restore` — Read back settings and credentials with explicit outcomes.

## How to get to it (user POV)

Open App settings from the drawer. Change theme, accent or text size. Use its export/restore controls to back up connections/preferences with an optional passphrase, then review a restore result.

The Wing plugin section shows the connected server and each profile’s version and
configured enablement. Refresh checks GitHub and backend inventory. The icon-only
Install or update Wing in all profiles action installs missing copies from
[tarkilhk/wing-hermes-plugin](https://github.com/tarkilhk/wing-hermes-plugin), updates
older copies through their existing source, and enables Wing where disabled.
Each profile keeps its own outcome; one failure does not hide other successes.
Without a connection, the section explains that Hermes is required.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/wing_plugin_settings_test.dart test/profile_plugins_session_test.dart
  flutter test --no-pub test/app_preferences_test.dart test/app_preferences_pending_authority_test.dart test/backup_restore_outcomes_test.dart test/config_backup_exact_credentials_test.dart
  ```

- **Android `journeys`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py journeys --output build/feature-verification/app-preferences-backup
  ```

- **Android `backup`:** the owned-emulator driver exercises its named production-control scenarios. Require the strict receipt and [shared proof rules](../FEATURE_MAP.md#driving-and-proof); read the completed names to establish which paths ran.

  ```sh
  python3 scripts/test_nightly_native.py backup --output build/feature-verification/app-preferences-backup
  ```

## Gotchas

Backup contains sensitive connection material. Use only owned fixture data and retain exact credential semantics. Wrong passphrases and storage/provider failures must preserve the existing configuration.

Plugin installation uses the stock Hermes management API. Git installs follow
their configured branch; catalog installs follow the reviewed catalog, which can
lag behind GitHub releases. Held pins, scan refusals and capability-review requests
are not overridden. An unavailable version is not treated as a missing plugin.
A lost update reply or unavailable readback requires Refresh before retrying.
Leaving the section stops undispatched changes; a command already sent can finish
on Hermes. Refresh after returning to check it. New tools apply to new chats;
any required backend restart is shown in the profile result. Opening settings
never installs plugins or enables automatic updates.

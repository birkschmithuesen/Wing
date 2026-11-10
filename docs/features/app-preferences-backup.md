# Personalize and back up Wing

Change appearance or device preferences, export connections and settings, then restore them with the intended passphrase and credential retention.

Feature ID: `app-preferences-backup`.

## Sub-features

- `app-preferences-backup.wing-plugin` — See the latest GitHub release and each backend profile’s installed Wing plugin version. Install, update and enable Wing in one profile or across all profiles through Hermes.
- `app-preferences-backup.personalize` — Save and preview device preferences.
- `app-preferences-backup.export` — Write the chosen backup through Android.
- `app-preferences-backup.restore` — Read back settings and credentials with explicit outcomes.

## How to get to it (user POV)

Open App settings from the drawer. Change theme, accent or text size. Under Voice, select a GPT-Live voice for each live conversation mode; these phone-owned choices are included in settings backups. Tap the adjacent speaker to preview subscription voices offline; API previews are unavailable. Use its export/restore controls to back up connections/preferences with an optional passphrase, then review a restore result.

Under **Open links in**, choose **Open in Wing** or **Open in external browser** for
regular web-link taps. Open in Wing is the initial choice. The saved choice
applies across connections and is included in settings backups. Use the
[link context menu](markdown.md#link-context-menu) to choose a destination
for one link.

Under Hermes, tap the compact Wing plugin card to open its dedicated page. It
explains the optional server plugin and links to its GitHub repository. Below
that, it shows the connected server, installed versions, latest GitHub release
and overall status. Open Profiles for individual versions, enablement and operation results.
Each profile row has its own install/update icon. It installs missing Wing copies,
updates older ones or enables a disabled copy in that selected profile. Current
profiles have a disabled action. Unknown or failed rows need Refresh; another
profile’s failure does not block a verified row.
Refresh checks GitHub and backend inventory. If the GitHub check fails, its
message distinguishes connection failure, timeout, request limits, HTTP refusal
and invalid release information. Installed versions remain visible; updates wait
for a successful check. The icon-only
Install or update Wing in all profiles action installs missing copies from
[tarkilhk/wing-hermes-plugin](https://github.com/tarkilhk/wing-hermes-plugin), updates
older copies, and enables Wing where disabled. Missing copies install at the
published release commit. For pinned copies, review the inline replacement explanation and
confirm to move them to that exact commit. The review and footer identify the
selected profile or the all-profile scope. Cancel sends no changes.
Each profile keeps its own outcome; one failure does not hide other successes.
Without a connection, the section explains that Hermes is required.

Voice settings include the saved live conversation choice: ChatGPT subscription
or OpenAI API. The portable preferences include this choice; a changed value
applies to the next call and never changes an active call's billing mode.

## Driving it with Wing harnesses

Preconditions: use the [shared baseline](../FEATURE_MAP.md#baseline-preconditions). Use the [verification workflow](../../.agents/skills/verify-wing/SKILL.md) for launch, readiness, evidence and cleanup.

- **Host boundary:** run the focused suites below; their supplied transport/platform responses limit the proof.

  ```sh
  flutter test --no-pub test/wing_plugin_settings_test.dart test/profile_plugins_session_test.dart
  flutter test --no-pub test/app_preferences_schema_test.dart test/app_preferences_test.dart test/app_preferences_pending_authority_test.dart test/backup_restore_outcomes_test.dart test/config_backup_exact_credentials_test.dart
  flutter test --no-pub test/app_preferences_settings_test.dart test/app_preferences_composition_test.dart test/app_settings_design_test.dart test/config_backup_service_test.dart test/web_preview_test.dart
  ```

  The link setting checks cover the popup below the row's trailing edge for
  either selected destination, held saves, recovery, app-wide dispatch, reopened
  preferences and backup round trips.

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

Plugin installation uses the stock Hermes management API. Unpinned updates follow
their configured branch or catalog, which can lag behind GitHub releases. Moving
a pin requires Hermes’s forced reinstall: its confirmation explains that caution
scan warnings will be accepted, while dangerous code remains blocked. Approval
applies only to the displayed release and selected scope. Other scan/capability refusals remain
visible, with Hermes’s reason. An unavailable version is not treated as missing.
A lost update reply or unavailable readback requires Refresh before retrying.
Returning from the plugin page to App settings keeps the current operation and
its visible progress. Leaving App settings or replacing the backend stops
undispatched changes; a command already sent can finish on Hermes. Refresh after
returning to check it. New tools apply to new chats;
any required backend restart is shown in the profile result. Opening settings
never installs plugins or enables automatic updates.

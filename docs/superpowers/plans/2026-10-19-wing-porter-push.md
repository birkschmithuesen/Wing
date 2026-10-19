# Wing Porter Push (UnifiedPush client, Pforte notice actions, Nachtruhe) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wing becomes a UnifiedPush client for the porter wake gate. It fetches each content-free-pushed notice over its authenticated dashboard connection and shows it on the existing attention channel with „Öffnen“, „Später“ and the trial ratings. It also gets a „Nachtruhe“ block that reads and writes quiet hours on the server.

**Architecture:** All porter code lives in one optional Dart module, `lib/porter_wake/`, and one Kotlin package, `com.tarkilhk.wing.porterwake`. It plugs into existing seams through a few small hooks in core files, listed in "Core seams". The module stays inert for a connection until `GET /api/plugins/porter_wake/settings/quiet-hours` answers 200. If the probe answers 404 or 503, the module registers nothing, shows nothing and calls no other porter route on that connection.
- **Push transport:** the native UnifiedPush Android connector, used directly from Kotlin (not the Flutter plugin).
- **Background handling:** if no Wing engine is alive, a push starts a short-lived headless Flutter engine. Its Dart entry point fetches the notice and posts it.
- **Notification taps:** they follow the approval precedent, an invisible activity that stays resumed until Dart has replied.

**Tech Stack:**
- Flutter 3.44.0 / Dart `^3.12.0`, `package:http` (with `MockClient` in tests), `shared_preferences`, `flutter_secure_storage` 11.2.0.
- Kotlin 2.4.20, AGP 9.4.1, `org.unifiedpush.android:connector` 3.x. The connector is new; see "Connector choice".

**Spec (binding):** `docs/superpowers/specs/2026-10-19-wing-push-contract.md`. It is a verbatim copy of PB `wt/t_2b45a583` @ `4ad631ba`, with the file last changed in `9c73d2cf`. In this plan, "contract §x" means that file. Birk's decisions of 2026-10-19 are binding:
- Push goes through self-hosted ntfy; the ntfy app is the distributor. No FCM, no Telegram, and no content in the push.
- Nachtruhe defaults to 22:00–08:00, on. The server is the single source of truth.
- The notification standard of contract §6.
- The three-screenshot go-live gate.

**Cards:**
- Plan card: t_7737d2c2.
- Build card: t_92a40e12, executed with superpowers:subagent-driven-development. The build card **stops before go-live**: it delivers the three screenshots and hands the §8.4 checklist to Birk.

**Scope exception (approved by Birk 2026-10-19):** `AGENTS.md` ("Hermes deployment constraint") rules out custom endpoints and plugins. Birk approved an exception for this module only. It is recorded in `CHANGELOG.fork.md` (Task 12). `AGENTS.md` itself is **not** edited.

## Global Constraints

- **Module boundary:** porter code lives only in `lib/porter_wake/`, `test/porter_wake/`, `android/app/src/main/kotlin/com/tarkilhk/wing/porterwake/`, `android/app/src/main/res/layout/notification_porter_*.xml`, `integration_test/porter_wake_device.dart` and `.github/workflows/porter-qa-apk.yml`. Core files get only the hooks listed in "Core seams". No core file imports a porter type, except the wiring in `lib/main.dart` (Task 10), following the precedent of core importing `lib/voice_offline/` and `lib/car_mode/`.
- **Inert on stock Hermes:** a quiet-hours probe answering 404 or 503 means no UnifiedPush registration, no „Nachtruhe“ UI and no further porter route on that connection for the session (contract §2.2 and §3.1).
- **Text:** the push carries no content, and Wing never builds titles or lines. Labels are shown exactly as the server sends them (contract §1 and §10).
- **German strings:** the only Wing-local German strings are „Nachtruhe“, „von“, „bis“, „Pforte: neue Nachricht“, „in 2 Stunden“ and „morgen“. All other Wing-local UI text is English, like the rest of Wing.
- **Language and commits:** English for code, identifiers, comments, commits and repo docs. `docs/refactoring-guidelines.md` does **not exist** in this repo (verified 2026-10-19), so follow the existing code style instead.
- **No session data, credentials, tokens or third-party data in the repo.** Test fixtures use the contract's synthetic examples and `hermes.test` hosts.
- **Server-side truth:** Wing does no quiet-hours suppression and keeps no local copy of the quiet hours (no `saveDevicePreference` for them). Cap and trial/live mode are never shown or edited.
- **Notification channel:** the existing attention channel `wing_attention_notifications`. Exactly one porter notification slot, id `214700`.
- **Logging:** `debugPrint` lines start with `porter_wake:` and never contain a payload, a notice text, an endpoint URL or a device id.
- **Test command:** `bash tools/factory/ci-suite.sh <test path>`. This is the FACTORY.yaml `test:` command. Flutter is not installed on this host, so the suite runs on GitHub Actions.
  - The script dispatches `pr-quality.yml`, which also runs `flutter analyze --no-pub --fatal-infos` (`pr-quality.yml:55`). That is the CONTRIBUTING.md gate (`CONTRIBUTING.md:13`).
  - Success ends with `ci-suite: run <id> conclusion=success …`.
  - Failure prints `failed step: Static analysis` or `failed step: Run tests` and `conclusion=failure`.
  - The path argument only works after Task 0.
- **Kotlin compile check:** `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`. Expected: `dispatch-check: voice-apk.yml run <id> conclusion=success`.
- **Commits:** commit after every task on `voice-offline`, with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. No merge, no push other than the CI throwaway refs the factory scripts create.
- **UI work:** read `docs/DESIGN_SYSTEM.md` first.
  - Use `CompactSwitchListTile` (`lib/core/widgets/compact_switch.dart:38`).
  - Use 48 dp targets, and disable writes while a save is pending (`DESIGN_SYSTEM.md:227`).
  - Inspect renders at 320 dp, at 100% and 200% text, in both themes, before calling UI done (`AGENTS.md` "Design before implementation", step 4).

## Verified references (current tree, 2026-10-19)

The contract's `WING/…:line` references were checked against `voice-offline` @ `b2415044`.

| Contract reference | Status | Current location / correction |
|---|---|---|
| `AGENTS.md:3-11` Hermes constraint | ✅ | `AGENTS.md:1-15` ("# Hermes deployment constraint") |
| `connection_manager.dart:1359-1395` login | ✅ | `Future<String> _login()` at `:1359`; the cookie regex at `:1383` |
| `_authHeaders` `:1424-1449` | ✅ | Public wrapper `authHeaders()` at `:1457` |
| `apiGet :1500`, `apiPost :1592`, `apiDelete/apiDeleteResult :1624-1632`, `apiPut :1674` | ✅ lines | **Premise partly wrong:** `apiPut`/`apiDeleteResult` throw plain `Exception('HTTP n')` (`:1690`, `:1648`). No helper exposes the error body. Contract §7 needs the server's `error` text, so Task 3 adds one generic helper, `apiSend`. Every helper already re-logs in once on 401 (`_resetAuth`, `:1331-1348`), so contract §2.2 and §7's "re-login, retry once" comes for free. |
| `DashboardClient` per connection | ⚠️ | **No per-connection getter exists.** Each service builds its own client from a `SavedConnection`; `_dashboardFor` (`profile_gateway.dart:75`) is copied in five places. Task 3 adds `porterDashboardFor`, following that precedent. |
| `pubspec.yaml:23` flutter_secure_storage | ✅ | `flutter_secure_storage: 11.2.0` (pinned) |
| `pubspec.yaml:41` flutter_local_notifications | ✅ | `^22.3.1` |
| `turn_notification_service.dart:333-338` attentionChannel | ✅ | Same lines |
| `ChatNotifications.kt:30` / `:141` | ✅ | Same lines |
| `ChatNotifications.kt:173-211`, buttons `:208-211` | ✅ (±1) | Approval RemoteViews at `:196-213`; button loop at `:208-212`; layouts `notification_approval_row.xml` and `notification_approval_grid.xml` (grid used when fontScale > 1.3) |
| Approval taps when the app is killed | ⚠️ | No BroadcastReceiver and no headless engine: `NotificationActionActivity` (`ChatNotifications.kt:232-278`) opens `MainActivity` when no live engine exists (`hasLiveEngine()`, `:135`). There is no `@pragma('vm:entry-point')` anywhere in `lib/`. Porter rate/snooze taps must not open the app, so Task 8 adds a headless engine (see "Background delivery"). |
| `main.dart:174-216` `openProfileNotification` | ✅ | Same lines |
| `profile_workspace_controller.dart:1086` `openNotification`, `:2667` `openSession`, `:49-76` `ProfileSessionKey` | ✅ | Same lines |
| "pinned or most recent pforte chat" (§6.6) | ❌ | **Wing has no pinned-chat concept** (grep `pin` finds nothing relevant). The plan uses the most recent `pforte` session: `switchProfile('pforte')` (`:1420`), then the row of `controller.current!.sessions` (`ProfileWorkspaceData.sessions`, `:273`) with the highest `last_active` (Task 10). |
| `app_settings_content.dart:227-228` Notifications, `:232-257` toggles | ✅ | Toggles at `:232`, `:243`, `:257-268`. `AppSettingsContent` (`:23-31`) is **global** (only `SharedPreferences` + callbacks, no connection). It is built in `main.dart:1471` and `profile_workspace_screen.dart:3090`. |
| `lib/features/porter_wake/` | ❌ | `lib/features/` does not exist. Feature modules sit at `lib/<name>/` (`lib/voice_offline/`, `lib/car_mode/`), with tests in `test/<name>/`. The plan uses `lib/porter_wake/` and `test/porter_wake/porter_wake_*_test.dart`. |
| `PRIVACY.md:25` | ✅ | The quoted sentence ends line 25 |
| `docs/PLAY_DATA_SAFETY.md:23` | ✅ | Same line |
| `docs/superpowers/plans/2026-10-13-wing-voice-vad-input.md:4090-4112` build chain | ✅ | Same lines (precondition: screen lock never bypassed) |
| Contract §8.2 `flutter test test/porter_wake_*_test.dart` | ⚠️ | No flutter here. The equivalent is `bash tools/factory/ci-suite.sh test/porter_wake/` (Task 0). **`ci-suite.sh` ignores its argument today**, and `pr-quality.yml:63` runs only `test/car_mode/car_mode_screen_test.dart`, a leftover of diagnostic card t_db672361. |
| Logout path (§5.1.6 "user logs out") | ❌ | Wing has no logout or sign-out anywhere in `lib/`. Revocation covers connection removal, distributor unregistration and dashboard credential edits instead (Task 7). |
| Device id (§3.2) | ✅ new | No device or install id exists. The nearest precedent is `ProfileConnectionIdentity` (a per-install key in secure storage). Task 4 adds its own namespace. |

## Connector choice

**Decision:** use `org.unifiedpush.android:connector` (3.x, Apache-2.0, Maven Central) directly from Kotlin, behind a Dart `PorterWakeBridge` interface, rather than the pub.dev `unifiedpush` Flutter package.

Reasons:
1. **Killed-app delivery must be ours anyway.** Wing has no background Dart precedent. Push handling (fetch with credentials from secure storage, then post) and notification-button handling (feedback POST) both need the same headless entry point. Owning the native side lets one `PorterHeadless` serve both.
2. **Isolation.** One Kotlin package and one Gradle line, no new pub dependency. The Dart side stays fully testable with a fake bridge. Removing the module means deleting that package and the Gradle line.
3. **API stability.** The Flutter plugin's callback API changed between major versions. The Android connector is the layer the plugin wraps anyway.

Connector API this plan codes against (from connector 3.x documentation; see ANNAHME C1):
- `class PorterPushService : PushService()` overrides:
  - `onNewEndpoint(endpoint: PushEndpoint, instance: String)`
  - `onMessage(message: PushMessage, instance: String)`, where `message.content: ByteArray` and `message.decrypted: Boolean`
  - `onRegistrationFailed(reason: FailedReason, instance: String)`
  - `onUnregistered(instance: String)`
- Manifest: the service is declared `exported="false"` with intent filter `org.unifiedpush.android.connector.PUSH_EVENT`.
- Registration: `UnifiedPush.tryUseCurrentOrDefaultDistributor(context) { success -> … }`, then `UnifiedPush.register(context, instance)`. Unregistration: `UnifiedPush.unregister(context, instance)`.
- **`instance` = Wing `SavedConnection.id`.** Each porter-enabled connection gets its own endpoint, so a push identifies its connection.

> **ANNAHME C1:** the exact connector version, the class and package names above and Maven Central availability could not be verified, because this host has no web access. **Check before Task 8, step 1:**
> - the latest release tag on <https://codeberg.org/UnifiedPush/android-connector> and its KDoc at <https://unifiedpush.org/kdoc/connector/>;
> - the method signatures;
> - whether `tryUseCurrentOrDefaultDistributor` needs an `Activity` context;
> - the minimum SDK, which must be ≤ 24.
>
> If names differ, adapt only `PorterPushService.kt` and `PorterWakeNative.register/unregister`. The Dart bridge contract (Task 6) stays unchanged.
>
> **ANNAHME C2:** connector 3.x generates WebPush keys and tries to decrypt. The gate sends plain JSON (contract §5.2), so the plan assumes the connector still calls `onMessage` with the raw bytes and `decrypted == false`, rather than dropping the message. **Check** in the connector source (`PushService`/`MessageReceiver`) before Task 8. If it drops undecryptable messages, stop and ask Birk; the fix belongs in the gate (WebPush encryption), not in Wing.
>
> **ANNAHME C3:** the ntfy app accepts an `http://` (tailnet) server and hands out `http://100.75.24.33:2586/up…?up=1`. This is assumed by contract §5.1. Verify it during the §8.4 handoff.

## Background delivery (when the app is not running)

Push path:
1. ntfy delivers the push.
2. The connector calls `PorterPushService.onMessage`, which calls `PorterWakeNative.deliverPush(context, instance, bytes)` on the main thread.
3. If the retained app engine (`MonitoringRuntime.engine`) has a ready porter channel, the push is invoked there.
4. Otherwise `PorterHeadless` takes a 30 s partial wake lock (`WAKE_LOCK` is already declared). It creates a `FlutterEngine` and runs the Dart entry point `porterWakeBackgroundMain` in `package:wing/porter_wake/porter_wake_background.dart`.
5. Dart calls `initialize(role: background)`, which returns the queued pushes. Dart handles them (fetch, then show) and calls `finished`, which destroys the engine and releases the lock. A 30 s timeout also destroys it.

Endpoint, unregistration and failure events are persisted natively in the `porter_wake_native` SharedPreferences under `pending`. They are delivered only to the **main** engine (`role: main`), which owns the registration with the server.

Button tap path:
1. A button opens `PorterActionActivity`, which is invisible, uses `@style/NotificationActionTheme` and handles the keyguard like `NotificationActionActivity`.
2. For `rate` and `snooze`, it hands the interaction to the main engine if one is live, otherwise to a fresh `PorterHeadless`. It stays resumed until Dart replies, then finishes, without opening Wing. Staying resumed gives the process foreground network access, the precedent comment at `ChatNotifications.kt:266-268`.
3. For `open` (content tap), it starts `MainActivity` with extra `porter_wake_interaction`. `MainActivity.onResume`/`onNewIntent` forward that extra through `PorterWakeNative.handleMainIntent`.

> **ANNAHME B1:** with the screen off (Doze), Wing gets network access during the push. The assumption is that the ntfy distributor grants the receiving app a temporary allowlist when it broadcasts. **Check** in §8.4 step 2b: `hadb shell dumpsys deviceidle force-idle`, then a forced push. If the fetch fails there, Wing shows „Pforte: neue Nachricht“ (contract §6.7). That is the specified degraded behaviour, not a crash, but tell Birk.
>
> **ANNAHME B2:** `FlutterEngine(context)` auto-registers the plugins from `GeneratedPluginRegistrant`, including `shared_preferences` and `flutter_secure_storage`, so the headless entry point can read connections with secrets. **Check:** the Task 13 QA run kills Wing (`am force-stop`) before the injected push and expects a rendered notice.

## Core seams (every change outside the module)

| File | Change | Task |
|---|---|---|
| `.github/workflows/pr-quality.yml` | `workflow_dispatch` input `tests` (default `test/`); the test step runs `${{ inputs.tests \|\| 'test/' }}` | 0 |
| `tools/factory/ci-suite.sh` | Forwards an optional first argument as `-f tests=<path>` | 0 |
| `lib/core/services/connection_manager.dart` | New generic `DashboardClient.apiSend(method, endpoint, {body})` that returns the raw `http.Response` after the usual single 401 re-login. Existing helpers are unchanged. | 3 |
| `lib/core/screens/app_settings_content.dart` | New optional `List<Widget> notificationExtras` rendered inside the Notifications card | 9 |
| `lib/core/screens/profile_workspace_screen.dart` | New optional `List<Widget> Function()? settingsExtras` passed to `AppSettingsContent` | 10 |
| `lib/main.dart` | Creates `PorterWakeModule`, syncs it on startup and after connection changes, forgets connections before deletion, supplies the open-profile callback and the settings extras | 10 |
| `android/app/build.gradle.kts` | `implementation("org.unifiedpush.android:connector:<C1 version>")` | 8 |
| `android/app/src/main/AndroidManifest.xml` | Declares `.porterwake.PorterPushService` and `.porterwake.PorterActionActivity` | 8 |
| `android/app/src/main/kotlin/com/tarkilhk/wing/MainActivity.kt` | `PorterWakeNative.attach(this, flutterEngine)` in `configureFlutterEngine`; `PorterWakeNative.handleMainIntent` in `onResume`/`onNewIntent` | 8 |
| `android/app/src/main/kotlin/com/tarkilhk/wing/MonitoringRuntime.kt` | `PorterWakeNative.detach()` next to `ChatNotifications.detach()` (`:127`) | 8 |
| `android/app/src/main/kotlin/com/tarkilhk/wing/ChatNotifications.kt` | `private fun createChannels` becomes `fun createChannels`, so the porter renderer reuses the attention channel definition | 8 |
| `.github/workflows/voice-review.yml` | Adds `test/porter_wake/porter_wake_settings_test.dart` to the render list | 9 |
| `PRIVACY.md`, `docs/PLAY_DATA_SAFETY.md`, `CHANGELOG.fork.md`, `README.md` | Docs | 12 |

## File structure

```
lib/porter_wake/
  porter_wake_payload.dart        PorterWakePayload.parse: contract §5.2
  porter_wake_notice.dart         PorterNotice + items/actions/feedback: contract §4
  porter_wake_api.dart            PorterWakeApi, PorterQuietHours, PorterApiError, PorterProbe: contract §3
  porter_wake_dashboard.dart      porterDashboardFor(SavedConnection)
  porter_wake_device_id.dart      PorterDeviceIdStore: contract §3.2
  porter_wake_ledger.dart         PorterNoticeLedger: duplicate notice_id guard, contract §6.8
  porter_wake_presentation.dart   PorterNotificationSpec, PorterButton: contract §6.2-6.3, 6.7
  porter_wake_bridge.dart         PorterWakeBridge, MethodChannelPorterWakeBridge, events
  porter_wake_handler.dart        PorterWakeHandler: push → fetch → show; taps → feedback
  porter_wake_module.dart         PorterWakeModule: probe gate, registration, revocation
  porter_wake_background.dart     @pragma('vm:entry-point') porterWakeBackgroundMain
  porter_wake_settings.dart       PorterWakeSettings + QuietHoursPanel („Nachtruhe“)
  porter_wake_snooze_sheet.dart   „in 2 Stunden“ / „morgen“ chooser (Task 11, gated)
test/porter_wake/
  porter_wake_fixtures.dart       Examples A/B/C (contract §4.1-4.3) as raw JSON strings
  porter_wake_fake_server.dart    MockClient-backed fake dashboard + porter routes
  fake_porter_bridge.dart         RecordingPorterWakeBridge
  porter_wake_payload_test.dart
  porter_wake_notice_test.dart
  porter_wake_api_test.dart
  porter_wake_device_id_test.dart
  porter_wake_ledger_test.dart
  porter_wake_presentation_test.dart
  porter_wake_bridge_test.dart
  porter_wake_handler_test.dart
  porter_wake_module_test.dart
  porter_wake_settings_test.dart
  porter_wake_snooze_sheet_test.dart
android/app/src/main/kotlin/com/tarkilhk/wing/porterwake/
  PorterPushService.kt  PorterWakeNative.kt  PorterHeadless.kt  PorterNotifications.kt  PorterActionActivity.kt
android/app/src/main/res/layout/
  notification_porter_row.xml  notification_porter_grid.xml
integration_test/porter_wake_device.dart          Isolated QA entry point (Task 13)
.github/workflows/porter-qa-apk.yml               Builds the QA APK → branch porter-qa-apk-bin
docs/PORTER_WAKE.md                               User-facing feature doc (README link)
```

## Contract §8.2 → named tests (1:1)

| §8.2 item | Test (file › name) |
|---|---|
| Payload: v1 `porter_wake` → exactly one fetch | `porter_wake_handler_test.dart` › `a v1 porter_wake push fetches the notice exactly once` |
| Payload: unknown `type` → no fetch, no crash | `porter_wake_handler_test.dart` › `an unknown push type fetches nothing and does not throw` |
| Payload: `v: 2` → no fetch, no crash | `porter_wake_handler_test.dart` › `a v2 push fetches nothing and does not throw` |
| (parser detail) | `porter_wake_payload_test.dart` › all |
| Notice parsing: A, B, C parse | `porter_wake_notice_test.dart` › `example A parses`, `example B parses with the snoozed block first`, `example C parses with no items` |
| Notice parsing: unknown fields ignored | `porter_wake_notice_test.dart` › `unknown fields and unknown action ids are ignored` |
| Actions: trial → 4 buttons + tap | `porter_wake_presentation_test.dart` › `a trial notice gives Später plus three ratings and an open tap` |
| Actions: live → 1 button + tap | `porter_wake_presentation_test.dart` › `a live notice gives only Später and an open tap` |
| Actions: every button posts the exact §3.3 body | `porter_wake_handler_test.dart` › `each button posts the exact feedback body` |
| Actions: `applied: false` is success | `porter_wake_handler_test.dart` › `applied false is a success and dismisses the notification` |
| Isolation: 404 probe → no registration | `porter_wake_module_test.dart` › `a 404 probe registers nothing and calls no other porter route` |
| Isolation: 404 probe → no „Nachtruhe“ | `porter_wake_settings_test.dart` › `Nachtruhe is hidden when the module is inactive` |
| (503 treated like 404) | `porter_wake_module_test.dart` › `a 503 probe is treated like 404` |
| „Nachtruhe“: shows GET values | `porter_wake_settings_test.dart` › `Nachtruhe shows the server values` |
| „Nachtruhe“: PUT error reverts + shows text | `porter_wake_settings_test.dart` › `a rejected save reverts and shows the server error` |
| Fetch failure → „Pforte: neue Nachricht“, only „Öffnen“ | `porter_wake_handler_test.dart` › `a failed fetch shows the neutral notice with only the open tap`; `porter_wake_presentation_test.dart` › `the neutral notice has no buttons` |
| §6.8 duplicates | `porter_wake_handler_test.dart` › `a second push with the same notice id shows nothing and posts nothing` |

---

### Task 0: Factory suite runs a chosen test path

**Why first:** without this change, `ci-suite.sh` runs only `test/car_mode/car_mode_screen_test.dart`, so no porter test would ever run in CI.

> **ANNAHME T0:** the hard-coded path and the "Diagnostic stack extraction" step in `pr-quality.yml` belong to card t_db672361. This task replaces only the test command and leaves the diagnostic steps alone. **Check** `git log -3 -- .github/workflows/pr-quality.yml` before editing. If a newer commit has already restored `flutter test`, keep that and add only the input.

**Files:**
- Modify: `.github/workflows/pr-quality.yml` (the `workflow_dispatch:` trigger, and step "Run tests", `:59-64`)
- Modify: `tools/factory/ci-suite.sh` (the `gh workflow run` line)

**Interfaces:**
- Produces: `bash tools/factory/ci-suite.sh [test-path]`. With no argument it runs the whole `test/` directory.

- [ ] **Step 1: Add the input.** In `pr-quality.yml`, replace `  workflow_dispatch:` with:

```yaml
  workflow_dispatch:
    inputs:
      tests:
        description: Test path(s) for flutter test (default the whole suite)
        type: string
        default: 'test/'
```

- [ ] **Step 2: Use the input.** In step "Run tests", replace the `flutter test` line with:

```yaml
          flutter test --no-pub --reporter=expanded ${{ inputs.tests || 'test/' }} 2>&1 | tee test_output.txt
```

- [ ] **Step 3: Forward the argument.** In `ci-suite.sh`, replace `gh workflow run pr-quality.yml -R "$repo" --ref "$br" >/dev/null` with:

```bash
if [ $# -gt 0 ]; then
  gh workflow run pr-quality.yml -R "$repo" --ref "$br" -f tests="$*" >/dev/null
else
  gh workflow run pr-quality.yml -R "$repo" --ref "$br" >/dev/null
fi
```

Also change the comment line `# Full Wing suite (flutter analyze + flutter test) on GitHub Actions.` to `# Wing suite (flutter analyze + flutter test [path]) on GitHub Actions.`

- [ ] **Step 4: Commit, then prove that a path is honoured.** Run the CI after committing, because the script tests HEAD:

```bash
git add .github/workflows/pr-quality.yml tools/factory/ci-suite.sh
git commit -m "ci: let the factory suite run a chosen test path"
```

Run: `bash tools/factory/ci-suite.sh test/notification_delivery_ledger_test.dart`
Expected:
- `ci-suite: run <id> …` and `Analyze & Test: success`, then `conclusion=success`;
- in `gh run view <id> -R birkschmithuesen/Wing --json jobs`, the step "Run tests" succeeded.

If `notification_delivery_ledger_test.dart` does not exist, use any existing small test from `ls test/*ledger*`.

---

### Task 1: Push payload parser

**Files:**
- Create: `lib/porter_wake/porter_wake_payload.dart`
- Test: `test/porter_wake/porter_wake_payload_test.dart`

**Interfaces:**
- Produces: `class PorterWakePayload { final String noticeId; static PorterWakePayload? parse(List<int> bytes); }`. It returns null for anything other than a v1 `porter_wake` push and never throws.

- [ ] **Step 1: Write the failing test**

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/porter_wake/porter_wake_payload.dart';

List<int> bytes(String s) => utf8.encode(s);

void main() {
  test('a v1 porter_wake push yields its notice id', () {
    final p = PorterWakePayload.parse(
      bytes('{"v":1,"type":"porter_wake","notice_id":"n-3f2a9c1b7d4e"}'),
    );
    expect(p?.noticeId, 'n-3f2a9c1b7d4e');
  });

  test('unknown type, v2, bad id, non-JSON and non-UTF-8 are ignored', () {
    for (final raw in [
      bytes('{"v":1,"type":"other","notice_id":"n-3f2a9c1b7d4e"}'),
      bytes('{"v":2,"type":"porter_wake","notice_id":"n-3f2a9c1b7d4e"}'),
      bytes('{"v":"1","type":"porter_wake","notice_id":"n-3f2a9c1b7d4e"}'),
      bytes('{"v":1,"type":"porter_wake","notice_id":"../settings"}'),
      bytes('{"v":1,"type":"porter_wake"}'),
      bytes('[1,2]'),
      bytes('not json'),
      [0xff, 0xfe, 0x00],
      <int>[],
    ]) {
      expect(PorterWakePayload.parse(raw), isNull, reason: '$raw');
    }
  });

  test('extra fields do not matter', () {
    final p = PorterWakePayload.parse(
      bytes('{"v":1,"type":"porter_wake","notice_id":"n-000000000000","x":1}'),
    );
    expect(p?.noticeId, 'n-000000000000');
  });
}
```

- [ ] **Step 2: Commit the test, run it, and see it fail**

```bash
git add test/porter_wake/porter_wake_payload_test.dart
git commit -m "test(porter_wake): payload parser"
```

Run: `bash tools/factory/ci-suite.sh test/porter_wake/porter_wake_payload_test.dart`
Expected: `failed step: Static analysis` (the target of the URI doesn't exist yet) and `conclusion=failure`.

- [ ] **Step 3: Implement**

```dart
import 'dart:convert';

/// The content-free push of the porter wake gate. Only [noticeId] is used, and
/// only in the notice URL.
class PorterWakePayload {
  const PorterWakePayload(this.noticeId);

  final String noticeId;

  static final _noticeId = RegExp(r'^n-[0-9a-f]{12}$');

  /// Null for anything that is not a v1 `porter_wake` push. Never throws.
  static PorterWakePayload? parse(List<int> bytes) {
    final Object? data;
    try {
      data = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
    if (data is! Map || data['type'] != 'porter_wake' || data['v'] != 1) {
      return null;
    }
    final id = data['notice_id'];
    if (id is! String || !_noticeId.hasMatch(id)) return null;
    return PorterWakePayload(id);
  }
}
```

- [ ] **Step 4: Run and see it pass**

Run: `bash tools/factory/ci-suite.sh test/porter_wake/porter_wake_payload_test.dart`
Expected: `conclusion=success`.

- [ ] **Step 5: Commit**

```bash
git add lib/porter_wake/porter_wake_payload.dart
git commit -m "feat(porter_wake): parse the content-free push payload"
```

---

### Task 2: Notice model and fixtures

**Files:**
- Create: `lib/porter_wake/porter_wake_notice.dart`
- Create: `test/porter_wake/porter_wake_fixtures.dart`
- Test: `test/porter_wake/porter_wake_notice_test.dart`

**Interfaces:**
- Produces:
  - `class PorterNotice { int v; String noticeId; String mode; String kind; String level; String title; List<String> lines; List<PorterNoticeItem> items; List<PorterNoticeAction> actions; String openProfile; PorterNoticeFeedback feedback; bool get isTrial; factory PorterNotice.fromJson(Map<String, dynamic>); }` (throws `FormatException`)
  - `class PorterNoticeItem { String itemId, sessionId, profile, block, line; String? why, snoozeLabel; }`
  - `class PorterNoticeAction { String id; String label; String? value; String? defaultValue; }`
  - `class PorterNoticeFeedback { String? rating; String? snoozedUntil; bool opened; }`
  - Fixtures: `const porterExampleA`, `porterExampleB`, `porterExampleC` (raw JSON `String`s, copied byte-for-byte from contract §4.1–4.3).

- [ ] **Step 1: Fixtures.** Create `test/porter_wake/porter_wake_fixtures.dart`, starting with `/// Synthetic examples copied from contract §4.1-4.3. No real data.` Define three `const String`s using raw triple-quoted strings (`r'''…'''`), whose contents are exactly the JSON blocks of contract §4.1, §4.2 and §4.3. Each is copied whole from the opening `{"v": 1, ` to the final `}`, keeping the emoji and umlauts. Then add:

```dart
const porterNoticeIds = ['n-3f2a9c1b7d4e', 'n-9e8d7c6b5a41', 'n-5a4b3c2d1e0f'];
const porterExamples = [porterExampleA, porterExampleB, porterExampleC];
```

- [ ] **Step 2: Write the failing test**

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/porter_wake/porter_wake_notice.dart';

import 'porter_wake_fixtures.dart';

PorterNotice parse(String raw) =>
    PorterNotice.fromJson(jsonDecode(raw) as Map<String, dynamic>);

void main() {
  test('example A parses', () {
    final n = parse(porterExampleA);
    expect(n.noticeId, 'n-3f2a9c1b7d4e');
    expect(n.isTrial, isTrue);
    expect(n.title, '🔴 Birk wartet auf dich');
    expect(n.lines, [
      'Antwort an Galerie Ostwind freigeben?',
      'Jemand wartet auf Antwort',
    ]);
    expect(n.items.single.sessionId, 's-ostwind');
    expect(n.actions.map((a) => a.id), ['open', 'snooze', 'rate', 'rate', 'rate']);
    expect(n.actions[1].defaultValue, 'default');
    expect(n.actions.skip(2).map((a) => a.value),
        ['unwichtig', 'so_lala', 'sehr_wichtig']);
    expect(n.openProfile, 'pforte');
    expect(n.feedback.rating, isNull);
    expect(n.feedback.opened, isFalse);
  });

  test('example B parses with the snoozed block first', () {
    final n = parse(porterExampleB);
    expect(n.isTrial, isFalse);
    expect(n.items.map((i) => i.block), ['snoozed', 'new', 'new']);
    expect(n.items.first.snoozeLabel,
        'zurückgestellt gestern 15:10 · 2× zurückgestellt');
    expect(n.items[1].snoozeLabel, isNull);
    expect(n.lines.first, startsWith('⏰ Zurückgestellt: '));
    expect(n.actions.map((a) => a.id), ['open', 'snooze']);
  });

  test('example C parses with no items', () {
    final n = parse(porterExampleC);
    expect(n.kind, 'trial_end');
    expect(n.items, isEmpty);
    expect(n.lines, ['Probelauf beendet, ab jetzt höchstens 3 am Tag']);
  });

  test('unknown fields and unknown action ids are ignored', () {
    final data = jsonDecode(porterExampleA) as Map<String, dynamic>
      ..['future_field'] = {'x': 1}
      ..['kind'] = 'brand_new_kind';
    (data['actions'] as List).add({'id': 'teleport', 'label': 'X'});
    (data['items'] as List).first['extra'] = true;
    final n = PorterNotice.fromJson(data);
    expect(n.kind, 'brand_new_kind');
    expect(n.actions.map((a) => a.id), isNot(contains('teleport')));
    expect(n.items, hasLength(1));
  });

  test('a notice without title or lines is malformed', () {
    final data = jsonDecode(porterExampleC) as Map<String, dynamic>
      ..remove('title');
    expect(() => PorterNotice.fromJson(data), throwsFormatException);
    final noLines = jsonDecode(porterExampleC) as Map<String, dynamic>
      ..['lines'] = 'x';
    expect(() => PorterNotice.fromJson(noLines), throwsFormatException);
  });
}
```

- [ ] **Step 3: Commit the test, run it, and see it fail**

```bash
git add test/porter_wake/porter_wake_fixtures.dart test/porter_wake/porter_wake_notice_test.dart
git commit -m "test(porter_wake): notice parsing for examples A, B and C"
```

Run: `bash tools/factory/ci-suite.sh test/porter_wake/porter_wake_notice_test.dart`
Expected: `conclusion=failure` (`failed step: Static analysis`).

- [ ] **Step 4: Implement**

```dart
/// The notice of contract §4. All text is rendered by the server; Wing shows it as given.
class PorterNotice {
  const PorterNotice({
    required this.v,
    required this.noticeId,
    required this.mode,
    required this.kind,
    required this.level,
    required this.title,
    required this.lines,
    required this.items,
    required this.actions,
    required this.openProfile,
    required this.feedback,
  });

  final int v;
  final String noticeId;
  final String mode;
  final String kind;
  final String level;
  final String title;
  final List<String> lines;
  final List<PorterNoticeItem> items;
  final List<PorterNoticeAction> actions;
  final String openProfile;
  final PorterNoticeFeedback feedback;

  bool get isTrial => mode == 'trial';

  static const knownActions = {'open', 'snooze', 'rate'};

  factory PorterNotice.fromJson(Map<String, dynamic> json) {
    try {
      final lines = json['lines'] as List;
      return PorterNotice(
        v: json['v'] as int,
        noticeId: json['notice_id'] as String,
        mode: json['mode'] as String? ?? 'live',
        kind: json['kind'] as String? ?? 'items',
        level: json['level'] as String? ?? 'yellow',
        title: json['title'] as String,
        lines: [for (final line in lines) line as String],
        items: [
          for (final item in json['items'] as List? ?? const [])
            PorterNoticeItem.fromJson(Map<String, dynamic>.from(item as Map)),
        ],
        actions: [
          for (final raw in json['actions'] as List? ?? const [])
            if (raw is Map && knownActions.contains(raw['id']))
              PorterNoticeAction.fromJson(Map<String, dynamic>.from(raw)),
        ],
        openProfile: json['open_profile'] as String? ?? 'pforte',
        feedback: PorterNoticeFeedback.fromJson(
          Map<String, dynamic>.from(json['feedback'] as Map? ?? const {}),
        ),
      );
    } on TypeError catch (error) {
      throw FormatException('Malformed porter notice: $error');
    }
  }
}

class PorterNoticeItem {
  const PorterNoticeItem({
    required this.itemId,
    required this.sessionId,
    required this.profile,
    required this.block,
    required this.line,
    this.why,
    this.snoozeLabel,
  });

  final String itemId;
  final String sessionId;
  final String profile;
  final String block;
  final String line;
  final String? why;
  final String? snoozeLabel;

  factory PorterNoticeItem.fromJson(Map<String, dynamic> json) =>
      PorterNoticeItem(
        itemId: json['item_id'] as String,
        sessionId: json['session_id'] as String,
        profile: json['profile'] as String,
        block: json['block'] as String,
        line: json['line'] as String,
        why: json['why'] as String?,
        snoozeLabel: json['snooze_label'] as String?,
      );
}

class PorterNoticeAction {
  const PorterNoticeAction({
    required this.id,
    required this.label,
    this.value,
    this.defaultValue,
  });

  final String id;
  final String label;
  final String? value;
  final String? defaultValue;

  factory PorterNoticeAction.fromJson(Map<String, dynamic> json) =>
      PorterNoticeAction(
        id: json['id'] as String,
        label: json['label'] as String,
        value: json['value'] as String?,
        defaultValue: json['default'] as String?,
      );
}

class PorterNoticeFeedback {
  const PorterNoticeFeedback({this.rating, this.snoozedUntil, this.opened = false});

  final String? rating;
  final String? snoozedUntil;
  final bool opened;

  factory PorterNoticeFeedback.fromJson(Map<String, dynamic> json) =>
      PorterNoticeFeedback(
        rating: json['rating'] as String?,
        snoozedUntil: json['snoozed_until'] as String?,
        opened: json['opened'] == true,
      );
}
```

- [ ] **Step 5: Run and see it pass**

Run: `bash tools/factory/ci-suite.sh test/porter_wake/porter_wake_notice_test.dart`
Expected: `conclusion=success`.

- [ ] **Step 6: Commit**

```bash
git add lib/porter_wake/porter_wake_notice.dart
git commit -m "feat(porter_wake): parse the server-rendered notice"
```

---

### Task 3: `DashboardClient.apiSend` seam and `PorterWakeApi`

**Files:**
- Modify: `lib/core/services/connection_manager.dart` (insert `apiSend` directly after `apiPut`, which ends at `:1693`)
- Create: `lib/porter_wake/porter_wake_dashboard.dart`
- Create: `lib/porter_wake/porter_wake_api.dart`
- Create: `test/porter_wake/porter_wake_fake_server.dart`
- Test: `test/porter_wake/porter_wake_api_test.dart`

**Interfaces:**
- Consumes: `PorterNotice.fromJson` (Task 2).
- Produces:
  - Core: `Future<http.Response> DashboardClient.apiSend(String method, String endpoint, {Map<String, dynamic>? body, bool retried = false})`. It returns any status and re-logs in once on 401.
  - `DashboardClient porterDashboardFor(SavedConnection connection)`
  - `enum PorterProbe { active, absent, unknown }`
  - `class PorterApiError implements Exception { final int status; final String? serverError; String get message; }`
  - `class PorterQuietHours { final bool enabled; final String from; final String to; final String timezone; PorterQuietHours copyWith({bool? enabled, String? from, String? to}); Map<String, Object> toPutJson(); factory PorterQuietHours.fromJson(Map<String, dynamic>); }`
  - `class PorterWakeApi`, constructed as `PorterWakeApi(DashboardClient client)`, with:
    - `Future<PorterProbe> probe()`
    - `Future<PorterNotice> notice(String noticeId)`
    - `Future<bool> feedback(String noticeId, Map<String, String> body)`, which returns `applied`
    - `Future<PorterQuietHours> quietHours()`
    - `Future<PorterQuietHours> saveQuietHours(PorterQuietHours value)`
    - `Future<void> registerDevice({required String deviceId, required String endpoint, String? label})`
    - `Future<void> removeDevice(String deviceId)`
    - `void close()`
  - Test helper: `class FakePorterServer`. Its fields: `Map<String, int> statusFor` (keyed by `'<METHOD> <path>'`), `Map<String, Object?> bodyFor`, `List<http.Request> requests`, `int logins`. Methods: `DashboardClient client()` and `List<http.Request> porterRequests()`. Defaults: login 200 with cookie `hermes_session_at=fixture`; quiet-hours GET returns the contract §3.4 body; the notices from `porterExamples`; feedback returns `{"applied": true, …}`; device POST/DELETE return 200.

- [ ] **Step 1: Fake server**

```dart
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wing/core/services/connection_manager.dart';

import 'porter_wake_fixtures.dart';

/// Fake dashboard for porter wake tests. Synthetic data only.
class FakePorterServer {
  static const base = '/api/plugins/porter_wake';
  final requests = <http.Request>[];
  final _statusFor = <String, int>{};
  Map<String, int> get statusFor => _statusFor;
  final bodyFor = <String, Object?>{};
  int logins = 0;
  Map<String, Object?> quietHours = {
    'enabled': true,
    'from': '22:00',
    'to': '08:00',
    'timezone': 'Europe/Berlin',
  };

  List<http.Request> porterRequests() =>
      requests.where((r) => r.url.path.startsWith(base)).toList();

  DashboardClient client() => DashboardClient(
    host: 'hermes.test',
    port: 9119,
    username: 'owner',
    password: 'fixture',
    httpClient: MockClient(_handle),
  );

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path == '/auth/password-login') {
      logins++;
      return http.Response('{}', 200,
          headers: {'set-cookie': 'hermes_session_at=fixture; Path=/'});
    }
    final key = '${request.method} $path';
    final status = statusFor[key] ?? 200;
    Object? body = bodyFor[key];
    if (body == null && status == 200) body = _default(request, path);
    return http.Response.bytes(
      utf8.encode(jsonEncode(body ?? {'error': 'fixture error'})),
      status,
      headers: {'content-type': 'application/json'},
    );
  }

  Object? _default(http.Request request, String path) {
    if (path == '$base/settings/quiet-hours') {
      if (request.method == 'PUT') {
        quietHours = {...jsonDecode(request.body) as Map<String, dynamic>,
            'timezone': 'Europe/Berlin'};
      }
      return quietHours;
    }
    for (var i = 0; i < porterNoticeIds.length; i++) {
      final id = porterNoticeIds[i];
      if (path == '$base/notices/$id') return jsonDecode(porterExamples[i]);
      if (path == '$base/notices/$id/feedback') {
        final sent = jsonDecode(request.body) as Map<String, dynamic>;
        return {'notice_id': id, 'action': sent['action'], 'applied': true, 'result': {}};
      }
    }
    if (path == '$base/push/devices') {
      return {'device_id': 'x', 'registered': '2026-10-19T06:00:00.000Z', 'replaced': false};
    }
    if (path.startsWith('$base/push/devices/')) return {'removed': true};
    return null;
  }
}
```

- [ ] **Step 2: Write the failing test**

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/porter_wake/porter_wake_api.dart';

import 'porter_wake_fake_server.dart';

void main() {
  late FakePorterServer server;
  late PorterWakeApi api;
  setUp(() {
    server = FakePorterServer();
    api = PorterWakeApi(server.client());
  });

  test('probe: 200 active, 404 and 503 absent, 500 unknown', () async {
    expect(await api.probe(), PorterProbe.active);
    for (final (status, expected) in [
      (404, PorterProbe.absent),
      (503, PorterProbe.absent),
      (500, PorterProbe.unknown),
    ]) {
      server.statusFor['GET ${FakePorterServer.base}/settings/quiet-hours'] = status;
      expect(await api.probe(), expected, reason: '$status');
    }
  });

  test('a 401 re-logs in once and retries', () async {
    final s = _FlakyAuthServer();
    expect(await PorterWakeApi(s.client()).probe(), PorterProbe.active);
    expect(s.logins, 2);
  });

  test('notice text survives UTF-8 (emoji and umlauts)', () async {
    final n = await api.notice('n-9e8d7c6b5a41');
    expect(n.title, '🔴 3 Dinge warten');
    expect(n.items.last.line, 'Zugangsdaten im Klartext in Notiz gefunden: löschen?');
  });

  test('saveQuietHours sends exactly enabled, from, to and returns the 200 body', () async {
    final saved = await api.saveQuietHours(
      const PorterQuietHours(enabled: true, from: '22:00', to: '07:30', timezone: 'Europe/Berlin'),
    );
    final put = server.porterRequests().last;
    expect(put.method, 'PUT');
    expect(jsonDecode(put.body), {'enabled': true, 'from': '22:00', 'to': '07:30'});
    expect(saved.to, '07:30');
  });

  test('400 and 409 carry the server error text', () async {
    for (final (status, text) in [(400, 'from equals to'), (409, 'config layout not editable')]) {
      server.statusFor['PUT ${FakePorterServer.base}/settings/quiet-hours'] = status;
      server.bodyFor['PUT ${FakePorterServer.base}/settings/quiet-hours'] = {'error': text};
      await expectLater(
        api.saveQuietHours(const PorterQuietHours(
            enabled: true, from: '22:00', to: '22:00', timezone: 'Europe/Berlin')),
        throwsA(isA<PorterApiError>()
            .having((e) => e.status, 'status', status)
            .having((e) => e.message, 'message', text)),
      );
    }
  });

  test('device registration and removal use the contract shapes', () async {
    await api.registerDevice(
      deviceId: 'wing-0123456789abcdef',
      endpoint: 'http://100.75.24.33:2586/upAbC123xyz?up=1',
      label: 'Pixel 7',
    );
    await api.removeDevice('wing-0123456789abcdef');
    final [post, delete] = server.porterRequests();
    expect(post.url.path, '${FakePorterServer.base}/push/devices');
    expect(jsonDecode(post.body), {
      'device_id': 'wing-0123456789abcdef',
      'endpoint': 'http://100.75.24.33:2586/upAbC123xyz?up=1',
      'label': 'Pixel 7',
    });
    expect(delete.method, 'DELETE');
    expect(delete.url.path, '${FakePorterServer.base}/push/devices/wing-0123456789abcdef');
  });
}

/// The first quiet-hours GET answers 401; the retry after re-login answers 200.
class _FlakyAuthServer extends FakePorterServer {
  var _rejected = false;
  @override
  Map<String, int> get statusFor {
    if (!_rejected && requests.where((r) => r.url.path.endsWith('/quiet-hours')).length == 1) {
      _rejected = true;
      return {'GET ${FakePorterServer.base}/settings/quiet-hours': 401};
    }
    return {};
  }
}
```

`FakePorterServer.statusFor` is a getter (Step 1), so `_FlakyAuthServer` can override it. The other tests write through the getter (`server.statusFor[...] = …`).

- [ ] **Step 3: Commit the test, run it, and see it fail**

```bash
git add test/porter_wake/porter_wake_fake_server.dart test/porter_wake/porter_wake_api_test.dart
git commit -m "test(porter_wake): API client against a fake dashboard"
```

Run: `bash tools/factory/ci-suite.sh test/porter_wake/porter_wake_api_test.dart`
Expected: `conclusion=failure`.

- [ ] **Step 4: Core seam.** In `connection_manager.dart`, directly after the closing brace of `apiPut` (`:1693`), add:

```dart
  /// Sends an authenticated API request and returns the response for any
  /// status after one re-login on 401. Callers own status and body handling.
  Future<http.Response> apiSend(
    String method,
    String endpoint, {
    Map<String, dynamic>? body,
    bool retried = false,
  }) async {
    final headers = await _authHeaders();
    final request = http.Request(method, Uri.parse('$_baseUrl/api/$endpoint'))
      ..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    final res = await http.Response.fromStream(await _http.send(request));
    if (res.statusCode == 401 && !retried) {
      _resetAuth(headers);
      return apiSend(method, endpoint, body: body, retried: true);
    }
    return res;
  }
```

- [ ] **Step 5: Implement the module files**

`lib/porter_wake/porter_wake_dashboard.dart`:

```dart
import '../core/services/connection_manager.dart';

/// Same construction as the other per-service dashboard clients
/// (profile_gateway.dart `_dashboardFor`).
DashboardClient porterDashboardFor(SavedConnection connection) => DashboardClient(
  host: connection.host,
  port: connection.dashboardPort,
  useHttps: connection.useHttps,
  pathPrefix: connection.dashboardPrefix ?? '',
  proxied: connection.dashboardProxied,
  username: connection.dashboardUsername,
  password: connection.dashboardPassword,
  dashboardOAuth: connection.dashboardOAuth,
  requiresOAuth: connection.isCloud,
  gatewayHeaders: connection.gatewayHeaders,
);
```

`lib/porter_wake/porter_wake_api.dart`:

```dart
import 'dart:convert';

import '../core/services/connection_manager.dart';
import 'porter_wake_notice.dart';

enum PorterProbe { active, absent, unknown }

class PorterApiError implements Exception {
  const PorterApiError(this.status, this.serverError);
  final int status;
  final String? serverError;
  String get message => serverError ?? 'The server answered HTTP $status.';
  @override
  String toString() => 'PorterApiError($status)';
}

class PorterQuietHours {
  const PorterQuietHours({
    required this.enabled,
    required this.from,
    required this.to,
    required this.timezone,
  });

  final bool enabled;
  final String from;
  final String to;
  final String timezone;

  factory PorterQuietHours.fromJson(Map<String, dynamic> json) => PorterQuietHours(
    enabled: json['enabled'] as bool,
    from: json['from'] as String,
    to: json['to'] as String,
    timezone: json['timezone'] as String? ?? '',
  );

  PorterQuietHours copyWith({bool? enabled, String? from, String? to}) =>
      PorterQuietHours(
        enabled: enabled ?? this.enabled,
        from: from ?? this.from,
        to: to ?? this.to,
        timezone: timezone,
      );

  /// The timezone is read-only on the server; sending it answers 400.
  Map<String, Object> toPutJson() => {'enabled': enabled, 'from': from, 'to': to};
}

/// The porter wake routes of contract §3 over the connection's dashboard auth.
class PorterWakeApi {
  PorterWakeApi(this._client);

  final DashboardClient _client;
  static const _base = 'plugins/porter_wake';

  Future<PorterProbe> probe() async {
    try {
      await _json('GET', 'settings/quiet-hours');
      return PorterProbe.active;
    } on PorterApiError catch (error) {
      return error.status == 404 || error.status == 503
          ? PorterProbe.absent
          : PorterProbe.unknown;
    } on Object {
      return PorterProbe.unknown;
    }
  }

  Future<PorterNotice> notice(String noticeId) async =>
      PorterNotice.fromJson(await _json('GET', 'notices/$noticeId'));

  Future<bool> feedback(String noticeId, Map<String, String> body) async =>
      (await _json('POST', 'notices/$noticeId/feedback', body: body))['applied'] == true;

  Future<PorterQuietHours> quietHours() async =>
      PorterQuietHours.fromJson(await _json('GET', 'settings/quiet-hours'));

  Future<PorterQuietHours> saveQuietHours(PorterQuietHours value) async =>
      PorterQuietHours.fromJson(
        await _json('PUT', 'settings/quiet-hours', body: value.toPutJson()),
      );

  Future<void> registerDevice({
    required String deviceId,
    required String endpoint,
    String? label,
  }) => _json('POST', 'push/devices', body: {
    'device_id': deviceId,
    'endpoint': endpoint,
    'label': ?label,
  });

  Future<void> removeDevice(String deviceId) =>
      _json('DELETE', 'push/devices/$deviceId');

  void close() => _client.close();

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, Object>? body,
  }) async {
    final res = await _client
        .apiSend(method, '$_base/$path', body: body)
        .timeout(const Duration(seconds: 20));
    Object? decoded;
    try {
      decoded = res.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      decoded = null;
    }
    final map = decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{};
    if (res.statusCode != 200) {
      final error = map['error'];
      throw PorterApiError(res.statusCode, error is String ? error : null);
    }
    return map;
  }
}
```

Note: `'label': ?label` is Dart 3.8+ null-aware map syntax, which the SDK `^3.12.0` supports. If `flutter analyze` rejects it, use `if (label != null) 'label': label`.

- [ ] **Step 6: Run and see it pass**

Run: `bash tools/factory/ci-suite.sh test/porter_wake/porter_wake_api_test.dart test/connection_manager_test.dart`
Expected: `conclusion=success`. The existing `connection_manager_test.dart` still passes because no existing helper changed.

- [ ] **Step 7: Commit**

```bash
git add lib/core/services/connection_manager.dart lib/porter_wake/porter_wake_dashboard.dart lib/porter_wake/porter_wake_api.dart test/porter_wake/porter_wake_api_test.dart test/porter_wake/porter_wake_fake_server.dart
git commit -m "feat(porter_wake): API client over a raw-response dashboard helper"
```

---

### Task 4: Device id store and duplicate ledger

**Files:**
- Create: `lib/porter_wake/porter_wake_device_id.dart`
- Create: `lib/porter_wake/porter_wake_ledger.dart`
- Test: `test/porter_wake/porter_wake_device_id_test.dart`
- Test: `test/porter_wake/porter_wake_ledger_test.dart`

**Interfaces:**
- Consumes: `CredentialStore` (`connection_manager.dart:23-31`: `read`, `write`, `delete`, `readCached`).
- Produces:
  - `class PorterDeviceIdStore`, constructed as `PorterDeviceIdStore({CredentialStore? store})`, with `Future<String> read()` (creates on first call, stable afterwards) and `static const key = 'porter_wake_device_id_v1'`. The production store is `FlutterSecureCredentialStore(storage: FlutterSecureStorage(aOptions: AndroidOptions(resetOnError: false, storageNamespace: 'wing_porter_wake')))`.
  - `class PorterNoticeLedger`, constructed as `PorterNoticeLedger(SharedPreferences prefs)`, with `Future<bool> claim(String noticeId)`, `Future<void> release(String noticeId)` and `static const key = 'porter_wake_seen_notices'` (keeps the last 32).

> **ANNAHME D1:** `FlutterSecureCredentialStore({FlutterSecureStorage? storage})` (`connection_manager.dart:43`) accepts a storage whose `AndroidOptions` use another namespace, so the device id stays out of `wing_connections` and therefore out of connection backups. **Check** the constructor and `config_backup_service.dart`. If the store forces its own options, construct `FlutterSecureStorage` directly in a 10-line `CredentialStore` implementation inside the module.

- [ ] **Step 1: Write the failing tests**

`test/porter_wake/porter_wake_device_id_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/porter_wake/porter_wake_device_id.dart';

/// Shared with the module and settings tests.
class MemoryCredentialStore implements CredentialStore {
  final values = <String, String>{};
  @override
  String? readCached(String key) => values[key];
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  test('the device id is created once, matches the contract and stays stable', () async {
    final memory = MemoryCredentialStore();
    final first = await PorterDeviceIdStore(store: memory).read();
    final again = await PorterDeviceIdStore(store: memory).read();
    expect(first, matches(RegExp(r'^wing-[0-9a-f]{16}$')));
    expect(RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(first), isTrue);
    expect(again, first);
    expect(memory.values[PorterDeviceIdStore.key], first);
  });

  test('two installs get different ids', () async {
    final a = await PorterDeviceIdStore(store: MemoryCredentialStore()).read();
    final b = await PorterDeviceIdStore(store: MemoryCredentialStore()).read();
    expect(a, isNot(b));
  });
}
```

`test/porter_wake/porter_wake_ledger_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/porter_wake/porter_wake_ledger.dart';

void main() {
  late PorterNoticeLedger ledger;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ledger = PorterNoticeLedger(await SharedPreferences.getInstance());
  });

  test('a notice id is claimed once', () async {
    expect(await ledger.claim('n-3f2a9c1b7d4e'), isTrue);
    expect(await ledger.claim('n-3f2a9c1b7d4e'), isFalse);
  });

  test('release allows a retry', () async {
    await ledger.claim('n-3f2a9c1b7d4e');
    await ledger.release('n-3f2a9c1b7d4e');
    expect(await ledger.claim('n-3f2a9c1b7d4e'), isTrue);
  });

  test('concurrent claims of one id yield exactly one winner', () async {
    final results = await Future.wait([
      for (var i = 0; i < 5; i++) ledger.claim('n-9e8d7c6b5a41'),
    ]);
    expect(results.where((r) => r), hasLength(1));
  });

  test('only the last 32 ids are kept', () async {
    for (var i = 0; i < 40; i++) {
      await ledger.claim('n-${i.toRadixString(16).padLeft(12, '0')}');
    }
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(PorterNoticeLedger.key), hasLength(32));
  });
}
```

- [ ] **Step 2: Commit the tests, run them, and see them fail**

```bash
git add test/porter_wake/porter_wake_device_id_test.dart test/porter_wake/porter_wake_ledger_test.dart
git commit -m "test(porter_wake): device id and notice ledger"
```

Run: `bash tools/factory/ci-suite.sh test/porter_wake/porter_wake_device_id_test.dart test/porter_wake/porter_wake_ledger_test.dart`
Expected: `conclusion=failure`.

- [ ] **Step 3: Implement**

`lib/porter_wake/porter_wake_device_id.dart`:

```dart
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/services/connection_manager.dart';

/// One push device id per Wing install (contract §3.2), kept in secure storage
/// outside the connection namespace.
class PorterDeviceIdStore {
  PorterDeviceIdStore({CredentialStore? store})
    : _store = store ??
          FlutterSecureCredentialStore(
            storage: const FlutterSecureStorage(
              aOptions: AndroidOptions(
                resetOnError: false,
                storageNamespace: 'wing_porter_wake',
              ),
            ),
          );

  static const key = 'porter_wake_device_id_v1';
  final CredentialStore _store;

  Future<String> read() async {
    final existing = await _store.read(key);
    if (existing != null && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final hex = [
      for (var i = 0; i < 8; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    final id = 'wing-$hex';
    await _store.write(key, id);
    return id;
  }
}
```

`lib/porter_wake/porter_wake_ledger.dart` (serialized like `NotificationDeliveryLedger`):

```dart
import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// Guards against a second notification for the same notice id (contract §6.8).
/// Shared by the app engine and the headless push engine through preferences.
class PorterNoticeLedger {
  PorterNoticeLedger(this._prefs);

  static const key = 'porter_wake_seen_notices';
  static const _limit = 32;
  final SharedPreferences _prefs;
  Future<void> _writes = Future.value();

  Future<bool> claim(String noticeId) {
    final result = Completer<bool>();
    _writes = _writes.then((_) async {
      await _prefs.reload();
      final ids = _prefs.getStringList(key) ?? <String>[];
      if (ids.contains(noticeId)) return result.complete(false);
      final next = [...ids, noticeId];
      if (next.length > _limit) next.removeRange(0, next.length - _limit);
      await _prefs.setStringList(key, next);
      result.complete(true);
    }).catchError((Object error) {
      if (!result.isCompleted) result.completeError(error);
    });
    return result.future;
  }

  Future<void> release(String noticeId) {
    _writes = _writes.then((_) async {
      await _prefs.reload();
      final ids = _prefs.getStringList(key) ?? <String>[];
      await _prefs.setStringList(key, ids.where((id) => id != noticeId).toList());
    });
    return _writes;
  }
}
```

- [ ] **Step 4: Run and see them pass**

Run: `bash tools/factory/ci-suite.sh test/porter_wake/porter_wake_device_id_test.dart test/porter_wake/porter_wake_ledger_test.dart`
Expected: `conclusion=success`.

- [ ] **Step 5: Commit**

```bash
git add lib/porter_wake/porter_wake_device_id.dart lib/porter_wake/porter_wake_ledger.dart
git commit -m "feat(porter_wake): stable device id and duplicate-notice ledger"
```

---

### Task 5: Notification presentation (buttons, neutral notice)

**Files:**
- Create: `lib/porter_wake/porter_wake_presentation.dart`
- Test: `test/porter_wake/porter_wake_presentation_test.dart`

**Interfaces:**
- Consumes: `PorterNotice` (Task 2).
- Produces:
  - `class PorterButton { final String action; final String label; final String value; Map<String, String> toJson(); Map<String, String> get feedbackBody; }`
  - `class PorterNotificationSpec { static const notificationId = 214700; static const channel = 'wing_attention_notifications'; static const neutralTitle = 'Pforte: neue Nachricht'; final String connectionId, noticeId, title, body, expanded, openProfile; final List<PorterButton> buttons; final bool neutral; factory PorterNotificationSpec.fromNotice(String connectionId, PorterNotice notice); factory PorterNotificationSpec.neutral(String connectionId, String noticeId); Map<String, Object?> toJson(); }`
- The content tap is always "open", and is not a button.

- [ ] **Step 1: Write the failing test**

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/porter_wake/porter_wake_notice.dart';
import 'package:wing/porter_wake/porter_wake_presentation.dart';

import 'porter_wake_fixtures.dart';

PorterNotificationSpec spec(String raw) => PorterNotificationSpec.fromNotice(
  'conn-1',
  PorterNotice.fromJson(jsonDecode(raw) as Map<String, dynamic>),
);

void main() {
  test('a trial notice gives Später plus three ratings and an open tap', () {
    final s = spec(porterExampleA);
    expect(s.buttons.map((b) => b.label), ['Später', 'unwichtig', 'so lala', 'sehr wichtig']);
    expect(s.buttons.map((b) => b.feedbackBody), [
      {'action': 'snooze', 'value': 'default'},
      {'action': 'rate', 'value': 'unwichtig'},
      {'action': 'rate', 'value': 'so_lala'},
      {'action': 'rate', 'value': 'sehr_wichtig'},
    ]);
    expect(s.toJson()['tap'], 'open');
  });

  test('a live notice gives only Später and an open tap', () {
    final s = spec(porterExampleB);
    expect(s.buttons.map((b) => b.label), ['Später']);
    expect(s.toJson()['tap'], 'open');
  });

  test('text is the server text: title, line 1, expanded line 1 + line 2', () {
    final a = spec(porterExampleA);
    expect(a.title, '🔴 Birk wartet auf dich');
    expect(a.body, 'Antwort an Galerie Ostwind freigeben?');
    expect(a.expanded, 'Antwort an Galerie Ostwind freigeben?\nJemand wartet auf Antwort');
    final c = spec(porterExampleC);
    expect(c.expanded, 'Probelauf beendet, ab jetzt höchstens 3 am Tag');
  });

  test('the neutral notice has no buttons', () {
    final n = PorterNotificationSpec.neutral('conn-1', 'n-3f2a9c1b7d4e');
    expect(n.title, 'Pforte: neue Nachricht');
    expect(n.buttons, isEmpty);
    expect(n.neutral, isTrue);
    expect(n.toJson()['tap'], 'open');
  });

  test('every spec uses the one porter slot on the attention channel', () {
    final json = spec(porterExampleB).toJson();
    expect(json['id'], 214700);
    expect(json['channel'], 'wing_attention_notifications');
    expect(json['connection'], 'conn-1');
    expect(json['notice_id'], 'n-9e8d7c6b5a41');
    expect(json['open_profile'], 'pforte');
  });
}
```

- [ ] **Step 2: Commit the test, run it, and see it fail**

```bash
git add test/porter_wake/porter_wake_presentation_test.dart
git commit -m "test(porter_wake): notification buttons and neutral notice"
```

Run: `bash tools/factory/ci-suite.sh test/porter_wake/porter_wake_presentation_test.dart`
Expected: `conclusion=failure`.

- [ ] **Step 3: Implement**

```dart
import 'porter_wake_notice.dart';

class PorterButton {
  const PorterButton({required this.action, required this.label, required this.value});
  final String action;
  final String label;
  final String value;

  Map<String, String> get feedbackBody => {'action': action, 'value': value};
  Map<String, String> toJson() => {'action': action, 'label': label, 'value': value};
}

/// What the native renderer posts. „Öffnen“ is the content tap; every other
/// server action becomes a button with the server's label.
class PorterNotificationSpec {
  const PorterNotificationSpec({
    required this.connectionId,
    required this.noticeId,
    required this.title,
    required this.body,
    required this.expanded,
    required this.openProfile,
    required this.buttons,
    this.neutral = false,
  });

  static const notificationId = 214700;
  static const channel = 'wing_attention_notifications';
  static const neutralTitle = 'Pforte: neue Nachricht';

  final String connectionId;
  final String noticeId;
  final String title;
  final String body;
  final String expanded;
  final String openProfile;
  final List<PorterButton> buttons;
  final bool neutral;

  factory PorterNotificationSpec.fromNotice(String connectionId, PorterNotice notice) =>
      PorterNotificationSpec(
        connectionId: connectionId,
        noticeId: notice.noticeId,
        title: notice.title,
        body: notice.lines.isEmpty ? '' : notice.lines.first,
        expanded: notice.lines.take(2).join('\n'),
        openProfile: notice.openProfile,
        buttons: [
          for (final action in notice.actions)
            if (action.id == 'snooze')
              PorterButton(action: 'snooze', label: action.label, value: action.defaultValue ?? 'default')
            else if (action.id == 'rate' && action.value != null)
              PorterButton(action: 'rate', label: action.label, value: action.value!),
        ],
      );

  /// Shown when the fetch fails (contract §6.7). It carries no notice text.
  factory PorterNotificationSpec.neutral(String connectionId, String noticeId) =>
      PorterNotificationSpec(
        connectionId: connectionId,
        noticeId: noticeId,
        title: neutralTitle,
        body: '',
        expanded: '',
        openProfile: 'pforte',
        buttons: const [],
        neutral: true,
      );

  Map<String, Object?> toJson() => {
    'id': notificationId,
    'channel': channel,
    'connection': connectionId,
    'notice_id': noticeId,
    'title': title,
    'body': body,
    'expanded': expanded,
    'open_profile': openProfile,
    'tap': 'open',
    'buttons': [for (final b in buttons) b.toJson()],
    'neutral': neutral,
  };
}
```

- [ ] **Step 4: Run and see it pass**

Run: `bash tools/factory/ci-suite.sh test/porter_wake/porter_wake_presentation_test.dart`
Expected: `conclusion=success`.

- [ ] **Step 5: Commit**

```bash
git add lib/porter_wake/porter_wake_presentation.dart
git commit -m "feat(porter_wake): map notices to the porter notification"
```

---

### Task 6: Bridge contract and push/tap handler

**Files:**
- Create: `lib/porter_wake/porter_wake_bridge.dart`
- Create: `lib/porter_wake/porter_wake_handler.dart`
- Create: `test/porter_wake/fake_porter_bridge.dart`
- Test: `test/porter_wake/porter_wake_bridge_test.dart`
- Test: `test/porter_wake/porter_wake_handler_test.dart`

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces:

```dart
sealed class PorterBridgeEvent { const PorterBridgeEvent(this.connectionId); final String connectionId; }
final class PorterPushEvent extends PorterBridgeEvent { final Uint8List bytes; }
final class PorterEndpointEvent extends PorterBridgeEvent { final String url; }
final class PorterUnregisteredEvent extends PorterBridgeEvent {}
final class PorterRegistrationFailedEvent extends PorterBridgeEvent { final String reason; }
final class PorterInteractionEvent extends PorterBridgeEvent {
  final String noticeId; final String action; final String? value; final String openProfile; final bool neutral;
}
abstract interface class PorterWakeBridge {
  Future<void> start(Future<bool> Function(PorterBridgeEvent event) onEvent, {required bool background});
  Future<bool> register(String connectionId);
  Future<void> unregister(String connectionId);
  Future<void> show(PorterNotificationSpec spec);
  Future<void> cancel();
  Future<String?> deviceLabel();
  Future<void> finished();
}
class MethodChannelPorterWakeBridge implements PorterWakeBridge {
  static const channel = MethodChannel('com.tarkilhk.wing/porter_wake');
}
typedef PorterApiFor = Future<PorterWakeApi?> Function(String connectionId);
typedef PorterOpenProfile = Future<void> Function(String connectionId, String profile);
class PorterWakeHandler {
  PorterWakeHandler({required PorterWakeBridge bridge, required PorterNoticeLedger ledger, required PorterApiFor apiFor, PorterOpenProfile? openProfile});
  Future<void> onPush(String connectionId, List<int> bytes);
  Future<bool> onInteraction(PorterInteractionEvent event);
}
```

**MethodChannel `com.tarkilhk.wing/porter_wake`.** Kotlin implements this exactly in Task 8.

| Direction | Method | Arguments | Result |
|---|---|---|---|
| Dart→Kotlin | `initialize` | `{"role": "main"\|"background"}` | `List<Map>` of queued events (each with `type`). Main gets endpoint/unregistered/failed/interaction; background gets push/interaction |
| Dart→Kotlin | `register` | `String connectionId` | `bool` (a distributor was found) |
| Dart→Kotlin | `unregister` | `String connectionId` | null |
| Dart→Kotlin | `show` | `PorterNotificationSpec.toJson()` | null |
| Dart→Kotlin | `cancel` | none | null |
| Dart→Kotlin | `deviceLabel` | none | `String` (`Build.MODEL`, at most 40 characters) |
| Dart→Kotlin | `finished` | none | null (background: destroys the engine) |
| Kotlin→Dart | `event` | `{"type":"push","connection","bytes":Uint8List}` / `{"type":"endpoint","connection","url"}` / `{"type":"unregistered","connection"}` / `{"type":"failed","connection","reason"}` / `{"type":"interaction","connection","notice_id","action","value"?,"open_profile","neutral"}` | `bool` handled |

- [ ] **Step 1: Fake bridge**

```dart
import 'dart:async';

import 'package:wing/porter_wake/porter_wake_bridge.dart';
import 'package:wing/porter_wake/porter_wake_presentation.dart';

class RecordingPorterWakeBridge implements PorterWakeBridge {
  final shown = <PorterNotificationSpec>[];
  final registered = <String>[];
  final unregistered = <String>[];
  int cancels = 0;
  int finishes = 0;
  bool distributorAvailable = true;
  Future<bool> Function(PorterBridgeEvent)? onEvent;

  Future<bool> emit(PorterBridgeEvent event) => onEvent!(event);

  @override
  Future<void> start(Future<bool> Function(PorterBridgeEvent) onEvent,
      {required bool background}) async => this.onEvent = onEvent;
  @override
  Future<bool> register(String connectionId) async {
    registered.add(connectionId);
    return distributorAvailable;
  }
  @override
  Future<void> unregister(String connectionId) async => unregistered.add(connectionId);
  @override
  Future<void> show(PorterNotificationSpec spec) async => shown.add(spec);
  @override
  Future<void> cancel() async => cancels++;
  @override
  Future<String?> deviceLabel() async => 'Pixel 7';
  @override
  Future<void> finished() async => finishes++;
}
```

- [ ] **Step 2: Write the failing handler test**

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/porter_wake/porter_wake_api.dart';
import 'package:wing/porter_wake/porter_wake_bridge.dart';
import 'package:wing/porter_wake/porter_wake_handler.dart';
import 'package:wing/porter_wake/porter_wake_ledger.dart';

import 'fake_porter_bridge.dart';
import 'porter_wake_fake_server.dart';

List<int> push(String type, int v, String id) =>
    utf8.encode(jsonEncode({'v': v, 'type': type, 'notice_id': id}));

void main() {
  late FakePorterServer server;
  late RecordingPorterWakeBridge bridge;
  late PorterWakeHandler handler;
  final opened = <(String, String)>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    server = FakePorterServer();
    bridge = RecordingPorterWakeBridge();
    opened.clear();
    handler = PorterWakeHandler(
      bridge: bridge,
      ledger: PorterNoticeLedger(await SharedPreferences.getInstance()),
      apiFor: (_) async => PorterWakeApi(server.client()),
      openProfile: (connection, profile) async => opened.add((connection, profile)),
    );
  });

  List<String> noticeFetches() => [
    for (final r in server.porterRequests())
      if (r.method == 'GET' && r.url.path.contains('/notices/')) r.url.path,
  ];

  test('a v1 porter_wake push fetches the notice exactly once', () async {
    await handler.onPush('conn-1', push('porter_wake', 1, 'n-3f2a9c1b7d4e'));
    expect(noticeFetches(), ['${FakePorterServer.base}/notices/n-3f2a9c1b7d4e']);
    expect(bridge.shown.single.title, '🔴 Birk wartet auf dich');
  });

  test('an unknown push type fetches nothing and does not throw', () async {
    await handler.onPush('conn-1', push('other', 1, 'n-3f2a9c1b7d4e'));
    expect(server.requests, isEmpty);
    expect(bridge.shown, isEmpty);
  });

  test('a v2 push fetches nothing and does not throw', () async {
    await handler.onPush('conn-1', push('porter_wake', 2, 'n-3f2a9c1b7d4e'));
    expect(server.requests, isEmpty);
    expect(bridge.shown, isEmpty);
  });

  test('a second push with the same notice id shows nothing and posts nothing', () async {
    await handler.onPush('conn-1', push('porter_wake', 1, 'n-3f2a9c1b7d4e'));
    await handler.onPush('conn-1', push('porter_wake', 1, 'n-3f2a9c1b7d4e'));
    expect(bridge.shown, hasLength(1));
    expect(noticeFetches(), hasLength(1));
    expect(server.porterRequests().where((r) => r.method == 'POST'), isEmpty);
  });

  test('a failed fetch shows the neutral notice with only the open tap', () async {
    for (final status in [404, 500]) {
      bridge.shown.clear();
      server.statusFor['GET ${FakePorterServer.base}/notices/n-9e8d7c6b5a41'] = status;
      await (await SharedPreferences.getInstance()).clear();
      await handler.onPush('conn-1', push('porter_wake', 1, 'n-9e8d7c6b5a41'));
      final shown = bridge.shown.single;
      expect(shown.neutral, isTrue, reason: '$status');
      expect(shown.title, 'Pforte: neue Nachricht');
      expect(shown.buttons, isEmpty);
      expect(shown.title, isNot(contains('n-9e8d7c6b5a41')));
    }
  });

  test('each button posts the exact feedback body', () async {
    for (final (action, value) in [
      ('snooze', 'default'),
      ('rate', 'unwichtig'),
      ('rate', 'so_lala'),
      ('rate', 'sehr_wichtig'),
    ]) {
      expect(
        await handler.onInteraction(PorterInteractionEvent(
          connectionId: 'conn-1', noticeId: 'n-3f2a9c1b7d4e', action: action,
          value: value, openProfile: 'pforte', neutral: false)),
        isTrue,
      );
      final post = server.porterRequests().last;
      expect(post.url.path, '${FakePorterServer.base}/notices/n-3f2a9c1b7d4e/feedback');
      expect(jsonDecode(post.body), {'action': action, 'value': value});
    }
    expect(bridge.cancels, 4);
  });

  test('applied false is a success and dismisses the notification', () async {
    server.bodyFor['POST ${FakePorterServer.base}/notices/n-3f2a9c1b7d4e/feedback'] =
        {'notice_id': 'n-3f2a9c1b7d4e', 'action': 'rate', 'applied': false, 'result': {'rating': 'so_lala'}};
    final ok = await handler.onInteraction(const PorterInteractionEvent(
      connectionId: 'conn-1', noticeId: 'n-3f2a9c1b7d4e', action: 'rate',
      value: 'unwichtig', openProfile: 'pforte', neutral: false));
    expect(ok, isTrue);
    expect(bridge.cancels, 1);
  });

  test('a failed feedback keeps the notification', () async {
    server.statusFor['POST ${FakePorterServer.base}/notices/n-3f2a9c1b7d4e/feedback'] = 500;
    final ok = await handler.onInteraction(const PorterInteractionEvent(
      connectionId: 'conn-1', noticeId: 'n-3f2a9c1b7d4e', action: 'snooze',
      value: 'default', openProfile: 'pforte', neutral: false));
    expect(ok, isFalse);
    expect(bridge.cancels, 0);
  });

  test('open posts {"action":"open"}, dismisses and opens the profile', () async {
    await handler.onInteraction(const PorterInteractionEvent(
      connectionId: 'conn-1', noticeId: 'n-3f2a9c1b7d4e', action: 'open',
      openProfile: 'pforte', neutral: false));
    expect(jsonDecode(server.porterRequests().last.body), {'action': 'open'});
    expect(bridge.cancels, 1);
    expect(opened, [('conn-1', 'pforte')]);
  });

  test('opening the neutral notice retries the fetch first', () async {
    await handler.onInteraction(const PorterInteractionEvent(
      connectionId: 'conn-1', noticeId: 'n-9e8d7c6b5a41', action: 'open',
      openProfile: 'pforte', neutral: true));
    expect(noticeFetches(), ['${FakePorterServer.base}/notices/n-9e8d7c6b5a41']);
    expect(jsonDecode(server.porterRequests().last.body), {'action': 'open'});
    expect(opened, [('conn-1', 'pforte')]);
  });

  test('a push for an unknown connection shows the neutral notice', () async {
    final h = PorterWakeHandler(
      bridge: bridge,
      ledger: PorterNoticeLedger(await SharedPreferences.getInstance()),
      apiFor: (_) async => null,
    );
    await h.onPush('gone', push('porter_wake', 1, 'n-5a4b3c2d1e0f'));
    expect(bridge.shown.single.neutral, isTrue);
  });
}
```

`PorterInteractionEvent` needs a `const` constructor with named parameters `connectionId`, `noticeId`, `action`, `value`, `openProfile` and `neutral`.

- [ ] **Step 3: Write the failing bridge test.** It mocks the channel and checks the method names and arguments from the table:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/porter_wake/porter_wake_bridge.dart';
import 'package:wing/porter_wake/porter_wake_presentation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(MethodChannelPorterWakeBridge.channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'initialize' => [
          {'type': 'endpoint', 'connection': 'c1', 'url': 'http://100.75.24.33:2586/upAbC123xyz?up=1'},
        ],
        'register' => true,
        'deviceLabel' => 'Pixel 7',
        _ => null,
      };
    });
  });

  test('start initializes with the role and replays queued events', () async {
    final events = <PorterBridgeEvent>[];
    await MethodChannelPorterWakeBridge().start((e) async {
      events.add(e);
      return true;
    }, background: false);
    expect(calls.first.method, 'initialize');
    expect(calls.first.arguments, {'role': 'main'});
    expect((events.single as PorterEndpointEvent).url, endsWith('?up=1'));
  });

  test('show sends the spec map; register sends the connection id', () async {
    final bridge = MethodChannelPorterWakeBridge();
    await bridge.show(PorterNotificationSpec.neutral('c1', 'n-3f2a9c1b7d4e'));
    expect(await bridge.register('c1'), isTrue);
    expect(calls[0].method, 'show');
    expect((calls[0].arguments as Map)['id'], 214700);
    expect(calls[1].method, 'register');
    expect(calls[1].arguments, 'c1');
  });

  test('an incoming event of an unknown type is answered false', () async {
    await MethodChannelPorterWakeBridge().start((_) async => true, background: true);
    final reply = await messenger.handlePlatformMessage(
      MethodChannelPorterWakeBridge.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('event', {'type': 'teleport', 'connection': 'c1'})),
      null,
    );
    expect(const StandardMethodCodec().decodeEnvelope(reply!), isFalse);
  });
}
```

- [ ] **Step 4: Commit the tests, run them, and see them fail**

```bash
git add test/porter_wake/fake_porter_bridge.dart test/porter_wake/porter_wake_handler_test.dart test/porter_wake/porter_wake_bridge_test.dart
git commit -m "test(porter_wake): push handling, feedback bodies and bridge contract"
```

Run: `bash tools/factory/ci-suite.sh test/porter_wake/porter_wake_handler_test.dart test/porter_wake/porter_wake_bridge_test.dart`
Expected: `conclusion=failure`.

- [ ] **Step 5: Implement the bridge**

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'porter_wake_presentation.dart';

sealed class PorterBridgeEvent {
  const PorterBridgeEvent(this.connectionId);
  final String connectionId;

  static PorterBridgeEvent? fromMap(Map<Object?, Object?> raw) {
    final connection = raw['connection'];
    if (connection is! String) return null;
    return switch (raw['type']) {
      'push' when raw['bytes'] is Uint8List =>
        PorterPushEvent(connection, raw['bytes'] as Uint8List),
      'endpoint' when raw['url'] is String =>
        PorterEndpointEvent(connection, raw['url'] as String),
      'unregistered' => PorterUnregisteredEvent(connection),
      'failed' => PorterRegistrationFailedEvent(connection, '${raw['reason']}'),
      'interaction' when raw['notice_id'] is String && raw['action'] is String =>
        PorterInteractionEvent(
          connectionId: connection,
          noticeId: raw['notice_id'] as String,
          action: raw['action'] as String,
          value: raw['value'] as String?,
          openProfile: raw['open_profile'] as String? ?? 'pforte',
          neutral: raw['neutral'] == true,
        ),
      _ => null,
    };
  }
}

final class PorterPushEvent extends PorterBridgeEvent {
  const PorterPushEvent(super.connectionId, this.bytes);
  final Uint8List bytes;
}

final class PorterEndpointEvent extends PorterBridgeEvent {
  const PorterEndpointEvent(super.connectionId, this.url);
  final String url;
}

final class PorterUnregisteredEvent extends PorterBridgeEvent {
  const PorterUnregisteredEvent(super.connectionId);
}

final class PorterRegistrationFailedEvent extends PorterBridgeEvent {
  const PorterRegistrationFailedEvent(super.connectionId, this.reason);
  final String reason;
}

final class PorterInteractionEvent extends PorterBridgeEvent {
  const PorterInteractionEvent({
    required String connectionId,
    required this.noticeId,
    required this.action,
    this.value,
    required this.openProfile,
    required this.neutral,
  }) : super(connectionId);
  final String noticeId;
  final String action;
  final String? value;
  final String openProfile;
  final bool neutral;
}

abstract interface class PorterWakeBridge {
  Future<void> start(
    Future<bool> Function(PorterBridgeEvent event) onEvent, {
    required bool background,
  });
  Future<bool> register(String connectionId);
  Future<void> unregister(String connectionId);
  Future<void> show(PorterNotificationSpec spec);
  Future<void> cancel();
  Future<String?> deviceLabel();
  Future<void> finished();
}

class MethodChannelPorterWakeBridge implements PorterWakeBridge {
  static const channel = MethodChannel('com.tarkilhk.wing/porter_wake');

  @override
  Future<void> start(
    Future<bool> Function(PorterBridgeEvent event) onEvent, {
    required bool background,
  }) async {
    Future<bool> dispatch(Object? raw) async {
      final event = raw is Map ? PorterBridgeEvent.fromMap(raw) : null;
      if (event == null) return false;
      try {
        return await onEvent(event);
      } on Object catch (error) {
        debugPrint('porter_wake: event failed (${error.runtimeType})');
        return false;
      }
    }

    channel.setMethodCallHandler((call) async =>
        call.method == 'event' ? dispatch(call.arguments) : null);
    final queued = await channel.invokeListMethod<Object?>(
      'initialize',
      {'role': background ? 'background' : 'main'},
    );
    for (final raw in queued ?? const []) {
      await dispatch(raw);
    }
  }

  @override
  Future<bool> register(String connectionId) async =>
      await channel.invokeMethod<bool>('register', connectionId) ?? false;
  @override
  Future<void> unregister(String connectionId) =>
      channel.invokeMethod<void>('unregister', connectionId);
  @override
  Future<void> show(PorterNotificationSpec spec) =>
      channel.invokeMethod<void>('show', spec.toJson());
  @override
  Future<void> cancel() => channel.invokeMethod<void>('cancel');
  @override
  Future<String?> deviceLabel() => channel.invokeMethod<String>('deviceLabel');
  @override
  Future<void> finished() => channel.invokeMethod<void>('finished');
}
```

- [ ] **Step 6: Implement the handler**

```dart
import 'package:flutter/foundation.dart';

import 'porter_wake_api.dart';
import 'porter_wake_bridge.dart';
import 'porter_wake_ledger.dart';
import 'porter_wake_payload.dart';
import 'porter_wake_presentation.dart';

typedef PorterApiFor = Future<PorterWakeApi?> Function(String connectionId);
typedef PorterOpenProfile = Future<void> Function(String connectionId, String profile);

/// Push → fetch → show, and notification taps → feedback (contract §6).
class PorterWakeHandler {
  PorterWakeHandler({
    required this.bridge,
    required this.ledger,
    required this.apiFor,
    this.openProfile,
  });

  final PorterWakeBridge bridge;
  final PorterNoticeLedger ledger;
  final PorterApiFor apiFor;
  final PorterOpenProfile? openProfile;

  Future<void> onPush(String connectionId, List<int> bytes) async {
    final payload = PorterWakePayload.parse(bytes);
    if (payload == null) {
      debugPrint('porter_wake: ignored a push that is not porter_wake v1');
      return;
    }
    if (!await ledger.claim(payload.noticeId)) return;
    try {
      await bridge.show(await _specFor(connectionId, payload.noticeId));
    } on Object {
      await ledger.release(payload.noticeId);
      rethrow;
    }
  }

  Future<PorterNotificationSpec> _specFor(String connectionId, String noticeId) async {
    try {
      final api = await apiFor(connectionId);
      if (api != null) {
        return PorterNotificationSpec.fromNotice(connectionId, await api.notice(noticeId));
      }
    } on Object catch (error) {
      debugPrint('porter_wake: notice fetch failed (${error.runtimeType})');
    }
    return PorterNotificationSpec.neutral(connectionId, noticeId);
  }

  Future<bool> onInteraction(PorterInteractionEvent event) async {
    final api = await apiFor(event.connectionId);
    if (event.action == 'open') {
      var profile = event.openProfile;
      if (api != null) {
        try {
          if (event.neutral) profile = (await api.notice(event.noticeId)).openProfile;
          await api.feedback(event.noticeId, const {'action': 'open'});
        } on Object catch (error) {
          debugPrint('porter_wake: open feedback failed (${error.runtimeType})');
        }
      }
      await bridge.cancel();
      await openProfile?.call(event.connectionId, profile);
      return true;
    }
    final value = event.value;
    if (api == null || value == null || !const {'rate', 'snooze'}.contains(event.action)) {
      return false;
    }
    try {
      // applied:false is the server's idempotent repeat and counts as success.
      await api.feedback(event.noticeId, {'action': event.action, 'value': value});
    } on Object catch (error) {
      debugPrint('porter_wake: feedback failed (${error.runtimeType})');
      return false;
    }
    await bridge.cancel();
    return true;
  }
}
```

- [ ] **Step 7: Run and see them pass**

Run: `bash tools/factory/ci-suite.sh test/porter_wake/`
Expected: `conclusion=success`.

- [ ] **Step 8: Commit**

```bash
git add lib/porter_wake/porter_wake_bridge.dart lib/porter_wake/porter_wake_handler.dart
git commit -m "feat(porter_wake): handle pushes and notification taps"
```

---

### Task 7: Module: probe gate, registration and revocation

**Files:**
- Create: `lib/porter_wake/porter_wake_module.dart`
- Test: `test/porter_wake/porter_wake_module_test.dart`

**Interfaces:**
- Consumes: `PorterWakeApi`, `PorterProbe` (Task 3); `PorterDeviceIdStore` (Task 4); `PorterWakeBridge`, events, `PorterWakeHandler` (Task 6); `SavedConnection` (`connection_manager.dart`).
- Produces:

```dart
typedef PorterApiFactory = PorterWakeApi Function(SavedConnection connection);
class PorterWakeModule extends ChangeNotifier {
  PorterWakeModule({required PorterWakeBridge bridge, required PorterDeviceIdStore deviceIds,
      required PorterNoticeLedger ledger, PorterApiFactory? apiFactory, PorterOpenProfile? openProfile});
  List<SavedConnection> get activeConnections;   // probe answered 200
  PorterWakeApi? apiFor(String connectionId);
  Future<void> start();                           // bridge.start(_onEvent, background: false)
  Future<void> sync(List<SavedConnection> connections);   // probes new ones, drops vanished ones
  Future<void> refresh(SavedConnection connection);       // after an edit: forget state, re-probe
  Future<void> forget(SavedConnection connection);        // before deletion: DELETE device + unregister
}
```

Revocation (contract §5.1.6, mapped to the real code):

| Trigger | Wing action |
|---|---|
| Connection deleted (`main.dart:1376`) | `forget`: `DELETE /push/devices/{id}` (best effort, 5 s timeout), then `bridge.unregister(conn.id)` |
| Distributor `onUnregistered` | `DELETE /push/devices/{id}` on that connection |
| Probe 404/503 ("module switched off" on the server) | `bridge.unregister` only. **No DELETE:** contract §2.2 forbids every other porter route, and the routes are gone anyway |
| Dashboard credentials edited (`updateConnection`, `main.dart:1284`) | `refresh`: re-probe, register again, and the server replaces the endpoint (`replaced: true`) |
| Logout | Wing has no logout (verified), so there is nothing to wire |
| `onRegistrationFailed` | Log `porter_wake: registration failed`; no POST |

- [ ] **Step 1: Write the failing test**

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/porter_wake/porter_wake_api.dart';
import 'package:wing/porter_wake/porter_wake_bridge.dart';
import 'package:wing/porter_wake/porter_wake_device_id.dart';
import 'package:wing/porter_wake/porter_wake_ledger.dart';
import 'package:wing/porter_wake/porter_wake_module.dart';

import 'fake_porter_bridge.dart';
import 'porter_wake_device_id_test.dart' show MemoryCredentialStore;
import 'porter_wake_fake_server.dart';

SavedConnection conn(String id) => SavedConnection(
  id: id, label: 'Home', host: 'hermes.test', port: 8642, apiKey: '');

void main() {
  late FakePorterServer server;
  late RecordingPorterWakeBridge bridge;
  late PorterWakeModule module;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    server = FakePorterServer();
    bridge = RecordingPorterWakeBridge();
    module = PorterWakeModule(
      bridge: bridge,
      deviceIds: PorterDeviceIdStore(store: MemoryCredentialStore()),
      ledger: PorterNoticeLedger(await SharedPreferences.getInstance()),
      apiFactory: (_) => PorterWakeApi(server.client()),
    );
    await module.start();
  });

  test('a 200 probe activates the connection and registers its instance', () async {
    await module.sync([conn('c1')]);
    expect(module.activeConnections.map((c) => c.id), ['c1']);
    expect(bridge.registered, ['c1']);
  });

  test('a 404 probe registers nothing and calls no other porter route', () async {
    server.statusFor['GET ${FakePorterServer.base}/settings/quiet-hours'] = 404;
    await module.sync([conn('c1')]);
    await module.sync([conn('c1')]);
    expect(module.activeConnections, isEmpty);
    expect(bridge.registered, isEmpty);
    expect(bridge.unregistered, ['c1']);
    expect(server.porterRequests().map((r) => '${r.method} ${r.url.path}'),
        ['GET ${FakePorterServer.base}/settings/quiet-hours']);
  });

  test('a 503 probe is treated like 404', () async {
    server.statusFor['GET ${FakePorterServer.base}/settings/quiet-hours'] = 503;
    await module.sync([conn('c1')]);
    expect(bridge.registered, isEmpty);
    expect(module.activeConnections, isEmpty);
  });

  test('a network failure leaves the connection unprobed for a later retry', () async {
    server.statusFor['GET ${FakePorterServer.base}/settings/quiet-hours'] = 500;
    await module.sync([conn('c1')]);
    expect(bridge.registered, isEmpty);
    server.statusFor.clear();
    await module.sync([conn('c1')]);
    expect(bridge.registered, ['c1']);
  });

  test('a new endpoint is posted with the stable device id and label', () async {
    await module.sync([conn('c1')]);
    await bridge.emit(const PorterEndpointEvent('c1', 'http://100.75.24.33:2586/upAbC123xyz?up=1'));
    await bridge.emit(const PorterEndpointEvent('c1', 'http://100.75.24.33:2586/upZZZ999zzz?up=1'));
    final posts = server.porterRequests().where((r) => r.method == 'POST').toList();
    expect(posts, hasLength(2));
    final first = jsonDecode(posts[0].body) as Map;
    final second = jsonDecode(posts[1].body) as Map;
    expect(first['device_id'], second['device_id']);
    expect(first['label'], 'Pixel 7');
    expect(second['endpoint'], 'http://100.75.24.33:2586/upZZZ999zzz?up=1');
  });

  test('an endpoint for an inactive connection is ignored', () async {
    await bridge.emit(const PorterEndpointEvent('c9', 'http://100.75.24.33:2586/upAbC123xyz?up=1'));
    expect(server.porterRequests(), isEmpty);
  });

  test('forget deletes the device and unregisters', () async {
    await module.sync([conn('c1')]);
    await module.forget(conn('c1'));
    final delete = server.porterRequests().last;
    expect(delete.method, 'DELETE');
    expect(delete.url.path, startsWith('${FakePorterServer.base}/push/devices/wing-'));
    expect(bridge.unregistered, ['c1']);
    expect(module.activeConnections, isEmpty);
  });

  test('distributor unregistration deletes the device on the server', () async {
    await module.sync([conn('c1')]);
    await bridge.emit(const PorterUnregisteredEvent('c1'));
    expect(server.porterRequests().last.method, 'DELETE');
  });

  test('refresh re-probes and registers again', () async {
    await module.sync([conn('c1')]);
    await module.refresh(conn('c1'));
    expect(bridge.registered, ['c1', 'c1']);
  });

  test('a vanished connection is dropped from the active set', () async {
    await module.sync([conn('c1')]);
    await module.sync([]);
    expect(module.activeConnections, isEmpty);
  });
}
```

- [ ] **Step 2: Commit the test, run it, and see it fail**

```bash
git add test/porter_wake/porter_wake_module_test.dart
git commit -m "test(porter_wake): probe gate, registration and revocation"
```

Run: `bash tools/factory/ci-suite.sh test/porter_wake/porter_wake_module_test.dart`
Expected: `conclusion=failure`.

- [ ] **Step 3: Implement**

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/services/connection_manager.dart';
import 'porter_wake_api.dart';
import 'porter_wake_bridge.dart';
import 'porter_wake_dashboard.dart';
import 'porter_wake_device_id.dart';
import 'porter_wake_handler.dart';
import 'porter_wake_ledger.dart';

typedef PorterApiFactory = PorterWakeApi Function(SavedConnection connection);

/// The optional porter wake module. A connection is active only after the
/// quiet-hours probe answered 200; 404/503 keep it inert for this session.
class PorterWakeModule extends ChangeNotifier {
  PorterWakeModule({
    required this.bridge,
    required this.deviceIds,
    required PorterNoticeLedger ledger,
    PorterApiFactory? apiFactory,
    PorterOpenProfile? openProfile,
  }) : _apiFactory = apiFactory ?? ((c) => PorterWakeApi(porterDashboardFor(c))) {
    handler = PorterWakeHandler(
      bridge: bridge,
      ledger: ledger,
      apiFor: (id) async => _active[id]?.api,
      openProfile: openProfile,
    );
  }

  final PorterWakeBridge bridge;
  final PorterDeviceIdStore deviceIds;
  final PorterApiFactory _apiFactory;
  late final PorterWakeHandler handler;
  final _active = <String, ({SavedConnection connection, PorterWakeApi api})>{};
  final _inert = <String>{};
  final _probing = <String>{};

  List<SavedConnection> get activeConnections =>
      [for (final entry in _active.values) entry.connection];

  PorterWakeApi? apiFor(String connectionId) => _active[connectionId]?.api;

  Future<void> start() => bridge.start(_onEvent, background: false);

  Future<void> sync(List<SavedConnection> connections) async {
    final ids = {for (final c in connections) c.id};
    final vanished = _active.keys.where((id) => !ids.contains(id)).toList();
    for (final id in vanished) {
      _active.remove(id)?.api.close();
    }
    if (vanished.isNotEmpty) notifyListeners();
    await Future.wait([
      for (final c in connections)
        if (!_active.containsKey(c.id) && !_inert.contains(c.id) && _probing.add(c.id))
          _probe(c).whenComplete(() => _probing.remove(c.id)),
    ]);
  }

  Future<void> _probe(SavedConnection connection) async {
    final api = _apiFactory(connection);
    switch (await api.probe()) {
      case PorterProbe.active:
        _active[connection.id] = (connection: connection, api: api);
        notifyListeners();
        if (!await bridge.register(connection.id)) {
          debugPrint('porter_wake: no UnifiedPush distributor installed');
        }
      case PorterProbe.absent:
        api.close();
        _inert.add(connection.id);
        await bridge.unregister(connection.id);
      case PorterProbe.unknown:
        api.close();
    }
  }

  Future<void> refresh(SavedConnection connection) async {
    _active.remove(connection.id)?.api.close();
    _inert.remove(connection.id);
    notifyListeners();
    await sync([...activeConnections, connection]);
  }

  Future<void> forget(SavedConnection connection) async {
    final entry = _active.remove(connection.id);
    _inert.remove(connection.id);
    if (entry == null) return;
    notifyListeners();
    try {
      await entry.api
          .removeDevice(await deviceIds.read())
          .timeout(const Duration(seconds: 5));
    } on Object catch (error) {
      debugPrint('porter_wake: device removal failed (${error.runtimeType})');
    }
    await bridge.unregister(connection.id);
    entry.api.close();
  }

  Future<bool> _onEvent(PorterBridgeEvent event) async {
    final api = _active[event.connectionId]?.api;
    switch (event) {
      case PorterPushEvent(:final bytes):
        await handler.onPush(event.connectionId, bytes);
        return true;
      case PorterInteractionEvent():
        return handler.onInteraction(event);
      case PorterEndpointEvent(:final url):
        if (api == null) return false;
        await api.registerDevice(
          deviceId: await deviceIds.read(),
          endpoint: url,
          label: await bridge.deviceLabel(),
        );
        return true;
      case PorterUnregisteredEvent():
        if (api == null) return false;
        await api.removeDevice(await deviceIds.read());
        return true;
      case PorterRegistrationFailedEvent():
        debugPrint('porter_wake: registration failed');
        return true;
    }
  }
}
```

- [ ] **Step 4: Run and see it pass**

Run: `bash tools/factory/ci-suite.sh test/porter_wake/`
Expected: `conclusion=success`.

- [ ] **Step 5: Commit**

```bash
git add lib/porter_wake/porter_wake_module.dart
git commit -m "feat(porter_wake): probe-gated registration and revocation"
```

---

### Task 8: Android: connector, push service, headless engine, renderer and taps

**Files:**
- Modify: `android/app/build.gradle.kts` (the `dependencies {` block, `:248`)
- Modify: `android/app/src/main/AndroidManifest.xml` (after `NotificationActionActivity`, `:22-23`)
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/MainActivity.kt` (`configureFlutterEngine` `:71-74`; `onResume` `:300`; `onNewIntent` `:328`)
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/MonitoringRuntime.kt:127`
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/ChatNotifications.kt:137` (`private fun createChannels` becomes `fun createChannels`)
- Create: `android/app/src/main/kotlin/com/tarkilhk/wing/porterwake/PorterPushService.kt`
- Create: `android/app/src/main/kotlin/com/tarkilhk/wing/porterwake/PorterWakeNative.kt`
- Create: `android/app/src/main/kotlin/com/tarkilhk/wing/porterwake/PorterHeadless.kt`
- Create: `android/app/src/main/kotlin/com/tarkilhk/wing/porterwake/PorterNotifications.kt`
- Create: `android/app/src/main/kotlin/com/tarkilhk/wing/porterwake/PorterActionActivity.kt`
- Create: `android/app/src/main/res/layout/notification_porter_row.xml`
- Create: `android/app/src/main/res/layout/notification_porter_grid.xml`
- Create: `lib/porter_wake/porter_wake_background.dart`

**Interfaces:**
- Consumes: the MethodChannel table of Task 6, and `PorterNotificationSpec.toJson()` keys.
- Produces: `@pragma('vm:entry-point') Future<void> porterWakeBackgroundMain()` and the Kotlin side of the channel.

There are no Kotlin unit tests in this repo (no `android/app/src/test`). The checks here are the Dart channel contract test (Task 6) plus a full release compile. Behaviour is checked on the device in Task 13.

- [ ] **Step 1: Resolve ANNAHME C1/C2.** Read the connector's latest release and KDoc as described in "Connector choice". Record the exact version and any API name differences as a short note at the top of `PorterPushService.kt`, as a code comment naming the version. If C2 fails, stop and ask Birk.

- [ ] **Step 2: Gradle and manifest.** In `android/app/build.gradle.kts`, inside `dependencies {`, add:

```kotlin
    implementation("org.unifiedpush.android:connector:3.0.10") // ANNAHME C1: replace with the verified latest 3.x
```

In `AndroidManifest.xml`, after the `NotificationActionActivity` element, add:

```xml
        <service android:name=".porterwake.PorterPushService" android:exported="false">
            <intent-filter>
                <action android:name="org.unifiedpush.android.connector.PUSH_EVENT" />
            </intent-filter>
        </service>
        <activity android:name=".porterwake.PorterActionActivity" android:exported="false"
            android:excludeFromRecents="true" android:theme="@style/NotificationActionTheme" />
```

- [ ] **Step 3: `PorterPushService.kt`**

```kotlin
package com.tarkilhk.wing.porterwake

import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage

/** UnifiedPush callbacks. The instance is the Wing connection id. */
class PorterPushService : PushService() {
    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) =
        PorterWakeNative.queueForMain(this, mapOf("type" to "endpoint", "connection" to instance, "url" to endpoint.url))

    // Plain JSON from the gate arrives with decrypted == false (ANNAHME C2).
    override fun onMessage(message: PushMessage, instance: String) =
        PorterWakeNative.deliverPush(this, instance, message.content)

    override fun onRegistrationFailed(reason: FailedReason, instance: String) =
        PorterWakeNative.queueForMain(this, mapOf("type" to "failed", "connection" to instance, "reason" to reason.name))

    override fun onUnregistered(instance: String) =
        PorterWakeNative.queueForMain(this, mapOf("type" to "unregistered", "connection" to instance))
}
```

- [ ] **Step 4: `PorterWakeNative.kt`**

```kotlin
package com.tarkilhk.wing.porterwake

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import org.unifiedpush.android.connector.UnifiedPush
import java.lang.ref.WeakReference

/** Native side of com.tarkilhk.wing/porter_wake for the app engine and the headless engine. */
object PorterWakeNative {
    const val channelName = "com.tarkilhk.wing/porter_wake"
    const val extra = "porter_wake_interaction"
    private val main = Handler(Looper.getMainLooper())
    private var mainEngine: FlutterEngine? = null
    private var mainChannel: MethodChannel? = null
    private var mainReady = false
    private var activity = WeakReference<Activity>(null)
    private var headless: PorterHeadless? = null
    private val headlessQueue = mutableListOf<Map<String, Any?>>()
    private val pendingInteractions = mutableListOf<Map<String, Any?>>()
    private fun prefs(context: Context) =
        context.getSharedPreferences("porter_wake_native", Context.MODE_PRIVATE)

    fun attach(source: Activity, engine: FlutterEngine) {
        activity = WeakReference(source)
        if (mainEngine === engine) return
        mainEngine = engine
        mainReady = false
        mainChannel = channel(source.applicationContext, engine, background = false)
    }

    fun detach() {
        mainChannel?.setMethodCallHandler(null)
        mainChannel = null
        mainEngine = null
        mainReady = false
    }

    internal fun channel(context: Context, engine: FlutterEngine, background: Boolean): MethodChannel =
        MethodChannel(engine.dartExecutor.binaryMessenger, channelName).apply {
            setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "initialize" -> {
                            if (background) {
                                result.success(headlessQueue.toList().also { headlessQueue.clear() })
                            } else {
                                mainReady = true
                                result.success(drainMain(context) + pendingInteractions.toList().also { pendingInteractions.clear() })
                            }
                        }
                        "register" -> register(context, call.arguments as String) { result.success(it) }
                        "unregister" -> { UnifiedPush.unregister(context, call.arguments as String); result.success(null) }
                        "show" -> { PorterNotifications.show(context, call.arguments as Map<*, *>); result.success(null) }
                        "cancel" -> { PorterNotifications.cancel(context); result.success(null) }
                        "deviceLabel" -> result.success(Build.MODEL.take(40))
                        "finished" -> { result.success(null); if (background) main.post { finishHeadless() } }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    result.error("porter_wake_failed", "Porter wake operation failed", null)
                }
            }
        }

    private fun register(context: Context, instance: String, done: (Boolean) -> Unit) {
        // ANNAHME C1: may require an Activity context to show the distributor chooser.
        val owner = activity.get() ?: context
        UnifiedPush.tryUseCurrentOrDefaultDistributor(owner) { success ->
            if (success) UnifiedPush.register(context, instance)
            main.post { done(success) }
        }
    }

    /** Registration events belong to the app engine; persist them across process death. */
    fun queueForMain(context: Context, event: Map<String, Any?>) = main.post {
        val channel = mainChannel
        if (mainReady && channel != null) { channel.invokeMethod("event", event); return@post }
        val queue = JSONArray(prefs(context).getString("pending", "[]"))
        queue.put(JSONObject(event))
        prefs(context).edit().putString("pending", queue.toString()).commit()
    }

    private fun drainMain(context: Context): List<Map<String, Any?>> {
        val queue = JSONArray(prefs(context).getString("pending", "[]"))
        prefs(context).edit().remove("pending").commit()
        return (0 until queue.length()).map { asMap(queue.getJSONObject(it)) }
    }

    /** JSONObject.NULL is not encodable by the method codec. */
    internal fun asMap(value: JSONObject): Map<String, Any?> = value.keys().asSequence().associateWith {
        val item = value.get(it)
        if (item == JSONObject.NULL) null else item
    }

    fun deliverPush(context: Context, instance: String, bytes: ByteArray) = main.post {
        val event = mapOf("type" to "push", "connection" to instance, "bytes" to bytes)
        val channel = mainChannel
        if (mainReady && channel != null) channel.invokeMethod("event", event)
        else runHeadless(context, event, null)
    }

    /** From PorterActionActivity: rate/snooze stay in the background; open goes to the app. */
    fun interact(context: Context, event: Map<String, Any?>, completed: () -> Unit) {
        val channel = mainChannel
        if (mainReady && channel != null) {
            channel.invokeMethod("event", event, object : MethodChannel.Result {
                override fun success(result: Any?) = completed()
                override fun error(code: String, message: String?, details: Any?) = completed()
                override fun notImplemented() = completed()
            })
        } else runHeadless(context, event, completed)
    }

    fun handleMainIntent(context: Context, intent: Intent?) {
        val raw = intent?.getStringExtra(extra) ?: return
        intent.removeExtra(extra)
        val event = asMap(JSONObject(raw))
        val channel = mainChannel
        if (mainReady && channel != null) channel.invokeMethod("event", event)
        else pendingInteractions.add(event)
    }

    private fun runHeadless(context: Context, event: Map<String, Any?>, completed: (() -> Unit)?) {
        headlessQueue.add(event)
        val current = headless
        if (current != null) { completed?.let(current::onFinished); return }
        headless = PorterHeadless(context.applicationContext, channelFactory = { engine ->
            channel(context.applicationContext, engine, background = true)
        }).also { started -> completed?.let(started::onFinished) }
    }

    private fun finishHeadless() {
        headless?.destroy()
        headless = null
    }

    internal fun headlessTimedOut() = finishHeadless()
}
```

- [ ] **Step 5: `PorterHeadless.kt`**

```kotlin
package com.tarkilhk.wing.porterwake

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** A short-lived engine that runs porterWakeBackgroundMain while Wing is not running. */
class PorterHeadless(context: Context, channelFactory: (FlutterEngine) -> MethodChannel) {
    private val engine = FlutterEngine(context)
    private val channel: MethodChannel
    private val finished = mutableListOf<() -> Unit>()
    private val timeout = Runnable { PorterWakeNative.headlessTimedOut() }
    private val handler = Handler(Looper.getMainLooper())
    private val wake = context.getSystemService(PowerManager::class.java)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "wing:porter_wake")
        .apply { setReferenceCounted(false); acquire(30_000) }

    init {
        channel = channelFactory(engine)
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(context)
        loader.ensureInitializationComplete(context, null)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "package:wing/porter_wake/porter_wake_background.dart",
                "porterWakeBackgroundMain",
            ),
        )
        handler.postDelayed(timeout, 30_000)
    }

    fun onFinished(callback: () -> Unit) { finished.add(callback) }

    fun destroy() {
        handler.removeCallbacks(timeout)
        channel.setMethodCallHandler(null)
        engine.destroy()
        if (wake.isHeld) wake.release()
        finished.toList().also { finished.clear() }.forEach { it() }
    }
}
```

- [ ] **Step 6: `PorterNotifications.kt` and the layouts.** The renderer posts on the attention channel with fixed id 214700, using `PorterActionActivity` PendingIntents. Up to 3 buttons use standard actions plus BigTextStyle (contract §6.2). Four buttons use custom RemoteViews like the approval precedent (`ChatNotifications.kt:196-213`): the grid layout above font scale 1.3, otherwise the row layout.

```kotlin
package com.tarkilhk.wing.porterwake

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.tarkilhk.wing.ChatNotifications
import com.tarkilhk.wing.R
import org.json.JSONObject

object PorterNotifications {
    private const val id = 214700
    private val buttonIds by lazy { listOf(R.id.porter_b0, R.id.porter_b1, R.id.porter_b2, R.id.porter_b3) }

    fun cancel(context: Context) = context.getSystemService(NotificationManager::class.java).cancel(id)

    private fun intent(context: Context, data: Map<*, *>, action: String, value: String?): PendingIntent {
        val event = JSONObject()
            .put("type", "interaction").put("connection", data["connection"]).put("notice_id", data["notice_id"])
            .put("action", action).put("value", value).put("open_profile", data["open_profile"])
            .put("neutral", data["neutral"] == true)
        val identity = Uri.Builder().scheme("wing-porter").authority("action")
            .appendPath(data["notice_id"].toString()).appendPath(action).appendPath(value ?: "").build()
        val target = Intent(context, PorterActionActivity::class.java).setData(identity)
            .putExtra(PorterWakeNative.extra, event.toString())
        return PendingIntent.getActivity(context, 0, target, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    fun show(context: Context, data: Map<*, *>) {
        ChatNotifications.createChannels(context)
        val title = data["title"] as String
        val body = data["body"] as String
        val expanded = data["expanded"] as String
        val buttons = (data["buttons"] as List<*>).map { it as Map<*, *> }
        val builder = NotificationCompat.Builder(context, data["channel"] as String)
            .setSmallIcon(R.drawable.ic_stat_wing_input).setContentTitle(title)
            .setContentText(body).setAutoCancel(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(NotificationCompat.Builder(context, data["channel"] as String)
                .setSmallIcon(R.drawable.ic_stat_wing_input).setContentTitle("Wing").build())
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setContentIntent(intent(context, data, "open", null))
        if (buttons.size > 3) {
            val large = context.resources.configuration.fontScale > 1.3f
            val views = RemoteViews(context.packageName,
                if (large) R.layout.notification_porter_grid else R.layout.notification_porter_row)
            views.setTextViewText(R.id.porter_title, title)
            views.setTextViewText(R.id.porter_text, expanded)
            buttonIds.forEachIndexed { index, viewId ->
                val button = buttons.getOrNull(index)
                views.setViewVisibility(viewId, if (button == null) View.GONE else View.VISIBLE)
                if (button != null) {
                    views.setTextViewText(viewId, button["label"] as String)
                    views.setOnClickPendingIntent(viewId,
                        intent(context, data, button["action"] as String, button["value"] as String))
                }
            }
            builder.setStyle(NotificationCompat.DecoratedCustomViewStyle()).setCustomBigContentView(views)
        } else {
            if (expanded.isNotEmpty()) builder.setStyle(NotificationCompat.BigTextStyle().bigText(expanded))
            for (button in buttons) {
                builder.addAction(0, button["label"] as String,
                    intent(context, data, button["action"] as String, button["value"] as String))
            }
        }
        NotificationManagerCompat.from(context).notify(id, builder.build())
    }
}
```

`notification_porter_row.xml` follows the approval row precedent (`notification_approval_row.xml`). The button labels come from the server at runtime:

```xml
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android" android:layout_width="match_parent" android:layout_height="wrap_content" android:orientation="vertical">
 <TextView android:layout_width="match_parent" android:layout_height="wrap_content" android:id="@+id/porter_title" android:maxLines="1" android:ellipsize="end" android:textSize="16sp" android:textStyle="bold" android:textColor="@color/notification_ink" />
 <TextView android:layout_width="match_parent" android:layout_height="wrap_content" android:id="@+id/porter_text" android:maxLines="2" android:ellipsize="end" android:textSize="14sp" android:textColor="@color/notification_ink" android:paddingTop="4dp" android:paddingBottom="8dp" />
 <LinearLayout android:layout_width="match_parent" android:layout_height="48dp" android:orientation="horizontal" android:baselineAligned="false">
  <Button android:id="@+id/porter_b0" android:layout_width="0dp" android:layout_weight="1" android:layout_height="match_parent" android:gravity="center" android:textSize="14sp" android:textColor="@color/notification_action" android:background="?android:attr/selectableItemBackground" android:textAllCaps="false" android:padding="0dp" android:minWidth="0dp" android:minHeight="0dp" android:maxLines="1" android:ellipsize="end" />
  <Button android:id="@+id/porter_b1" android:layout_width="0dp" android:layout_weight="1" android:layout_height="match_parent" android:gravity="center" android:textSize="14sp" android:textColor="@color/notification_action" android:background="?android:attr/selectableItemBackground" android:textAllCaps="false" android:padding="0dp" android:minWidth="0dp" android:minHeight="0dp" android:maxLines="1" android:ellipsize="end" />
  <Button android:id="@+id/porter_b2" android:layout_width="0dp" android:layout_weight="1" android:layout_height="match_parent" android:gravity="center" android:textSize="14sp" android:textColor="@color/notification_action" android:background="?android:attr/selectableItemBackground" android:textAllCaps="false" android:padding="0dp" android:minWidth="0dp" android:minHeight="0dp" android:maxLines="1" android:ellipsize="end" />
  <Button android:id="@+id/porter_b3" android:layout_width="0dp" android:layout_weight="1.2" android:layout_height="match_parent" android:gravity="center" android:textSize="14sp" android:textColor="@color/notification_action" android:background="?android:attr/selectableItemBackground" android:textAllCaps="false" android:padding="0dp" android:minWidth="0dp" android:minHeight="0dp" android:maxLines="1" android:ellipsize="end" />
 </LinearLayout>
</LinearLayout>
```

`notification_porter_grid.xml` has the same two `TextView`s, followed by two 48 dp rows. Row 1 holds `porter_b0` and `porter_b1`; row 2 holds `porter_b2` and `porter_b3`. Every button has `layout_weight="1"` and otherwise the attributes above, with `android:maxLines="2"` so labels can wrap at large font scales.

> **ANNAHME N1:** `R.drawable.ic_stat_wing_input` (`ChatNotifications.kt:180`) is a fitting small icon for "needs attention". **Check** with Birk in the screenshot review.

- [ ] **Step 7: `PorterActionActivity.kt`** (keyguard handling copied from `NotificationActionActivity`)

```kotlin
package com.tarkilhk.wing.porterwake

import android.app.Activity
import android.app.KeyguardManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import com.tarkilhk.wing.MainActivity
import org.json.JSONObject

/** Handles porter notification taps; rate/snooze never open the app. */
class PorterActionActivity : Activity() {
    private var sent = false
    private var resumed = false

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        if (Build.VERSION.SDK_INT >= 27) setShowWhenLocked(true)
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (keyguard.isKeyguardLocked && Build.VERSION.SDK_INT >= 26) {
            keyguard.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() { deliver() }
                override fun onDismissCancelled() { finish() }
                override fun onDismissError() { finish() }
            })
        } else if (keyguard.isKeyguardLocked) openMain()
    }

    override fun onResume() { super.onResume(); resumed = true; deliver() }
    override fun onPause() { resumed = false; super.onPause() }

    private fun deliver() {
        if (!resumed || sent || getSystemService(KeyguardManager::class.java).isKeyguardLocked) return
        sent = true
        val raw = intent.getStringExtra(PorterWakeNative.extra) ?: return finish()
        val value = JSONObject(raw)
        if (value.optString("action") == "open") return openMain()
        val event = PorterWakeNative.asMap(value)
        // Stay resumed until Dart replied: a resumed activity keeps network access.
        PorterWakeNative.interact(this, event) { runOnUiThread { finish() } }
    }

    private fun openMain() {
        startActivity(Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(PorterWakeNative.extra, intent.getStringExtra(PorterWakeNative.extra)))
        finish()
    }
}
```

- [ ] **Step 8: Core hooks**
  - `MainActivity.configureFlutterEngine`: add `PorterWakeNative.attach(this, flutterEngine)` after `MonitoringRuntime.attach(this, flutterEngine)` (`:74`).
  - `MainActivity.onResume` and `onNewIntent`: add `PorterWakeNative.handleMainIntent(this, intent)` after `ChatNotifications.handleMainIntent(this, intent)` (`:300` and `:328`).
  - `MonitoringRuntime.releaseIfUnused`: add `com.tarkilhk.wing.porterwake.PorterWakeNative.detach()` after `ChatNotifications.detach()` (`:127`).
  - `ChatNotifications.kt:137`: drop `private` from `createChannels`.

- [ ] **Step 9: Background Dart entry point** (`lib/porter_wake/porter_wake_background.dart`)

```dart
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/connection_manager.dart';
import 'porter_wake_api.dart';
import 'porter_wake_bridge.dart';
import 'porter_wake_dashboard.dart';
import 'porter_wake_handler.dart';
import 'porter_wake_ledger.dart';

/// Runs in a headless engine started by PorterHeadless while Wing is not
/// running: handles queued pushes and taps, then lets the engine go.
@pragma('vm:entry-point')
Future<void> porterWakeBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final bridge = MethodChannelPorterWakeBridge();
  try {
    final prefs = await SharedPreferences.getInstance();
    final connections = await ConnectionManager.create(prefs);
    final handler = PorterWakeHandler(
      bridge: bridge,
      ledger: PorterNoticeLedger(prefs),
      apiFor: (id) async {
        final connection = (await connections.loadConnectionsWithSecrets())
            .where((c) => c.id == id)
            .firstOrNull;
        return connection == null ? null : PorterWakeApi(porterDashboardFor(connection));
      },
    );
    await bridge.start((event) async {
      switch (event) {
        case PorterPushEvent(:final bytes):
          await handler.onPush(event.connectionId, bytes);
          return true;
        case PorterInteractionEvent():
          return handler.onInteraction(event);
        default:
          return false;
      }
    }, background: true);
  } on Object catch (error) {
    debugPrint('porter_wake: background run failed (${error.runtimeType})');
  } finally {
    await bridge.finished();
  }
}
```

> **ANNAHME B3:** `ConnectionManager.create(prefs)` (`connection_manager.dart:285`) has no side effects that need the UI (it runs a migration in `initialize`, `:299`). **Check** that `initialize` does no navigation and asks for no permission. If it does, use `ConnectionManager(prefs)` plus `loadConnectionsWithSecrets()` only.

- [ ] **Step 10: Compile, then run the Dart suite.** Commit first, because both scripts test HEAD:

```bash
git add android/app/build.gradle.kts android/app/src/main/AndroidManifest.xml android/app/src/main/kotlin/com/tarkilhk/wing/MainActivity.kt android/app/src/main/kotlin/com/tarkilhk/wing/MonitoringRuntime.kt android/app/src/main/kotlin/com/tarkilhk/wing/ChatNotifications.kt android/app/src/main/kotlin/com/tarkilhk/wing/porterwake android/app/src/main/res/layout/notification_porter_row.xml android/app/src/main/res/layout/notification_porter_grid.xml lib/porter_wake/porter_wake_background.dart
git commit -m "feat(porter_wake): UnifiedPush service, headless delivery and native notification"
```

Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: `dispatch-check: voice-apk.yml run <id> conclusion=success`. On failure, the `annotation:` lines show the Kotlin errors; fix them and commit again.

Run: `bash tools/factory/ci-suite.sh test/porter_wake/ test/app_notification_routing_test.dart test/notification_action_background_test.dart`
Expected: `conclusion=success` (analyze covers the new entry point; the notification tests still pass).

---

### Task 9: „Nachtruhe“ settings block

**Design (AGENTS.md "Design before implementation")**
- **Task:** check or change when Pforte stays silent. **Primary action:** the „Nachtruhe“ switch. **Editable:** switch, „von“, „bis“. **Passive:** the server timezone. **Temporary:** saving and error.
- **Arrangement A (chosen):** rows inside the existing Notifications card, after "Show message previews", separated by a `Divider`.
  - Row 1: `CompactSwitchListTile` „Nachtruhe“, with the timezone as muted subtitle.
  - Rows 2–3: `ListTile` „von“ / „bis“, each with the time as trailing text, tap opens `showTimePicker`.
  - It adds no header; quiet hours are a notification behaviour, and A costs three rows.
- **Arrangement B (rejected):** its own `_SettingsSection(title: 'Nachtruhe')` containing a switch also called „Nachtruhe“. That repeats the label, adds a header and card, and puts more weight on a rarely changed setting.
- **Saving feedback:**
  - While a PUT is pending, all three controls are disabled (`DESIGN_SYSTEM.md:227`) and show the pending value.
  - On success, the value becomes the 200 body, with no success text.
  - On error, the last server state is restored and a `StudioError` appears under the rows with the server's `error` text.
- **Copy:** labels „Nachtruhe“, „von“, „bis“ (contract-named). Error fallback, in English: `Could not reach the server. Nachtruhe is unchanged.`
- **Time picker:** `showTimePicker(context: context, initialTime: …, helpText: 'Time in Hermes’ timezone')`, following the precedent at `admin_scheduled_task_editor_page.dart:640`. It uses a 24 h `MediaQuery` override (`alwaysUse24HourFormat: true`), because the server format is `HH:MM`.

**Files:**
- Create: `lib/porter_wake/porter_wake_settings.dart`
- Modify: `lib/core/screens/app_settings_content.dart`: constructor (`:23-31`) adds `this.notificationExtras = const []`; field `final List<Widget> notificationExtras;`; inside the Notifications card's `Column`, after the "Show message previews" tile (ends about `:268`), add `for (final extra in widget.notificationExtras) ...[const Divider(height: 1), extra],`
- Modify: `.github/workflows/voice-review.yml` (append `test/porter_wake/porter_wake_settings_test.dart` to the render list)
- Test: `test/porter_wake/porter_wake_settings_test.dart`

**Interfaces:**
- Consumes: `PorterWakeModule.activeConnections`, `apiFor` (Task 7); `PorterQuietHours`, `PorterApiError` (Task 3).
- Produces:
  - `class PorterWakeSettings extends StatelessWidget { const PorterWakeSettings({super.key, required this.module}); }`. It renders `SizedBox.shrink()` while no connection is active, and one `QuietHoursPanel` per active connection (with a connection-label subtitle only when there is more than one).
  - `class QuietHoursPanel extends StatefulWidget { const QuietHoursPanel({super.key, required this.api, this.connectionLabel}); }`
  - Core: `AppSettingsContent.notificationExtras`.

- [ ] **Step 1: Write the failing test.** Use the capture helper pattern from `test/vad_settings_test.dart:16-45`, with `frame = Key('porter-frame')` and output to `build/voice-review/porter-*.png`.

```dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/porter_wake/porter_wake_api.dart';
import 'package:wing/porter_wake/porter_wake_device_id.dart';
import 'package:wing/porter_wake/porter_wake_ledger.dart';
import 'package:wing/porter_wake/porter_wake_module.dart';
import 'package:wing/porter_wake/porter_wake_settings.dart';

import 'fake_porter_bridge.dart';
import 'porter_wake_device_id_test.dart' show MemoryCredentialStore;
import 'porter_wake_fake_server.dart';

void main() {
  const capture = bool.fromEnvironment('VOICE_REVIEW');
  const frame = Key('porter-frame');
  setUpAll(() async {
    if (!capture) return;
    const path = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': ['Roboto-Regular.ttf'],
      'MaterialIcons': ['MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final name in entry.value) {
        loader.addFont(Future.value(ByteData.sublistView(File('$path/$name').readAsBytesSync())));
      }
      await loader.load();
    }
  });

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(frame));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build/voice-review').createSync(recursive: true);
      await File('build/voice-review/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  late FakePorterServer server;

  Future<PorterWakeModule> module({int probe = 200}) async {
    SharedPreferences.setMockInitialValues({});
    if (probe != 200) {
      server.statusFor['GET ${FakePorterServer.base}/settings/quiet-hours'] = probe;
    }
    final m = PorterWakeModule(
      bridge: RecordingPorterWakeBridge(),
      deviceIds: PorterDeviceIdStore(store: MemoryCredentialStore()),
      ledger: PorterNoticeLedger(await SharedPreferences.getInstance()),
      apiFactory: (_) => PorterWakeApi(server.client()),
    );
    await m.start();
    await m.sync([SavedConnection(id: 'c1', label: 'Home', host: 'hermes.test', port: 8642, apiKey: '')]);
    server.statusFor.clear();
    return m;
  }

  Future<void> pump(WidgetTester tester, PorterWakeModule m,
      {Brightness brightness = Brightness.light, double scale = 1}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: wingTheme(brightness),
      home: RepaintBoundary(
        key: frame,
        child: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(size: const Size(320, 700), textScaler: TextScaler.linear(scale)),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Card(child: PorterWakeSettings(module: m)),
            ),
          ),
        ),
      ),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  setUp(() => server = FakePorterServer());

  testWidgets('Nachtruhe shows the server values', (tester) async {
    final m = await tester.runAsync(() => module());
    await pump(tester, m!);
    expect(find.text('Nachtruhe'), findsOneWidget);
    expect(find.text('von'), findsOneWidget);
    expect(find.text('bis'), findsOneWidget);
    expect(find.text('22:00'), findsOneWidget);
    expect(find.text('08:00'), findsOneWidget);
    expect(find.text('Europe/Berlin'), findsOneWidget);
    await screenshot(tester, 'porter-nachtruhe-light');
  });

  testWidgets('Nachtruhe is hidden when the module is inactive', (tester) async {
    final m = await tester.runAsync(() => module(probe: 404));
    await pump(tester, m!);
    expect(find.text('Nachtruhe'), findsNothing);
  });

  testWidgets('toggling sends the full PUT and shows the 200 body', (tester) async {
    final m = await tester.runAsync(() => module());
    await pump(tester, m!);
    await tester.tap(find.text('Nachtruhe'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    final put = server.porterRequests().last;
    expect(put.method, 'PUT');
    expect(put.body, '{"enabled":false,"from":"22:00","to":"08:00"}');
  });

  testWidgets('a rejected save reverts and shows the server error', (tester) async {
    final m = await tester.runAsync(() => module());
    server.statusFor['PUT ${FakePorterServer.base}/settings/quiet-hours'] = 409;
    server.bodyFor['PUT ${FakePorterServer.base}/settings/quiet-hours'] =
        {'error': 'config layout not editable'};
    await pump(tester, m!);
    await tester.tap(find.text('Nachtruhe'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('config layout not editable'), findsOneWidget);
    final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(toggle.value, isTrue);
    await screenshot(tester, 'porter-nachtruhe-error');
  });

  testWidgets('dark theme at 200% text keeps every control reachable', (tester) async {
    final m = await tester.runAsync(() => module());
    await pump(tester, m!, brightness: Brightness.dark, scale: 2);
    expect(tester.takeException(), isNull);
    expect(find.text('bis'), findsOneWidget);
    await screenshot(tester, 'porter-nachtruhe-dark-200');
  });
}
```

> **ANNAHME S1:** `CompactSwitchListTile` builds on `SwitchListTile`, so `find.byType(SwitchListTile)` finds it. **Check** `compact_switch.dart:38`; otherwise find `CompactSwitchListTile` and read its `value`.

- [ ] **Step 2: Commit the test, run it, and see it fail**

```bash
git add test/porter_wake/porter_wake_settings_test.dart
git commit -m "test(porter_wake): Nachtruhe settings block"
```

Run: `bash tools/factory/ci-suite.sh test/porter_wake/porter_wake_settings_test.dart`
Expected: `conclusion=failure`.

- [ ] **Step 3: Implement `porter_wake_settings.dart`**

```dart
import 'package:flutter/material.dart';

import '../core/widgets/compact_switch.dart';
import '../core/widgets/studio_error.dart';
import 'porter_wake_api.dart';
import 'porter_wake_module.dart';

/// „Nachtruhe“ rows for the Notifications card. The server is the only truth;
/// nothing is stored on the device.
class PorterWakeSettings extends StatelessWidget {
  const PorterWakeSettings({super.key, required this.module});

  final PorterWakeModule module;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: module,
    builder: (context, _) {
      final active = module.activeConnections;
      if (active.isEmpty) return const SizedBox.shrink();
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final connection in active)
            QuietHoursPanel(
              key: ValueKey(connection.id),
              api: module.apiFor(connection.id)!,
              connectionLabel: active.length > 1 ? connection.label : null,
            ),
        ],
      );
    },
  );
}

class QuietHoursPanel extends StatefulWidget {
  const QuietHoursPanel({super.key, required this.api, this.connectionLabel});

  final PorterWakeApi api;
  final String? connectionLabel;

  @override
  State<QuietHoursPanel> createState() => _QuietHoursPanelState();
}

class _QuietHoursPanelState extends State<QuietHoursPanel> {
  PorterQuietHours? _server;
  PorterQuietHours? _shown;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await widget.api.quietHours();
      if (mounted) setState(() => _server = _shown = value);
    } on Object {
      if (mounted) setState(() => _error = 'Could not reach the server. Nachtruhe is unchanged.');
    }
  }

  Future<void> _save(PorterQuietHours next) async {
    setState(() {
      _shown = next;
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.api.saveQuietHours(next);
      if (mounted) setState(() => _server = _shown = saved);
    } on PorterApiError catch (error) {
      if (mounted) setState(() {
        _shown = _server;
        _error = error.message;
      });
    } on Object {
      if (mounted) setState(() {
        _shown = _server;
        _error = 'Could not reach the server. Nachtruhe is unchanged.';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pick(String current, PorterQuietHours Function(String) apply) async {
    final parts = current.split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
      helpText: 'Time in Hermes’ timezone',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null || !mounted) return;
    final text = '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}';
    if (text != current) await _save(apply(text));
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown == null) {
      return _error == null
          ? const SizedBox(height: 48)
          : Padding(padding: const EdgeInsets.all(16), child: StudioError(_error!));
    }
    final subtitle = [?widget.connectionLabel, shown.timezone].join(' · ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CompactSwitchListTile(
          value: shown.enabled,
          onChanged: _saving ? null : (value) => _save(shown.copyWith(enabled: value)),
          title: const Text('Nachtruhe'),
          subtitle: Text(subtitle),
        ),
        ListTile(
          title: const Text('von'),
          trailing: Text(shown.from),
          enabled: !_saving,
          onTap: () => _pick(shown.from, (v) => shown.copyWith(from: v)),
        ),
        ListTile(
          title: const Text('bis'),
          trailing: Text(shown.to),
          enabled: !_saving,
          onTap: () => _pick(shown.to, (v) => shown.copyWith(to: v)),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: StudioError(_error!),
          ),
      ],
    );
  }
}
```

The test expects `Europe/Berlin` as its own text when there is only one connection. With a single connection, `subtitle` equals the timezone, so the test holds.

- [ ] **Step 4: Core seam in `app_settings_content.dart`.** Add the constructor parameter, the field and the loop exactly as listed under **Files**. Add no other change.

- [ ] **Step 5: Add the render capture.** In `.github/workflows/voice-review.yml`, append ` test/porter_wake/porter_wake_settings_test.dart` to the `flutter test` line after `test/car_mode/car_mode_screen_test.dart`.

- [ ] **Step 6: Run and see it pass**

Run: `bash tools/factory/ci-suite.sh test/porter_wake/ test/app_settings_design_test.dart test/app_notification_settings_test.dart`
Expected: `conclusion=success`.

- [ ] **Step 7: Commit**

```bash
git add lib/porter_wake/porter_wake_settings.dart lib/core/screens/app_settings_content.dart .github/workflows/voice-review.yml
git commit -m "feat(porter_wake): Nachtruhe block reads and writes server quiet hours"
```

- [ ] **Step 8: Inspect the renders.** Run `bash tools/factory/dispatch-check.sh voice-review.yml`, then `git fetch origin voice-review-bin`, then `git archive --format=tar --output=build/voice-review-bin.tar origin/voice-review-bin`, and unpack it into `build/voice-review-bin/`. Read `porter-nachtruhe-light.png`, `porter-nachtruhe-error.png` and `porter-nachtruhe-dark-200.png`. Check:
- a single label per row;
- the time is right-aligned in the trailing column;
- the timezone is muted;
- the error sits directly under the rows;
- nothing is clipped at 200%;
- contrast holds in dark mode.

Fix anything that looks wrong and rerun from Step 6.

---

### Task 10: Wiring into the app

**Files:**
- Modify: `lib/main.dart`
  - fields near `:127-142`;
  - `initState` (`:328-401`);
  - connection save, update and delete call sites: the call at `:1266` (save, where `saveConnection` returns), the `updateConnection` call at `:1284`, and the delete at `:1376`;
  - both `ProfileWorkspaceScreen(` constructions (`:276`, `:1215`);
  - the `AppSettingsContent(` at `:1471`.
- Modify: `lib/core/screens/profile_workspace_screen.dart`: constructor (`:106`) adds `this.settingsExtras`; field `final List<Widget> Function()? settingsExtras;`; at `:3090` pass `notificationExtras: widget.settingsExtras?.call() ?? const []`.
- Test: `test/porter_wake/porter_wake_module_test.dart` (one added test for `openPorterProfile`).

**Interfaces:**
- Consumes: `PorterWakeModule` (Task 7), `PorterWakeSettings` (Task 9), `MethodChannelPorterWakeBridge` (Task 6).
- Produces in `lib/main.dart`:
  - `late final PorterWakeModule _porter;`
  - `Future<void> _syncPorter()`
  - `Future<void> openPorterProfile(String connectionId, String profile)`

`HomeScreenState` owns the save, update and delete calls, while `WingAppState` owns the module. Give `HomeScreen` a new optional constructor parameter `PorterWakeModule? porter` and pass `_porter` from `WingAppState`. The three call sites then call `widget.porter?…`.

> **ANNAHME W1:** `HomeScreen` is constructed in `WingAppState.build`. **Check** with `grep -n "HomeScreen(" lib/main.dart`. If it is built elsewhere, pass the module along that path.

- [ ] **Step 1: Write the failing test.** `openPorterProfile` must pick the most recent session. Put the selection rule into a pure function in the module so it can be tested. Add it to `porter_wake_module.dart`:

```dart
/// The most recent session row (contract §6.6; Wing has no pinned chats).
String? mostRecentSessionId(List<Map<String, dynamic>> rows) {
  String? best;
  num bestTime = double.negativeInfinity;
  for (final row in rows) {
    final id = row['id'];
    final time = row['last_active'];
    if (id is String && time is num && time > bestTime) {
      best = id;
      bestTime = time;
    }
  }
  return best;
}
```

Test, appended to `porter_wake_module_test.dart`:

```dart
  test('the most recent pforte session wins', () {
    expect(mostRecentSessionId([
      {'id': 'old', 'last_active': 10},
      {'id': 'new', 'last_active': 30},
      {'id': 'mid', 'last_active': 20},
      {'id': 'broken'},
    ]), 'new');
    expect(mostRecentSessionId(const []), isNull);
  });
```

Commit the test with message `test(porter_wake): most recent pforte session`, then run `bash tools/factory/ci-suite.sh test/porter_wake/porter_wake_module_test.dart`. Expected: failure, then `conclusion=success` after the function is added.

- [ ] **Step 2: Wire `WingAppState`.** Add the imports `porter_wake/porter_wake_bridge.dart`, `porter_wake_device_id.dart`, `porter_wake_ledger.dart`, `porter_wake_module.dart` and `porter_wake_settings.dart`. Then add:

```dart
  late final PorterWakeModule _porter;

  Future<void> _syncPorter() async {
    try {
      await _porter.sync(await widget.connManager.loadConnectionsWithSecrets());
    } on Object catch (error) {
      debugPrint('porter_wake: sync failed (${error.runtimeType})');
    }
  }

  /// „Öffnen“: the most recent chat of [profile] on that connection, else its chat list.
  Future<void> openPorterProfile(String connectionId, String profile) async {
    final connection = (await widget.connManager.loadConnectionsWithSecrets())
        .where((c) => c.id == connectionId)
        .firstOrNull;
    if (connection == null) return _showNotificationOpenError();
    final controller = await _profileControllers.forConnection(connection);
    await controller.switchProfile(profile);
    final data = controller.current;
    final session = data == null ? null : mostRecentSessionId(data.sessions);
    if (data == null || session == null) {
      await _homeKey.currentState?.selectWorkspaceConnection(connection, AppDestination.chats);
      return;
    }
    await openProfileNotification(jsonEncode(ProfileSessionKey(data.scope, session).toJson()));
  }
```

In `initState`, after `_networkAvailability.start(...)` (`:397-400`), add:

```dart
    _porter = PorterWakeModule(
      bridge: MethodChannelPorterWakeBridge(),
      deviceIds: PorterDeviceIdStore(),
      ledger: PorterNoticeLedger(widget.connManager.prefs),
      openProfile: openPorterProfile,
    );
    unawaited(_notificationsReady.then((_) async {
      await _porter.start();
      await _syncPorter();
    }).catchError((Object _) {}));
```

In `dispose`, add `_porter.dispose();`. In both `ProfileWorkspaceScreen(` constructions, add `settingsExtras: () => [PorterWakeSettings(module: _porter)],`.

> **ANNAHME W2:** `ProfileWorkspaceData` exposes `scope` (a `WorkspaceScope`) and `sessions` (`:273`), and `AppDestination.chats` with `selectWorkspaceConnection` (used at `main.dart:288`) shows the chat list for the switched profile. **Check** `ProfileWorkspaceData` (`profile_workspace_controller.dart:270-310`) for the scope field name before writing the code.

- [ ] **Step 3: Wire `HomeScreenState`.**
  - At `:1471`, `AppSettingsContent(` adds `notificationExtras: [if (widget.porter != null) PorterWakeSettings(module: widget.porter!)],`.
  - After the `saveConnection` result (`:1266`) and after `updateConnection` (`:1284`), add `unawaited(widget.porter?.refresh(saved) ?? Future.value());`, where `saved` is the connection with secrets reloaded through `widget.connManager.loadConnectionsWithSecrets()`, matched by id.
  - Before `await widget.connManager.deleteConnection(conn.id);` (`:1376`), add the line below. The DELETE must run while the credentials still exist:

```dart
                final full = (await widget.connManager.loadConnectionsWithSecrets())
                    .where((c) => c.id == conn.id).firstOrNull;
                if (full != null) await widget.porter?.forget(full);
```

- [ ] **Step 4: Run the affected suites**

Run: `bash tools/factory/ci-suite.sh test/porter_wake/ test/app_notification_routing_test.dart test/app_settings_design_test.dart test/profile_workspace_controller_test.dart test/connection_manager_test.dart`
Expected: `conclusion=success`.

Widget tests that build `WingApp` without the platform channel get `MissingPluginException` from `MethodChannelPorterWakeBridge.start`. The `.catchError` in `initState` swallows it. If a test fails on an unhandled exception, wrap `_porter.start()` in a `try { … } on MissingPluginException { }`.

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart lib/core/screens/profile_workspace_screen.dart lib/porter_wake/porter_wake_module.dart test/porter_wake/porter_wake_module_test.dart
git commit -m "feat(porter_wake): wire the module into connections, settings and Öffnen"
```

---

### Task 11: Specific snooze times („in 2 Stunden“, „morgen“) [GATED]

**Gate:** do not start this task until Birk has answered **FRAGE 1**. Contract §6.4 allows either "expanded view" or "in-app sheet via long-press", but §8.2 requires live = 1 button and trial = 4 buttons. Extra snooze buttons in the expanded view would break those counts. So the contract-consistent option is an in-app sheet, and Wing has no "notice view" for it to live in yet.

**Recommended design (default if Birk confirms):** after „Öffnen“, Wing opens the Pforte chat (Task 10) and shows a compact modal bottom sheet `PorterNoticeSheet` above it, but only for `kind == items`. The sheet contains:
- `title`;
- one row per item: `line`, with `why` and `snooze_label` as muted subtitle;
- tap on a row: opens that item's session (`profile`, `session_id`, as contract §6.6 allows);
- long-press on a row: shows the chooser `Später` · `in 2 Stunden` · `morgen`, which sends `snooze` with `default` / `2h` / `morgen` and closes the sheet.

**Files:**
- Create: `lib/porter_wake/porter_wake_snooze_sheet.dart`
- Modify: `lib/porter_wake/porter_wake_handler.dart` (an optional `PorterShowNotice? showNotice` callback after `openProfile`)
- Modify: `lib/porter_wake/porter_wake_module.dart` (forwards `showNotice` to the handler)
- Modify: `lib/main.dart` (supply `showNotice` from `WingAppState` using `_navigatorKey.currentContext`)
- Test: `test/porter_wake/porter_wake_snooze_sheet_test.dart`

**Interfaces:**
- `typedef PorterShowNotice = Future<void> Function(String connectionId, PorterNotice notice);`
- `Future<void> showPorterNoticeSheet(BuildContext context, {required PorterNotice notice, required Future<bool> Function(Map<String, String> body) feedback, required Future<void> Function(String profile, String sessionId) openItem});`
- Chooser values: `const porterSnoozeChoices = [('Später', 'default'), ('in 2 Stunden', '2h'), ('morgen', 'morgen')];`. The first label comes from the notice's snooze action; the other two are the contract-named Wing-local strings.

- [ ] **Step 1: Write the failing test**

```dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/porter_wake/porter_wake_notice.dart';
import 'package:wing/porter_wake/porter_wake_snooze_sheet.dart';

import 'porter_wake_fixtures.dart';

void main() {
  testWidgets('long-press offers Später, in 2 Stunden and morgen and sends the value', (tester) async {
    final notice = PorterNotice.fromJson(jsonDecode(porterExampleB) as Map<String, dynamic>);
    final sent = <Map<String, String>>[];
    final opened = <(String, String)>[];
    await tester.pumpWidget(MaterialApp(
      theme: wingTheme(Brightness.light),
      home: Builder(builder: (context) => TextButton(
        onPressed: () => showPorterNoticeSheet(context,
          notice: notice,
          feedback: (body) async { sent.add(body); return true; },
          openItem: (profile, session) async => opened.add((profile, session))),
        child: const Text('go'),
      )),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Buchhandlung Seewind: Lesungstermin bestätigen?'), findsOneWidget);
    await tester.longPress(find.text('Steuer: Konto für Erstattung bestätigen?'));
    await tester.pumpAndSettle();
    expect(find.text('Später'), findsOneWidget);
    expect(find.text('in 2 Stunden'), findsOneWidget);
    expect(find.text('morgen'), findsOneWidget);
    await tester.tap(find.text('in 2 Stunden'));
    await tester.pumpAndSettle();
    expect(sent, [{'action': 'snooze', 'value': '2h'}]);
  });

  testWidgets('tapping an item opens its own session', (tester) async {
    final notice = PorterNotice.fromJson(jsonDecode(porterExampleB) as Map<String, dynamic>);
    final opened = <(String, String)>[];
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
      onPressed: () => showPorterNoticeSheet(context, notice: notice,
        feedback: (_) async => true,
        openItem: (p, s) async => opened.add((p, s))),
      child: const Text('go')))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zugangsdaten im Klartext in Notiz gefunden: löschen?'));
    await tester.pumpAndSettle();
    expect(opened, [('cothinker', 's-notiz')]);
  });
}
```

- [ ] **Step 2: Commit the test, run it, and see it fail**

```bash
git add test/porter_wake/porter_wake_snooze_sheet_test.dart
git commit -m "test(porter_wake): in-app snooze chooser"
```

Run: `bash tools/factory/ci-suite.sh test/porter_wake/porter_wake_snooze_sheet_test.dart`. Expected: `conclusion=failure`.

- [ ] **Step 3: Implement**

```dart
import 'package:flutter/material.dart';

import 'porter_wake_notice.dart';

const porterSnoozeChoices = [('in 2 Stunden', '2h'), ('morgen', 'morgen')];

Future<void> showPorterNoticeSheet(
  BuildContext context, {
  required PorterNotice notice,
  required Future<bool> Function(Map<String, String> body) feedback,
  required Future<void> Function(String profile, String sessionId) openItem,
}) {
  final later = notice.actions.where((a) => a.id == 'snooze').firstOrNull;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(notice.title, style: Theme.of(sheet).textTheme.titleMedium),
          ),
          for (final item in notice.items)
            ListTile(
              title: Text(item.line),
              subtitle: (item.snoozeLabel ?? item.why) == null
                  ? null
                  : Text([?item.why, ?item.snoozeLabel].join(' · ')),
              onTap: () async {
                Navigator.of(sheet).pop();
                await openItem(item.profile, item.sessionId);
              },
              onLongPress: later == null
                  ? null
                  : () async {
                      final value = await showModalBottomSheet<String>(
                        context: sheet,
                        builder: (chooser) => SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final (label, value) in [
                                (later.label, later.defaultValue ?? 'default'),
                                ...porterSnoozeChoices,
                              ])
                                ListTile(
                                  title: Text(label),
                                  onTap: () => Navigator.of(chooser).pop(value),
                                ),
                            ],
                          ),
                        ),
                      );
                      if (value == null || !sheet.mounted) return;
                      await feedback({'action': 'snooze', 'value': value});
                      if (sheet.mounted) Navigator.of(sheet).pop();
                    },
            ),
        ],
      ),
    ),
  );
}
```

In `PorterWakeHandler`, add the constructor parameter `this.showNotice` and the field `final PorterShowNotice? showNotice;`. Then replace the `open` branch of `onInteraction` with:

```dart
    if (event.action == 'open') {
      var profile = event.openProfile;
      PorterNotice? notice;
      if (api != null) {
        try {
          notice = await api.notice(event.noticeId);
          profile = notice.openProfile;
        } on Object catch (error) {
          debugPrint('porter_wake: notice fetch on open failed (${error.runtimeType})');
        }
        try {
          await api.feedback(event.noticeId, const {'action': 'open'});
        } on Object catch (error) {
          debugPrint('porter_wake: open feedback failed (${error.runtimeType})');
        }
      }
      await bridge.cancel();
      await openProfile?.call(event.connectionId, profile);
      if (notice != null) await showNotice?.call(event.connectionId, notice);
      return true;
    }
```

Add `import 'porter_wake_notice.dart';` to the handler. Task 6's tests still hold: `open posts {"action":"open"}` checks the last request, which is still the feedback POST. Pass `showNotice` through `PorterWakeModule` with a new optional constructor parameter `PorterShowNotice? showNotice`, forwarded to the handler. In `main.dart`, pass:

```dart
showNotice: (connectionId, notice) async {
  final context = _navigatorKey.currentContext;
  final api = _porter.apiFor(connectionId);
  if (context == null || !context.mounted || api == null || notice.kind != 'items') return;
  await showPorterNoticeSheet(context,
    notice: notice,
    feedback: (body) => api.feedback(notice.noticeId, body),
    openItem: (profile, session) => openPorterSession(connectionId, profile, session));
}
```

`openPorterSession` is `openPorterProfile` with a fixed session: it switches to `profile` and opens `ProfileSessionKey(data.scope, session)`. Add it next to `openPorterProfile`.

- [ ] **Step 4: Run, render and inspect.** Run `bash tools/factory/ci-suite.sh test/porter_wake/`; expected `conclusion=success`. Add a light, a dark and a 200% capture of the sheet with example B to this test, using the Task 9 capture helper. Add the file to `voice-review.yml`, dispatch it, and inspect the result as in Task 9 step 8.

- [ ] **Step 5: Commit**

```bash
git add lib/porter_wake/porter_wake_snooze_sheet.dart lib/porter_wake/porter_wake_handler.dart lib/porter_wake/porter_wake_module.dart lib/main.dart test/porter_wake/porter_wake_snooze_sheet_test.dart .github/workflows/voice-review.yml
git commit -m "feat(porter_wake): in-app snooze chooser with in 2 Stunden and morgen"
```

---

### Task 12: Privacy docs, feature doc, changelog and README

**Files:**
- Modify: `PRIVACY.md:25` (last sentence)
- Modify: `docs/PLAY_DATA_SAFETY.md:23` (sentence "Wing does not register with a push provider…")
- Create: `docs/PORTER_WAKE.md`
- Modify: `CHANGELOG.fork.md` (new top entry under a `## <build date>` heading, following the format at its top)
- Modify: `README.md` (one line in the "Wing Voice (fork)" feature list, `:1-15`)

**Interfaces:** none (docs).

- [ ] **Step 1: PRIVACY.md.** Replace `Wing does not use Firebase or transmit device push tokens to a push provider.` with:

```
Wing does not use Firebase. Only when a connected Hermes server offers the optional porter wake plugin, Wing registers a UnifiedPush endpoint with that server; the push distributor is the user's own ntfy app and server. The push carries no message content: Wing fetches each notice from the user's Hermes server over its authenticated connection. Removing the connection or unregistering in the distributor deletes the registration on the server.
```

- [ ] **Step 2: PLAY_DATA_SAFETY.md.** Replace `Wing does not register with a push provider or transmit device push tokens.` with:

```
Wing does not use Firebase or Google push. If a connected Hermes server offers the optional porter wake plugin, Wing registers a UnifiedPush endpoint and a random per-install device id with that user-operated server; the distributor is the user's own ntfy app. Pushes carry no content; notices are fetched from the user's Hermes server.
```

- [ ] **Step 3: `docs/PORTER_WAKE.md`.** About 40 lines, in English. Sections:
  - "What it does": the Pforte notification, actions, „Nachtruhe“.
  - "Requirements": a Hermes server with the porter wake plugin; the ntfy app as UnifiedPush distributor, pointed at the user's ntfy server.
  - "Stock Hermes": the module stays inert (404/503 probe).
  - "Privacy": no content in the push; device id; how to revoke.
  - "Scope exception": a custom plugin endpoint, approved by Birk 2026-10-19 for this module only, with all code in `lib/porter_wake/` and `…/porterwake/`.
  - "Contract": a link to `superpowers/specs/2026-10-19-wing-push-contract.md`.

- [ ] **Step 4: CHANGELOG.fork.md entry** (newest first):

```markdown
### Pforte notifications via UnifiedPush, with Nachtruhe
- **What:** Optional porter wake module (`lib/porter_wake/`): Wing registers a UnifiedPush endpoint (ntfy as distributor, no FCM) with a Hermes server that offers the porter wake plugin, fetches each content-free-pushed notice and shows it on the attention channel with Öffnen, Später and, in trial mode, three ratings. A „Nachtruhe“ block in the Notifications settings reads and writes the server's quiet hours.
- **Why:** Pforte must reach Birk without polling and without Google services; quiet hours stay a single server-side truth.
- **Exception:** This module calls a custom plugin endpoint (`/api/plugins/porter_wake`), an exception to the AGENTS.md "Hermes deployment constraint" approved by Birk on 2026-10-19 for this module only. It is inert on stock Hermes (404/503 probe).
- **Docs:** [PORTER_WAKE.md](docs/PORTER_WAKE.md)
- **Merge:** `MERGE_SHA` · **Card:** t_92a40e12 (plan t_7737d2c2)
```

The merge step replaces `MERGE_SHA` with the merge commit hash. The AGENTS.md rule is checked at merge time.

- [ ] **Step 5: README.md.** Add `- [Pforte notifications and Nachtruhe](docs/PORTER_WAKE.md)` to the feature list.

- [ ] **Step 6: Run the doc-adjacent tests and commit**

Run: `bash tools/factory/ci-suite.sh test/privacy_policy_screen_test.dart test/background_monitoring_service_test.dart`
Expected: `conclusion=success`.

```bash
git add PRIVACY.md docs/PLAY_DATA_SAFETY.md docs/PORTER_WAKE.md CHANGELOG.fork.md README.md
git commit -m "docs(porter_wake): privacy, data safety, feature doc and fork changelog"
```

---

### Task 13: Go-live gate: QA build, three screenshots, handoff

**Approach for examples A, B and C without the live server:** use an **isolated QA entry point with a loopback fake server**. This follows the existing precedent `integration_test/notification_revamp_device.dart`, built with `-PnotificationQa=true` (`docs/TESTING.md:215-226`, `docs/BACKGROUND_NOTIFICATIONS.md:88-94`).

Why this approach:
- **It cannot reach release builds.** The entry point lives in `integration_test/` and is selected only with `-t`. `voice-apk.yml` builds `lib/main.dart`. `-PnotificationQa` gives the separate package `com.tarkilhk.wing.notificationqa`, so Birk's Wing Voice data is never touched.
- **No debug code in `lib/`.** The repo has no `kDebugMode` precedent (verified), and none is added.
- **It exercises the real chain.** The production `PorterWakeModule` and handler run, the real `MethodChannelPorterWakeBridge`, the Kotlin renderer and `PorterActionActivity`. The only fakes are the dashboard (a loopback `HttpServer`) and the push origin (a loopback control endpoint that calls the same `PorterWakeHandler.onPush`).

**Files:**
- Create: `integration_test/porter_wake_device.dart`
- Create: `.github/workflows/porter-qa-apk.yml`

**Interfaces:**
- Fake dashboard: `127.0.0.1:18767`. It serves `/auth/password-login`, `/api/plugins/porter_wake/settings/quiet-hours`, `/api/plugins/porter_wake/notices/<id>` (examples A/B/C from `test/porter_wake/porter_wake_fixtures.dart`), `…/feedback` and `…/push/devices`, and records every porter request.
- Control endpoint: `127.0.0.1:18768`.
  - `GET /push?notice=<id>` → `handler.onPush('porter-qa', utf8(v1 payload))`.
  - `GET /state` → the JSON list of recorded porter requests.
  - `GET /reset` → clears `PorterNoticeLedger.key`.

- [ ] **Step 1: QA entry point.** Modelled on `notification_revamp_device.dart`:

```dart
/// Isolated porter wake QA entry point. Build with -PnotificationQa=true and
/// -t integration_test/porter_wake_device.dart; never a distributed build.
/// The dashboard is fake and loopback-only; data are contract examples.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/porter_wake/porter_wake_bridge.dart';
import 'package:wing/porter_wake/porter_wake_device_id.dart';
import 'package:wing/porter_wake/porter_wake_ledger.dart';
import 'package:wing/porter_wake/porter_wake_module.dart';

import '../test/porter_wake/porter_wake_fixtures.dart';
import '../test/profile_connection_identity_test.dart' show MemoryIdentityStore;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final recorded = <Map<String, Object?>>[];
  final dashboard = await HttpServer.bind(InternetAddress.loopbackIPv4, 18767);
  dashboard.listen((request) async {
    final path = request.uri.path;
    final body = await utf8.decoder.bind(request).join();
    if (path.startsWith('/api/plugins/porter_wake')) {
      recorded.add({'method': request.method, 'path': path, 'body': body});
    }
    Object? reply;
    if (path == '/auth/password-login') {
      request.response.headers.add('set-cookie', 'hermes_session_at=qa; Path=/');
      reply = {};
    } else if (path.endsWith('/settings/quiet-hours')) {
      reply = {'enabled': true, 'from': '22:00', 'to': '08:00', 'timezone': 'Europe/Berlin'};
    } else if (path.endsWith('/feedback')) {
      reply = {'applied': true, 'result': {}};
    } else if (path.contains('/push/devices')) {
      reply = {'device_id': 'qa', 'registered': '2026-10-19T06:00:00.000Z', 'replaced': false};
    } else {
      for (var i = 0; i < porterNoticeIds.length; i++) {
        if (path.endsWith('/notices/${porterNoticeIds[i]}')) reply = jsonDecode(porterExamples[i]);
      }
    }
    request.response.statusCode = reply == null ? 404 : 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(reply ?? {'error': 'unknown notice'}));
    await request.response.close();
  });

  final prefs = await SharedPreferences.getInstance();
  final connection = SavedConnection(
    id: 'porter-qa', label: 'Porter QA', host: '127.0.0.1', port: 1, apiKey: '',
    dashboardPort: 18767, dashboardUsername: 'qa', dashboardPassword: 'qa');
  final module = PorterWakeModule(
    bridge: MethodChannelPorterWakeBridge(),
    deviceIds: PorterDeviceIdStore(store: MemoryIdentityStore()),
    ledger: PorterNoticeLedger(prefs),
    openProfile: (_, _) async {},
  );
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('Porter QA')))));
  await module.start();
  await module.sync([connection]);

  final control = await HttpServer.bind(InternetAddress.loopbackIPv4, 18768);
  await for (final request in control) {
    switch (request.uri.path) {
      case '/push':
        final id = request.uri.queryParameters['notice']!;
        await module.handler.onPush('porter-qa',
            utf8.encode(jsonEncode({'v': 1, 'type': 'porter_wake', 'notice_id': id})));
      case '/reset':
        await prefs.remove(PorterNoticeLedger.key);
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'requests': recorded}));
    await request.response.close();
  }
}
```

> **ANNAHME Q1:** `SavedConnection` accepts the named parameters `dashboardPort`, `dashboardUsername` and `dashboardPassword`, which are fields used by `_dashboardFor`. **Check** the `SavedConnection` constructor in `connection_manager.dart`, and adapt the names. `MemoryIdentityStore` implements `CredentialStore` (`test/profile_connection_identity_test.dart:7`).
>
> **ANNAHME Q2:** the probe uses `127.0.0.1:18767` over plain HTTP. Wing's network security config allows cleartext to loopback, as the existing QA fixture's `127.0.0.1` connection does. **Check** `android/app/src/main/res/xml/` if the probe fails with a cleartext error.

- [ ] **Step 2: Build workflow** `.github/workflows/porter-qa-apk.yml`. It is not on `main`, so it is triggered by pushing a `ci-porter-qa-apk/**` ref (`dispatch-check.sh` handles this):

```yaml
name: Porter QA APK (debug, isolated package)

# Debug APK of integration_test/porter_wake_device.dart under package
# com.tarkilhk.wing.notificationqa (fake loopback dashboard). Never distributed.
# Output goes to branch porter-qa-apk-bin (git transport; see voice-apk.yml).
on:
  push:
    branches: ['ci-porter-qa-apk/**', 'ci-porter-qa-apk-publish/**']

permissions:
  contents: write

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 1
          persist-credentials: false
      - uses: actions/setup-java@de7274f081f381c8f8158605e0321c36c376e2e6 # v6.0.1
        with:
          distribution: 'temurin'
          java-version: '17'
      - name: Set up Flutter
        uses: ./.github/actions/setup-flutter
        with:
          flutter-version: '3.44.0'
          channel: 'stable'
          cache: true
      - run: flutter pub get
      - name: Build QA APK
        run: |
          set +e
          ORG_GRADLE_PROJECT_notificationQa=true flutter build apk --debug --target-platform android-arm64 \
            -t integration_test/porter_wake_device.dart 2>&1 | tee /tmp/build.log
          rc=${PIPESTATUS[0]}
          if [ "$rc" != 0 ]; then
            grep -E "^e: |error:|FAILED|What went wrong|Execution failed|Caused by" -A3 /tmp/build.log | head -60 | while IFS= read -r l; do echo "::error::${l:0:900}"; done
          fi
          exit "$rc"
      - name: Publish to porter-qa-apk-bin
        env:
          TOKEN: ${{ github.token }}
        run: |
          mkdir -p /tmp/out
          cp build/app/outputs/flutter-apk/app-debug.apk /tmp/out/porter-qa.apk
          echo "${GITHUB_SHA}" > /tmp/out/SOURCE_COMMIT
          (cd /tmp/out && sha256sum porter-qa.apk > SHA256SUMS)
          cd /tmp/out
          git init -q -b porter-qa-apk-bin
          git config user.name "ci"; git config user.email "ci@localhost"
          git add -A && git commit -q -m "porter qa ${GITHUB_SHA}"
          git push -f "https://x-access-token:${TOKEN}@github.com/${GITHUB_REPOSITORY}.git" porter-qa-apk-bin
```

Commit Steps 1 and 2:

```bash
git add integration_test/porter_wake_device.dart .github/workflows/porter-qa-apk.yml
git commit -m "test(porter_wake): isolated QA entry point and APK workflow for the screenshot gate"
```

- [ ] **Step 3: Build and fetch**

Run: `bash tools/factory/dispatch-check.sh porter-qa-apk.yml publish=true`
Expected: `conclusion=success`.

Then run `git fetch origin porter-qa-apk-bin`, followed by `git archive --format=tar --output=build/porter-qa.tar origin/porter-qa-apk-bin`, and unpack it into `build/porter-qa/`. Check that `SOURCE_COMMIT` equals `git rev-parse HEAD` and that `sha256sum` matches `SHA256SUMS`.

- [ ] **Step 4: Install on the phone.** Follow the preconditions of `docs/superpowers/plans/2026-10-13-wing-voice-vad-input.md:4090-4112`:
- Never bypass the screen lock. If `hadb shell 'dumpsys window | grep isKeyguardShowing'` reports `true`, ask Birk to unlock and wait.
- Install with `hadb install build/porter-qa/porter-qa.apk`, or with the tailnet HTTP fallback described there. Expected: `Success`.
- Then grant the notification permission and launch the app:

```
hadb shell pm grant com.tarkilhk.wing.notificationqa android.permission.POST_NOTIFICATIONS
hadb shell am start -n com.tarkilhk.wing.notificationqa/com.tarkilhk.wing.MainActivity
```

- [ ] **Step 5: Render and capture A, B and C.** For each `(n, id)` in `(1, n-3f2a9c1b7d4e)`, `(2, n-9e8d7c6b5a41)`, `(3, n-5a4b3c2d1e0f)`:

```
hadb shell curl -s http://127.0.0.1:18768/reset
hadb shell curl -s "http://127.0.0.1:18768/push?notice=<id>"
hadb shell cmd statusbar expand-notifications
hadb shell screencap -p /sdcard/porter-<n>.png
hadb pull /sdcard/porter-<n>.png build/porter-qa/porter-<n>.png
hadb shell rm /sdcard/porter-<n>.png
hadb shell cmd statusbar collapse
```

If the porter notification is collapsed in the shade, expand it with a two-finger downward swipe on it (`hadb shell input swipe …`) before `screencap`. The trial buttons of example A only appear in the expanded custom view.

Expected images, checked visually:
- **porter-1:** „🔴 Birk wartet auf dich“, „Antwort an Galerie Ostwind freigeben?“ / „Jemand wartet auf Antwort“, and four buttons: „Später“, „unwichtig“, „so lala“, „sehr wichtig“.
- **porter-2:** „🔴 3 Dinge warten“, with „⏰ Zurückgestellt: Buchhandlung Seewind: Lesungstermin bestätigen?“ first, then „Frist heute“, and one „Später“ button.
- **porter-3:** „🟢 Probelauf beendet“, „Probelauf beendet, ab jetzt höchstens 3 am Tag“, and one „Später“ button.

Also capture `porter-1-large.png` with `hadb shell settings put system font_scale 1.5`, which switches to the grid layout. Restore with `hadb shell settings put system font_scale 1.0`.

- [ ] **Step 6: Tap-path smoke (QA app only, no real server).**
- Tap „unwichtig“ on example A. Expected:
  - the notification disappears;
  - `hadb shell curl -s http://127.0.0.1:18768/state` lists a POST `…/notices/n-3f2a9c1b7d4e/feedback` with body `{"action":"rate","value":"unwichtig"}`;
  - Wing did not come to the foreground (`hadb shell dumpsys activity activities | grep mResumedActivity` does not show `notificationqa` MainActivity).
- Push the same id again without `/reset`. Expected: no new notification.
- Run `hadb shell am force-stop com.tarkilhk.wing.notificationqa`, then the `/push` call. Expected: the control server is gone with the process, so the push cannot be injected. This step therefore cannot test the headless path. Record that ANNAHME B2 is verified only in the §8.4 E2E (step 2c below).

- [ ] **Step 7: Clean up and hand over.** Uninstall the QA app (`hadb uninstall com.tarkilhk.wing.notificationqa`). Send the four PNGs to Birk and record on cards t_92a40e12 and t_2b45a583 that the screenshot gate is waiting for Birk's OK. **The build card stops here.** The steps below are a manual handoff for Birk and are not executed by the build card.

**Handoff checklist (contract §8.3 and §8.4, run by Birk or at his request after PB GO-LIVE and ntfy GO-LIVE):**
1. Test build (§8.3):
   - `bash tools/factory/dispatch-check.sh voice-apk.yml publish=true`
   - `bash /home/birk/hermes-shared/hermes-entities/tools/technik/wing-voice-build.sh`
   - `hadb install /home/birk/handy-builds/wing-voice/wing-voice-latest.apk`
   - Expected: `Success`, and a newer `lastUpdateTime` in `hadb shell 'dumpsys package com.tarkilhk.wing.voice | grep lastUpdateTime'`.
2. Contract §8.4 steps 1–6, exactly as written there. Use the §8.1 `read -s` login, never typing secrets on the command line. Add these steps:
   - **2b (ANNAHME B1):** `hadb shell dumpsys deviceidle force-idle` before a forced push. Expected: the full notice, or at worst „Pforte: neue Nachricht“. Then `hadb shell dumpsys deviceidle unforce`.
   - **2c (ANNAHME B2):** `hadb shell am force-stop com.tarkilhk.wing.voice` before a forced push. Expected: the full notice, which proves the headless engine.
   - **3b:** tap „Später“ with Wing force-stopped. Expected: Wing does not open, and `feedback.snoozed_until` is set.
3. Revocation:
   - Delete and re-add the connection in Wing. Expected: `GET /push/devices` shows the device gone, then back.
   - In the ntfy app, remove the Wing subscription. Expected: the device is removed on the server (`onUnregistered` → DELETE).

---

### Task 14: Mutation check for the key behaviours

Prove that the key tests catch real regressions. This follows the repo precedent (`f03c9434` "mutation-test: temporarily revert…" / `b1258938` "revert: restore the fix after the mutation check").

**Files (temporary):** `lib/porter_wake/porter_wake_handler.dart`, `lib/porter_wake/porter_wake_module.dart`, `lib/porter_wake/porter_wake_settings.dart`

- [ ] **Step 1: Apply three mutations in one commit**
  1. **Dedupe by notice_id:** in `PorterWakeHandler.onPush`, replace `if (!await ledger.claim(payload.noticeId)) return;` with `await ledger.claim(payload.noticeId);`.
  2. **404 isolation:** in `PorterWakeModule._probe`, change `case PorterProbe.absent:` to fall into the active branch. Do this by changing `PorterWakeApi.probe` usage to `final probe = await api.probe(); switch (probe == PorterProbe.absent ? PorterProbe.active : probe) {`.
  3. **Revert on PUT error:** in `_QuietHoursPanelState._save`, inside `on PorterApiError catch`, delete the line `_shown = _server;`.

```bash
git add lib/porter_wake/porter_wake_handler.dart lib/porter_wake/porter_wake_module.dart lib/porter_wake/porter_wake_settings.dart
git commit -m "mutation-test: break dedupe, 404 isolation and PUT revert (to be reverted)"
```

- [ ] **Step 2: Run and see it fail**

Run: `bash tools/factory/ci-suite.sh test/porter_wake/`
Expected: `conclusion=failure` with `failed step: Run tests`. If the job annotations or the step summary are readable, the failing tests are exactly:
- `a second push with the same notice id shows nothing and posts nothing`
- `a 404 probe registers nothing and calls no other porter route`
- `a 503 probe is treated like 404`
- `Nachtruhe is hidden when the module is inactive`
- `a rejected save reverts and shows the server error`

If any of these passes, strengthen that test before continuing.

- [ ] **Step 3: Revert and confirm green**

```bash
git revert --no-edit HEAD
```

Then amend the message to `revert: restore behaviour after the mutation check`. Run: `bash tools/factory/ci-suite.sh`. This is the whole suite and the final gate. Expected: `conclusion=success`.

---

## Open questions for Birk

- **FRAGE 1 (Task 11, UX):** where should „in 2 Stunden“ and „morgen“ live?
  - Contract §8.2 fixes the notification at live = 1 button and trial = 4. Extra snooze buttons in the expanded notification would break that.
  - Recommended: an in-app sheet over the Pforte chat after „Öffnen“, which lists the items (tap opens the item's chat; long-press shows Später / in 2 Stunden / morgen).
  - Alternative: drop the specific times from v1 (only „Später“ = morning bundle).
  - Task 11 is gated on this answer. Tasks 0–10 and 12–14 do not depend on it.
- **FRAGE 2 (CI, Task 0):** `pr-quality.yml` currently tests only `test/car_mode/car_mode_screen_test.dart`, a leftover of diagnosis card t_db672361. Task 0 makes the default the whole `test/` directory. Is it OK to change this while t_db672361 may still be open?

## ANNAHME index (to check during the build)

| Id | Assumption | Where to check | Task |
|---|---|---|---|
| C1 | Connector 3.x coordinates and API names (`PushService`, `PushEndpoint.url`, `PushMessage.content`, `tryUseCurrentOrDefaultDistributor`, `register`, `unregister`), minSdk ≤ 24 | codeberg.org/UnifiedPush/android-connector release + KDoc | 8 |
| C2 | Plain (unencrypted) JSON still reaches `onMessage` (`decrypted=false`) | connector source | 8 |
| C3 | The ntfy app accepts the `http://` tailnet server and issues `…/up…?up=1` endpoints | Handoff §8.4.1 | 13 |
| B1 | Network during the push in Doze (distributor temporary allowlist) | Handoff 2b | 13 |
| B2 | The headless `FlutterEngine` auto-registers `shared_preferences` + `flutter_secure_storage` | Handoff 2c | 8/13 |
| B3 | `ConnectionManager.create` is UI-free | `connection_manager.dart:285-335` | 8 |
| D1 | `FlutterSecureCredentialStore(storage:)` honours a separate namespace, outside backups | `connection_manager.dart:33-80`, `config_backup_service.dart` | 4 |
| T0 | The `pr-quality.yml` hard-coded test path is a leftover of t_db672361 | `git log` of the file | 0 |
| S1 | `CompactSwitchListTile` is findable as `SwitchListTile` | `compact_switch.dart:38` | 9 |
| W1 | `HomeScreen` is constructed in `WingAppState.build` | `grep -n "HomeScreen(" lib/main.dart` | 10 |
| W2 | `ProfileWorkspaceData.scope` / `.sessions` exist with these names | `profile_workspace_controller.dart:270-310` | 10 |
| N1 | `ic_stat_wing_input` is the right small icon | Birk at the screenshot review | 8/13 |
| Q1 | `SavedConnection` named parameters for the dashboard port and credentials | `connection_manager.dart` `SavedConnection` | 13 |
| Q2 | Cleartext to `127.0.0.1` is allowed | `android/app/src/main/res/xml/` | 13 |

## Self-review notes

- **Spec coverage.** Each contract section maps to tasks:
  - §2.1 → Global Constraints and file structure.
  - §2.2 → Task 7, plus the Task 9 hidden test.
  - §2.3 → Task 12.
  - §2.4 → Task 12.
  - §3.1–3.4 → Task 3.
  - §3.2 device id → Task 4.
  - §4 → Task 2.
  - §5.1 → Tasks 7 and 8.
  - §5.2 → Task 1.
  - §6.1–6.3 → Tasks 5, 6 and 8.
  - §6.4 → Task 11 (gated).
  - §6.5 → Task 6.
  - §6.6 → Tasks 6 and 10.
  - §6.7 → Tasks 5 and 6.
  - §6.8 → Tasks 4 and 6.
  - §7 → Task 9.
  - §8.2 → the mapping table.
  - §8.3–8.5 → Task 13.
  - §10 unknown kinds and actions → the Task 2 test.
- **Not implemented, deliberately:**
  - Wing-side quiet-hours suppression, and showing the cap or the trial/live mode (contract §1 and §7).
  - A local copy of the quiet hours.
  - Any German text built in Wing beyond the six contract-named strings.
- **Known limit:** if the headless engine itself fails to start, no notification appears for that push. Dart-side failures still produce the neutral notice. A native fallback was left out to keep notice-id parsing in one place (Dart).

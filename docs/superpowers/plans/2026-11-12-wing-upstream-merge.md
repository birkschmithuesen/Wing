# Wing upstream merge (t_d1d49ff1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge `upstream/main` (tarkilhk/Wing) into the fork line `voice-offline` with one `git merge`, keep
every voice/car-mode/fork feature working on top of upstream's rewritten chat/gateway/voice code, get
`bash tools/factory/ci-suite.sh` green and hand Birk a signed APK for the phone self-test.

**Architecture:** Resolve the 94 conflict blocks and the `voice_preferences.dart` modify/delete exactly as the
spec's Table B says (upstream side + thin fork hooks), commit the merge, then repair in separate commits what
the merge breaks without markers: silent losses (spec §6), API-surface breaks in fork-owned files (spec §7),
the voice-settings seam (spec §9.1), the chat-state adapter and auto-send seam (spec §9.2-9.3), and upstream's
new CI architecture gates (spec §11).

**Tech Stack:** Flutter/Dart (flutter_test), Kotlin (Android), Gradle, GitHub Actions; git; bash; Python 3
for small helper scripts.

**Spec:** `docs/superpowers/specs/2026-11-12-wing-upstream-merge-design.md`. It is the authority for every
block decision (Table B, IDs like `SCR-B6`), every silent loss (`S1`..`S10`), every API break (Table C) and the
OPEN questions `Q1`..`Q11` with their defaults. Read §0, §5, §6, §7, §9, §11 and §13 before starting. Where a
step below says "per spec <ID>", the spec row contains the exact code to write.

## Global Constraints

- **Branch:** work branch `wt/t_d1d49ff1`, created from `origin/plan/t_dcfc9770` (= `origin/voice-offline`
  b3178398 at Stand 2026-11-12 + the spec/plan commits; Task 1). Commit only there. **Never commit to, merge into or push `voice-offline`**
  (a push there triggers `voice-apk.yml` publishing). The merge into `voice-offline` is a separate [Merge]
  card. No push except what the two factory scripts do themselves (`ci/<sha>`, `ci-voice-apk*/<sha>` refs).
- **MERGE, no rebase.** Exactly one `git merge --no-ff upstream/main`. No cherry-picks of upstream commits.
- **Stock Hermes only.** No backend patch, plugin or custom endpoint. Upstream's live-call code ships as
  upstream wrote it (Q2 default); the fork adds nothing that needs the Wing plugin.
- **One command per Bash call.** No `cd`, no `&&`/`;`/`|`, no `$VAR`, no `$( )`, no loops. Multi-step checks
  go into a small Python script under `.cc-context/` (git-excluded) run with `python3 -I`.
- **No Flutter SDK on the host.** Never plan on local `flutter`/`dart`. Suite: `bash tools/factory/ci-suite.sh`
  (pushes committed HEAD to `ci/<sha>`, runs `pr-quality.yml` on GitHub Actions; expected last line
  `ci-suite: run <id> conclusion=success …`, exit 0). It builds the **committed** HEAD: commit first. Run it
  only at **[SUITE]** checkpoints. The run takes up to ~95 min after the merge (upstream's emulator journeys):
  use the maximum Bash timeout and, if it times out, re-attach with `gh run watch <id> -R birkschmithuesen/Wing`.
- **Native compile/APK:** `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false` (compile) and
  `publish=true` (APK to branch `voice-apk-bin`), expected last line
  `dispatch-check: voice-apk.yml run <id> conclusion=success …`. Only at **[NATIVE]** checkpoints.
- **OPEN questions:** every task that depends on one names it and implements its **default** (spec §13). If
  Birk's answer differs when the task starts, follow the answer and note it in the commit body. Q8 gates the
  phone install. Q11 is a stop-and-ask, never a default.
- **Comments/identifiers/commits in English** (docs/refactoring-guidelines.md §7). Commit bodies list the
  spec IDs handled. End every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Changelog rule (AGENTS.md):** the card's final commit set must add a `CHANGELOG.fork.md` entry (What, Why,
  merge commit hash, card t_d1d49ff1) — Task 13.
- **Architecture census:** after every task that adds or deletes a file, `python3 tools/architecture/rules/authored_census.py`
  must print nothing (from Task 12 on; before that the census is known red).
- Phone tests are Birk's. The implementer never installs or drives the phone.

## Interfaces introduced by this plan (all tasks use these names)

| name | file | signature |
|---|---|---|
| `VadVoiceInputSettings` | `lib/core/models/voice_processing_settings.dart` | `final class VadVoiceInputSettings extends VoiceInputSettings { const VadVoiceInputSettings(); }` |
| `VoiceLocalEngine` | `lib/voice_offline/voice_offline_prefs.dart` | `enum VoiceLocalEngine { system, parakeet }` |
| `VoiceOfflinePrefs.localEngineKey` / `.localEngine` | same | `static const localEngineKey = 'voice.local_engine'`; `final VoiceLocalEngine localEngine` (default `system`) |
| `VoiceOfflinePrefs.migrateLegacyVadRoute` | same | `static Future<void> migrateLegacyVadRoute(SharedPreferences preferences)` |
| `voiceInputSettingsFor` | `lib/voice_offline/voice_input_settings_for.dart` | `VoiceInputSettings? voiceInputSettingsFor(AppPreferences app, SharedPreferences preferences)` |
| `VadInputRound.roundSettings` | `lib/voice_offline/vad_input_round.dart` | ctor param `VoiceOfflinePrefs Function()? roundSettings`; method `VoiceOfflinePrefs roundSettings()` |
| `ChatVoiceView` getters | `lib/voice_offline/chat_voice_view.dart` | `voiceBusy`, `voiceDraft`, `needsUserInput`, `voiceOpening`, `voiceOffline`, `voiceCommandRunning`, `voiceChangingAnswer`, `voiceEditingQueue`, `voiceTurnEnded`, `listenState` |
| `WorkspaceVoiceHost.liveVoiceActive` | `lib/voice_offline/workspace_voice_driver.dart` | `bool get liveVoiceActive;` |
| `TransientSend` | `lib/fork/transient_send.dart` | `static void mark(Object chat)`, `static bool take(Object chat)` |
| `VoiceChannel.pauseOffline()` / `resume()` | `VoiceChannel.kt` | `fun pauseOffline()`, `fun resume()` |
| `VoicePlayback` keep-voice | `VoicePlayback.kt` | ctor param `keepsVoice: () -> Boolean = { false }`; `fun stop(owner: String? = null, force: Boolean = false)` |
| `guiSessionSource` | `lib/core/services/wing_session_source.dart` | `const String guiSessionSource = 'gui';` |

---

### Task 1: Preflight — branch, refs, re-measure

**Files:** none changed.

- [ ] **Step 1: Create the work branch from the plan branch**

The spec and this plan exist only on `origin/plan/t_dcfc9770` (= `voice-offline` b3178398 + docs-only
commits). Branch from there so the docs travel with the merge; the [Merge] card brings them into
`voice-offline`.

Run: `git fetch origin`
Run: `git fetch upstream`
Run: `git switch -c wt/t_d1d49ff1 origin/plan/t_dcfc9770`
Expected: `Switched to a new branch 'wt/t_d1d49ff1'`; `git merge-base --is-ancestor b3178398 HEAD` exits 0.
If the worktree already exists on `wt/t_d1d49ff1` at `voice-offline`: `git merge --ff-only origin/plan/t_dcfc9770`.

- [ ] **Step 2: Record the refs**

Run: `git rev-parse HEAD origin/voice-offline upstream/main`
Run: `git merge-base HEAD upstream/main`
Expected Stand 2026-11-12: HEAD = origin/voice-offline = `b3178398…`, upstream = `e8a4089c…`, base
`151ee281…`. If `voice-offline` is ahead of b3178398 (another card merged), that is fine: continue, Step 3
measures the real state. Write the four hashes into the task notes.

- [ ] **Step 3: Probe the merge without touching the worktree**

Run: `git merge-tree --write-tree --name-only HEAD upstream/main`
Expected: exit 1, first line = tree hash, then the conflicting paths. Stand 2026-11-12: exactly the 22 paths
of the spec's File-ID table.

Then count blocks per file in the probe tree (one call per conflicting path, or all at once):
Run: `git grep -c "^<<<<<<< " <tree-hash> -- .github AGENTS.md android lib test`
Expected: per-file counts equal the spec's File-ID table (sum 94; `voice_preferences.dart` has none).

- [ ] **Step 4: Decide whether the spec still applies**

If `upstream/main` ≠ e8a4089c or the counts differ: list the new/changed conflict files and blocks
(`git log --oneline e8a4089c..upstream/main -- <file>` for each). Blocks whose upstream side changed need a
fresh row; if more than 10 blocks or any new conflict file outside the spec's table appear, stop and report
`FRAGE: upstream moved (<n> new blocks in <files>); re-plan or continue with per-block judgement?`. Otherwise
note the deltas and continue. Line ranges in Table B will shift by the deltas; block numbering inside a file
stays the reference.

---

### Task 2: Start the merge; resolve CI, repo docs and build (PRQ, AGT, GRD)

**Merge-in-progress rule (Tasks 2-7):** the merge stays uncommitted until Task 8. Each task resolves its files
and stages them with `git add <file>` (or `git rm`); it does **not** run `git commit`, `git merge --abort`,
`git stash` or `git checkout -- <file>` on other tasks' files. The staged index is the checkpoint.

**Files:**
- Modify: `.github/workflows/pr-quality.yml` (PRQ-B1, PRQ-B2)
- Modify: `AGENTS.md` (AGT-B1)
- Modify: `android/app/build.gradle.kts` (GRD-B1)

- [ ] **Step 1: Start the merge**

Run: `git merge --no-ff --no-commit upstream/main`
Expected: `Automatic merge failed; fix conflicts and then commit the result.`
Run: `git diff --name-only --diff-filter=U`
Expected: the 22 paths (Task 1).

- [ ] **Step 2: PRQ-B1** — take the upstream line (`flutter build apk --debug --no-pub 2>&1 | tee android_build_output.txt` step body); delete ours.

- [ ] **Step 3: PRQ-B2** — take the upstream block, then append the spec's Appendix B snippet inside the same
`run: |` of step "Failure summary" after upstream's `for check in …; done`. Step ids used by the snippet exist
upstream (`analyze`, `test`, `android_build`, `native_test`; verified at e8a4089c lines 127-157).

- [ ] **Step 4: AGT-B1** — keep upstream's file text, keep our `# Fork changelog` section verbatim, and add after it:

```markdown
# Fork notes

- Wing Voice targets stock Hermes. Upstream's live voice call needs the Wing Hermes plugin; fork work does
  not depend on or extend it.
- `docs/DESIGN_SYSTEM.md` and the administration handoff were removed upstream (moved to a private
  workspace). Public UI references: `docs/features/ui-foundations.md`, `docs/FEATURE_MAP.md`.
- Upstream's `scripts/wing_save.py` and private `internal/` workflow do not apply to the fork factory.
```

- [ ] **Step 5: GRD-B1** — keep both lines, upstream first:

```kotlin
// Correct the upstream animation-cache lifetime (kept from upstream).
apply(from = rootProject.file("ime-cache-fix.gradle.kts"))

// Fork (Wing Voice): own build additions, see voice-offline.gradle.
apply(from = "voice-offline.gradle")
```
(Keep upstream's own comment line text above its `apply` if it differs from the first line shown.)

- [ ] **Step 6: Verify and stage**

Run: `git grep -n -E "^(<<<<<<<|=======|>>>>>>>)" -- .github/workflows/pr-quality.yml AGENTS.md android/app/build.gradle.kts`
Expected: no output.
Run: `git grep -n "apply(from" -- android/app/build.gradle.kts`
Expected: two lines, `ime-cache-fix.gradle.kts` before `voice-offline.gradle`.
Run: `git grep -n "Fork changelog" -- AGENTS.md`
Expected: one hit.
Run: `git add .github/workflows/pr-quality.yml AGENTS.md android/app/build.gradle.kts`

---

### Task 3: Resolve Android voice (VCA, VCH, VPB) + native silent losses S1, S2, S3, S6

**Files:**
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceCapture.kt` (VCA-B1..B6, S1)
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt` (VCH-B1..B4, S2, S6)
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/VoicePlayback.kt` (VPB-B1, VPB-B2, S6)
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/MainActivity.kt` (S6: `pauseOffline()` call; no conflict)
- Modify: `android/app/src/main/AndroidManifest.xml` (S3; no conflict)

**Interfaces:** Produces `VoiceChannel.pauseOffline()`, `VoiceChannel.resume()`, `VoicePlayback(activity, ::emit, keepsVoice = …)`, `VoicePlayback.stop(owner: String? = null, force: Boolean = false)`, `VoiceCapture.stop(owner, timeoutMs, completed)`.

- [ ] **Step 1: VoiceCapture.kt** — resolve VCA-B1..B6 per spec (imports without `java.io.File`; `available()`
with `recognitionAvailable`; `languages()` with `onDeviceRecognition`; upstream recorder + `createRecognizer`;
async `stop(owner, timeoutMs = 5000L, completed)` with `arm(attempt, timeoutMs, …)`; `transcript` with
`cleanTranscript` and the empty-partial skip). Then S1 outside the markers:

```kotlin
// in started(): replaces arm(attempt, 125000, …)
arm(attempt, (MAX_RECORDING_MS + RECORDING_DEADLINE_BUFFER_MS).toLong(), "Recording reached its time limit. Please try a shorter recording.")
// in the file-recorder branch: replaces capture.setMaxDuration(120000)
capture.setMaxDuration(MAX_RECORDING_MS)
```

- [ ] **Step 2: VoicePlayback.kt** — VPB-B1 (`segments` parameter, `val attempt = claim(owner, response)`),
VPB-B2 (`LanguageSpeech.enqueue(tts!!, attempt.generation.toString(), text, segments, voice)`,
`finishPlayback(attempt, …)`). S6:

```kotlin
class VoicePlayback(
    private val activity: Activity,
    private val emit: (Map<String, Any>) -> Unit,
    // Fork (Wing Voice): conversation mode keeps reading aloud while the Activity is paused.
    private val keepsVoice: () -> Boolean = { false },
) {
```
and in upstream's `stop`, change the signature to `fun stop(owner: String? = null, force: Boolean = false)`
with first statement `if (owner == null && !force && keepsVoice()) return` (keep upstream's body after it; if
upstream's `stop` already has an `owner` parameter, add only `force` and the guard). Every caller other than
`VoiceChannel.pause()` passes `force = true`; find them with
`git grep -n "playback.stop(" -- android/app/src/main/kotlin`.

- [ ] **Step 3: VoiceChannel.kt** — VCH-B1..B4 per spec. Field:
`private val playback = VoicePlayback(activity, ::emit, keepsVoice = { offline.keepsVoice() })`.
`pause()` stays upstream's literal body. Add:

```kotlin
    /** Fork (Wing Voice): VAD/media-key pause, separate from the guarded pause(). */
    fun pauseOffline() {
        if (closed) return
        if (!offline.keepsVoice()) offline.pauseVad()
        offline.pauseMediaKeys()
    }

    fun resume() {
        if (!closed) offline.resume()
    }
```
S2: change the guard to `call.method in listOf("start", "startVad", "openMicLink", "speak", "play")`.
`"stop"` passes `call.argument<Number>("timeoutMs")?.toLong() ?: 5000L`. Keep upstream's
`requestLivePermissions` case.

- [ ] **Step 4: MainActivity.kt (S6)** — in `onPause`, directly after the existing statement
`voiceChannel?.pause()`, add `voiceChannel?.pauseOffline()`. Keep `voiceChannel?.resume()` in `onResume`.

- [ ] **Step 5: AndroidManifest.xml (S3)** — delete our three duplicate lines
`BLUETOOTH_CONNECT`, `MODIFY_AUDIO_SETTINGS`, `FOREGROUND_SERVICE_MICROPHONE` (the ones from the fork block;
keep upstream's block).

- [ ] **Step 6: Verify and stage**

Run: `git grep -n -E "^(<<<<<<<|=======|>>>>>>>)" -- android`
Expected: no output.
Run: `git grep -n -E "125000|setMaxDuration\(120000\)" -- android/app/src/main/kotlin`
Expected: no output.
Run: `git grep -n "MAX_RECORDING_MS" -- android/app/src/main/kotlin/com/tarkilhk/wing/VoiceCapture.kt`
Expected: the constant declaration plus the `arm(` and `setMaxDuration(` uses.
Run: `git grep -n "audioOwned" -- android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt`
Expected: one line containing `"startVad"` and `"openMicLink"`.
Run: `git grep -n "requestLivePermissions" -- android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt`
Expected: at least one hit.
Run: `git grep -n "LanguageSpeech.enqueue" -- android/app/src/main/kotlin/com/tarkilhk/wing/VoicePlayback.kt`
Expected: one hit containing `attempt.generation.toString()`.
Run: `git grep -n "java.io" -- android/app/src/main/kotlin/com/tarkilhk/wing/VoiceCapture.kt android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt android/app/src/main/kotlin/com/tarkilhk/wing/VoicePlayback.kt`
Expected: no output.
Run: `git grep -c -E "android.permission.(MODIFY_AUDIO_SETTINGS|FOREGROUND_SERVICE_MICROPHONE|BLUETOOTH_CONNECT)\"" -- android/app/src/main/AndroidManifest.xml`
Expected: `…AndroidManifest.xml:3`.
Run: `git grep -n "voiceChannel?" -- android/app/src/main/kotlin/com/tarkilhk/wing/MainActivity.kt`
Expected: `pause()`, `pauseOffline()`, `resume()`, `leaveForeground()`, `close()`, `permissionResult(` present.
Run: `git add android/app/src/main/kotlin/com/tarkilhk/wing/VoiceCapture.kt android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt android/app/src/main/kotlin/com/tarkilhk/wing/VoicePlayback.kt android/app/src/main/kotlin/com/tarkilhk/wing/MainActivity.kt android/app/src/main/AndroidManifest.xml`

---

### Task 4: Resolve voice Dart (VIC, VOC, VPF, VPC, TVF, TVP, TVX)

Depends on: Q1 (default A: engine row), Q5 (default A: notice).

**Files:**
- Modify: `lib/core/controllers/voice_input_controller.dart` (VIC-B1..B8)
- Modify: `lib/core/controllers/voice_output_controller.dart` (VOC-B1, VOC-B2)
- Delete: `lib/core/services/voice_preferences.dart` (VPF)
- Modify: `lib/core/widgets/voice_preferences_card.dart` (VPC-B1..B4)
- Modify: `lib/core/models/voice_processing_settings.dart` (no conflict; add the marker)
- Modify: `lib/core/services/voice_preferences_session.dart` (no conflict; one getter)
- Modify: `test/support/voice_fixture.dart` (TVF-B1), `test/voice_preferences_test.dart` (TVP-B1..B3), `test/voice_processing_test.dart` (TVX-B1..B10)

**Interfaces:** Produces `VadVoiceInputSettings`; consumes `VadInputRound.roundSettings()` (implemented in
Task 9 — the merge commit may not compile until then; that is expected), `VoiceOfflineInputRows` and
`VoiceOfflineSettings(part:, session:)` (Task 9).

- [ ] **Step 1: Marker class** — append to `lib/core/models/voice_processing_settings.dart` (no import):

```dart
/// Fork (Wing Voice): local recognition through the on-phone VAD + Parakeet
/// route. Field-less: this library is domain-only; the round reads its
/// settings from VadInputRound.roundSettings.
final class VadVoiceInputSettings extends VoiceInputSettings {
  const VadVoiceInputSettings();
}
```

- [ ] **Step 2: voice_input_controller.dart** — VIC-B1..B8 per spec. The VIC-B6 switch:

```dart
    switch (settings) {
      case VadVoiceInputSettings():
        final offline = vadRound!.roundSettings();
        maxSeconds = offline.vad.maxDuration.inSeconds;
        final current = await vadRound!.begin(
          id,
          offline,
          isCurrent: () => _id == id && !_disposed,
        );
        if (!current) return;
      case LocalVoiceInputSettings(:final language):
        maxSeconds = maxRecordingSeconds;
        await device.start(id, local: true, language: language);
      case HermesVoiceInputSettings():
        maxSeconds = maxRecordingSeconds;
        _remote = createRemote();
        await device.start(id, local: false, language: '');
    }
```
Outside the markers: `stopHandsFree`/`_vadTranscribing` assign `_phase`, not `phase`. Q5 default A: route VAD
no-speech to upstream's notice — pass `noSpeech: () => _emptyResult(VoiceInputEmptyResult.noSpeech)` to
`vadRound!.forceEnd(...)`/`onEvent(...)` (the callback parameter is added to `VadInputRound` in Task 9).

- [ ] **Step 3: voice_output_controller.dart** — VOC-B1, VOC-B2 per spec (`Future<bool> speak`,
`Future<bool> _play` with `finished`). Keep the MEDIA filter in `spokenReplyText`.

- [ ] **Step 4: VPF** — Run: `git rm lib/core/services/voice_preferences.dart`

- [ ] **Step 5: voice_preferences_session.dart** — add next to the other getters:

```dart
  /// Fork (Wing Voice): the device the fork settings rows probe and preview with.
  VoiceDevice get device => _device;
```
(If the field has another name, use it; `git grep -n "VoiceDevice" -- lib/core/services/voice_preferences_session.dart` shows it.)

- [ ] **Step 6: voice_preferences_card.dart** — VPC-B1..B4 per spec: upstream file + import
`'../../voice_offline/voice_offline_settings.dart'` + the two hooks:

```dart
            if (state.input.selected == AppVoiceProcessing.local)
              VoiceOfflineInputRows(session: _session),
```
after the input description, and

```dart
            VoiceOfflineSettings(
              part: VoiceOfflineSettingsPart.replies,
              session: _session,
            ),
```
after the output description. (Exact field names: read `state` in `build`; `git grep -n "selected" -- lib/core/services/voice_preferences_session.dart`.)

- [ ] **Step 7: Tests** — TVF-B1 (keep `lastStopTimeout = timeout;` then `if (recording != id) return null;`),
TVP-B1..B3 and TVX-B1..B10 take upstream.

- [ ] **Step 8: Verify and stage**

Run: `git grep -n -E "^(<<<<<<<|=======|>>>>>>>)" -- lib/core/controllers lib/core/widgets/voice_preferences_card.dart test/support/voice_fixture.dart test/voice_preferences_test.dart test/voice_processing_test.dart`
Expected: no output.
Run: `git grep -n -E "Future<bool> (speak|_play)\(" -- lib/core/controllers/voice_output_controller.dart`
Expected: 2 hits.
Run: `git grep -n "mediaReferencePattern" -- lib/core/controllers/voice_output_controller.dart`
Expected: at least 1 hit.
Run: `git grep -n -E "seconds >= 120|_seconds >= 120" -- lib/core/controllers`
Expected: no output.
Run: `git grep -n -E "class VadVoiceInputSettings|^import" -- lib/core/models/voice_processing_settings.dart`
Expected: the class line; no new import.
Run: `git add lib/core/controllers/voice_input_controller.dart lib/core/controllers/voice_output_controller.dart lib/core/widgets/voice_preferences_card.dart lib/core/models/voice_processing_settings.dart lib/core/services/voice_preferences_session.dart test/support/voice_fixture.dart test/voice_preferences_test.dart test/voice_processing_test.dart`

---

### Task 5: Resolve the workspace screen (SCR-B1..B22)

Depends on: Q3 (default A), Q4 (default B — screen side needs nothing either way).

**Files:**
- Modify: `lib/core/screens/profile_workspace_screen.dart` (SCR-B1..B22 + the live-call `prepare:` hook outside the markers)
- Modify: `lib/core/widgets/voice_input_activity.dart` (S9; upstream file, no conflict)

**Interfaces:** Consumes `WorkspaceVoiceHost` (driver, adapted in Task 10), `voiceInputSettingsFor` (Task 9),
`VadInputRound(roundSettings:)` (Task 9). Produces host members `dictate(chat, {resume})`,
`performComposerAction(chat, action, {conversation})`, `composerActions(chat)`, `liveVoiceActive`.

- [ ] **Step 1: Fields, constructor, state head** — SCR-B1, SCR-B2, SCR-B3, SCR-B4 per spec. In SCR-B4 the
`VadInputRound` gets `roundSettings: () => _voice.car.roundSettings(VoiceOfflinePrefs.read(controller.preferences)),`.

- [ ] **Step 2: Workspace listeners** — SCR-B5 (keep `_voiceWorkspaceChanged` via `ChatVoiceView` getters,
keep upstream `_syncVoiceTarget`, `void _cancelVoice() => _voice.cancel();`).

- [ ] **Step 3: Dictation, read-aloud, recording rows** — SCR-B6 (new `dictate` on upstream's
`_voiceInput.dictate`, alias `_requestDictation`), SCR-B7 (`_requestReadAloud` body with `endLoop`, queue
clears, `_voiceOwner`), SCR-B8 (`..._voice.listeningRows(),` + upstream `VoiceInputActivity`), SCR-B9
(`onPressed: _voice.stopSpeech`). Add the live-voice host getter next to the other overrides:

```dart
  @override
  bool get liveVoiceActive =>
      LiveVoiceScope.maybeOf(context)?.session.active == true;
```

- [ ] **Step 4: Lifecycle** — SCR-B10 (our 4 initState lines, then upstream's 2), SCR-B11 (`_voice.lifecycle(state)`
before `final active`, VAD/media-key sync after `_appIsActive` update), SCR-B12 (dispose edits), SCR-B13
(delete ours), SCR-B14 (`?_recentVisit` added to our merge list).

- [ ] **Step 5: Menu and message list** — SCR-B15/B16 (upstream menu + `car` item/branch), SCR-B17/B18
(upstream).

- [ ] **Step 6: Composer** — SCR-B19 (upstream; then in the live-call button's `prepare:` closure make
`_voice.cancel();` the first statement — Q3 default A), SCR-B20 (upstream + `composerActions` delegate +
public `performComposerAction`), SCR-B21, SCR-B22 (upstream).

- [ ] **Step 7: voice_input_activity.dart (S9)** — replace the hard-coded `'/ 120s'` with
`'/ ${controller.maxSeconds}s'`.

- [ ] **Step 8: Verify and stage**

Run: `git grep -n -E "^(<<<<<<<|=======|>>>>>>>)" -- lib/core/screens/profile_workspace_screen.dart`
Expected: no output.
Run: `git grep -n -E "_dictate\(|_readAloud\(|VoicePreferences|HermesVoice\.forConnection|_performComposerAction" -- lib/core/screens/profile_workspace_screen.dart`
Expected: no output.
Run: `git grep -n -E "@override|liveVoiceActive|composerActions\(|performComposerAction\(" -- lib/core/screens/profile_workspace_screen.dart`
Expected: `liveVoiceActive` getter, `composerActions` delegating to `_composerActionLabels`, one `performComposerAction(` declaration.
Run: `git grep -n -E "_voice\.(cancel|attach|attachRoute|syncVadRoute|syncMediaKeys|lifecycle|detach|releaseDevice|disposeCar|enterCarMode|listeningRows|stopSpeech)" -- lib/core/screens/profile_workspace_screen.dart`
Expected: each name at least once.
Run: `git grep -n "120s" -- lib/core/widgets/voice_input_activity.dart`
Expected: no output.
Run: `git add lib/core/screens/profile_workspace_screen.dart lib/core/widgets/voice_input_activity.dart`

---

### Task 6: Resolve controller, gateway, registry and their test fixtures (CTL, GWY, REG, TCA, TBF)

Depends on: Q6 (default B), Q7 (default A).

**Files:**
- Modify: `lib/core/services/profile_workspace_controller.dart` (CTL-B1..B9; NetworkGate hooks in `_composerRuntime`; S10 in `resumeConnection`)
- Modify: `lib/core/services/profile_gateway.dart` (GWY-B1..B4)
- Modify: `lib/core/services/wing_session_source.dart` (`guiSessionSource`)
- Modify: `lib/core/services/profile_workspace_registry.dart` (REG-B1)
- Modify: `test/profile_composer_actions_test.dart` (TCA-B1), `test/support/profile_browser_fixture.dart` (TBF-B1)

**Interfaces:** Consumes `TransientSend.mark/take` (Task 11), `CompletedReplies.offer` (existing).

- [ ] **Step 1: Controller blocks** — CTL-B1..B9 per spec. Take upstream in CTL-B3, CTL-B4, CTL-B5, CTL-B8.
CTL-B6 hook before `final notification = _notification(`:

```dart
    if (!failed && !cancelled && finalText.trim().isNotEmpty && !_closed) {
      _completedReplies.offer(chat, finalText);
    }
```
CTL-B7: after upstream's first guard in `_scheduleReconnect`:
```dart
    // Fork (NetworkGate): no timer retries while Android reports no network;
    // networkRestored() + resumeConnection(networkChanged: true) retries.
    if (!connectionStatus.networkAvailable) return;
```
CTL-B9: `unawaited(_completedReplies.close());` first.

- [ ] **Step 2: NetworkGate hooks outside the markers** — in `_composerRuntime(...)` append
`&& connectionStatus.networkAvailable` to the `connected:` expression and to the `automaticDrainAvailable:`
expression. In `resumeConnection(...)` add as first statement after its own guards:
`if (networkChanged) connectionStatus.networkRestored();` (S10).

- [ ] **Step 3: Q6 hooks (default B)** — in `_sendPrompt`'s catch (upstream body), where the failure is settled
as definitely unsent (`!submitted`), add `if (isTemporaryWorkspaceFailure(error)) TransientSend.mark(chat);`.
In `_performReconnect`, in the loop that drains `resumedChats`, before `await _drainQueuedPrompts(chat);` add
`if (TransientSend.take(chat)) await resumeQueue(chat);`. Import `'../../fork/transient_send.dart'`. Remove the
import of `'../../fork/offline_queue.dart'`.

- [ ] **Step 4: Gateway** — GWY-B1 (both imports; Task 12 turns `wing_session_source.dart` into a part),
GWY-B2 (`gateway.noteReady(ready);` after `requireCurrent();`), GWY-B3 (`'source': sourceFor(guiSessionSource)`),
GWY-B4 (`'source': ?(wingSourceAdvertised ? wingSessionSource : null),`). Add to
`lib/core/services/wing_session_source.dart`:

```dart
/// Upstream's source for sessions created by the browser command (stock fallback).
const String guiSessionSource = 'gui';
```

- [ ] **Step 5: Registry and fixtures** — REG-B1 (`if (networkChanged) owner.networkRestored();` as first loop
statement), TCA-B1 (only `final steerRequests = …;`), TBF-B1 (all five imports).

- [ ] **Step 6: Verify and stage**

Run: `git grep -n -E "^(<<<<<<<|=======|>>>>>>>)" -- lib/core/services test/profile_composer_actions_test.dart test/support/profile_browser_fixture.dart`
Expected: no output.
Run: `git grep -n -E "networkAvailable|networkRestored" -- lib/core/services/profile_workspace_controller.dart lib/core/services/profile_workspace_registry.dart`
Expected: `_scheduleReconnect` guard, two `_composerRuntime` uses, `resumeConnection` hook, `networkRestored()` definition, registry `if (networkChanged) owner.networkRestored();`.
Run: `git grep -n -E "_completedReplies" -- lib/core/services/profile_workspace_controller.dart`
Expected: field, getter, `.offer(chat, finalText)`, `.close()`.
Run: `git grep -n -E "queuedHeadDelivered|fork/offline_queue|quietTransientFailure|_maxRecoveryRetries" -- lib`
Expected: no output.
Run: `git grep -n -E "noteReady|sourceFor\(|wingSourceAdvertised" -- lib/core/services/profile_gateway.dart lib/core/services/profile_workspace_controller.dart`
Expected: `noteReady(ready)`, `sourceFor(guiSessionSource)`, the resume `source` entry, controller `sourceFor(desktopSessionSource)`.
Run: `git grep -c "steerResult" -- test/support/profile_browser_fixture.dart test/profile_composer_actions_test.dart`
Expected: the declaration only in `profile_browser_fixture.dart`.
Run: `git add lib/core/services/profile_workspace_controller.dart lib/core/services/profile_gateway.dart lib/core/services/wing_session_source.dart lib/core/services/profile_workspace_registry.dart test/profile_composer_actions_test.dart test/support/profile_browser_fixture.dart`

---

### Task 7: Resolve the message widgets (DLA, MMC, PMS)

Depends on: Q4 (default **B**: keep our full-width thumbnail). If Birk chose A before this task starts, take
the upstream files as they are and skip Step 2.

**Files:**
- Modify: `lib/core/widgets/deliverable_attachment.dart` (DLA-B1..B4)
- Modify: `lib/core/widgets/markdown_message_content.dart` (MMC-B1..B6)
- Modify: `lib/core/widgets/profile_message.dart` (PMS-B1, PMS-B2)
- Modify: `lib/fork/inline_media_thumbnail.dart` (loader signature `(String path)`)

- [ ] **Step 1: Take upstream in every block** of the three widget files; remove `onLoadRemoteImage` /
`onLoadImage` remnants and the old `InlineMediaThumbnail` tail in `deliverable_attachment.dart`.

- [ ] **Step 2: Q4=B hook** — in `deliverable_attachment.dart`, in upstream's image branch
(`if (output.kind == ChatOutputKind.image)`), when `widget.loadImage != null` and
`InlineMediaThumbnail.handles(output)` return our widget instead of `ChatInlineImage`:

```dart
    final load = widget.loadImage;
    if (output.kind == ChatOutputKind.image &&
        load != null &&
        InlineMediaThumbnail.handles(output)) {
      // Fork (Wing Voice): full-width thumbnail with Download/Open preview row.
      return InlineMediaThumbnail(
        output: output,
        load: (_) => load(output.path!),
        onOpen: widget.onOpen,
        onDownload: widget.onDownload,
      );
    }
```
Adapt `InlineMediaThumbnail`'s constructor names to the ones in `lib/fork/inline_media_thumbnail.dart`
(`git grep -n "InlineMediaThumbnail(" -- lib/fork/inline_media_thumbnail.dart`); keep its `load` callback
type `Future<Uint8List> Function(ChatOutput)` so its test stays valid. Re-add
`import '../../fork/inline_media_thumbnail.dart';`.

- [ ] **Step 3: Verify and stage**

Run: `git grep -n -E "^(<<<<<<<|=======|>>>>>>>)" -- lib/core/widgets`
Expected: no output.
Run: `git grep -n -E "onLoadRemoteImage|onLoadImage" -- lib test`
Expected: no output.
Run: `git grep -n "InlineMediaThumbnail" -- lib/core/widgets`
Expected (Q4=B): the import and the one use in `deliverable_attachment.dart`. (Q4=A: no output.)
Run: `git add lib/core/widgets/deliverable_attachment.dart lib/core/widgets/markdown_message_content.dart lib/core/widgets/profile_message.dart lib/fork/inline_media_thumbnail.dart`

---

### Task 8: Commit the merge

**Files:** none new.

- [ ] **Step 1: No unmerged path, no marker anywhere**

Run: `git diff --name-only --diff-filter=U`
Expected: no output.
Run: `git grep -n -E "^(<<<<<<<|>>>>>>>) " -- .`
Expected: no output.

- [ ] **Step 2: Table A deletions are in place** (spec §4 / Appendix A)

Run: `git ls-files -- lib/core/models/session.dart lib/core/services/gateway_turn_coordinator.dart docs/DESIGN_SYSTEM.md docs/TESTING.md lib/core/services/voice_preferences.dart android/app/src/main/res/drawable-v21/launch_background.xml`
Expected: no output.
Run: `git grep -n -E "models/(session|gateway_turn_contract|hermes_project)\.dart|gateway_turn_|text_size_preference|profile_color_store|profile_selection_store|services/voice_preferences\.dart" -- lib test`
Expected: no output.

- [ ] **Step 3: Commit** (the tree is expected not to compile yet; Tasks 9-12 repair it)

```bash
git commit -F .cc-context/merge-msg.txt
```
with `.cc-context/merge-msg.txt` (write it with the Write tool first):

```
merge: upstream/main <sha> into voice-offline line (t_d1d49ff1)

Merge of tarkilhk/Wing upstream/main (<sha>, <n> commits) per
docs/superpowers/specs/2026-11-12-wing-upstream-merge-design.md.

Taken from upstream (dropping our variant, upstream already solves it):
- CTL-B5: own _drainQueuedPrompts loop incl. the t_f0c1d125 offlineSnapshot
  guard -> ComposerSession.drain gated by automaticDrainAvailable.
- CTL-B8: history-text resolution of an uncertain queue head
  (lib/fork/offline_queue.dart) -> idempotent replay by submission_id.
- SCR-B19: composer toolbar mic entry -> upstream VoiceInputButton.
- SCR-B7 parts: read-aloud toggle/cancel/admission -> _voiceOutput.readAloud.
- MMC-B2/B3/B5/B6, PMS-B1: image plumbing names -> upstream loadImage.
Upstream behaviour kept over base code: 'no_speech' notice (VCA-B4),
unlimited capped reconnect backoff (CTL-B7), session.create source 'gui'
(GWY-B3), VoiceInputActivity recording chrome (SCR-B8), minSdk 29.
Re-hung fork functions: see spec Table B rows marked "re-hang".
OPEN defaults used: Q1=A Q2=A Q3=A Q4=<A|B> Q5=A Q6=B Q7=A Q9=A.
Known red until follow-up commits: Table C API breaks, census/roles.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```
(Fill `<sha>`, `<n>` from Task 1, `<A|B>` from Q4.)

Run: `git log -1 --format="%H %P"`
Expected: two parent hashes (HEAD of `voice-offline` line, upstream head). Note the merge commit hash for
Task 13.

---

### Task 9: Voice settings seam — `voice.local_engine`, migration, `voiceInputSettingsFor`, settings rows, VAD round (Q1, Q5)

**Files:**
- Modify: `lib/voice_offline/voice_offline_prefs.dart`
- Create: `lib/voice_offline/voice_input_settings_for.dart`
- Modify: `lib/voice_offline/vad_input_round.dart` (`roundSettings`, `noSpeech`)
- Modify: `lib/core/services/application_startup.dart` (one hook line)
- Modify: `lib/voice_offline/voice_offline_settings.dart` (session-based rows: `VoiceOfflineInputRows`, `VoiceOfflineSettings(part:, session:)`)
- Modify: `lib/voice_offline/barge_in_settings.dart`, `lib/car_mode/car_mode_session.dart` (drop `VoicePreferences`)
- Test: `test/voice_offline/voice_local_engine_test.dart` (create), `test/voice_offline/voice_offline_prefs_test.dart`, `test/voice_offline/voice_offline_settings_test.dart`, `test/voice_offline/transcription_deadline_test.dart`, `test/voice_vad_input_test.dart`, `test/vad_settings_test.dart`, `test/support/voice_settings_fixture.dart`, `test/support/voice_workspace_fixture.dart`
- Delete: `test/voice_offline/voice_offline_prefs_tryread_test.dart`

**Interfaces:** Produces `VoiceLocalEngine`, `VoiceOfflinePrefs.localEngineKey/localEngine/migrateLegacyVadRoute`,
`voiceInputSettingsFor`, `VadInputRound(roundSettings:)`, `VadInputRound.roundSettings()`.

- [ ] **Step 1: Write the failing test** `test/voice_offline/voice_local_engine_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/voice_processing_settings.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/voice_offline/voice_input_settings_for.dart';
import 'package:wing/voice_offline/voice_offline_prefs.dart';

void main() {
  test('legacy voice.input=vad migrates to local + parakeet, once', () async {
    SharedPreferences.setMockInitialValues({'voice.input': 'vad'});
    final prefs = await SharedPreferences.getInstance();
    await VoiceOfflinePrefs.migrateLegacyVadRoute(prefs);
    expect(prefs.getString('voice.input'), 'local');
    expect(prefs.getString(VoiceOfflinePrefs.localEngineKey), 'parakeet');
    await VoiceOfflinePrefs.migrateLegacyVadRoute(prefs);
    expect(prefs.getString('voice.input'), 'local');
  });

  test('migration leaves other input values alone', () async {
    SharedPreferences.setMockInitialValues({'voice.input': 'hermes'});
    final prefs = await SharedPreferences.getInstance();
    await VoiceOfflinePrefs.migrateLegacyVadRoute(prefs);
    expect(prefs.getString('voice.input'), 'hermes');
    expect(prefs.getString(VoiceOfflinePrefs.localEngineKey), isNull);
  });

  test('local + parakeet resolves to the VAD route, system stays local', () async {
    SharedPreferences.setMockInitialValues({
      'voice.input': 'local',
      VoiceOfflinePrefs.localEngineKey: 'parakeet',
    });
    final prefs = await SharedPreferences.getInstance();
    final app = AppPreferences(prefs);
    addTearDown(app.dispose);
    expect(voiceInputSettingsFor(app, prefs), isA<VadVoiceInputSettings>());
    await prefs.setString(VoiceOfflinePrefs.localEngineKey, 'system');
    expect(voiceInputSettingsFor(app, prefs), isA<LocalVoiceInputSettings>());
  });

  test('hermes input ignores the local engine', () async {
    SharedPreferences.setMockInitialValues({
      'voice.input': 'hermes',
      VoiceOfflinePrefs.localEngineKey: 'parakeet',
    });
    final prefs = await SharedPreferences.getInstance();
    final app = AppPreferences(prefs);
    addTearDown(app.dispose);
    expect(voiceInputSettingsFor(app, prefs), isA<HermesVoiceInputSettings>());
  });

  test('local engine accepts only system and parakeet', () {
    expect(VoiceOfflinePrefs.accepts(VoiceOfflinePrefs.localEngineKey, 'parakeet'), isTrue);
    expect(VoiceOfflinePrefs.accepts(VoiceOfflinePrefs.localEngineKey, 'system'), isTrue);
    expect(VoiceOfflinePrefs.accepts(VoiceOfflinePrefs.localEngineKey, 'vad'), isFalse);
  });
}
```
(`AppPreferences.dispose` exists upstream: `git grep -n "void dispose" -- lib/core/services/app_preferences.dart`; if it is named differently, use that name.)

- [ ] **Step 2: Implement `VoiceOfflinePrefs` additions** in `lib/voice_offline/voice_offline_prefs.dart`:
remove `import '../core/services/voice_preferences.dart';` and `tryReadVoicePreferences`; add

```dart
/// Which on-phone recognizer the Local voice input uses. [parakeet] is the
/// fork's VAD + Parakeet route (formerly `voice.input = vad`).
enum VoiceLocalEngine { system, parakeet }
```
add `static const localEngineKey = 'voice.local_engine';` to the key constants and to `keys`; add
`localEngineKey => value == 'system' || value == 'parakeet',` to `accepts`; add the field
`final VoiceLocalEngine localEngine;` (constructor default `this.localEngine = VoiceLocalEngine.system`), read as
`localEngine: preferences.getString(localEngineKey) == 'parakeet' ? VoiceLocalEngine.parakeet : VoiceLocalEngine.system,`;
and

```dart
  /// One-time move of the pre-merge route value `voice.input = vad`, which
  /// upstream's preference schema rejects, to `voice.input = local` plus
  /// `voice.local_engine = parakeet`. Idempotent; runs before AppPreferences
  /// reads the store.
  static Future<void> migrateLegacyVadRoute(
    SharedPreferences preferences,
  ) async {
    if (preferences.getString('voice.input') != 'vad') return;
    await preferences.setString(localEngineKey, 'parakeet');
    await preferences.setString('voice.input', 'local');
  }
```
Fix the doc comment "End-of-utterance settings for [VoiceInputRoute.vad]" → "for the Parakeet route".

- [ ] **Step 3: Create `lib/voice_offline/voice_input_settings_for.dart`**

```dart
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models/voice_processing_settings.dart';
import '../core/services/app_preferences.dart';
import 'voice_offline_prefs.dart';

/// Upstream's typed voice input choice, with Local narrowed to the fork's
/// Parakeet route when `voice.local_engine = parakeet`. Null means upstream
/// flags the input preference for repair.
VoiceInputSettings? voiceInputSettingsFor(
  AppPreferences app,
  SharedPreferences preferences,
) {
  final base = app.current.voiceInputSettings;
  if (base is LocalVoiceInputSettings &&
      VoiceOfflinePrefs.read(preferences).localEngine ==
          VoiceLocalEngine.parakeet) {
    return const VadVoiceInputSettings();
  }
  return base;
}
```

- [ ] **Step 4: Startup hook** — in `lib/core/services/application_startup.dart`, after
`final preferences = await SharedPreferences.getInstance();`:

```dart
  // Fork (Wing Voice): move the pre-merge `voice.input = vad` value first.
  await VoiceOfflinePrefs.migrateLegacyVadRoute(preferences);
```
plus `import '../../voice_offline/voice_offline_prefs.dart';`.

- [ ] **Step 5: `VadInputRound`** — constructor parameter `VoiceOfflinePrefs Function()? roundSettings`
stored as `_roundSettings = roundSettings ?? _defaults` with `static VoiceOfflinePrefs _defaults() => const VoiceOfflinePrefs();`
and `VoiceOfflinePrefs roundSettings() => _roundSettings();`. Q5 default A: give `onEvent`, `forceEnd` and
`stopHandsFree` a `required void Function() noSpeech` parameter and replace
`fail(StateError('No speech detected. Try again.'))` in `_finish` by `noSpeech()`. Update the controller call
sites from Task 4 Step 2 to pass it.

- [ ] **Step 6: Settings rows** — rewrite `lib/voice_offline/voice_offline_settings.dart`'s public widgets to
take `VoicePreferencesSession session` (device = `session.device`, prefs via `SharedPreferences.getInstance()`):
`VoiceOfflineInputRows` = a `StudioSelect<VoiceLocalEngine>` "Recognition engine" with "Android system
recognizer" / "Parakeet on this phone"; on change save via `saveDevicePreference(prefs,
VoiceOfflinePrefs.localEngineKey, engine.name)` and call the existing model prepare/release logic
(`onVoiceInputRouteChanged`, retyped to `(VoiceDevice device, bool wasParakeet, bool isParakeet)`); when
Parakeet is selected render the existing mic-route row and `VadSettingsSection`. `VoiceOfflineSettings(part:
VoiceOfflineSettingsPart.replies, session:)` keeps today's replies rows. Each row owns its `_saving`. Delete
`vadInputChoice`. Use `StudioSelect`/`StudioSwitch` and the shared tokens (AGENTS.md / `docs/features/ui-foundations.md`).

- [ ] **Step 7: Remaining `VoicePreferences` callers** — `barge_in_settings.dart` (field becomes
`bool vad` + `LocalVoiceOutputSettings? output`; the echo probe builds `LocalVoiceOutputSettings(voice: …, rate: AppVoiceRate.normal)`),
`car_mode_session.dart:299` (route name `switch (voiceInputSettingsFor(app, prefs)) { VadVoiceInputSettings() => 'vad', LocalVoiceInputSettings() => 'local', HermesVoiceInputSettings() => 'hermes', null => 'local' }`
— the bridge exposes `appPreferences`).

- [ ] **Step 8: Rewrite the dependent tests** per spec §7/Table C rows: `voice_offline_prefs_test.dart`
(`VoicePreferences.*` → `VoiceOfflinePrefs.*`; former `voice.input=vad` assertions become the migration tests
above), `voice_offline_settings_test.dart` and `vad_settings_test.dart` (seed `'voice.input': 'local',
'voice.local_engine': 'parakeet'`; mount `VoicePreferencesCard(createSession: () => VoicePreferencesSession(preferences: AppPreferences(prefs), device: device, hermesProfileLabel: null, openHermesSettings: null))`
like upstream `test/voice_preferences_test.dart`), `transcription_deadline_test.dart` and
`voice_vad_input_test.dart` (`VoiceInputController(device:, vadRound: VadInputRound(..., roundSettings: () => offline))`,
`start(const VadVoiceInputSettings(), VoiceDraft(text: '', selectionStart: -1, selectionEnd: -1), cb, createRemote: RemoteVoiceFixture.new)`;
the two no-speech tests assert `controller.notice` is noSpeech and `controller.error` is null),
`voice_settings_fixture.dart`, `voice_workspace_fixture.dart` (seed keys as above). Then
Run: `git rm test/voice_offline/voice_offline_prefs_tryread_test.dart`

- [ ] **Step 9: Verify**

Run: `git grep -n -w -E "VoicePreferences|VoiceInputRoute|VoiceProcessing|tryReadVoicePreferences" -- lib test`
Expected: no output.
Run: `git grep -n "voice.local_engine" -- lib test`
Expected: `voice_offline_prefs.dart` and tests.
Run: `git grep -n "migrateLegacyVadRoute" -- lib`
Expected: definition + exactly one call in `application_startup.dart`.
Run: `git grep -n "No speech detected. Try again" -- lib`
Expected: no output (Q5=A).

- [ ] **Step 10: Commit**

```bash
git add -A lib/voice_offline lib/car_mode lib/core/services/application_startup.dart lib/core/controllers/voice_input_controller.dart test
git commit -m "fix(voice): re-hang the Parakeet route on upstream's voice settings (t_d1d49ff1)

Spec VPF, §9.1, Q1=A, Q5=A: voice.local_engine + one-time migration of
voice.input=vad, VadVoiceInputSettings marker, voiceInputSettingsFor,
session-based fork settings rows, VAD no-speech as upstream notice.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Chat-state adapter, voice driver and car mode on upstream's chat model (Table C, §9.2-9.3, Q3)

**Files:**
- Modify: `lib/voice_offline/chat_voice_view.dart`
- Modify: `lib/voice_offline/workspace_voice_driver.dart`
- Modify: `lib/car_mode/car_mode_bridge.dart`, `lib/car_mode/car_mode_screen.dart`, `lib/voice_offline/completed_replies.dart` (cycle C3)
- Test: `test/voice_offline/chat_voice_view_test.dart` (create), `test/voice_offline/workspace_*_test.dart`, `test/car_mode/car_mode_workspace_test.dart`, `test/car_mode/car_mode_bridge_test.dart`, `test/support/voice_workspace_fixture.dart`

**Interfaces:** Produces the `ChatVoiceView` getters and `WorkspaceVoiceHost.liveVoiceActive`; consumes
`voiceInputSettingsFor` (Task 9).

- [ ] **Step 1: Rewrite `chat_voice_view.dart`**

```dart
import '../core/models/chat_runtime.dart';
import '../core/services/profile_workspace_controller.dart';
import 'barge_in_policy.dart';

/// The ProfileChat state the fork voice driver and car mode read. The only
/// place that follows upstream's chat.runtime / chat.composer split.
extension ChatVoiceView on ProfileChat {
  bool get voiceBusy => runtime.blocksTurnAdmission;

  String get voiceDraft => composer.observation.text;

  /// Approvals, clarify questions and secure prompts need the user's hands or
  /// eyes, so they end a hands-free conversation.
  bool get needsUserInput => runtime.needsInput;

  bool get voiceOpening => runtime.opening;

  bool get voiceOffline => runtime.offline;

  bool get voiceCommandRunning => runtime.commandRunning;

  bool get voiceChangingAnswer => runtime.changingAnswer;

  bool get voiceEditingQueue => composer.observation.editing != null;

  bool get voiceTurnEnded =>
      runtime.execution == ChatExecution.failed ||
      runtime.execution == ChatExecution.cancelled;

  ListenChatState get listenState => runtime.canSteer || runtime.needsInput
      ? ListenChatState.steerable
      : runtime.execution == ChatExecution.submitting ||
            runtime.reconnecting ||
            runtime.executionActive
      ? ListenChatState.busy
      : ListenChatState.idle;
}
```

- [ ] **Step 2: Driver** (`workspace_voice_driver.dart`), every change from spec Table C:
add `bool get liveVoiceActive;` to `WorkspaceVoiceHost`; early-return on `host.liveVoiceActive` in
`_speakCompletedReply`, `openListen`, `_voiceDeviceEvent`, `enterCarMode`, `talk`; `syncVadRoute`/`syncMediaKeys`
compute `want = … && !host.liveVoiceActive`; `canContinueConversation` adds `!host.liveVoiceActive`.
`sendConversationTurn` condition becomes

```dart
    if (_controller.recovering ||
        chat.voiceOpening ||
        chat.voiceOffline ||
        (_controller.current?.offlineSnapshot ?? false) ||
        !_controller.connectionStatus.networkAvailable) {
      awaitingReply = true;
      await _controller.queuePrompt(chat, text);
      return;
    }
```
The steer branch keeps `final accepted = await _controller.steer(chat, text); if (accepted) openListen(chat);`
and drops the manual `updateDraft(chat, '')`. `_listenTarget.onSteer` → `_controller.steer(chat, text)` (no
`preserveComposer`). `chat.opening/commandRunning/changingAnswer/editingQueuedPrompt` → the `ChatVoiceView`
getters. `HermesVoice.forConnection(_controller.connection, …)` → `HermesVoice.forConnection(_controller.access, …)`.
`insertVoiceTranscript(host.composer.value, text)` → build `VoiceDraft(text: c.text, selectionStart: c.selection.start, selectionEnd: c.selection.end)`,
call, write back `TextEditingValue(text: r.text, selection: TextSelection(baseOffset: r.selectionStart, extentOffset: r.selectionEnd))`.
`_voiceOutput.speak(..., settings, ...)` passes `_controller.appPreferences.current.voiceOutputSettings`
(skip speaking when it is null). `vadRoute()` → `voiceInputSettingsFor(_controller.appPreferences, _controller.preferences) is VadVoiceInputSettings`.
`_voiceInputChanged` ends the loop when `_voiceInput.notice != null` as well as on `error != null`, and when
the controller went active → idle without a result (Cancel in `VoiceInputActivity`, spec SCR-B8).

- [ ] **Step 3: `BackgroundVoiceChannel` hold refusal (spec §8)** — in
`android/app/src/main/kotlin/com/tarkilhk/wing/voicebackground/BackgroundVoiceChannel.kt` "hold": if
`LiveVoiceRuntime.audioOwned` reply with the existing refusal path (reuse the reason string the channel already
returns when the hold cannot start).

- [ ] **Step 4: Car mode** — `car_mode_bridge.dart` `carSnapshotOf`/`carActivityOf`: `ProfileTurnStatus` →
`ChatExecution`/`ChatRecovery`, `ProfileMainActivity` → `ChatMainActivity`, `chat.mainActivity/mainToolActivity/tool`
→ `chat.runtime.*`, busy/needs-input/opening/offline/command via `ChatVoiceView`. `car_mode_screen.dart:45-50`:
accent from `bridge.appPreferences.current` (`AppAccentPreference`, rendering `AppAccentRendering.appearance`),
no `WorkspaceAccent.fromName/preferenceKey/mint`.

- [ ] **Step 5: Cycle C3** — `completed_replies.dart` must not import the controller: make it carry
`Object chat` (`void offer(Object chat, String text)`, stream of `({Object chat, String text})`) and cast at the
driver (`event.chat as ProfileChat`).

- [ ] **Step 6: Tests** — create `test/voice_offline/chat_voice_view_test.dart` that drives a chat through the
upstream fixture (`test/support/composer_fixture.dart` `stockChatReply`, `message.start`) and asserts
`listenState` idle → busy (submitting) → steerable (running) and `voiceBusy` true while running. Rewrite
`workspace_conversation_test.dart`, `workspace_listen_turn_test.dart`, `workspace_screen_off_test.dart`,
`workspace_barge_in_test.dart`, `workspace_vad_media_keys_test.dart`, `car_mode_workspace_test.dart`: replace
every `chat.status = ProfileTurnStatus.running` by a gateway `message.start` event via the fixture, every
`chat.offlineSnapshot = true/false` by `h.controller.networkUnavailable()` / `h.controller.networkRestored()` +
`resumeConnection(networkChanged: true)`, `chat.draft` → `chat.composer.observation.text`, `chat.queuedPrompts`
→ `chat.composer.observation.queue`, `chat.messages` → `chat.reading.messages`. Fixtures/tests that build a
`ProfileWorkspaceController` use `access: ConnectionAccess(connection: <SavedConnection>, dashboardOAuth: null)`
and `appPreferences: AppPreferences(prefs)` (pattern: upstream `test/session_visibility_test.dart:130-143`).
Add a test "starting a live call ends the conversation loop" if the fixture can provide a `LiveVoiceScope`;
otherwise a driver-level test with a host fake whose `liveVoiceActive` is true asserting `openListen` does nothing.

- [ ] **Step 7: Verify**

Run: `git grep -n -E "ProfileTurnStatus|ProfileMainActivity|chat\.(busy|draft|opening|offlineSnapshot|commandRunning|changingAnswer|editingQueuedPrompt|queuedPrompts|queuePaused|runtimeId|messages)\b" -- lib/voice_offline lib/car_mode lib/fork test/voice_offline test/car_mode test/fork test/support`
Expected: no output.
Run: `git grep -n -E "preserveComposer|WorkspaceAccent\.(fromName|preferenceKey|mint)|forConnection\(_controller\.connection" -- lib test`
Expected: no output.
Run: `git grep -n "liveVoiceActive" -- lib`
Expected: the interface member, the screen getter, and ≥ 5 driver uses.
Run: `git grep -n "profile_workspace_controller.dart" -- lib/voice_offline/completed_replies.dart`
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add -A lib/voice_offline lib/car_mode android/app/src/main/kotlin/com/tarkilhk/wing/voicebackground test
git commit -m "fix(voice): voice driver and car mode on upstream's chat runtime (t_d1d49ff1)

Spec Table C, §9.2, §9.3, §8, Q3=A: ChatVoiceView adapter, auto-send via
queuePrompt/steer on the outbox, live-call mutual exclusion, accent via
AppPreferences, CompletedReplies without controller import (cycle C3).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Offline send seam (Q6, Q7) and auto-merged test repairs (S4, S5)

**Files:**
- Create: `lib/fork/transient_send.dart`
- Delete: `lib/fork/offline_queue.dart`
- Rename: `test/fork/offline_queue_test.dart` → `test/fork/offline_send_test.dart`
- Modify: `test/fork/network_gate_test.dart`, `test/fork/registry_network_test.dart`
- Modify: `test/session_visibility_test.dart` (S4), `test/profile_workspace_controller_test.dart` and `test/support/profile_browser_fixture.dart` (S5), `test/wing_session_source_test.dart` (GWY-B3)

**Interfaces:** Produces `TransientSend.mark(Object chat)`, `TransientSend.take(Object chat) → bool` (used by Task 6 hooks).

- [ ] **Step 1: Write the failing test** — in `test/fork/offline_send_test.dart` keep test 1 (outage shows
`ServerConnectionStatus.phase == disconnected` at once, queued text not drained offline, exactly one
`prompt.submit` after `networkRestored()` + `resumeConnection(networkChanged: true)`), with assertions on
`chat.composer.observation.queue.map((q) => q.text)` and `.paused`. Keep test 2 "flaky send right after
reconnect resolves on the next reconnect instead of sticking forever": `host.promptSubmitFailures = 1` with a
`JsonRpcError` connection-closed **before** submission; after the next `networkRestored()` + reconnect expect
`observation.paused == false` and both prompts submitted in order. Delete test 3 (history-text head; upstream
test "lost ACK recovers the original receipt without executing twice" covers it).

- [ ] **Step 2: Implement `lib/fork/transient_send.dart`**

```dart
/// Chats whose last queued prompt failed transiently before it was
/// submitted. Upstream pauses such a queue until the user taps Resume; in
/// hands-free conversation no Resume is reachable, so the fork resumes these
/// queues once on the next reconnect (spec Q6). Uncertain deliveries stay
/// upstream's (idempotent replay).
abstract final class TransientSend {
  static final Expando<bool> _marked = Expando<bool>('transientSend');

  static void mark(Object chat) => _marked[chat] = true;

  /// True once per mark.
  static bool take(Object chat) {
    final marked = _marked[chat] == true;
    _marked[chat] = null;
    return marked;
  }
}
```
Run: `git rm lib/fork/offline_queue.dart`
Run: `git mv test/fork/offline_queue_test.dart test/fork/offline_send_test.dart` (before Step 1's edits if not yet moved)

- [ ] **Step 3: S4/S5/GWY-B3 test repairs** — `test/session_visibility_test.dart`: the all-sources assertion
`hasLength(160)` → `hasLength(161)`. `test/profile_workspace_controller_test.dart` and
`test/support/profile_browser_fixture.dart`: move the `if (method == 'prompt.submit' && promptSubmitFailures > 0) { … }`
block to the top of upstream's `prompt.submit` branch (before `canonicalAdmissions.putIfAbsent`).
`test/wing_session_source_test.dart`: the `session.create` source expectation → `guiSessionSource`.
`network_gate_test.dart`: add case "lost gate wins over a scheduled recovery" (`phase == disconnected` while
`waitForRecovery` holds). `registry_network_test.dart`: new controller ctor; cases `recoverConnections()` lifts the
gate, `resumeConnections()` does not.

- [ ] **Step 4: Verify**

Run: `git grep -n -B3 "promptSubmitFailures > 0" -- test/profile_workspace_controller_test.dart test/support/profile_browser_fixture.dart`
Expected: the block precedes `canonicalAdmissions.putIfAbsent`.
Run: `git grep -n "hasLength(16" -- test/session_visibility_test.dart`
Expected: `hasLength(161)` once.
Run: `git grep -n -E "offline_queue|queuedHeadDelivered" -- lib test`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add -A lib/fork test
git commit -m "fix(fork): offline send on upstream's outbox; repair auto-merged tests (t_d1d49ff1)

Spec CTL-B5/B8, §9.3, Q6=B, Q7=A, S4, S5: TransientSend resumes a
transiently failed queue on reconnect; offline_queue.dart removed
(upstream replays uncertain heads); session_visibility 161 rows;
promptSubmitFailures injection before upstream's prompt.submit branch.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Upstream architecture gates and CI tooling (spec §11, S7, S8)

**Files:**
- Modify: `lib/voice_offline/vad_voice_device.dart` (cycle C1), `lib/core/services/wing_session_source.dart` + `lib/core/services/profile_gateway.dart` + importers (cycle C4)
- Modify: `lib/core/widgets/vad_settings_section.dart` (dialog rule D1)
- Modify: `tools/architecture/roles.json`, `tools/architecture/roots.json`
- Modify: `tools/factory/ci-suite.sh`, `tools/factory/dispatch-check.sh` (S7)
- Modify: `.github/workflows/voice-apk.yml`, `.github/workflows/voice-review.yml` (S8)
- Create: `.cc-context/census_fill.py` (helper, not committed)

- [ ] **Step 1: Cycle C1** — `vad_voice_device.dart` drops `import '…/android_voice.dart'`; `VadVoiceDevice.of(Object device)` and `VoiceSwitchHolders` take `Object` and cast; `AndroidVadVoice` declares `static const _channel = MethodChannel('com.tarkilhk.wing/voice');` (import `package:flutter/services.dart`).

- [ ] **Step 2: Cycle C4** — `wing_session_source.dart` becomes `part of 'profile_gateway.dart';` (remove its `library;` and imports); `profile_gateway.dart` replaces `import 'wing_session_source.dart';` by `part 'wing_session_source.dart';`. Importers of `wing_session_source.dart` (`git grep -n "wing_session_source.dart" -- lib test`) import `profile_gateway.dart` instead.

- [ ] **Step 3: D1** — `vad_settings_section.dart`: `AlertDialog` → `StudioDialog`, the Cancel/confirm `TextButton`s → `StudioFormActions` (both in `lib/core/widgets/studio_form_actions.dart`; copy the usage pattern from an upstream caller: `git grep -n "StudioDialog(" -- lib/core/widgets`).

- [ ] **Step 4: roles.json** — add one entry per fork `lib` file with the role/feature from spec §11 (format `"<path>": {"role": "...", "feature": "...", "library": "<path or owner library>"}`; `wing_session_source.dart` has `"library": "lib/core/services/profile_gateway.dart"`). List the files with
Run: `git ls-files -- lib/voice_offline lib/car_mode lib/fork lib/core/services/vad_endpoint.dart lib/core/services/wing_session_source.dart lib/core/widgets/vad_settings_section.dart`

- [ ] **Step 5: roots.json census** — write `.cc-context/census_fill.py` (`.cc-context/` is git-excluded in the
fork worktrees; if it is not, add it to `.git/info/exclude` first so the helper never gets committed or censused):

```python
"""Add missing git-visible files to tools/architecture/roots.json files[] and drop stale ones."""
import json
import subprocess

PATH = "tools/architecture/roots.json"
data = json.load(open(PATH))
tracked = set(subprocess.run(["git", "ls-files"], capture_output=True, text=True).stdout.split())
declared = {e["path"] for e in data["files"]}
for path in sorted(tracked - declared):
    area = path.split("/", 1)[0] if "/" in path else "root"
    data["files"].append({"path": path, "area": area, "provenance": "tracked"})
data["files"] = sorted((e for e in data["files"] if e["path"] in tracked), key=lambda e: e["path"])
open(PATH, "w").write(json.dumps(data, indent=2) + "\n")
print(len(tracked - declared), "added", len(declared - tracked), "stale removed")
```
Run: `python3 -I .cc-context/census_fill.py`
Run: `python3 tools/architecture/rules/authored_census.py`
Expected: no output, exit 0. (If the census excludes paths that `git ls-files` lists, the rule prints them as
stale; remove those entries and re-run.)
Run: `python3 tools/architecture/rules/native_retired_resources.py`
Expected: `ARCH_NATIVE_RETIRED_RESOURCES: 0 findings`.

- [ ] **Step 6: S7 factory scripts** — `tools/factory/ci-suite.sh`: delete the line
`gh workflow run pr-quality.yml -R "$repo" --ref "$br" >/dev/null` and change the list call to
`gh run list -R "$repo" --workflow pr-quality.yml --event push --branch "$br" \`. Update the header comment
("the push of ci/<sha> triggers pr-quality.yml (push: '**')"). `tools/factory/dispatch-check.sh`: add
`--workflow "$workflow"` to its `gh run list` call.

- [ ] **Step 7: S8 workflows** — `flutter-version: '3.47.9'` in `.github/workflows/voice-apk.yml` and `.github/workflows/voice-review.yml`.

- [ ] **Step 8: Verify**

Run: `git grep -n -E "^import '.*android_voice\.dart'" -- lib/voice_offline/vad_voice_device.dart`
Expected: no output.
Run: `git grep -n -E "AlertDialog|Text\('Cancel'\)" -- lib/core/widgets/vad_settings_section.dart`
Expected: no output.
Run: `git grep -n "gh workflow run" -- tools/factory/ci-suite.sh`
Expected: no output.
Run: `git grep -n -e "--event push" -- tools/factory/ci-suite.sh`
Expected: one hit.
Run: `git grep -n "flutter-version" -- .github/workflows/voice-apk.yml .github/workflows/voice-review.yml`
Expected: `'3.47.9'` in both.

- [ ] **Step 9: Commit**

```bash
git add -A lib tools .github
git commit -m "fix(ci): pass upstream architecture gates; factory scripts for push-triggered CI (t_d1d49ff1)

Spec §11, S7, S8: roles.json and roots.json entries for fork files,
cycles C1/C4 broken, StudioDialog in vad settings, Flutter 3.47.9 in the
voice workflows, ci-suite/dispatch-check select the right run.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Docs and changelog

**Files:**
- Modify: `CHANGELOG.fork.md`, `docs/VOICE.md`, `README.md` (only if Q4=A)

- [ ] **Step 1: CHANGELOG.fork.md** — new top entry:

```markdown
## Upstream merge (t_d1d49ff1, merge <merge-commit-hash>)

**What:** Merged tarkilhk/Wing upstream/main <sha> (806+ commits: gateway/chat rewrite, outbox, typed
preferences, live voice call) into the fork. Fork voice, car mode and offline features re-hung on upstream's
new seams (spec docs/superpowers/specs/2026-11-12-wing-upstream-merge-design.md).
**Why:** Stay upstream-compatible (fork strategy); card t_d1d49ff1.
**User-visible:** Parakeet is chosen as "Recognition engine" under Local voice input (stored value migrated
automatically); empty Parakeet recognition shows upstream's "No speech detected" notice; upstream's live call
button appears (needs the Wing Hermes plugin); unsent drafts/queues from before the update are not carried over
(upstream format change). <Add one line per OPEN answer that differs from the default.>
**Dropped for upstream:** own queue drain loop and history-text queue-head check (upstream outbox), composer
toolbar mic (upstream mic in the text field).
```

- [ ] **Step 2: docs/VOICE.md** — add a short "Wing Voice (fork)" note under upstream's dictation section:
conversation mode sends dictations automatically (opt-in), the system-recognizer fallback stays inside Local
(never switches to Hermes), maximum dictation duration is 10 minutes.

- [ ] **Step 3: README.md** — only if Q4=A: change the "Inline, tap-to-zoom chat images" bullet to say upstream's inline images are used.

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.fork.md docs/VOICE.md README.md
git commit -m "docs: fork changelog and voice notes for the upstream merge (t_d1d49ff1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
Then census: `python3 tools/architecture/rules/authored_census.py` → no output.

---

### Task 14: [SUITE] + [NATIVE] — make CI green

- [ ] **Step 1: Suite**

Run: `bash tools/factory/ci-suite.sh` (Bash timeout max; see Global Constraints)
Expected: last line `ci-suite: run <id> conclusion=success …`, exit 0.

- [ ] **Step 2: On red** — read the failed steps and `::error::` annotations the script prints (PRQ-B2
snippet). Fix in the smallest commit that names the spec ID it completes; never weaken an upstream gate, test or
rule. If `VoicePermissionLifecycleGuard` (step "permission lifecycle") rejects VCH-B4/S6 after one fix attempt:
stop and end with `FRAGE: Q11 — keep a fork edit of upstream's VoicePermissionLifecycleGuard, or let conversation mode pause TTS when the screen turns off?`.
If the emulator/KVM jobs fail for infrastructure reasons only (no `/dev/kvm`), report it with the run URL and ask
(Q10). Repeat Step 1 until green.

- [ ] **Step 3: Native**

Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: last line `dispatch-check: voice-apk.yml run <id> conclusion=success …`. On "NDK 28.2.13676358 not
installed" or "platform android-36 missing": copy upstream's "Install pinned Android SDK" step from
`pr-quality.yml` into `voice-apk.yml`, commit, re-run.

---

### Task 15: Refresh from `voice-offline` and final measurement

- [ ] **Step 1:** Run: `git fetch origin`; Run: `git log --oneline wt/t_d1d49ff1..origin/voice-offline`.
If empty, skip to Step 3.
- [ ] **Step 2:** Run: `git merge --no-ff origin/voice-offline` (MERGE, no rebase); resolve; re-run the census
(`python3 -I .cc-context/census_fill.py`, `python3 tools/architecture/rules/authored_census.py`); commit; repeat Task 14 Step 1.
- [ ] **Step 3:** Run: `git merge-tree --write-tree --name-only HEAD upstream/main`
Expected: exit 0 if upstream has not moved (nothing left to merge), else the list of new conflicts — report it, do not merge again in this card.

---

### Task 16: Signed APK — gated on Q8

- [ ] **Step 1: Gate** — Q8 default A: before any phone install Birk must confirm that all unsent drafts and
queued messages in the installed Wing Voice are sent or copied out. If that confirmation is not on the card,
end with `FRAGE: Q8 — sind alle ungesendeten Entwürfe und Warteschlangen in der installierten Wing Voice versendet oder kopiert? Erst dann baue ich die signierte APK zur Installation.`
(The build in Step 2 may run before the answer; only the hand-over waits.)

- [ ] **Step 2: Build the unsigned release APK on CI**

Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=true`
Expected: `conclusion=success`; branch `voice-apk-bin` gets `wing-voice-unsigned.apk`, `SHA256SUMS`, `SOURCE_COMMIT` = this HEAD.

- [ ] **Step 3: Sign** (script lives in the entity repo, not in Wing; verified 2026-11-12)

Run: `/home/birk/hermes-shared/hermes-entities/tools/technik/wing-voice-build.sh`
Expected: a zipaligned APK signed with `~/.android/wing-voice.keystore` (alias `voice`), its path printed;
`SOURCE_COMMIT` equals `git rev-parse HEAD`. Do not pass `--install` (the phone is Birk's).

- [ ] **Step 4: Identity check** — with the build-tools on the host (`~/.local/share/android-tools/`), if `aapt2`
is available: `aapt2 dump badging <apk>`; expected `package: name='com.tarkilhk.wing.voice'`, `versionCode` >
2356, `application-label:'Wing Voice'`, `sdkVersion:'29'`; and the APK contains `assets/silero_vad.onnx`
(`unzip -l <apk> assets/silero_vad.onnx`). If no `aapt2`, record "identity check on the phone" in the card.

---

### Task 17: Birk phone self-test and card comment

- [ ] **Step 1: Post the self-test checklist on card t_d1d49ff1** (German, for Birk):

```
Handytest Wing Voice nach Upstream-Merge (APK <hash>):
[ ] Vor dem Update: alle ungesendeten Entwürfe/Warteschlangen versendet oder kopiert (Q8).
[ ] App startet als "Wing Voice", Einstellungen/Verbindung noch da.
[ ] Diktat (Parakeet) endet von selbst nach einer Sprechpause.
[ ] Diktat > 60 s kommt vollständig an (auch Android-Erkenner > 2 min, bis 10 min).
[ ] Konversationsmodus: Antwort wird vorgelesen, Mikrofon öffnet sich danach wieder.
[ ] Einstellungen → Spracheingabe: Lokal + "Erkennung: Parakeet auf diesem Telefon" ist ausgewählt (Q1, Migration).
[ ] Stille im Parakeet-Diktat zeigt den Hinweis "No speech detected" und beendet die Konversation (Q5).
[ ] Diktat bei laufender Antwort wird als Steuernachricht angehängt; offline diktiert → nach Wiederverbindung
    automatisch gesendet, Konversation läuft weiter (t_f0c1d125, Q6).
[ ] Flugmodus an: Status zeigt sofort offline (Q7).
[ ] Bildschirm aus im Konversationsmodus: Vorlesen läuft weiter (S6/Q11).
[ ] Live-Anruf-Knopf (Wellenform) neben dem Mikrofon: Tippen ohne Plugin zeigt Hinweis; mit laufendem
    Konversationsmodus beendet der Start die Konversation (Q2, Q3).
[ ] Bilder im Chat: volle Breite mit Download/Vorschau-Knöpfen (Q4=B) bzw. Upstream-Kasten (Q4=A).
[ ] Automodus, Medientasten, Barge-in wie vorher.
```
Add one line per OPEN question Birk answered differently from the default.

- [ ] **Step 2: Post the "taken from upstream / dropped on our side" list** on the card: one line per spec ID
with decision `drop our variant, upstream already solves it` or `keep upstream behaviour` where our side had
code (CTL-B3, CTL-B4, CTL-B5, CTL-B7 cap, CTL-B8, SCR-B7 parts, SCR-B13, SCR-B19, SCR-B21, SCR-B22, VCA-B4
message, VIC-B4, VPC-B2, VPC-B3, MMC-B2..B6, PMS-B1, PMS-B2, DLA-B1..B4 per Q4, PRQ-B1, GWY-B3
`close_on_disconnect`), and per file the re-hung fork functions.

- [ ] **Step 3: Stop.** The merge into `voice-offline` is the [Merge] card's job.

---

## Self-review notes (architect, 2026-11-12)

- Spec coverage: Table B rows → Tasks 2-7 (every ID named); VPF → Task 4/9; §6 S1-S3, S6 → Task 3, S4/S5 →
  Task 11, S7/S8 → Task 12, S9 → Task 5, S10 → Task 6; Table C → Tasks 9-11; §8 → Tasks 3, 5, 10; §9 →
  Tasks 6, 9, 10, 11; §10 items 1-8 → Tasks 9, 7, 3, 10, 3, 12, 6, 11; §11 → Task 12; §12/Q8 → Task 16;
  Q1-Q11 → named in the depending tasks; phone checklist → Task 17.
- The merge commit (Task 8) does not compile by design; the first [SUITE] is Task 14 after all repair commits.

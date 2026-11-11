# Wing upstream-compatibility refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every fork change that sits inside an upstream-owned file into fork-owned files, leaving
only thin hooks, with no behaviour change, so the later upstream merge (`t_d1d49ff1`) is small.

**Architecture:** Own units with narrow interfaces (`VadVoiceDevice` mixin, `VoiceOfflinePrefs`,
`VadInputRound`, `VoiceOfflineSettings`, `WorkspaceVoiceDriver` + `WorkspaceVoiceHost`, `NetworkGate`,
`CompletedReplies`, `InlineMediaThumbnail`, `VoiceOfflineHandler.kt`, `RecognizerSelection.kt`,
`voice-offline.gradle.kts`) plus thin hooks in today's fork files. Each hook is chosen to map onto a named
upstream/main seam (spec §4). Tests leave upstream test files for own files with shared own fixtures.

**Tech Stack:** Flutter/Dart (flutter_test), Kotlin (Android), Gradle Kotlin DSL, bash; suite on GitHub
Actions.

**Spec:** `docs/superpowers/specs/2026-11-11-wing-upstream-compat-refactor-design.md`. Read §3 (what
upstream did), §4 (per-file table: the authority for targets and hook shapes), §6 (removal list and open
items) before starting.

## Global Constraints

- **No behaviour change.** No UI, copy, timing, storage key, default or channel-contract change. Moves are
  verbatim apart from renamed private symbols that become public in their new file. When a move would
  require a semantic change, stop and leave the code where it is: record it in the task notes as
  "kept, open".
- **No upstream merge**, no adoption of upstream features, no backend change (AGENTS.md: Hermes stays stock).
- Removals only from the spec §6 "Removed" table. Everything in "Kept, open" stays.
- Own code locations: `lib/voice_offline/` (voice), `lib/car_mode/` (car mode), `lib/fork/` (new; non-voice
  fork code), `android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/` (native voice),
  `test/voice_offline/`, `test/car_mode/`, `test/fork/` (new), `test/support/*_fixture.dart`.
- Comments and identifiers in English (docs/refactoring-guidelines.md §7). Match the surrounding comment
  density; a moved block keeps its comments.
- One command per Bash call. No `cd`, no `&&`/`;`, no `$VAR`, no `$( )`.
- Suite: `bash tools/factory/ci-suite.sh` (pushes HEAD to a throwaway `ci/<sha>` branch, runs `flutter
  analyze` + `flutter test` on GitHub Actions, ~minutes). It builds the **committed** HEAD: commit first.
  Expected last line `ci-suite: run <id> conclusion=success …`. Run it only at the checkpoints marked
  **[SUITE]**, not after every task. There is no Flutter SDK on the host: never plan on local `flutter`.
- Kotlin/Gradle compile: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`. Expected last
  line `dispatch-check: voice-apk.yml run <id> conclusion=success …`. Only at **[NATIVE]** checkpoints.
- Metrics: `bash tools/factory/upstream-diff-metrics.sh` (Task 1). Run it after each task group and note
  the two TOTAL lines in the task's commit message body.
- Commit after every task on `voice-offline` (local). No push except what the two factory scripts do
  themselves. No merge except the `voice-offline` refresh in Task 0 and Task 18.
- Other wing cards may merge into `voice-offline` while this runs (e.g. `wt/t_256dcf56`, 2026-11-11). Task 18
  merges the latest `voice-offline` before the final measurement.
- Phone tests are Birk's (manual). The implementer never installs or drives the phone.
- **Changelog:** refactor commits are not feat/fix; Task 18 adds one internal `CHANGELOG.fork.md` entry for
  the whole card. No README feature line (nothing user-visible).

## Baseline (2026-11-11, `voice-offline` 55db5f1f, `upstream/main` 5020e141, merge-base 151ee281)

- (a) 38 modified upstream files, **+4351 / −157** (lib 1622, native/build 198, tests 2454, meta 77).
- (b) Probe merge: **27 conflict files, 92 conflict blocks**, 2 modify/delete (`docs/TESTING.md`,
  `lib/core/services/voice_preferences.dart`).

## File map

| File | Status | Task | Responsibility |
|---|---|---|---|
| `tools/factory/upstream-diff-metrics.sh` | new | 1 | metrics (a) + (b) |
| `docs/VAD_INPUT.md`, `docs/CAR_MODE.md` | change | 2 | receive fork paragraphs from `docs/VOICE.md`, `docs/TESTING.md` |
| `android/app/.gitignore` | new | 2 | `/libs/` |
| `android/app/voice-offline.gradle.kts` | new | 3 | sherpa/Silero fetch, deps, variant overrides |
| `android/.../wing/voiceoffline/VoiceOfflineHandler.kt` | new | 4 | fork method-channel calls and lifecycle |
| `android/.../wing/voiceoffline/RecognizerSelection.kt` | new | 4 | recognizer fallback, `cleanTranscript` |
| `lib/voice_offline/vad_voice_device.dart` | new | 5 | `VadVoiceDevice`, `AndroidVadVoice`, VAD types |
| `test/support/vad_voice_fixture.dart` | new | 5 | `VadVoiceFixture` mixin |
| `lib/voice_offline/voice_offline_prefs.dart` | new | 6 | fork preferences |
| `lib/voice_offline/vad_input_round.dart` | new | 7 | VAD round inside `VoiceInputController` |
| `lib/voice_offline/voice_offline_settings.dart` | new | 8 | fork rows of the voice settings card |
| `test/support/voice_workspace_fixture.dart` | new | 9 | workspace harness for own tests |
| `test/voice_offline/workspace_*_test.dart`, `test/car_mode/car_mode_workspace_test.dart` | new | 9 | tests moved out of `test/voice_workspace_test.dart` |
| `test/support/voice_settings_fixture.dart`, `test/voice_offline/voice_offline_prefs_test.dart`, `test/voice_offline/voice_offline_settings_test.dart`, `test/voice_offline/transcription_deadline_test.dart` | new | 10 | tests moved out of `voice_preferences_test.dart` / `voice_processing_test.dart` |
| `lib/fork/network_gate.dart`, `lib/voice_offline/completed_replies.dart`, `lib/fork/offline_queue.dart` | new | 11 | network-loss state, reply stream, queue helper |
| `test/fork/network_gate_test.dart`, `test/fork/registry_network_test.dart`, `test/fork/offline_queue_test.dart` | new | 11 | moved tests |
| `lib/fork/inline_media_thumbnail.dart`, `test/fork/inline_media_thumbnail_test.dart` | new | 12 | inline MEDIA thumbnail |
| `lib/voice_offline/workspace_voice_driver.dart`, `lib/voice_offline/chat_voice_view.dart` | new | 13–16 | screen voice logic, `ProfileChat` adapter |

---

### Task 0: Preflight

**Files:** none.

- [ ] **Step 1: Refresh refs**

Run: `git fetch upstream`
Run: `git fetch origin`
Run: `git status --short`
Expected: on `voice-offline`, no tracked changes (untracked `.worktrees/` and `.suite-cache-before.out` are fine).

- [ ] **Step 2: Take the latest `voice-offline`**

Run: `git merge --ff-only origin/voice-offline`
Expected: fast-forward or "Already up to date". If it is not a fast-forward, stop and ask (`FRAGE:`).

- [ ] **Step 3: Note the start commit**

Run: `git rev-parse --short=8 HEAD`
Keep the value; Task 18 quotes it.

---

### Task 1: Metrics script

**Files:**
- Create: `tools/factory/upstream-diff-metrics.sh`

**Interfaces:**
- Produces: `bash tools/factory/upstream-diff-metrics.sh [branch=HEAD] [upstream=upstream/main]`; last lines
  `TOTAL modified upstream files: <n>  +<a> -<d>` and `TOTAL conflict files: <f>  conflict blocks: <b>`.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Upstream-compatibility metrics for the fork (card t_ba3601fa).
#  (a) our lines in upstream-owned files: files that exist at the merge-base
#      and that we modified (--diff-filter=M), per file and total, plus
#      whether upstream also changed the file since the merge-base;
#  (b) probe merge of <upstream> into <branch> in a throwaway detached
#      worktree: conflict files (with git status code) and conflict blocks.
# Read-only for the current checkout; the probe worktree is removed on exit.
# Usage: tools/factory/upstream-diff-metrics.sh [branch=HEAD] [upstream=upstream/main]
set -euo pipefail
branch=${1:-HEAD}
upstream=${2:-upstream/main}
top=$(git rev-parse --show-toplevel)
base=$(git merge-base "$upstream" "$branch")
echo "branch $(git rev-parse --short=8 "$branch")  upstream $(git rev-parse --short=8 "$upstream")  merge-base $(git rev-parse --short=8 "$base")"

theirs=$(git diff --name-only "$base" "$upstream")
echo
echo "== (a) our lines in upstream files (added deleted path [U=upstream changed it too])"
git diff --numstat --diff-filter=M "$base" "$branch" | sort -k1,1nr | {
  n=0; a=0; d=0
  while read -r add del path; do
    mark=" "
    grep -qxF "$path" <<<"$theirs" && mark="U"
    printf '%6s %6s %s %s\n' "$add" "$del" "$mark" "$path"
    n=$((n + 1)); a=$((a + add)); d=$((d + del))
  done
  echo "TOTAL modified upstream files: $n  +$a -$d"
}

echo
echo "== (b) probe merge $upstream -> $branch"
probe="$top/.worktrees/upstream-probe-$$"
git worktree add -q --detach "$probe" "$branch"
trap 'git worktree remove --force "$probe" >/dev/null 2>&1 || true' EXIT
git -C "$probe" -c user.name=probe -c user.email=probe@invalid \
  merge -q --no-commit --no-ff "$upstream" >/dev/null 2>&1 || true
files=0; blocks=0
while IFS= read -r line; do
  code=${line:0:2}
  path=${line:3}
  case "$code" in
    DD|AU|UD|UA|DU|AA|UU) ;;
    *) continue ;;
  esac
  n=0
  [ -f "$probe/$path" ] && n=$(grep -c '^<<<<<<< ' "$probe/$path" || true)
  printf '%4s %s %s\n' "$n" "$code" "$path"
  files=$((files + 1)); blocks=$((blocks + n))
done < <(git -C "$probe" status --porcelain=v1 --untracked-files=no)
echo "TOTAL conflict files: $files  conflict blocks: $blocks"
```

- [ ] **Step 2: Run it against the baseline commit**

Run: `bash tools/factory/upstream-diff-metrics.sh 55db5f1f upstream/main`
Expected (if `upstream/main` is still `5020e141`): `TOTAL modified upstream files: 38  +4351 -157` and
`TOTAL conflict files: 27  conflict blocks: 92`. If upstream moved, record the new numbers as the baseline.

- [ ] **Step 3: Run it on HEAD and confirm the probe worktree is gone**

Run: `bash tools/factory/upstream-diff-metrics.sh`
Run: `git worktree list`
Expected: no `upstream-probe-*` entry left.

- [ ] **Step 4: Commit**

Run: `git add tools/factory/upstream-diff-metrics.sh`
Run: `git commit -m "chore(factory): upstream-diff metrics script (t_ba3601fa)"` (body: both TOTAL lines; trailer `Co-Authored-By` as configured)

---

### Task 2: Docs and .gitignore out of upstream files

**Files:**
- Modify: `docs/TESTING.md` (revert to merge-base), `docs/VOICE.md`, `.gitignore` (revert our line),
  `docs/VAD_INPUT.md`, `docs/CAR_MODE.md`
- Create: `android/app/.gitignore`

- [ ] **Step 1: Read our additions**

Run: `git diff 151ee281 HEAD -- docs/TESTING.md docs/VOICE.md .gitignore`

- [ ] **Step 2: Move the `docs/TESTING.md` paragraph**

Append the 4-line paragraph that begins "The vad route's maximum duration is 10-30 min" verbatim to
`docs/VAD_INPUT.md` under a new heading `## Testing`. Then restore the upstream file:
Run: `git checkout 151ee281 -- docs/TESTING.md`

- [ ] **Step 3: Move the `docs/VOICE.md` additions**

Move the Parakeet/VAD paragraph to `docs/VAD_INPUT.md` (top, under the existing intro) and the car-mode
link lines to `docs/CAR_MODE.md` if not already present there. Restore `docs/VOICE.md` with
`git checkout 151ee281 -- docs/VOICE.md`, then add one line at the end of its first section:

```markdown
Fork additions (on-device VAD dictation, car mode): see [VAD_INPUT.md](VAD_INPUT.md) and [CAR_MODE.md](CAR_MODE.md).
```

- [ ] **Step 4: Move the ignore rule**

Create `android/app/.gitignore`:

```gitignore
# Fork: sherpa-onnx AAR fetched by voice-offline.gradle.kts (never committed)
/libs/
```

Run: `git checkout 151ee281 -- .gitignore`
Run: `git check-ignore -v android/app/libs/sherpa-onnx-1.13.8.aar`
Expected: `android/app/.gitignore:2:/libs/	android/app/libs/sherpa-onnx-1.13.8.aar`

- [ ] **Step 5: Check links**

Run: `grep -rn "TESTING.md#\|VOICE.md#" docs README.md CHANGELOG.fork.md`
Expected: no anchor that pointed at a moved paragraph; fix any hit to the new `VAD_INPUT.md` anchor.

- [ ] **Step 6: Metrics and commit**

Run: `bash tools/factory/upstream-diff-metrics.sh`
Expected: `docs/TESTING.md` and `.gitignore` gone from (a); `docs/TESTING.md` gone from (b).
Run: `git add docs/TESTING.md docs/VOICE.md docs/VAD_INPUT.md docs/CAR_MODE.md .gitignore android/app/.gitignore`
Run: `git commit -m "refactor(docs): move fork notes out of upstream docs (t_ba3601fa)"`

---

### Task 3: Gradle script plugin **[NATIVE]**

**Files:**
- Create: `android/app/voice-offline.gradle.kts`
- Modify: `android/app/build.gradle.kts` (remove our 71 lines, add the apply line)

**Interfaces:**
- Produces: tasks `fetchSherpaOnnxAar`, `fetchSileroVad` (same names, same outputs); Gradle property
  `voiceVariant=true` keeps label "Wing Voice" and id `com.tarkilhk.wing.voice` for release.

- [ ] **Step 1: Create the script**

`android/app/voice-offline.gradle.kts` — move verbatim from `build.gradle.kts`: the imports `java.io.File`,
`java.net.URI`, `java.security.MessageDigest`; class `FetchVerifiedFile`; `fetchSherpaOnnxAar`,
`fetchSileroVad`; the `preBuild` `dependsOn`. Then add the variant overrides and dependencies:

```kotlin
// Fork (Wing Voice): on-device speech dependencies and the side-by-side variant.
// Applied at the end of build.gradle.kts so these overrides run after upstream's.
import com.android.build.api.dsl.ApplicationExtension
import com.android.build.api.variant.ApplicationAndroidComponentsExtension

// ... FetchVerifiedFile, fetchSherpaOnnxAar, fetchSileroVad, preBuild dependsOn (verbatim) ...

val voiceVariant = providers.gradleProperty("voiceVariant").orNull == "true"

extensions.configure<ApplicationExtension>("android") {
    buildTypes.getByName("release") {
        proguardFiles("proguard-rules.pro")
        if (voiceVariant) manifestPlaceholders["appLabel"] = "Wing Voice"
    }
}

extensions.configure<ApplicationAndroidComponentsExtension>("androidComponents") {
    onVariants(selector().withBuildType("release")) { variant ->
        if (voiceVariant) variant.applicationId.set("com.tarkilhk.wing.voice")
    }
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(
            fetchSileroVad, FetchVerifiedFile::outputDirectory
        )
    }
}

dependencies {
    add("implementation", files("libs/sherpa-onnx-1.13.8.aar"))
    add("implementation", "org.apache.commons:commons-compress:1.27.1")
}
```

- [ ] **Step 2: Restore upstream lines in `build.gradle.kts`**

Remove every line our diff added (imports, `FetchVerifiedFile`, tasks, `voiceVariant`, `proguardFiles`, the
asset `addGeneratedSourceDirectory`, the two `implementation` lines) and restore the two changed lines to
their merge-base text (`manifestPlaceholders["appLabel"] = "Wing"`,
`variant.applicationId.set("com.tarkilhk.wing")`). Append at the end of the file:

```kotlin

// Fork (Wing Voice): own build additions, see voice-offline.gradle.kts.
apply(from = "voice-offline.gradle.kts")
```

Run: `git diff 151ee281 -- android/app/build.gradle.kts`
Expected: exactly the 3 added lines above.

- [ ] **Step 3: Compile**

Run: `git add android/app/voice-offline.gradle.kts android/app/build.gradle.kts`
Run: `git commit -m "refactor(android): move fork build additions into voice-offline.gradle.kts (t_ba3601fa)"`
Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: `conclusion=success`.

**Fallback (decision rule).** Script plugins applied with `apply(from = …)` may not see AGP classes
(`Unresolved reference: ApplicationExtension`), because AGP is loaded through the app module's `plugins {}`
block. Upstream's own `ime-cache-fix.gradle.kts` avoids AGP types for that reason.
1. If the dispatch check fails with an unresolved AGP type: rewrite the same content as a Groovy script
   `android/app/voice-offline.gradle` (dynamic typing resolves `android { … }` / `androidComponents { … }`
   at runtime), apply it with `apply(from = "voice-offline.gradle")`, delete the `.kts`, re-run the check.
2. If that fails too: restore `build.gradle.kts` to its pre-task state
   (`git checkout HEAD~1 -- android/app/build.gradle.kts`), delete the new script, amend the commit to a
   no-op or drop it, and record "Gradle: kept, open (applied script cannot configure AGP)" for Task 18.

- [ ] **Step 4: APK identity check**

The release APK built with `voiceVariant=true` must keep id `com.tarkilhk.wing.voice`, label "Wing Voice"
and include `assets/silero_vad.onnx`. Check the `voice-apk.yml` job log lines (step names in the
dispatch-check output) or, if the workflow prints `aapt dump badging`, compare `package: name=`. If the
workflow does not show it, note "identity verified by Birk at install" for Task 18's manual list.

---

### Task 4: Native voice handler **[NATIVE]**

**Files:**
- Create: `android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/VoiceOfflineHandler.kt`,
  `android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/RecognizerSelection.kt`
- Modify: `VoiceChannel.kt`, `VoiceCapture.kt` (same package dir `com/tarkilhk/wing/`)

**Interfaces:**
- Produces (Kotlin, package `com.tarkilhk.wing.voiceoffline`):

```kotlin
class VoiceOfflineHandler(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val emit: (Map<String, Any>) -> Unit,
) {
    /** Handles fork-only voice calls; returns false for calls it does not own.
     *  "startVad" is routed by VoiceChannel itself (it shares the mic-permission request). */
    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean
    /** The "startVad" half of VoiceChannel.start (permission already granted). */
    fun startVad(id: String, call: MethodCall, result: MethodChannel.Result)
    fun cancel(id: String)                       // vad.cancel(id)
    fun permissionResult(requestCode: Int, grants: IntArray): Boolean
    /** True when the background voice service keeps the mic (BackgroundVoiceService.keepsVoice()). */
    fun keepsVoice(): Boolean
    fun pauseVad()                               // vad.pause()
    fun pauseMediaKeys()                         // mediaKeys.pause()
    fun resume()                                 // mediaKeys.resume()
    fun closeRoutes()                            // background.close(); route.close()
    fun closeKeys()                              // mediaKeys.close(); clear FLAG_KEEP_SCREEN_ON
    fun close()                                  // vad, micRoute, debugStore, speech, models .close()
}
```

The split `pause*`/`close*` methods exist only to keep today's call order exactly (see Step 2).

`RecognizerSelection.kt`:

```kotlin
internal fun onDeviceRecognition(activity: Activity): Boolean
internal fun recognitionAvailable(activity: Activity): Boolean   // onDevice || isRecognitionAvailable
internal fun createRecognizer(activity: Activity): SpeechRecognizer
internal fun cleanTranscript(raw: String): String                // moved verbatim
```

- [ ] **Step 1: Move into `VoiceOfflineHandler`**

Move verbatim from `VoiceChannel.kt`: fields `models`, `speech`, `debugStore`, `micRoute`, `vad`,
`mediaKeys`, `background`, `route`; the `when` branches `finishVad`, `deleteVadDebugRecordings`, `vadModelStatus`, `installVadModel`, `cancelVadModelInstall`,
`removeVadModel`, `prepareVad`, `releaseVad`, `openMicLink`, `closeMicLink`, `setMediaKeys`,
`keepScreenOn`; the `startVad` half of `start()` (options, `begin`, Bluetooth permission); the two
fork `permissionResult` lines; the fork parts of `pause/resume/close`. Imports move with them.

- [ ] **Step 2: Leave hooks in `VoiceChannel.kt`**

The upstream file keeps (and only keeps) these fork lines:

```kotlin
import com.tarkilhk.wing.voiceoffline.VoiceOfflineHandler
// field
private val offline = VoiceOfflineHandler(activity, messenger, ::emit)
// in the when:
"start", "startVad" -> { /* upstream "start" body unchanged: id check, permission request or start(call, result) */ }
"stop" -> result.success(capture.stop(id, call.argument<Number>("timeoutMs")?.toLong() ?: 5000L))
"cancel" -> { /* upstream pending check */ offline.cancel(id); capture.cancel(id); result.success(null) }
"speak" -> /* upstream call + */ call.argument<List<Map<String, String>>>("segments"), result)
else -> if (!offline.handle(call, result)) result.notImplemented()
// start(): today's first line (keepPlayback condition), then
val id = call.argument<String>("id")!!
if (call.method == "startVad") { capture.cancel(id); offline.startVad(id, call, result); return }
offline.cancel(id)
/* upstream capture.start(...) and result.success(null) */
// permissionResult(): first line
if (offline.permissionResult(requestCode, grants)) return true
// pause()/resume()/close() — same order as today
fun pause() { if (offline.keepsVoice()) { capture.pause(); offline.pauseMediaKeys(); return }; capture.pause(); offline.pauseVad(); playback.stop(); offline.pauseMediaKeys() }
fun resume() { offline.resume() }
fun close() {
    offline.closeRoutes()
    pending?.second?.error("cancelled", "Recording cancelled.", null); pending = null
    offline.closeKeys()
    capture.close(); playback.close(); offline.close(); channel.setMethodCallHandler(null)
}
```

Merging the `"start"` and `"startVad"` branches into one `"start", "startVad" ->` removes the duplicated
permission block (both bodies are identical today except the error text, which is the same string —
verify with `git diff 151ee281 -- android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt` before
merging; if they differ, keep two branches).
Today's orders, which must not change: `pause()` normal path `capture.pause(); vad.pause(); playback.stop();
mediaKeys.pause()`; keep-voice path `capture.pause(); mediaKeys.pause()` (VAD is **not** paused there);
`close()` `background.close(); route.close()`, pending error, `mediaKeys.close()` + screen flag,
`capture.close(); playback.close(); vad.close(); micRoute.close(); debugStore.close(); speech.close();
models.close()`, handler null.

- [ ] **Step 3: `RecognizerSelection.kt`**

Move `onDevice()`, the `available()` body, `recognizer()` and `cleanTranscript` out of `VoiceCapture.kt`.
`VoiceCapture.kt` keeps: `fun available() = recognitionAvailable(activity)`, `languages()` uses
`onDeviceRecognition(activity)`, `recognizer = createRecognizer(activity).also { … }`, the two constants,
`stop(owner, timeoutMs)`, and the `cleanTranscript(...)` call + partial skip in `transcript()`.

- [ ] **Step 4: Check the diff**

Run: `git diff 151ee281 -- android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt android/app/src/main/kotlin/com/tarkilhk/wing/VoiceCapture.kt`
Expected: VoiceChannel ≤ ~15 added lines, VoiceCapture ≤ ~10.

- [ ] **Step 5: Compile and commit**

Run: `git add android/app/src/main/kotlin/com/tarkilhk/wing`
Run: `git commit -m "refactor(android): fork voice calls into VoiceOfflineHandler (t_ba3601fa)"`
Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: `conclusion=success`. Then Task 18's phone list covers the native paths (VAD dictation, media
keys, screen-off, car kit).

---

### Task 5: `VadVoiceDevice` split and fixture mixin **[SUITE A]**

**Files:**
- Create: `lib/voice_offline/vad_voice_device.dart`, `test/support/vad_voice_fixture.dart`
- Modify: `lib/core/services/android_voice.dart`, `test/support/voice_fixture.dart`, all importers of the
  moved types (find with grep in Step 3), `integration_test/voice_native_test.dart`,
  `integration_test/voice_permission_native_test.dart` (revert)

**Interfaces:**
- Produces:

```dart
// lib/voice_offline/vad_voice_device.dart
abstract interface class VadVoiceDevice {
  // Exactly the VAD / switch / mic-link methods that VoiceDevice has today and upstream's does not:
  // startVad, finishVad, vadModelStatus, installVadModel, cancelVadModelInstall, removeVadModel,
  // prepareVad, releaseVad, deleteVadDebugRecordings, setMediaKeys, keepScreenOn, openMicLink, closeMicLink.
  // Signatures moved verbatim.

  /// Every production and test VoiceDevice also implements VadVoiceDevice.
  static VadVoiceDevice of(VoiceDevice device) => device as VadVoiceDevice;
}

/// Platform implementation on AndroidVoice's channel; mixed into AndroidVoice.
mixin AndroidVadVoice implements VadVoiceDevice { /* bodies moved verbatim, using AndroidVoice.channel */ }

// also moved here verbatim: VadCaptureOptions, VadModelState, VadModelStatus, VoiceSwitchHolders
```

```dart
// lib/core/services/android_voice.dart (hooks)
import '../../voice_offline/vad_voice_device.dart';
abstract interface class VoiceDevice {
  Future<Uint8List?> stop(String id, {Duration timeout = const Duration(seconds: 5)});
  // ... upstream members only
}
class AndroidVoice with AndroidVadVoice implements VoiceDevice, VadVoiceDevice { … }
```

```dart
// test/support/vad_voice_fixture.dart
mixin VadVoiceFixture implements VadVoiceDevice { /* all fork fields and methods moved verbatim from VoiceDeviceFixture */ }
// test/support/voice_fixture.dart (hooks)
import 'vad_voice_fixture.dart';
class VoiceDeviceFixture with VadVoiceFixture implements VoiceDevice, VadVoiceDevice { … }
```

- [ ] **Step 1: Check where `AndroidVoice.channel` is accessible**

Run: `grep -n "channel" lib/core/services/android_voice.dart`
If the channel is a private top-level or instance member, make the mixin `mixin AndroidVadVoice on
VoiceDevice` and pass the channel through a one-line protected getter `MethodChannel get vadChannel`
declared in the mixin as abstract and implemented in `AndroidVoice` (`@override MethodChannel get
vadChannel => _channel;`). Count it among the hooks.

- [ ] **Step 2: Move the code**

Move the members and types listed above. `stop`'s `timeout` becomes optional with the 5 s default (the
native side defaults to 5000 ms when `timeoutMs` is absent, so explicit 5 s and default are identical).
Keep `AndroidVoice.stop` passing `timeoutMs: timeout.inMilliseconds` as today. Keep
`'segments': speechSegmentsPayload(text)` in `speak`.

- [ ] **Step 3: Fix importers**

Run: `grep -rlnE "VadCaptureOptions|VadModelStatus|VadModelState|VoiceSwitchHolders|startVad|finishVad|setMediaKeys|keepScreenOn|openMicLink|closeMicLink|vadModelStatus|prepareVad|releaseVad|deleteVadDebugRecordings" lib test`
For every file: add `import '<rel>/voice_offline/vad_voice_device.dart';`. Where a VAD method is called on
a `VoiceDevice` value, call it on `VadVoiceDevice.of(device)` (or store a `VadVoiceDevice` field next to the
`VoiceDevice` one when the class calls several). Do not change constructor parameter types of upstream
classes.

- [ ] **Step 4: Revert the integration tests**

Run: `git checkout 151ee281 -- integration_test/voice_native_test.dart integration_test/voice_permission_native_test.dart`
Then check that nothing else of ours was in them:
Run: `git diff 55db5f1f -- integration_test`
Expected: only the removed `timeout:` arguments.

- [ ] **Step 5: Static self-check**

Run: `git diff 151ee281 --stat -- lib/core/services/android_voice.dart test/support/voice_fixture.dart`
Expected: android_voice ≤ ~10 added lines; voice_fixture ≤ ~5.

- [ ] **Step 6: Commit and run the suite [SUITE A]**

Run: `git add lib test integration_test`
Run: `git commit -m "refactor(voice): VadVoiceDevice in own file, stop timeout default (t_ba3601fa)"`
Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`. Record the passing-test count from the run (`gh run view <id> -R
birkschmithuesen/Wing --json jobs` shows the step; if the count is not visible, record "count n/a" and use
the analyzer/test conclusion).

---

### Task 6: `VoiceOfflinePrefs`

**Files:**
- Create: `lib/voice_offline/voice_offline_prefs.dart`
- Modify: `lib/core/services/voice_preferences.dart`, `lib/core/services/config_backup_service.dart` (only if
  it needs an import), every reader of the moved fields (grep in Step 3)
- Test: `test/voice_offline/voice_offline_prefs_tryread_test.dart` (new, small)

**Interfaces:**
- Produces:

```dart
// lib/voice_offline/voice_offline_prefs.dart
enum VadAudioSource { … }   // moved verbatim
enum VoiceMicRoute { … }    // moved verbatim

class VoiceOfflinePrefs {
  // fields moved verbatim from VoicePreferences: vad pause/minSpeech/preRoll/max/noSpeech/cues/debug/source,
  // autoSpeak, conversation, listenTurn, listenMinSpeech, bargeInPlayback, micRoute; same defaults.
  const VoiceOfflinePrefs({ … });
  factory VoiceOfflinePrefs.read(SharedPreferences preferences); // same parsing as today; never throws
  static const keys = { … };      // the 14 fork keys, unchanged strings
  static bool accepts(String key, Object value); // the fork cases, unchanged
  // key constants, choice lists and defaults used by the settings UI, moved verbatim
}

/// VoicePreferences.read, or null where it throws a FormatException (unknown
/// `voice.input` / `voice.output` value) — the pattern of the screen's three try sites.
VoicePreferences? tryReadVoicePreferences(SharedPreferences preferences);
```

`VoicePreferences` keeps: `VoiceInputRoute` (with `vad`), its upstream fields, `input` parsing including
`vad`, `static const keys = { …upstream keys, ...VoiceOfflinePrefs.keys }`, and in `accepts` a last case
`_ => VoiceOfflinePrefs.accepts(key, value)` (replacing the fork cases).

- [ ] **Step 1: Write the failing test**

`test/voice_offline/voice_offline_prefs_tryread_test.dart` (package name `wing`; only `voice.input` and
`voice.output` throw today, `voice_preferences.dart` L171 and L222):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/voice_preferences.dart';
import 'package:wing/voice_offline/voice_offline_prefs.dart';

void main() {
  test('tryReadVoicePreferences returns null where read throws', () async {
    SharedPreferences.setMockInitialValues({'voice.input': 'bogus'});
    final prefs = await SharedPreferences.getInstance();
    expect(() => VoicePreferences.read(prefs), throwsFormatException);
    expect(tryReadVoicePreferences(prefs), isNull);
  });

  test('tryReadVoicePreferences reads valid values like read', () async {
    SharedPreferences.setMockInitialValues({'voice.input': 'vad'});
    final prefs = await SharedPreferences.getInstance();
    expect(tryReadVoicePreferences(prefs)?.input, VoiceInputRoute.vad);
  });

  test('fork preferences keep their defaults', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final offline = VoiceOfflinePrefs.read(prefs);
    expect(offline.listenTurn, isTrue);
    expect(offline.bargeInPlayback, isFalse);
    expect(offline.vad.pause, const Duration(milliseconds: 1800));
  });
}
```

It fails first because `voice_offline_prefs.dart` does not exist (compile error in the suite).

- [ ] **Step 2: Move the code**

Move fields, defaults, parsing, keys, `accepts` cases, enums and choice lists. `tryReadVoicePreferences`
wraps `VoicePreferences.read` in `try { … } on FormatException { return null; }` — exactly the screen's
current pattern.

- [ ] **Step 3: Update readers**

Run: `grep -rnE "\.(vad[A-Z]\w*|autoSpeak|conversation|listenTurn|listenMinSpeech|bargeInPlayback|micRoute)\b" lib --include=*.dart`
Each access on a `VoicePreferences` value becomes an access on `VoiceOfflinePrefs.read(prefs)` (or a
`VoiceOfflinePrefs` passed in). Readers in `lib/voice_offline/`, `lib/car_mode/`,
`lib/core/widgets/vad_settings_section.dart` import the new file. Do not yet change the screen's three
`try` sites; Task 13 does.

- [ ] **Step 4: Static self-check**

Run: `git diff 151ee281 --stat -- lib/core/services/voice_preferences.dart`
Expected: ≤ ~30 added lines.

- [ ] **Step 5: Commit**

Run: `git add lib test`
Run: `git commit -m "refactor(voice): fork preferences in VoiceOfflinePrefs (t_ba3601fa)"`

---

### Task 7: `VadInputRound`

**Files:**
- Create: `lib/voice_offline/vad_input_round.dart`
- Modify: `lib/core/controllers/voice_input_controller.dart`, screen construction site of
  `VoiceInputController` (`lib/core/screens/profile_workspace_screen.dart`, the `_voiceInput` field),
  `lib/car_mode/*` if it constructs one

**Interfaces:**
- Consumes: `VadVoiceDevice` (Task 5), `VoiceOfflinePrefs` (Task 6), `CarMicSession`, `VadEndpoint*`.
- Produces:

```dart
// lib/voice_offline/vad_input_round.dart
/// Local deadline for the native transcription after stop, scaled with seconds spoken.
Duration transcriptionDeadlineFor(int seconds);   // moved verbatim
String micFallbackMessage(String fallback);       // moved verbatim (keep today's signature)

class VadInputRound {
  VadInputRound({
    required VadVoiceDevice device,
    CarMicSession? carMicSession,
    bool Function()? carKitConnected,
    bool Function()? carModeActive,
  });

  /// True while a vad round owns the recording.
  bool get active;
  /// Mic fallback hint of the last round; reading it clears it.
  String? takeMicFallbackHint();
  /// Whether the last round ended by itself (endpoint), not by a user stop.
  bool get finishedOnItsOwn;

  /// Starts a vad round; same arguments the controller passes to startVad today.
  Future<void> begin(String id, VoiceOfflinePrefs prefs, {required String language});
  /// Feeds a device event; returns true when it was a vad event and was consumed.
  bool onEvent(Map<String, dynamic> event, {required void Function(String text) finish, required void Function(Object error) fail});
  /// User stop while a vad round runs (today's forceEnd path).
  Future<void> forceEnd({required void Function(String text) finish, required void Function(Object error) fail});
  void stopHandsFree();
  void clear();
}
```

The exact parameter lists follow the code being moved: if today's `startVad` call passes more values,
`begin` takes them. Keep `micFallbackHint`'s public setter only if a caller outside the screen sets it;
otherwise the screen uses `takeMicFallbackHint()` (today it reads and then sets null at
`profile_workspace_screen.dart` ~L749–751 — same effect).

- [ ] **Step 1: Move the code**

Move `_endpointer`, the vad branch of `start`, the `windows` event handling, `_finishVad`, the vad part of
`stop`, the car SCO hold (`carMicSession`, `_carKitConnected`, `_carModeActive`, `beginRound`), mic
fallback, `finishedOnItsOwn` / `_stopRequested` / `stopHandsFree`, `transcriptionDeadlineFor`,
`micFallbackMessage`.

- [ ] **Step 2: Hooks in `VoiceInputController`**

Keep only: import; constructor parameter `VadInputRound? vadRound` stored in a field (replacing the three
car parameters); in `start` `if (route == VoiceInputRoute.vad) { await vadRound!.begin(…); … return; }`
with the bookkeeping lines the vad branch shares with the normal path today; one line in the event
handler `if (vadRound?.onEvent(event, finish: _finish, fail: _fail) ?? false) return;`; in `stop`
`if (vadRound?.active ?? false) return vadRound!.forceEnd(finish: _finish, fail: _fail);`; in `_clear`
`vadRound?.clear();`; the `maxRecordingSeconds = 600` constant; forwarding getters `finishedOnItsOwn`,
`stopHandsFree()` if the screen calls them on the controller (1 line each), `stop()` passing
`timeout: transcriptionDeadlineFor(seconds)`.

- [ ] **Step 3: Construction site**

Where `VoiceInputController(…)` is built with `carMicSession:`/`carKitConnected:`/`carModeActive:`, pass
`vadRound: VadInputRound(device: VadVoiceDevice.of(device), carMicSession: …, carKitConnected: …,
carModeActive: …)` instead.

- [ ] **Step 4: Static self-check**

Run: `git diff 151ee281 --stat -- lib/core/controllers/voice_input_controller.dart`
Expected: ≤ ~40 added lines.

- [ ] **Step 5: Commit**

Run: `git add lib`
Run: `git commit -m "refactor(voice): VAD round out of VoiceInputController (t_ba3601fa)"`

---

### Task 8: `VoiceOfflineSettings` **[SUITE B]**

**Files:**
- Create: `lib/voice_offline/voice_offline_settings.dart`
- Modify: `lib/core/widgets/voice_preferences_card.dart`

**Interfaces:**
- Consumes: `VoiceOfflinePrefs`, `VadVoiceDevice`, `VadSettingsSection`, `BargeInSettings`.
- Produces:

```dart
/// Fork rows of the voice settings card: mic route, VAD settings, spoken replies,
/// conversation mode, barge-in. Rendered at the positions they have today.
class VoiceOfflineSettings extends StatefulWidget {
  const VoiceOfflineSettings({
    super.key,
    required this.preferences,   // SharedPreferences
    required this.device,        // VoiceDevice (VadVoiceDevice.of inside)
    required this.route,         // current VoiceInputRoute, from the card
    required this.part,          // VoiceOfflineSettingsPart.vadRoute | .replies
  });
}
enum VoiceOfflineSettingsPart { vadRoute, replies }

/// The "Recognize on this phone" choice of the input select (label/description unchanged).
DropdownMenuItem<VoiceInputRoute> vadInputChoice(BuildContext context);  // use the item type the card uses today

/// Prepares or releases the on-device model when the input route changes (today's _saveInput body).
Future<void> onVoiceInputRouteChanged(VoiceDevice device, VoiceInputRoute from, VoiceInputRoute to);
```

Two parts because today the rows sit at two positions (mic route + VAD section inside the vad branch;
reply/conversation switches + barge-in after the output description). Moving them to one position would
change the UI.

- [ ] **Step 1: Move the code**

Move the mic-route select + hint, `VadSettingsSection` placement, both switches, `BargeInSettings`
placement, and the prepare/release logic. State the card used for these rows (`_saving`, `_save`) is
re-created inside the new widget's state with the same save pattern (write the key, re-read, `setState`).
If the card's `_saving` flag also disables upstream rows while a fork row saves, keep that behaviour by
passing an `onSaving(bool)` callback from the card (one hook line) — check `_saving` usages first:
Run: `grep -n "_saving" lib/core/widgets/voice_preferences_card.dart`

- [ ] **Step 2: Hooks in the card**

Import; `vadInputChoice(context)` in the input select items; `await onVoiceInputRouteChanged(…)` in
`_saveInput`; `if (route == VoiceInputRoute.vad) VoiceOfflineSettings(part: VoiceOfflineSettingsPart.vadRoute, …)`;
`VoiceOfflineSettings(part: VoiceOfflineSettingsPart.replies, …)`; the 3 enum renames stay.

- [ ] **Step 3: Static self-check**

Run: `git diff 151ee281 --stat -- lib/core/widgets/voice_preferences_card.dart`
Expected: ≤ ~25 added lines.

- [ ] **Step 4: Commit and run the suite [SUITE B]**

Run: `git add lib`
Run: `git commit -m "refactor(voice): fork settings rows in VoiceOfflineSettings (t_ba3601fa)"`
Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`; the existing render tests in `test/voice_preferences_test.dart`
(320 dp @ 200 % text, both themes) pass unchanged, which proves the layout did not move.

---

### Task 9: Workspace tests into own files

**Files:**
- Create: `test/support/voice_workspace_fixture.dart`, `test/voice_offline/workspace_conversation_test.dart`,
  `test/voice_offline/workspace_listen_turn_test.dart`, `test/voice_offline/workspace_barge_in_test.dart`,
  `test/voice_offline/workspace_vad_media_keys_test.dart`, `test/voice_offline/workspace_screen_off_test.dart`,
  `test/car_mode/car_mode_workspace_test.dart`
- Modify: `test/voice_workspace_test.dart` (restore to merge-base)

**Interfaces:**
- Produces:

```dart
// test/support/voice_workspace_fixture.dart
/// Workspace harness for fork voice tests (was private in test/voice_workspace_test.dart).
class VoiceWorkspaceHarness {
  VoiceWorkspaceHarness();                 // builds what setUp built: fixture with gateways, controller,
                                           // device (VoiceDeviceFixture), background, route
  late final VoiceWorkspaceFixture fixture; // the former _Fixture subclass with `gateways` + gateway()
  late final ProfileWorkspaceController controller;
  late final VoiceDeviceFixture device;
  late final BackgroundVoiceFixture background;
  late final HeadphoneRouteFixture route;
  Future<void> setUp();                    // former setUp body
  Future<void> tearDown();                 // former tearDown body
  Future<void> show(WidgetTester tester, {String? destination});
  // helpers moved verbatim and made public: starts, prompts, settle, sayFinal, completeReply,
  // conversationMode, vadRoute, gatewayEvent, openCarMode, tapCar, toggleCarLoop, swipeOut, …
}
```

- [ ] **Step 1: Inventory**

Run: `git diff 151ee281 HEAD -- test/voice_workspace_test.dart`
List every added `testWidgets`/`test`/`group` name into the task notes (expected ~64 cases, spec §4.3).

- [ ] **Step 2: Build the harness**

Copy the upstream file's private `_Fixture`, controller construction, `show()` and our helpers into the
harness, public names, no logic change. The harness passes `backgroundVoice`, `headphoneRoute` and
`initialDestination` to `ProfileWorkspaceScreen` exactly as our modified `show()` does today.

- [ ] **Step 3: Move the tests**

Move each added test verbatim into the file of its group (spec §4.3 table): conversation loop →
`workspace_conversation_test.dart`; listen-while-working → `workspace_listen_turn_test.dart`; read-aloud
barge-in + route → `workspace_barge_in_test.dart`; VAD conversation + media keys + lifecycle →
`workspace_vad_media_keys_test.dart`; `group('screen off')` → `workspace_screen_off_test.dart`; car mode →
`test/car_mode/car_mode_workspace_test.dart`. Each file: `late VoiceWorkspaceHarness h; setUp(() async { h
= VoiceWorkspaceHarness(); await h.setUp(); }); tearDown(() => h.tearDown());` and `h.` prefixes.
The `_liveWorkspaces` static counter test (former L1160) must run in a file where no other workspace is
left mounted between tests — keep it in `workspace_vad_media_keys_test.dart` with its original neighbours.

- [ ] **Step 4: Restore the upstream test file**

Run: `git checkout 151ee281 -- test/voice_workspace_test.dart`
Run: `grep -c "testWidgets(\|test(" test/voice_workspace_test.dart`
Run: `grep -rc "testWidgets(\|test(" test/voice_offline/workspace_conversation_test.dart test/voice_offline/workspace_listen_turn_test.dart test/voice_offline/workspace_barge_in_test.dart test/voice_offline/workspace_vad_media_keys_test.dart test/voice_offline/workspace_screen_off_test.dart test/car_mode/car_mode_workspace_test.dart`
Expected: the moved count equals the count of added cases from Step 1 (loops count once per source line).

- [ ] **Step 5: Commit**

Run: `git add test`
Run: `git commit -m "test(voice): fork workspace tests into own files (t_ba3601fa)"`
(The suite runs at Task 10's checkpoint.)

---

### Task 10: Remaining tests into own files **[SUITE C]**

**Files:**
- Create: `test/support/voice_settings_fixture.dart`, `test/voice_offline/voice_offline_prefs_test.dart`,
  `test/voice_offline/voice_offline_settings_test.dart`, `test/voice_offline/transcription_deadline_test.dart`
- Modify: `test/voice_preferences_test.dart`, `test/voice_processing_test.dart`

- [ ] **Step 1: `voice_preferences_test.dart`**

Run: `git diff 151ee281 HEAD -- test/voice_preferences_test.dart`
Move the added `read/accepts/keys` tests (autoSpeak, conversation, vad route/settings, barge-in prefs,
mic route) to `voice_offline_prefs_test.dart`, the widget tests (microphone choice, listen settings, echo
probe, `showBargeIn` loops and renders) to `voice_offline_settings_test.dart`. Copy the private `show`,
`screenshot`, `capture`, `frame` helpers and the font `setUpAll` into `test/support/voice_settings_fixture.dart`
(public names). The `com.tarkilhk.wing/headphone_route` method-channel mock `setUp` goes with the widget
tests. In the upstream file keep only: the 4 `VoiceProcessing`→`VoiceInputRoute` swaps and the
`expect(saved.autoSpeak, isFalse)` line **only if** the existing upstream test needs it to stay green;
otherwise move that assertion too.

- [ ] **Step 2: `voice_processing_test.dart`**

Move "stop() asks the native layer to wait longer for longer recordings" to
`transcription_deadline_test.dart`. Keep the enum swaps and the retitled maximum-duration test (it
changes an existing upstream assertion; spec §4.3).

- [ ] **Step 3: Counts**

Run: `git diff 151ee281 --stat -- test/voice_preferences_test.dart test/voice_processing_test.dart`
Expected: voice_preferences_test ≤ ~6 added lines, voice_processing_test ≤ ~12.

- [ ] **Step 4: Commit and run the suite [SUITE C]**

Run: `git add test`
Run: `git commit -m "test(voice): fork preference and processing tests into own files (t_ba3601fa)"`
Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`, test count equal to SUITE A's plus the 3 tests of
`voice_offline_prefs_tryread_test.dart` (Task 6).

---

### Task 11: Network gate, completed replies, session source

**Files:**
- Create: `lib/fork/network_gate.dart`, `lib/voice_offline/completed_replies.dart`, `lib/fork/offline_queue.dart`,
  `test/fork/network_gate_test.dart`, `test/fork/registry_network_test.dart`, `test/fork/offline_queue_test.dart`
- Modify: `lib/core/services/server_connection_status.dart`, `lib/core/services/profile_workspace_controller.dart`,
  `lib/core/services/profile_gateway.dart`, `lib/core/services/wing_session_source.dart`,
  `test/server_connection_status_test.dart` (restore), `test/profile_workspace_registry_test.dart` (restore),
  `test/profile_workspace_controller_test.dart`

**Interfaces:**
- Produces:

```dart
// lib/fork/network_gate.dart
/// Device-network loss as reported by the platform; while lost, the server is shown offline at once.
class NetworkGate {
  NetworkGate(this._changed);
  final void Function() _changed;
  bool _available = true;
  bool get available => _available;
  void lost();      // body of today's ServerConnectionStatus.networkLost minus the shared notify
  void restored();  // body of today's networkRestored
}

// lib/voice_offline/completed_replies.dart
class CompletedReplies {
  Stream<({ProfileChat chat, String text})> get stream;
  void offer(ProfileChat chat, String text);   // call only where today's `.add` is
  Future<void> close();
}

// lib/fork/offline_queue.dart
bool queuedHeadDelivered(/* exact params of today's _queuedHeadDelivered */);

// lib/core/services/wing_session_source.dart (additions)
extension WingGatewaySource on ProfileGateway {
  void noteReady(Map<String, dynamic>? ready);   // sets the advertised flag (Expando<bool>)
  String sourceFor(String fallback);             // today's sessionSource getter logic
}
```

Keep public names that callers use today: `ServerConnectionStatus.networkLost()` / `networkRestored()` /
`networkAvailable` stay as one-line delegates (the controller, registry and tests call them).

- [ ] **Step 1: Write the failing test for the gateway extension**

`test/wing_session_source_test.dart` already covers `sessionSource` (L73–83). Change those assertions to
call `gateway.noteReady(...)` / `gateway.sourceFor('desktop')` instead of the field/getter; run nothing
locally; the suite at Task 12 proves it.

- [ ] **Step 2: Move the code**

`NetworkGate`: field, getter, both methods out of `server_connection_status.dart`; the status keeps
`late final networkGate = NetworkGate(_changed);`, `bool get networkAvailable => networkGate.available;`,
the `phase` early-return line, and the two delegates. `CompletedReplies`: the `StreamController`, getter
and `close`; the controller keeps a field, the `offer` call, the `close` call and
`Stream<…> get completedReplies => _replies.stream;`. `_queuedHeadDelivered` body → `queuedHeadDelivered`.
The offline-queue gates in `_sendPrompt` / `_drainQueuedPrompts` and the reconnect head check **stay**
(spec §4.1: upstream moved the queue to `ComposerSession`; they are re-implemented there at merge).
Gateway: field + getter → extension with `Expando<bool>`; `profile_gateway.dart` keeps the import,
`gateway.noteReady(ready)`, and `'source': gateway.sourceFor(...)` in create and resume.

- [ ] **Step 3: Move the tests**

`test/server_connection_status_test.dart` addition → `test/fork/network_gate_test.dart`;
`test/profile_workspace_registry_test.dart` addition → `test/fork/registry_network_test.dart` (copy the
`registry` + `identityTestConnection()` setup); the 3 new tests from `test/profile_workspace_controller_test.dart`
→ `test/fork/offline_queue_test.dart` (import `Host` from the upstream test file as 30+ tests already do).
Then:
Run: `git checkout 151ee281 -- test/server_connection_status_test.dart test/profile_workspace_registry_test.dart`
`test/profile_workspace_controller_test.dart` keeps `Host.promptSubmitFailures` (3 lines) and the
`controller.networkRestored();` line in the resume test.

- [ ] **Step 4: Static self-check and commit**

Run: `git diff 151ee281 --stat -- lib/core/services test/profile_workspace_controller_test.dart`
Expected: server_connection_status ≤ ~8, profile_gateway ≤ ~5, profile_workspace_controller ≤ ~70.
Run: `git add lib test`
Run: `git commit -m "refactor(fork): network gate, completed replies, session source in own files (t_ba3601fa)"`

---

### Task 12: Inline MEDIA thumbnail **[SUITE D]**

**Files:**
- Create: `lib/fork/inline_media_thumbnail.dart`, `test/fork/inline_media_thumbnail_test.dart`
- Modify: `lib/core/widgets/deliverable_attachment.dart`, `test/deliverable_attachment_test.dart` (restore)

**Interfaces:**
- Produces:

```dart
/// Inline thumbnail for an image deliverable; falls back to [card] while loading or on error.
class InlineMediaThumbnail extends StatefulWidget {
  const InlineMediaThumbnail({
    super.key,
    required this.path,
    required this.load,      // Future<Uint8List> Function(String path) — today's onLoadImage
    required this.card,      // Widget: the file card (today's _card())
    required this.actions,   // Widget: the Download/Open-preview row (today's _actions())
    required this.onOpen,    // VoidCallback: today's _openPreview
  });
  static bool handles(String path);   // today's _inlineImageExtension check
}
```

- [ ] **Step 1: Move the code**

Move `_inlineImageExtension`, `_minThumbnailHeight`, the static `_imageCache`, `_loadImage`, `_imageCard()`
and the `FutureBuilder`. `deliverable_attachment.dart` keeps the `onLoadImage` field and constructor param,
`_actions()`/`_card()`/`_openPreview` if upstream had their content inline (restore the inline form when the
split was only for our feature, and pass closures instead), and one branch in `build`:

```dart
final load = onLoadImage;
if (load != null && InlineMediaThumbnail.handles(path)) {
  return InlineMediaThumbnail(path: path, load: load, card: card, actions: actions, onOpen: open);
}
```

- [ ] **Step 2: Move the tests**

Move the 5 thumbnail tests + `testPngBytes`, `thumbnailImages()` and a local `message()` with
`onLoadRemoteImage` and the `reportPath`/`htmlReportPath` constants into
`test/fork/inline_media_thumbnail_test.dart`.
Run: `git checkout 151ee281 -- test/deliverable_attachment_test.dart`

- [ ] **Step 3: Self-check, commit, suite [SUITE D]**

Run: `git diff 151ee281 --stat -- lib/core/widgets/deliverable_attachment.dart`
Expected: ≤ ~15 added lines.
Run: `git add lib test`
Run: `git commit -m "refactor(fork): inline MEDIA thumbnail in own widget (t_ba3601fa)"`
Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`.
Run: `bash tools/factory/upstream-diff-metrics.sh`

---

### Tasks 13–16: Workspace screen → `WorkspaceVoiceDriver`

Shared interface for all four tasks (created in Task 13, extended by 14–16):

```dart
// lib/voice_offline/workspace_voice_driver.dart
/// What the workspace screen offers the fork voice driver. Implemented by
/// ProfileWorkspaceScreenState, so the screen keeps only one-line hooks.
abstract interface class WorkspaceVoiceHost {
  bool get mounted;
  ProfileWorkspaceController get controller;
  ProfileChat? get currentChat;
  bool get routeIsCurrent;
  bool get appIsActive;
  VoiceInputController get voiceInput;
  VoiceOutputController get voiceOutput;
  Future<void> dictate(ProfileChat chat, {bool resume = false});
  Future<void> performComposerAction(ProfileChat chat, ComposerAction action, {bool conversation = false});
  void showVoiceError(String message);
  void refresh();   // setState(() {}) on the screen
}

class WorkspaceVoiceDriver extends ChangeNotifier {
  WorkspaceVoiceDriver({
    required WorkspaceVoiceHost host,
    required VoiceDevice device,
    BackgroundVoiceHost? background,
    HeadphoneRouteHost? headphones,
  });
  void attach();                       // initState part
  void detach();                       // dispose part
  void endLoop();                      // _conversation = null
  // Task 13: conversation loop
  void onDictated(ProfileChat chat);   // post-dictation send in conversation mode
  // Task 14: listen rounds / barge-in
  void routeChanged(bool current);
  // Task 15: VAD route, media keys, background, lifecycle
  bool keepsVoice(AppLifecycleState state);
  void lifecycle(AppLifecycleState state);
  // Task 16: car mode
  bool get carActive;
  Future<void> enterCarMode(BuildContext context);
  Widget? activity(BuildContext context);  // listening row + stop buttons, null when idle
  void cancel();
}
```

```dart
// lib/voice_offline/chat_voice_view.dart
/// The ProfileChat fields the fork voice driver reads. At the upstream merge only this file
/// follows upstream's chat.composer / chat.runtime split.
extension ChatVoiceView on ProfileChat {
  bool get voiceBusy;            // today: chat.busy
  String get voiceDraft;         // today: chat.draft
  bool get needsUserInput;       // today's _needsUserInput(chat)
  ListenChatState get listenState; // today's _listenState(chat)
}
```

Getters that exist only to satisfy the host interface are added to the screen state as one-liners next to
the fields they expose. Each task moves only its own members; members still used by not-yet-moved screen
code are reached through the driver's public getter for that task's duration.

### Task 13: Driver skeleton + conversation loop

**Files:**
- Create: `lib/voice_offline/workspace_voice_driver.dart`, `lib/voice_offline/chat_voice_view.dart`
- Modify: `lib/core/screens/profile_workspace_screen.dart`

- [ ] **Step 1: Move**

Into the driver: `_conversation` (field + setter body), `_conversationAwaitingReply`, `_voiceInputChanged`,
`_autoSpeakQueue`, `_speakCompletedReply`, `_canContinueConversation`, `_sendConversationTurn`, `_carSend`,
the `completedReplies` subscription. `_needsUserInput` → `ChatVoiceView.needsUserInput`.
Every `_conversation = null` in the screen becomes `_voice.endLoop();` (spec §6 removal: same assignment).
The three `try { VoicePreferences.read … } on FormatException` sites (screen ~L556, ~L619, ~L640) become
`tryReadVoicePreferences(controller.preferences)` with the same null handling (fork fields then come
from `VoiceOfflinePrefs.read`, which never throws).
Delete the stale `decideDelivery` comment (spec §6; `grep -rn decideDelivery lib` must print nothing).

- [ ] **Step 2: Hooks**

Screen: `implements WorkspaceVoiceHost` + its one-line getters; `late final _voice = WorkspaceVoiceDriver(host: this, device: widget.voiceDevice ?? AndroidVoice.instance, background: widget.backgroundVoice, headphones: widget.headphoneRoute);`;
`_voice.attach()` / `_voice.detach()`; in `_dictate`'s completion `_voice.onDictated(chat);`.

- [ ] **Step 3: Self-check and commit**

Run: `git diff 151ee281 --stat -- lib/core/screens/profile_workspace_screen.dart`
Expected: added lines fall by roughly the size of the moved members (~240).
Run: `git add lib`
Run: `git commit -m "refactor(voice): conversation loop into WorkspaceVoiceDriver (t_ba3601fa)"`

### Task 14: Listen rounds, barge-in, headphones **[SUITE E]**

**Files:** Modify `lib/voice_offline/workspace_voice_driver.dart`, `lib/core/screens/profile_workspace_screen.dart`

- [ ] **Step 1: Move**

`_bargeIn` (coordinator), `_headphones`, `_carKitConnected`, `_listenState`, `_listenTarget`,
`_openListen`, `_playbackBargeIn`, `_headphoneRouteChanged`. The screen calls `_voice.routeChanged(current)`
where it reacts to destination/route changes today.

- [ ] **Step 2: Commit and suite [SUITE E]**

Run: `git add lib`
Run: `git commit -m "refactor(voice): listen rounds and barge-in into WorkspaceVoiceDriver (t_ba3601fa)"`
Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`. The own tests from Task 9 (`workspace_conversation`, `workspace_listen_turn`,
`workspace_barge_in`) are the guard.

### Task 15: VAD route, media keys, background, lifecycle

**Files:** Modify `lib/voice_offline/workspace_voice_driver.dart`, `lib/core/screens/profile_workspace_screen.dart`

- [ ] **Step 1: Move**

`_background`, `_syncVadRoute`, `_vadRoute`, `_syncMediaKeys`, `_mediaKeysOn`, `_voiceDeviceEvent` +
subscription, `_liveWorkspaces` (static — keep it static on the driver, same increments/decrements at the
same lifecycle points), `_loopFocus`, the fork part of `didChangeAppLifecycleState` (`_voice.lifecycle(state)`
plus `if (_voice.keepsVoice(state)) return;` before the upstream cancel), screen-on hold.

- [ ] **Step 2: Commit**

Run: `git add lib`
Run: `git commit -m "refactor(voice): VAD route, media keys and lifecycle into WorkspaceVoiceDriver (t_ba3601fa)"`

### Task 16: Car mode and activity row **[SUITE F]**

**Files:** Modify `lib/voice_offline/workspace_voice_driver.dart`, `lib/core/screens/profile_workspace_screen.dart`,
the screen's constructor callers (grep `backgroundVoice:` / `headphoneRoute:` in `lib` and `test`)

- [ ] **Step 1: Move**

`_carMic`, `_car` (`CarModeSession`), `_carActiveChanged`, the car menu entry action (the `PopupMenuItem`
itself stays as a hook: 3 lines), the listening row + stop buttons of `_voiceActivity` →
`_voice.activity(context)`, `_hasWorkspaceFocus`'s car term → `_voice.carActive`, `_cancelVoice`'s fork part
→ `_voice.cancel()`.

- [ ] **Step 2: Constructor**

Keep `backgroundVoice` and `headphoneRoute` constructor parameters as they are (2 fields + 2 params). Do
**not** fold them into one options object: test callers (`VoiceWorkspaceHarness`) pass them, and the
change would only move lines around.

- [ ] **Step 3: Self-check**

Run: `git diff 151ee281 --stat -- lib/core/screens/profile_workspace_screen.dart`
Expected: ≤ ~70 added lines (target ~60, spec §4.1).
Run: `grep -nE "_conversation = null|on FormatException|decideDelivery" lib/core/screens/profile_workspace_screen.dart`
Expected: no output.

- [ ] **Step 4: Commit and suite [SUITE F]**

Run: `git add lib test`
Run: `git commit -m "refactor(voice): car mode and activity row into WorkspaceVoiceDriver (t_ba3601fa)"`
Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`.

---

### Task 17: Sweep for leftovers

**Files:** any upstream file still in metrics (a) with more than its spec §4 target.

- [ ] **Step 1: Measure**

Run: `bash tools/factory/upstream-diff-metrics.sh`
Compare each line of (a) with the spec §4 targets. For each file over target, look at the remaining hunk
(`git diff 151ee281 -- <file>`) and either move it (same rules) or record why it must stay.

- [ ] **Step 2: Unused imports and dead private members created by the moves**

Run: `git diff 151ee281 -U0 -- lib | grep -E "^\+import"`
For each added import in an upstream file, check it is still used in that file (`grep -n <Symbol> <file>`);
remove unused ones. `flutter analyze` in the next suite run is the final check.

- [ ] **Step 3: Verify the removal list (spec §6)**

Run: `grep -rn "decideDelivery" lib`
Run: `grep -rnc "_conversation = null" lib`
Expected: no hits for both. Every "Kept, open" item still exists (spot-check `VoiceDebugStore.kt`,
`bargeInPlaybackAvailable`, the `pr-quality.yml` annotation block).

- [ ] **Step 4: Commit**

Run: `git add lib test docs`
Run: `git commit -m "refactor: sweep leftover fork hunks in upstream files (t_ba3601fa)"`

---

### Task 18: Final merge, measurement, docs **[SUITE final] [NATIVE final]**

**Files:**
- Modify: `CHANGELOG.fork.md`
- Modify (outside the repo, not committed here): `/home/birk/hermes-shared/hermes-entities/tools/technik/wing-fork-upstream-strategie.md`

- [ ] **Step 1: Take the latest `voice-offline`**

Run: `git fetch origin`
Run: `git merge origin/voice-offline`
If another card merged in meanwhile and touched upstream files (check with the metrics script), move its
new hunks the same way (one extra commit) before measuring. Merge conflicts in own files: resolve keeping
both changes; stop and ask (`FRAGE:`) if a conflict touches behaviour.

- [ ] **Step 2: Suite and native build**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`, test count ≥ SUITE A's count.
Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: `conclusion=success`.

- [ ] **Step 3: Final metrics**

Run: `git fetch upstream`
Run: `bash tools/factory/upstream-diff-metrics.sh HEAD upstream/main`
Run: `bash tools/factory/upstream-diff-metrics.sh 55db5f1f upstream/main`
The second run re-measures the "before" against the same upstream tip, so before/after compare like with
like even if upstream moved since 2026-11-11.

- [ ] **Step 4: Changelog**

Add at the top of `CHANGELOG.fork.md` under today's date:

```markdown
### Internal: fork code moved out of upstream files (no behaviour change)
- **What:** Fork logic that lived inside upstream-owned files moved into fork-owned files
  (`lib/voice_offline/`, `lib/fork/`, `voiceoffline/VoiceOfflineHandler.kt`, `voice-offline.gradle.kts`,
  own test files); upstream files keep thin hooks. Lines in upstream files: +<before> → +<after>;
  probe-merge conflicts against `upstream/main` <sha>: <files>/<blocks> → <files>/<blocks>.
- **Why:** Birk 2026-11-11: own code in own files keeps every later upstream merge small; the upstream
  merge card t_d1d49ff1 runs after this one.
- **Merge:** pending · **Card:** t_ba3601fa
```

Run: `git add CHANGELOG.fork.md`
Run: `git commit -m "docs(changelog): upstream-compatibility refactor (t_ba3601fa)"`

- [ ] **Step 5: Strategy doc**

Edit the strategy doc (path above): replace "Abschluss-Refactoring" with the new file layout (the file map of
this plan, as built), the before/after numbers from Step 3, and the open items for `t_d1d49ff1` from spec §6
(route key `voice.input=vad`, inline image vs `ChatInlineImage`, duplicate manifest permissions,
`BackgroundVoiceService` vs `LiveVoiceService`, native guards, `roots.json`/`roles.json` entries,
`NetworkGate` semantics, offline queue → `ComposerSession`). German, matching the doc. Not a repo commit.

- [ ] **Step 6: Closing comment**

Write the card's closing comment: start commit (Task 0), end commit, suite run ids (A–F, final), native run
ids, metrics before/after (both TOTAL lines each), files still over their spec target with the reason,
every "kept, open" item, and the manual phone test for Birk:

1. Dictation ends by itself (VAD route: speak one sentence, stay silent; the round ends without a tap).
2. Long dictation complete (2–3 min on the VAD route and on the Hermes route; full text arrives).
3. Conversation mode: several rounds hands-free, read-aloud, barge-in with headphones, media key.
4. Plus from the native tasks: screen-off background voice, car kit (if available), app id/label
   "Wing Voice" next to the official Wing.

The implementer cannot run these; the card stays open for Birk's result.

---

## Self-review notes

- Spec §4.1–4.4 rows each map to a task: android_voice → 5; voice_preferences → 6; voice_input_controller
  → 7; voice_output_controller → unchanged (spec); card → 8; screen → 13–16; controller/status/gateway/
  registry → 11; deliverable/markdown/profile_message → 12 (plumbing unchanged); gradle → 3; VoiceChannel,
  VoiceCapture → 4; VoicePlayback, manifest, MainActivity → unchanged (spec); tests → 5, 9, 10, 11, 12;
  docs/.gitignore → 2; pr-quality/AGENTS/README → unchanged (spec).
- Spec §5 → Task 1; §6 removals → Tasks 4 (duplicate permission block), 5 (integration tests), 13
  (`endLoop`, `tryReadVoicePreferences`, comment), 17 (verification); §8 → Tasks 5/8/10/12/14/16/18.

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
questions `Q1`..`Q11` with Birk's decisions (§13), the regression suite R1-R8 (§14) and the differences ledger (§15). Read §0, §5, §6, §7, §9, §11, §13, §14 and §15 before starting. Where a
step below says "per spec <ID>", the spec row contains the exact code to write.

## Global Constraints

- **Governing rule (Birk, 2026-11-12): "As a Wing user he must notice NOTHING from the merge except
  improvements."** Every task respects it: the daily-flow regression suite R1-R8 (spec §14) is written and
  green **before** the merge (Tasks 1a, 1b) and must be green after it with unchanged expectations (Task 15);
  every other user-visible difference goes to Birk as one question before the [Merge] card (Task 18).
- **Hard requirement:** the dictation limit stays 10 minutes (600 s) on every route; never upstream's 120 s
  (spec §6 S1/S9, R4).
- **Regression files `test/regression/daily_flow_*_test.dart`:** after Task 1a, any task whose API change breaks
  them (Tasks 4, 7, 9, 10, 11) adapts only the lines between `// SETUP` markers, imports and Table C renames, in
  the same commit. `expect(...)`, matchers and `reason:` texts never change (checked in Task 15 Step 4).
- **Branch:** work branch `wt/t_d1d49ff1`, created from `origin/plan/t_dcfc9770` (= `origin/voice-offline`
  b3178398 at Stand 2026-11-12 + the spec/plan commits; Task 1). Commit only there. **Never commit to, merge into or push `voice-offline`**
  (a push there triggers `voice-apk.yml` publishing). The merge into `voice-offline` is a separate [Merge]
  card. No push except what the two factory scripts do themselves (`ci/<sha>`, `ci-voice-apk*/<sha>` refs).
- **MERGE, no rebase.** Exactly one `git merge --no-ff upstream/main`. No cherry-picks of upstream commits.
- **Stock Hermes only.** No backend patch, plugin or custom endpoint. Upstream's live-call code ships as
  upstream wrote it (Q2=A decided); the fork adds nothing that needs the Wing plugin.
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
- **Birk's decisions (2026-11-12, spec §13):** Q1=A (engine row; stored values migrate, behaviour identical),
  Q2=A, Q3=A, Q4=A (upstream `ChatInlineImage`; our `InlineMediaThumbnail` removed), Q5=A, Q6=B (keep our
  automatic queue resume), Q7=A, Q8=A (one-time step before install, handled by the installer/device card,
  not by this coder card), Q9=A, Q10=A, Q11=A (if CI rejects the S6 recipe, maintain a fork edit of
  upstream's `VoicePermissionLifecycleGuard`). No task asks these again.
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

### Task 1a: Daily-flow regression suite R1-R8 on the pre-merge base

Birk's current daily flow as automated tests, written on `wt/t_d1d49ff1` **before** `git merge upstream/main`
(spec §14). Each file copies the named existing tests verbatim (bodies, helpers they need, imports) so the
suite survives the rewrites of the original files during the merge.

**Files:**
- Create: `test/regression/daily_flow_conversation_loop_test.dart` (R1)
- Create: `test/regression/daily_flow_unsolicited_reply_test.dart` (R2)
- Create: `test/regression/daily_flow_media_test.dart` (R3)
- Create: `test/regression/daily_flow_dictation_limit_test.dart` (R4)
- Create: `test/regression/daily_flow_queue_resume_test.dart` (R5)
- Create: `test/regression/daily_flow_offline_indicator_test.dart` (R6)
- Create: `test/regression/daily_flow_screen_off_test.dart` (R7)
- Create: `test/regression/daily_flow_barge_in_hint_test.dart` (R8)

Every test name starts with `R<n>: ` so the CI annotations name the item. Group per file:
`group('R<n> <item>', () { … });`.

- [ ] **Step 1: R1** — copy from `test/voice_offline/workspace_conversation_test.dart` the tests "conversation
mode sends a dictation that ended on its own" (l.15) and "conversation reopens the microphone after the reply
was spoken" (l.159), and from `test/voice_offline/workspace_vad_media_keys_test.dart` "vad conversation sends
after the pause" (l.44), with the fixture imports they use (`test/support/voice_workspace_fixture.dart` etc.).

- [ ] **Step 2: R2** — copy from `workspace_conversation_test.dart` "an unsolicited reply while recording
queues instead of cutting the recording off or ending the loop" (l.284), "an unsolicited reply while idle is
spoken and the loop stays on" (l.332), "a reply that arrives while one plays queues instead of cutting it off"
(l.189).

- [ ] **Step 3: R3** — copy `test/voice_processing_test.dart` "MEDIA reference lines are not read aloud"
(l.318) and add this widget test (the image half of `test/fork/inline_media_thumbnail_test.dart` l.66, written
so it holds for our thumbnail now and for upstream's `ChatInlineImage` after the merge):

```dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/chat_output.dart';
import 'package:wing/core/widgets/chat_image_preview.dart';
import 'package:wing/core/widgets/deliverable_attachment.dart';
import 'package:wing/core/widgets/profile_message.dart';

final _png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7'
    'gP9i18U1AAAAABJRU5ErkJggg==',
  ),
);

// SETUP (the only lines that may change at the merge): how the message gets
// its image loader. Pre-merge: onLoadRemoteImage (ChatOutput). Post-merge:
// loadAttachmentImage (String path) feeding upstream's ChatInlineImage.
Widget _message(String text, Future<Uint8List> Function(String path) load) =>
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProfileMessage(
            message: {'role': 'assistant', 'content': text},
            onLoadRemoteImage: (ChatOutput output) => load(output.path!),
          ),
        ),
      ),
    );

void main() {
  testWidgets('R3: an image deliverable shows inline and opens the preview on tap', (
    tester,
  ) async {
    final requested = <String>[];
    await tester.pumpWidget(
      _message('MEDIA:/srv/screenshot.png', (path) async {
        requested.add(path);
        return _png;
      }),
    );
    await tester.pumpAndSettle();
    final inline = find.descendant(
      of: find.byType(DeliverableAttachment),
      matching: find.byType(Image),
    );
    expect(inline, findsOneWidget);
    expect(requested, ['/srv/screenshot.png']);
    await tester.tap(inline);
    await tester.pumpAndSettle();
    expect(find.byType(ChatImagePreview), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
```
(`ChatOutput` import only needed pre-merge; remove it with the setup change.)

- [ ] **Step 4: R4** — copy the duration part of `test/voice_processing_test.dart` "recording is bounded at the
new maximum duration and native errors leave the draft untouched" (l.269: no stop after 121 s, stop at
`VoiceInputController.maxRecordingSeconds`) and `workspace_vad_media_keys_test.dart` "recording status shows
the default vad limit of 10 minutes" (l.233, `Recording · 0s / 600s`). Add:

```dart
  test('R4: the maximum dictation is 10 minutes', () {
    expect(VoiceInputController.maxRecordingSeconds, 600);
  });

  test('R4: the native recorder uses the 10-minute constant, never 120 s', () {
    final source = File(
      'android/app/src/main/kotlin/com/tarkilhk/wing/VoiceCapture.kt',
    ).readAsStringSync();
    expect(source, contains('MAX_RECORDING_MS = 600_000'));
    expect(source, contains('setMaxDuration(MAX_RECORDING_MS)'));
    expect(source, contains('MAX_RECORDING_MS + RECORDING_DEADLINE_BUFFER_MS'));
    expect(
      RegExp(r'\b12[05]_?000\b').hasMatch(source),
      isFalse,
      reason: 'no 120 s / 125 s literal may come back with an upstream merge',
    );
  });
```
In the copied widget test add after the existing expectation:
`expect(find.textContaining('/ 120s'), findsNothing);`. (`flutter test` runs from the repo root, so the
relative `File` path resolves; imports `dart:io` and `package:wing/core/controllers/voice_input_controller.dart`.)
This static guard is R4-native (spec §6 S1): `VoiceCapture` needs an `Activity` and a `SpeechRecognizer`, so a
Kotlin unit test cannot exercise it; the guard proves both call sites use the 600 000 ms constant.

- [ ] **Step 5: R5** — copy `test/fork/offline_queue_test.dart` test 2 "a flaky send right after reconnect
resolves on the next reconnect instead of sticking forever" (l.79) and `workspace_conversation_test.dart` "a
flaky send right after reconnect does not end the conversation; the mic reopens once it drains" (l.92).

- [ ] **Step 6: R6** — copy `test/fork/network_gate_test.dart` (l.5) and `offline_queue_test.dart` test 1 "a
message queued during a real network outage shows offline at once and sends exactly once on reconnect" (l.36).
Add `expect(controller.connectionStatus.description, 'Disconnected');` right after `networkUnavailable()`
(`ServerConnectionStatus.description` exists on both sides; upstream's `server_connection_status.dart:96`
still returns `'Disconnected'`).

- [ ] **Step 7: R7** — copy `test/voice_offline/workspace_screen_off_test.dart` "a vad conversation holds while
it runs" (l.41), "reading continues and the microphone reopens" (l.65), "a reply that arrives with the screen
off is spoken" (l.93) with their `group` setup.

- [ ] **Step 8: R8** — copy `test/voice_offline/workspace_barge_in_test.dart` "the message after a barge-in
carries the interrupted-reply hint" (l.228), `test/voice_offline/barge_in_policy_test.dart` "the
interrupted-reply hint follows the words after a blank line" (l.147),
`test/voice_offline/barge_in_coordinator_test.dart` "words that cut off read-aloud carry the hint when sent or
queued" (l.114), and pin the text:

```dart
  test('R8: the interrupted-reply hint text', () {
    expect(
      withInterruptedReplyHint('Testsatz zwei, stopp '),
      'Testsatz zwei, stopp\n\n[Hinweis von Wing: Die vorige Antwort wurde '
      'beim Vorlesen abgebrochen und nicht zu Ende gehört.]',
    );
  });
```

- [ ] **Step 9: Mark the setup lines** — in every regression file put the fixture/constructor/loader lines that
the merge may have to adapt between `// SETUP` comments (as in Step 3). Expectations stay outside them.

- [ ] **Step 10: Commit**

```bash
git add test/regression
git commit -m "test(regression): daily-flow suite R1-R8 before the upstream merge (t_d1d49ff1)

Spec §14. Copies of the existing tests that prove Birk's daily flow,
plus the 10-minute static guard and the hint text pin.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
Run: `git rev-parse HEAD` — note it as `<pre-merge-regression-commit>` (Tasks 15, 17).

---

### Task 1b: [SUITE] Baseline — the regression suite describes today's behaviour

- [ ] **Step 1:** Run: `bash tools/factory/ci-suite.sh` (pre-merge workflow: push + dispatch is still correct
here because `pr-quality.yml` at this commit triggers on `push: [main]` only)
Expected: last line `ci-suite: run <id> conclusion=success …`, exit 0.

- [ ] **Step 2: On red** — a red R-test means the copy is wrong, not the app: fix the copy (missing fixture,
import) and re-run. Never loosen an expectation to get green. If an item cannot be expressed with the existing
fixtures, stop and report which item and why (`FRAGE: R<n> lässt sich vor dem Merge nicht automatisiert prüfen, weil …; reicht der Gerätetest?`).

- [ ] **Step 3:** Record the run id and URL in the card notes as the baseline proof.

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

Decided: Q1=A (engine row, values migrate), Q5=A (notice).

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
Outside the markers: `stopHandsFree`/`_vadTranscribing` assign `_phase`, not `phase`. Q5=A (decided): route VAD
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

Decided: Q3=A, Q4=A (screen side needs no image argument).

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
`_voice.cancel();` the first statement — Q3=A decided), SCR-B20 (upstream + `composerActions` delegate +
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

Decided: Q6=B (keep our automatic queue resume), Q7=A (keep NetworkGate).

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

- [ ] **Step 3: Q6=B hooks** — in `_sendPrompt`'s catch (upstream body), where the failure is settled
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

### Task 7: Resolve the message widgets (DLA, MMC, PMS) — Q4=A

Decided Q4=A (Birk 2026-11-12): upstream's `ChatInlineImage` replaces our `InlineMediaThumbnail`. R3 keeps
proving "images show inline and open the preview on tap".

**Files:**
- Modify: `lib/core/widgets/deliverable_attachment.dart` (DLA-B1..B4)
- Modify: `lib/core/widgets/markdown_message_content.dart` (MMC-B1..B6)
- Modify: `lib/core/widgets/profile_message.dart` (PMS-B1, PMS-B2)
- Delete: `lib/fork/inline_media_thumbnail.dart`, `test/fork/inline_media_thumbnail_test.dart`

- [ ] **Step 1: Take upstream in every block** of the three widget files; remove every `onLoadRemoteImage` /
`onLoadImage` remnant, our `InlineMediaThumbnail` tail and its import in `deliverable_attachment.dart`. The three
files must equal upstream afterwards.

Run: `git diff upstream/main -- lib/core/widgets/deliverable_attachment.dart lib/core/widgets/markdown_message_content.dart lib/core/widgets/profile_message.dart`
Expected: no output.

- [ ] **Step 2: Remove our widget and its test**

Run: `git rm lib/fork/inline_media_thumbnail.dart test/fork/inline_media_thumbnail_test.dart`

- [ ] **Step 3: Verify and stage**

Run: `git grep -n -E "^(<<<<<<<|=======|>>>>>>>)" -- lib/core/widgets`
Expected: no output.
Run: `git grep -n -E "onLoadRemoteImage|onLoadImage|InlineMediaThumbnail|inline_media_thumbnail" -- lib test`
Expected: only `test/regression/daily_flow_media_test.dart` (its SETUP line, adapted in Task 15). No hit in `lib`.
Run: `git add lib/core/widgets/deliverable_attachment.dart lib/core/widgets/markdown_message_content.dart lib/core/widgets/profile_message.dart`

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
- DLA-B1..B4, MMC-B2/B3/B5/B6, PMS-B1 (Q4=A): InlineMediaThumbnail and its
  plumbing -> upstream ChatInlineImage / loadImage.
Upstream behaviour kept over base code: 'no_speech' notice (VCA-B4),
unlimited capped reconnect backoff (CTL-B7), session.create source 'gui'
(GWY-B3), VoiceInputActivity recording chrome (SCR-B8), minSdk 29.
Re-hung fork functions: see spec Table B rows marked "re-hang".
Birk's decisions (2026-11-12): Q1=A Q2=A Q3=A Q4=A Q5=A Q6=B Q7=A Q8=A Q9=A
Q10=A Q11=A.
Known red until follow-up commits: Table C API breaks, census/roles.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```
(Fill `<sha>`, `<n>` from Task 1.)

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

  test('migration keeps every other fork voice setting byte-identical (Q1)', () async {
    final before = <String, Object>{
      'voice.input': 'vad',
      'voice.output': 'local',
      'voice.android_language': 'de-DE',
      VoiceOfflinePrefs.autoSpeakKey: 'on',
      VoiceOfflinePrefs.conversationKey: 'on',
      VoiceOfflinePrefs.vadPauseKey: '2400',
      VoiceOfflinePrefs.vadMinSpeechKey: '400',
      VoiceOfflinePrefs.vadPreRollKey: '500',
      VoiceOfflinePrefs.vadMaxKey: '1200',
      VoiceOfflinePrefs.vadNoSpeechKey: '12',
      VoiceOfflinePrefs.vadCuesKey: 'off',
      VoiceOfflinePrefs.vadDebugKey: 'on',
      VoiceOfflinePrefs.vadSourceKey: 'recognition',
      VoiceOfflinePrefs.listenTurnKey: 'off',
      VoiceOfflinePrefs.listenMinSpeechKey: '600',
      VoiceOfflinePrefs.bargeInPlaybackKey: 'on',
      VoiceOfflinePrefs.micRouteKey: 'bluetooth',
    };
    SharedPreferences.setMockInitialValues(before);
    final prefs = await SharedPreferences.getInstance();
    final read = VoiceOfflinePrefs.read(prefs);
    await VoiceOfflinePrefs.migrateLegacyVadRoute(prefs);
    for (final entry in before.entries) {
      if (entry.key == 'voice.input') continue;
      expect(prefs.get(entry.key), entry.value, reason: entry.key);
    }
    expect(prefs.getKeys(), {...before.keys, VoiceOfflinePrefs.localEngineKey});
    final after = VoiceOfflinePrefs.read(prefs);
    expect(after.vad.pause, read.vad.pause);
    expect(after.vad.maxDuration, read.vad.maxDuration);
    expect(after.micRoute, read.micRoute);
    expect(after.conversation, read.conversation);
    expect(after.localEngine, VoiceLocalEngine.parakeet);
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
and `VoiceOfflinePrefs roundSettings() => _roundSettings();`. Q5=A (decided): give `onEvent`, `forceEnd` and
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
- Modify: `CHANGELOG.fork.md`, `docs/VOICE.md`, `README.md`

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
(upstream format change, one-time step before install). Inline chat images now use upstream's image box
(tap opens the preview). Every Birk answer from the ledger question (Task 18) that changes the app gets a line.
**Dropped for upstream:** own queue drain loop and history-text queue-head check (upstream outbox), composer
toolbar mic (upstream mic in the text field).
```

- [ ] **Step 2: docs/VOICE.md** — add a short "Wing Voice (fork)" note under upstream's dictation section:
conversation mode sends dictations automatically (opt-in), the system-recognizer fallback stays inside Local
(never switches to Hermes), maximum dictation duration is 10 minutes.

- [ ] **Step 3: README.md** — Q4=A: in the "Wing Voice (fork)" block remove the "Inline, tap-to-zoom chat images" bullet (the feature is now upstream's `ChatInlineImage`) and add to `CHANGELOG.fork.md`'s inline-image entry a line "Superseded by upstream ChatInlineImage in the upstream merge (t_d1d49ff1)."

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
apply Q11=A (decided): edit `tools/architecture/native_voice/VoicePermissionLifecycleGuard.kt` so it additionally accepts the `keepsVoice = { … }` constructor argument of `VoicePlayback` and the statement `voiceChannel?.pauseOffline()` in `onPause`, extend its proof fixtures (`tools/architecture/native_voice/prove_boundary.py` inputs) with one accepted case for exactly this shape, add a `# Fork (Wing Voice)` comment at each edit, add the files to the CHANGELOG.fork.md entry, commit, re-run.
If the emulator/KVM jobs fail for infrastructure reasons only (no `/dev/kvm`), report it with the run URL and
end with `FRAGE: CI-Emulatorjobs laufen im Fork nicht (kein KVM, Run <URL>) — wie weiter?` (Q10=A accepted the
cost, not a missing runner). Repeat Step 1 until green; R1-R8 (`test/regression`) must be among the passed tests.

- [ ] **Step 3: Native**

Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: last line `dispatch-check: voice-apk.yml run <id> conclusion=success …`. On "NDK 28.2.13676358 not
installed" or "platform android-36 missing": copy upstream's "Install pinned Android SDK" step from
`pr-quality.yml` into `voice-apk.yml`, commit, re-run.

---

### Task 15: Refresh from `voice-offline`, regression invariance, final measurement

- [ ] **Step 1:** Run: `git fetch origin`; Run: `git log --oneline wt/t_d1d49ff1..origin/voice-offline`.
If empty, skip to Step 3.
- [ ] **Step 2:** Run: `git merge --no-ff origin/voice-offline` (MERGE, no rebase); resolve; re-run the census
(`python3 -I .cc-context/census_fill.py`, `python3 tools/architecture/rules/authored_census.py`); commit; repeat Task 14 Step 1.
- [ ] **Step 3:** Run: `git merge-tree --write-tree --name-only HEAD upstream/main`
Expected: exit 0 if upstream has not moved (nothing left to merge), else the list of new conflicts — report it, do not merge again in this card.

- [ ] **Step 4: Regression invariance (spec §14)** — the R1-R8 expectations are unchanged since
`<pre-merge-regression-commit>` (Task 1a). Write `.cc-context/regression_invariance.py`:

```python
"""Fail if any expectation line in test/regression changed since the pre-merge commit."""
import subprocess
import sys

base = sys.argv[1]
diff = subprocess.run(
    ["git", "diff", "-U0", base, "HEAD", "--", "test/regression"],
    capture_output=True, text=True, check=True,
).stdout
bad = [
    line for line in diff.splitlines()
    if line[:1] in "+-" and not line.startswith(("+++", "---"))
    and any(token in line for token in ("expect(", "reason:", "findsOneWidget", "findsNothing", "isTrue", "isFalse"))
]
files = subprocess.run(
    ["git", "ls-files", "test/regression"], capture_output=True, text=True, check=True,
).stdout.split()
print(len(files), "regression files")
print("\n".join(bad) if bad else "expectations unchanged")
sys.exit(1 if bad or len(files) != 8 else 0)
```
Run: `python3 -I .cc-context/regression_invariance.py <pre-merge-regression-commit>`
Expected: `8 regression files`, `expectations unchanged`, exit 0.
Run: `git diff <pre-merge-regression-commit> HEAD -- test/regression`
Expected: only lines between `// SETUP` markers, imports and constructor/getter renames from spec Table C. The
reviewer card (t_6a4e1890) re-checks this diff. A changed expectation is a regression, not an adaptation: revert
it and fix the app instead.

- [ ] **Step 5:** Confirm the last [SUITE] run of Task 14 (or Step 2 above) was on the current HEAD and green
(includes R1-R8 and the R4 static guard). Note its run URL for Task 17.

---

### Task 16: Signed APK (build and sign only; no install)

Q8=A is handled by the installer/device card (last section), not here. This card never contacts the phone and
never asks Birk about drafts.

- [ ] **Step 1: Build the unsigned release APK on CI**

Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=true`
Expected: `conclusion=success`; branch `voice-apk-bin` gets `wing-voice-unsigned.apk`, `SHA256SUMS`,
`SOURCE_COMMIT` = this HEAD.

- [ ] **Step 2: Sign** (script lives in the entity repo, not in Wing; verified 2026-11-12)

Run: `/home/birk/hermes-shared/hermes-entities/tools/technik/wing-voice-build.sh`
Expected: a zipaligned APK signed with `~/.android/wing-voice.keystore` (alias `voice`), its path printed;
`SOURCE_COMMIT` equals `git rev-parse HEAD`. Do not pass `--install`.

- [ ] **Step 3: Checksum** — Run: `sha256sum <signed-apk-path>`; note the hash.

- [ ] **Step 4: Identity check** — if `aapt2` is available under `~/.local/share/android-tools/`:
`aapt2 dump badging <apk>`; expected `package: name='com.tarkilhk.wing.voice'`, `versionCode` > 2356,
`application-label:'Wing Voice'`, `sdkVersion:'29'`. Run: `unzip -l <apk> assets/silero_vad.onnx` → one entry.
If no `aapt2`, the installer card checks identity on the phone (`dumpsys package com.tarkilhk.wing.voice`).

---

### Task 17: Card comments — handoff and "taken from upstream / dropped"

- [ ] **Step 1: Handoff block** on card t_d1d49ff1 (read by the installer/device card):

```
HANDOFF t_d1d49ff1
APK: <signed-apk-path>
SHA256: <sha256>
SOURCE_COMMIT: <HEAD hash>
CI suite (HEAD): <run URL>  conclusion=success
Native build: <dispatch-check run URL>
Regression baseline (pre-merge): <Task 1b run URL> at <pre-merge-regression-commit>
```

- [ ] **Step 2: "Taken from upstream / dropped on our side" list**, one line per spec ID with decision
`drop our variant, upstream already solves it` or `keep upstream behaviour` where our side had code (CTL-B3,
CTL-B4, CTL-B5, CTL-B7 cap, CTL-B8, SCR-B7 parts, SCR-B13, SCR-B19, SCR-B21, SCR-B22, VCA-B4 message, VIC-B4,
VPC-B2, VPC-B3, MMC-B2..B6, PMS-B1, PMS-B2, DLA-B1..B4 (Q4=A, `InlineMediaThumbnail` removed), PRQ-B1, GWY-B3
`close_on_disconnect`), and per file the re-hung fork functions.

---

### Task 18: Differences ledger — ONE question to Birk before the [Merge] card

Governing rule: every user-visible difference not covered by R1-R8 and not already decided goes to Birk as one
question before the merge into `voice-offline`.

- [ ] **Step 1: Re-check the ledger (spec §15) against the built branch.** For each row L1-L18 confirm it is
still true at HEAD (e.g. L7: `git grep -n "VoiceInputButton" -- lib/core/screens/profile_workspace_screen.dart`;
L10: `git grep -n "StudioDialog" -- lib/core/widgets/vad_settings_section.dart`; L16:
`git grep -n "minSdk" -- android/app/build.gradle.kts`). Append any further user-visible difference found
while implementing Tasks 2-14 (anything a user could see or hear that the R-tests do not pin), with old vs new.

- [ ] **Step 2: Post ONE comment on card t_d1d49ff1** (German, one block) listing every still-undecided row
(Stand spec 2026-11-12: L7, L8, L10, L11, L12, L13, L14, L15, L16, L17, plus any new row) — per row: what
changes (vorher → nachher) and the recommendation; already decided rows are listed in one line
("bereits entschieden: Q1-Q11"). Template:

```
Wing-Upstream-Merge: sichtbare Unterschiede, die noch nicht entschieden sind (alles andere bleibt gleich;
R1-R8 sind vor und nach dem Merge grün):
L7 Mikrofon-Knopf: bisher eigenes Symbol in der Leiste unter dem Text → jetzt im Textfeld. Empfehlung: übernehmen.
L8 Aufnahmezeile: Text-Knöpfe Stop/Abbrechen → Symbol-Knöpfe (Zähler bleibt "/ 600s"). Empfehlung: übernehmen.
…
L17 Server: Upstream 1.4.0 braucht das aktuelle Hermes-Gateway-Webapp. Empfehlung: Gerätekarte prüft die
    Verbindung direkt nach der Installation; bei Problem Stopp, kein Server-Update ohne dich.
Bereits entschieden: Q1-Q11 (12.11.).
Antwort: "alle ok" oder je Zeile L<n> ok/nein.
```

- [ ] **Step 3: End the run** with the line
`FRAGE: Wing-Upstream-Merge — sind die sichtbaren Unterschiede L<…> (Kommentar oben) so ok? ("alle ok" oder je Zeile)`
so the [Merge] card cannot start before Birk answered. If Step 1 finds no undecided row, write "Ledger: keine
offenen Unterschiede" on the card instead and end without `FRAGE:`.

---

## Installer/device card (specified here; the architect creates the card)

Chain: coder t_d1d49ff1 → review t_6a4e1890 → **device card (new)** → merge t_f8523002. Parents
[t_6a4e1890], child t_f8523002. Skill: `android-phone-remote-ops` (`~/.hermes/profiles/birk/skills/devops/android-phone-remote-ops/`,
references `apk-transfer-and-install.md`, `voice-self-test.md`, `hadb-pegelmessung-und-dateien.md`), method as in
the earlier device acceptances (e.g. card t_dc830669): logcat lines, uiautomator dumps, synthetic WAVs with
leading silence (padding per `voice-self-test.md`, trimmed so speech starts within 1.5 s). A failed item blocks
the card; the [Merge] card must not start. Items marked **live with Birk** go one step per message.

**Step 1 — APK.** Read the HANDOFF block of t_d1d49ff1. Clone/locate the signed APK, `sha256sum` it, compare with
`SHA256:`; check `SOURCE_COMMIT` equals the reviewed HEAD of `wt/t_d1d49ff1`. Mismatch → block.

**Step 2 — Birk's one-time step (Q8=A).** Send exactly:
`python3 ~/.hermes/profiles/birk/scripts/robo-push.py --kind decision "Wing-Update bereit" "Bitte vorher offene Entwürfe abschicken, dann 'ok'."`
then `kanban_block needs_input` until Birk answers "ok". No install before that.

**Step 3 — Record device settings** (restore them in Step 7): `settings get system screen_off_timeout`,
`settings get global stay_on_while_plugged_in`, `settings get global airplane_mode_on`,
`cmd media_session volume --stream 3 --get`, Wing Voice's installed `versionCode`
(`dumpsys package com.tarkilhk.wing.voice | grep versionCode`).

**Step 4 — Install** per `apk-transfer-and-install.md` (Tailnet `http.server` + phone-side `curl`, sha256 on the
phone, `pm install -r`). Then: launch Wing Voice; uiautomator dump of Settings → Voice input shows **Local** and
"Recognition engine: **Parakeet on this phone**" (Q1 migration; Birk's VAD pause/max/mic settings unchanged —
compare the dump's values with a dump taken in Step 3 before the install, same screen). Open a chat: the
connection status in the dump is "Connected" (ledger L17; if not, block and report — no server change).

**Step 5 — Regression items R1-R8 on the phone.**

| item | device procedure | evidence (pass criterion) |
|---|---|---|
| R1 conversation loop | Conversation mode on (Birk's setting), new chat, tap mic, play a synthetic question WAV ("Wie spät ist es in Tokio? Antworte in einem Satz.") | `dumpsys audio` `rec start`→`rec stop` ends by itself (VAD) a few s after the speech; `WingTtsLang` `segment …/… status=0` lines for the reply; a new `rec start` within 5 s after the last segment; dump shows the recording row again |
| R2 unsolicited reply | In the same chat ask (synthetic WAV) "Schick mir in 60 Sekunden unaufgefordert eine zweite kurze Nachricht"; when the reply was spoken and the next round records, wait for the unsolicited message. ANNAHME: Hermes can schedule a delayed message in the same session (method of the t_0179b15f acceptance); if not → **live with Birk**: Birk triggers a message from another client into this chat while Wing records | the recording is not cut at the message's arrival (`rec stop` only after the VAD end, not at the arrival time); the unsolicited reply is spoken afterwards (`WingTtsLang` lines after `rec stop`); the loop continues (next `rec start`) |
| R3 MEDIA + images | Ask (typed via `input text` or WAV) for a reply that contains one image as a `MEDIA:` line (e.g. "Zeig mir das Wing-Icon als MEDIA-Bild") | `WingTtsLang` `chars=` sum ≈ length of the prose only (no path read); dump shows an image node inside the message; `input tap` on it → dump shows the image preview (full-screen preview node); Back closes it |
| R4 10-min dictation | Parakeet route: play a 150 s synthetic speech WAV (continuous sentences, gaps < Birk's pause setting, last sentence "Ende des Langtests einhundertfünfzig") into a dictation without conversation send (or with, either is fine); repeat once with "Recognition engine: Android system recognizer" (restore Parakeet afterwards) | dump during recording shows `/ 600s`; `rec start`→`rec stop` ≥ 150 s on both routes (proves the 120 s cap is gone); the transcript in the text field ends with "einhundertfünfzig" |
| R5 queue resume | Conversation mode: start a dictation, `cmd connectivity airplane-mode enable` while recording, let the VAD end (prompt is queued offline), wait 10 s, `cmd connectivity airplane-mode disable` | after reconnect the queued prompt is sent without any tap (dump: queue empty, no "Resume" button), the reply is spoken (`WingTtsLang`), the mic reopens (`rec start`) |
| R6 offline indicator | `cmd connectivity airplane-mode enable`, dump after 2 s; disable | dump shows "Disconnected" within 2 s (not "Reconnecting"); after disable "Connected" returns |
| R7 screen-off read-aloud | Conversation mode: ask a question needing a ~4-sentence reply via WAV; right after `rec stop` send `input keyevent KEYCODE_SLEEP` | `dumpsys power` `mWakefulness=Asleep`/`Dozing`; `WingBgVoice` `hold on` and `pause kept`; `WingTtsLang` `segment` lines with `status=0` timestamped after the sleep; next `rec start` while the screen is off. Audibility: **live with Birk** ("Hast du die Antwort bei ausgeschaltetem Bildschirm gehört?") |
| R8 barge-in hint | **live with Birk**, headset connected (barge-in is headphones-only): Birk asks a question that needs a long answer, then speaks during read-aloud ("Stopp, kürzer bitte") | read-aloud stops (`WingTtsLang` segment `status` ≠ 0 or no further segments); the next user message in the chat (dump or Hermes session history) ends with `[Hinweis von Wing: Die vorige Antwort wurde beim Vorlesen abgebrochen und nicht zu Ende gehört.]` |

**Step 6 — Result.** Post on the device card and on t_d1d49ff1 a table `item | pass/fail | evidence line`
(one quoted logcat/dump/dumpsys line per item, plus the measured R4 durations). Any fail → `kanban_block` with
the item and evidence; the [Merge] card does not start.

**Step 7 — Restore** the settings recorded in Step 3 (airplane off, screen-off timeout, stay-on, volume,
Parakeet engine), delete test files from `/data/local/tmp`, uninstall any temporary player app.

---

## Self-review notes (architect, 2026-11-12, updated after Birk's decisions)

- Spec coverage: §14 R1-R8 → Tasks 1a, 1b (pre-merge), 15 Step 4 (invariance), device card Step 5; §15 ledger
  → Task 18; Table B rows → Tasks 2-7 (every ID named); VPF → Task 4/9; §6 S1-S3, S6 → Task 3, S4/S5 → Task 11,
  S7/S8 → Task 12, S9 → Task 5, S10 → Task 6; Table C → Tasks 9-11; §8 → Tasks 3, 5, 10; §9 → Tasks 6, 9, 10,
  11; §10 items 1-8 → Tasks 9, 7, 3, 10, 3, 12, 6, 11; §11 → Task 12; §12/Q8 → device card Step 2; Q1-Q11 →
  Global Constraints + named tasks; signed APK → Task 16; card comments → Task 17.
- The merge commit (Task 8) does not compile by design; the first post-merge [SUITE] is Task 14 after all
  repair commits. The pre-merge [SUITE] (Task 1b) proves R1-R8 describe today's behaviour.

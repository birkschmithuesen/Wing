# Wing upstream merge (gateway/chat rewrite): conflict assignment

Card t_dcfc9770 (architect plan). Executing card: t_d1d49ff1 (merge, CI green, signed APK).
Plan: `docs/superpowers/plans/2026-11-12-wing-upstream-merge.md`.

All facts below are **Stand 2026-11-12**, measured against the commits named in §1. They are not
permanent truths: if `upstream/main` has moved when t_d1d49ff1 starts, §1 must be re-measured first (plan
Task 1). Statements that could not be verified by reading git objects are marked `ANNAHME:` with the check
that settles them. No Flutter/Dart SDK exists on the vServer; nothing here was compiled or run.

## 0. Decision rules used in this spec

**Governing rule (Birk, 2026-11-12): "As a Wing user he must notice NOTHING from the merge except
improvements."** Every decision, task and test below serves this rule. Concretely: (a) Birk's current daily
flow is pinned by an automated regression suite R1-R8 (§14) that is green before the merge and must be green
again after it with unchanged expectations, and is re-run on the phone; (b) every other user-visible difference
is listed in the ledger (§15) and goes to Birk as one question before the merge into `voice-offline`;
(c) the 10-minute dictation limit is a hard requirement with its own tests (§6 S1/S9, R4).

0. Birk decided Q1-Q11 on 2026-11-12 (§13); those answers replace the defaults below.
1. MERGE, no rebase (`git merge upstream/main` into a branch from `voice-offline`).
2. Per conflict: keep upstream behaviour and re-hang our function as a thin hook. Where upstream already
   solves the same thing, drop our variant and say so in the merge commit text.
3. Dropping one of our functions with a **user-visible behaviour change** is Birk's decision: such blocks
   were marked `OPEN Q<n>` and listed in §13; Birk answered all of them on 2026-11-12 (§13, DECIDED).
4. Things that were already in the merge base and that upstream itself changed (for example the base
   recognizer message "No speech detected. Try again." in `VoiceCapture.kt`/`voice_input_controller.dart`,
   the base reconnect attempt cap `_maxRecoveryRetries`, the base `minSdk = 24`, the base inline recording
   rows) are upstream behaviour, not fork functions, so they were not OPEN questions. Under the governing
   rule every such change that a user can see is still listed in the ledger (§15) and goes to Birk as one
   question before the merge into `voice-offline`.
5. Stock Hermes only (AGENTS.md): no backend patch, plugin or custom endpoint is introduced by this merge.

Block IDs used everywhere (spec, plan, commit text): `<FILE-ID>-B<n>`, n = block number in file order in the
conflicted file at the measured commit.

| File ID | file | blocks |
|---|---|---|
| PRQ | `.github/workflows/pr-quality.yml` | 2 |
| AGT | `AGENTS.md` | 1 |
| GRD | `android/app/build.gradle.kts` | 1 |
| VCA | `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceCapture.kt` | 6 |
| VCH | `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt` | 4 |
| VPB | `android/app/src/main/kotlin/com/tarkilhk/wing/VoicePlayback.kt` | 2 |
| VIC | `lib/core/controllers/voice_input_controller.dart` | 8 |
| VOC | `lib/core/controllers/voice_output_controller.dart` | 2 |
| SCR | `lib/core/screens/profile_workspace_screen.dart` | 22 |
| GWY | `lib/core/services/profile_gateway.dart` | 4 |
| CTL | `lib/core/services/profile_workspace_controller.dart` | 9 |
| REG | `lib/core/services/profile_workspace_registry.dart` | 1 |
| VPF | `lib/core/services/voice_preferences.dart` (modify/delete) | 0 markers, 1 row |
| DLA | `lib/core/widgets/deliverable_attachment.dart` | 4 |
| MMC | `lib/core/widgets/markdown_message_content.dart` | 6 |
| PMS | `lib/core/widgets/profile_message.dart` | 2 |
| VPC | `lib/core/widgets/voice_preferences_card.dart` | 4 |
| TCA | `test/profile_composer_actions_test.dart` | 1 |
| TBF | `test/support/profile_browser_fixture.dart` | 1 |
| TVF | `test/support/voice_fixture.dart` | 1 |
| TVP | `test/voice_preferences_test.dart` | 3 |
| TVX | `test/voice_processing_test.dart` | 10 |

## 1. Measurement (Stand 2026-11-12)

| item | value | command |
|---|---|---|
| upstream head | `e8a4089cc2150af418a74570f4064bb24a1f432b` (2026-11-12 20:03 +0800, "Avoid redundant background history saves and ownership scans"), pubspec 1.4.1+2518 | `git fetch upstream` then `git log -1 --format="%H %ci %s" upstream/main` |
| ours | `origin/voice-offline` = `b317839870175451926c469fd94d4b4f975147e3`, pubspec 1.1.3+2356 | `git rev-parse origin/voice-offline` |
| merge base | `151ee281c6009024449c836b18ed8910c4ce3e10` | `git merge-base origin/voice-offline upstream/main` |
| commits ahead | upstream 806, ours 323 | `git rev-list --count 151ee281..upstream/main`, `... ..origin/voice-offline` |
| probe merge tree | `8657cda7a3959abdda3006d4932759f2856816e6` (exit 1 = conflicts) | `git merge-tree --write-tree --name-only origin/voice-offline upstream/main` |
| result vs ours | 1814 files: 1109 A, 597 M, 105 D, 3 R | `git diff --name-status -M origin/voice-offline 8657cda7…` counted per letter |
| conflict files | 22 (21 content, 1 modify/delete) | list printed by the merge-tree command |
| conflict blocks | 94 (per-file counts in the File-ID table above) | `<<<<<<<` … `>>>>>>>` pairs counted in `git show 8657cda7…:<path>` |

`git merge-tree` (ort) produces the same conflicts and marker positions as `git merge`; no worktree was
needed for the probe. The conflicted blob of any file is `git show 8657cda7…:<path>`; the line ranges in
Table B are lines of that blob, marker to marker. The 3 renames are upstream's own
(`docs/design/images/wing-readme-hero-tagline.png` → `docs/images/…`, `lib/core/utils/message_content.dart`
→ `integration_test/support/message_content.dart`, `assets/.gitkeep` → `website/.nojekyll`).

`git diff --name-status 151ee281 upstream/main` lists 106 deletions: the 105 of Table A plus
`lib/core/services/voice_preferences.dart`, which our fork modified (+27/−6) and which therefore appears as
the modify/delete conflict VPF, not as a clean deletion.

## 2. Premise correction (card text vs measurement)

The card says the 105 deleted files are "still active and imported on our side". Measured:

- Our fork has **zero net changes** in all 105 paths:
  `git diff --numstat 151ee281 origin/voice-offline -- <path>` is empty for every path in Table A
  (scripted over all 105; the only fork commits that ever touched one, `docs/TESTING.md`, net to zero after
  the compat refactor moved the fork notes into `docs/VAD_INPUT.md`).
- **No fork-owned file** (`lib/voice_offline`, `lib/car_mode`, `lib/fork`, `test/voice_offline`,
  `test/car_mode`, `test/fork`, `voiceoffline/*.kt`, `voicebackground/*.kt`) imports any of the 105 paths or
  uses a class they declared: `git grep -n -w -E "Session|ProfileColorStore|ProfileSelectionStore|TextSizePreference|TextSizePreferenceStore|DashboardOAuthSession|CloudAccessException|GatewayTurnCoordinator|GatewayTurnJournal|CapabilityRegistry|QuickChatStore|ChatSpaceStore|DesktopGatewayClient" origin/voice-offline -- lib/voice_offline lib/car_mode lib/fork test/voice_offline test/car_mode test/fork …`
  hits only the word "Session" in comments. The basename grep hit on `session.dart` is a false positive
  (`car_mode_session.dart`, `car_mic_session.dart`).
- The imports the card saw are imports **by other upstream files**, which upstream deleted or rewrote in
  the same commits. In the merged tree the only import of a deleted path left is
  `dashboard_oauth_session.dart`, which upstream moved to `lib/core/services/` (relative imports resolve).

So all 105 rows of Table A are "take upstream deletion". The real merge risk is elsewhere:
(a) fork code that calls upstream APIs upstream removed or renamed (Table C, §7), (b) **silent merge
losses** in auto-merged lines without conflict markers (§6), (c) upstream's new CI architecture gates that
our files do not yet satisfy (§11), (d) the preference schema that rejects our stored `voice.input=vad`
(Q1).

## 3. What upstream changed (the facts the decisions rely on)

- **Chat model split** (27b5a346, b491c30e, 69cddd72, 669f3bfc): `ProfileChat` lost `status`
  (`ProfileTurnStatus` has 0 hits on upstream), `busy`, `draft`, `opening`, `offlineSnapshot`,
  `commandRunning`, `changingAnswer`, `editingQueuedPrompt`, `queuedPrompts`, `queuePaused`,
  `draftSubmissionUncertain`, `approval`, `clarification`, `sensitivePrompt`, `mainActivity`, `tool`,
  `messages`, `runtimeId`. Replacements: `chat.runtime.*` (`ChatRuntimeObservation`, enums `ChatExecution
  {idle,submitting,running,completed,cancelled,failed}`, `ChatRecovery {ready,opening,offline,reconnecting}`,
  `ChatMainActivity`, `lib/core/models/chat_runtime.dart`), `chat.composer` (`ComposerSession`,
  `lib/core/services/composer_session.dart`) with `chat.composer.observation.{text,queue,paused,
  submissionUncertain,editing}`, and `chat.reading.messages`.
- **Outbox**: Send while offline persists to a per-conversation outbox (`composer_work_v3.*`) and drains on
  reconnect when `ComposerRuntimeObservation.automaticDrainAvailable` is true. Lost acknowledgements are
  replayed idempotently with the same `submission_id`; the rest of the queue then stays paused until the
  user resumes (`docs/DRAFTS_OUTBOX.md`).
- **Controller API kept**: `Future<bool> steer(ProfileChat chat, String rawText)` (controller:8424, no
  `preserveComposer`), `Future<void> queuePrompt(ProfileChat chat, String rawText)` (controller:8539),
  `updateDraft`, `recovering`, `switching`, `preferences`, `connectionStatus`, `resumeConnection`.
  Constructor now needs `access: ConnectionAccess(...)` and `appPreferences: AppPreferences(...)`.
- **Voice**: `voice_preferences.dart` deleted (b491c30e). Typed settings `VoiceInputSettings`
  (`LocalVoiceInputSettings(language)` | `HermesVoiceInputSettings`, sealed) and `VoiceOutputSettings` in
  `lib/core/models/voice_processing_settings.dart`; strict schema `AppPreferencesSchema` in
  `lib/core/models/app_preferences.dart` (`voice.input` accepts only `local|hermes`, line 287-288); owner
  `AppPreferences` (`lib/core/services/app_preferences.dart`); settings UI via `VoicePreferencesSession`.
  `VoiceInputController.dictate<T>(...)` (line 77) and `start(settings, VoiceDraft, onResult,
  {createRemote})` (line 128); empty recognition is a notice (`VoiceInputEmptyResult.noSpeech`), not an error.
  Native side rewritten around `VoiceOperation`, `VoiceFileWork`, async `stop`, `Reply`,
  `VoicePermissionRequests`.
- **Live voice (new)**: cloud duplex call (OpenAI GPT-Live over WebRTC) brokered by the **Wing Hermes plugin**
  (`plugins/wing/voice/v2`). Not stock Hermes, not offline. See §8.
- **CI/architecture**: `pr-quality.yml` runs on `push: ['**']` with Flutter 3.47.9 (`pubspec.yaml` requires
  `>=3.47.9`), runs `tools/architecture/check_all.dart` (library cycles, role inventory `roles.json`, dialog
  and form rules, …), `authored_census.py` (`roots.json` must list every tracked file), native voice guards
  (`VoicePermissionLifecycleGuard`, `VoiceFileApiGuard`), and an emulator journey job. See §11.

## 4. Table A — the 105 deleted paths

Every row: **take upstream deletion**. Full table with one row per path: Appendix A. Groups:

| group | paths (count) | deleting commit | replacement |
|---|---|---|---|
| engineering docs moved private | `CONTEXT.md`, `.github/actions/setup-flutter/README.md`, 13 `docs/*.md`, `docs/design/**` (9), `tools/fake_gateway/README.md` (25) | 6ae1b6ad | none public; design guidance now private `internal/AGENTS.md#ui-design`, public stand-ins `docs/features/ui-foundations.md`, `docs/FEATURE_MAP.md`. Our `AGENTS.md` links are fixed by AGT-B1. |
| retired Android resources | 7 `android/app/src/main/res/**` | b491c30e, 0409d51b | `@mipmap/ic_launcher`; notification layouts replaced in Kotlin. `native_retired_resources.py` requires absence; no fork file references them. |
| gateway-turn / projects / search / home family | 31 `lib/core/**` | 27b5a346, b491c30e, 050ef331 | chat runtime + composer outbox; `dashboard_oauth_session.dart` moved to `lib/core/services/`; `TextSizePreference` → `AppTextSizePreference`; profile colours → `AppPreferences` |
| tests and test support of deleted subjects | 38 `test/**` | 27b5a346, b491c30e, 050ef331, e2919af4 | deleted with their subject |
| misc | `assets/pricing/openai.json`, `scripts/test_native_monitoring_count.py`, `tools/fake_gateway/turn_recovery_contract.py` | 28659bc5, e2919af4, b491c30e | backend catalog pricing; none |

Verification after the merge: every Table A path is absent
(`git ls-files -- <paths>` empty, plan Task 9) and nothing references a deleted Dart path
(`git grep -n -E "models/(session|gateway_turn_contract|hermes_project)\.dart|gateway_turn_|text_size_preference|profile_color_store|profile_selection_store" -- lib test` empty).

## 5. Table B — the 94 conflict blocks (+ VPF)

Line ranges are in the conflicted blob `git show 8657cda7…:<path>` at upstream e8a4089c. "Recipe" is what the
implementer writes; "take upstream" means the `>>>>>>> upstream/main` side.

### 5.1 CI, repo docs, build

| ID | lines | ours does | upstream does | decision | reason + recipe |
|---|---|---|---|---|---|
| PRQ-B1 | L153-157 | `flutter test --no-pub --reporter=expanded test/ \| tee test_output.txt` (leftover of our edit of the old test step) | step "Compile debug Android APK" (`flutter build apk --debug … \| tee android_build_output.txt`); tests run in separate step `python3 scripts/test.py --changed-since "$TEST_BASE_REF" --skip-linters` | keep upstream behaviour | Take upstream. `tools/architecture/rules/required_quality_gates.dart` requires the gate steps verbatim (single-line `run`, no `continue-on-error`); do not touch them. |
| PRQ-B2 | L252-286 | `::error::` annotations of analyze/test failures (Actions logs are not fetchable from the egress-blocked vServer; annotations are) | failure summary: outcome echo + `for check in android_build native_test` cat into step summary | re-hang our function | Take upstream block, then append the annotation snippet in Appendix B inside the same `run: \|` of step "Failure summary". Only `analyze_output.txt`, `android_build_output.txt`, `native_test_output.txt` exist; host-test evidence is `/tmp/wing-host-tests-*/tests.jsonl` (ANNAHME: `mkdtemp` lands in `/tmp`; a red run confirms). |
| AGT-B1 | L41-74 | base UI-design planning list (L42-57) + our `# Fork changelog` section (L59-69) | 3-line "Wing targets the latest upstream, unmodified Hermes…" paragraph; UI rules moved to private `internal/AGENTS.md#ui-design` | re-hang our function | Result: upstream file + our `# Fork changelog` section verbatim. Our current "Hermes deployment constraint" (also upstream's own text in reworded form) and "UI design" sections: keep upstream's wording; add after the Fork changelog section a 3-line `# Fork notes` paragraph: (1) Wing Voice targets stock Hermes, the live-call plugin is out of scope for fork work (Q2), (2) public UI references are `docs/features/ui-foundations.md` and `docs/FEATURE_MAP.md` because `docs/DESIGN_SYSTEM.md` and the administration handoff were removed upstream (6ae1b6ad), (3) upstream's `scripts/wing_save.py`/private `internal/` workflow does not apply to the fork factory. Docs-only, no user-visible app change. |
| GRD-B1 | L195-201 | `apply(from = "voice-offline.gradle")` | `apply(from = rootProject.file("ime-cache-fix.gradle.kts"))` | re-hang our function | Keep both, upstream first, ours last (our `onVariants` must run after upstream's to win `applicationId com.tarkilhk.wing.voice`). `voice-offline.gradle` still fits: it does not touch `ndkVersion`, `minSdk`, signing or `buildFeatures` (verified by reading). Our duplicate `testImplementation junit:junit:4.13.2` may stay (harmless). |

### 5.2 Android voice (Kotlin)

| ID | lines | ours does | upstream does | decision | reason + recipe |
|---|---|---|---|---|---|
| VCA-B1 | L15-22 | imports `voiceoffline.{cleanTranscript,createRecognizer,onDeviceRecognition,recognitionAvailable}` + `java.io.File` | no imports here | re-hang our function | Keep the 4 `voiceoffline` imports; drop `java.io.File` (`VoiceFileApiGuard` forbids java.io in this file; upstream uses `VoiceFileWork`). |
| VCA-B2 | L47-51 | `available() = recognitionAvailable(activity)` (on-device OR system RecognitionService = system-recognizer fallback) | `!closed && SDK>=31 && isOnDeviceRecognitionAvailable` | re-hang our function | `fun available() = !closed && recognitionAvailable(activity)`. |
| VCA-B3 | L60-64 | `languages()` probes on-device recognizer only | `closed \|\| SDK<33 \|\| !available()` | re-hang our function | `if (closed \|\| Build.VERSION.SDK_INT < 33 \|\| !onDeviceRecognition(activity)) { callback(null); return }`. |
| VCA-B4 | L104-163 | `createRecognizer(activity)`; old `id` listener; local message "No speech detected. Try again."; old `File.createTempFile` recorder with `setMaxDuration(MAX_RECORDING_MS)` | `createOnDeviceSpeechRecognizer`; `operations.owns(attempt)` listener; `fail(attempt, "No speech detected", "no_speech")`; recorder via `VoiceFileWork` | keep upstream behaviour + re-hang our function | Take upstream side incl. `no_speech` code (the base text was upstream's, see §0.4). Replace `SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)` by `createRecognizer(activity)`. Drop our temp-file branch. The 600 s limit is re-applied outside the block (§6 S1). |
| VCA-B5 | L201-232 | sync `stop(owner, timeoutMs=5000L): ByteArray?`; own 605 s start deadline | async `stop(owner, completed)`; `arm(attempt, 5000, "Recognition did not finish…")` | keep upstream behaviour + re-hang our function | Take upstream. Re-hang "wait time after stop": `fun stop(owner: String, timeoutMs: Long = 5000L, completed: (ByteArray?, Exception?) -> Unit)` and `arm(attempt, timeoutMs, "Recognition did not finish. Please retry.")` in the recognizer branch. Drop our own deadline Runnable (upstream's `started()` arms it; value per §6 S1). |
| VCA-B6 | L253-269 | `transcript(owner…)` with `cleanTranscript(...)`; drops empty non-final partials ("…" filter) | `arm()` helper + `transcript(attempt…)` without cleaning | re-hang our function | Keep upstream `arm()`. `transcript(attempt, result, final)`: `if (!operations.owns(attempt)) return; val text = cleanTranscript(result?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()); if (!final && text.isEmpty()) return;` then upstream's remaining lines (`if (final) clear(); emit(mapOf("id" to attempt.id, "text" to text, "final" to final))`). An empty final still reaches Dart's empty-result handling. |
| VCH-B1 | L21-35 | `private val offline = VoiceOfflineHandler(activity, messenger, ::emit)`; `pending: Pair<MethodCall, Result>?` | `closed`, `replies`, `Permission`, inner `Reply` | re-hang our function | Take upstream (drop `pending`). Insert `private val offline = VoiceOfflineHandler(activity, messenger, ::emit)` after `private val playback = …`. |
| VCH-B2 | L77-80 | old sync `"stop" -> result.success(capture.stop(id, timeoutMs))` | (empty; upstream `"stop"` case sits above) | re-hang our function | Delete the block. Edit upstream's `"stop"` line: `capture.stop(id, call.argument<Number>("timeoutMs")?.toLong() ?: 5000L) { bytes, error -> … }` (Dart sends `timeoutMs`, `android_voice.dart`). |
| VCH-B3 | L109-125 | `start()`: `keepPlayback` (barge-in), `startVad` routing to `offline.startVad`, `offline.cancel(id)` | `if (closed) error`, `playback.stop()`, async `capture.start(…, completed)` | re-hang our function | `if (closed) { result.error("cancelled","Voice channel closed.",null); return }` / `if (call.argument<Boolean>("keepPlayback") != true) playback.stop(force = true)` (see §6 S6) / `val id = call.argument<String>("id")!!` / `if (call.method == "startVad") { capture.cancel(id); offline.startVad(id, call, result); return }` / `offline.cancel(id)` / upstream's async `capture.start(…) { error -> … }`. No `result.success(null)` after `capture.start`. |
| VCH-B4 | L145-175 | `pause()` with `offline.keepsVoice()` early return, `pauseVad`, `pauseMediaKeys`; `resume()`; `close()` closing routes/keys | `pause()` = `if (closed) return; capture.pause(); playback.stop()`, `leaveForeground()`, `close()` with `closed` + `replies` | re-hang our function | Upstream `pause()` body stays **literal** (the native `VoicePermissionLifecycleGuard` in CI allows only `capture.pause()` and `playback.stop()` there). Add `fun pauseOffline() { if (closed) return; if (!offline.keepsVoice()) offline.pauseVad(); offline.pauseMediaKeys() }` and `fun resume() { if (!closed) offline.resume() }` (MainActivity calls it; without it MainActivity does not compile). Keep-voice-in-background for TTS: §6 S6. `close()`: upstream body, plus `offline.closeRoutes()` before the replies cancel, `offline.closeKeys()` before `capture.close()`, `offline.close()` before `channel.setMethodCallHandler(null)`. If the guard still rejects the result: Q11=A (decided) — fork edit of upstream's guard. |
| VPB-B1 | L120-126 | `speak(…, segments: List<Map<String,String>>?, response)` (language segments) | `speak(…, response)` with `val attempt = claim(owner, response)` | re-hang our function | `fun speak(owner: String, text: String, voiceName: String, rate: Float, segments: List<Map<String, String>>?, response: MethodChannel.Result) {` + `val attempt = claim(owner, response)`. |
| VPB-B2 | L139-149 | `LanguageSpeech.enqueue(tts!!, owner, text, segments, voice)`; `finishPlayback(owner, …)` | chunk loop with utterance tags `"${attempt.generation}:…"`; `finishPlayback(attempt, …)` | re-hang our function | `LanguageSpeech.enqueue(tts!!, attempt.generation.toString(), text, segments, voice)` and `finishPlayback(attempt, error.message ?: "Could not generate speech.")`. **Mandatory**: upstream's `UtteranceProgressListener` matches the generation prefix; passing `owner` would leave playback hanging until the 600 s timeout. |

### 5.3 Voice Dart (controllers, preferences, card, tests)

| ID | lines | ours does | upstream does | decision | reason + recipe |
|---|---|---|---|---|---|
| VIC-B1 | L9-15 | imports `voice_preferences.dart`, `vad_input_round.dart`, `voice_offline_prefs.dart` | imports `../models/voice_processing_settings.dart` | re-hang our function | Upstream import + `import '../../voice_offline/vad_input_round.dart';`. Drop the other two. |
| VIC-B2 | L31-53 | public mutable `phase/partial/error/seconds`, `createRemote` field, `vadRound`, `finishedOnItsOwn`, `_stopRequested` | private fields + getters, no `createRemote` field | re-hang our function | Upstream fields + `final VadInputRound? vadRound;`, `bool finishedOnItsOwn = false;` (keep doc comment), `bool _stopRequested = false;`. `maxSeconds`, `vad`, `static const maxRecordingSeconds = 600` are in non-conflicting lines and stay. |
| VIC-B3 | L70-91 | ctor `({device, createRemote, vadRound})` | ctor `({device})`, getters | re-hang our function | `VoiceInputController({required this.device, this.vadRound}) { _events = device.events.listen(_event); }` + upstream getters + `@visibleForTesting set seconds(int v) => _seconds = v;` (transcription_deadline_test). |
| VIC-B4 | L174-186 | `start(VoicePreferences, VoiceOfflinePrefs, TextEditingValue, cb)` | `start(VoiceInputSettings, VoiceDraft, cb, {required createRemote})` | keep upstream behaviour | Take upstream signature; the VAD round reads its offline prefs from `VadInputRound.roundSettings` (§9.1), not from `start`'s arguments. |
| VIC-B5 | L192-205 | resets incl. `finishedOnItsOwn`, `_stopRequested` | resets `_error/_notice/_partial/_seconds`, `_phase` | re-hang our function | Upstream + `finishedOnItsOwn = false; _stopRequested = false;`. |
| VIC-B6 | L209-237 | `if input==vad { maxSeconds = offline.vad.maxDuration.inSeconds; vadRound!.begin(...) } else { maxSeconds = 600; … device.start }` | `if (settings is HermesVoiceInputSettings) _remote = createRemote(); device.start(...)` | re-hang our function | `switch (settings) { case VadVoiceInputSettings(): final offline = vadRound!.roundSettings(); maxSeconds = offline.vad.maxDuration.inSeconds; final current = await vadRound!.begin(id, offline, isCurrent: () => _id == id && !_disposed); if (!current) return; case LocalVoiceInputSettings(:final language): maxSeconds = maxRecordingSeconds; await device.start(id, local: true, language: language); case HermesVoiceInputSettings(): maxSeconds = maxRecordingSeconds; _remote = createRemote(); await device.start(id, local: false, language: ''); }`. |
| VIC-B7 | L248-255 | timer stops at `maxRecordingSeconds` (600) unless vad | timer stops at 120 | re-hang our function | `if (!vad && _seconds >= maxRecordingSeconds) { unawaited(stop()); }` (maximum dictation duration is a fork feature; native side §6 S1). |
| VIC-B8 | L297-309 | `stop()`: vad → `vadRound!.forceEnd`, `_stopRequested = true` | guard `_phase != recording` | re-hang our function | Upstream guard, then `if (vad) { return vadRound!.forceEnd(transcribing: _vadTranscribing, finish: _finish, fail: _fail); }` and `_stopRequested = true;`. Outside the block: `stopHandsFree`/`_vadTranscribing` must assign `_phase` (getter-only `phase`). VAD no-speech per Q5. |
| VOC-B1 | L150-175 | inline `speak` returning `Future<bool>` (true only if played to the end) | `speak(...) => _play(message, (id) async { switch (settings) … })` | re-hang our function | Take upstream shape, keep `Future<bool> speak(` and our doc comment; in the Hermes branch the non-conflicting `return false;` becomes `return;` (closure returns void). |
| VOC-B2 | L181-219 | `device.speak(... voice: settings.voice, rate: settings.rate)`; `finished = _id == id && !_disposed` | `case LocalVoiceOutputSettings(:final voice, :final rate): …rate.multiplier`, `playAudio`, `_play` | re-hang our function | Take upstream; `Future<bool> _play(...)`: `if (_disposed) return false;`, `var finished = false;`, after `await play(id);` `finished = _id == id && !_disposed;`, `return finished;`. `playAudio` stays `Future<void>`. The MEDIA-line filter in `spokenReplyText` is outside the block and stays (`mediaReferencePattern` exists upstream, `lib/core/models/media_reference.dart:13`). |
| VPF (modify/delete) | whole file | +27/−6: `enum VoiceInputRoute {local,hermes,vad}`, accepts `vad`, `keys`/`accepts` include `VoiceOfflinePrefs` keys (fork keys in config backup), `read` maps `vad` | deleted in b491c30e; successors `AppPreferenceField`/`AppPreferencesSchema`/`AppVoiceProcessing` (`lib/core/models/app_preferences.dart`), `VoiceInputSettings`/`VoiceOutputSettings` (`lib/core/models/voice_processing_settings.dart`), `AppPreferences` (`lib/core/services/app_preferences.dart`), `VoicePreferencesSession` | keep upstream behaviour (delete the file) + re-hang our function (Q1=A, Q9=A decided) | `git rm lib/core/services/voice_preferences.dart`. Our prefs re-hang in `lib/voice_offline/voice_offline_prefs.dart` (`VoiceOfflinePrefs`, already owns all `voice.vad_*`, `voice.auto_speak`, `voice.conversation`, `voice.listen_*`, `voice.barge_in_playback`, `voice.mic_route` keys). Add `voice.local_engine` (`system`\|`parakeet`) + one-time migration `voice.input=vad → voice.input=local, voice.local_engine=parakeet` and `VadVoiceInputSettings`; details §9.1 and Q1. Remove `tryReadVoicePreferences`; "repair needed" is `appPreferences.current.voiceInputSettings == null`. |
| VPC-B1 | L1-22 | imports for the SharedPreferences-based card | imports for the session-based card | keep upstream behaviour | Upstream imports + `import '../../voice_offline/voice_offline_settings.dart';`. |
| VPC-B2 | L79-127 | `_load`, `_save`, `_setSaving` | (empty; session owns load/save) | keep upstream behaviour | Delete ours. |
| VPC-B3 | L141-229 | `_saveInput` (prepares/releases Parakeet model on route change), `_engine`, `_languageChoice` | `_select<T>` over `AppPreferenceControl`, `_engines`, `_languageChoice(state)` | keep upstream behaviour | Take upstream. The prepare/release logic moves into the fork engine row (VPC-B4). |
| VPC-B4 | L273-447 | whole `build` incl. `vadInputChoice`, `VoiceOfflineSettings(vadRoute)`, `VoiceOfflineSettings(replies)`, local preview | `build` on `_session.current` | re-hang our function (Q1=A decided) | Take upstream `build`. Insert 2 hooks: after the input description `if (state.input.selected == AppVoiceProcessing.local) VoiceOfflineInputRows(session: _session),` (engine select "Android system recognizer / Parakeet on this phone"; when Parakeet: mic route + `VadSettingsSection`), and after the output description `VoiceOfflineSettings(part: VoiceOfflineSettingsPart.replies, session: _session)`. Both thin widgets live in `lib/voice_offline/voice_offline_settings.dart`, read `SharedPreferences` themselves, take the device from a new one-line getter `VoiceDevice get device => _device;` in `lib/core/services/voice_preferences_session.dart`. Each fork row has its own `_saving`. |
| TVF-B1 | L57-61 | `lastStopTimeout = timeout;` | `if (recording != id) return null;` | re-hang our function | Keep both, ours first. |
| TVP-B1 | L111-135 | `VoicePreferences.read`, `saveDevicePreference` | `AppPreferences` owner API | keep upstream behaviour | Take upstream. |
| TVP-B2 | L417-431 | `show(tester, prefs, …)` + `StudioSelect<String>` | `show(tester, owner, …)` + `selectHermes` | keep upstream behaviour | Take upstream. |
| TVP-B3 | L472-476 | `VoicePreferences.read(prefs).input` | `owner.current.values.voiceInput` | keep upstream behaviour | Take upstream. |
| TVX-B1 | L6-12 | imports `voice_preferences.dart`, `voice_offline_prefs.dart` | imports `app_preferences.dart`, `voice_processing_settings.dart` | keep upstream behaviour | Take upstream. |
| TVX-B2 | L17-23 | loops over `VoiceInputRoute`/`VoiceProcessing` | loops over `AppVoiceProcessing` | keep upstream behaviour | Take upstream. |
| TVX-B3 | L54-83 | duplicate old setup (`VoicePreferences`, `TextEditingValue`) | `expect(device.local, …)` | keep upstream behaviour | Take upstream. |
| TVX-B4 | L102-114 | `VoiceInputRoute.local` comparisons | `AppVoiceProcessing.local` | keep upstream behaviour | Take upstream. |
| TVX-B5 | L153-160 | `VoicePreferences(...), VoiceOfflinePrefs(), TextEditingValue.empty` args of `start` | `LocalVoiceInputSettings(language: '')`/`HermesVoiceInputSettings()`, `VoiceDraft(...)` | keep upstream behaviour | Take upstream. |
| TVX-B6 | L185-192 | same as B5 | same as B5 | keep upstream behaviour | Take upstream. |
| TVX-B7 | L202-209 | same | same | keep upstream behaviour | Take upstream. |
| TVX-B8 | L228-235 | same | same | keep upstream behaviour | Take upstream. |
| TVX-B9 | L305-312 | same | same | keep upstream behaviour | Take upstream. |
| TVX-B10 | L385-392 | same | same | keep upstream behaviour | Take upstream. Our non-conflicting test "recording is bounded at the new maximum duration" (pumps 121 s, expects no stop) stays and is correct with VIC-B7. |

### 5.4 Workspace screen (`profile_workspace_screen.dart`)

Upstream facts used here: one mic `VoiceInputButton` inside the field (`_dictationButton` →
`_requestDictation`), `_voiceInput.dictate(...)` with `controller.captureVoiceDraft`/`applyVoiceDraft`,
read-aloud via `_voiceOutput.readAloud(...)`, recording chrome `VoiceInputActivity`, target tracking
`_syncVoiceTarget()` (no `_voiceOwner`), `_composerActionLabels(chat)` (private), live-call button
"Start voice conversation" beside the field.

| ID | lines | ours does | upstream does | decision | reason + recipe |
|---|---|---|---|---|---|
| SCR-B1 | L156-166 | fields `backgroundVoice`, `headphoneRoute` | 5 new fields (`createBotsSession`, `onOpenBotChat`, `initialBotSession`, `initialBot`, `initialInvestigation`) | re-hang our function | Keep both sets (upstream's 5, then ours 2). |
| SCR-B2 | L186-195 | ctor `this.backgroundVoice, this.headphoneRoute` | ctor for the 5 upstream fields | re-hang our function | Keep both. |
| SCR-B3 | L206-448 | `late final _voice = WorkspaceVoiceDriver(...)` + 12 `WorkspaceVoiceHost` overrides; `final _composer = TextEditingController()` | bots/recents owners, destination helpers, `final _composer = SkillComposerController()` | re-hang our function | Take upstream's 210 lines. Insert our `_voice` field + 12 overrides (ours L207-235, without our `_composer` line) after `ProfileWorkspaceController get controller => widget.controller;`. `TextEditingController get composer => _composer;` still type-checks (`SkillComposerController extends TextEditingController`). |
| SCR-B4 | L520-538 | `_voiceOwner`; `VoiceInputController(device, createRemote: HermesVoice.forConnection(...), vadRound: VadInputRound(...))` | `VoiceInputController(device: ...)` | re-hang our function | Keep `ProfileSessionKey? _voiceOwner;` (auto-speak/read-aloud cancel on chat change needs it). `VoiceInputController(device: widget.voiceDevice ?? AndroidVoice.instance, vadRound: VadInputRound(<our 4 args>, roundSettings: () => _voice.car.roundSettings(VoiceOfflinePrefs.read(controller.preferences))))`; drop `createRemote:` (now per call). |
| SCR-B5 | L544-575 | `_voiceWorkspaceChanged()` ends/cancels the loop on chat change, edit-queue, needs-input, failed/cancelled turn | `_syncVoiceTarget()`, `_cancelVoice()` | re-hang our function | Keep both. Ours with upstream accessors via `ChatVoiceView` (`voiceEditingQueue` = `composer.observation.editing != null`, `needsUserInput` = `runtime.needsInput`, `voiceTurnEnded` = execution in {failed, cancelled}). Upstream `_syncVoiceTarget()` unchanged. `void _cancelVoice() => _voice.cancel();` (all upstream callers then also end the loop and release car mic/barge-in). |
| SCR-B6 | L594-684 | host `dictate(chat, {resume})`: stop output, clear queues, close barge-in, admission, compute offline settings, set conversation/owner, `_voiceInput.start(...)`, callback decides auto-send, then `_voice.sendConversationTurn(chat)`; VAD mic fallback hint | `_requestDictation(chat)` → `_voiceInput.dictate(target, draft, settings, stopPlayback, admitsTarget, admitPresentation, createRemote, applyDraft, onApplied, onNotice)` | re-hang our function | New `@override Future<void> dictate(ProfileChat chat, {bool resume = false})` built on upstream's `dictate` call; alias `Future<void> _requestDictation(ProfileChat chat) => dictate(chat);`. Steps: (a) live-call guard `if (LiveVoiceScope.maybeOf(context)?.session.active == true) { if (resume) _voice.endLoop(); return; }`; (b) our pre-steps verbatim (`_voiceOutput.stop()`, clear `autoSpeakQueue`/`queuedUnsolicitedReplies`, `bargeIn.close('dictate')`, `carSend = false`); (c) our admission incl. `resume && !_voice.canContinueConversation(chat)` → `endLoop`; (d) `offline = _voice.car.roundSettings(VoiceOfflinePrefs.read(controller.preferences))`, `conversation`, `awaitingReply`, `_voiceOwner`; (e) `capture = controller.captureVoiceDraft(chat)`; (f) `_voiceInput.dictate(target: chat.key, draft: …, settings: () => voiceInputSettingsFor(controller.appPreferences, controller.preferences) /* §9.1 */, stopPlayback: _voiceOutput.stop, admitsTarget: …, admitPresentation: …, createRemote: (t) => controller.voiceForChat(chat, t), applyDraft: (text) async { final send = _voice.conversation == chat.key && (_voiceInput.finishedOnItsOwn \|\| _voice.carSend); if (!send) _voice.endLoop(); await controller.applyVoiceDraft(chat, capture, text); if (send) await _voice.sendConversationTurn(chat); }, onApplied: …, onNotice: (m) { _voice.endLoop(); showStudioError(context, m); })`. Compute `send` before the first `await`. (g) mic fallback hint after the call. |
| SCR-B7 | L690-726 | `_readAloud`: end loop, clear queues, toggle, cancel input, set owner, `speak(...)` with `VoicePreferences` | `_requestReadAloud(...) => _voiceOutput.readAloud(...)` (toggle, cancel dictation, admission) | re-hang our function | Take upstream; body becomes `async { _voice.endLoop(); _voice.autoSpeakQueue.clear(); _voice.queuedUnsolicitedReplies.clear(); _voiceOwner = chat.key; await _voiceOutput.readAloud(<upstream args>); }`. Toggle/cancel/admission parts of ours: dropped, upstream already solves them. |
| SCR-B8 | L731-774 | `..._voice.listeningRows()` + inline Recording column (max seconds, Stop/Cancel via `_voice.cancelRecording`) | `VoiceInputActivity(context:, controller: _voiceInput)` | keep upstream behaviour + re-hang our function | `..._voice.listeningRows(),` then upstream's `VoiceInputActivity`. Outside the screen: `lib/core/widgets/voice_input_activity.dart` hard-codes `'/ 120s'` → `'/ ${controller.maxSeconds}s'`; Cancel must end the conversation loop (driver `_voiceInputChanged` ends the loop on active→idle without a result, and on `notice != null`). The recording chrome look (icon buttons) is upstream's own redesign of base UI, not a fork function. |
| SCR-B9 | L785-795 | "Stop speech" `TextButton(onPressed: _voice.stopSpeech)` | `StudioButtonPress(child: TextButton(onPressed: _voiceOutput.stop, …))` | re-hang our function | Upstream shape with `onPressed: _voice.stopSpeech`. |
| SCR-B10 | L1173-1181 | initState: `addListener(_voiceWorkspaceChanged); _voice.attach(); _voice.attachRoute(); _voice.syncVadRoute();` | `addListener(_syncVoiceTarget); addListener(_supervisionWorkspaceChanged);` | re-hang our function | Both: ours 4 lines, then upstream's 2. |
| SCR-B11 | L1268-1284 | lifecycle: `_voice.lifecycle(state)`, `_appIsActive = …`, `syncVadRoute`/`syncMediaKeys` | `active` computation, recents/bots/supervision visibility, `setState(() => _appIsActive = active)` | re-hang our function | Upstream; `_voice.lifecycle(state);` before `final active = …`; after the `_appIsActive` update `if (active) { _voice.syncVadRoute(); } else { _voice.syncMediaKeys(); }`. |
| SCR-B12 | L1318-1343 | dispose: `disposeCar`, remove listener, `_voice.detach()`, `setRouteVisibility(false)`, `releaseDevice` | dispose of new owners, remove listeners, `_voiceInput.dispose(); _voiceOutput.dispose();`, `setRouteVisibility(false); setRouteMounted(false)` | re-hang our function | Upstream + first line `_voice.disposeCar();`, `controller.removeListener(_voiceWorkspaceChanged);` after `removeListener(_syncVoiceTarget)`, replace `_voiceInput.dispose(); _voiceOutput.dispose();` by `_voice.detach();` (disposes both), `_voice.releaseDevice();` after `setRouteMounted(this, false)`. |
| SCR-B13 | L1422-1427 | before profile switch: `_voice.cancel(); unfocus; cancelNotificationOpen()` | moved into the `_profileNavigation.switchTo` closure (`_cancelVoice(); …`) | keep upstream behaviour | Delete ours; upstream's closure calls `_cancelVoice()` which delegates to `_voice.cancel()` (SCR-B5). |
| SCR-B14 | L1518-1522 | `Listenable.merge([controller, _voiceInput, _voiceOutput, _voice.bargeIn])` | adds `?_recentVisit` | re-hang our function | `[controller, _voiceInput, _voiceOutput, _voice.bargeIn, ?_recentVisit]`. |
| SCR-B15 | L1939-2023 | AppBar actions: menu IconButton + PopupMenuButton (parent/goal/background/find/**car**/refresh) | `StudioButtonPress(child: PopupMenuButton(...))` (screen/outputs/find/git/parent/refresh); menu button moved | re-hang our function | Take upstream (B15+B16 interleave). Re-add car mode: `onSelected` `} else if (action == 'car') { unawaited(_voice.enterCarMode(context)); }` and item `const StudioPopupMenuItem(value: 'car', child: Text('Car mode')),` after `'git'`. |
| SCR-B16 | L2026-2054 | popup items goal/background/find/car/refresh | popup tail + `screen` item | re-hang our function | See SCR-B15. |
| SCR-B17 | L2455-2492 | old `_answer` head with fork `onLoadRemoteImage:` | timeline-based `_answer` | keep upstream behaviour (image part: Q4=A) | Take upstream. Q4=A (decided): upstream's `loadAttachmentImage` plumbing feeds `ChatInlineImage`; nothing of ours is added. |
| SCR-B18 | L2532-2628 | old message Column with `_readAloud`, `onLoadRemoteImage` | `final body = ProfileMessage(…, loadAttachmentImage, …)` | keep upstream behaviour | Take upstream; no screen-side image argument (see SCR-B17). |
| SCR-B19 | L3739-3985 | old composer toolbar Row incl. `IconButton 'Dictate message'` → `dictate(chat)` and its enable condition | `ConversationComposer(beforeField, field, primaryAction, onAttach, controls)`, mic inside the field gated by `_voiceInput.canDictate(controller.canDictate(chat))` | drop our variant, upstream already solves it | Take upstream. Our only content (mic entry + its enable condition) is upstream's `_dictationButton → _requestDictation → dictate` (SCR-B6). One hook outside the block, in the live-call button's `prepare:` closure (`_composerTextField`, merged ~L3096): `_voice.cancel();` first (Q3). |
| SCR-B20 | L4103-4295 | `_canForkDraft`, host `composerActions` (hand-built reasons incl. "Reconnecting"), `_composerActionButton`, `performComposerAction` header | `_changeModelControls`, `_composerActionLabels(chat)`, `_dictationButton`, `_composerActionButton`, `_performComposerAction` header | re-hang our function | Take upstream; drop our hand-built availability (upstream computes it; `fork` action removed upstream). Host contract: `@override Map<ComposerAction, String?> composerActions(ProfileChat chat) => _composerActionLabels(chat);`. Rename upstream's `_performComposerAction` to `@override Future<void> performComposerAction(` (our `{bool conversation = false}` param and `if (!conversation) _voice.endLoop();` are already merged below the block); update its two callers. |
| SCR-B21 | L4303-4307 | `composerActions(chat)[action] != null` | `_composerActionLabels(chat)[action] != null` | keep upstream behaviour | Take upstream. |
| SCR-B22 | L4638-4678 | old action sheet → `performComposerAction(chat, ComposerAction.values.byName(action))` | per-message queue sheet (`edit/steer/delete/resume`) + `_steer(...)` | keep upstream behaviour | Take upstream. Queue-sheet actions are manual touch actions; `_voiceWorkspaceChanged` ends the loop when a queue entry enters edit mode. |

### 5.5 Controller, gateway, registry, their test fixtures

| ID | lines | ours does | upstream does | decision | reason + recipe |
|---|---|---|---|---|---|
| CTL-B1 | L2734-2744 | `networkUnavailable`: `if (_closed) return; connectionStatus.networkLost(); if (!initialized…) return;` | one guard `if (_closed \|\| (!_initialized && !recovering && notificationChat == null)) return;` | re-hang our function | Upstream body; guard becomes `if (_closed) return;` / `connectionStatus.networkLost();` / `if (!_initialized && !recovering && notificationChat == null) return;`. |
| CTL-B2 | L4527-4548 | `ProfileChat(..., source: resource.gateway.sourceFor(desktopSessionSource), ...)` | `_createChatRecord(..., source: 'desktop', ...)` | re-hang our function | Upstream; replace `'desktop'` by `resource.gateway.sourceFor(desktopSessionSource)`. |
| CTL-B3 | L8129-8135 | `_sendPrompt` params `attachmentOverride`, `quietTransientFailure` | `ComposerQueueId? queuedPrompt`, `commandPrompt` | keep upstream behaviour (Q6) | Upstream. `attachmentOverride` obsolete. `quietTransientFailure` is not a parameter any more; its behaviour is re-hung per Q6 (§9.3). |
| CTL-B4 | L8222-8410 | `_sendPrompt` tail/catch: uncertain → reconnecting + sticky pause; quiet transient branch | prepare/dispatch pipeline with `submission_id`, `composer.settle(ticket, accepted/uncertain/definitelyUnsent)`, recovery | keep upstream behaviour | Take upstream wholesale. Our uncertain handling = upstream's `uncertain` branch. Quiet transient: Q6 hook (one line in the catch, §9.3). |
| CTL-B5 | L8782-8917 | own `_drainQueuedPrompts` loop with t_f0c1d125 guard `chat.offlineSnapshot \|\| !networkAvailable` | `composer.drain(...)` gated by `runtime.automaticDrainAvailable` | drop our variant, upstream already solves it | Take upstream. The `offlineSnapshot` guard is subsumed by `automaticDrainAvailable` (`!runtime.offline`, `!opening`, `!_recovering`, `!_offlineSnapshot`, access+live available). Residual NetworkGate hook (outside the block, `_composerRuntime`): append `&& connectionStatus.networkAvailable` to `connected:` and `automaticDrainAvailable:` (Q7). |
| CTL-B6 | L9805-9821 | `_settleTurn`: recompute fields; `_completedReplies.offer(chat, finalText)` (auto-speak source) | (empty; moved into `_runtime.completeTurn` and `chat.reading.completionText`) | re-hang our function | Take upstream (empty). One hook before `final notification = _notification(`: `if (!failed && !cancelled && finalText.trim().isNotEmpty && !_closed) { _completedReplies.offer(chat, finalText); }`. Field/getter/import merged cleanly. |
| CTL-B7 | L10547-10590 | `_scheduleReconnect`: `if (!networkAvailable) return;` + base attempt cap `_maxRecoveryRetries` | no cap (capped delay, infinite retries), `waitForRecovery`, diagnostics | keep upstream behaviour + re-hang our function | Upstream; re-add only `if (!connectionStatus.networkAvailable) return;` after the first guard. The cap was base code that upstream removed (§0.4). |
| CTL-B8 | L10702-10729 | `_performReconnect`: resolve uncertain queue head by history-text match (`queuedHeadDelivered`, `lib/fork/offline_queue.dart`), drain | `resumedChats` drained after recovery ends; uncertain heads reconciled by idempotent replay (`_reconcileCanonicalSubmissions`) | drop our variant, upstream already solves it | Take upstream. Delete `lib/fork/offline_queue.dart`, its import, test 3 of `test/fork/offline_queue_test.dart`. Upstream's replay is exactly-once by `submission_id`; `docs/DRAFTS_OUTBOX.md` rejects text matching as proof. No user-visible regression. |
| CTL-B9 | L11284-11300 | `unawaited(_completedReplies.close());` | composer/runtime/reading disposal | re-hang our function | Both: ours first, then upstream's lines. |
| GWY-B1 | L27-31 | `import 'wing_session_source.dart';` | `import 'connection_diagnostics.dart';` | re-hang our function | Keep both; then convert per §11 C4 (`part` instead of import). |
| GWY-B2 | L464-500 | `ready = await waitForGatewayReady(); if (closed) throw; gateway.noteReady(ready);` | capability/session-authority checks with `requireCurrent()` | re-hang our function | Upstream; insert `gateway.noteReady(ready);` right after the `requireCurrent();` following `final ready = …`. |
| GWY-B3 | L1256-1266 | `session.create` with `sourceFor(desktopSessionSource)`, `close_on_disconnect: false` | `_browserCommand('session.create', {'source': 'gui', 'request_id', 'cwd', …})` | re-hang our function | Upstream; `'source': sourceFor(guiSessionSource)` with `const String guiSessionSource = 'gui';` in `wing_session_source.dart`; update `test/wing_session_source_test.dart` expectation. `close_on_disconnect` dropped (upstream decision). |
| GWY-B4 | L1306-1327 | `session.resume` with `omit_messages`, `source` when `wing` advertised | `session.resume` with `display_projection`, supersede check | re-hang our function | Upstream + `'source': ?(wingSourceAdvertised ? wingSessionSource : null),`. Stock gateways do not advertise `wing`, so stock traffic equals upstream's. |
| REG-B1 | L240-246 | `owner.networkRestored(); if (owner.initialized \|\|` | `final eligible = owner.initialized \|\|` (loop shared by `recoverConnections()` and `resumeConnections()`) | re-hang our function | Upstream; first loop statement `if (networkChanged) owner.networkRestored();` (only the OS-network path lifts the gate). |
| TCA-B1 | L38-42 | (empty) | `final steerRequests = …; Map<String,dynamic> steerResult = {'status':'queued'};` | re-hang our function | Take only `final steerRequests = …;`; the base fixture already declares `steerResult` (t_f0c1d125 commit 7e5dec56). |
| TBF-B1 | L8-15 | `import '…/ws_client.dart';` (for `JsonRpcError`) | 4 bots imports | re-hang our function | Keep all five. |

### 5.6 Message widgets (inline image)

| ID | lines | ours does | upstream does | decision | reason + recipe |
|---|---|---|---|---|---|
| DLA-B1 | L19-23 | `this.onLoadImage` | `this.loadImage` | drop our variant, upstream already solves it (Q4=A) | Take upstream. |
| DLA-B2 | L29-33 | `Future<Uint8List> Function(ChatOutput)? onLoadImage` | `Future<Uint8List> Function(String path)? loadImage` | drop our variant, upstream already solves it (Q4=A) | Take upstream. |
| DLA-B3 | L114-175 | `actions`/`card` locals for the thumbnail hook | `if (output.kind == ChatOutputKind.image) return … ChatInlineImage(...)`, card with icon buttons | drop our variant, upstream already solves it (Q4=A, Birk 2026-11-12) | Take upstream. Images stay inline and open the preview on tap (R3 proves it before and after). |
| DLA-B4 | L202-245 | closes `card` with `actions`; tail returns `InlineMediaThumbnail` | inline icon buttons, `return Container(...)` | drop our variant, upstream already solves it (Q4=A) | Take upstream; delete our tail after the block and `import '../../fork/inline_media_thumbnail.dart'`. Delete `lib/fork/inline_media_thumbnail.dart` and `test/fork/inline_media_thumbnail_test.dart` (its tap-opens-preview assertion lives on in R3). The three widget files equal upstream after resolution. |
| MMC-B1 | L1-4 | — | `import 'package:flutter/foundation.dart' show mapEquals;` | keep upstream behaviour | Take upstream. |
| MMC-B2 | L53-57 | field `onLoadRemoteImage` | field `loadImage` | drop our variant, upstream already solves it | Take upstream (plumbing only; upstream passes `loadImage` through). |
| MMC-B3 | L70-74 | ctor `this.onLoadRemoteImage` | `this.loadImage` | drop our variant, upstream already solves it | Take upstream. |
| MMC-B4 | L571-630 | old `MarkdownBody` with `_DeliverableBuilder(..., onLoadRemoteImage)` | `prose(...)` refactor | keep upstream behaviour | Take upstream. |
| MMC-B5 | L669-678 | `_DeliverableBuilder(onOpen, onDownload, onLoadImage, {maxWidth})` | `(onOpen, onDownload, {maxWidth, loadImages, loadImage})` | drop our variant, upstream already solves it | Take upstream; remove our field `onLoadImage`. |
| MMC-B6 | L715-719 | `onLoadImage: onLoadImage` | `loadImage: loadImage` | drop our variant, upstream already solves it | Take upstream. |
| PMS-B1 | L626-630 | `onLoadRemoteImage: onLoadRemoteImage` | `loadImage: loadAttachmentImage` | drop our variant, upstream already solves it | Take upstream. |
| PMS-B2 | L774-819 | old copy-header layout with `MarkdownMessageContent(... onLoadRemoteImage ...)` | `Expanded(child: answer)` + copy action | keep upstream behaviour | Take upstream; remove our `onLoadRemoteImage` field/param and any surviving uses (`git grep -n onLoadRemoteImage -- lib` empty). |

The three widget files' fork diff is only the image plumbing; after resolution they equal upstream (Q4=A).

## 6. Silent merge losses and semantic breaks without conflict markers

The auto-merge took upstream's lines here; nothing flags them. Each must be fixed in the merge commit or right
after it (plan Tasks 3-8, 10).

| # | file | what happens | fix |
|---|---|---|---|
| S1 | `VoiceCapture.kt` | merged `started()` has `arm(attempt, 125000, …)` and the file branch `capture.setMaxDuration(120000)`: our 600 s dictation limit silently drops to 2 min (`MAX_RECORDING_MS` stays declared but unused) | `arm(attempt, (MAX_RECORDING_MS + RECORDING_DEADLINE_BUFFER_MS).toLong(), "Recording reached its time limit. Please try a shorter recording.")`, `capture.setMaxDuration(MAX_RECORDING_MS)`. 600 s ≈ 7.2 MB, below `MAX_VOICE_BYTES` 25 MiB. **Hard requirement (Birk).** Tests: R4-native (`test/regression/daily_flow_dictation_limit_test.dart`, static guard over `VoiceCapture.kt`: `MAX_RECORDING_MS = 600_000`, `setMaxDuration(MAX_RECORDING_MS)`, `MAX_RECORDING_MS + RECORDING_DEADLINE_BUFFER_MS` present, no literal `120000`/`125000`/`120_000`/`125_000`; runs in the CI host-test step) and R4-dart (§14). A static guard is used instead of a Kotlin unit test because `VoiceCapture` needs an `Activity` and a `SpeechRecognizer`; the guard proves the constant is what both call sites use. |
| S2 | `VoiceChannel.kt` | upstream guard `if (LiveVoiceRuntime.audioOwned && call.method in listOf("start","speak","play"))` does not cover fork mic entries | `listOf("start", "startVad", "openMicLink", "speak", "play")` |
| S3 | `AndroidManifest.xml` | duplicate `<uses-permission>` for `MODIFY_AUDIO_SETTINGS`, `FOREGROUND_SERVICE_MICROPHONE`, `BLUETOOTH_CONNECT` (both sides added them) | remove our three lines; keep upstream's block |
| S4 | `test/session_visibility_test.dart` | both sides changed `hasLength(159)` → `160`; merged data has 161 rows (upstream `room-worker` + our `wing`) | the all-sources assertion → `hasLength(161)` |
| S5 | `test/profile_workspace_controller_test.dart` | our `promptSubmitFailures` injection in `Host.rpc` sits after upstream's new `prompt.submit` branch and never fires | move our block to the top of the upstream `prompt.submit` branch; same check in `test/support/profile_browser_fixture.dart` |
| S6 | `VoicePlayback.kt` / `VoiceChannel.kt` | with upstream's literal `pause()` (VCH-B4) TTS would stop on every Activity pause, breaking screen-off conversation | `VoicePlayback.stop(owner: String? = null, force: Boolean = false)` returns early when `owner == null && !force && keepsVoice()` (lambda passed in the constructor: `VoicePlayback(activity, ::emit, keepsVoice = { offline.keepsVoice() })` with a new last constructor parameter `keepsVoice: () -> Boolean = { false }` is still a literal construction; the lambda reads `offline` lazily, so field order does not matter); every non-pause caller passes `force = true`; `MainActivity.onPause` gets `voiceChannel?.pauseOffline()` after the literal `voiceChannel?.pause()`. ANNAHME: `VoicePermissionLifecycleGuard` accepts constructor args and the extra statement; CI step "permission lifecycle" decides; if it rejects, Q11=A (decided): maintain a fork edit of upstream's guard. |
| S7 | `pr-quality.yml` triggers | `push: ['**']` makes `tools/factory/ci-suite.sh` (push + `gh workflow run` on the same ref, same concurrency group) cancel its own first run → false red; `dispatch-check.sh` lists runs without `--workflow` and may pick the pr-quality run | ci-suite: drop `gh workflow run`, list with `--event push --workflow pr-quality.yml`; dispatch-check: add `--workflow "$workflow"` to `gh run list` |
| S8 | `voice-apk.yml`, `voice-review.yml` | pin Flutter `3.44.0`; upstream `pubspec.yaml` needs `>=3.47.9` and `ime-cache-fix.gradle.kts` pins the 3.47.9 embedding jar | set `flutter-version: '3.47.9'` in both |
| S9 | `voice_input_activity.dart` (upstream file) | shows `/ 120s` | `/ ${controller.maxSeconds}s` (SCR-B8). Tests: R4-dart (§14): the recording row shows `Recording · 0s / 600s` on the Parakeet route with default settings and `/ 600s` on the Android-recognizer route, `120s` never appears; the controller does not stop at 121 s and stops at `maxRecordingSeconds` = 600. |
| S10 | `profile_workspace_controller.dart` `resumeConnection` | upstream tests that call `networkUnavailable()` then `resumeConnection(networkChanged: true)` keep the sticky NetworkGate lost | one hook line at the top of `resumeConnection`: `if (networkChanged) connectionStatus.networkRestored();` |

## 7. Table C — API-surface breaks in non-conflicting code

Fork-owned files auto-merge unchanged but call upstream APIs that changed. `git grep -w <symbol> upstream/main`
was run for each. Ranked list of non-compiling files: `workspace_voice_driver.dart` (~15 sites) >
`test/support/voice_workspace_fixture.dart` + 9 tests using it > voice prefs tests > `offline_queue_test`,
`registry_network_test`, `car_mode_bridge_test` > `car_mode_bridge.dart` (~8) > `car_mode_screen.dart` (2) >
`voice_offline_prefs.dart`, `voice_offline_settings.dart`, `barge_in_settings.dart` > `chat_voice_view.dart`.

| symbol | our callers (origin/voice-offline) | upstream/main status | fix |
|---|---|---|---|
| `ProfileTurnStatus`, `chat.status` | `chat_voice_view.dart:16-22`, `car_mode_bridge.dart:109,120-121`; tests `workspace_conversation_test.dart` (206,261,301,348,392,417), `workspace_screen_off_test.dart:135`, `car_mode_workspace_test.dart:247`, `offline_queue_test.dart` | removed → `chat.runtime.execution` (`ChatExecution`), `chat.runtime.recovery` (`ChatRecovery`), `canSteer`, `reconnecting` | rewrite via `ChatVoiceView` (§9.2); tests start a turn through gateway events (`stockChatReply`/`message.start`, pattern `test/profile_workspace_controller_test.dart:842-847` upstream) instead of assigning status |
| `ProfileMainActivity`, `chat.mainActivity/mainToolActivity/tool` | `car_mode_bridge.dart:121-131` | `ChatMainActivity`, `chat.runtime.mainActivity/mainToolActivity/tool` | rename |
| `chat.busy` | `chat_voice_view.dart:7`, `car_mode_bridge.dart:101`, tests | removed | `chat.runtime.blocksTurnAdmission` (executionActive \|\| needsInput \|\| reconnecting = old `busy`) |
| `chat.draft` | `chat_voice_view.dart:9`, tests | removed | `chat.composer.observation.text` |
| `chat.approval/clarification/sensitivePrompt` | `chat_voice_view.dart:13`, `car_mode_bridge.dart:103-105` | removed | `chat.runtime.needsInput` |
| `chat.opening`, `commandRunning`, `changingAnswer` | driver 462-465,524; bridge 104,118 | `chat.runtime.opening/commandRunning/changingAnswer` | prefix |
| `chat.editingQueuedPrompt` | driver 466 | removed | `chat.composer.observation.editing != null` |
| `chat.offlineSnapshot` | driver 524, bridge 104, `workspace_conversation_test` 72-104 | chat-level field removed; `ProfileWorkspaceData.offlineSnapshot` (controller:408, read-only) | `chat.runtime.offline \|\| (controller.current?.offlineSnapshot ?? false)` |
| `chat.queuedPrompts/queuePaused/draftSubmissionUncertain` | `offline_queue.dart`, tests | `chat.composer.observation.queue/paused/submissionUncertain` | tests rewritten; file deleted (CTL-B8) |
| `chat.runtimeId`, `chat.messages` | `offline_queue.dart:18`, fixtures, tests | `chat.runtime.runtimeId`, `chat.reading.messages` | prefix |
| `steer(chat, text, {preserveComposer})` | driver 534, 569-570 | `Future<bool> steer(ProfileChat, String)`; consumes the draft only if `text == draft.trim()` | drop `preserveComposer: true`; drop the manual `updateDraft(chat, '')` after an accepted steer (upstream consumes) |
| `queuePrompt(chat, text)` | driver 525, 572 | exists, same signature | none |
| `HermesVoice.forConnection(SavedConnection, String)` | driver ~388 | `(ConnectionAccess, String)` | `HermesVoice.forConnection(_controller.access, profile)` or `controller.voiceForChat(chat, chat.key)` |
| `insertVoiceTranscript(TextEditingValue, String)` | driver ~574 | `VoiceDraft insertVoiceTranscript(VoiceDraft, String)` | convert at the host edge (host method applying a transcript) |
| `VoiceOutputController.speak(…, VoicePreferences, …)` → `Future<bool>` | driver ~385-396, `barge_in_settings.dart:91-96` | `speak(Object, String, VoiceOutputSettings, createRemote)` → `Future<void>` | VOC-B1/B2 restore `Future<bool>`; callers pass `controller.appPreferences.current.voiceOutputSettings` or `LocalVoiceOutputSettings(voice:, rate: AppVoiceRate.normal)` |
| `VoicePreferences`, `VoiceInputRoute`, `VoiceProcessing`, `tryReadVoicePreferences` | `voice_offline_prefs.dart:4,176-185`, `workspace_voice_driver.dart:14,253,355,586-591,647`, `voice_offline_settings.dart:6,23-57,178`, `barge_in_settings.dart:7,30,94,119`, `car_mode_session.dart:8,299`; tests `voice_workspace_fixture.dart:14,201`, `vad_settings_test.dart`, `transcription_deadline_test.dart`, `voice_offline_prefs_test.dart` (~45), `voice_offline_prefs_tryread_test.dart`, `voice_offline_settings_test.dart`, `voice_vad_input_test.dart`; `voice_settings_fixture.dart:84` | file deleted | §9.1: `voiceInputSettingsFor(...)`, `is VadVoiceInputSettings`, `VoiceOfflinePrefs.localEngine`; delete `voice_offline_prefs_tryread_test.dart` |
| `VoiceInputController(createRemote:, vadRound:)`, `start(VoicePreferences, VoiceOfflinePrefs, TextEditingValue, cb)` | tests `transcription_deadline_test.dart:24-31`, `voice_vad_input_test.dart:31,66,219`, `car_mode_bridge_test.dart:103` | ctor `({device})`, `start(VoiceInputSettings, VoiceDraft, cb, {createRemote})` | VIC re-hang keeps `vadRound`; tests construct `VadVoiceInputSettings`/`LocalVoiceInputSettings`, `VoiceDraft`, `createRemote:` per call |
| `ProfileWorkspaceController({connection:, …})` | `voice_workspace_fixture.dart:90-100`, `car_mode_bridge_test.dart:84-95`, `offline_queue_test.dart:19-30`, `registry_network_test.dart:23-28` | needs `access: ConnectionAccess(connection: …, dashboardOAuth: null)`, `appPreferences: AppPreferences(prefs)` | pattern from upstream `test/session_visibility_test.dart:130-143` |
| `WorkspaceAccent.fromName/preferenceKey/mint` | `car_mode_screen.dart:47-49` | removed; accent is `AppPreferenceField.accent` (`workspace_accent_v1`), `AppAccentPreference` (`teal`), rendering `AppAccentRendering.appearance` | read via `controller.appPreferences.current` accent (typed) through the bridge |
| `VoicePreferencesCard(preferences:, device:)` | `vad_settings_test.dart:78`, `voice_settings_fixture.dart:84` | `VoicePreferencesCard(createSession: …)` | mount like upstream `test/voice_preferences_test.dart` `show` |
| `WorkspaceVoiceHost.composerActions` type `Map<ComposerAction,String?>` | driver 498-546 | screen delegates to `_composerActionLabels` (String?) | keep type; only `== null` is read |
| `controller.completedReplies` | driver ~154 | fork member in a conflict file | CTL-B6/B9 |
| `controller.networkRestored()` | registry, tests | fork member (merged cleanly) | REG-B1, S10 |
| `ProfileGateway.sourceFor/noteReady/wingSourceAdvertised` | gateway, controller | fork extension compiles; new `session.create` sites | GWY-B2..B4; 5 `session.create/resume` call sites exist now (`bots_repository.dart:547` stays upstream) |
| `VoiceDevice.stop(id, {timeout})` | `android_voice.dart` (merged unchanged) | upstream interface `stop(String id)`; upstream fixtures implement `VoiceDevice` | keep the optional named param (fixtures still compile); TVF-B1 |
| `mediaReferencePattern`, `ChatImagePreview(bytes:, title:)`, `saveDevicePreference`, `ComposerAction.{send,steer,queue,stop}`, theme tokens, `MonitoringRuntime.activityVisible`, `R.drawable.ic_stat_monitoring` | various | exist | none (ANNAHME for `ChatImagePreview` named params; verify with `git grep -n -A12 "class ChatImagePreview" -- lib/core/widgets/chat_image_preview.dart`) |

Fork files that compile unchanged: `barge_in_coordinator`, `barge_in_policy`, `car_mic_session`,
`headphone_route`, `language_guess`, `sentence_splitter`, `speech_queue`, `speech_segments`, `turn_listener`,
`vad_input_round`, `vad_voice_device`, `background_voice`, `car_mode_palette`, `car_mode_state`,
`vad_endpoint.dart`, `wing_session_source.dart`, `network_gate.dart`, `vad_settings_section.dart` (but see
§11 D1), all Kotlin fork files (they use only `MonitoringRuntime.activityVisible`, `MainActivity`,
`R.drawable.ic_stat_monitoring` and each other).

## 8. Upstream voice/live mode vs ours (card item 4)

Upstream's "live voice" (`lib/core/services/live_voice_session.dart`, `live_voice_protocol.dart`,
`live_voice_transport.dart`, `profile_workspace_live_voice.dart`, `lib/core/widgets/live_voice_scope.dart`,
`android/.../LiveVoiceService.kt`) is a **cloud full-duplex call**: OpenAI GPT-Live over WebRTC
(`flutter_webrtc`), session brokered by the Wing Hermes plugin (`POST plugins/wing/voice/v2/session`, 404 →
"plugin is not installed or enabled"), billed to a ChatGPT plan or OpenAI API key. Spoken turns are not saved
to Hermes history. Upstream dictation remains "tap mic, speak, tap Stop, text lands in the draft; Wing never
sends automatically" (`docs/VOICE.md`). `git grep -i -E "vad|silence|barge|hands-free|MediaSession|car mode|conversation mode|autoSpeak" upstream/main -- lib android/app/src/main`
finds nothing relevant.

| our feature | ours (files) | upstream equivalent | verdict | decision |
|---|---|---|---|---|
| VAD chain (Silero end of speech, Parakeet on device) | `VadCapture.kt`, `OfflineSpeech.kt`, `SpeechModelStore.kt`, `VoiceOfflineHandler.kt`, `vad_input_round.dart`, `vad_voice_device.dart`, `vad_endpoint.dart` | none (upstream local = Android `createOnDeviceSpeechRecognizer`) | coexists | keep; hooks only (VCH-B3, VIC-B6) |
| maximum dictation duration | `MAX_RECORDING_MS` 600 s, `maxRecordingSeconds = 600`, vad `voice.vad_max_seconds` | 120 s / 125 s literals | collides (same lines) | keep ours (VIC-B7, §6 S1, S9) |
| system-recognizer fallback | `RecognizerSelection.kt` | none; upstream doc: "Wing shows an error if your chosen engine is unavailable" | collides (policy + code) | keep ours (VCA-B2/B3/B4); fork note in `docs/VOICE.md` (fallback stays within "Local", never switches to Hermes) |
| wait time after stop | `stop(id, timeout: transcriptionDeadlineFor(seconds))`, native `timeoutMs` | fixed 5000 ms | collides (signature) | keep ours (VCA-B5, VCH-B2) |
| "…" filter | `cleanTranscript` | none (empty results → notice downstream) | complements | keep ours (VCA-B6) |
| input route `vad` | `voice.input=vad` | schema accepts only `local\|hermes` | **collides hard**: stored `vad` → `AppPreferenceIssue` → dictation blocked ("Repair voice input settings…") | re-hang via `voice.local_engine` + migration (Q1) |
| conversation mode (read reply aloud, reopen mic) | `workspace_voice_driver.dart`, `completed_replies.dart`, `speech_queue.dart`, `turn_listener.dart` | none; live call is a different product | coexists; collides at runtime with the live call | keep; mutual exclusion (Q3) |
| auto-send during running turn / offline (t_f0c1d125) | driver `sendConversationTurn` | live call delegates text via steer/`enqueueExternal`; dictation never sends | coexists | keep (§9) |
| barge-in | `barge_in_*`, `turn_listener.dart`, `HeadphoneRouteChannel.kt` | model-side interruption inside the live call | coexists | keep; blocked during a live call |
| background voice | `BackgroundVoiceService` (`microphone` FGS, id 214611, channel `voice_conversation`, `com.tarkilhk.wing/background_voice`) | `LiveVoiceService` (`microphone\|mediaPlayback`, id 214602, `wing_live_voice`, `com.tarkilhk.wing/live_voice`) | coexists (no id/channel/name clash; manifest has both) | **keep separate**; different owner, stop semantics and lifecycle (`MonitoringRuntime` pinning). Mutual exclusion instead of merging (Q3) |
| car mode | `lib/car_mode/*`, SCO hold `CarMicSession` | none | coexists | keep; ended on live-call start |
| media keys / headset | `VoiceMediaKeys.kt` (`MediaSession("WingVoice")`), `HeadsetMicRoute.kt` | none (WebRTC `AudioSwitchManager` for routing) | coexists | keep; disabled during a live call |
| TTS auto-speak queue, language segments | `speech_queue.dart`, `speech_segments.dart`, `LanguageSpeech.kt` | `VoicePlayback.speak` without segments | collides (signatures) | keep (VPB-B1/B2, VOC-B1/B2) |
| MEDIA lines not read aloud | `spokenReplyText` filter | not stripped upstream | upstream does not solve it | keep |

Runtime resources shared with the live call: microphone (WebRTC vs `MediaRecorder`/`AudioRecord`/SCO), audio
focus (our `AUDIOFOCUS_GAIN_TRANSIENT` would end the call), audio mode (`MODE_IN_COMMUNICATION` stops our
`BackgroundVoiceService` on API 31+), completion stream (a voice-delegated reply would be spoken twice).
Required regardless of Q2/Q3: §6 S2 guard; `bool get liveVoiceActive` on `WorkspaceVoiceHost` (screen:
`LiveVoiceScope.maybeOf(context)?.session.active == true`), checked in `_speakCompletedReply`,
`openListen`, `_voiceDeviceEvent`, `enterCarMode`, `talk`, `syncVadRoute`/`syncMediaKeys`,
`canContinueConversation`; `BackgroundVoiceChannel` "hold" refuses while `LiveVoiceRuntime.audioOwned`.
**No "drop ours for upstream's" candidate exists**: upstream solves none of our features.

## 9. t_f0c1d125 re-hang and the voice/queue seams

### 9.1 Voice input settings (VPF, Q1)

- `VoiceOfflinePrefs` (`lib/voice_offline/voice_offline_prefs.dart`) gains `static const localEngineKey =
  'voice.local_engine'` (in `keys`), `enum VoiceLocalEngine { system, parakeet }`, `accepts` for
  `system|parakeet`, field `localEngine` (default `system`), and
  `static Future<void> migrateLegacyVadRoute(SharedPreferences p)`: if `p.getString('voice.input') == 'vad'`
  then `setString('voice.local_engine', 'parakeet')` and `setString('voice.input', 'local')`; idempotent.
  Its import of `core/services/voice_preferences.dart` and `tryReadVoicePreferences` are removed.
- Call site: `createApplicationDependencies()` in `lib/core/services/application_startup.dart` (async,
  verified): `await VoiceOfflinePrefs.migrateLegacyVadRoute(preferences);` directly after
  `final preferences = await SharedPreferences.getInstance();`, i.e. before `AppPreferences(preferences)`.
- `lib/core/models/voice_processing_settings.dart` (upstream file, role `domain` in `roles.json`; a sealed
  subclass must live in the same library): add a **field-less marker**
  `final class VadVoiceInputSettings extends VoiceInputSettings { const VadVoiceInputSettings(); }`. No import:
  a domain library must not reach `shared_preferences`, so the marker cannot carry `VoiceOfflinePrefs`. The
  only exhaustive switch over `VoiceInputSettings` upstream is in `voice_input_controller.dart` (VIC-B6).
- `VadInputRound` (`lib/voice_offline/vad_input_round.dart`) gains a constructor parameter
  `VoiceOfflinePrefs Function()? roundSettings` (default `() => const VoiceOfflinePrefs()`), exposed as
  `VoiceOfflinePrefs roundSettings()`; the screen supplies the car-mode-adjusted prefs (SCR-B4), the controller
  reads them in its VAD branch (VIC-B6).
- New fork file `lib/voice_offline/voice_input_settings_for.dart`:
  `VoiceInputSettings? voiceInputSettingsFor(AppPreferences app, SharedPreferences prefs)`:
  `base = app.current.voiceInputSettings`; returns `const VadVoiceInputSettings()` when
  `base is LocalVoiceInputSettings && VoiceOfflinePrefs.read(prefs).localEngine == VoiceLocalEngine.parakeet`,
  else `base` (null = repair needed, upstream's own state). Used by SCR-B6, the
  driver (`vadRoute()`), car mode (`car_mode_session.dart:299` route name `vad|local|hermes` computed from it)
  and barge-in settings.
- Stored values: the 5 shared keys (`voice.input`, `voice.output`, `voice.android_language`,
  `voice.android_voice`, `voice.android_rate`) have identical names and values upstream; all fork keys are not
  `AppPreferenceField`s and are ignored by upstream's schema (ANNAHME: no upstream code prunes unknown keys;
  check `git grep -n -E "remove\(|getKeys" -- lib/core/services/app_preferences.dart lib/core/services/application_startup.dart`).

### 9.2 Chat state for voice (`ChatVoiceView`)

`lib/voice_offline/chat_voice_view.dart` becomes the single adapter; the driver and `car_mode_bridge.dart`
read only through it:

```
extension ChatVoiceView on ProfileChat {
  bool get voiceBusy => runtime.blocksTurnAdmission;
  String get voiceDraft => composer.observation.text;
  bool get needsUserInput => runtime.needsInput;
  bool get voiceOpening => runtime.opening;
  bool get voiceCommandRunning => runtime.commandRunning;
  bool get voiceChangingAnswer => runtime.changingAnswer;
  bool get voiceEditingQueue => composer.observation.editing != null;
  bool get voiceTurnEnded => runtime.execution == ChatExecution.failed || runtime.execution == ChatExecution.cancelled;
  ListenChatState get listenState => runtime.canSteer || runtime.needsInput
      ? ListenChatState.steerable
      : (runtime.execution == ChatExecution.submitting || runtime.reconnecting || runtime.executionActive)
          ? ListenChatState.busy
          : ListenChatState.idle;
}
```

ANNAHME: `runtime.needsInput` with an open question while running keeps `canSteer` true (old `attention`
status was steerable); the existing `workspace_listen_turn_test` decides.

### 9.3 Auto-send after disconnect (card t_f0c1d125)

Where it lives today (verified on origin/voice-offline): `lib/voice_offline/workspace_voice_driver.dart`
`sendConversationTurn` (lines 482-563): (1) `recovering || chat.opening || chat.offlineSnapshot` →
`awaitingReply = true; await _controller.queuePrompt(chat, text)` (conversation stays active);
(2) `chat.voiceBusy` → `steer`, clear draft if equal, `openListen`; (3) else `performComposerAction(send,
conversation: true)`. `_listenTarget` (barge-in) calls `steer(..., preserveComposer: true)` and `queuePrompt`.
Controller hooks: `_drainQueuedPrompts` guard (066bbb51), `quietTransientFailure`, `_performReconnect` head
resolution (`lib/fork/offline_queue.dart`), `_scheduleReconnect` guard, NetworkGate
(`lib/fork/network_gate.dart` wired in `server_connection_status.dart`).

Attachment to upstream:

| behaviour to preserve | upstream API | fork code after the merge |
|---|---|---|
| queue while offline / recovering / opening | `queuePrompt(chat, text)` → `composer.enqueue` → persistent outbox (`composer_work_v3.*`) | driver condition becomes `_controller.recovering \|\| chat.voiceOpening \|\| chat.runtime.offline \|\| (_controller.current?.offlineSnapshot ?? false) \|\| !_controller.connectionStatus.networkAvailable`; call unchanged. `queuePrompt` (not `send`) because the dictation must not touch the user's draft. Throws `StateError` while a submission is in flight; the call is inside `host.run` (snackbar), as today. |
| do not drain while offline (t_f0c1d125 bug fix) | `ComposerSession.drain` returns while `!runtime.automaticDrainAvailable` (`composer_session.dart:1797,1816`), which includes `!_offlineSnapshot`, `!runtime.offline`, `!_recovering` | our guard dropped (CTL-B5); NetworkGate adds `&& connectionStatus.networkAvailable` to `connected`/`automaticDrainAvailable` in `_composerRuntime` |
| drain on reconnect | `_performReconnect` drains `resumedChats` after recovery ends | none |
| steer during a running turn | `steer(chat, text)` (`runtime.canSteer` = running && ready; returns false when refused) | drop `preserveComposer`; keep `if (accepted) openListen(chat)`; refused → existing `actions[steer] != null` path ends the loop |
| conversation mode stays active | driver state (`conversation`, `awaitingReply`) | unchanged; the reply arrives through CTL-B6 `_completedReplies.offer` |
| no hard error + no sticky pause on a transient pre-submit failure (t_8c76c35a) | upstream: `settle(definitelyUnsent)` → `drain` sets `_paused = true` until the user taps Resume | Q6=B DECIDED (Birk 2026-11-12, keep ours): fork `lib/fork/transient_send.dart` with `Expando<bool>`; one hook line in `_sendPrompt`'s catch (`!submitted && isTemporaryWorkspaceFailure(error)` → mark), one hook line in `_performReconnect` before draining resumed chats (`TransientSend.take(chat)` → `await resumeQueue(chat)`; `ProfileWorkspaceController.resumeQueue(ProfileChat)` exists upstream, controller:8697). Pinned by R5. |
| uncertain head after reconnect is not sent twice | upstream idempotent replay by `submission_id` | ours dropped (CTL-B8) |

Upstream does queue offline and drain on reconnect for never-submitted messages
(`docs/DRAFTS_OUTBOX.md`; upstream test `test/conversation_outbox_lifecycle_test.dart` "offline Send survives
restart and reconnect drains FIFO"). Birk's note "upstream does not auto-resend after connection loss" holds
for **uncertain** deliveries only: those are replayed with the same payload on the next resume and the rest of
the queue stays paused until Resume.

Tests that prove the behaviour after the merge:

| test | proves | change |
|---|---|---|
| `test/fork/offline_queue_test.dart` test 1 (rename file to `test/fork/offline_send_test.dart`) | outage shows offline at once; queued text not drained offline; exactly one `prompt.submit` after `networkRestored()` + reconnect | assertions via `composer.observation.queue/paused/text`; controller ctor with `access`/`appPreferences` |
| same, test 2 "flaky send right after reconnect…" | transient pre-submit failure does not stick | keep expectation if Q6 default; else assert upstream pause |
| same, test 3 (history-text head) | — | delete (CTL-B8); upstream "lost ACK recovers the original receipt without executing twice" covers it |
| `test/fork/network_gate_test.dart` | gate semantics | unchanged + case "gate lost wins over `_recoveries`" |
| `test/fork/registry_network_test.dart` | registry marks owners | new ctor; cases `recoverConnections()` lifts the gate, `resumeConnections()` does not |
| `test/voice_offline/workspace_conversation_test.dart` "a second dictation while the first turn still runs becomes a steering message", "a dictation while reconnecting is queued and sent once reconnected", "flaky send … mic reopens once it drains" | steer, offline queue, loop survives | replace `chat.status = …` and `chat.offlineSnapshot = …` assignments by gateway events and `networkUnavailable()`/`networkRestored()`; `queuedPrompts` → `composer.observation.queue` |
| `test/profile_workspace_controller_test.dart` (merged) | `networkRestored()` hook, `promptSubmitFailures` | S5 |

## 10. The 8 "Offene Punkte" from the strategy doc (Spec §6)

| # | item | resolution |
|---|---|---|
| 1 | Route key `voice.input=vad` vs upstream's new input configuration | Upstream's strict schema rejects `vad` (dictation would be blocked). Re-hang as `voice.local_engine=parakeet` + one-time migration + `VadVoiceInputSettings` (§9.1). Settings placement: Q1=A decided (engine row, values migrated, behaviour identical). |
| 2 | Inline image: `inline_media_thumbnail.dart` vs upstream `ChatInlineImage` | Upstream renders image deliverables inline (`lib/core/widgets/chat_inline_image.dart:14`, boxed max 420×320, overlay download, tap → preview). Ours: full width, button row with "Open preview". DECIDED Q4=A (Birk 2026-11-12): take upstream's `ChatInlineImage`, delete `inline_media_thumbnail.dart` and its test and hooks. Regression R3 checks "images show inline and open the preview on tap". |
| 3 | Duplicate manifest permissions | Present again after the merge (3 duplicates, §6 S3): remove ours. |
| 4 | `BackgroundVoiceService` vs `LiveVoiceService` | Keep separate; mutual exclusion (§8, Q3). No id, channel or manifest clash. |
| 5 | Native guards in `VoiceChannel`/`VoiceCapture` | VCH-B1..B4, VCA-B1..B6; `audioOwned` guard extended (S2); `pause()` literal for `VoicePermissionLifecycleGuard` with `pauseOffline()` + `VoicePlayback.stop` keep-voice hook (VCH-B4, S6); `requestLivePermissions` case kept; every Dart method name routes (`start`, `stop`(timeoutMs), `cancel`, `speak`(segments), `startVad`, 12 VAD/model/media-key names via `offline.handle`). |
| 6 | `roots.json`/`roles.json` entries | Both are enforced in CI now (§11): census entries for every fork file, role inventory for every fork `lib` file, 3 cycles to break, 1 dialog rule. |
| 7 | `NetworkGate` semantics vs upstream connection status | Upstream has no OS-network flag ("a device-network event is a reason to retry, never proof of server access", `network_availability.dart:5`) and shows "Reconnecting" while a recovery is scheduled; ours shows "disconnected" at once and stops retry timers until the OS reports network. Keep (adapt with 5 hooks: CTL-B1, CTL-B7, `_composerRuntime`, REG-B1, S10). Q7=A decided: keep. Pinned by R6. Known risk unchanged from today: a missed OS "available" event leaves the app offline until the next one. |
| 8 | Offline queue → upstream `ComposerSession` | `lib/fork/offline_queue.dart` deleted (upstream solves the uncertain head); auto-send attaches to `queuePrompt`/`steer`/`automaticDrainAvailable` (§9.3); transient-failure stickiness: Q6=B decided (keep our auto-resume), pinned by R5. |

## 11. Upstream CI gates our fork must pass (new since the base)

`pr-quality.yml` runs `scripts/check_commit_linters.py --dart-only` (→ `tools/architecture/check_all.dart`
plus every rule in `tools/architecture/rules/*.dart`), `tools/architecture/rules/authored_census.py`, native
guards and `scripts/test.py`. Findings by reading:

- **Census** (`tools/architecture/roots.json`): every git-visible file needs a `files[]` entry
  `{"path": …, "area": <first path segment or "root">, "provenance": "tracked"}`, sorted, no duplicates, no
  stale entries. All fork-added files (`git diff --name-status --diff-filter=A 151ee281 HEAD`) must be added;
  deleted fork files (`lib/fork/offline_queue.dart`, `lib/fork/inline_media_thumbnail.dart`, `test/fork/inline_media_thumbnail_test.dart`) must not appear. Must be
  regenerated after every later commit that adds/removes files.
- **Role inventory** (`tools/architecture/roles.json`, `"files": {"<lib path>": {"role", "feature",
  "library"}}`), required for every fork `lib/**.dart`. Proposed: `domain` (voice) for `vad_endpoint`,
  `language_guess`, `sentence_splitter`, `speech_segments`, `speech_queue`; `domain` (connections) for
  `network_gate`; `data` (voice) for `voice_offline_prefs`; `application` (voice) for `barge_in_policy`,
  `barge_in_coordinator`, `turn_listener`, `car_mic_session`, `vad_input_round`, `completed_replies`,
  `chat_voice_view`, `transient_send` (Q6), `voice_input_settings_for` (§9.1); `platform` (voice) for
  `vad_voice_device`, `headphone_route`, `background_voice`; `data` (conversation, library
  `lib/core/services/profile_gateway.dart`) for `wing_session_source` (part); `presentation` (voice) for
  `car_mode_bridge`, `car_mode_state`, `car_mode_session`, `workspace_voice_driver`, `barge_in_settings`,
  `voice_offline_settings`; `view` (voice) for `car_mode_screen`, `car_mode_palette`,
  `vad_settings_section`. ANNAHME: role constraints as read from the rules;
  the CI run is authoritative.
- **Library cycles** (`ARCH_LIBRARY_CYCLE`): C1 `android_voice.dart` ↔ `vad_voice_device.dart` (fix: drop the
  `android_voice` import in `vad_voice_device.dart`; cast `Object`; own `MethodChannel('com.tarkilhk.wing/voice')`);
  C3 `completed_replies.dart` ↔ controller (fix: `CompletedReplies` carries `Object chat` or is generic, no
  controller import); C4 `profile_gateway.dart` ↔ `wing_session_source.dart` (fix: `part of
  'profile_gateway.dart'`; callers import `profile_gateway.dart`). C2 (`offline_queue.dart`) disappears with
  CTL-B8. Upstream business files must never import `car_mode_*`, `workspace_voice_driver`, or settings
  widgets (transitive view dependency rule).
- **Dialog/form rules**: `lib/core/widgets/vad_settings_section.dart:72` `AlertDialog` → `StudioDialog`;
  `:76-79` `TextButton(child: Text('Cancel'))` → `StudioFormActions`. Forced by upstream CI; small visual
  change of one confirmation dialog (model removal), not a fork function drop.
- **Native guards**: `VoiceFileApiGuard` (no `java.io` in `VoiceChannel/VoiceCapture/VoicePlayback`, VCA-B1),
  `VoicePermissionLifecycleGuard` (VCH-B4, S6), `native_retired_resources.py` (clean: no fork res files).
- **Workflows**: Flutter 3.47.9 (S8); `push: ['**']` cannot be narrowed (the gate rule requires it) → every
  push runs the emulator job (Q10=A decided: accepted); NDK `28.2.13676358` via `wing.ndkVersion` (ANNAHME: hosted runner
  installs it; else copy upstream's "Install pinned Android SDK" step into `voice-apk.yml`).
- `minSdk` moves 24 → 29 with upstream (`build.gradle.kts:84`); base was 24, so this is upstream behaviour.
  ANNAHME: Birk's phone runs Android ≥ 10 (Xperia 5 IV, Android 14 per the voice docs); `aapt dump badging`
  of the built APK and the phone install confirm it.

## 12. Data migration (card item 8)

Upstream CHANGELOG (upstream/main):
- 1.2.0 "Before updating" (line ~311): "Saved drafts and queues use a new per-conversation format. Earlier
  saved drafts and queues are not imported; send them or copy their text and files before updating." Also:
  configuration backups version 2, older backups cannot be imported.
- 1.3.0 "Before updating" (line 134-135): "This release changes the local draft and outbox format. Earlier v2
  records are not imported. Finish or copy out unsent messages and queued work before updating; configuration
  backups do not include them. Saved conversations remain on Hermes."

Meaning for Birk's installed Wing Voice (built from voice-offline = upstream 1.1.3 storage): all unsent
drafts, unsent attachments metadata and **queued prompts, including dictations queued offline by
t_f0c1d125**, live in one SharedPreferences string per connection, key `composer_drafts_v1_<identity>`
(`lib/core/services/composer_draft_store.dart:44` on origin/voice-offline). After the update nothing reads or
deletes it (`git grep composer_drafts_v1 upstream/main -- lib` is empty): the new store starts empty, the old
string stays orphaned. **Unsent work is lost silently on update.** Sent conversations stay on Hermes. Our
voice settings survive (§9.1; `vad` via the migration). The update installs over the existing app (same
`applicationId com.tarkilhk.wing.voice`, same sideload key `~/.android/wing-voice.keystore`, versionCode 2518 >
2356; ANNAHME until `aapt dump badging` shows it). Older configuration backup files (v1) can no longer be
imported (ledger L14). → Q8 DECIDED A: a one-time step before install; afterwards behaviour is identical. The
coder card only builds and signs the APK; a separate installer/device card pings Birk via ntfy, waits for his
"ok" (he has sent his open drafts), then installs and runs R1-R8 on the phone (plan section "Installer/device
card").

## 13. Questions to Birk — all DECIDED (Birk 2026-11-12)

Source: card t_dcfc9770 comment thread, Birk 2026-11-12 16:54 plus his correction later that day (the
correction wins). These answers replace every "default" written earlier; plan tasks implement them.

| Q | topic | decision | consequence for the implementation |
|---|---|---|---|
| Q1 | Parakeet choice / `voice.input=vad` | **DECIDED A** (Birk 2026-11-12) + condition | Engine row "Recognition engine" under Local input, stored in `voice.local_engine`. Condition: stored values migrate so behaviour is identical — a Parakeet user stays on Parakeet with the same VAD/pause/max/mic/conversation settings. Test (plan Task 9): `voice.input=vad` → `voice.local_engine=parakeet` + `voice.input=local`, idempotent, every other fork key byte-identical before/after. |
| Q2 | upstream live-call button | **DECIDED A** | Kept as upstream ships it. Ledger L5. |
| Q3 | live call vs conversation mode | **DECIDED A** | Starting a live call ends our loop (`_voice.cancel()` in `prepare:`, `liveVoiceActive` gates). |
| Q4 | inline chat images | **DECIDED A** (final, after Birk's correction) | Take upstream's `ChatInlineImage`; delete `lib/fork/inline_media_thumbnail.dart`, `test/fork/inline_media_thumbnail_test.dart`, hooks; README line updated. R3 checks "inline + opens preview on tap". |
| Q5 | VAD no-speech | **DECIDED A** | Upstream notice chip on all routes; conversation still ends on silence. |
| Q6 | transient send failure | **DECIDED B** | Keep our automatic queue resume (`lib/fork/transient_send.dart` + 2 hooks). R5 pins it. |
| Q7 | offline indicator | **DECIDED A** | Keep NetworkGate (instant "Disconnected"). R6 pins it. |
| Q8 | unsent drafts/queues not imported | **DECIDED A** | One-time step before install. The coder card builds/signs only; the installer/device card pings Birk via ntfy (`robo-push.py --kind decision "Wing-Update bereit" "Bitte vorher offene Entwürfe abschicken, dann 'ok'."`), blocks `needs_input` until his "ok", then installs. |
| Q9 | fork voice keys out of config backup | **DECIDED A** | Accepted. Ledger L9. |
| Q10 | Actions cost | **DECIDED A** | Accepted; no repo-setting change by the implementer. |
| Q11 | screen-off conversation vs lifecycle guard | **DECIDED A** | If CI's `VoicePermissionLifecycleGuard` rejects the S6/VCH-B4 recipe, maintain a fork edit of upstream's guard (`tools/architecture/native_voice/VoicePermissionLifecycleGuard.kt` + its fixtures) that additionally allows the `keepsVoice` construction / `pauseOffline()` statement. No stop-and-ask any more. |

Original options (for the record): Q1 B = widen upstream's schema with a third select entry, C = drop the route;
Q2 B = hide the button unless the plugin status probe succeeds, C = remove live voice; Q3 B = refuse the call,
C = run both; Q4 B = keep our full-width thumbnail via a hook; Q5 B = keep the red error on the VAD route;
Q6 A = upstream pause until Resume, C = auto-resume every paused queue; Q7 B = upstream "Reconnecting";
Q8 B = one-shot importer of `composer_drafts_v1_<identity>`, C = A + delete the orphaned key; Q9 B = extend
upstream's backup schema; Q10 B = disable nightly in repo settings, C = run CI less often; Q11 B = drop TTS
continuation with the screen off.

## 14. Regression suite of Birk's daily flow (R1-R8)

Birk requires an automated regression suite of his **current** daily flow, green **before** the merge (on the
pre-merge base of `wt/t_d1d49ff1`) and green again **after** it, plus a device run. Files:
`test/regression/daily_flow_<item>_test.dart`, one file per item. Each file duplicates (copies verbatim, with
its fixtures) the existing test bodies named below, so the regression set stays intact even when the original
test files are rewritten during the merge. Rule after the merge: **only API adaptation** in these files
(constructors, renamed getters per Table C, fixture setup, the image loader parameter name); `expect(...)`
lines and `reason:` texts must not change. Exception: R3's image assertion is already written against
"inline + opens on tap", which holds for both widgets.

| ID | item (Birk) | regression file | copied from (origin/voice-offline) | asserted behaviour |
|---|---|---|---|---|
| R1 | conversation mode loop — mic reopens after a reply | `daily_flow_conversation_loop_test.dart` | `test/voice_offline/workspace_conversation_test.dart` "conversation mode sends a dictation that ended on its own" (l.15), "conversation reopens the microphone after the reply was spoken" (l.159); `test/voice_offline/workspace_vad_media_keys_test.dart` "vad conversation sends after the pause" (l.44) | a self-ended dictation is sent; the reply is spoken; a new recording starts after it |
| R2 | background/unsolicited replies don't break the mode (t_0179b15f; fix 2aea5f3f, merge ff3f0be7) | `daily_flow_unsolicited_reply_test.dart` | `workspace_conversation_test.dart` "an unsolicited reply while recording queues instead of cutting the recording off or ending the loop" (l.284), "an unsolicited reply while idle is spoken and the loop stays on" (l.332), "a reply that arrives while one plays queues instead of cutting it off" (l.189) | recording not cut; unsolicited reply queued then spoken; loop stays on |
| R3 | MEDIA lines not read aloud; images inline and open on tap | `daily_flow_media_test.dart` | `test/voice_processing_test.dart` "MEDIA reference lines are not read aloud" (l.318); `test/fork/inline_media_thumbnail_test.dart` "image deliverable renders an inline thumbnail and tap opens the zoom preview" (l.66) — rewritten neutrally: within `DeliverableAttachment` find exactly one `Image`, tap it, expect `ChatImagePreview` | `spokenReplyText` drops `MEDIA:` lines; an image deliverable shows an `Image` inline and a tap opens `ChatImagePreview` (pre-merge: our thumbnail; post-merge: upstream `ChatInlineImage`; loader parameter `onLoadRemoteImage:` → `loadAttachmentImage:` is the allowed setup change) |
| R4 | 10-min dictation (hard requirement) | `daily_flow_dictation_limit_test.dart` | `test/voice_processing_test.dart` "recording is bounded at the new maximum duration and native errors leave the draft untouched" (l.269: no stop at 121 s, stop at `maxRecordingSeconds`; only the duration part is copied); `test/voice_offline/workspace_vad_media_keys_test.dart` "recording status shows the default vad limit of 10 minutes" (l.233, `Recording · 0s / 600s`) | R4-dart: `VoiceInputController.maxRecordingSeconds == 600`; Android-recognizer route not stopped at 121 s, stopped at 600 s; Parakeet default limit row `Recording · 0s / 600s`; `find.textContaining('120s')` finds nothing. R4-native: static guard over `VoiceCapture.kt` (§6 S1) |
| R5 | automatic queue resume after a send error (Q6=B) | `daily_flow_queue_resume_test.dart` | `test/fork/offline_queue_test.dart` test 2 "a flaky send right after reconnect resolves on the next reconnect instead of sticking forever" (l.79) and `workspace_conversation_test.dart` "a flaky send right after reconnect does not end the conversation; the mic reopens once it drains" (l.92) | after a transient pre-submit failure and the next reconnect the queue is not paused and every queued prompt reaches `prompt.submit` exactly once, in order; the conversation mic reopens |
| R6 | offline indicator (instant offline, Q7=A) | `daily_flow_offline_indicator_test.dart` | `test/fork/network_gate_test.dart` (l.5) and `offline_queue_test.dart` test 1 (l.36) "a message queued during a real network outage shows offline at once and sends exactly once on reconnect" | right after `networkUnavailable()` the phase is `disconnected` (label "Disconnected"), no reconnect timer runs, and the queued text is sent exactly once after `networkRestored()` |
| R7 | read-aloud with the screen off | `daily_flow_screen_off_test.dart` | `test/voice_offline/workspace_screen_off_test.dart` "a vad conversation holds while it runs" (l.41), "reading continues and the microphone reopens" (l.65), "a reply that arrives with the screen off is spoken" (l.93) | background hold on; reading continues after `paused`; mic reopens. Native part (TTS not stopped on Activity pause, S6) is proven on the device only |
| R8 | Wing hint after an interrupted read-aloud (barge-in hint, 8d9e629a / c53b69aa) | `daily_flow_barge_in_hint_test.dart` | `test/voice_offline/workspace_barge_in_test.dart` "the message after a barge-in carries the interrupted-reply hint" (l.228); `test/voice_offline/barge_in_policy_test.dart` "the interrupted-reply hint follows the words after a blank line" (l.147); `test/voice_offline/barge_in_coordinator_test.dart` "words that cut off read-aloud carry the hint when sent or queued" (l.114) | the message sent after a barge-in ends with `\n\n[Hinweis von Wing: Die vorige Antwort wurde beim Vorlesen abgebrochen und nicht zu Ende gehört.]` |

Verification of "only setup changed": `git diff <pre-merge-regression-commit> HEAD -- test/regression` is
reviewed; additionally `git diff <pre> HEAD -- test/regression` filtered to lines containing `expect(` or
`reason:` must be empty (plan Task 15 has the command).

Device run (installer/device card, plan last section): the same 8 items on Birk's phone via `hadb`, with
logcat tags `WingBgVoice` ("hold on", "pause kept", "listening on"), `WingTtsLang` ("segment i/n … status=…"),
`WingMic`, `WingVad`, `dumpsys audio` `rec start/stop` lines, and uiautomator dumps.

## 15. User-visible differences ledger (merged app vs today's fork app)

Every user-visible difference NOT covered by R1-R8 and listed with its decision state. "Decided" = Birk's
answer in §13. Undecided entries go to Birk as ONE question before the merge into `voice-offline` (plan
Task 18); the architect's recommendation is given.

| L | difference | old (fork today) | new (merged) | state | recommendation |
|---|---|---|---|---|---|
| L1 | Parakeet choice location | 3rd entry "On this phone · Parakeet" in the Voice input select | Voice input "Local" + row "Recognition engine: Parakeet on this phone"; stored value migrated | decided Q1=A | — |
| L2 | empty dictation | red error "No speech detected. Try again." | notice chip "No speech detected" (all routes) | decided Q5=A | — |
| L3 | inline images | full message width, button row Download / Open preview, file card while loading | box max 420×320, download overlay icon, tap opens preview, spinner while loading, retry on error | decided Q4=A | — |
| L4 | offline indicator, queue resume | — | unchanged (R5, R6) | decided Q6=B, Q7=A | — |
| L5 | live-call button (waveform) beside the mic; needs the Wing plugin, else an error message | none | new button | decided Q2=A, Q3=A | — |
| L6 | unsent drafts/queues from before the update | kept on the phone | not imported (one-time) | decided Q8=A | — |
| L7 | mic button position | separate "Dictate message" icon in the composer toolbar row | mic inside the text field (`VoiceInputButton`); toolbar row replaced by upstream `ConversationComposer` (attach, model, primary action) | **undecided** | accept (upstream layout; same function, fewer rows) |
| L8 | recording chrome | inline text rows "Recording · 12s / 600s" with TextButtons Stop/Cancel | upstream `VoiceInputActivity`: same text with `/ 600s` (S9), icon buttons Stop/Cancel, error in a scroll box | **undecided** | accept |
| L9 | fork voice settings in the config backup | exported | not exported; old v1 backup files cannot be imported | decided Q9=A (backup v1 part: undecided, see L14) | — |
| L10 | Parakeet model removal confirmation | Material `AlertDialog` with "Cancel" | `StudioDialog` + `StudioFormActions` (forced by upstream CI rule) | **undecided** | accept (forced; look matches the rest of the app) |
| L11 | drafts and queue UI | one draft per chat, simple queue sheet | per-conversation drafts persisted in an outbox; queue sheet per message (edit / steer / delete / resume); "Resume" after a failed/cancelled turn's review pause | **undecided** | accept (upstream improvement; hands-free path keeps auto-resume, Q6) |
| L12 | app bar menu | menu button + items parent/goal/background/find/car/refresh | upstream menu (screen/outputs/find/git/parent/refresh) + "Car mode"; goal/background entries live where upstream put them | **undecided** | accept |
| L13 | reconnect after long outages | gave up after a capped number of attempts with a failure message (base code) | retries forever with capped delay | **undecided** | accept (improvement; NetworkGate still pauses retries while Android reports no network) |
| L14 | old configuration backup files | importable | v1 backups rejected (upstream 1.2.0) | **undecided** | accept; make a fresh backup after the update |
| L15 | session source label on the server for new chats | `desktop` (or `wing` if advertised) | `gui` (or `wing` if advertised) for gateway-created sessions; local record `desktop` | **undecided** (visible only in Hermes session lists) | accept |
| L16 | Android version floor | minSdk 24 | minSdk 29 (Android 10) | **undecided** (no effect on Birk's Xperia; ANNAHME Android ≥ 10) | accept |
| L17 | server requirement | works with the current server | upstream 1.4.0 "Before updating": needs the current Hermes gateway Webapp; a standalone dashboard is not sufficient | **undecided — must be checked before install** | installer card checks the connection right after install (R-device step 4); if the server is too old, report and stop — no server upgrade without Birk (AGENTS.md) |
| L18 | everything else upstream added in 806 commits (bots, recents, notification destinations, analytics, admin pages, …) | absent | present | improvements by definition; listed in the upstream CHANGELOG 1.2.0-1.4.1 | accept |

The plan's ledger task re-checks this table against the built branch (new differences found during
implementation are appended) before asking Birk.

## Appendix B — PRQ-B2 annotation snippet

Append inside step "Failure summary" after upstream's `for check in …; done`:

```
          # Surface failure detail as annotations too: the step summary and logs are
          # not fetchable from the egress-blocked vServer, check-run annotations are.
          if [ "${{ steps.analyze.outcome }}" != "success" ]; then
            grep -E "(info|warning|error) •" analyze_output.txt | head -10 > /tmp/analyze_hits.txt || true
            if [ -s /tmp/analyze_hits.txt ]; then
              while IFS= read -r line; do printf '::error::ANALYZE: %s\n' "$line"; done < /tmp/analyze_hits.txt
            else
              tail -n 20 analyze_output.txt | while IFS= read -r line; do printf '::error::ANALYZE-TAIL: %s\n' "$line"; done
            fi
          fi
          if [ "${{ steps.test.outcome }}" != "success" ]; then
            evidence="$(ls -dt /tmp/wing-host-tests-* 2>/dev/null | head -1)"
            if [ -n "$evidence" ] && [ -f "$evidence/tests.jsonl" ]; then
              grep -h '"type":"error"' "$evidence/tests.jsonl" | head -8 | cut -c1-900 | while IFS= read -r line; do printf '::error::TEST: %s\n' "$line"; done
              tail -n 20 "$evidence/tests.stderr" | while IFS= read -r line; do printf '::error::TEST-STDERR: %s\n' "$line"; done
            fi
          fi
          if [ "${{ steps.native_test.outcome }}" != "success" ] && [ -f native_test_output.txt ]; then
            tail -n 25 native_test_output.txt | while IFS= read -r line; do printf '::error::NATIVE-TEST: %s\n' "$line"; done
          fi
          if [ "${{ steps.android_build.outcome }}" != "success" ] && [ -f android_build_output.txt ]; then
            tail -n 25 android_build_output.txt | while IFS= read -r line; do printf '::error::ANDROID-BUILD: %s\n' "$line"; done
          fi
```

Step ids (`analyze`, `test`, `native_test`, `android_build`) must match upstream's `id:` fields; verify with
`git grep -n "id: " -- .github/workflows/pr-quality.yml` before pasting.

## Appendix A — Table A, one row per deleted path

"fork net diff 0" = `git diff --numstat 151ee281 origin/voice-offline -- <path>` is empty. "no fork-owned
reference" = no import or symbol use in `lib/voice_offline`, `lib/car_mode`, `lib/fork`, their tests, or the
fork Kotlin packages (§2).

| # | path | decision | reason | upstream replacement |
|---|---|---|---|---|
| A1 | `.github/actions/setup-flutter/README.md` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A2 | `CONTEXT.md` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A3 | `android/app/src/main/res/drawable-v21/launch_background.xml` | take upstream deletion | retired resource; `tools/architecture/rules/native_retired_resources.py` requires it to stay absent (b491c30e); fork net diff 0; no fork-owned reference | `@mipmap/ic_launcher` (adaptive icon) |
| A4 | `android/app/src/main/res/layout/notification_approval_grid.xml` | take upstream deletion | removed by the notification destination fix (0409d51b); fork net diff 0; no fork-owned reference | upstream notification rendering in Kotlin |
| A5 | `android/app/src/main/res/layout/notification_approval_row.xml` | take upstream deletion | removed by the notification destination fix (0409d51b); fork net diff 0; no fork-owned reference | upstream notification rendering in Kotlin |
| A6 | `android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml` | take upstream deletion | retired resource; `tools/architecture/rules/native_retired_resources.py` requires it to stay absent (b491c30e); fork net diff 0; no fork-owned reference | `@mipmap/ic_launcher` (adaptive icon) |
| A7 | `android/app/src/main/res/mipmap-anydpi-v33/ic_launcher_round.xml` | take upstream deletion | retired resource; `tools/architecture/rules/native_retired_resources.py` requires it to stay absent (b491c30e); fork net diff 0; no fork-owned reference | `@mipmap/ic_launcher` (adaptive icon) |
| A8 | `android/app/src/main/res/values-night/notification_colors.xml` | take upstream deletion | removed by the notification destination fix (0409d51b); fork net diff 0; no fork-owned reference | upstream notification rendering in Kotlin |
| A9 | `android/app/src/main/res/values/notification_colors.xml` | take upstream deletion | removed by the notification destination fix (0409d51b); fork net diff 0; no fork-owned reference | upstream notification rendering in Kotlin |
| A10 | `assets/pricing/openai.json` | take upstream deletion | replaced by backend catalog pricing (28659bc5); fork net diff 0; no fork-owned reference | backend model catalog pricing (28659bc5) |
| A11 | `docs/ANDROID_RELEASE_PLAN.md` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A12 | `docs/BUG_TRACKER.md` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A13 | `docs/CODE_QUALITY_CHECKLIST.md` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A14 | `docs/DEFAULT_PROFILE.md` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A15 | `docs/DESIGN_SYSTEM.md` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | private `internal/AGENTS.md#ui-design`; public stand-ins `docs/features/ui-foundations.md`, `docs/FEATURE_MAP.md` |
| A16 | `docs/LOCAL_BUILD_SETUP.md` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A17 | `docs/PERFORMANCE.md` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A18 | `docs/PLAY_DATA_SAFETY.md` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A19 | `docs/TESTING.md` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A20 | `docs/TRANSCRIPT_DISPLAY_TYPES.md` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A21 | `docs/UPSTREAM_HERMES_BUGS.md` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A22 | `docs/design/2026-09-14-administration-handoff.md` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | private Wing workspace; no public successor |
| A23 | `docs/design/2026-09-14-app-icon.md` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A24 | `docs/design/2026-09-15-wing-identity.md` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A25 | `docs/design/images/connection-notification-proof.png` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A26 | `docs/design/images/icon-production-proof.png` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A27 | `docs/design/images/notification-identity-board.svg` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A28 | `docs/design/images/wing-identity-board.png` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A29 | `docs/design/images/wing-readme-hero-slim-w.png` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A30 | `docs/design/images/wing-welcome-light.png` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A31 | `lib/core/models/dashboard_oauth_session.dart` | take upstream deletion | removed by the feature-owner refactor (b491c30e); fork net diff 0; no fork-owned reference | moved to `lib/core/services/dashboard_oauth_session.dart` (relative imports of upstream callers resolve) |
| A32 | `lib/core/models/gateway_turn_contract.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A33 | `lib/core/models/hermes_project.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A34 | `lib/core/models/project_sessions_tree.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A35 | `lib/core/models/projects_tree_overview.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A36 | `lib/core/models/session.dart` | take upstream deletion | removed by the feature-owner refactor (b491c30e); fork net diff 0; no fork-owned reference | folded into the feature owners of b491c30e; not needed by the fork |
| A37 | `lib/core/models/session_search_hit.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A38 | `lib/core/screens/backend_updates_screen.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A39 | `lib/core/services/ai_search_query_rewriter.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A40 | `lib/core/services/capability_registry.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A41 | `lib/core/services/chat_space_store.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A42 | `lib/core/services/desktop_gateway_client.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A43 | `lib/core/services/gateway_turn_application_controller.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A44 | `lib/core/services/gateway_turn_coordinator.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A45 | `lib/core/services/gateway_turn_journal.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A46 | `lib/core/services/gateway_turn_recovery.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A47 | `lib/core/services/gateway_turn_ui_projection.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A48 | `lib/core/services/profile_color_store.dart` | take upstream deletion | removed by the feature-owner refactor (b491c30e); fork net diff 0; no fork-owned reference | profile colours in `AppPreferences.profileColorsFor` (`lib/core/services/app_preferences.dart`), `profile_colors_session.dart` |
| A49 | `lib/core/services/profile_selection_store.dart` | take upstream deletion | removed by the feature-owner refactor (b491c30e); fork net diff 0; no fork-owned reference | folded into the feature owners of b491c30e (ANNAHME: `AppPreferences`; not needed by the fork) |
| A50 | `lib/core/services/projects_gateway_client.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A51 | `lib/core/services/projects_repository.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A52 | `lib/core/services/quick_chat_store.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A53 | `lib/core/services/session_search_client.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A54 | `lib/core/services/session_search_preferences.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A55 | `lib/core/services/shared_attachment_preparer.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A56 | `lib/core/services/text_size_preference.dart` | take upstream deletion | removed by the feature-owner refactor (b491c30e); fork net diff 0; no fork-owned reference | `AppTextSizePreference` in `lib/core/models/app_preferences.dart` + `AppPreferences.setTextSize` |
| A57 | `lib/core/utils/activity_feed.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A58 | `lib/core/utils/chat_display_items.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A59 | `lib/core/utils/chat_history_scroll.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A60 | `lib/core/utils/home_digest.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A61 | `lib/core/utils/home_turn_signals.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A62 | `lib/core/utils/new_chat_options.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A63 | `lib/core/utils/project_session_filter.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A64 | `lib/core/utils/responsive.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A65 | `lib/core/utils/turn_recovery_fallback.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A66 | `lib/core/widgets/activity_shimmer.dart` | take upstream deletion | replaced by the feather pulse (050ef331); fork net diff 0; no fork-owned reference | Wing feather pulse (050ef331) |
| A67 | `lib/core/widgets/profile_usage_panel.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | chat runtime + composer outbox (`lib/core/models/chat_runtime.dart`, `lib/core/services/composer_session.dart`, `composer_draft_store.dart`) for the gateway-turn/recovery family; otherwise the feature was removed |
| A68 | `scripts/test_native_monitoring_count.py` | take upstream deletion | removed in the test-suite review (e2919af4); fork net diff 0; no fork-owned reference | none |
| A69 | `test/activity_feed_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A70 | `test/activity_shimmer_test.dart` | take upstream deletion | replaced by the feather pulse (050ef331); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A71 | `test/ai_search_query_rewriter_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A72 | `test/api_client_timeout_test.dart` | take upstream deletion | removed by the feature-owner refactor (b491c30e); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A73 | `test/backend_updates_screen_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A74 | `test/capability_registry_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A75 | `test/chat_display_items_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A76 | `test/chat_space_store_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A77 | `test/document_intake_profile_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A78 | `test/gateway_turn_application_controller_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A79 | `test/gateway_turn_coordinator_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A80 | `test/gateway_turn_journal_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A81 | `test/gateway_turn_recovery_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A82 | `test/gateway_turn_ui_projection_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A83 | `test/home_digest_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A84 | `test/home_turn_signals_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A85 | `test/new_chat_options_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A86 | `test/profile_selection_store_test.dart` | take upstream deletion | removed by the feature-owner refactor (b491c30e); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A87 | `test/profile_usage_panel_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A88 | `test/project_session_filter_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A89 | `test/project_sessions_repository_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A90 | `test/project_sessions_tree_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A91 | `test/projects_gateway_client_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A92 | `test/projects_repository_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A93 | `test/projects_tree_overview_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A94 | `test/quick_chat_store_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A95 | `test/release_identity_test.dart` | take upstream deletion | removed in the test-suite review (e2919af4); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A96 | `test/session_model_test.dart` | take upstream deletion | removed by the feature-owner refactor (b491c30e); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A97 | `test/session_search_client_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A98 | `test/session_search_preferences_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A99 | `test/shared_attachment_preparer_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A100 | `test/space_migration_write_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A101 | `test/support/inert_turn_application_session.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A102 | `test/support/memory_turn_journal_store.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A103 | `test/turn_recovery_fallback_test.dart` | take upstream deletion | removed in the release hardening / gateway rewrite (27b5a346); fork net diff 0; no fork-owned reference | deleted together with its subject (or subject rewritten upstream); no fork test imports it |
| A104 | `tools/fake_gateway/README.md` | take upstream deletion | engineering record moved to the private Wing workspace (6ae1b6ad); fork net diff 0; no fork-owned reference | none in public git |
| A105 | `tools/fake_gateway/turn_recovery_contract.py` | take upstream deletion | removed by the feature-owner refactor (b491c30e); fork net diff 0; no fork-owned reference | feature owners of b491c30e |

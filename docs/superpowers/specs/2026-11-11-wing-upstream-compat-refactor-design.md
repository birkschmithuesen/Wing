# Wing fork: refactor for maximum upstream compatibility — design

Card `t_ba3601fa` (board `wing`, size L). Branch `voice-offline`. Follow-up card: upstream merge `t_d1d49ff1`
(runs **after** this refactor; this card does not merge upstream).

## 1. Goal and non-goals

**Goal.** Every fork change that today sits inside an upstream-owned file moves into a fork-owned file
(class, mixin, extension, widget, Kotlin class, Gradle script, doc). The upstream file keeps only a thin
hook: an import, a field, a call, a delegating `when` branch. Remove duplicates and proven dead code on the
way. Result: the later upstream merge (`t_d1d49ff1`) touches as few upstream lines as possible, and each
remaining conflict is a small, obvious hook.

**Non-goals.**
- No new behaviour, no UI change, no storage-key change, no settings migration.
- No upstream merge, no adoption of upstream features (even where upstream now has an equivalent; see §6).
- No backend change (AGENTS.md: Hermes stays stock).

**Rule source.** Strategy doc `~/hermes-shared/hermes-entities/tools/technik/wing-fork-upstream-strategie.md`,
rule 1 "Eigenes in eigene Dateien". The final task updates it with the new file layout and the numbers.

## 2. Measured baseline (2026-11-11)

Refs: `voice-offline` `55db5f1f`, `upstream/main` `5020e141` (2026-11-12 03:58 +0800), merge-base
`151ee281`. Measured with the probe script from §5 (identical to the architect's numbers).

- **(a) Lines in upstream files:** 38 modified files (`--diff-filter=M`), **+4351 / −157**. 37 of 38 were
  also changed upstream (`android_voice.dart` is the only one upstream left alone).
- **(b) Probe merge** `upstream/main` → `voice-offline`: **27 conflict files, 92 conflict blocks**, of which
  2 are modify/delete (`docs/TESTING.md`, `lib/core/services/voice_preferences.dart`, both deleted upstream).
- Split of (a): lib 1622, native/build 198, tests 2454, repo meta (CI, docs, AGENTS, README, .gitignore) 77.

## 3. What upstream did meanwhile (affects hook placement)

Upstream commit `b491c30e` "Refactor Wing into explicit feature owners and guard architecture boundaries"
and its successors rewrote almost every file we touch. The hooks below are placed in **today's fork files**
(the refactor runs before the merge), but each hook is chosen so it maps onto a named upstream seam. The
mapping is recorded per hook in §4 so `t_d1d49ff1` can re-attach it quickly.

Facts that shape the design:
- `voice_preferences.dart` is **deleted** upstream. Preferences moved to `models/app_preferences.dart`
  (`AppVoiceProcessing {local, hermes}`), `services/app_preferences.dart`, sealed
  `models/voice_processing_settings.dart` and `services/voice_preferences_session.dart`. The upstream
  parser rejects `voice.input=vad`; sealed classes cannot get a third branch from another library.
- `VoiceInputController` upstream: `start(settings: VoiceInputSettings, …)`, `dictate<T>(…)`.
  `VoiceOutputController` upstream: `speak` delegates to `_play`, returns `Future<void>`.
- Workspace screen upstream: `_requestDictation` / `_requestReadAloud` replace `_dictate` / `_readAloud`;
  `ProfileChat` fields moved to `chat.composer.*` / `chat.runtime.*`.
- Controller queue moved into `ComposerSession` (`composer_session.dart`); our offline-queue hunks must be
  re-implemented there at merge time whatever we do now.
- `VoiceDevice` (`android_voice.dart`) is unchanged upstream: `stop(String id)` without a timeout.
- Native: `VoiceChannel/VoiceCapture/VoicePlayback.kt` rewritten (`VoiceOperations`, `VoiceFileWork`).
  Upstream guards (`tools/architecture/native_voice/`) require `VoiceChannel.pause()` to contain only
  `capture.pause()` and `playback.stop()`, and forbid `java.io.File` in those three classes.
- Upstream has its own inline image rendering (`ChatInlineImage`, `DeliverableAttachment(loadImage:)`),
  a `LiveVoiceService.kt` microphone foreground service, and already declares `BLUETOOTH_CONNECT`,
  `MODIFY_AUDIO_SETTINGS` and `FOREGROUND_SERVICE_MICROPHONE`.
- Upstream census/role files (`tools/architecture/roots.json`, `roles.json`) list every tracked file. Each
  fork-owned file will need an entry after the merge. That is merge-card work; this card only keeps the
  number of new own files reasonable (one file per responsibility, no splinters).

## 4. Design per file

Approach chosen: **own units with narrow interfaces plus thin hooks** (rejected alternatives in §7).
Own code lives in the existing fork directories: `lib/voice_offline/` (voice), `lib/car_mode/` (car mode),
`lib/fork/` (new, non-voice fork code), `android/.../wing/voiceoffline/` (native voice),
`test/voice_offline/`, `test/car_mode/`, `test/fork/` (new), `test/support/*_fixture.dart`.

Estimated residual lines are targets, not guarantees. The implementer measures the actual numbers.

### 4.1 Dart lib

| Upstream file | Now | Target | Receives the logic | Hook that stays | Upstream seam at merge |
|---|---|---|---|---|---|
| `lib/core/services/android_voice.dart` | +211/−3 | ~+8/−2 | `lib/voice_offline/vad_voice_device.dart`: `abstract interface class VadVoiceDevice` (startVad, finishVad, model status/install/cancel/remove, prepare/release, deleteVadDebugRecordings, setMediaKeys, keepScreenOn, openMicLink, closeMicLink), `mixin AndroidVadVoice` (impls on `AndroidVoice.channel`), types `VadCaptureOptions`, `VadModelState`, `VadModelStatus`, `VoiceSwitchHolders`, `VadVoiceDevice.of(VoiceDevice)` | import; `class AndroidVoice with AndroidVadVoice implements VoiceDevice, VadVoiceDevice`; `stop(id, {Duration timeout = const Duration(seconds: 5)})` (default = native default, so callers that pass nothing behave as before); `'segments': speechSegmentsPayload(text)` in `speak` | unchanged upstream file; `stop` default keeps upstream's call shape `stop(id)` |
| `lib/core/services/voice_preferences.dart` (deleted upstream) | +187/−16 | ~+25/−3 | `lib/voice_offline/voice_offline_prefs.dart`: `class VoiceOfflinePrefs` with all fork fields (VAD pause/minSpeech/preRoll/max/noSpeech/cues/debug/source, `autoSpeak`, `conversation`, `listenTurn`, `listenMinSpeech`, `bargeInPlayback`, `micRoute`), `factory read(SharedPreferences)`, `tryRead`, `static keys`, `static accepts`; enums `VadAudioSource`, `VoiceMicRoute` | `VoiceInputRoute` enum (keeps `vad`; it is the type of the existing `input` field), `keys` spreads `...VoiceOfflinePrefs.keys`, `accepts` falls through to `VoiceOfflinePrefs.accepts`, `read()` parses `vad` | file is deleted upstream: at merge accept the deletion; `VoiceOfflinePrefs` reads `SharedPreferences` directly with unchanged keys, so it re-attaches with no upstream hunk except the route-key question (§6) |
| `lib/core/controllers/voice_input_controller.dart` | +178/−9 | ~+35/−4 | `lib/voice_offline/vad_input_round.dart`: `class VadInputRound` (endpointer, car SCO hold via `CarMicSession`, mic fallback hint, `_finishVad`), top-level `transcriptionDeadlineFor`, `micFallbackMessage`; `finishedOnItsOwn` / `stopHandsFree` state | ctor field `VadInputRound? vadRound`; `start` branch to `vadRound.begin`; one line in the event handler; one `forceEnd` line in `stop`; `vadRound?.clear()` in `_clear`; `maxRecordingSeconds` constant (behaviour: 600 s ceiling) | upstream `start(settings:)` / `dictate<T>` admission: the vad branch sits before the sealed-settings switch |
| `lib/core/controllers/voice_output_controller.dart` | +8/−3 | +8/−3 (unchanged) | — | `speak` returns `Future<bool>` "played to its end" | upstream `_play`: return the bool from `_play` |
| `lib/core/widgets/voice_preferences_card.dart` | +110/−8 | ~+20/−4 | `lib/voice_offline/voice_offline_settings.dart`: `class VoiceOfflineSettings extends StatefulWidget` (mic route select + hint, `VadSettingsSection`, spoken-replies and conversation switches, `BargeInSettings`, model prepare/release on route change via `onRouteChanged`) | import; `vad` option row in the input select (built by an own helper `vadInputChoice()`), `VoiceOfflineSettings(...)` placed where the blocks render today, route-change callback | upstream session-driven card: the `vad` choice cannot be hooked into `_select<AppVoiceProcessing>`; open item §6 |
| `lib/core/screens/profile_workspace_screen.dart` | +635/−34 | ~+60/−10 | `lib/voice_offline/workspace_voice_driver.dart`: `class WorkspaceVoiceDriver extends ChangeNotifier` owning `CarMicSession`, `BackgroundVoice`, `BargeInCoordinator`, `HeadphoneRoute`, `CarModeSession`, `SpeechQueue`, conversation/awaiting-reply state, media-key subscription, `VoiceSwitchHolders`; `abstract interface class WorkspaceVoiceHost` implemented by the screen state; `lib/voice_offline/workspace_voice_options.dart`: `class VoiceOfflineDeps({BackgroundVoiceHost? background, HeadphoneRouteHost? headphones})` | imports; one ctor field `voiceOffline`; `late final _voice = WorkspaceVoiceDriver(host: this, …)`; `attach`/`detach` in `initState`/`dispose`; `lifecycle(state)` and keep-voice guard; `routeChanged`; focus getter `|| _voice.carActive`; dictation completion `_voice.onDictated(chat)`; activity row `_voice.activity(context)`; `_voice.cancel()`; car menu entry; `conversation:` flag on composer action; `onLoadRemoteImage:` at 3 sites (thumbnails, §4.1 last rows) | `_requestDictation` / `_requestReadAloud` / `_voiceActivity` / `didChangeAppLifecycleState`; `ProfileChat` field access goes through an own `extension ChatVoiceView on ProfileChat` so only that extension changes at merge |
| `lib/core/services/profile_workspace_controller.dart` | +102/−9 | ~+65/−9 | `lib/voice_offline/completed_replies.dart`: `class CompletedReplies` (stream, `offer`, `close`); `lib/fork/network_gate.dart`: `class NetworkGate` (lost/restored state, used by `ServerConnectionStatus`); pure helper `queuedHeadDelivered(...)` into `lib/fork/offline_queue.dart` | 1 field + 1 `offer` + 1 `close` + getter; `networkUnavailable`/`networkRestored` delegates; `_scheduleReconnect` early return; offline-queue gates in `_sendPrompt` / `_drainQueuedPrompts` and the reconnect head check **stay** (upstream moved the queue to `ComposerSession`; they must be re-implemented there at merge, extracting them now does not reduce that work); `source:` line | `networkUnavailable` (~L2722), `_scheduleReconnect` (~L10319), `ComposerSession.drain` |
| `lib/core/services/server_connection_status.dart` | +26 | ~+6 | `NetworkGate` (above) | field, one `phase` line, change wiring | rewritten `phase`; note conflicting upstream semantics (§6) |
| `lib/core/services/profile_gateway.dart` | +13/−2 | ~+4/−2 | `lib/core/services/wing_session_source.dart` (existing): `extension WingGatewaySource on ProfileGateway` with an `Expando<bool>` for the advertised flag, `noteReady(ready)`, `sourceFor(fallback)` | import; `gateway.noteReady(ready)`; `'source': gateway.sourceFor(...)` in create and resume | rewritten `createSession` / `waitForGatewayReady` |
| `lib/core/services/profile_workspace_registry.dart` | +1 | +1 | — | `owner.networkRestored()` | `recoverConnections` |
| `lib/core/widgets/deliverable_attachment.dart` | +129/−22 | ~+10/−3 | `lib/fork/inline_media_thumbnail.dart`: `class InlineMediaThumbnail` (extension check, static cache, `FutureBuilder`, min height, tap to preview) | `onLoadImage` field + one branch `if (onLoadImage != null && InlineMediaThumbnail.handles(path)) return InlineMediaThumbnail(...)` | superseded upstream (`ChatInlineImage`); drop decision §6 |
| `lib/core/widgets/markdown_message_content.dart` | +18/−2 | +18/−2 | — | `onLoadRemoteImage` plumbing (cannot be moved; pure parameter passing) | upstream `loadImage` parameter |
| `lib/core/widgets/profile_message.dart` | +4 | +4 | — | plumbing | same |

### 4.2 Native and build

| Upstream file | Now | Target | Receives the logic | Hook that stays |
|---|---|---|---|---|
| `android/app/build.gradle.kts` | +71/−2 | ~+2/0 | `android/app/voice-offline.gradle.kts` (script plugin, same pattern as upstream's `ime-cache-fix.gradle.kts`): `FetchVerifiedFile` task, sherpa AAR + Silero fetch tasks, `preBuild` dependency, `voiceVariant` label / `applicationId` override via `androidComponents.onVariants`, release `proguardFiles`, VAD asset dir, `implementation` deps (via `extensions.configure` / `dependencies.add`, no typed accessors) | `apply(from = file("voice-offline.gradle.kts"))` + comment |
| `VoiceChannel.kt` | +86/−9 | ~+12/−2 | `voiceoffline/VoiceOfflineHandler.kt`: `class VoiceOfflineHandler(activity, messenger, emit)` with `handle(call, result): Boolean`, `permissionResult(code, grants): Boolean`, `pause()`, `resume()`, `close()`, `keepsVoice()`; owns models, speech, debug store, mic route, VAD, media keys, background, headphone route | 1 field; `else -> if (!offline.handle(call, result)) result.notImplemented()`; 1 line in `permissionResult`; `resume()`/`close()` one-liners; `keepPlayback` condition in `start`. `pause()` keeps the guard-compatible body shape (`capture.pause(); playback.stop()` plus one `offline.pause()` call placed so the merge can move it to `MainActivity.onPause`; see §6) |
| `VoiceCapture.kt` | +27/−9 | ~+8/−5 | `voiceoffline/RecognizerSelection.kt`: `onDeviceRecognition(activity)`, `recognitionAvailable(activity)`, `createRecognizer(activity)`, `cleanTranscript(raw)` | constants for the 600 s ceiling, `recognizer()` call, `cleanTranscript` call + partial skip, `timeoutMs` param |
| `VoicePlayback.kt` | +6/−8 | unchanged | already delegated to `voiceoffline/LanguageSpeech.kt` | `segments` param, `LanguageSpeech.enqueue`, voice-null relaxation |
| `AndroidManifest.xml` | +7 | +7 | — (a `<service>` cannot move without a library module) | 3 permissions + `BackgroundVoiceService` element |
| `MainActivity.kt` | +1 | +1 | — | `voiceChannel?.resume()` |

### 4.3 Tests

Our tests leave upstream test files. Shared helpers move into own fixtures.

| Upstream file | Now | Target | Destination |
|---|---|---|---|
| `test/voice_workspace_test.dart` | +1478 | 0 | `test/voice_offline/workspace_conversation_test.dart`, `workspace_listen_turn_test.dart`, `workspace_barge_in_test.dart`, `workspace_vad_media_keys_test.dart`, `workspace_screen_off_test.dart`, `test/car_mode/car_mode_workspace_test.dart`; shared harness `test/support/voice_workspace_fixture.dart` (`VoiceWorkspaceHarness`: controller construction, device, background, route, gateway-event injection, `show(tester, destination)`, `sayFinal`, `completeReply`, `settle`, …) |
| `test/voice_preferences_test.dart` | +467/−4 | ~+4/−4 | `test/voice_offline/voice_offline_prefs_test.dart` (read/accepts/keys cases), `test/voice_offline/voice_offline_settings_test.dart` (widget, barge-in rows, renders); the private `show/screenshot/capture/frame` helpers and the font `setUpAll` are copied into `test/support/voice_settings_fixture.dart`; the `headphone_route` channel mock moves with the tests. The 4 `VoiceProcessing`→`VoiceInputRoute` swaps stay (type of the existing `input` field) |
| `test/support/voice_fixture.dart` | +107/−1 | ~+3/−1 | `test/support/vad_voice_fixture.dart`: `mixin VadVoiceFixture implements VadVoiceDevice` with all VAD/media-key/mic-link state and methods; hook: `class VoiceDeviceFixture with VadVoiceFixture implements VoiceDevice, VadVoiceDevice` + import; `stop` keeps the optional `timeout` param |
| `test/voice_processing_test.dart` | +45/−9 | ~+10/−9 | deadline test → `test/voice_offline/transcription_deadline_test.dart`; enum swaps and the 600 s maximum-duration test stay (they change an existing assertion) |
| `test/deliverable_attachment_test.dart` | +148 | 0 | `test/fork/inline_media_thumbnail_test.dart` with its own `message()` helper |
| `test/profile_workspace_controller_test.dart` | +147 | ~+5 | 3 new tests → `test/fork/offline_queue_test.dart`; `Host.promptSubmitFailures` hook (3 lines) and `networkRestored()` in the resume test stay |
| `test/server_connection_status_test.dart` | +24 | 0 | `test/fork/network_gate_test.dart` |
| `test/profile_workspace_registry_test.dart` | +11 | 0 | `test/fork/registry_network_test.dart` (copies the `registry` / `identityTestConnection()` setup) |
| `test/support/profile_browser_fixture.dart` | +8 | +8 | stays (closure inside `gateway()`) |
| `test/session_visibility_test.dart` | +4/−2 | +4/−2 | stays (existing assertions count the `wing` row) |
| `test/profile_composer_actions_test.dart` | −1 | −1 | stays (field moved to `ProfileBrowserFixture`) |
| `integration_test/voice_native_test.dart` | +8/−2 | 0 | revert: `stop` has a 5 s default again |
| `integration_test/voice_permission_native_test.dart` | +7/−1 | 0 | revert, same |

No test is dropped. The move is verbatim apart from helper names; the total test count must stay the same
(checked in the plan from the suite output).

### 4.4 Repo meta and docs

| File | Now | Target | Action |
|---|---|---|---|
| `docs/TESTING.md` (deleted upstream) | +5 | 0 | paragraph → `docs/VAD_INPUT.md`; removes a modify/delete conflict |
| `docs/VOICE.md` | +19 | ~+1 | Parakeet/VAD paragraph and car-mode link → `docs/VAD_INPUT.md` / `docs/CAR_MODE.md`; one link line stays |
| `.gitignore` | +1 | 0 | `/android/app/libs/` → new `android/app/.gitignore` (`/libs/`) |
| `.github/workflows/pr-quality.yml` | +20/−1 | +20/−1 | stays: `ci-suite.sh` dispatches this workflow and `workflow_dispatch` only works for workflows on the fork's default branch, so moving the steps to an own workflow changes the factory; kept, open (§6) |
| `AGENTS.md` | +12 | +12 | stays: agent tools load `AGENTS.md` itself, a linked file would not be read |
| `README.md` | +20 | +20 | stays: the fork block is the fork's GitHub landing text (AGENTS.md rule) |

### 4.5 Estimated totals

| Metric | Before | Target |
|---|---|---|
| Modified upstream files | 38 | ≤ 31 |
| Our lines in upstream files (+) | 4351 | ≤ 450 |
| of which lib / native / tests / meta | 1622 / 198 / 2454 / 77 | ~260 / ~40 / ~40 / ~55 |
| Probe-merge conflict files | 27 | lower; modify/delete 2 → 1 (`voice_preferences.dart` stays a deletion conflict with ~25 hook lines) |
| Probe-merge conflict blocks | 92 | lower |

The conflict numbers cannot be predicted precisely: many hooks sit in regions upstream rewrote, so a
one-line hook still makes one conflict block. Acceptance is "measured, reported, not higher than before";
the line metric is the primary target.

## 5. Measurement

New script `tools/factory/upstream-diff-metrics.sh [branch=HEAD] [upstream=upstream/main]`, read-only for
the checkout: prints (a) `git diff --numstat --diff-filter=M <merge-base> <branch>` per file with a `U` mark
where upstream changed the file too, and totals; (b) a probe merge in a throwaway detached worktree under
`.worktrees/upstream-probe-<pid>` (removed on exit), listing each unmerged path with its git status code
(`UU`, `UD`, …) and its `^<<<<<<< ` count, plus totals. The before numbers in §2 were produced by exactly
this script.

## 6. Removal list and open items

**Removed (with evidence).**
| Item | Evidence |
|---|---|
| Repeated `_conversation = null` assignments (20 in the screen, measured 2026-11-11) | each becomes a call to one `WorkspaceVoiceDriver.endLoop()` at the same position; the method does exactly the assignment, so no behaviour difference. Sites that also do other work keep that work |
| 3 copies of `VoicePreferences.read` inside `try { … } on FormatException` (screen L556, L619, L640) | collapse into `VoiceOfflinePrefs.tryRead()` returning `null` on `FormatException`; call sites without a catch keep throwing semantics via `read()` |
| Stale comment in `_sendConversationTurn` referring to a `decideDelivery` hook | `grep -rn decideDelivery lib` finds nothing; the hook never landed. Comment only |
| `test/` path argument edits in the two integration tests | made unnecessary by the `stop` default |

**Kept, open (not proven unused, or a product decision).**
| Item | Why kept |
|---|---|
| VAD debug recordings (`VoiceDebugStore.kt`, `voice.vad_debug`, `deleteVadDebugRecordings`) | user-reachable switch in VAD settings |
| `bargeInPlaybackAvailable = true` (`barge_in_policy.dart`) | constant flag, read in 3 places; removing changes code paths only formally, but it is the switch for the echo gate (Task 7 of the barge-in plan) |
| `reason` argument of `openMicLink`/`closeMicLink` (ignored in Kotlin) | harmless, part of the channel contract |
| Temporary annotation block in `pr-quality.yml` | needed while the step summary is unreachable through the vServer egress firewall |
| static `_imageCache` without eviction | behaviour; moves unchanged |
| Our inline MEDIA thumbnail vs upstream `ChatInlineImage` | upstream equivalent exists (boxed 420×320 vs our full-width). Adopting upstream is a visible change: Birk decides in `t_d1d49ff1`. After this card, dropping ours costs one own file + ~30 hook lines |
| 3 manifest permissions also declared upstream | needed until the merge brings upstream's declarations; drop in `t_d1d49ff1` |
| `voice.input=vad` storage value | upstream's `AppPreferenceField` rejects it; needs an own key + migration. That is a storage change: decision in `t_d1d49ff1` |
| `BackgroundVoiceService` vs upstream `LiveVoiceService` | overlap to assess in the merge card |
| `NetworkGate` "authoritative network loss" vs upstream "device-network event is a reason to retry, never proof" | semantics differ; assess in the merge card |
| Upstream native guards (`VoiceChannel.pause()` body, no `java.io.File`) | our `VoiceOfflineHandler.pause()` call and the `File` usage must move at merge; this card only keeps `pause()` to one extra call |
| `roots.json` / `roles.json` entries for own files | merge card |

## 7. Approaches considered

1. **Own units + thin hooks, in today's fork files (chosen).** Shrinks our upstream footprint now; each
   hook is documented against the upstream seam it maps to. Risk: the screen driver is a large extraction;
   it is split into four tasks with the suite after each pair.
2. **Merge upstream first, then extract.** Hooks would land directly on upstream's new seams. Rejected: Birk
   fixed the order (this card first, then `t_d1d49ff1`), and doing both at once mixes refactor and
   behaviour adaptation in one unreviewable change.
3. **Parallel own controllers/screens** (e.g. a `VadVoiceInputController` selected by the screen, an own
   workspace screen subclass). Fewer hooks in the controller, but duplicates upstream logic and turns every
   upstream fix to those classes into a manual port. Rejected.

## 8. Verification

- Suite: `bash tools/factory/ci-suite.sh` (GitHub Actions: `flutter analyze` + `flutter test`), at the
  checkpoints named in the plan, not after every task. Last line must read `conclusion=success`.
- Kotlin and Gradle: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false` after native tasks.
- Test count: the number of passing tests in the final suite run is not lower than the baseline run.
- Metrics: `bash tools/factory/upstream-diff-metrics.sh` before and after, numbers into the closing comment.
- Phone self-test (Birk, manual, not doable by the implementer): dictation ends by itself, long dictation
  arrives complete, conversation mode runs several rounds.
- Other wing cards may merge into `voice-offline` during the work (e.g. `wt/t_256dcf56`). Before the final
  measurement merge the latest `voice-offline` and re-run the suite and the metrics.

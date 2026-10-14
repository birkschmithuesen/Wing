# Wing car mode (one big talk button) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fullscreen car mode for an open chat. The whole screen is one button. In the main case (Conversation
mode off), a tap starts recording, a tap stops and sends, and every reply is read aloud. After that the screen is
idle with the microphone closed. The screen shows the connection and what Hermes is doing, and stays on. A recording
made offline is sent once when the connection returns. Swipe or Back leaves, and logs carry no spoken or answer text.

**Architecture:** Car mode is its own route (`CarModeScreen`), pushed over the chat workspace. The workspace stays
mounted below and keeps its voice loop, read-aloud and media keys. All logic lives in `lib/car_mode/`:
- a pure state/tap/status table;
- a palette from Studio tokens;
- a session that owns the route, screen-on holder, hold/release, connection signal and log;
- a bridge whose closures reach into the workspace, plus the only adapter that reads chat types.

`profile_workspace_screen.dart` gets about 53 lines of thin hooks (Task 6), plus about 24 for steering while Hermes
works (Task 7).

**Tech Stack:** Flutter/Dart (Material, `ChangeNotifier`, gesture arena), the existing `VoiceDevice` /
`VoiceSwitchHolders` from the VAD chain. No new packages, no Kotlin change.

**Spec:** `docs/superpowers/specs/2026-10-14-wing-car-mode-design.md` (decisions: section "Decisions (Birk 14.10.)").
Clickable draft: `docs/superpowers/specs/2026-10-14-wing-car-mode-mockup.html`. Screenshots:
`docs/superpowers/specs/2026-10-14-wing-car-mode-shots/`.

**Gate:** Birk decided D1-D3 on 14.10. Nothing in this plan waits on him. Points he did not address are
`ANNAHME:` (spec, end of "Decisions"). If he later picks another option, apply the matching delta from "If Birk picks
another option" before Task 1.

## Global Constraints

- Targets the latest **unmodified upstream Hermes**. No backend change; all behaviour is client-only (AGENTS.md).
- Never change saved settings. `voice.conversation` and `voice.auto_speak` stay as the user set them. Car mode
  neither forces the loop on nor switches it off (spec §4.2).
- Own code goes in own files (`lib/car_mode/`, `test/car_mode/`). Upstream files only get the hooks of spec §6/§8
  (strategy doc rule 1).
- Logs (`WingCar …` via `debugPrint`) **never** contain transcript, spoken text, reply text, held text, chat title,
  tool name, activity text or session id (spec §7).
- The status line shows only the activity kind or the tool's `displayName`; never `detail`, arguments, commands or
  output (spec §2.2).
- Screen-on is a fixed part of car mode, held for the whole visit. It is not an option. Screen-off background voice is
  card t_4934d7d4.
- UI strings are English. Wing has no l10n (no `*.arb`, no `flutter_localizations`).
- Studio tokens (`WingTokens`) in both themes. At night there are no pure white areas. Touch targets ≥ 48 dp.
- Numbers: debounce 600 ms; swipe exit `|dx| ≥ min(96 dp, 25 % width)` or `|v| ≥ 700 dp/s` with `|dx| ≥ 48 dp`;
  swipe hint 6 s; offline retry every 20 s; signal pulses 250 ms apart; night fill `Color.lerp(surface, token, .28)`
  (all `ANNAHME:`, spec §4).
- Test command: `bash tools/factory/ci-suite.sh`. It runs `flutter analyze` and the **whole** `flutter test` on GitHub
  (`pr-quality.yml`). It takes **no** test-path argument (checked: `tools/factory/ci-suite.sh` never reads `$1`), so
  an appended path is ignored. The vServer has no Flutter SDK.
  - Success: last line `ci-suite: run <id> conclusion=success https://github.com/birkschmithuesen/Wing/actions/runs/<id>`, exit 0.
  - Failure: `conclusion=failure` plus `  failed step: Run tests` (or `Analyze`), exit 1.
  - Failing test names are **not** printed (the log host is blocked). Open the run URL in a browser or ask Birk.
- Kotlin / APK compile: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`. Success: last line
  `dispatch-check: voice-apk.yml run <id> conclusion=success …`, exit 0.

---

## Basis / Rebase

Line numbers in this plan: **vo** = `origin/voice-offline` @ `b4f5e4a0` (VAD chain merged, read via `git show`).
**up** = `upstream/main` @ `d0a0c262`. The implementation starts on **`voice-offline` after the upstream merge chain
(t_d1d49ff1 → t_6a4e1890 → t_f8523002)**. That merge is still pending: neither `8105ab72` nor `d0a0c262` is an ancestor
of `b4f5e4a0`. Every anchor below must be re-verified before Task 1.

Run each command from the repo root, one at a time. Write the result of each anchor into the commit message of
Task 1 ("Basis: anchors A1-A17 ok / moved: …").

| # | Command | Expected | If it moved / is missing |
|---|---|---|---|
| A1 | `git merge-base --is-ancestor 4a1a86c6 HEAD` | exit 0 (VAD chain merged; true on vo `b4f5e4a0`) | **Stop.** Car mode needs `VoiceSwitchHolders` + `stopHandsFree`. Ask Birk (`FRAGE:`). |
| A2 | `git merge-base --is-ancestor d0a0c262 HEAD` | exit 0 (upstream merged) | If Birk ordered an earlier start, continue: all vo line numbers apply as written. If upstream moved past `d0a0c262`, use the merged tip; the anchors below decide. |
| A3 | `git grep -n "class VoiceSwitchHolders" -- lib/core/services/android_voice.dart` | 1 hit (vo :218) | Missing → stop and ask (A1). |
| A4 | `git grep -n "Future<void> stopHandsFree" -- lib/core/controllers/voice_input_controller.dart` | 1 hit (vo :183) | Missing → the bridge's `sendNow` calls `_voiceInput.stop()`. The `_carSend` flag (Task 6) still makes it a send. |
| A5 | `git grep -n "enum VoiceInputPhase" -- lib/core/controllers/voice_input_controller.dart` | `{ idle, starting, recording, transcribing }` (vo :10) | Other values → extend `carPhaseOf` (Task 1) and its table test. |
| A6 | `git grep -n "_speakCompletedReply\|_canContinueConversation\|Future<void> _dictate\|_sendConversationTurn\|_conversationAwaitingReply = true\|finishedOnItsOwn" -- lib/core/screens/profile_workspace_screen.dart` | the loop is still in the screen (vo :238, :278, :300, :313, :392, :411) | The merge moved the loop → apply the Task 6/7 hooks there (same names). If the loop was **dropped**, stop and ask: case 1 needs it, and case 2 needs `_dictate`'s send path. |
| A7 | `git grep -n "settings.conversation\|\.conversation)\|final settings = VoicePreferences.read" -- lib/core/screens/profile_workspace_screen.dart` | vo :244, :245, :293, :401, :402 | Task 6 changes only :245, :401 and :402. The settings type may now be `AppPreferences…` → `roundSettings`/`carTapOnlySettings` take that type. |
| A8 | `git grep -n "_routeIsCurrent = isCurrent" -- lib/core/screens/profile_workspace_screen.dart` | 1 hit (vo :561, up :841) | Missing → find `ModalRoute.isCurrentOf(context)` in `didChangeDependencies` and OR `_car.active` into the variable that feeds `_hasWorkspaceFocus`. |
| A9 | `git grep -n "tooltip: 'Chat actions'" -- lib/core/screens/profile_workspace_screen.dart` | 1 hit (vo :980, up :1508) | Entry goes into that menu. Upstream uses `StudioPopupMenuItem` → use it for the item. |
| A10 | `git grep -n "Map<ComposerAction, String?> _composerActions\|Future<void> _performComposerAction" -- lib/core/screens/profile_workspace_screen.dart` | 2 hits (vo :2218, :2287) | Upstream composer moved → for Task 7 use `controller.steer(chat, text)` / `controller.queuePrompt(chat, text)` directly (up `profile_workspace_controller.dart:7139`, `:7148`). |
| A11 | `git grep -n "ServerConnectionPhase get phase" -- lib/core/services/server_connection_status.dart` | 1 hit (vo :43) | Needed by `carSnapshotOf` (Task 4). |
| A12 | `git grep -n "bool get busy\|enum ProfileTurnStatus\|enum ChatExecution" -- lib/core` | fork: `ProfileChat.busy` (vo controller :251), `ProfileTurnStatus` (:86); upstream: `ChatExecution` (up `lib/core/models/chat_runtime.dart:7`) | Upstream types → use the **upstream bodies** in Task 4. |
| A13 | `git grep -n "decideDelivery" -- lib` | none (barge-in t_7e81e040 not merged; none on vo) | Hit → barge-in landed. Skip Task 7 step 3; keep its test. Delete nothing of barge-in. |
| A14 | `git grep -n "ThemeData profileWorkspaceTheme\|static const preferenceKey = 'workspace_accent_v1'" -- lib/core/theme/profile_workspace_theme.dart` | 2 hits (vo :22, :17) | Moved → use what the workspace's `build` uses for its accent theme. |
| A15 | `git grep -n "enum ProfileMainActivity\|GatewayToolActivity? mainToolActivity\|enum ChatMainActivity" -- lib/core` | fork: vo controller :97, :101; upstream: `chat_runtime.dart:11` | Upstream → use the upstream body of `carActivityOf` (Task 4). |
| A16 | `git grep -n "Future<void> updateDraft\|Future<void> _persistDraft" -- lib/core/services/profile_workspace_controller.dart` | 2 hits (vo :3563, :3697): the draft is stored on the device | Missing → the held text would live only in memory. Stop and ask (`FRAGE:`), because spec §4.4 relies on the stored draft. |
| A17 | `git grep -n "const VoicePreferences({\|class VadEndpointConfig\|const int vadWindowMs" -- lib/core/services` | vo `voice_preferences.dart:93`, `vad_endpoint.dart:18`, `:9` | `carTapOnlySettings` (Task 3) copies **every** constructor field. Compare the field list with vo `voice_preferences.dart:93-105`; add new fields to the copy and its test. |

Also run `git log --oneline -5 -- lib/core/screens/profile_workspace_screen.dart`. If the max-dictation card
(t_d3a672fe) or barge-in touched `_dictate` or `_sendConversationTurn`, re-read both methods in full before Task 6.
On vo the newest commit there is `1f4dc471`.

**After the upstream merge (note for Task 4 and Task 6):**
- upstream `send` turns every message into a persisted outbox entry that drains after reconnect (up
  `profile_workspace_controller.dart:6391`, `:7193`, `:7278`). Keep `holdForConnection` anyway. It keeps the
  "Waiting for connection" screen honest and works on both bases.
- If the merged base already resends on reconnect, `sendHeld` still runs only once. It sends through
  `_sendConversationTurn`, which bails out on an empty draft.

**Overlap with other plans:**
- TTS language plan (`docs/superpowers/plans/2026-10-13-wing-tts-language.md`) touches `android_voice.dart` `speak`,
  `VoicePlayback.kt` and `VoiceChannel.kt`. This plan touches none of them.
- Barge-in touches `_sendConversationTurn` and `_speakCompletedReply`, as Tasks 6/7 do. Whoever lands second rebases.
  The shared hook is described in Task 7.
- Screen-off background voice (t_4934d7d4, `docs/superpowers/plans/2026-10-14-wing-voice-background.md`): separate
  card. This plan does not touch its files.

## File structure

| File | Create/Modify | Responsibility |
|---|---|---|
| `lib/car_mode/car_mode_state.dart` | Create | Pure: phases, snapshot, phase priority, tap table, texts, status line, connection texts, swipe rule, debounce gate, busy delivery |
| `lib/car_mode/car_mode_palette.dart` | Create | Day/night colours per phase and per connection badge, contrast helper |
| `lib/car_mode/car_mode_bridge.dart` | Create | `CarModeBridge` (closures), `carTapOnlySettings`, `carConnectionOf` (Task 3); `carSnapshotOf`, `carActivityOf` (Task 4) — the only car code that reads `ProfileChat` |
| `lib/car_mode/car_mode_session.dart` | Create | `CarModeSession`: enter/exit, screen-on, tap dispatch, hold/release, retry, connection signal, auto-exit, logs |
| `lib/car_mode/car_mode_screen.dart` | Create | Route widget: one full-screen button, top strip, status line, swipe hint, drag-to-leave |
| `lib/core/screens/profile_workspace_screen.dart` | Modify | Hooks: imports, field, dispose, focus, read-aloud, round settings, `_carSend`, hold, menu, busy delivery |
| `test/car_mode/car_mode_state_test.dart` | Create | Tables for phase, tap, texts, status line, connection, swipe, delivery, gate |
| `test/car_mode/car_mode_palette_test.dart` | Create | Contrast and "no white at night" |
| `test/car_mode/car_mode_bridge_test.dart` | Create | `carTapOnlySettings`, `carConnectionOf` |
| `test/car_mode/car_mode_session_test.dart` | Create | Session with a fake bridge |
| `test/car_mode/car_mode_screen_test.dart` | Create | Rendering, swipe vs tap, Back, hint, sizes, `VOICE_REVIEW` captures |
| `test/voice_workspace_test.dart` | Modify | Group "car mode": real workspace end to end |
| `.github/workflows/voice-review.yml` | Modify (1 line) | Add `test/car_mode/car_mode_screen_test.dart` to the renders (vo :34-35) |
| `docs/CAR_MODE.md` | Create | Behaviour, log lines, limits |
| `docs/VOICE.md` | Modify (1 line) | Link to `CAR_MODE.md` |

Upstream files touched: only `profile_workspace_screen.dart`. Budget: **~53 insertions in Task 6 and ~24 in Task 7,
~77 in total** (previous plan: ~35 + ~22). Acceptance limits: Task 6 ≤ 60 insertions, Task 6 + 7 ≤ 90 (checked in
Task 6 step 5 and Task 7 step 5). `voice-review.yml` is fork-owned (VAD chain).

---

### Task 1: Pure car-mode state

**Files:**
- Create: `lib/car_mode/car_mode_state.dart`
- Test: `test/car_mode/car_mode_state_test.dart`

**Interfaces:**
- Consumes: `VoiceInputPhase` from `lib/core/controllers/voice_input_controller.dart` (vo :10).
- Produces:
  - `enum CarPhase { idle, listening, transcribing, thinking, speaking, waiting, attention, error }`
  - `enum CarConnection { ok, reconnecting, offline }`
  - `enum CarTapAction { talk, sendNow, ignore }`
  - `enum CarDelivery { send, steer, queue, end }`
  - `typedef CarText = ({String label, String? hint, String? detail})`
  - `const String carWorking = 'Working'`
  - `class CarSnapshot` with fields `chatKey`, `title`, `input`, `speaking`, `working`, `activity`, `needsInput`,
    `connection`, `error`
  - `CarPhase carPhaseOf(CarSnapshot s, {bool held = false})`
  - `CarTapAction carTapActionFor(CarPhase phase, CarSnapshot s)`
  - `CarText carTextFor(CarPhase phase, CarSnapshot s)`
  - `IconData carIconFor(CarPhase phase)`
  - `String? carStatusLine(CarPhase phase, CarSnapshot s)`
  - `({String label, IconData icon}) carConnectionText(CarConnection c)`
  - `bool carSwipeExits({required double dx, required double velocity, required double width})`
  - `CarDelivery carDeliveryFor({required bool working, required bool steerAvailable, required bool queueAvailable})`
  - `class CarTapGate` (`CarTapGate({Duration gap})`, `bool accept()`, `void dispose()`)

- [ ] **Step 1: Write the failing test**

```dart
// test/car_mode/car_mode_state_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/car_mode/car_mode_state.dart';
import 'package:wing/core/controllers/voice_input_controller.dart';

void main() {
  const idle = CarSnapshot(chatKey: 'chat');

  test('phase priority: attention > listening > transcribing > speaking > waiting > thinking > error > idle', () {
    expect(carPhaseOf(idle), CarPhase.idle);
    expect(carPhaseOf(const CarSnapshot(chatKey: 'c', error: 'x')), CarPhase.error);
    expect(carPhaseOf(const CarSnapshot(chatKey: 'c', error: 'x', working: true)), CarPhase.thinking);
    expect(carPhaseOf(const CarSnapshot(chatKey: 'c', working: true), held: true), CarPhase.waiting);
    expect(carPhaseOf(const CarSnapshot(chatKey: 'c', speaking: true), held: true), CarPhase.speaking);
    expect(
      carPhaseOf(const CarSnapshot(chatKey: 'c', speaking: true, input: VoiceInputPhase.transcribing)),
      CarPhase.transcribing,
    );
    expect(carPhaseOf(const CarSnapshot(chatKey: 'c', input: VoiceInputPhase.starting)), CarPhase.listening);
    expect(
      carPhaseOf(const CarSnapshot(chatKey: 'c', input: VoiceInputPhase.recording), held: true),
      CarPhase.listening,
    );
    expect(
      carPhaseOf(const CarSnapshot(chatKey: 'c', input: VoiceInputPhase.recording, needsInput: true)),
      CarPhase.attention,
    );
    // The connection alone never changes the phase; the badge shows it.
    expect(carPhaseOf(const CarSnapshot(chatKey: 'c', connection: CarConnection.offline)), CarPhase.idle);
  });

  test('tap table of spec 4.3', () {
    CarTapAction tap(CarSnapshot s, {bool held = false}) => carTapActionFor(carPhaseOf(s, held: held), s);
    expect(tap(idle), CarTapAction.talk);
    expect(tap(const CarSnapshot(chatKey: 'c', input: VoiceInputPhase.starting)), CarTapAction.ignore);
    expect(tap(const CarSnapshot(chatKey: 'c', input: VoiceInputPhase.recording)), CarTapAction.sendNow);
    expect(tap(const CarSnapshot(chatKey: 'c', input: VoiceInputPhase.transcribing)), CarTapAction.ignore);
    expect(tap(const CarSnapshot(chatKey: 'c', working: true)), CarTapAction.talk);
    expect(tap(const CarSnapshot(chatKey: 'c', speaking: true)), CarTapAction.talk);
    expect(tap(idle, held: true), CarTapAction.talk);
    expect(tap(const CarSnapshot(chatKey: 'c', needsInput: true)), CarTapAction.ignore);
    expect(tap(const CarSnapshot(chatKey: 'c', error: 'x')), CarTapAction.talk);
    expect(tap(const CarSnapshot(chatKey: 'c', connection: CarConnection.offline)), CarTapAction.talk);
  });

  test('every phase has a label and an icon; texts of spec 4.3', () {
    for (final phase in CarPhase.values) {
      expect(carTextFor(phase, idle).label, isNotEmpty);
      expect(carIconFor(phase), isA<IconData>());
    }
    const error = CarSnapshot(chatKey: 'c', error: 'No speech detected. Try again.');
    expect(carTextFor(CarPhase.error, error).detail, 'No speech detected. Try again.');
    expect(carTextFor(CarPhase.idle, idle).label, 'Tap to talk');
    expect(carTextFor(CarPhase.listening, idle).hint, 'Tap to send');
    expect(carTextFor(CarPhase.waiting, idle).label, 'Waiting for connection');
    expect(carTextFor(CarPhase.waiting, idle).hint, 'Sends when back online');
  });

  test('status line: kind or tool name only, generic Working left to the thinking label', () {
    const terminal = CarSnapshot(chatKey: 'c', working: true, activity: 'Terminal');
    const working = CarSnapshot(chatKey: 'c', working: true, activity: carWorking);
    expect(carStatusLine(CarPhase.thinking, terminal), 'Terminal');
    expect(carStatusLine(CarPhase.listening, terminal), 'Terminal');
    expect(carStatusLine(CarPhase.thinking, working), isNull);
    expect(carStatusLine(CarPhase.listening, working), carWorking);
    expect(carStatusLine(CarPhase.idle, idle), isNull);
  });

  test('connection texts', () {
    expect(carConnectionText(CarConnection.ok).label, 'Connected');
    expect(carConnectionText(CarConnection.reconnecting).label, 'Reconnecting');
    expect(carConnectionText(CarConnection.offline).label, 'Offline');
    expect(
      CarConnection.values.map((c) => carConnectionText(c).icon).toSet(),
      hasLength(CarConnection.values.length),
    );
  });

  test('swipe exits on distance or on a fast flick, never on a short slide', () {
    expect(carSwipeExits(dx: -96, velocity: 0, width: 411), isTrue);
    expect(carSwipeExits(dx: 95, velocity: 0, width: 411), isFalse);
    expect(carSwipeExits(dx: 80, velocity: 0, width: 320), isTrue); // 25 % of 320 dp
    expect(carSwipeExits(dx: 50, velocity: -900, width: 411), isTrue);
    expect(carSwipeExits(dx: 40, velocity: 2000, width: 411), isFalse);
    expect(carSwipeExits(dx: 60, velocity: 600, width: 411), isFalse);
  });

  test('carDeliveryFor', () {
    expect(carDeliveryFor(working: false, steerAvailable: false, queueAvailable: false), CarDelivery.send);
    expect(carDeliveryFor(working: true, steerAvailable: true, queueAvailable: true), CarDelivery.steer);
    expect(carDeliveryFor(working: true, steerAvailable: false, queueAvailable: true), CarDelivery.queue);
    expect(carDeliveryFor(working: true, steerAvailable: false, queueAvailable: false), CarDelivery.end);
  });

  testWidgets('CarTapGate ignores a second tap within 600 ms, accepts after', (tester) async {
    final gate = CarTapGate();
    addTearDown(gate.dispose);
    expect(gate.accept(), isTrue);
    await tester.pump(const Duration(milliseconds: 599));
    expect(gate.accept(), isFalse);
    await tester.pump(const Duration(milliseconds: 2));
    expect(gate.accept(), isTrue);
    await tester.pump(const Duration(milliseconds: 700));
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=failure`, `  failed step: Analyze` (the missing `package:wing/car_mode/car_mode_state.dart` is an
analyzer error).

- [ ] **Step 3: Write the implementation**

```dart
// lib/car_mode/car_mode_state.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/controllers/voice_input_controller.dart';

/// What car mode shows. Exactly one phase at a time, see [carPhaseOf].
enum CarPhase { idle, listening, transcribing, thinking, speaking, waiting, attention, error }

/// The connection badge; never a phase of its own (spec §4.4).
enum CarConnection { ok, reconnecting, offline }

enum CarTapAction { talk, sendNow, ignore }

/// How a hands-free utterance reaches a busy chat (spec §6.4).
enum CarDelivery { send, steer, queue, end }

typedef CarText = ({String label, String? hint, String? detail});

/// Generic activity; the thinking label already says it (spec §4.6).
const String carWorking = 'Working';

/// Neutral facts about the chat on screen. Filled by `carSnapshotOf`; the
/// rest of car mode never reads chat or controller types.
class CarSnapshot {
  const CarSnapshot({
    required this.chatKey,
    this.title,
    this.input = VoiceInputPhase.idle,
    this.speaking = false,
    this.working = false,
    this.activity,
    this.needsInput = false,
    this.connection = CarConnection.ok,
    this.error,
  });

  /// Identity of the chat on screen; a change ends car mode.
  final Object? chatKey;

  /// Shown small on screen; never logged.
  final String? title;
  final VoiceInputPhase input;

  /// Read-aloud is playing or being prepared.
  final bool speaking;

  /// The chat's turn is submitting, running, waiting or reconnecting.
  final bool working;

  /// Status line: activity kind or tool display name only; never logged.
  final String? activity;

  /// Approval, clarification or secure prompt pending.
  final bool needsInput;
  final CarConnection connection;

  /// Short voice or turn error text; shown on screen, never logged.
  final String? error;
}

/// [held]: a finished recording waits for the connection (spec §4.4).
CarPhase carPhaseOf(CarSnapshot s, {bool held = false}) {
  if (s.needsInput) return CarPhase.attention;
  switch (s.input) {
    case VoiceInputPhase.starting || VoiceInputPhase.recording:
      return CarPhase.listening;
    case VoiceInputPhase.transcribing:
      return CarPhase.transcribing;
    case VoiceInputPhase.idle:
      break;
  }
  if (s.speaking) return CarPhase.speaking;
  if (held) return CarPhase.waiting;
  if (s.working) return CarPhase.thinking;
  if (s.error != null) return CarPhase.error;
  return CarPhase.idle;
}

/// Spec §4.3. Thinking → talk steers the running turn; waiting → talk adds to
/// the held text.
CarTapAction carTapActionFor(CarPhase phase, CarSnapshot s) => switch (phase) {
  CarPhase.idle ||
  CarPhase.error ||
  CarPhase.speaking ||
  CarPhase.thinking ||
  CarPhase.waiting => CarTapAction.talk,
  CarPhase.listening =>
    s.input == VoiceInputPhase.recording ? CarTapAction.sendNow : CarTapAction.ignore,
  CarPhase.transcribing || CarPhase.attention => CarTapAction.ignore,
};

CarText carTextFor(CarPhase phase, CarSnapshot s) => switch (phase) {
  CarPhase.idle => (label: 'Tap to talk', hint: null, detail: null),
  CarPhase.listening => (label: 'Listening', hint: 'Tap to send', detail: null),
  CarPhase.transcribing => (label: 'Got it', hint: 'Transcribing…', detail: null),
  CarPhase.thinking => (label: 'Hermes is working', hint: 'Tap to add something', detail: null),
  CarPhase.speaking => (label: 'Reading aloud', hint: 'Tap to interrupt', detail: null),
  CarPhase.waiting => (label: 'Waiting for connection', hint: 'Sends when back online', detail: null),
  CarPhase.attention => (
    label: 'Needs you on screen',
    hint: 'Approval or question waiting. Look when parked.',
    detail: null,
  ),
  CarPhase.error => (label: "Didn't work", hint: 'Tap to try again', detail: s.error),
};

IconData carIconFor(CarPhase phase) => switch (phase) {
  CarPhase.idle => Icons.mic,
  CarPhase.listening => Icons.stop_rounded,
  CarPhase.transcribing => Icons.more_horiz,
  CarPhase.thinking => Icons.hourglass_empty,
  CarPhase.speaking => Icons.volume_up,
  CarPhase.waiting => Icons.schedule_send,
  CarPhase.attention => Icons.visibility,
  CarPhase.error => Icons.warning,
};

/// Upper-third status line (spec §4.6). Never arguments or output: the
/// adapter only ever passes a kind or a tool display name.
String? carStatusLine(CarPhase phase, CarSnapshot s) {
  final activity = s.activity;
  if (activity == null) return null;
  if (phase == CarPhase.thinking && activity == carWorking) return null;
  return activity;
}

({String label, IconData icon}) carConnectionText(CarConnection c) => switch (c) {
  CarConnection.ok => (label: 'Connected', icon: Icons.cloud_done),
  CarConnection.reconnecting => (label: 'Reconnecting', icon: Icons.sync),
  CarConnection.offline => (label: 'Offline', icon: Icons.cloud_off),
};

/// A horizontal drag leaves car mode when it is long or a fast flick
/// (spec §4.8). [dx] is measured from touch-down, [velocity] in dp/s.
bool carSwipeExits({required double dx, required double velocity, required double width}) {
  final distance = dx.abs();
  return distance >= math.min(96.0, width * .25) || (velocity.abs() >= 700 && distance >= 48);
}

/// A hands-free utterance on a busy chat: steer if Hermes accepts it, else
/// queue, else give up (spec §6.4; barge-in's decideDelivery replaces this).
CarDelivery carDeliveryFor({
  required bool working,
  required bool steerAvailable,
  required bool queueAvailable,
}) {
  if (!working) return CarDelivery.send;
  if (steerAvailable) return CarDelivery.steer;
  if (queueAvailable) return CarDelivery.queue;
  return CarDelivery.end;
}

/// Ignores a second hit within [gap] (bumpy road). Timer based, so widget
/// tests control it with `pump`.
class CarTapGate {
  CarTapGate({this.gap = const Duration(milliseconds: 600)});
  final Duration gap;
  Timer? _closed;

  bool accept() {
    if (_closed?.isActive ?? false) return false;
    _closed = Timer(gap, () {});
    return true;
  }

  void dispose() => _closed?.cancel();
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tools/factory/ci-suite.sh`
Expected: `ci-suite: run <id> conclusion=success …`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/car_mode/car_mode_state.dart test/car_mode/car_mode_state_test.dart
git commit -m "feat(car): pure car-mode phases, tap table, status line and swipe rule"
```

(The commit body records the Basis anchor results, see "Basis / Rebase".)

---

### Task 2: Palette from Studio tokens

**Files:**
- Create: `lib/car_mode/car_mode_palette.dart`
- Test: `test/car_mode/car_mode_palette_test.dart`

**Interfaces:**
- Consumes: `CarPhase`, `CarConnection` (Task 1). `WingTokens` (`lib/core/theme/wing_theme.dart`, fields `surface`,
  `raised`, `onSurface`, `muted`, `accent`, `success` (vo :148), `warning`, `danger`, `running`). `wingTheme(Brightness,
  {Color? accent})` (vo :291). `WorkspaceAccent` (`light`, `dark`; vo `profile_workspace_theme.dart:5-16`).
- Produces:
  - `class CarColors { final Color fill, label, hint; final Color? border; }`
  - `CarColors carColorsFor(CarPhase phase, WingTokens t, Brightness brightness)`
  - `class CarBadgeColors { final Color background, foreground; }`
  - `CarBadgeColors carBadgeColorsFor(CarConnection c, WingTokens t)`
  - `double carContrast(Color a, Color b)`

- [ ] **Step 1: Write the failing test**

```dart
// test/car_mode/car_mode_palette_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/car_mode/car_mode_palette.dart';
import 'package:wing/car_mode/car_mode_state.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';
import 'package:wing/core/theme/wing_theme.dart';

void main() {
  for (final accent in WorkspaceAccent.values) {
    for (final brightness in Brightness.values) {
      final tokens = wingTheme(
        brightness,
        accent: brightness == Brightness.dark ? accent.dark : accent.light,
      ).extension<WingTokens>()!;
      test('${accent.name} ${brightness.name}: label ≥ 3:1, hint ≥ 4.5:1, badge ≥ 4.5:1', () {
        for (final phase in CarPhase.values) {
          final c = carColorsFor(phase, tokens, brightness);
          expect(carContrast(c.label, c.fill), greaterThanOrEqualTo(3.0), reason: '$phase label');
          expect(carContrast(c.hint, c.fill), greaterThanOrEqualTo(4.5), reason: '$phase hint');
        }
        for (final connection in CarConnection.values) {
          final b = carBadgeColorsFor(connection, tokens);
          expect(carContrast(b.foreground, b.background), greaterThanOrEqualTo(4.5), reason: '$connection');
        }
      });
      if (brightness == Brightness.dark) {
        test('${accent.name} night has no pure white', () {
          final colors = [
            for (final phase in CarPhase.values) ...[
              carColorsFor(phase, tokens, brightness).fill,
              carColorsFor(phase, tokens, brightness).label,
              carColorsFor(phase, tokens, brightness).hint,
              ?carColorsFor(phase, tokens, brightness).border,
            ],
            for (final connection in CarConnection.values) ...[
              carBadgeColorsFor(connection, tokens).background,
              carBadgeColorsFor(connection, tokens).foreground,
            ],
          ];
          for (final color in colors) {
            expect(color.toARGB32(), isNot(0xFFFFFFFF));
          }
        });
      }
    }
  }

  test('day listening uses the danger token with white text; badge colours follow the connection', () {
    final tokens = wingTheme(Brightness.light).extension<WingTokens>()!;
    final c = carColorsFor(CarPhase.listening, tokens, Brightness.light);
    expect(c.fill, tokens.danger);
    expect(c.label, Colors.white);
    expect(carContrast(Colors.white, const Color(0xFFB91C1C)), closeTo(6.5, 0.1));
    expect(carBadgeColorsFor(CarConnection.ok, tokens).foreground, tokens.success);
    expect(carBadgeColorsFor(CarConnection.reconnecting, tokens).foreground, tokens.warning);
    expect(carBadgeColorsFor(CarConnection.offline, tokens).foreground, tokens.danger);
    expect(carBadgeColorsFor(CarConnection.offline, tokens).background, tokens.surface);
  });
}
```

ANNAHME: Dart ≥ 3.8 null-aware list elements (`?….border`) are available (`pubspec.yaml` `sdk: ^3.12.0`), and
`Color.toARGB32()` exists in the pinned Flutter 3.44 (`voice-review.yml` `flutter-version: '3.44.0'`). Check:
`git grep -n "sdk:" -- pubspec.yaml` and `git grep -n "flutter-version" -- .github/workflows/voice-review.yml`. If the
analyzer rejects either, use `if (x.border != null) x.border!` and `.value`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=failure`, `  failed step: Analyze` (missing file).

- [ ] **Step 3: Write the implementation**

```dart
// lib/car_mode/car_mode_palette.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/wing_theme.dart';
import 'car_mode_state.dart';

class CarColors {
  const CarColors({required this.fill, required this.label, required this.hint, this.border});
  final Color fill;
  final Color label;
  final Color hint;
  final Color? border;
}

class CarBadgeColors {
  const CarBadgeColors({required this.background, required this.foreground});
  final Color background;
  final Color foreground;
}

/// Day: the state token as fill with white text. Night: the token mixed 28 %
/// into the dark canvas, token-coloured label and a softer hint; no white.
CarColors carColorsFor(CarPhase phase, WingTokens t, Brightness brightness) {
  final night = brightness == Brightness.dark;
  if (phase == CarPhase.idle) {
    return CarColors(fill: t.raised, label: t.accent, hint: t.muted, border: t.accent);
  }
  final token = switch (phase) {
    CarPhase.listening || CarPhase.transcribing => t.danger,
    CarPhase.thinking => t.running,
    CarPhase.speaking => t.accent,
    CarPhase.attention || CarPhase.error => t.warning,
    CarPhase.waiting || CarPhase.idle => t.muted,
  };
  if (!night) return CarColors(fill: token, label: Colors.white, hint: Colors.white);
  return CarColors(
    fill: Color.lerp(t.surface, token, .28)!,
    label: token,
    hint: Color.lerp(token, t.onSurface, .5)!,
  );
}

/// The connection badge: a surface pill with token-coloured border, icon and
/// text, so it stands out on every state fill (spec §4.4).
CarBadgeColors carBadgeColorsFor(CarConnection c, WingTokens t) => CarBadgeColors(
  background: t.surface,
  foreground: switch (c) {
    CarConnection.ok => t.success,
    CarConnection.reconnecting => t.warning,
    CarConnection.offline => t.danger,
  },
);

/// WCAG 2 contrast ratio.
double carContrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`.

The contrast test may fail for one accent/phase pair. The likely case is a light accent used as the day *speaking*
fill. If it fails, do **not** lower the threshold. For that phase, switch the day label and hint to `t.onSurface` on a
`Color.lerp(t.raised, token, .25)` fill, and note the change in `docs/CAR_MODE.md`. The badge pairs are computed in
spec §4.6 (light: 4.7:1, 4.7:1, 6.1:1).

- [ ] **Step 5: Commit**

```bash
git add lib/car_mode/car_mode_palette.dart test/car_mode/car_mode_palette_test.dart
git commit -m "feat(car): day/night car palette and connection badge colours from studio tokens"
```

---

### Task 3: Session (route, screen-on, tap, hold/release, signal, logs), bridge type, tap-only settings

**Files:**
- Create: `lib/car_mode/car_mode_bridge.dart` (`CarModeBridge`, `carTapOnlySettings`, `carConnectionOf`; Task 4
  appends the adapter)
- Create: `lib/car_mode/car_mode_session.dart`
- Create: `lib/car_mode/car_mode_screen.dart` (minimal placeholder in this task, replaced in Task 5)
- Test: `test/car_mode/car_mode_bridge_test.dart`, `test/car_mode/car_mode_session_test.dart`

**Interfaces:**
- Consumes: Task 1 (`CarSnapshot`, `carPhaseOf`, `carTapActionFor`, `CarTapGate`, `CarDelivery`, `CarConnection`).
  `VoiceDevice`, `VoiceSwitchHolders.screenOn(device).set(Object owner, bool on)` (vo
  `lib/core/services/android_voice.dart:218-256`). `VoicePreferences` (const constructor, vo
  `voice_preferences.dart:93-105`; `read` :107). `VadEndpointConfig`, `VadEndpointer`, `VadEndReason` (vo
  `vad_endpoint.dart:18`, `:71`, `:55`). `ServerConnectionPhase` (vo `server_connection_status.dart:7-13`).
  `VoiceDeviceFixture.keepScreenOnCalls` (vo `test/support/voice_fixture.dart:30`).
- Produces:

```dart
class CarModeBridge {
  const CarModeBridge({
    required this.changes,      // Listenable
    required this.read,         // CarSnapshot Function()
    required this.preferences,  // SharedPreferences (accent + route/loop names for the log)
    required this.talk,         // Future<void> Function()
    required this.sendNow,      // Future<void> Function()
    required this.stopSpeech,   // Future<void> Function()
    required this.retry,        // Future<void> Function()
    required this.sendHeld,     // Future<void> Function()
    required this.leave,        // VoidCallback
  });
}
VoicePreferences carTapOnlySettings(VoicePreferences s);
CarConnection carConnectionOf(ServerConnectionPhase phase, {required bool sendBlocked});

class CarModeSession extends ChangeNotifier {
  CarModeSession({required VoiceDevice device, required CarModeBridge bridge,
      void Function(String line)? log, Duration retryEvery = const Duration(seconds: 20),
      Duration signalGap = const Duration(milliseconds: 250)});
  bool get active;
  bool get held;
  CarSnapshot get snapshot;
  CarPhase get phase;
  Future<void> enter(BuildContext context);
  void exit(String reason);
  Future<void> tap();
  VoicePreferences roundSettings(VoicePreferences settings);
  bool holdForConnection();
  void logDelivery(CarDelivery delivery);
  void swiped({required bool exits});
}
class CarModeScreen extends StatefulWidget { const CarModeScreen({super.key, required this.session}); }
```

- [ ] **Step 1: Write the failing tests**

```dart
// test/car_mode/car_mode_bridge_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/car_mode/car_mode_bridge.dart';
import 'package:wing/car_mode/car_mode_state.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/services/vad_endpoint.dart';
import 'package:wing/core/services/voice_preferences.dart';

void main() {
  test('carTapOnlySettings copies every field and only stretches the vad pause', () {
    const s = VoicePreferences(
      input: VoiceInputRoute.vad,
      output: VoiceProcessing.hermes,
      language: 'de-DE',
      voice: 'v1',
      rate: 1.2,
      autoSpeak: true,
      conversation: false,
      vad: VadEndpointConfig(
        pause: Duration(milliseconds: 1400),
        minSpeech: Duration(milliseconds: 150),
        preRoll: Duration(milliseconds: 500),
        maxDuration: Duration(seconds: 900),
        noSpeechTimeout: Duration(seconds: 12),
      ),
      cues: false,
      debugRecordings: true,
      audioSource: VadAudioSource.recognition,
    );
    final t = carTapOnlySettings(s);
    expect(t.input, s.input);
    expect(t.output, s.output);
    expect(t.language, s.language);
    expect(t.voice, s.voice);
    expect(t.rate, s.rate);
    expect(t.autoSpeak, s.autoSpeak);
    expect(t.conversation, s.conversation);
    expect(t.cues, s.cues);
    expect(t.debugRecordings, s.debugRecordings);
    expect(t.audioSource, s.audioSource);
    expect(t.vad.pause, const Duration(seconds: 900));
    expect(t.vad.minSpeech, s.vad.minSpeech);
    expect(t.vad.preRoll, s.vad.preRoll);
    expect(t.vad.maxDuration, s.vad.maxDuration);
    expect(t.vad.noSpeechTimeout, s.vad.noSpeechTimeout);
  });

  test('with tap-only settings the vad pause never ends a round; the default does', () {
    final normal = VadEndpointer(const VadEndpointConfig());
    expect(normal.feedAll(List.filled(30, .9)), isNull);
    expect(normal.feedAll(List.filled(60, .1))?.reason, VadEndReason.pause);

    final tapOnly = VadEndpointer(carTapOnlySettings(const VoicePreferences()).vad);
    expect(tapOnly.feedAll(List.filled(30, .9)), isNull);
    expect(tapOnly.feedAll(List.filled(200, .1)), isNull);
    expect(tapOnly.forceEnd(VadEndReason.mediaKey).reason, VadEndReason.mediaKey);
  });

  test('carConnectionOf: limited and blocked sends count as reconnecting', () {
    expect(carConnectionOf(ServerConnectionPhase.connected, sendBlocked: false), CarConnection.ok);
    expect(carConnectionOf(ServerConnectionPhase.unchecked, sendBlocked: false), CarConnection.ok);
    expect(carConnectionOf(ServerConnectionPhase.connected, sendBlocked: true), CarConnection.reconnecting);
    expect(carConnectionOf(ServerConnectionPhase.limited, sendBlocked: false), CarConnection.reconnecting);
    expect(carConnectionOf(ServerConnectionPhase.reconnecting, sendBlocked: false), CarConnection.reconnecting);
    expect(carConnectionOf(ServerConnectionPhase.disconnected, sendBlocked: false), CarConnection.offline);
  });
}
```

```dart
// test/car_mode/car_mode_session_test.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/car_mode/car_mode_bridge.dart';
import 'package:wing/car_mode/car_mode_session.dart';
import 'package:wing/car_mode/car_mode_state.dart';
import 'package:wing/core/controllers/voice_input_controller.dart';
import 'package:wing/core/services/voice_preferences.dart';
import '../support/voice_fixture.dart';

class _World extends ChangeNotifier {
  CarSnapshot snapshot = const CarSnapshot(chatKey: 'chat', title: 'Secret title');
  final calls = <String>[];
  void set(CarSnapshot next) {
    snapshot = next;
    notifyListeners();
  }
}

void main() {
  late VoiceDeviceFixture device;
  late _World world;
  late List<String> logs;
  late CarModeSession session;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    device = VoiceDeviceFixture();
    world = _World();
    logs = [];
    session = CarModeSession(
      device: device,
      log: logs.add,
      bridge: CarModeBridge(
        changes: world,
        read: () => world.snapshot,
        preferences: prefs,
        talk: () async => world.calls.add('talk'),
        sendNow: () async => world.calls.add('sendNow'),
        stopSpeech: () async => world.calls.add('stopSpeech'),
        retry: () async => world.calls.add('retry'),
        sendHeld: () async => world.calls.add('sendHeld'),
        leave: () => world.calls.add('leave'),
      ),
    );
  });
  tearDown(() async {
    session.dispose();
    await device.stream.close();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => session.enter(context),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  List<Object?> recordHaptics(WidgetTester tester) {
    final haptics = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    return haptics;
  }

  testWidgets('enter holds the screen on; a swipe exit leaves and releases it', (tester) async {
    await open(tester);
    expect(session.active, isTrue);
    expect(find.byType(CarModeScreen), findsOneWidget);
    expect(device.keepScreenOnCalls, [true]);
    expect(logs.first, 'WingCar enter route=local loop=off');
    session.swiped(exits: true);
    await tester.pumpAndSettle();
    expect(session.active, isFalse);
    expect(find.byType(CarModeScreen), findsNothing);
    expect(device.keepScreenOnCalls, [true, false]);
    expect(world.calls, ['leave']);
    expect(logs, containsAllInOrder(['WingCar swipe action=exit', 'WingCar exit reason=swipe']));
  });

  testWidgets('a short swipe neither leaves nor taps', (tester) async {
    await open(tester);
    session.swiped(exits: false);
    await tester.pump();
    expect(session.active, isTrue);
    expect(world.calls, isEmpty);
    expect(logs.last, 'WingCar swipe action=short');
    session.exit('test');
    await tester.pumpAndSettle();
  });

  testWidgets('Android Back leaves directly, without a hint', (tester) async {
    await open(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(session.active, isFalse);
    expect(find.byType(CarModeScreen), findsNothing);
    expect(world.calls, ['leave']);
    expect(device.keepScreenOnCalls, [true, false]);
    expect(logs.last, 'WingCar exit reason=back');
  });

  testWidgets('tap dispatches by phase and debounces', (tester) async {
    await open(tester);
    await session.tap();
    expect(world.calls, ['talk']);
    world.set(const CarSnapshot(chatKey: 'chat', input: VoiceInputPhase.recording));
    await session.tap(); // within 600 ms → debounced
    expect(world.calls, ['talk']);
    await tester.pump(const Duration(milliseconds: 650));
    await session.tap();
    expect(world.calls, ['talk', 'sendNow']);
    await tester.pump(const Duration(milliseconds: 650));
    world.set(const CarSnapshot(chatKey: 'chat', speaking: true));
    await session.tap();
    expect(world.calls, ['talk', 'sendNow', 'stopSpeech', 'talk']);
    await tester.pump(const Duration(milliseconds: 650));
    world.set(const CarSnapshot(chatKey: 'chat', needsInput: true));
    await session.tap();
    expect(world.calls.length, 4);
    expect(logs.last, 'WingCar tap phase=attention action=ignore');
    session.exit('test');
    await tester.pumpAndSettle();
  });

  testWidgets('a different chat on screen closes car mode', (tester) async {
    await open(tester);
    world.set(const CarSnapshot(chatKey: 'other'));
    await tester.pumpAndSettle();
    expect(session.active, isFalse);
    expect(find.byType(CarModeScreen), findsNothing);
    expect(logs.last, 'WingCar exit reason=chatChanged');
  });

  testWidgets('a held recording is released exactly once when the connection is back', (tester) async {
    await open(tester);
    world.set(const CarSnapshot(chatKey: 'chat', connection: CarConnection.offline));
    expect(session.holdForConnection(), isTrue);
    expect(session.phase, CarPhase.waiting);
    expect(session.holdForConnection(), isTrue); // still one hold
    expect(logs.where((l) => l == 'WingCar hold'), hasLength(1));
    world.set(const CarSnapshot(chatKey: 'chat', connection: CarConnection.reconnecting));
    world.set(const CarSnapshot(chatKey: 'chat', working: true));
    await tester.pump();
    expect(world.calls, isNot(contains('sendHeld'))); // Hermes still busy
    world.set(const CarSnapshot(chatKey: 'chat'));
    await tester.pump();
    world.set(const CarSnapshot(chatKey: 'chat'));
    world.set(const CarSnapshot(chatKey: 'chat'));
    await tester.pump();
    expect(world.calls.where((c) => c == 'sendHeld'), hasLength(1));
    expect(session.held, isFalse);
    expect(session.phase, CarPhase.idle);
    expect(session.holdForConnection(), isFalse); // connected: a normal send
    session.exit('test');
    await tester.pumpAndSettle();
  });

  testWidgets('a new round sent while connected carries the held text and clears the hold', (tester) async {
    await open(tester);
    world.set(const CarSnapshot(chatKey: 'chat', connection: CarConnection.offline));
    expect(session.holdForConnection(), isTrue);
    world.snapshot = const CarSnapshot(chatKey: 'chat', input: VoiceInputPhase.transcribing);
    expect(session.holdForConnection(), isFalse);
    expect(session.held, isFalse);
    world.set(const CarSnapshot(chatKey: 'chat'));
    await tester.pump();
    expect(world.calls, isNot(contains('sendHeld')));
    session.exit('test');
    await tester.pumpAndSettle();
  });

  testWidgets('while held and offline the session retries every 20 s', (tester) async {
    await open(tester);
    world.set(const CarSnapshot(chatKey: 'chat', connection: CarConnection.offline));
    session.holdForConnection();
    await tester.pump(const Duration(seconds: 19));
    expect(world.calls, isNot(contains('retry')));
    await tester.pump(const Duration(seconds: 2));
    expect(world.calls.where((c) => c == 'retry'), hasLength(1));
    await tester.pump(const Duration(seconds: 20));
    expect(world.calls.where((c) => c == 'retry'), hasLength(2));
    session.exit('test'); // cancels the timer
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 40));
    expect(world.calls.where((c) => c == 'retry'), hasLength(2));
  });

  testWidgets('connection loss vibrates three times, the return twice; blips stay quiet', (tester) async {
    final haptics = recordHaptics(tester);
    await open(tester);
    world.set(const CarSnapshot(chatKey: 'chat', connection: CarConnection.reconnecting));
    world.set(const CarSnapshot(chatKey: 'chat'));
    await tester.pump(const Duration(seconds: 1));
    expect(haptics, isEmpty);
    world.set(const CarSnapshot(chatKey: 'chat', connection: CarConnection.offline));
    await tester.pump(const Duration(seconds: 1));
    expect(haptics, [null, null, null]); // HapticFeedback.vibrate()
    world.set(const CarSnapshot(chatKey: 'chat', connection: CarConnection.reconnecting));
    world.set(const CarSnapshot(chatKey: 'chat'));
    await tester.pump(const Duration(seconds: 1));
    expect(haptics.skip(3), ['HapticFeedbackType.heavyImpact', 'HapticFeedbackType.heavyImpact']);
    expect(
      logs.where((l) => l.startsWith('WingCar connection')),
      [
        'WingCar connection state=reconnecting',
        'WingCar connection state=ok',
        'WingCar connection state=offline',
        'WingCar connection state=reconnecting',
        'WingCar connection state=ok',
      ],
    );
    session.exit('test');
    await tester.pumpAndSettle();
  });

  testWidgets('roundSettings: tap-only only in car mode with conversation mode off', (tester) async {
    const off = VoicePreferences();
    const on = VoicePreferences(conversation: true);
    expect(identical(session.roundSettings(off), off), isTrue); // not in car mode
    await open(tester);
    expect(session.roundSettings(off).vad.pause, off.vad.maxDuration);
    expect(identical(session.roundSettings(on), on), isTrue);
    session.exit('test');
    await tester.pumpAndSettle();
  });

  testWidgets('logs never contain title, error, activity or held text', (tester) async {
    await open(tester);
    world.set(const CarSnapshot(
      chatKey: 'chat',
      title: 'Secret title',
      error: 'Secret error',
      activity: 'Secret tool',
      connection: CarConnection.offline,
    ));
    await session.tap();
    session.holdForConnection();
    session.logDelivery(CarDelivery.steer);
    await tester.pump(const Duration(milliseconds: 650));
    session.exit('test');
    await tester.pumpAndSettle();
    expect(logs, isNotEmpty);
    for (final line in logs) {
      expect(line, startsWith('WingCar '));
      expect(line, isNot(contains('Secret')));
    }
    expect(logs, contains('WingCar deliver kind=steer'));
    expect(logs, contains('WingCar tap phase=error action=talk'));
    expect(logs, contains('WingCar hold'));
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=failure`, `  failed step: Analyze`.

- [ ] **Step 3: Write the implementation**

```dart
// lib/car_mode/car_mode_bridge.dart
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/server_connection_status.dart';
import '../core/services/vad_endpoint.dart';
import '../core/services/voice_preferences.dart';
import 'car_mode_state.dart';

/// What car mode may do in the chat workspace. The workspace builds it from
/// closures over its private voice loop (spec §6.5).
class CarModeBridge {
  const CarModeBridge({
    required this.changes,
    required this.read,
    required this.preferences,
    required this.talk,
    required this.sendNow,
    required this.stopSpeech,
    required this.retry,
    required this.sendHeld,
    required this.leave,
  });

  /// Fires when anything in [read] may have changed.
  final Listenable changes;
  final CarSnapshot Function() read;
  final SharedPreferences preferences;

  /// Stop read-aloud and open the microphone for the chat.
  final Future<void> Function() talk;

  /// End the running round now and send what was said.
  final Future<void> Function() sendNow;
  final Future<void> Function() stopSpeech;

  /// Ask the workspace to reconnect (`controller.resumeConnection`).
  final Future<void> Function() retry;

  /// Send the held draft once through the normal hands-free send.
  final Future<void> Function() sendHeld;

  /// Cancel recording (not sent) and stop read-aloud; the turn keeps running.
  final VoidCallback leave;
}

/// Case 2 (spec §4.2): the vad pause can never end the round before the
/// limit, so only a tap (or the media key) does. Copies every field.
VoicePreferences carTapOnlySettings(VoicePreferences s) => VoicePreferences(
  input: s.input,
  output: s.output,
  language: s.language,
  voice: s.voice,
  rate: s.rate,
  autoSpeak: s.autoSpeak,
  conversation: s.conversation,
  vad: VadEndpointConfig(
    pause: s.vad.maxDuration,
    minSpeech: s.vad.minSpeech,
    preRoll: s.vad.preRoll,
    maxDuration: s.vad.maxDuration,
    noSpeechTimeout: s.vad.noSpeechTimeout,
  ),
  cues: s.cues,
  debugRecordings: s.debugRecordings,
  audioSource: s.audioSource,
);

/// Spec §4.4. [sendBlocked]: the workspace would refuse a send right now
/// (`recovering`, chat opening or offline snapshot).
CarConnection carConnectionOf(ServerConnectionPhase phase, {required bool sendBlocked}) =>
    switch (phase) {
      ServerConnectionPhase.disconnected => CarConnection.offline,
      ServerConnectionPhase.reconnecting || ServerConnectionPhase.limited => CarConnection.reconnecting,
      ServerConnectionPhase.connected ||
      ServerConnectionPhase.unchecked => sendBlocked ? CarConnection.reconnecting : CarConnection.ok,
    };
```

```dart
// lib/car_mode/car_mode_session.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/controllers/voice_input_controller.dart';
import '../core/services/android_voice.dart';
import '../core/services/voice_preferences.dart';
import 'car_mode_bridge.dart';
import 'car_mode_screen.dart';
import 'car_mode_state.dart';

/// One car-mode visit over one chat. Owns the route, the screen-on holder, the
/// held recording and the text-free log (spec §4, §7).
class CarModeSession extends ChangeNotifier {
  CarModeSession({
    required this.device,
    required this.bridge,
    void Function(String line)? log,
    this.retryEvery = const Duration(seconds: 20),
    this.signalGap = const Duration(milliseconds: 250),
  }) : _log = log ?? debugPrint;

  final VoiceDevice device;
  final CarModeBridge bridge;
  final Duration retryEvery;
  final Duration signalGap;
  final void Function(String line) _log;
  final _gate = CarTapGate();
  final _pulses = <Timer>[];
  bool _active = false;
  bool _held = false;
  bool _lostSignalled = false;
  Object? _chatKey;
  CarConnection _connection = CarConnection.ok;
  NavigatorState? _navigator;
  Route<void>? _route;
  Timer? _retry;

  bool get active => _active;

  /// A finished recording waits in the chat draft for the connection.
  bool get held => _held;
  CarSnapshot get snapshot => bridge.read();
  CarPhase get phase => carPhaseOf(snapshot, held: _held);

  Future<void> enter(BuildContext context) async {
    final snap = bridge.read();
    if (_active || snap.chatKey == null) return;
    // Active before the push: the workspace below keeps its focus.
    _active = true;
    _held = false;
    _lostSignalled = false;
    _chatKey = snap.chatKey;
    _connection = snap.connection;
    VoiceSwitchHolders.screenOn(device).set(this, true);
    bridge.changes.addListener(_changed);
    _log('WingCar enter route=${_routeName()} loop=${_loopName()}');
    notifyListeners();
    final navigator = _navigator = Navigator.of(context);
    final route = _route = MaterialPageRoute<void>(
      builder: (_) => CarModeScreen(session: this),
    );
    await navigator.push(route);
    // Android Back popped the route; after exit() this does nothing.
    _leave('back');
  }

  void exit(String reason) {
    if (!_active) return;
    _leave(reason);
    final route = _route;
    final navigator = _navigator;
    _route = null;
    if (route == null || navigator == null || !route.isActive) return;
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  void _leave(String reason) {
    if (!_active) return;
    bridge.leave();
    _end(reason);
  }

  void _end(String reason) {
    if (!_active) return;
    _active = false;
    _held = false;
    _retry?.cancel();
    _retry = null;
    for (final pulse in _pulses) {
      pulse.cancel();
    }
    _pulses.clear();
    bridge.changes.removeListener(_changed);
    VoiceSwitchHolders.screenOn(device).set(this, false);
    _log('WingCar exit reason=$reason');
    notifyListeners();
  }

  void _changed() {
    if (!_active) return;
    final snap = bridge.read();
    if (snap.chatKey != _chatKey) {
      exit('chatChanged');
      return;
    }
    _connectionChanged(snap.connection);
    if (_held &&
        snap.connection == CarConnection.ok &&
        !snap.working &&
        !snap.speaking &&
        snap.input == VoiceInputPhase.idle) {
      // Cleared before the send: only a new hold can send again.
      _held = false;
      _syncRetry();
      _log('WingCar release');
      // Outside this listener call: the send notifies the same listeners.
      scheduleMicrotask(() => unawaited(bridge.sendHeld()));
    }
    notifyListeners();
  }

  void _connectionChanged(CarConnection next) {
    if (next == _connection) return;
    _connection = next;
    _log('WingCar connection state=${next.name}');
    if (next == CarConnection.offline && !_lostSignalled) {
      _lostSignalled = true;
      _pulse(HapticFeedback.vibrate, 3);
    } else if (next == CarConnection.ok && _lostSignalled) {
      _lostSignalled = false;
      _pulse(HapticFeedback.heavyImpact, 2);
    }
    _syncRetry();
  }

  /// Vibration only: the cue tones cannot play on demand (spec §4.4).
  void _pulse(Future<void> Function() haptic, int times) {
    _pulses.removeWhere((timer) => !timer.isActive);
    for (var i = 0; i < times; i++) {
      _pulses.add(Timer(signalGap * i, () => unawaited(haptic())));
    }
  }

  /// `disconnected` stays until someone retries (spec §2.3).
  void _syncRetry() {
    final want = _active && _held && _connection == CarConnection.offline;
    if (!want) {
      _retry?.cancel();
      _retry = null;
    } else {
      _retry ??= Timer.periodic(retryEvery, (_) => unawaited(bridge.retry()));
    }
  }

  /// Called by the workspace before it sends a car-mode round. True: keep the
  /// draft and wait for the connection (spec §4.4).
  bool holdForConnection() {
    if (!_active) return false;
    final connection = bridge.read().connection;
    if (connection == CarConnection.ok) {
      if (_held) {
        // This send carries the held text with it.
        _held = false;
        _syncRetry();
        _log('WingCar release');
        notifyListeners();
      }
      return false;
    }
    _connectionChanged(connection);
    if (!_held) {
      _held = true;
      _log('WingCar hold');
    }
    _syncRetry();
    notifyListeners();
    return true;
  }

  Future<void> tap() async {
    if (!_active) return;
    final snap = bridge.read();
    final phase = carPhaseOf(snap, held: _held);
    final action = carTapActionFor(phase, snap);
    if (action == CarTapAction.ignore) {
      _log('WingCar tap phase=${phase.name} action=ignore');
      unawaited(HapticFeedback.vibrate());
      return;
    }
    if (!_gate.accept()) {
      _log('WingCar tap phase=${phase.name} action=debounced');
      return;
    }
    _log('WingCar tap phase=${phase.name} action=${action.name}');
    unawaited(HapticFeedback.heavyImpact());
    switch (action) {
      case CarTapAction.talk:
        if (phase == CarPhase.speaking) {
          final watch = Stopwatch()..start();
          await bridge.stopSpeech();
          _log('WingCar stopSpeech ms=${watch.elapsedMilliseconds}');
        }
        await bridge.talk();
      case CarTapAction.sendNow:
        await bridge.sendNow();
      case CarTapAction.ignore:
        break;
    }
  }

  /// Case 2 (Conversation mode off): rounds end by tap only (spec §4.2).
  VoicePreferences roundSettings(VoicePreferences settings) =>
      _active && !settings.conversation ? carTapOnlySettings(settings) : settings;

  /// Called by the workspace when a car-mode utterance is delivered.
  void logDelivery(CarDelivery delivery) {
    if (_active) _log('WingCar deliver kind=${delivery.name}');
  }

  /// The screen reports a finished horizontal drag (spec §4.8).
  void swiped({required bool exits}) {
    if (!_active) return;
    _log('WingCar swipe action=${exits ? 'exit' : 'short'}');
    if (exits) exit('swipe');
  }

  String _routeName() {
    try {
      return VoicePreferences.read(bridge.preferences).input.name;
    } on FormatException {
      return 'unknown';
    }
  }

  String _loopName() {
    try {
      return VoicePreferences.read(bridge.preferences).conversation ? 'on' : 'off';
    } on FormatException {
      return 'unknown';
    }
  }

  @override
  void dispose() {
    final route = _route;
    final navigator = _navigator;
    _end('disposed');
    if (route != null && navigator != null && route.isActive) {
      // The workspace is going away; take the car route with it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) navigator.removeRoute(route);
      });
    }
    _gate.dispose();
    super.dispose();
  }
}
```

ANNAHME: `VoicePreferences.read(SharedPreferences)` with `.input` and `.conversation` still exists after the upstream
merge (A7). If the merge replaced it, read the replacement type in `_routeName`, `_loopName` and
`carTapOnlySettings`. These are the only places.

Placeholder screen for this task. Task 5 replaces it:

```dart
// lib/car_mode/car_mode_screen.dart
import 'package:flutter/material.dart';

import 'car_mode_session.dart';

class CarModeScreen extends StatefulWidget {
  const CarModeScreen({super.key, required this.session});
  final CarModeSession session;

  @override
  State<CarModeScreen> createState() => _CarModeScreenState();
}

class _CarModeScreenState extends State<CarModeScreen> {
  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.expand());
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`.

- [ ] **Step 5: Commit**

```bash
git add lib/car_mode/car_mode_bridge.dart lib/car_mode/car_mode_session.dart lib/car_mode/car_mode_screen.dart test/car_mode/car_mode_bridge_test.dart test/car_mode/car_mode_session_test.dart
git commit -m "feat(car): car-mode session with screen-on, swipe/Back exit, connection hold and text-free log"
```

---

### Task 4: Snapshot adapter `carSnapshotOf` and `carActivityOf`

**Files:**
- Modify: `lib/car_mode/car_mode_bridge.dart` (append two functions, add imports)
- Test: no separate file. Both need a real `ProfileWorkspaceController` and `ProfileChat`, and that fixture lives in
  `test/voice_workspace_test.dart`. Task 6 exercises every field: listening, speaking, needs input (approval),
  working and activity (status line test), connection (offline test), chat key (exit). The mapping tables themselves
  are covered by Task 1 and Task 3 (`carConnectionOf`).

**Interfaces:**
- Consumes: `ProfileWorkspaceController` (`notificationChat`, `current?.chat`, `connectionStatus` (vo :474),
  `recovering` (vo :491)); `ProfileChat` (`key`, `title`, `busy` (:251), `status` (:221), `opening`, `offlineSnapshot`
  (:106), `approval` (:176), `clarification` (:187), `sensitivePrompt` (:188), `mainActivity` (:100),
  `mainToolActivity` (:101), `tool` (:125), `commandRunning` (:154)); `GatewayToolActivity` (`displayName`, vo
  `lib/core/models/gateway_activity.dart:42`); `VoiceInputController` (`phase`, `error`); `VoiceOutputController`
  (`owner` :54, `error`).
- Produces:
  - `CarSnapshot carSnapshotOf(ProfileWorkspaceController controller, VoiceInputController input, VoiceOutputController output)`
  - `String? carActivityOf(ProfileChat chat)`

- [ ] **Step 1: Write the implementation (fork types; A12 shows `ProfileTurnStatus`)**

Add to the imports of `lib/car_mode/car_mode_bridge.dart`:

```dart
import '../core/controllers/voice_input_controller.dart';
import '../core/controllers/voice_output_controller.dart';
import '../core/models/gateway_activity.dart';
import '../core/services/profile_workspace_controller.dart';
```

Append:

```dart
/// The only car code that reads chat and controller types; re-adapt this body
/// when the workspace types change (upstream merge).
CarSnapshot carSnapshotOf(
  ProfileWorkspaceController controller,
  VoiceInputController input,
  VoiceOutputController output,
) {
  final chat = controller.notificationChat ?? controller.current?.chat;
  return CarSnapshot(
    chatKey: chat?.key,
    title: chat?.title,
    input: input.phase,
    speaking: output.owner != null,
    working: chat?.busy ?? false,
    activity: chat == null ? null : carActivityOf(chat),
    needsInput:
        chat != null &&
        (chat.approval != null || chat.clarification != null || chat.sensitivePrompt != null),
    connection: carConnectionOf(
      controller.connectionStatus.phase,
      sendBlocked:
          controller.recovering || (chat?.opening ?? false) || (chat?.offlineSnapshot ?? false),
    ),
    error:
        input.error ??
        output.error ??
        (chat?.status == ProfileTurnStatus.failed ? 'Hermes could not finish this reply.' : null),
  );
}

/// Status line (spec §4.6): the kind of work or the tool's display name.
/// Never `detail`, arguments, commands or output.
String? carActivityOf(ProfileChat chat) {
  if (chat.commandRunning) return 'Command';
  return switch (chat.status) {
    ProfileTurnStatus.submitting => 'Sending',
    ProfileTurnStatus.running => switch (chat.mainActivity) {
      ProfileMainActivity.working => carWorking,
      ProfileMainActivity.thinking => 'Thinking',
      ProfileMainActivity.writing => 'Writing',
      ProfileMainActivity.tool =>
        chat.mainToolActivity?.displayName ??
            (chat.tool == null
                ? carWorking
                : GatewayToolActivity(
                    name: chat.tool!,
                    phase: GatewayToolActivityPhase.running,
                  ).displayName),
    },
    _ => null,
  };
}
```

**Upstream bodies** (use them if A12/A15 show `ChatExecution`/`ChatMainActivity`). Field names are from up
`lib/core/models/chat_runtime.dart` (`execution`, `mainActivity` :141, `mainToolActivity` :145, `needsInput` :163,
`executionActive` :165, `reconnecting` :170) and `ProfileChat.runtime` (up `profile_workspace_controller.dart:117`).
ANNAHME: `ChatRuntimeObservation` exposes `execution` and `commandRunning`. Check with
`git grep -n "final ChatExecution execution\|final bool commandRunning" -- lib/core/models/chat_runtime.dart`. If
`commandRunning` is missing, drop that line.

```dart
  final runtime = chat?.runtime;
  return CarSnapshot(
    chatKey: chat?.key,
    title: chat?.title,
    input: input.phase,
    speaking: output.owner != null,
    working: runtime != null && (runtime.executionActive || runtime.reconnecting),
    activity: chat == null ? null : carActivityOf(chat),
    needsInput: runtime?.needsInput ?? false,
    connection: carConnectionOf(
      controller.connectionStatus.phase,
      sendBlocked: controller.recovering || (runtime?.offline ?? false),
    ),
    error: input.error ?? output.error ??
        (runtime?.execution == ChatExecution.failed ? 'Hermes could not finish this reply.' : null),
  );
```

```dart
String? carActivityOf(ProfileChat chat) {
  final runtime = chat.runtime;
  if (runtime.commandRunning) return 'Command';
  if (runtime.execution == ChatExecution.submitting) return 'Sending';
  if (runtime.execution != ChatExecution.running) return null;
  return switch (runtime.mainActivity) {
    ChatMainActivity.working => carWorking,
    ChatMainActivity.thinking => 'Thinking',
    ChatMainActivity.writing => 'Writing',
    ChatMainActivity.tool => runtime.mainToolActivity?.displayName ?? carWorking,
  };
}
```

ANNAHME: `controller.recovering` survives the merge. Check with
`git grep -n "bool get recovering" -- lib/core/services/profile_workspace_controller.dart`. If it is missing, use
`runtime?.offline` alone.

- [ ] **Step 2: Run analyze/tests**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`. The new functions are not used yet; analyze must stay clean.

- [ ] **Step 3: Commit**

```bash
git add lib/car_mode/car_mode_bridge.dart
git commit -m "feat(car): snapshot and activity adapter from the chat workspace"
```

---

### Task 5: Car-mode screen (one full-screen button)

**Files:**
- Modify: `lib/car_mode/car_mode_screen.dart` (replace the placeholder)
- Modify: `.github/workflows/voice-review.yml` (render list, vo :34-35)
- Test: `test/car_mode/car_mode_screen_test.dart`

**Interfaces:**
- Consumes: `CarModeSession` (`phase`, `snapshot`, `tap()`, `swiped(exits:)`, `exit(String)`, `bridge.preferences`),
  `carTextFor`, `carIconFor`, `carStatusLine`, `carConnectionText`, `carSwipeExits`, `carColorsFor`,
  `carBadgeColorsFor`, `profileWorkspaceTheme(ThemeData, accent:)` (vo `profile_workspace_theme.dart:22`),
  `WorkspaceAccent.fromName` (:18), `WorkspaceAccent.preferenceKey` (:17), `WingTokens.of(context)` (vo
  `wing_theme.dart:215`).
- Produces (keys used by tests in Task 6):
  - `ValueKey('car-button')`: the full-screen button
  - `ValueKey('car-connection')`: the connection badge (drawn on the button)
  - `ValueKey('car-status')`: the status line text
  - `ValueKey('car-swipe-hint')`: the 6 s hint

Design rules (spec §4.6, mockup and screenshots):
- **Button:** fills the `SafeArea` with an 8 dp inset (none at the top), 28 dp corners. Everything is drawn on it.
- **Portrait:** top strip 56 dp (badge left, title right, 16 sp), 28 dp gap, status line 48 dp slot (34 sp w600).
  The centre (icon 120, label 44 sp w600, hint 22 sp) fills the rest. A 28 dp bottom slot holds the swipe hint.
- **Landscape:** top strip 56 dp with the badge left, status line middle (30 sp), title right. Then the centre row:
  icon 112 + texts (label 40 sp). A 24 dp hint slot.
- **Drag:** horizontal drag only; content follows at 35 % of `dx`; `DragStartBehavior.down`, so `dx` counts from
  touch-down (spec §4.8).
- **Pulse:** a pulsing ring only while listening, static with `MediaQuery.disableAnimationsOf`.
- **Never:** transcript, reply, held text, tool arguments, timers (spec §4.5).

- [ ] **Step 1: Write the failing test**

```dart
// test/car_mode/car_mode_screen_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/car_mode/car_mode_bridge.dart';
import 'package:wing/car_mode/car_mode_screen.dart';
import 'package:wing/car_mode/car_mode_session.dart';
import 'package:wing/car_mode/car_mode_state.dart';
import 'package:wing/core/controllers/voice_input_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import '../support/voice_fixture.dart';

class _World extends ChangeNotifier {
  CarSnapshot snapshot = const CarSnapshot(chatKey: 'chat', title: 'Weekend trip');
  final calls = <String>[];
  void set(CarSnapshot next) {
    snapshot = next;
    notifyListeners();
  }
}

void main() {
  const capture = bool.fromEnvironment('VOICE_REVIEW');
  const frame = Key('car-frame');
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

  late VoiceDeviceFixture device;
  late _World world;
  late List<String> logs;
  late CarModeSession session;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    device = VoiceDeviceFixture();
    world = _World();
    logs = [];
    session = CarModeSession(
      device: device,
      log: logs.add,
      bridge: CarModeBridge(
        changes: world,
        read: () => world.snapshot,
        preferences: prefs,
        talk: () async => world.calls.add('talk'),
        sendNow: () async => world.calls.add('sendNow'),
        stopSpeech: () async => world.calls.add('stopSpeech'),
        retry: () async => world.calls.add('retry'),
        sendHeld: () async => world.calls.add('sendHeld'),
        leave: () => world.calls.add('leave'),
      ),
    );
  });
  tearDown(() async {
    session.dispose();
    await device.stream.close();
  });

  Future<void> show(
    WidgetTester tester, {
    Size size = const Size(411, 960),
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: wingTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: RepaintBoundary(key: frame, child: child!),
      ),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => session.enter(context),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

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

  Future<void> close(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 700));
    session.exit('test');
    await tester.pumpAndSettle();
  }

  Finder button() => find.byKey(const ValueKey('car-button'));

  const states = {
    'idle': CarSnapshot(chatKey: 'chat', title: 'Weekend trip'),
    'listening': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', input: VoiceInputPhase.recording),
    'transcribing': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', input: VoiceInputPhase.transcribing),
    'thinking': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', working: true, activity: 'Terminal'),
    'speaking': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', speaking: true),
    'attention': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', needsInput: true),
    'error': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', error: 'No speech detected. Try again.'),
    'offline': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', connection: CarConnection.offline),
  };

  for (final MapEntry(key: name, value: snap) in states.entries) {
    testWidgets('$name renders its label, icon and connection', (tester) async {
      world.snapshot = snap;
      await show(tester);
      final phase = carPhaseOf(snap);
      expect(find.text(carTextFor(phase, snap).label), findsOneWidget);
      expect(find.byIcon(carIconFor(phase)), findsOneWidget);
      expect(find.text(carConnectionText(snap.connection).label), findsOneWidget);
      expect(find.text('Weekend trip'), findsOneWidget);
      await close(tester);
    });
  }

  testWidgets('waiting shows the held state; the status line shows the tool name', (tester) async {
    world.snapshot = const CarSnapshot(chatKey: 'chat', connection: CarConnection.offline);
    await show(tester);
    session.holdForConnection();
    await tester.pump();
    expect(find.text('Waiting for connection'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    world.set(const CarSnapshot(chatKey: 'chat', working: true, activity: 'Terminal'));
    await tester.pump();
    expect(find.text('Terminal'), findsOneWidget);
    await close(tester);
  });

  testWidgets('the button is the whole screen; badge and status line count as button', (tester) async {
    world.snapshot = const CarSnapshot(chatKey: 'chat', working: true, activity: 'Terminal');
    await show(tester);
    final rect = tester.getRect(button());
    expect(rect.width * rect.height, greaterThan(411 * 960 * .9));
    await tester.tap(find.byKey(const ValueKey('car-connection')));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.tap(find.byKey(const ValueKey('car-status')));
    await tester.pump(const Duration(milliseconds: 700));
    expect(world.calls, ['talk', 'talk']);
    await close(tester);
  });

  testWidgets('a swipe exits and never starts a round', (tester) async {
    await show(tester);
    await tester.drag(button(), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(session.active, isFalse);
    expect(find.byType(CarModeScreen), findsNothing);
    expect(world.calls, ['leave']);
    expect(logs, contains('WingCar swipe action=exit'));
    expect(logs.where((l) => l.startsWith('WingCar tap')), isEmpty);
  });

  testWidgets('a swipe while listening exits without sending', (tester) async {
    world.snapshot = const CarSnapshot(chatKey: 'chat', input: VoiceInputPhase.recording);
    await show(tester);
    await tester.drag(button(), const Offset(220, 0));
    await tester.pumpAndSettle();
    expect(world.calls, ['leave']);
    expect(world.calls, isNot(contains('sendNow')));
  });

  testWidgets('a short slide or a vertical wobble is neither a tap nor an exit', (tester) async {
    await show(tester);
    await tester.drag(button(), const Offset(40, 0));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.drag(button(), const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 700));
    expect(session.active, isTrue);
    expect(world.calls, isEmpty);
    expect(logs, contains('WingCar swipe action=short'));
    await close(tester);
  });

  testWidgets('Back leaves directly', (tester) async {
    await show(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(session.active, isFalse);
    expect(find.byType(CarModeScreen), findsNothing);
    expect(world.calls, ['leave']);
  });

  testWidgets('the swipe hint shows for 6 s, the title stays', (tester) async {
    await show(tester);
    expect(find.byKey(const ValueKey('car-swipe-hint')), findsOneWidget);
    expect(find.text('Swipe to leave'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 6100));
    expect(find.text('Swipe to leave'), findsNothing);
    expect(find.text('Weekend trip'), findsOneWidget);
    await close(tester);
  });

  for (final brightness in Brightness.values) {
    for (final size in const [Size(411, 960), Size(960, 411), Size(320, 640)]) {
      for (final scale in const [1.0, 2.0]) {
        final tag = '${brightness.name}-${size.width.toInt()}x${size.height.toInt()}-${(scale * 100).toInt()}';
        testWidgets('all phases fit $tag', (tester) async {
          await show(tester, size: size, brightness: brightness, scale: scale);
          for (final MapEntry(key: name, value: snap) in states.entries) {
            world.set(snap);
            await tester.pump();
            expect(tester.takeException(), isNull, reason: name);
            final badge = tester.getSize(find.byKey(const ValueKey('car-connection')));
            expect(badge.height, greaterThanOrEqualTo(48));
            if (size.width == 411 || size.width == 960) {
              await screenshot(tester, 'car-$name-$tag');
            }
          }
          await close(tester);
        });
      }
    }
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=failure`, `  failed step: Run tests`. The placeholder renders no label or keys.

- [ ] **Step 3: Write the implementation**

```dart
// lib/car_mode/car_mode_screen.dart
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/theme/profile_workspace_theme.dart';
import '../core/theme/wing_theme.dart';
import 'car_mode_palette.dart';
import 'car_mode_session.dart';
import 'car_mode_state.dart';

/// Fullscreen car mode: the whole screen is one button over the open chat
/// (spec §4). Android Back pops the route; the session leaves on pop.
class CarModeScreen extends StatefulWidget {
  const CarModeScreen({super.key, required this.session});
  final CarModeSession session;

  @override
  State<CarModeScreen> createState() => _CarModeScreenState();
}

class _CarModeScreenState extends State<CarModeScreen> {
  static const _hintFor = Duration(seconds: 6);
  bool _hint = true;
  Timer? _hintTimer;
  double _dragDx = 0;

  @override
  void initState() {
    super.initState();
    _hintTimer = Timer(_hintFor, () {
      if (mounted) setState(() => _hint = false);
    });
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The pushed route sits outside the workspace's accent theme.
    final theme = profileWorkspaceTheme(
      Theme.of(context),
      accent: WorkspaceAccent.fromName(
        widget.session.bridge.preferences.getString(WorkspaceAccent.preferenceKey),
      ),
    );
    return Theme(
      data: theme,
      child: ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) => _page(context),
      ),
    );
  }

  Widget _page(BuildContext context) {
    final tokens = WingTokens.of(context);
    final session = widget.session;
    final snap = session.snapshot;
    final phase = session.phase;
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final width = MediaQuery.sizeOf(context).width;
    final colors = carColorsFor(phase, tokens, Theme.of(context).brightness);
    final text = carTextFor(phase, snap);
    final status = carStatusLine(phase, snap);
    final connection = carConnectionText(snap.connection);
    return Scaffold(
      backgroundColor: tokens.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Semantics(
            button: true,
            liveRegion: true,
            label: [text.label, text.detail, text.hint, status, connection.label]
                .whereType<String>()
                .join('. '),
            hint: 'Swipe sideways to leave car mode',
            excludeSemantics: true,
            onTap: session.tap,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              dragStartBehavior: DragStartBehavior.down,
              onHorizontalDragUpdate: (details) =>
                  setState(() => _dragDx += details.primaryDelta ?? 0),
              onHorizontalDragEnd: (details) {
                final exits = carSwipeExits(
                  dx: _dragDx,
                  velocity: details.primaryVelocity ?? 0,
                  width: width,
                );
                setState(() => _dragDx = 0);
                session.swiped(exits: exits);
              },
              onHorizontalDragCancel: () => setState(() => _dragDx = 0),
              child: Material(
                key: const ValueKey('car-button'),
                color: colors.fill,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                  side: colors.border == null
                      ? BorderSide.none
                      : BorderSide(color: colors.border!, width: 4),
                ),
                child: InkWell(
                  onTap: session.tap,
                  child: Transform.translate(
                    offset: Offset(_dragDx * .35, 0),
                    child: Padding(
                      padding: landscape
                          ? const EdgeInsets.fromLTRB(20, 16, 20, 12)
                          : const EdgeInsets.fromLTRB(20, 20, 20, 16),
                      child: _content(context, phase, snap, colors, text, status, landscape, width),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    CarPhase phase,
    CarSnapshot snap,
    CarColors colors,
    CarText text,
    String? status,
    bool landscape,
    double width,
  ) {
    final tokens = WingTokens.of(context);
    final badge = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: landscape ? 260 : width * .6),
      child: _Badge(connection: snap.connection, colors: carBadgeColorsFor(snap.connection, tokens)),
    );
    final title = Text(
      snap.title ?? '',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.end,
      style: TextStyle(fontSize: 16, color: colors.hint),
    );
    final statusLine = _fitLine(
      Text(
        status ?? '',
        key: const ValueKey('car-status'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: landscape ? 30 : 34,
          fontWeight: FontWeight.w600,
          height: 1.25,
          color: colors.label,
        ),
      ),
    );
    final hint = _hint
        ? Row(
            key: const ValueKey('car-swipe-hint'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.swap_horiz, size: 22, color: colors.hint),
              const SizedBox(width: 8),
              Text('Swipe to leave', style: TextStyle(fontSize: 16, color: colors.hint)),
            ],
          )
        : null;
    final centre = LayoutBuilder(
      builder: (context, box) => Center(
        // Enlarged text scales down instead of overflowing the button.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: _centre(phase, colors, text, landscape, box.maxWidth),
        ),
      ),
    );
    if (landscape) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 56,
            child: Row(
              children: [
                badge,
                const SizedBox(width: 16),
                Expanded(child: statusLine),
                const SizedBox(width: 16),
                ConstrainedBox(constraints: const BoxConstraints(maxWidth: 220), child: title),
              ],
            ),
          ),
          Expanded(child: centre),
          SizedBox(height: 24, child: FittedBox(fit: BoxFit.scaleDown, child: hint)),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 56,
          child: Row(children: [badge, const SizedBox(width: 12), Expanded(child: title)]),
        ),
        const SizedBox(height: 28),
        SizedBox(height: 48, child: statusLine),
        Expanded(child: centre),
        SizedBox(height: 28, child: FittedBox(fit: BoxFit.scaleDown, child: hint)),
      ],
    );
  }

  /// One line: ellipsised to the width, scaled down to the slot height.
  Widget _fitLine(Text text) => LayoutBuilder(
    builder: (context, box) => Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: box.maxWidth), child: text),
      ),
    ),
  );

  Widget _centre(CarPhase phase, CarColors colors, CarText text, bool landscape, double maxWidth) {
    final iconSize = landscape ? 112.0 : 120.0;
    final icon = SizedBox.square(
      dimension: iconSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (phase == CarPhase.listening) _Pulse(color: colors.label),
          Icon(carIconFor(phase), size: iconSize * .8, color: colors.label),
        ],
      ),
    );
    final align = landscape ? TextAlign.start : TextAlign.center;
    final texts = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: landscape ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Text(
          text.label,
          textAlign: align,
          style: TextStyle(
            fontSize: landscape ? 40 : 44,
            fontWeight: FontWeight.w600,
            height: 1.1,
            color: colors.label,
          ),
        ),
        if (text.detail != null) ...[
          const SizedBox(height: 10),
          Text(text.detail!, textAlign: align, style: TextStyle(fontSize: 20, color: colors.hint)),
        ],
        if (text.hint != null) ...[
          const SizedBox(height: 10),
          Text(text.hint!, textAlign: align, style: TextStyle(fontSize: 22, color: colors.hint)),
        ],
      ],
    );
    if (landscape) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 36),
          ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth * .6), child: texts),
        ],
      );
    }
    return SizedBox(
      width: maxWidth,
      child: Column(mainAxisSize: MainAxisSize.min, children: [icon, const SizedBox(height: 18), texts]),
    );
  }
}

/// Large coloured connection state, readable from the corner of the eye.
class _Badge extends StatelessWidget {
  const _Badge({required this.connection, required this.colors});
  final CarConnection connection;
  final CarBadgeColors colors;

  @override
  Widget build(BuildContext context) {
    final text = carConnectionText(connection);
    return Container(
      key: const ValueKey('car-connection'),
      height: 56,
      padding: const EdgeInsets.fromLTRB(14, 0, 18, 0),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: colors.foreground, width: 3),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(text.icon, size: 28, color: colors.foreground),
            const SizedBox(width: 8),
            Text(
              text.label,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: colors.foreground),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Microphone is live" ring; exists only while listening. Static with
/// reduced motion.
class _Pulse extends StatefulWidget {
  const _Pulse({required this.color});
  final Color color;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller
        ..stop()
        ..value = .35;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) {
      final t = _controller.value;
      return Transform.scale(
        scale: .7 + .55 * t,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: widget.color.withValues(alpha: .55 * (1 - t)), width: 6),
          ),
          child: const SizedBox.expand(),
        ),
      );
    },
  );
}
```

Add the screen test to the render list in `.github/workflows/voice-review.yml` (vo lines 34-35):

```yaml
          flutter test --no-pub --dart-define=VOICE_REVIEW=true --dart-define=CAPTURE_FONT_DIR="$fonts" \
            test/voice_preferences_test.dart test/vad_settings_test.dart test/voice_workspace_test.dart \
            test/car_mode/car_mode_screen_test.dart
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`.

If "a short slide or a vertical wobble" fails because the vertical drag reached the `InkWell` as a tap, check that the
`TapGestureRecognizer`'s slop rejection applies (`kTouchSlop` 18 dp, `preAcceptSlopTolerance`). Do **not** loosen the
test. Wrap the `InkWell` in a `GestureDetector(onVerticalDragStart: (_) {})`: a vertical recognizer then wins the
arena for vertical movement and the tap loses.

- [ ] **Step 5: Commit**

```bash
git add lib/car_mode/car_mode_screen.dart test/car_mode/car_mode_screen_test.dart .github/workflows/voice-review.yml
git commit -m "feat(car): full-screen car-mode button with status line, connection badge and swipe to leave"
```

---

### Task 6: Workspace hooks (entry, focus, read-aloud, case 2 round, tap-send, hold)

**Files:**
- Modify: `lib/core/screens/profile_workspace_screen.dart`. vo anchors:
  - imports (top);
  - fields after `_voiceDeviceEvents` (:178);
  - `_speakCompletedReply` (:245);
  - `_sendConversationTurn` (:301);
  - `_dictate` (:393, :401, :402, :411);
  - `didChangeDependencies` (:561);
  - `dispose` (:651);
  - Chat actions menu (`onSelected` :982-1022, `itemBuilder` :1023-1047).
- Test: `test/voice_workspace_test.dart`. New tests go at the end of `main`, after `vadStarts`/`vadRoute`/`windows`
  (vo :453-461). They use its helpers `show` (:95), `settle` (:260), `starts` (:243), `prompts` (:244), `gatewayEvent`
  (:245), `conversationMode` (:252), `completeReply` (:272).

**Interfaces:**
- Consumes: `CarModeSession`, `CarModeBridge`, `carSnapshotOf` (Tasks 3-4).
- Produces: workspace field `_car` (`CarModeSession`) and `bool _carSend`. Task 7 uses `_car.active` and
  `_car.logDelivery`.

- [ ] **Step 1: Write the failing tests**

Add at the top of `test/voice_workspace_test.dart`:

```dart
import 'package:wing/car_mode/car_mode_screen.dart';
import 'package:wing/core/services/server_connection_status.dart';
```

Append inside `main()`, after the last test:

```dart
  // Car mode: the whole screen is one button over the chat (docs/CAR_MODE.md).
  Finder carButton() => find.byKey(const ValueKey('car-button'));
  Future<void> openCarMode(WidgetTester tester) async {
    // Car mode holds sends unless the server counts as connected.
    controller.connectionStatus
      ..accessAvailable()
      ..liveChanged('car-test', true);
    await tester.pump();
    expect(controller.connectionStatus.phase, ServerConnectionPhase.connected);
    await tester.tap(find.byTooltip('Chat actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Car mode'));
    await tester.pumpAndSettle();
  }

  Future<void> tapCar(WidgetTester tester) async {
    await tester.tap(carButton());
    // Past the 600 ms debounce; lets async voice work run.
    await tester.pump(const Duration(milliseconds: 350));
    await settle(tester);
  }

  Future<void> swipeOut(WidgetTester tester) async {
    await tester.drag(carButton(), const Offset(-250, 0));
    await settle(tester);
  }

  testWidgets('car mode case 2: three rounds by tap only, read aloud, then idle with the mic closed', (
    tester,
  ) async {
    await vadRoute();
    await conversationMode(false);
    await show(tester);
    await openCarMode(tester);
    expect(find.byType(CarModeScreen), findsOneWidget);
    expect(find.text('Tap to talk'), findsOneWidget);
    expect(device.keepScreenOnCalls, [true]);
    for (var round = 1; round <= 3; round++) {
      await tapCar(tester); // tap = start recording
      expect(vadStarts(), round);
      expect(find.text('Listening'), findsOneWidget);
      await windows(tester, 0.9, 30);
      await windows(tester, 0.1, 200); // 6.4 s of silence: no automatic end in case 2
      expect(device.finishes, hasLength(round - 1));
      expect(prompts(), round - 1);
      await tapCar(tester); // tap = stop and send
      expect(device.finishes.last.reason.name, 'mediaKey');
      expect(prompts(), round);
      await completeReply(tester, 'Answer $round.');
      expect(device.spoken, 'Answer $round.'); // read aloud although Spoken replies is off
      expect(vadStarts(), round); // the microphone stays closed
      expect(find.text('Tap to talk'), findsOneWidget);
    }
    expect(controller.preferences.getString(VoicePreferences.conversationKey), 'off');
    expect(controller.preferences.getString(VoicePreferences.autoSpeakKey), isNot('on'));
    await swipeOut(tester);
    expect(find.byType(CarModeScreen), findsNothing);
    expect(device.keepScreenOnCalls.last, isFalse);
  });

  testWidgets('car mode case 1: the loop runs; a tap while listening sends at once', (tester) async {
    await conversationMode(true); // local route (default)
    await show(tester);
    await openCarMode(tester);
    await tapCar(tester);
    expect(starts(), 1);
    final id = device.recording;
    await tapCar(tester); // end of speech not detected: the tap sends now
    device.stream.add({'id': id, 'text': 'Question', 'final': true});
    await settle(tester);
    expect(prompts(), 1);
    await completeReply(tester, 'Answer.');
    expect(device.spoken, 'Answer.');
    expect(starts(), 2); // the saved loop reopened the microphone
    expect(find.text('Listening'), findsOneWidget);
    await swipeOut(tester);
    expect(device.recording, isNull);
  });

  testWidgets('car mode: a tap during read-aloud stops it, then opens the microphone', (tester) async {
    device.playbackDelay = Completer<void>();
    await show(tester);
    await openCarMode(tester);
    await tapCar(tester);
    final id = device.recording;
    await tapCar(tester);
    device.stream.add({'id': id, 'text': 'Question', 'final': true});
    await settle(tester);
    gatewayEvent('message.complete', {'text': 'A long answer.'});
    await tester.pump();
    await tester.pump();
    expect(find.text('Reading aloud'), findsOneWidget);
    device.calls.clear();
    await tapCar(tester);
    expect(device.calls, contains('stopPlayback'));
    expect(device.calls.indexOf('stopPlayback'), lessThan(device.calls.indexOf('start')));
    expect(find.text('Listening'), findsOneWidget);
    device.playbackDelay!.complete();
    device.playbackDelay = null;
    await swipeOut(tester);
  });

  testWidgets('car mode: focus stays under the car route (media keys on)', (tester) async {
    await vadRoute();
    await show(tester);
    await openCarMode(tester);
    expect(device.mediaKeysCalls, [true]);
    await tapCar(tester);
    await windows(tester, 0.9, 30);
    await tapCar(tester);
    expect(prompts(), 1);
    expect(device.mediaKeysCalls, [true]);
    gatewayEvent('message.complete', {'text': 'Done.'});
    await settle(tester);
    await swipeOut(tester);
  });

  testWidgets('car mode: a swipe exit cancels the recording and keeps the draft', (tester) async {
    final chat = controller.current!.chat!;
    await controller.updateDraft(chat, 'Typed before');
    await show(tester);
    await openCarMode(tester);
    await tapCar(tester);
    final id = device.recording;
    await swipeOut(tester);
    expect(find.byType(CarModeScreen), findsNothing);
    expect(device.cancelled, contains(id));
    expect(chat.draft, 'Typed before');
    expect(prompts(), 0);
  });

  testWidgets('car mode: the status line shows the running tool by name only', (tester) async {
    await show(tester);
    await openCarMode(tester);
    gatewayEvent('message.start');
    gatewayEvent('tool.start', {'name': 'terminal', 'tool_id': 't1', 'context': 'rm -rf /tmp/secret'});
    await settle(tester);
    expect(find.text('Hermes is working'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.textContaining('secret'), findsNothing);
    gatewayEvent('message.complete', {'text': 'Done.'});
    await settle(tester);
    await swipeOut(tester);
  });

  testWidgets('car mode: a recording finished offline waits and is sent once after reconnect', (
    tester,
  ) async {
    await vadRoute();
    await show(tester);
    await openCarMode(tester);
    await tapCar(tester);
    controller.connectionStatus.failRecovery('car-test', 'Offline');
    await settle(tester);
    expect(find.text('Offline'), findsOneWidget);
    await windows(tester, 0.9, 30); // recording goes on offline
    await tapCar(tester);
    expect(prompts(), 0);
    expect(find.text('Waiting for connection'), findsOneWidget);
    expect(controller.current!.chat!.draft, 'Hello from the phone'); // kept on the device
    controller.connectionStatus.endRecovery('car-test');
    await settle(tester);
    expect(prompts(), 1);
    expect(
      fixture.calls.lastWhere((c) => c.$2 == 'prompt.submit').$3['text'],
      'Hello from the phone',
    );
    controller.connectionStatus.liveChanged('car-test', true); // more notifications
    await settle(tester);
    expect(prompts(), 1);
    await completeReply(tester, 'Got it.');
    expect(device.spoken, 'Got it.');
    await swipeOut(tester);
  });

  testWidgets('car mode: a pending approval shows on screen and the tap does nothing', (tester) async {
    await show(tester);
    await openCarMode(tester);
    gatewayEvent('approval', {'request_id': 'approve-1', 'command': 'rm -rf build'});
    await settle(tester);
    expect(find.text('Needs you on screen'), findsOneWidget);
    await tapCar(tester);
    expect(starts(), 0);
    expect(fixture.calls.where((c) => c.$2.contains('approval')), isEmpty);
    await swipeOut(tester);
  });
```

ANNAHME (connection fixture): after `accessAvailable()` and `liveChanged('car-test', true)` the fixture reports
`connected`. The `expect` in `openCarMode` proves it. If it reports `limited`, another live owner is unavailable. Find
it with `git grep -n "liveChanged(" -- lib test/support`, and set that owner to `true` in `openCarMode` too. Do not
change the shared fixture.

ANNAHME (playback): the fixture's `speak` resolves at once without `playbackDelay`, so `device.spoken` is set and
`owner` is null again right after `completeReply`. The existing conversation tests use the same pattern (vo
`test/voice_workspace_test.dart:440-447`).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=failure`, `  failed step: Run tests` (there is no 'Car mode' menu item).

- [ ] **Step 3: Implement the hooks** (vo lines; re-check them with Basis A6-A9)

3a. Imports, after the other relative imports at the top:

```dart
import '../../car_mode/car_mode_bridge.dart';
import '../../car_mode/car_mode_session.dart';
import '../../car_mode/car_mode_state.dart';
```

(`car_mode_state.dart` is needed by Task 7. If the analyzer reports it as unused after this task, add it in Task 7.)

3b. Fields, directly after `StreamSubscription<Map<String, dynamic>>? _voiceDeviceEvents;` (vo :178):

```dart
  /// Car mode (docs/CAR_MODE.md). [_carSend] makes the next transcript count
  /// as hands-free, so the big button sends on every input route.
  bool _carSend = false;
  late final _car = CarModeSession(
    device: _voiceDevice,
    bridge: CarModeBridge(
      changes: Listenable.merge([controller, controller.connectionStatus, _voiceInput, _voiceOutput]),
      read: () => carSnapshotOf(controller, _voiceInput, _voiceOutput),
      preferences: controller.preferences,
      talk: () async {
        final chat = controller.notificationChat ?? controller.current?.chat;
        if (chat != null) await _run(() => _dictate(chat));
      },
      sendNow: () {
        _carSend = true;
        return _voiceInput.stopHandsFree();
      },
      stopSpeech: _voiceOutput.stop,
      retry: () => _run(controller.resumeConnection),
      sendHeld: () async {
        final chat = controller.notificationChat ?? controller.current?.chat;
        if (chat == null) return;
        _conversation = chat.key;
        await _run(() => _sendConversationTurn(chat));
      },
      leave: _cancelVoice,
    ),
  );
```

3c. Read every reply aloud in car mode (vo :245, inside `_speakCompletedReply`):

```dart
    if (!(settings.autoSpeak || settings.conversation || _car.active) ||
        _voiceInput.active) {
```

Leave vo :244 (`if (!settings.conversation) _conversation = null;`) and vo :293 unchanged. They keep the loop on the
saved setting, so in case 2 the microphone stays closed after read-aloud.

3d. In `_dictate`, directly after `await _voiceOutput.stop();` (vo :393):

```dart
    _carSend = false;
```

Replace vo :401-402:

```dart
    final settings = _car.roundSettings(
      VoicePreferences.read(controller.preferences),
    );
    _conversation = settings.conversation || _car.active ? chat.key : null;
```

and vo :411:

```dart
      final send =
          _conversation == chat.key && (_voiceInput.finishedOnItsOwn || _carSend);
```

`_carSend` is set by the bridge **after** the round started, so the reset above never clears a pending tap.

3e. Hold while offline, in `_sendConversationTurn`, directly after `final text = chat.draft.trim();` (vo :301):

```dart
    // Car mode: offline, the draft waits on the device (spec §4.4).
    if (_conversation == chat.key && text.isNotEmpty && _car.holdForConnection()) {
      return;
    }
```

3f. Focus, in `didChangeDependencies` (vo :561):

```dart
    _routeIsCurrent = isCurrent || _car.active;
```

3g. Menu: in `onSelected` (vo :982-1022), before `} else if (action == 'parent') {`:

```dart
                  } else if (action == 'car') {
                    unawaited(_car.enter(context));
```

In `itemBuilder` (vo :1023-1047), before the `'refresh'` item:

```dart
                  const PopupMenuItem(value: 'car', child: Text('Car mode')),
```

(After the upstream merge: `const StudioPopupMenuItem(value: 'car', child: Text('Car mode')),` before
`const PopupMenuDivider(),`, up `:1507-1550`.)

3h. `dispose` (vo :651): first line of the method body:

```dart
    _car.dispose();
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`. All existing conversation, media-key and screen-on tests must stay green:
- "without conversation mode a final dictation is never sent" is unchanged: car mode is not open there;
- "vad conversation sends after the pause" still ends with reason `pause`: `roundSettings` returns the settings
  unchanged outside car mode;
- "a running conversation keeps the screen on" still expects `[true, false]`.

- [ ] **Step 5: Count the hook lines and commit**

Run: `git diff --stat -- lib/core/screens/profile_workspace_screen.dart`
Expected: about `1 file changed, ~53 insertions(+), ~5 deletions(-)` (with formatter line breaks). Record the exact
numbers in the commit body. **Acceptance limit: ≤ 60 insertions.** More means something that belongs in
`lib/car_mode/` landed in the screen; move it out (e.g. the bridge closures into a `CarModeBridge` factory taking the
workspace callbacks).

```bash
git add lib/core/screens/profile_workspace_screen.dart test/voice_workspace_test.dart
git commit -m "feat(car): car mode entry and hooks in the chat workspace"
```

---

### Task 7: Speaking while Hermes works steers the running turn (shared hook with barge-in)

**Files:**
- Modify: `lib/core/screens/profile_workspace_screen.dart`, `_sendConversationTurn` (vo :300-322)
- Test: `test/voice_workspace_test.dart`

**Interfaces:**
- Consumes: `_car.active`, `_car.logDelivery(CarDelivery)`, `carDeliveryFor(...)` (Task 1), `_composerActions`,
  `_performComposerAction(chat, action, conversation: true)` (vo :2218, :2287).
- Produces: nothing new. When barge-in (t_7e81e040) lands later, its `decideDelivery` hook in the same method replaces
  this block. The barge-in coder must then delete `carDeliveryFor` and this block, and keep the `_car.logDelivery(...)`
  calls. The code comment below says so.

- [ ] **Step 1: Write the failing test**

```dart
  testWidgets('car mode: speech during a running turn is steered into it', (tester) async {
    await show(tester);
    await openCarMode(tester);
    await tapCar(tester);
    var id = device.recording;
    await tapCar(tester);
    device.stream.add({'id': id, 'text': 'Plan the trip', 'final': true});
    await settle(tester);
    expect(prompts(), 1);
    controller.current!.chat!.status = ProfileTurnStatus.running;
    await tapCar(tester); // thinking → microphone (tap while working, option A)
    id = device.recording;
    expect(id, isNotNull);
    await tapCar(tester);
    device.stream.add({'id': id, 'text': 'Also the weather', 'final': true});
    await settle(tester);
    expect(prompts(), 1);
    expect(
      fixture.calls.where((c) => c.$2 == 'session.steer').single.$3['text'],
      'Also the weather',
    );
    await swipeOut(tester);
  });
```

ANNAHME: `ProfileBrowserFixture` answers `session.steer` with `{}` (default branch, vo
`test/support/profile_browser_fixture.dart:249`). So `controller.steer` records the call and then throws
`FormatException('Unsupported steering response.')`, which `_runValue` shows as a snackbar. The test only asserts the
recorded call. Do not change the shared fixture.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=failure`, `  failed step: Run tests`. Without the hook, `_sendConversationTurn` ends on
`chat.busy` (vo :306), so no `session.steer` call is made.

- [ ] **Step 3: Implement** (skip this step if Basis A13 found `decideDelivery`; then barge-in already steers)

In `_sendConversationTurn`, directly after the hold hook from Task 6 step 3e:

```dart
    // Car mode: speech while Hermes works steers the running turn (spec §6.4).
    // Barge-in (t_7e81e040) replaces this block with its decideDelivery hook;
    // keep the _car.logDelivery call when it does.
    if (_car.active &&
        mounted &&
        chat.busy &&
        _conversation == chat.key &&
        text.isNotEmpty &&
        !text.startsWith('/')) {
      final actions = _composerActions(chat);
      final delivery = carDeliveryFor(
        working: true,
        steerAvailable: actions[ComposerAction.steer] == null,
        queueAvailable: actions[ComposerAction.queue] == null,
      );
      _car.logDelivery(delivery);
      if (delivery != CarDelivery.end) {
        _conversationAwaitingReply = true;
        await _performComposerAction(
          chat,
          delivery == CarDelivery.steer ? ComposerAction.steer : ComposerAction.queue,
          conversation: true,
        );
        return;
      }
    }
```

Directly before `_conversationAwaitingReply = true;` (vo :313):

```dart
    _car.logDelivery(CarDelivery.send);
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`.

- [ ] **Step 5: Count and commit**

Run: `git diff --stat main...HEAD -- lib/core/screens/profile_workspace_screen.dart`
Expected: about `~77 insertions(+), ~5 deletions(-)` for Tasks 6 + 7 together (use the branch's merge base instead of
`main` if the branch was cut elsewhere). **Acceptance limit: ≤ 90 insertions in total.** Record the number in the
commit body.

```bash
git add lib/core/screens/profile_workspace_screen.dart test/voice_workspace_test.dart
git commit -m "feat(car): steer the running turn with speech from car mode"
```

---

### Task 8: Docs, rendered-screen review, APK build

**Files:**
- Create: `docs/CAR_MODE.md`
- Modify: `docs/VOICE.md` (one link line at the end of its overview)

- [ ] **Step 1: Write `docs/CAR_MODE.md`**

```markdown
# Car mode

Open a chat → ⋮ → **Car mode**. The whole screen becomes one button for the open chat. The screen stays on until
you leave; that is part of car mode, not an option.

**Conversation mode off (the usual car mode):** tap to start recording, tap again to send. There is no automatic end
of speech. Every reply is read aloud; afterwards the microphone stays closed until you tap.
**Conversation mode on:** the conversation loop runs as usual; a tap while listening sends at once.
Car mode never changes either setting.

| Shown | A tap does |
|---|---|
| Tap to talk | starts recording |
| Listening | ends the recording now and sends it |
| Got it | nothing |
| Hermes is working | starts recording; what you say steers the running reply (queued if Hermes can't take it now) |
| Reading aloud | stops reading and starts recording |
| Waiting for connection | starts recording; it is added to the waiting text and sent with it |
| Needs you on screen | nothing; approve or answer in the chat when parked |
| Didn't work | starts recording again |

On the button: the connection (Connected / Reconnecting / Offline, large and coloured) and what Hermes is working on
(e.g. "Terminal"). Tool arguments and commands are never shown. Losing the connection vibrates three times; getting
it back vibrates twice.

**Offline:** a recording finished without a connection stays as the chat draft on the phone. It is sent once when
the connection is back. Leaving car mode before that keeps it as the draft, unsent.

**Leaving:** Android Back, or swipe sideways across the screen. A swipe never starts or sends a recording. Leaving:
- cancels a recording without sending;
- stops reading aloud;
- leaves a running reply alone.

**Logs** (`adb logcat -s flutter`, prefix `WingCar`): `enter route=… loop=…`, `tap phase=… action=…`,
`stopSpeech ms=…`, `deliver kind=…`, `connection state=…`, `hold`, `release`, `swipe action=…`, `exit reason=…`.
They never contain text, titles or tool names.

**Limits:**
- Wing must be in the foreground; another app in front ends a running recording.
- `local` input route: Android's recognizer ends on silence by itself, and car mode sends that result.
- `hermes` input route: needs the connection to transcribe; offline it fails.
- A recording that reaches the maximum length (default 10 min) is not sent; it stays in the draft.
- After a queued (not steered) utterance in Conversation mode, the microphone stays closed until you tap.
- Vibration follows Android's touch-vibration setting.
```

In `docs/VOICE.md`, append: `Car mode (one big talk button for driving): see [CAR_MODE.md](CAR_MODE.md).`

- [ ] **Step 2: Render and inspect the real screens**

Run: `bash tools/factory/dispatch-check.sh voice-review.yml`
Expected: `dispatch-check: voice-review.yml run <id> conclusion=success …`.

Fetch the renders:
- Run: `git fetch -q origin voice-review-bin`
- Run: `mkdir -p build/voice-review-bin`
- Run: `git archive --output=build/voice-review-bin.tar origin/voice-review-bin`
- Run: `tar -xf build/voice-review-bin.tar -C build/voice-review-bin`

Open every `build/voice-review-bin/car-*.png` and compare it with
`docs/superpowers/specs/2026-10-14-wing-car-mode-shots/` (same state, size and theme). Check:
- the label is readable from arm's length;
- the connection badge is recognisable from the corner of the eye on every fill;
- the status line is in the upper third and one line;
- night has no white area;
- the 200 % text renders scale down without clipping;
- the title never hides the badge;
- the listening ring is visible.

Fix what looks wrong (spacing and sizes in `car_mode_screen.dart`), re-run, commit. Passing widget tests alone are not
enough (AGENTS.md "Design before implementation" 4).

- [ ] **Step 3: Build the APK**

Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: `… conclusion=success`. There is no Kotlin change; this proves the release Dart build.

Then run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=true`
Expected: `conclusion=success`. Branch `voice-apk-bin` now carries `SOURCE_COMMIT` = HEAD (input for Task 9).

- [ ] **Step 4: Full suite and commit**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`.

```bash
git add docs/CAR_MODE.md docs/VOICE.md
git commit -m "docs(car): car mode behaviour, logs and limits"
```

---

### Task 9: On-device acceptance (separate worker card, phone via `hadb`)

Not for the coder of Tasks 1-8. A separate worker card runs this on Birk's Xperia 5 IV (`com.tarkilhk.wing.voice`).

**Install:** follow the VAD plan's install steps
(`git show origin/voice-offline:docs/superpowers/plans/2026-10-13-wing-voice-vad-input.md`, Task 15 steps 1-2, lines
4090-4112). They cover `hadb install` and the tailnet `curl` + `pm install -r` fallback for large files. If the phone
is locked (`hadb shell 'dumpsys window | grep isKeyguardShowing'` → `true`), post a notification asking Birk to
unlock, as in that task (lines 4086-4087).

**Speech input:** use the VAD plan's synthetic self-test WAV (`/sdcard/Music/wingvad-selftest.wav`, same task, step 6,
lines 4144-4152). Start playback with `org.lineageos.twelve`, then bring Wing to the front, as in its step 7
(lines 4163-4164). ANNAHME: playing the WAV and returning to Wing keeps car mode open. Car mode survives the pause,
and the round is started by the tap after returning. If the WAV path is not workable, ask Birk via notification to
say a synthetic test sentence ("Testsatz eins, bitte antworte mit zwei Sätzen") at each round.

**Settings before:** input route `vad`, **Conversation mode off** (case 2), **Spoken replies off** (proves car mode
reads aloud anyway), a test chat with a harmless prompt history.

Record before, and restore after:
- `hadb shell 'settings get system screen_off_timeout'`
- `hadb shell 'settings get system accelerometer_rotation'`
- `hadb shell 'settings get system user_rotation'`

Clear the log first: `hadb shell 'logcat -c'`. Read it with `hadb shell 'logcat -d -s flutter'` and filter for
`WingCar` on the vServer (`| grep WingCar`).

| # | Do | Observe (pass criterion) |
|---|---|---|
| 1 | Open the chat → ⋮ → Car mode (`uiautomator dump` + `input tap`) | Screen shows "Tap to talk" and the badge "Connected". Log: `WingCar enter route=vad loop=off` |
| 2 | Wait 7 s; `uiautomator dump` at 1 s and at 7 s | "Swipe to leave" is in the 1 s dump and missing from the 7 s dump. The chat title stays |
| 3 | **Case 2, round 1:** tap, play speech, wait 10 s after the speech ends, tap | Log: `tap phase=idle action=talk`, then **no** round end during the 10 s silence (still "Listening"), then `tap phase=listening action=sendNow`, `deliver kind=send`. The chat gets the user message; the reply is read aloud; afterwards "Tap to talk", **no** start beep and **no** new recording (`dumpsys media.audio_flinger \| grep -c "Input thread"` unchanged, or no `WingVad` start line) |
| 4 | Rounds 2 and 3: same, tap only | 3 `deliver kind=send` lines in total. No touch outside the big button during the three rounds |
| 5 | Double tap fast (two taps < 0.3 s) in idle | One `action=talk` and one `action=debounced`. A deliberate second tap ≥ 0.7 s later is accepted (`action=sendNow`) |
| 6 | During read-aloud (a reply of ≥ 2 sentences), tap | `WingCar stopSpeech ms=<n>` with **n ≤ 500** (ANNAHME until measured). Audio audibly stops within 0.5 s (Birk or the worker listening). Then "Listening" |
| 7 | Tap while "Hermes is working" (prompt: "Führe im Terminal sleep 15 aus und antworte dann mit fertig"); read the screen | `uiautomator dump` shows the status line text `Terminal` (or the tool's display name) and no command text (`sleep 15` absent from the dump). Then speak, tap: `deliver kind=steer`; the chat shows a steer row |
| 8 | **Swipe:** `hadb shell 'input swipe 900 1200 150 1200 200'` | `WingCar swipe action=exit`, `WingCar exit reason=swipe`, **no** `WingCar tap` line for that gesture, no new user message. Re-enter car mode. Then a short slide `input swipe 500 1200 560 1200 150` (60 px ≈ 23 dp): `swipe action=short` or nothing, no `tap`, car mode stays. Then a swipe during "Listening" (tap, then swipe): exit, `prompts` unchanged (no new user message in the chat) |
| 9 | **Offline during a recording:** run the detached script below (adb may drop while airplane mode is on) | Screenshot `/sdcard/car-wait.png` shows "Waiting for connection" and the red "Offline" badge. Log afterwards: `connection state=offline`, `hold`, `connection state=…`, `release`, then **exactly one** `deliver kind=send`. The chat has the user message **once** (`uiautomator dump` count). Vibration: `hadb shell 'dumpsys vibrator_manager'` lists vibrations from `com.tarkilhk.wing.voice` at the loss and return times (ANNAHME: the section is named "Recent vibrations"; otherwise record what it shows). The connection never sat in `limited`/"Reconnecting" for more than 30 s after airplane mode off |
| 10 | **Screen on:** `hadb shell 'settings put system screen_off_timeout 30000'`, leave car mode idle **10 min** | `hadb shell 'dumpsys power \| grep -E "mWakefulness="'` → `Awake` at 10 min. `hadb shell 'dumpsys window windows \| grep -E "KEEP_SCREEN_ON"'` lists the Wing window |
| 11 | Landscape: `settings put system accelerometer_rotation 0`, `settings put system user_rotation 1` | `uiautomator dump`: the `car-button` bounds are wider than tall; badge, status line and label fully visible. Run one round (tap → speak → tap → reply) |
| 12 | Split screen with Maps (if the launcher allows), then a tap | ANNAHME (spec §4.1): the round runs. If it ends at once, record "car mode needs Wing fullscreen" in `docs/CAR_MODE.md` limits |
| 13 | Approval: prompt "Lösche die Datei /tmp/wing-car-test mit rm" (synthetic file created first via the same chat) | "Needs you on screen". A tap logs `action=ignore`, and nothing is approved |
| 14 | Android Back (`input keyevent 4`) | `WingCar exit reason=back` at once, no hint, back in the chat. `KEEP_SCREEN_ON` is gone from `dumpsys window windows` (unless a conversation still runs). The draft is unchanged |
| 15 | Case 1 check: Conversation mode **on**, re-enter, one round without tapping to send | The round ends on its own after the pause and is sent; the mic reopens after the reply. A tap while listening sends at once (`action=sendNow`, `deliver kind=send`) |
| 16 | Privacy: `hadb shell 'logcat -d' \| grep -i -E "Testsatz\|fertig\|wing-car-test\|sleep 15\|Terminal"` | Only lines **not** from `WingCar`/`WingVad` may match. Any `WingCar` line containing spoken, reply, held or tool text fails |

**Step 9 script.** Get the button centre from `uiautomator dump` first (resource or bounds of the car button; call it
`X Y`). Then run, as one command:

```
hadb shell 'nohup sh -c "am start -a android.intent.action.VIEW -t audio/wav -d file:///sdcard/Music/wingvad-selftest.wav org.lineageos.twelve; sleep 1; am start -n com.tarkilhk.wing.voice/com.tarkilhk.wing.MainActivity; sleep 2; input tap X Y; sleep 3; cmd connectivity airplane-mode enable; sleep 14; input tap X Y; sleep 6; screencap -p /sdcard/car-wait.png; sleep 10; cmd connectivity airplane-mode disable" > /dev/null 2>&1 &'
```

Wait 60 s, then reconnect `hadb` and collect the log, the screenshot (`hadb pull /sdcard/car-wait.png build/`) and the
chat dump. ANNAHME: `cmd connectivity airplane-mode` exists on the phone's Android version (the VAD plan uses it, line
4141). ANNAHME: the detached script survives the adb drop. If either fails, post a notification asking Birk to switch
airplane mode on while "Listening" and off after "Waiting for connection" shows.

**Restore** the three settings, Conversation mode and Spoken replies, and delete the test file, the WAV and
`/sdcard/car-wait.png` as in the VAD task. Post the results (table with pass/fail, the measured `stopSpeech ms`
values, and the vibration evidence) as a card comment. Birk confirms the driving feel himself on a real drive; that is
not part of this worker card.

---

## If Birk picks another option

Apply before Task 1, and adjust the tests named.

- **Tap while working B (tap stops the running turn):**
  - Add `required this.interrupt` (`Future<void> Function()`) to `CarModeBridge`. The workspace passes
    `() async { final chat = controller.notificationChat ?? controller.current?.chat; if (chat != null) await _run(() => controller.stop(chat)); }`
    (`controller.stop`, vo `profile_workspace_controller.dart:4915`).
  - In `CarModeSession.tap`, for `phase == CarPhase.thinking`, `await bridge.interrupt()` before `bridge.talk()`.
  - Task 7 becomes unnecessary (the turn is cancelled, so the next utterance is a normal send). Replace its test with
    "tap while working calls `session.interrupt`" (`fixture.calls` has `session.interrupt`).
  - Text: hint 'Tap to stop and talk'.
- **Tap while working C (ignored):**
  - `carTapActionFor`: `CarPhase.thinking => CarTapAction.ignore`; thinking hint `null`.
  - Drop Task 7. In the Task 1 tap table, thinking → `ignore`.
- **D3-B (circle instead of the colour field):**
  - In `_page`, the `Material` gets `shape: const CircleBorder()`, sized
    `min(box.maxWidth * .86, box.maxHeight * .6)`, centred on `tokens.surface`. Badge, status line and texts stay
    outside the circle and are **not** tappable.
  - The screen test "the button is the whole screen" becomes "> 30 % of the screen", and the badge tap no longer
    reaches the session. This contradicts Birk's D2 reason ("der ganze Bildschirm kann Sprechknopf sein").
- **A real tone on connection loss/return (instead of vibration only):**
  - Kotlin, `VoiceChannel.kt` `handle`: add
    `"cue" -> { ToneGenerator(AudioManager.STREAM_MUSIC, 70).startTone(if (call.argument<String>("kind") == "lost") ToneGenerator.TONE_PROP_NACK else ToneGenerator.TONE_PROP_ACK, 200); result.success(null) }`
    (same API as `VadCapture.cue`, vo `VadCapture.kt:73-80`; release the generator after 300 ms as there).
  - Dart: `Future<void> cue(String kind)` in `VoiceDevice` (vo `android_voice.dart:27-66`), `AndroidVoice` and
    `VoiceDeviceFixture` (records `cues`).
  - `CarModeSession._connectionChanged` calls `device.cue('lost')` / `device.cue('back')` next to the vibration.
  - Costs: a Kotlin change and one more method on a shared interface (touches the TTS-language plan's file
    `VoiceChannel.kt`; rebase whichever lands second). Prove it with `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`.
- **Swipe hint in the top strip (Birk's example) instead of the bottom edge:** in `_content`, show the hint in place of
  `title` for 6 s. At 411 dp next to the "Connected" badge it is clipped ("Swipe to le…", see the mockup check in the
  spec §4.1), so shorten the badge to an icon-only pill for those 6 s or accept the ellipsis.

## Self-review notes (plan author)

- **Spec coverage:**
  - §4.1 enter / Back / swipe / auto-exit / screen-on fixed → Tasks 3, 5, 6; device 1, 2, 8, 10, 14.
  - §4.2 case 1 / case 2, no override, tap-only vad, read every reply → Tasks 3 (`carTapOnlySettings`,
    `roundSettings`), 6 (3c-3d); device 3, 4, 15.
  - §4.3 table, waiting, tap while working, debounce, haptics → Tasks 1, 3, 7; device 5, 6, 7.
  - §4.4 badge, signal, hold / retry / release once → Tasks 1, 2, 3, 4, 5, 6 (3e); device 9.
  - §4.5 nothing shown → Tasks 4 (`carActivityOf` never reads `detail`), 5, 6 (status line test); device 7, 16.
  - §4.6 look, status line → Tasks 2, 5; renders in Task 8.
  - §4.7 orientation → Task 5 (both layouts, no lock); device 11.
  - §4.8 tap vs drag in the arena → Task 5 tests; device 8.
  - §5 files → Tasks 1-5. §6.1-6.5 hooks → Tasks 6-7. §7 logs → Task 3 (privacy test), device 16.
  - §8 upstream budget (~53 + ~24, limits 60 / 90) → Task 6 step 5, Task 7 step 5.
  - §10 tests → Tasks 1-7. Device acceptance → Task 9.
- **Not covered on purpose:** spec §11 "Later" items, including screen-off background voice (t_4934d7d4).
- **Changed against the previous plan revision:** Task 1 (phases, `waiting`, no `retry`, status line, swipe rule),
  Task 2 (badge colours), Task 3 (swipe/Back exit, hold/release/retry, signal, `roundSettings`, bridge test), Task 4
  (`carActivityOf`, `carConnectionOf` with send-blocked), Task 5 (no exit pill, full-screen button, drag), Task 6
  (no forced loop; :245/:401/:402 hooks; hold; new tests for case 1/2, status line, offline), Task 7 (exit via swipe in
  the test, budget check), Task 8 (docs), Task 9 (steps rewritten), deltas.

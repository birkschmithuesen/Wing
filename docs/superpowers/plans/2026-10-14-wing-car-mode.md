# Wing car mode (one big talk button) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fullscreen car mode for an open chat: one big button that talks, sends, interrupts read-aloud
and steers a running turn, usable blind. The screen stays on, and logs carry no spoken or answer text.

**Architecture:** Car mode is an own route (`CarModeScreen`), pushed over the chat workspace. The workspace
stays mounted below and keeps running the existing hands-free conversation loop. All logic lives in
`lib/car_mode/`:
- a pure state/tap table;
- a palette derived from Studio tokens;
- a session object that owns the route, the screen-on holder and the log;
- a bridge whose closures reach into the workspace.

`profile_workspace_screen.dart` gets about 35 lines of thin hooks: focus, loop forced on, tap-send flag,
menu entry, field/dispose, plus about 20 lines for steering while Hermes works.

**Tech Stack:** Flutter/Dart (Material, `ChangeNotifier`), existing `VoiceDevice`/`VoiceSwitchHolders`
from the VAD chain. No new packages, no Kotlin change.

**Spec:** `docs/superpowers/specs/2026-10-14-wing-car-mode-design.md`. Clickable draft:
`docs/superpowers/specs/2026-10-14-wing-car-mode-mockup.html`.

**Gate:** Do not start before Birk approved the clickable draft (card comment). If he picked options other
than the recommended ones, apply the deltas in the section "If Birk picks another option" first.

## Global Constraints

- Targets latest **unmodified upstream Hermes**. No backend change. All behaviour is client-only (AGENTS.md).
- Never change saved settings to simulate car mode. `voice.conversation` stays as the user set it. Car mode
  forces the loop in memory only (spec §4.2).
- Own code goes in own files (`lib/car_mode/`, `test/car_mode/`). Upstream files only get the hooks listed
  in spec §6/§8 (strategy doc rule 1).
- Logs (`WingCar …` via `debugPrint`) **never** contain transcript, spoken text, reply text, chat title or
  session id (spec §7).
- UI strings are English. Wing has no l10n (no `*.arb`, no `flutter_localizations`).
- The 48 dp minimum touch target and Studio tokens (`WingTokens`) apply to both themes. At night there are
  no pure white areas.
- Debounce 600 ms (ANNAHME, spec §4.2). Hold-to-exit 1 s (D2-A). Night fill = `Color.lerp(surface, token, .28)`.
- Test command: `bash tools/factory/ci-suite.sh`. It runs `flutter analyze` + the **whole** `flutter test`
  on GitHub (`pr-quality.yml`). It takes **no** test-path argument (checked: `tools/factory/ci-suite.sh`
  never reads `$1`), so an appended path is ignored. The vServer has no Flutter SDK (`which flutter` →
  not found).
  - Success: last line `ci-suite: run <id> conclusion=success https://github.com/birkschmithuesen/Wing/actions/runs/<id>`, exit 0.
  - Failure: `conclusion=failure` plus `  failed step: Run tests` (or `Analyze`), exit 1.
  - Failing test names are **not** printed: the log host is blocked (script line 23-24). Open the run URL
    in a browser or ask Birk.
- Kotlin / APK compile: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`. It ships with
  the VAD chain. Success: last line `dispatch-check: voice-apk.yml run <id> conclusion=success …`, exit 0.

---

## Basis / Rebase

This plan is written against `voice-offline` @ `f2c08256` plus the VAD chain `wt/t_24ef9c3d` @ `4a1a86c6`
(line numbers marked **wt**) and `upstream/main` @ `8105ab72` (marked **up**). The implementation starts
on **`voice-offline` after the VAD merge (card t_145c5731) and after the upstream merge chain
(t_d1d49ff1 → t_6a4e1890 → t_f8523002)**. Neither merge existed when this plan was written: `wt/t_d1d49ff1`
was still at `eb87b9b0`. Every anchor below must be re-verified before Task 1.

Run each command from the repo root, one at a time. Write the result for each anchor into the commit
message of Task 1 ("Basis: anchors A1-A14 ok / moved: …").

| # | Command | Expected | If it moved / is missing |
|---|---|---|---|
| A1 | `git merge-base --is-ancestor 4a1a86c6 HEAD` | exit 0 (VAD chain merged) | **Stop.** Car mode needs `VoiceSwitchHolders` + `stopHandsFree`. Ask Birk (`FRAGE:`). |
| A2 | `git merge-base --is-ancestor 8105ab72 HEAD` | exit 0 (upstream merged) | If Birk ordered an earlier start, continue: all wt line numbers apply as written. |
| A3 | `git grep -n "class VoiceSwitchHolders" -- lib/core/services/android_voice.dart` | 1 hit | Missing → stop and ask (A1). |
| A4 | `git grep -n "Future<void> stopHandsFree" -- lib/core/controllers/voice_input_controller.dart` | 1 hit | Missing → the bridge's `sendNow` calls `_voiceInput.stop()`. The `_carSend` flag (Task 6) still makes it a send. |
| A5 | `git grep -n "enum VoiceInputPhase" -- lib/core/controllers/voice_input_controller.dart` | `{ idle, starting, recording, transcribing }` | Other values → extend `carPhaseOf` (Task 1) and its table test. |
| A6 | `git grep -n "_speakCompletedReply\|_canContinueConversation\|Future<void> _dictate\|_sendConversationTurn\|_conversationAwaitingReply = true\|finishedOnItsOwn" -- lib/core/screens/profile_workspace_screen.dart` | the loop is still in the screen (wt :238, :278, :300, :313, :392, :411) | The merge moved the loop into another file → apply the Task 6 hooks there instead (same lines, same names). If the loop was **dropped** (upstream has none), stop and ask: car mode needs the loop. |
| A7 | `git grep -n "settings.conversation\|\.conversation)" -- lib/core/screens/profile_workspace_screen.dart` | 4 uses (wt :244, :245, :293, :402) | Replace each use found with `_loopWanted(settings)`. The settings type may now be `AppPreferences…` → `_loopWanted` takes that type. |
| A8 | `git grep -n "_routeIsCurrent = isCurrent" -- lib/core/screens/profile_workspace_screen.dart` | 1 hit (wt :561, up :779) | Missing → find `ModalRoute.isCurrentOf(context)` in `didChangeDependencies` and OR `_car.active` into the variable that feeds `_hasChatFocus`. |
| A9 | `git grep -n "tooltip: 'Chat actions'" -- lib/core/screens/profile_workspace_screen.dart` | 1 hit (wt :980, up :1401) | Entry goes into that menu. Upstream uses `StudioPopupMenuItem` → use it for the item. |
| A10 | `git grep -n "Map<ComposerAction, String?> _composerActions\|Future<void> _performComposerAction" -- lib/core/screens/profile_workspace_screen.dart` | 2 hits (wt :2218, :2287) | Upstream composer moved to `composer_session.dart` → for Task 7 use `controller.steer(chat, text)` / `controller.queuePrompt(chat, text)` directly (up `profile_workspace_controller.dart:6911`, `:6920`). |
| A11 | `git grep -n "ServerConnectionPhase get phase" -- lib/core/services/server_connection_status.dart` | 1 hit | Needed by `carSnapshotOf` (Task 4). |
| A12 | `git grep -n "bool get busy\|enum ProfileTurnStatus\|enum ChatExecution" -- lib/core` | fork: `ProfileChat.busy`, `ProfileTurnStatus`; upstream: `ChatExecution` in `lib/core/models/chat_runtime.dart` | Upstream types → use the **upstream body** of `carSnapshotOf` given in Task 4. |
| A13 | `git grep -n "decideDelivery" -- lib` | none (barge-in t_7e81e040 not merged) | Hit → barge-in landed. Skip Task 7 step 3; keep its test. Delete nothing of barge-in. |
| A14 | `git grep -n "ThemeData profileWorkspaceTheme\|static const preferenceKey = 'workspace_accent_v1'" -- lib/core/theme/profile_workspace_theme.dart` | 2 hits | Moved → use what the workspace's `build` uses for its accent theme. |

Also run `git log --oneline -5 -- lib/core/screens/profile_workspace_screen.dart`. If the max-dictation card
(t_d3a672fe) or barge-in touched `_dictate` or `_sendConversationTurn`, re-read those two methods in full
before Task 6.

**Overlap with other plans:**
- TTS language plan (`docs/superpowers/plans/2026-10-13-wing-tts-language.md`) touches `android_voice.dart`
  `speak`, `VoicePlayback.kt` and `VoiceChannel.kt`. This plan touches none of them.
- Barge-in touches the same screen methods as Task 6/7 (`_sendConversationTurn`, `_speakCompletedReply`,
  the `_conversation` setter). Whoever lands second rebases. The shared hook is described in Task 7.

## File structure

| File | Create/Modify | Responsibility |
|---|---|---|
| `lib/car_mode/car_mode_state.dart` | Create | Pure: phases, snapshot, phase priority, tap table, texts, debounce gate, busy delivery |
| `lib/car_mode/car_mode_palette.dart` | Create | Day/night colours per phase from `WingTokens`, contrast helper |
| `lib/car_mode/car_mode_bridge.dart` | Create | `CarModeBridge` (closures into the workspace) + `carSnapshotOf` (the only car code that reads `ProfileChat`) |
| `lib/car_mode/car_mode_session.dart` | Create | `CarModeSession`: enter/exit route, screen-on holder, tap dispatch, auto-exit, logs |
| `lib/car_mode/car_mode_screen.dart` | Create | Route widget: big button, hold-to-exit pill, Back hint, portrait/landscape |
| `lib/core/screens/profile_workspace_screen.dart` | Modify | Hooks: import, field, dispose, focus, `_loopWanted`, `_carSend`, menu, busy delivery |
| `test/car_mode/car_mode_state_test.dart` | Create | Tables for phase, tap, text, delivery, gate |
| `test/car_mode/car_mode_palette_test.dart` | Create | Contrast and "no white at night" |
| `test/car_mode/car_mode_session_test.dart` | Create | Session with a fake bridge |
| `test/car_mode/car_mode_screen_test.dart` | Create | Rendering, hold-to-exit, Back, sizes, `VOICE_REVIEW` captures |
| `test/voice_workspace_test.dart` | Modify | Group "car mode": real workspace end to end |
| `.github/workflows/voice-review.yml` | Modify (1 line) | Add `test/car_mode/car_mode_screen_test.dart` to the renders |
| `docs/CAR_MODE.md` | Create | Behaviour, log lines, device checks |
| `docs/VOICE.md` | Modify (1 line) | Link to `CAR_MODE.md` |

Upstream files touched: only `profile_workspace_screen.dart`, about 35 lines plus about 22 for Task 7 (spec
§8). `voice-review.yml` is fork-owned (VAD chain).

---

### Task 1: Pure car-mode state

**Files:**
- Create: `lib/car_mode/car_mode_state.dart`
- Test: `test/car_mode/car_mode_state_test.dart`

**Interfaces:**
- Consumes: `VoiceInputPhase` from `lib/core/controllers/voice_input_controller.dart`.
- Produces:
  - `enum CarPhase { idle, listening, transcribing, thinking, speaking, attention, error, offline }`
  - `enum CarConnection { ok, reconnecting, offline }`
  - `enum CarTapAction { talk, sendNow, retry, ignore }`
  - `enum CarDelivery { send, steer, queue, end }`
  - `class CarSnapshot`: fields `chatKey`, `title`, `input`, `speaking`, `working`, `needsInput`,
    `connection`, `error`
  - `CarPhase carPhaseOf(CarSnapshot)`
  - `CarTapAction carTapActionFor(CarPhase, CarSnapshot)`
  - `CarText carTextFor(CarPhase, CarSnapshot)`, with `typedef CarText = ({String label, String? hint, String? detail})`
  - `IconData carIconFor(CarPhase)`
  - `class CarTapGate` (`accept()`, `dispose()`)
  - `CarDelivery carDeliveryFor({required bool working, required bool steerAvailable, required bool queueAvailable})`

- [ ] **Step 1: Write the failing test**

```dart
// test/car_mode/car_mode_state_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/car_mode/car_mode_state.dart';
import 'package:wing/core/controllers/voice_input_controller.dart';

void main() {
  const idle = CarSnapshot(chatKey: 'chat');

  group('carPhaseOf', () {
    test('priority: attention > listening > transcribing > speaking > offline > thinking > error > idle', () {
      expect(carPhaseOf(idle), CarPhase.idle);
      expect(carPhaseOf(const CarSnapshot(chatKey: 'c', error: 'x')), CarPhase.error);
      expect(carPhaseOf(const CarSnapshot(chatKey: 'c', error: 'x', working: true)), CarPhase.thinking);
      expect(
        carPhaseOf(const CarSnapshot(chatKey: 'c', working: true, connection: CarConnection.offline)),
        CarPhase.offline,
      );
      expect(
        carPhaseOf(const CarSnapshot(chatKey: 'c', speaking: true, connection: CarConnection.offline)),
        CarPhase.speaking,
      );
      expect(
        carPhaseOf(const CarSnapshot(chatKey: 'c', speaking: true, input: VoiceInputPhase.transcribing)),
        CarPhase.transcribing,
      );
      expect(carPhaseOf(const CarSnapshot(chatKey: 'c', input: VoiceInputPhase.starting)), CarPhase.listening);
      expect(carPhaseOf(const CarSnapshot(chatKey: 'c', input: VoiceInputPhase.recording)), CarPhase.listening);
      expect(
        carPhaseOf(const CarSnapshot(chatKey: 'c', input: VoiceInputPhase.recording, needsInput: true)),
        CarPhase.attention,
      );
    });
  });

  group('carTapActionFor', () {
    CarTapAction tap(CarSnapshot s) => carTapActionFor(carPhaseOf(s), s);
    test('table of spec 4.2', () {
      expect(tap(idle), CarTapAction.talk);
      expect(tap(const CarSnapshot(chatKey: 'c', input: VoiceInputPhase.starting)), CarTapAction.ignore);
      expect(tap(const CarSnapshot(chatKey: 'c', input: VoiceInputPhase.recording)), CarTapAction.sendNow);
      expect(tap(const CarSnapshot(chatKey: 'c', input: VoiceInputPhase.transcribing)), CarTapAction.ignore);
      expect(tap(const CarSnapshot(chatKey: 'c', working: true)), CarTapAction.talk); // D1-A
      expect(tap(const CarSnapshot(chatKey: 'c', speaking: true)), CarTapAction.talk);
      expect(tap(const CarSnapshot(chatKey: 'c', needsInput: true)), CarTapAction.ignore);
      expect(tap(const CarSnapshot(chatKey: 'c', error: 'x')), CarTapAction.talk);
      expect(tap(const CarSnapshot(chatKey: 'c', connection: CarConnection.offline)), CarTapAction.retry);
      expect(tap(const CarSnapshot(chatKey: 'c', connection: CarConnection.reconnecting)), CarTapAction.ignore);
    });
  });

  test('every phase has a label and an icon; error shows its detail; no text leaks other state', () {
    for (final phase in CarPhase.values) {
      expect(carTextFor(phase, idle).label, isNotEmpty);
      expect(carIconFor(phase), isA<IconData>());
    }
    final error = const CarSnapshot(chatKey: 'c', error: 'No speech detected. Try again.');
    expect(carTextFor(CarPhase.error, error).detail, 'No speech detected. Try again.');
    expect(carTextFor(CarPhase.idle, idle).label, 'Tap to talk');
    expect(carTextFor(CarPhase.listening, idle).hint, 'Tap to send');
    expect(
      carTextFor(CarPhase.offline, const CarSnapshot(chatKey: 'c', connection: CarConnection.reconnecting)).hint,
      'Reconnecting…',
    );
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
Expected: `conclusion=failure`, `  failed step: Analyze` (the missing `package:wing/car_mode/car_mode_state.dart` is an analyzer error).

- [ ] **Step 3: Write the implementation**

```dart
// lib/car_mode/car_mode_state.dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/controllers/voice_input_controller.dart';

/// What car mode shows. Exactly one phase at a time, see [carPhaseOf].
enum CarPhase { idle, listening, transcribing, thinking, speaking, attention, error, offline }

enum CarConnection { ok, reconnecting, offline }

enum CarTapAction { talk, sendNow, retry, ignore }

/// How a hands-free utterance reaches a chat (spec §6.3).
enum CarDelivery { send, steer, queue, end }

typedef CarText = ({String label, String? hint, String? detail});

/// Neutral facts about the chat on screen. Filled by `carSnapshotOf`; the
/// rest of car mode never reads chat or controller types.
class CarSnapshot {
  const CarSnapshot({
    required this.chatKey,
    this.title,
    this.input = VoiceInputPhase.idle,
    this.speaking = false,
    this.working = false,
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

  /// Approval, clarification or secure prompt pending.
  final bool needsInput;
  final CarConnection connection;

  /// Short voice or turn error text; shown on screen, never logged.
  final String? error;
}

CarPhase carPhaseOf(CarSnapshot s) {
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
  if (s.connection != CarConnection.ok) return CarPhase.offline;
  if (s.working) return CarPhase.thinking;
  if (s.error != null) return CarPhase.error;
  return CarPhase.idle;
}

/// Spec §4.2. Thinking → talk is decision D1-A (steer what is said next).
CarTapAction carTapActionFor(CarPhase phase, CarSnapshot s) => switch (phase) {
  CarPhase.idle || CarPhase.error || CarPhase.speaking || CarPhase.thinking => CarTapAction.talk,
  CarPhase.listening =>
    s.input == VoiceInputPhase.recording ? CarTapAction.sendNow : CarTapAction.ignore,
  CarPhase.offline =>
    s.connection == CarConnection.offline ? CarTapAction.retry : CarTapAction.ignore,
  CarPhase.transcribing || CarPhase.attention => CarTapAction.ignore,
};

CarText carTextFor(CarPhase phase, CarSnapshot s) => switch (phase) {
  CarPhase.idle => (label: 'Tap to talk', hint: null, detail: null),
  CarPhase.listening => (label: 'Listening', hint: 'Tap to send', detail: null),
  CarPhase.transcribing => (label: 'Got it', hint: 'Transcribing…', detail: null),
  CarPhase.thinking => (label: 'Hermes is working', hint: 'Tap to add something', detail: null),
  CarPhase.speaking => (label: 'Reading aloud', hint: 'Tap to interrupt', detail: null),
  CarPhase.attention => (
    label: 'Needs you on screen',
    hint: 'Approval or question waiting. Look when parked.',
    detail: null,
  ),
  CarPhase.error => (label: "Didn't work", hint: 'Tap to try again', detail: s.error),
  CarPhase.offline => (
    label: 'No connection',
    hint: s.connection == CarConnection.reconnecting ? 'Reconnecting…' : 'Tap to retry',
    detail: null,
  ),
};

IconData carIconFor(CarPhase phase) => switch (phase) {
  CarPhase.idle => Icons.mic,
  CarPhase.listening => Icons.stop_rounded,
  CarPhase.transcribing => Icons.more_horiz,
  CarPhase.thinking => Icons.hourglass_empty,
  CarPhase.speaking => Icons.volume_up,
  CarPhase.attention => Icons.visibility,
  CarPhase.error => Icons.warning,
  CarPhase.offline => Icons.cloud_off,
};

/// A hands-free utterance on a busy chat: steer if Hermes accepts it, else
/// queue, else give up (spec §6.3; barge-in's decideDelivery replaces this).
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
git commit -m "feat(car): pure car-mode phases, tap table and debounce"
```

(The commit body records the Basis anchor results, see "Basis / Rebase".)

---

### Task 2: Palette from Studio tokens

**Files:**
- Create: `lib/car_mode/car_mode_palette.dart`
- Test: `test/car_mode/car_mode_palette_test.dart`

**Interfaces:**
- Consumes: `CarPhase` (Task 1); `WingTokens` (`lib/core/theme/wing_theme.dart`, fields `surface`, `raised`,
  `onSurface`, `muted`, `accent`, `warning`, `danger`, `running`), `wingTheme(Brightness, {Color? accent})`.
- Produces:
  - `class CarColors { final Color fill, label, hint; final Color? border; }`
  - `CarColors carColorsFor(CarPhase, WingTokens, Brightness)`
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
      test('${accent.name} ${brightness.name}: label ≥ 3:1, hint ≥ 4.5:1', () {
        for (final phase in CarPhase.values) {
          final c = carColorsFor(phase, tokens, brightness);
          expect(carContrast(c.label, c.fill), greaterThanOrEqualTo(3.0), reason: '$phase label');
          expect(carContrast(c.hint, c.fill), greaterThanOrEqualTo(4.5), reason: '$phase hint');
        }
      });
      if (brightness == Brightness.dark) {
        test('${accent.name} night has no pure white', () {
          for (final phase in CarPhase.values) {
            final c = carColorsFor(phase, tokens, brightness);
            for (final color in [c.fill, c.label, c.hint, ?c.border]) {
              expect(color.toARGB32(), isNot(0xFFFFFFFF), reason: '$phase');
            }
          }
        });
      }
    }
  }

  test('day listening uses the danger token with white text', () {
    final tokens = wingTheme(Brightness.light).extension<WingTokens>()!;
    final c = carColorsFor(CarPhase.listening, tokens, Brightness.light);
    expect(c.fill, tokens.danger);
    expect(c.label, Colors.white);
    expect(carContrast(Colors.white, const Color(0xFFB91C1C)), closeTo(6.5, 0.1));
  });
}
```

ANNAHME: Dart ≥ 3.8 null-aware list elements (`?c.border`) are available. `pubspec.yaml` says
`sdk: ^3.12.0`, so they are. `Color.toARGB32()` exists in the pinned Flutter 3.44 (`voice-review.yml`
`flutter-version: '3.44.0'`). If the analyzer rejects either, replace them with `if (c.border != null) c.border!`
and `.value`.

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
    CarPhase.offline || CarPhase.idle => t.muted,
  };
  if (!night) return CarColors(fill: token, label: Colors.white, hint: Colors.white);
  return CarColors(
    fill: Color.lerp(t.surface, token, .28)!,
    label: token,
    hint: Color.lerp(token, t.onSurface, .5)!,
  );
}

/// WCAG 2 contrast ratio.
double carContrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`.

The contrast test may fail for one accent/phase pair. The likely case is the light `gold` accent `#745A0A`
used as the day *speaking* fill, but `idle` only uses the accent as label and border. If it fails, do
**not** lower the threshold. For that phase, switch the day label to `t.onSurface` on a
`Color.lerp(t.raised, token, .25)` fill, and note the change in `docs/CAR_MODE.md`.

- [ ] **Step 5: Commit**

```bash
git add lib/car_mode/car_mode_palette.dart test/car_mode/car_mode_palette_test.dart
git commit -m "feat(car): day/night car palette from studio tokens"
```

---

### Task 3: Session (route, screen-on, tap dispatch, logs) and bridge type

**Files:**
- Create: `lib/car_mode/car_mode_bridge.dart` (only the `CarModeBridge` class in this task; `carSnapshotOf` comes in Task 4)
- Create: `lib/car_mode/car_mode_session.dart`
- Create: `lib/car_mode/car_mode_screen.dart` (minimal placeholder widget in this task, replaced in Task 5)
- Test: `test/car_mode/car_mode_session_test.dart`

**Interfaces:**
- Consumes: Task 1 (`CarSnapshot`, `carPhaseOf`, `carTapActionFor`, `CarTapGate`, `CarDelivery`);
  `VoiceDevice`, `VoiceSwitchHolders.screenOn(device).set(Object owner, bool on)` (wt
  `lib/core/services/android_voice.dart:215-241`); `VoiceDeviceFixture.keepScreenOnCalls` (wt
  `test/support/voice_fixture.dart:29`).
- Produces:

```dart
class CarModeBridge {
  const CarModeBridge({
    required this.changes,      // Listenable
    required this.read,         // CarSnapshot Function()
    required this.preferences,  // SharedPreferences (accent + input route name)
    required this.talk,         // Future<void> Function()
    required this.sendNow,      // Future<void> Function()
    required this.stopSpeech,   // Future<void> Function()
    required this.retry,        // Future<void> Function()
    required this.leave,        // VoidCallback
  });
}

class CarModeSession extends ChangeNotifier {
  CarModeSession({required VoiceDevice device, required CarModeBridge bridge,
      void Function(String line)? log});
  bool get active;
  CarSnapshot get snapshot;
  CarPhase get phase;
  Future<void> enter(BuildContext context);
  void exit([String reason = 'hold']);
  Future<void> tap();
  void logDelivery(CarDelivery delivery);
}
class CarModeScreen extends StatefulWidget { const CarModeScreen({super.key, required this.session}); }
```

- [ ] **Step 1: Write the failing test**

```dart
// test/car_mode/car_mode_session_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/car_mode/car_mode_bridge.dart';
import 'package:wing/car_mode/car_mode_session.dart';
import 'package:wing/car_mode/car_mode_state.dart';
import 'package:wing/core/controllers/voice_input_controller.dart';
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

  testWidgets('enter pushes the route and holds the screen on until exit', (tester) async {
    await open(tester);
    expect(session.active, isTrue);
    expect(find.byType(CarModeScreen), findsOneWidget);
    expect(device.keepScreenOnCalls, [true]);
    session.exit();
    await tester.pumpAndSettle();
    expect(session.active, isFalse);
    expect(find.byType(CarModeScreen), findsNothing);
    expect(device.keepScreenOnCalls, [true, false]);
    expect(world.calls, ['leave']);
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
    world.set(const CarSnapshot(chatKey: 'chat', connection: CarConnection.offline));
    await session.tap();
    expect(world.calls.last, 'retry');
    await tester.pump(const Duration(milliseconds: 650));
    session.exit();
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

  testWidgets('logs never contain chat text, title or error text', (tester) async {
    await open(tester);
    world.set(const CarSnapshot(chatKey: 'chat', title: 'Secret title', error: 'Secret error'));
    await session.tap();
    session.logDelivery(CarDelivery.steer);
    await tester.pump(const Duration(milliseconds: 650));
    session.exit();
    await tester.pumpAndSettle();
    expect(logs, isNotEmpty);
    for (final line in logs) {
      expect(line, startsWith('WingCar '));
      expect(line, isNot(contains('Secret')));
    }
    expect(logs, contains('WingCar deliver kind=steer'));
    expect(logs, contains('WingCar tap phase=error action=talk'));
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=failure`, `  failed step: Analyze`.

- [ ] **Step 3: Write the implementation**

```dart
// lib/car_mode/car_mode_bridge.dart
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'car_mode_state.dart';

/// What car mode may do in the chat workspace. The workspace builds it from
/// closures over its private voice loop (spec §6.4).
class CarModeBridge {
  const CarModeBridge({
    required this.changes,
    required this.read,
    required this.preferences,
    required this.talk,
    required this.sendNow,
    required this.stopSpeech,
    required this.retry,
    required this.leave,
  });

  /// Fires when anything in [read] may have changed.
  final Listenable changes;
  final CarSnapshot Function() read;
  final SharedPreferences preferences;

  /// Stop read-aloud and open the microphone for the chat; the loop is on.
  final Future<void> Function() talk;

  /// End the running round now and send what was said.
  final Future<void> Function() sendNow;
  final Future<void> Function() stopSpeech;
  final Future<void> Function() retry;

  /// Cancel recording (not sent) and stop read-aloud; the turn keeps running.
  final VoidCallback leave;
}
```

```dart
// lib/car_mode/car_mode_session.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/services/android_voice.dart';
import '../core/services/voice_preferences.dart';
import 'car_mode_bridge.dart';
import 'car_mode_screen.dart';
import 'car_mode_state.dart';

/// One car-mode visit over one chat. Owns the route, the screen-on holder and
/// the text-free log (spec §7).
class CarModeSession extends ChangeNotifier {
  CarModeSession({
    required this.device,
    required this.bridge,
    void Function(String line)? log,
  }) : _log = log ?? debugPrint;

  final VoiceDevice device;
  final CarModeBridge bridge;
  final void Function(String line) _log;
  final _gate = CarTapGate();
  bool _active = false;
  Object? _chatKey;
  NavigatorState? _navigator;
  Route<void>? _route;

  bool get active => _active;
  CarSnapshot get snapshot => bridge.read();
  CarPhase get phase => carPhaseOf(snapshot);

  Future<void> enter(BuildContext context) async {
    final snap = bridge.read();
    if (_active || snap.chatKey == null) return;
    // Active before the push: the workspace below keeps its chat focus.
    _active = true;
    _chatKey = snap.chatKey;
    VoiceSwitchHolders.screenOn(device).set(this, true);
    bridge.changes.addListener(_changed);
    _log('WingCar enter route=${_routeName()}');
    notifyListeners();
    final navigator = _navigator = Navigator.of(context);
    final route = _route = MaterialPageRoute<void>(
      builder: (_) => CarModeScreen(session: this),
    );
    await navigator.push(route);
    _end('popped');
  }

  void exit([String reason = 'hold']) {
    if (!_active) return;
    bridge.leave();
    _end(reason);
    final route = _route;
    _route = null;
    final navigator = _navigator;
    if (route == null || navigator == null || !route.isActive) return;
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  void _end(String reason) {
    if (!_active) return;
    _active = false;
    bridge.changes.removeListener(_changed);
    VoiceSwitchHolders.screenOn(device).set(this, false);
    _log('WingCar exit reason=$reason');
    notifyListeners();
  }

  void _changed() {
    if (!_active) return;
    if (bridge.read().chatKey != _chatKey) {
      exit('chatChanged');
      return;
    }
    notifyListeners();
  }

  Future<void> tap() async {
    if (!_active) return;
    final snap = bridge.read();
    final phase = carPhaseOf(snap);
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
      case CarTapAction.retry:
        await bridge.retry();
      case CarTapAction.ignore:
        break;
    }
  }

  /// Called by the workspace when a car-mode utterance is delivered.
  void logDelivery(CarDelivery delivery) {
    if (_active) _log('WingCar deliver kind=${delivery.name}');
  }

  String _routeName() {
    try {
      return VoicePreferences.read(bridge.preferences).input.name;
    } on FormatException {
      return 'unknown';
    }
  }

  @override
  void dispose() {
    _end('disposed');
    _gate.dispose();
    super.dispose();
  }
}
```

ANNAHME: `VoicePreferences.read(SharedPreferences)` and `.input` (`VoiceInputRoute`) still exist after the
upstream merge (A7). If the merge replaced them, return the name from the replacement settings type here.
This is the only place.

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

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`.

- [ ] **Step 5: Commit**

```bash
git add lib/car_mode/car_mode_bridge.dart lib/car_mode/car_mode_session.dart lib/car_mode/car_mode_screen.dart test/car_mode/car_mode_session_test.dart
git commit -m "feat(car): car-mode session with screen-on holder and text-free log"
```

---

### Task 4: Snapshot adapter `carSnapshotOf`

**Files:**
- Modify: `lib/car_mode/car_mode_bridge.dart` (append function)
- Test: no separate test file. `carSnapshotOf` needs a real `ProfileWorkspaceController`, and that fixture
  lives in `test/voice_workspace_test.dart`. The Task 6 tests exercise every field: listening, speaking,
  needs input (approval test), working (Task 7) and chat key (exit). The error and offline mapping is
  covered by the pure tables in Task 1.

**Interfaces:**
- Consumes: `ProfileWorkspaceController` (`notificationChat`, `current?.chat`, `connectionStatus`),
  `ProfileChat` (`key`, `title`, `busy`, `status`, `approval`, `clarification`, `sensitivePrompt`),
  `VoiceInputController` (`phase`, `error`), `VoiceOutputController` (`owner`, `error`),
  `ServerConnectionPhase`.
- Produces: `CarSnapshot carSnapshotOf(ProfileWorkspaceController controller, VoiceInputController input, VoiceOutputController output)`.

- [ ] **Step 1: Write the implementation (fork types, after A12 says `ProfileTurnStatus`)**

Append to `lib/car_mode/car_mode_bridge.dart` (add the imports at the top):

```dart
import '../core/controllers/voice_input_controller.dart';
import '../core/controllers/voice_output_controller.dart';
import '../core/services/profile_workspace_controller.dart';
import '../core/services/server_connection_status.dart';

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
    needsInput:
        chat != null &&
        (chat.approval != null || chat.clarification != null || chat.sensitivePrompt != null),
    connection: switch (controller.connectionStatus.phase) {
      ServerConnectionPhase.reconnecting => CarConnection.reconnecting,
      ServerConnectionPhase.disconnected => CarConnection.offline,
      _ => CarConnection.ok,
    },
    error:
        input.error ??
        output.error ??
        (chat?.status == ProfileTurnStatus.failed ? 'Hermes could not finish this reply.' : null),
  );
}
```

**Upstream body** (use it if A12 shows `ChatExecution` and no `ProfileTurnStatus`). Field names are from up
`lib/core/models/chat_runtime.dart`. ANNAHME: the merged `ProfileChat` exposes `runtime` the way up
`profile_workspace_screen.dart:1305` uses it (`chat.runtime.opening`). Check with
`git grep -n "chat.runtime\." -- lib/core/screens/profile_workspace_screen.dart`.

```dart
  final runtime = chat?.runtime;
  return CarSnapshot(
    chatKey: chat?.key,
    title: chat?.title,
    input: input.phase,
    speaking: output.owner != null,
    working: runtime != null && (runtime.executionActive || runtime.reconnecting),
    needsInput: runtime?.needsInput ?? false,
    connection: switch (controller.connectionStatus.phase) {
      ServerConnectionPhase.reconnecting => CarConnection.reconnecting,
      ServerConnectionPhase.disconnected => CarConnection.offline,
      _ => CarConnection.ok,
    },
    error: input.error ?? output.error ??
        (runtime?.execution == ChatExecution.failed ? 'Hermes could not finish this reply.' : null),
  );
```

- [ ] **Step 2: Run analyze/tests**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`. The new function is not used yet; analyze must stay clean.

- [ ] **Step 3: Commit**

```bash
git add lib/car_mode/car_mode_bridge.dart
git commit -m "feat(car): snapshot adapter from the chat workspace"
```

---

### Task 5: Car-mode screen

**Files:**
- Modify: `lib/car_mode/car_mode_screen.dart` (replace the placeholder)
- Modify: `.github/workflows/voice-review.yml` (render list, 1 line)
- Test: `test/car_mode/car_mode_screen_test.dart`

**Interfaces:**
- Consumes: `CarModeSession` (`phase`, `snapshot`, `tap()`, `exit(String)`, `bridge.preferences`),
  `carTextFor`, `carIconFor`, `carColorsFor`, `profileWorkspaceTheme(ThemeData, accent:)`,
  `WorkspaceAccent.fromName`, `WorkspaceAccent.preferenceKey`, `WingTokens.of(context)`.
- Produces (keys used by tests in Task 6):
  - `ValueKey('car-button')`: the big button
  - `ValueKey('car-exit')`: the hold-to-exit pill
  - `ValueKey('car-hint')`: the transient hint

Design rules (spec §4.4):
- **Portrait:** top strip (min 64 dp) with the pill left and the title right in `muted`, 16 sp. Below it the
  button with 12 dp inset and 28 dp corners.
- **Landscape:** a 172 dp strip on the left.
- **Type:** label 44 sp (landscape 40 sp, w600), hint 22 sp, detail 20 sp. Icon 120 dp (landscape 112 dp).
- **Pulse:** a pulsing ring only in `listening`. It is static with `MediaQuery.disableAnimationsOf`.
- **No transcript, reply or timer text** (spec §4.3).

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
  late CarModeSession session;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    device = VoiceDeviceFixture();
    world = _World();
    session = CarModeSession(
      device: device,
      log: (_) {},
      bridge: CarModeBridge(
        changes: world,
        read: () => world.snapshot,
        preferences: prefs,
        talk: () async => world.calls.add('talk'),
        sendNow: () async => world.calls.add('sendNow'),
        stopSpeech: () async => world.calls.add('stopSpeech'),
        retry: () async => world.calls.add('retry'),
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

  const states = {
    'idle': CarSnapshot(chatKey: 'chat', title: 'Weekend trip'),
    'listening': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', input: VoiceInputPhase.recording),
    'transcribing': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', input: VoiceInputPhase.transcribing),
    'thinking': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', working: true),
    'speaking': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', speaking: true),
    'attention': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', needsInput: true),
    'error': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', error: 'No speech detected. Try again.'),
    'offline': CarSnapshot(chatKey: 'chat', title: 'Weekend trip', connection: CarConnection.offline),
  };

  for (final MapEntry(key: name, value: snap) in states.entries) {
    testWidgets('$name renders its label and icon', (tester) async {
      world.snapshot = snap;
      await show(tester);
      final phase = carPhaseOf(snap);
      expect(find.text(carTextFor(phase, snap).label), findsOneWidget);
      expect(find.byIcon(carIconFor(phase)), findsOneWidget);
      expect(find.text('Weekend trip'), findsOneWidget);
      await close(tester);
    });
  }

  testWidgets('a tap anywhere on the button reaches the session', (tester) async {
    await show(tester);
    final rect = tester.getRect(find.byKey(const ValueKey('car-button')));
    expect(rect.width * rect.height, greaterThan(411 * 960 * .7));
    await tester.tapAt(rect.topLeft + const Offset(30, 30));
    await tester.pump(const Duration(milliseconds: 700));
    expect(world.calls, ['talk']);
    await close(tester);
  });

  testWidgets('exit needs a 1 s hold; a short press only shows a hint', (tester) async {
    await show(tester);
    final pill = find.byKey(const ValueKey('car-exit'));
    var gesture = await tester.startGesture(tester.getCenter(pill));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pump();
    expect(session.active, isTrue);
    expect(find.text('Keep holding to exit'), findsOneWidget);
    gesture = await tester.startGesture(tester.getCenter(pill));
    await tester.pump(const Duration(milliseconds: 1100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(session.active, isFalse);
    expect(world.calls, ['leave']);
  });

  testWidgets('Back is blocked and shows how to leave', (tester) async {
    await show(tester);
    final handled = await tester.binding.handlePopRoute();
    await tester.pump();
    expect(handled, isTrue);
    expect(session.active, isTrue);
    expect(find.text('Hold Exit to leave car mode'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Hold Exit to leave car mode'), findsNothing);
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
            final pill = tester.getSize(find.byKey(const ValueKey('car-exit')));
            expect(pill.height, greaterThanOrEqualTo(48));
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

import 'package:flutter/material.dart';

import '../core/theme/profile_workspace_theme.dart';
import '../core/theme/wing_theme.dart';
import 'car_mode_palette.dart';
import 'car_mode_session.dart';
import 'car_mode_state.dart';

/// Fullscreen car mode: one big button over the open chat (spec §4).
class CarModeScreen extends StatefulWidget {
  const CarModeScreen({super.key, required this.session});
  final CarModeSession session;

  @override
  State<CarModeScreen> createState() => _CarModeScreenState();
}

class _CarModeScreenState extends State<CarModeScreen> with SingleTickerProviderStateMixin {
  late final _hold = AnimationController(vsync: this, duration: const Duration(seconds: 1))
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.session.exit('hold');
    });
  String? _hint;
  Timer? _hintTimer;

  void _showHint(String text) {
    _hintTimer?.cancel();
    setState(() => _hint = text);
    _hintTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _hint = null);
    });
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _hold.dispose();
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
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _showHint('Hold Exit to leave car mode');
        },
        child: ListenableBuilder(
          listenable: widget.session,
          builder: (context, _) => _page(context),
        ),
      ),
    );
  }

  Widget _page(BuildContext context) {
    final tokens = WingTokens.of(context);
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final snap = widget.session.snapshot;
    final title = Text(
      snap.title ?? '',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: landscape ? TextAlign.start : TextAlign.end,
      style: TextStyle(fontSize: 16, color: tokens.muted),
    );
    final exit = _ExitPill(
      hold: _hold,
      onShortPress: () => _showHint('Keep holding to exit'),
      onExit: () => widget.session.exit('hold'),
    );
    final button = _bigButton(context, snap, landscape);
    final body = landscape
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 172,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [exit, const SizedBox(height: 12), title],
                  ),
                ),
              ),
              Expanded(
                child: Padding(padding: const EdgeInsets.fromLTRB(4, 12, 12, 12), child: button),
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Row(
                    children: [exit, const SizedBox(width: 12), Expanded(child: title)],
                  ),
                ),
              ),
              Expanded(
                child: Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: button),
              ),
            ],
          );
    return Scaffold(
      backgroundColor: tokens.surface,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: body),
            if (_hint != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: 32,
                child: Center(
                  child: DecoratedBox(
                    key: const ValueKey('car-hint'),
                    decoration: BoxDecoration(
                      color: tokens.raised,
                      borderRadius: WingRadius.card,
                      border: Border.all(color: tokens.border),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Text(_hint!, style: TextStyle(fontSize: 17, color: tokens.onSurface)),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bigButton(BuildContext context, CarSnapshot snap, bool landscape) {
    final tokens = WingTokens.of(context);
    final brightness = Theme.of(context).brightness;
    final phase = carPhaseOf(snap);
    final colors = carColorsFor(phase, tokens, brightness);
    final text = carTextFor(phase, snap);
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
    final texts = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: landscape ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Text(
          text.label,
          textAlign: landscape ? TextAlign.start : TextAlign.center,
          style: TextStyle(
            fontSize: landscape ? 40 : 44,
            fontWeight: FontWeight.w600,
            height: 1.1,
            color: colors.label,
          ),
        ),
        if (text.detail != null) ...[
          const SizedBox(height: 10),
          Text(
            text.detail!,
            textAlign: landscape ? TextAlign.start : TextAlign.center,
            style: TextStyle(fontSize: 20, color: colors.hint),
          ),
        ],
        if (text.hint != null) ...[
          const SizedBox(height: 10),
          Text(
            text.hint!,
            textAlign: landscape ? TextAlign.start : TextAlign.center,
            style: TextStyle(fontSize: 22, color: colors.hint),
          ),
        ],
      ],
    );
    return Semantics(
      button: true,
      liveRegion: true,
      label: [text.label, text.detail, text.hint].whereType<String>().join('. '),
      excludeSemantics: true,
      onTap: widget.session.tap,
      child: Material(
        key: const ValueKey('car-button'),
        color: colors.fill,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: colors.border == null ? BorderSide.none : BorderSide(color: colors.border!, width: 4),
        ),
        child: InkWell(
          onTap: widget.session.tap,
          child: LayoutBuilder(
            builder: (context, box) {
              final content = landscape
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        icon,
                        const SizedBox(width: 36),
                        SizedBox(width: box.maxWidth * .5, child: texts),
                      ],
                    )
                  : SizedBox(
                      width: box.maxWidth - 48,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [icon, const SizedBox(height: 18), texts],
                      ),
                    );
              // Enlarged text scales down instead of overflowing the button.
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: content)),
              );
            },
          ),
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

class _ExitPill extends StatelessWidget {
  const _ExitPill({required this.hold, required this.onShortPress, required this.onExit});
  final AnimationController hold;
  final VoidCallback onShortPress;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    return Semantics(
      button: true,
      label: 'Hold to exit car mode',
      onLongPress: onExit,
      excludeSemantics: true,
      child: Listener(
        key: const ValueKey('car-exit'),
        onPointerDown: (_) => hold.forward(from: 0),
        onPointerUp: (_) {
          if (hold.value < 1) onShortPress();
          hold.reset();
        },
        onPointerCancel: (_) => hold.reset(),
        child: AnimatedBuilder(
          animation: hold,
          builder: (context, child) => CustomPaint(
            foregroundPainter: _HoldRing(hold.value, tokens.accent),
            child: child,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.raised,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: tokens.border, width: 2),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.close, size: 20, color: tokens.muted),
                      const SizedBox(width: 6),
                      Text('Hold to exit', style: TextStyle(fontSize: 16, color: tokens.onSurface)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HoldRing extends CustomPainter {
  _HoldRing(this.progress, this.color);
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(size.height / 2)));
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
  }

  @override
  bool shouldRepaint(_HoldRing old) => old.progress != progress || old.color != color;
}
```

Add the screen test to the render list in `.github/workflows/voice-review.yml` (wt line 34-35):

```yaml
          flutter test --no-pub --dart-define=VOICE_REVIEW=true --dart-define=CAPTURE_FONT_DIR="$fonts" \
            test/voice_preferences_test.dart test/vad_settings_test.dart test/voice_workspace_test.dart \
            test/car_mode/car_mode_screen_test.dart
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`.

- [ ] **Step 5: Commit**

```bash
git add lib/car_mode/car_mode_screen.dart test/car_mode/car_mode_screen_test.dart .github/workflows/voice-review.yml
git commit -m "feat(car): fullscreen car-mode screen with hold-to-exit"
```

---

### Task 6: Workspace hooks (entry, focus, forced loop, tap-send)

**Files:**
- Modify: `lib/core/screens/profile_workspace_screen.dart`. wt anchors:
  - imports (top);
  - fields after `_voiceDeviceEvents` (:178);
  - `_speakCompletedReply` (:244-245);
  - `_canContinueConversation` (:293);
  - `_dictate` (:392-436, :402, :411);
  - `didChangeDependencies` (:561);
  - `dispose` (:650-677);
  - Chat actions menu (:982-1047).
- Test: `test/voice_workspace_test.dart` (new tests at the end of `main`, using its helpers `show`,
  `settle`, `starts`, `prompts`, `completeReply`, `gatewayEvent`, `conversationMode`, `vadRoute`, `windows`).

**Interfaces:**
- Consumes: `CarModeSession`, `CarModeBridge`, `carSnapshotOf` (Tasks 3-4).
- Produces: workspace field `_car` (`CarModeSession`) and `bool _carSend`. Task 7 uses `_car.active` and
  `_car.logDelivery`.

- [ ] **Step 1: Write the failing tests** (append inside `main()` of `test/voice_workspace_test.dart`, after
  the last test; add `import 'package:wing/car_mode/car_mode_screen.dart';` at the top)

```dart
  // Car mode: one big button over the chat (docs/CAR_MODE.md).
  Finder carButton() => find.byKey(const ValueKey('car-button'));
  Future<void> openCarMode(WidgetTester tester) async {
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

  Future<void> holdExit(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('car-exit'))),
    );
    await tester.pump(const Duration(milliseconds: 1100));
    await gesture.up();
    await settle(tester);
  }

  testWidgets('car mode: three rounds by tap only with conversation mode off', (
    tester,
  ) async {
    await conversationMode(false);
    await show(tester);
    await openCarMode(tester);
    expect(find.byType(CarModeScreen), findsOneWidget);
    expect(find.text('Tap to talk'), findsOneWidget);
    expect(device.keepScreenOnCalls, [true]);
    await tapCar(tester);
    expect(starts(), 1);
    expect(find.text('Listening'), findsOneWidget);
    for (var round = 1; round <= 3; round++) {
      final id = device.recording;
      await tapCar(tester); // ends the round and sends, although Stop-like
      device.stream.add({'id': id, 'text': 'Question $round', 'final': true});
      await settle(tester);
      expect(prompts(), round);
      await completeReply(tester, 'Answer $round.');
      expect(device.spoken, 'Answer $round.');
      expect(starts(), round + 1); // the loop reopened the microphone
    }
    // The saved preference was never touched.
    expect(controller.preferences.getString(VoicePreferences.conversationKey), 'off');
    await holdExit(tester);
    expect(find.byType(CarModeScreen), findsNothing);
    expect(device.recording, isNull);
    expect(device.keepScreenOnCalls.last, isFalse);
  });

  testWidgets('car mode: a tap during read-aloud stops it, then opens the microphone', (
    tester,
  ) async {
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
    await holdExit(tester);
  });

  testWidgets('car mode: vad tap ends the round as hands-free and sends', (tester) async {
    await vadRoute();
    await show(tester);
    await openCarMode(tester);
    expect(device.mediaKeysCalls, [true]); // focus kept under the car route
    await tapCar(tester);
    expect(vadStarts(), 1);
    await windows(tester, 0.9, 30);
    await tapCar(tester);
    expect(device.finishes.single.reason.name, 'mediaKey');
    expect(prompts(), 1);
    expect(device.mediaKeysCalls, [true]);
    gatewayEvent('message.complete', {'text': 'Done.'});
    await settle(tester);
    await holdExit(tester);
  });

  testWidgets('car mode: exit cancels recording and keeps the draft', (tester) async {
    final chat = controller.current!.chat!;
    await controller.updateDraft(chat, 'Typed before');
    await show(tester);
    await openCarMode(tester);
    await tapCar(tester);
    final id = device.recording;
    await holdExit(tester);
    expect(device.cancelled, contains(id));
    expect(chat.draft, 'Typed before');
    expect(prompts(), 0);
  });

  testWidgets('car mode: a pending approval shows on screen and the tap does nothing', (
    tester,
  ) async {
    await show(tester);
    await openCarMode(tester);
    gatewayEvent('approval', {'request_id': 'approve-1', 'command': 'rm -rf build'});
    await settle(tester);
    expect(find.text('Needs you on screen'), findsOneWidget);
    await tapCar(tester);
    expect(starts(), 0);
    expect(fixture.calls.where((c) => c.$2.contains('approval')), isEmpty);
    await holdExit(tester);
  });
```

`vadStarts`, `windows` and `vadRoute` are declared further up in the same `main()` (wt
`test/voice_workspace_test.dart:455-461`). Place the new tests after them.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=failure`, `  failed step: Run tests` (there is no 'Car mode' menu item).

- [ ] **Step 3: Implement the hooks** (wt lines; re-check them with Basis A6-A9)

3a. Imports, after the other relative imports at the top:

```dart
import '../../car_mode/car_mode_bridge.dart';
import '../../car_mode/car_mode_session.dart';
import '../../car_mode/car_mode_state.dart';
```

(`car_mode_state.dart` is needed by Task 7. If the analyzer reports an unused import after this task,
add it in Task 7 instead.)

3b. Fields, directly after `StreamSubscription<Map<String, dynamic>>? _voiceDeviceEvents;` (wt :178):

```dart
  /// Car mode (docs/CAR_MODE.md): forces the conversation loop while open;
  /// [_carSend] makes the next transcript count as hands-free.
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
      leave: _cancelVoice,
    ),
  );
  bool _loopWanted(VoicePreferences settings) => settings.conversation || _car.active;
```

3c. Replace the four preference checks:

```dart
// wt :244
    if (!_loopWanted(settings)) _conversation = null;
// wt :245
    if (!(settings.autoSpeak || _loopWanted(settings)) || _voiceInput.active) {
// wt :293 (last line of the `ok` expression in _canContinueConversation)
        _loopWanted(VoicePreferences.read(controller.preferences));
// wt :402 (in _dictate)
    _conversation = _loopWanted(settings) ? chat.key : null;
```

3d. In `_dictate`, directly after `await _voiceOutput.stop();` (wt :393):

```dart
    _carSend = false;
```

and at wt :411:

```dart
      final send =
          _conversation == chat.key && (_voiceInput.finishedOnItsOwn || _carSend);
```

`_carSend` is set by the bridge **after** the round started, so the reset above never clears a pending
tap.

3e. Focus, in `didChangeDependencies` (wt :561):

```dart
    _routeIsCurrent = isCurrent || _car.active;
```

3f. Menu: in `onSelected` (wt :982-1022), before `} else if (action == 'parent') {`:

```dart
                  } else if (action == 'car') {
                    unawaited(_car.enter(context));
```

In `itemBuilder` (wt :1023-1047), before the `'refresh'` item:

```dart
                  const PopupMenuItem(value: 'car', child: Text('Car mode')),
```

(After the upstream merge: `const StudioPopupMenuItem(value: 'car', child: Text('Car mode')),`, placed
before `const PopupMenuDivider(),`.)

3g. `dispose` (wt :650): first line of the method body:

```dart
    _car.dispose();
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`. All existing conversation, media-key and screen-on tests must stay green:
- "a running conversation keeps the screen on" still expects `[true, false]`; car mode is not opened there.
- "stacked workspaces leave media keys" is unchanged.

- [ ] **Step 5: Count the hook lines and commit**

Run: `git diff --stat -- lib/core/screens/profile_workspace_screen.dart`
Expected: about `1 file changed, ~40 insertions(+), ~6 deletions(-)` (formatter line breaks included).
Record the exact number in the commit body. Spec §8 estimate: ~35 changed lines. More than 60 means
something that belongs in `lib/car_mode/` landed in the screen; move it out.

```bash
git add lib/core/screens/profile_workspace_screen.dart test/voice_workspace_test.dart
git commit -m "feat(car): car mode entry and hooks in the chat workspace"
```

---

### Task 7: Speaking while Hermes works steers the running turn (shared hook with barge-in)

**Files:**
- Modify: `lib/core/screens/profile_workspace_screen.dart`, `_sendConversationTurn` (wt :300-322)
- Test: `test/voice_workspace_test.dart`

**Interfaces:**
- Consumes: `_car.active`, `_car.logDelivery(CarDelivery)`, `carDeliveryFor(...)` (Task 1), `_composerActions`,
  `_performComposerAction(chat, action, conversation: true)` (wt :2218, :2287).
- Produces: nothing new. When barge-in (t_7e81e040) lands later, its `decideDelivery` hook in the same method
  replaces this block. The barge-in coder must then delete `carDeliveryFor` + this block and keep
  `_car.logDelivery(...)` calls. Put that note in the code comment below.

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
    await tapCar(tester); // thinking → microphone (D1-A)
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
    await holdExit(tester);
  });
```

ANNAHME: `ProfileBrowserFixture` answers `session.steer` with `{}` (`test/support/profile_browser_fixture.dart:249`),
so `controller.steer` records the call and then throws `FormatException('Unsupported steering response.')`.
That exception is shown as a snackbar by `_runValue`. The test only asserts the recorded call, and that is
enough. Do not change the shared fixture.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=failure`, `  failed step: Run tests`. Without the hook, `_sendConversationTurn` ends
the loop on `chat.busy`, so no `session.steer` call is made.

- [ ] **Step 3: Implement** (skip this step if Basis A13 found `decideDelivery`; then barge-in already steers)

In `_sendConversationTurn`, directly after `final text = chat.draft.trim();` (wt :301):

```dart
    // Car mode: speech while Hermes works steers the running turn (spec §6.3).
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

Directly before `_conversationAwaitingReply = true;` (wt :313):

```dart
    _car.logDelivery(CarDelivery.send);
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tools/factory/ci-suite.sh`
Expected: `conclusion=success`.

- [ ] **Step 5: Commit**

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

Open a chat → ⋮ → **Car mode**. The screen becomes one big button for the open chat. The screen stays on
until you leave.

| Shown | A tap does |
|---|---|
| Tap to talk | opens the microphone |
| Listening | ends the round now and sends it |
| Got it | nothing |
| Hermes is working | opens the microphone; what you say steers the running reply (queued if Hermes can't take it now) |
| Reading aloud | stops reading and opens the microphone |
| Needs you on screen | nothing; approve or answer in the chat when parked |
| Didn't work | opens the microphone again |
| No connection | reconnects |

**Leaving:** hold **Hold to exit** (top left, or left in landscape) for 1 s. Back only shows a hint. Leaving:
- cancels a recording without sending;
- stops reading aloud;
- leaves a running reply alone.

Car mode reads replies aloud and reopens the microphone, as in Conversation mode, without changing that
setting. It never shows what you said or the reply text. Steering-wheel media keys keep working on the
on-phone (vad) route.

**Logs** (`adb logcat -s flutter`, prefix `WingCar`): `enter route=…`, `tap phase=… action=…`,
`stopSpeech ms=…`, `deliver kind=…`, `exit reason=…`. They never contain text.

**Limits:**
- Wing must be in the foreground; another app in front ends a running round.
- On the `hermes` input route, every round ends by tap.
- After a queued (not steered) utterance, the microphone stays closed until you tap.
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

Open every `build/voice-review-bin/car-*.png` and compare with
`docs/superpowers/specs/2026-10-14-wing-car-mode-shots/` (same state, size and theme). Check:
- the label is readable from arm's length;
- night has no white area;
- the 200 % text renders scale down without clipping;
- the pill stays ≥ 48 dp;
- the listening ring is visible;
- the landscape strip does not truncate "Hold to exit" into nothing.

Fix what looks wrong (spacing and sizes in `car_mode_screen.dart`), re-run, commit. Passing widget tests
alone are not enough (AGENTS.md "Design before implementation" 4).

- [ ] **Step 3: Build the APK**

Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: `… conclusion=success`. There is no Kotlin change, but this proves the release Dart build.

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
(`git show wt/t_24ef9c3d:docs/superpowers/plans/2026-10-13-wing-voice-vad-input.md`, Task 15, lines
~4093-4110). This covers `hadb install`, or the tailnet `curl` + `pm install -r` fallback for large files.
If the phone is locked (`hadb shell 'dumpsys window | grep isKeyguardShowing'` → `true`), post a
notification asking Birk to unlock, as in that task.

**Speech input:** use the VAD plan's synthetic self-test WAV (`/sdcard/Music/wingvad-selftest.wav`, same
task). Play it with the player, then bring Wing to the front, as in its steps 1-2. ANNAHME: playing the
WAV and returning to Wing keeps car mode open. Car mode survives the pause; the round is started by the tap
after returning. If the WAV path is not workable, ask Birk via notification to say a synthetic test
sentence ("Testsatz eins, bitte antworte mit zwei Sätzen") at each round.

**Settings before:** input route `vad`, Conversation mode **off** (to prove car mode forces the loop), a
test chat with a harmless prompt history.

Record before, and restore after:
- `hadb shell 'settings get system screen_off_timeout'`
- `hadb shell 'settings get system accelerometer_rotation'`
- `hadb shell 'settings get system user_rotation'`

Clear the log first: `hadb shell 'logcat -c'`.

| # | Do | Observe (pass criterion) |
|---|---|---|
| 1 | Open the chat → ⋮ → Car mode (`uiautomator dump` + `input tap`) | Screen shows "Tap to talk". `hadb shell 'logcat -d -s flutter' \| grep WingCar` → `WingCar enter route=vad` |
| 2 | Round 1: tap the button, play speech, tap again | `tap phase=idle action=talk`, `tap phase=listening action=sendNow`, `deliver kind=send`. The chat gets the user message. The reply is read aloud. Afterwards the mic reopens on its own ("Listening" + start beep) |
| 3 | Rounds 2 and 3: same, tap only | 3 `deliver kind=send` lines in total. No touch outside the big button and the exit pill during the three rounds |
| 4 | Double tap fast (two taps < 0.3 s) in idle | One `action=talk` and one `action=debounced`. A deliberate second tap ≥ 0.7 s later is accepted |
| 5 | During read-aloud (a reply of ≥ 2 sentences), tap | `WingCar stopSpeech ms=<n>` with **n ≤ 500** (ANNAHME until measured). Audio audibly stops within 0.5 s (Birk or the worker listening). Then "Listening" |
| 6 | Tap while "Hermes is working" (send a prompt that takes ≥ 10 s: "Führe im Terminal sleep 15 aus und antworte dann mit fertig"), speak, tap | `deliver kind=steer`. The chat shows a steer row |
| 7 | Screen on: `hadb shell 'settings put system screen_off_timeout 30000'`, leave car mode idle **10 min** | `hadb shell 'dumpsys power \| grep -E "mWakefulness="'` → `Awake` at 10 min. `hadb shell 'dumpsys window windows \| grep -E "KEEP_SCREEN_ON"'` lists the Wing window |
| 8 | Landscape: `settings put system accelerometer_rotation 0`, `settings put system user_rotation 1` | `uiautomator dump`: the `car-button` bounds are wider than tall, and "Hold to exit" is fully visible. Run one round (tap → speak → tap → reply) |
| 9 | Split screen with Maps (if the launcher allows), then a tap | ANNAHME (spec §4.1): the round runs. If it ends at once, record "car mode needs Wing fullscreen" in `docs/CAR_MODE.md` limits |
| 10 | Approval: prompt "Lösche die Datei /tmp/wing-car-test mit rm" (synthetic file created first via the same chat) | "Needs you on screen". A tap logs `action=ignore`, and nothing is approved |
| 11 | Back gesture (`input keyevent 4`) | Hint "Hold Exit to leave car mode". Car mode stays (`WingCar exit` absent) |
| 12 | Hold the exit pill 1.2 s (`input swipe x y x y 1200`) | `WingCar exit reason=hold`. Back in the chat. The draft is unchanged. `KEEP_SCREEN_ON` is gone from `dumpsys window windows` (unless a conversation still runs) |
| 13 | Privacy: `hadb shell 'logcat -d' \| grep -i -E "Testsatz\|fertig\|wing-car-test"` | Only lines **not** from `WingCar`/`WingVad` may match. Any `WingCar` line containing spoken or reply text fails |

**Restore** the three settings and delete the test file and WAV as in the VAD task. Post the results
(table with pass/fail and the measured `stopSpeech ms` values) as a card comment. Birk confirms the driving
feel himself on a real drive; that is not part of this worker card.

---

## If Birk picks another option

Apply before Task 1, and adjust the tests named.

- **D1-B (tap stops the running turn):**
  - In `carTapActionFor`, thinking → `CarTapAction.talk` stays.
  - Add `required this.interrupt` (`Future<void> Function()`) to `CarModeBridge`. The workspace passes
    `() async { final chat = …; if (chat != null) await _run(() => controller.stop(chat)); }`.
  - In `CarModeSession.tap`, for `phase == CarPhase.thinking`, `await bridge.interrupt()` before
    `bridge.talk()`.
  - Task 7 becomes unnecessary (the turn is cancelled, so the next utterance is a normal send). Replace its
    test with "tap while working calls `session.interrupt`" (`fixture.calls` has `session.interrupt`).
  - Text: hint 'Tap to stop and talk'.
- **D1-C (tap ignored while working):**
  - `carTapActionFor`: `CarPhase.thinking => CarTapAction.ignore`; hint `null`.
  - Drop Task 7.
- **D2-B (double tap):**
  - `_ExitPill`: replace the hold with a 400 ms double-tap window (`onTap` stores time; a second tap within
    400 ms → `onExit`; the first tap shows 'Tap again to exit').
  - Label 'Double-tap to exit'. Back hint 'Double-tap Exit to leave car mode'.
  - Adjust the screen test "exit needs a 1 s hold".
- **D2-C (plain exit, Back leaves):**
  - Pill `onTap: onExit`, label 'Exit'.
  - `PopScope(canPop: true)` plus `onPopInvokedWithResult: (didPop, _) { if (didPop) widget.session.exit('back'); }`.
    `exit` must then skip `navigator.pop()` because the route is already popping (guard with `route.isActive`).
- **D3-B (circle):**
  - In `_bigButton`, the `Material` gets `shape: const CircleBorder()`, sized
    `min(box.maxWidth * .86, box.maxHeight * .6)`, centred, with the texts **below** it, outside the tap
    target, on `tokens.surface`.
  - The screen test "tap anywhere" becomes "tap on the circle".
  - Update the area expectation (> 30 % of the screen).

## Self-review notes (plan author)

- **Spec coverage:**
  - §4.1 enter/exit/auto-exit → Tasks 3, 5, 6.
  - §4.2 table, forced loop, tap-send, debounce, haptics → Tasks 1, 3, 6.
  - §4.3 nothing shown → Task 5 (no transcript widgets).
  - §4.4 look → Tasks 2, 5.
  - §4.5 orientation → Task 5 (both layouts, no lock).
  - §5 files → Tasks 1-5.
  - §6.1-6.4 hooks → Tasks 6-7.
  - §7 logs → Task 3 (test "logs never contain…"), Task 9 step 13.
  - §8 upstream lines → Task 6 step 5.
  - §10 tests → Tasks 1-7.
  - Device acceptance → Task 9.
- **Not covered on purpose:** spec §11 "Later" items.

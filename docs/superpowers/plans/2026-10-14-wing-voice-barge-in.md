# Wing Voice barge-in Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In Conversation mode on the vad route, Wing keeps listening while Hermes works and steers each
utterance into the running turn (part (a), done). Speaking during read-aloud stops it **only while the
output goes to headphones** (part (b), gated on the headphone echo measurement S2), and the message
spoken over the reply tells Hermes that the reply was cut off.

**Architecture:** A chat-agnostic `TurnListener` runs VAD "listen rounds" on the existing `VoiceDevice`;
a pure policy file decides thresholds and delivery; `BargeInCoordinator` turns transcripts into
steer/queue/send calls through `ListenTarget` (all merged). Part (b) adds a native
`HeadphoneRouteChannel` (raw route facts: routed device type, Bluetooth class, Android car mode), a pure
Dart classifier with a cached `HeadphoneRoute` notifier, thin screen hooks around the speech queue, and
the interrupted-reply hint inside the coordinator.

**Tech Stack:** Flutter/Dart (flutter_test), Kotlin (Android `AudioManager`, `AudioDeviceCallback`,
`BluetoothManager`, `UiModeManager`, sherpa-onnx Silero), Hermes TUI gateway JSON-RPC (`session.steer`,
`prompt.submit`).

**Spec:** `docs/superpowers/specs/2026-10-14-wing-voice-barge-in-design.md` (read §3.4, §3.6, §5.3, §6, §7
before Task 15).

## Global Constraints

- Target: latest upstream Hermes, unmodified. Steer path verified at `NousResearch/hermes-agent` `main`
  `e06df9c2eae6901f4c88f464e0ae6e753c0428b8`. No backend patches, plugins or custom endpoints. Part (b)
  and the hint add no gateway call.
- Base: `voice-offline` at or after `e00ee3c9` (contains the part (a) merge `fff2ed93`). Task R0 checks it.
- Strategy rule 1: new logic goes in `lib/voice_offline/` and the Kotlin package
  `com.tarkilhk.wing.voiceoffline`; existing files get thin hooks only.
  `lib/core/controllers/voice_input_controller.dart` and
  `android/app/src/main/kotlin/com/tarkilhk/wing/VoicePlayback.kt` are **not touched**.
- D1 (Birk 14.10.): `voice.listen_turn` defaults **on**, own switch, persisted. Switch off → the mic stays
  closed while Hermes works.
- D2 (Birk 14.10.): voice barge-in into read-aloud **only while the routed output device is headphones**
  (spec §3.4.1 table). Over the phone speaker and in the car only tap / media key interrupt. Bluetooth
  counts only with class `AUDIO_VIDEO_WEARABLE_HEADSET` (0x0404) or `AUDIO_VIDEO_HEADPHONES` (0x0418);
  unknown class, car audio, hands-free, Wing car mode and Android car mode never count.
- D3 (Birk 14.10.): a reply that Birk talked over or barged into is not read further; it stays in the chat.
- New runtime permission `android.permission.BLUETOOTH_CONNECT`, requested only when the user switches
  "Interrupt read-aloud by speaking" on.
- Defaults: `voice.listen_turn` **on**, `voice.listen_min_speech_ms` **400** (choices 250/400/600),
  `voice.barge_in_playback` **off**.
- Playback gate start values: `bargeGateThreshold = 0.7`, `bargeGateWindows = 16` (512 ms). Task 7 may
  replace them from the S2 numbers.
- Echo thresholds (S2 only is the gate): pass `run50 ≤ 6` and `p99 < 0.5`; marginal `run50 ≤ 15` and
  `p99 < 0.75`. S1 (speaker) and S3 (car) are optional and informational.
- Interrupted-reply hint: exactly
  `[Hinweis von Wing: Die vorige Antwort wurde beim Vorlesen abgebrochen und nicht zu Ende gehört.]`,
  appended after a blank line, only to `send`/`queue` deliveries of an utterance whose round fired the
  playback gate. Never on a steer. No percentage.
- Logs: prefix `WingBargeIn`, via `debugPrint` (Kotlin: nothing new). **Never** transcript, reply,
  prompt or hint text, session ids, Bluetooth addresses or device names.
- Test texts are synthetic. No session data or personal text in the repo.
- One command per Bash call. No `cd`, no `&&`/`;`, no `$VAR`, no `$( )`.
- Suite: `bash tools/factory/ci-suite.sh <test path>`. It runs flutter analyze + flutter test on GitHub
  Actions; expected last line `ci-suite: run <id> conclusion=success`. The script builds the committed
  HEAD, so commit before running it.
- Kotlin compile: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`; expected last line
  `dispatch-check: voice-apk.yml run <id> conclusion=success …`.
- Phone steps (install, `hadb`, measurement, listening tests) and edits of Birk's profile config are done
  by the **Hermes worker**, never by a Claude Code subagent. These tasks are marked **[WORKER]**.
- Commit after every task on the working branch. No merge, no push except what the two factory scripts
  do themselves.

## File map (remaining work)

| File | Status | Responsibility |
|---|---|---|
| `android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/HeadphoneRouteChannel.kt` | new (Task 15) | Channel `com.tarkilhk.wing/headphone_route`: `current`, `bluetoothAllowed`, `requestBluetooth`, pushes `changed` |
| `android/app/src/main/AndroidManifest.xml` | hook (Task 15) | `BLUETOOTH_CONNECT` |
| `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt` | hook (Task 15) | create/close the route channel, forward its permission result |
| `lib/voice_offline/headphone_route.dart` | new (Task 15) | `OutputRoute`, `classifyRoute`, `routeLogLine`, `HeadphoneRouteHost`, `AndroidHeadphoneRouteHost`, `HeadphoneRoute` |
| `test/voice_offline/headphone_route_test.dart` | new (Task 15) | |
| `test/support/headphone_route_fixture.dart` | new (Task 15) | fake host |
| `lib/voice_offline/barge_in_settings.dart` | change (Task 16) | subtitle, permission request, `route`/`playbackAvailable` params, route line before the probe |
| `lib/voice_offline/barge_in_policy.dart` | change (Tasks 16, 7, 17) | drop `bargeInPlaybackHint`; gate constants; hint |
| `test/voice_preferences_test.dart` | change (Task 16) | settings-row tests and renders |
| `lib/voice_offline/turn_listener.dart` | change (Tasks 10, 17) | `playback` getter; `utteranceBarged` |
| `lib/voice_offline/barge_in_coordinator.dart` | change (Task 17) | hint on send/queue after a barge |
| `lib/core/screens/profile_workspace_screen.dart` | hooks (Task 10) | route parameter/field, playback decision, route re-evaluation |
| `test/voice_offline/turn_listener_test.dart`, `test/voice_offline/barge_in_coordinator_test.dart`, `test/voice_offline/barge_in_policy_test.dart`, `test/voice_workspace_test.dart` | change (Tasks 10, 17) | |
| `docs/VOICE_BARGE_IN.md` | change (Tasks 6, 7, 11R) | measurement, decision, behaviour |
| `/home/birk/.hermes/profiles/birk/config.yaml` (outside the repo) | change (Task 18 [WORKER]) | `platform_hints.wing.append` sentence |

## Task order and dependencies (remaining work)

```
R0 → 15 → 16 ──→ 6 [WORKER + Birk, S2] → 7 ─┬─ pass/marginal → 10 → 17 → 11R → 18 [WORKER] → 13 [WORKER] → 14 [WORKER + Birk]
                 (6 may also run on the        └─ fail → revert 15+16, skip 10/17/18 → 11R ((b) not built) → 13 → 14 (a only)
                  existing Task 5 APK; then
                  the route checks move to 13)
```

- Tasks 15 and 16 do not need the measurement. Built before Birk's headphone session, they let Task 6
  check the headphone detection on the device in the same session (route log before each probe).
- Task 6 waits for Birk with headphones. Nothing else in the chain can replace S2.
- Task 18 needs Task 17 merged and deployed to Birk's phone before it matters, but it is harmless earlier
  (the sentence only applies when the hint appears).

---

## Part 1 — done (part (a), merged into `voice-offline` in `fff2ed93`)

### Task 0: Basis check — Done, merged in fff2ed93.
### Task 1: Capture options `keepPlayback` and `startCue` — Done, merged in fff2ed93.
### Task 2: Preferences and pure policy — Done, merged in fff2ed93.
### Task 3: `TurnListener` — Done, merged in fff2ed93.
### Task 4: Settings rows and the debug echo probe — Done, merged in fff2ed93.
### Task 5: Probe build for the phone — Done on device card t_a731ee0d (versionName 1.1.3, SOURCE_COMMIT fff2ed93).
### Task 8: `BargeInCoordinator` — Done, merged in fff2ed93.
### Task 9: Screen hooks for (a) "listen while Hermes works" — Done, merged in fff2ed93.
### Task 11 (steps 1-3: `docs/VOICE_BARGE_IN.md`, commit, suite) — Done, merged in fff2ed93 (doc commit 1a1ff326). The doc update for this revision is Task 11R.
### Task 12: Rendered review of the listening row and settings — Done, merged in fff2ed93.

---

## Part 2 — remaining work

### Task R0: Basis and hook locations at the current HEAD (no code)

**Files:** none. **Interfaces:** none.

- [ ] **Step 1: Part (a) included**

Run: `git merge-base --is-ancestor fff2ed93 HEAD`
Expected: exit code 0, no output. If 1: stop and report "part (a) merge missing from base".

- [ ] **Step 2: Re-verify every hook location (one command each)**

```
git grep -n "private val background\|fun permissionResult\|fun close()" -- android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt
git grep -n "android.permission.RECORD_AUDIO" -- android/app/src/main/AndroidManifest.xml
git grep -n "voiceChannel?.permissionResult" -- android/app/src/main/kotlin/com/tarkilhk/wing/MainActivity.kt
git grep -n "final BackgroundVoiceHost? backgroundVoice\|this.backgroundVoice\|late final _bargeIn\|void _speakCompletedReply\|unawaited(_bargeIn.close('turnEnd')\|if (!finished) {\|_bargeIn.beginTurn();\|void _openListen\|_car.addListener(_carActiveChanged)\|_car.removeListener(_carActiveChanged)\|_bargeIn.dispose()" -- lib/core/screens/profile_workspace_screen.dart
git grep -n "bool get isOpen\|void Function(String text)? onUtterance\|_gate = playback ? PlaybackGate() : null;\|final onset = _gate?.feed\|onUtterance?.call(text)" -- lib/voice_offline/turn_listener.dart
git grep -n "void _utterance\|Future<void> _deliver\|case ListenDelivery.queue:\|case ListenDelivery.send:" -- lib/voice_offline/barge_in_coordinator.dart
git grep -n "const bool bargeInPlaybackAvailable\|const String? bargeInPlaybackHint\|const double bargeGateThreshold\|const int bargeGateWindows" -- lib/voice_offline/barge_in_policy.dart
git grep -n "required this.onSave,\|if (bargeInPlaybackAvailable)\|Future<void> _probe()" -- lib/voice_offline/barge_in_settings.dart
git grep -n "bool get active" -- lib/car_mode/car_mode_session.dart
git grep -n "late BackgroundVoiceFixture background\|background = BackgroundVoiceFixture()\|await background.close()\|backgroundVoice: background," -- test/voice_workspace_test.dart
git grep -n "expect(find.text('Interrupt read-aloud by speaking'), findsNothing);" -- test/voice_preferences_test.dart
```

Expected: every command prints at least one line. At `e00ee3c9` they were:
VoiceChannel.kt :23 / :115 / :132; manifest :4; MainActivity.kt :320; screen :103, :120, :193, :297,
:319, :331, :448, :496, :823, :899, :911; turn_listener.dart :40, :28, :74, :120, :191;
barge_in_coordinator.dart :93, :101, :117, :120; barge_in_policy.dart :14, :17, :21, :22;
barge_in_settings.dart :22, :123, :46; car_mode_session.dart :40; voice_workspace_test.dart :53, :78,
:99, :123; voice_preferences_test.dart :332. Numbers may have shifted; use the printed lines from here on.

- [ ] **Step 3: Hermes steer statuses unchanged upstream**

Run: `curl -s -m 60 -H "Accept: application/vnd.github.raw" "https://api.github.com/repos/NousResearch/hermes-agent/contents/tui_gateway/methods_session_interrupt.py?ref=main" -o build/hermes-msi.py`
Then: `grep -n "\"rejected\"\|_session_compression_in_flight\|_correction_method(\"session.steer\"" build/hermes-msi.py`
Expected: the three patterns are present. If not: stop and report it.

No commit: nothing changed.

---

### Task 15: Headphone route detection (native facts, pure Dart verdict)

**Files:**
- Create: `android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/HeadphoneRouteChannel.kt`
- Modify: `android/app/src/main/AndroidManifest.xml` (after the `RECORD_AUDIO` line, :4)
- Modify: `android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt` (:23 field, :115 `permissionResult`, :132 `close`)
- Create: `lib/voice_offline/headphone_route.dart`
- Create: `test/support/headphone_route_fixture.dart`
- Test: `test/voice_offline/headphone_route_test.dart`

**Interfaces:**
- Native channel `com.tarkilhk.wing/headphone_route`:
  - `current` → `{supported: bool, type: int, bluetoothClass: int?, androidCarMode: bool}`
  - `bluetoothAllowed` → `bool`; `requestBluetooth` → `bool` (true when granted or not needed)
  - native → Dart `changed` with the same map as `current`, on every audio-device add/remove and after
    a permission answer.
- Produces (Dart, `headphone_route.dart`):
  - `class OutputRoute { const OutputRoute({required bool supported, required int type, int? bluetoothClass, bool androidCarMode = false}); factory OutputRoute.fromMap(Map<Object?, Object?>); static const unknown; }`
  - `typedef RouteVerdict = ({bool headphones, String reason});`
  - `RouteVerdict classifyRoute(OutputRoute route, {required bool wingCarMode})`
  - `String routeLogLine(OutputRoute route, RouteVerdict verdict)`
  - `abstract interface class HeadphoneRouteHost { Future<OutputRoute> current(); Stream<OutputRoute> get changes; Future<bool> bluetoothAllowed(); Future<bool> requestBluetooth(); }`
  - `class AndroidHeadphoneRouteHost implements HeadphoneRouteHost { static final instance; }`
  - `class HeadphoneRoute extends ChangeNotifier { HeadphoneRoute(HeadphoneRouteHost host, {required bool Function() wingCarMode}); bool get headphones; Future<bool> refresh(); void carModeChanged(); }`
- Produces (test support): `class HeadphoneRouteFixture implements HeadphoneRouteHost` with
  `static const speaker`, `static const headphones`, fields `route`, `allowed`, `grant`, `requests`,
  methods `change(OutputRoute)`, `close()`.

- [ ] **Step 1: Test fixture**

`test/support/headphone_route_fixture.dart`:

```dart
import 'dart:async';

import 'package:wing/voice_offline/headphone_route.dart';

class HeadphoneRouteFixture implements HeadphoneRouteHost {
  static const speaker = OutputRoute(supported: true, type: 2);
  static const headphones = OutputRoute(supported: true, type: 4);

  OutputRoute route = speaker;
  bool allowed = true;
  bool grant = true;
  int requests = 0;
  final _changes = StreamController<OutputRoute>.broadcast(sync: true);

  @override
  Stream<OutputRoute> get changes => _changes.stream;

  @override
  Future<OutputRoute> current() async => route;

  @override
  Future<bool> bluetoothAllowed() async => allowed;

  @override
  Future<bool> requestBluetooth() async {
    requests++;
    allowed = grant;
    return grant;
  }

  /// Simulates plugging in, unplugging or a Bluetooth change.
  void change(OutputRoute next) {
    route = next;
    _changes.add(next);
  }

  Future<void> close() => _changes.close();
}
```

- [ ] **Step 2: Write the failing test**

`test/voice_offline/headphone_route_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/voice_offline/headphone_route.dart';
import '../support/headphone_route_fixture.dart';

void main() {
  group('classifyRoute (spec §3.4.1)', () {
    const cases = <(String, OutputRoute, bool, bool, String)>[
      ('wired headphones', OutputRoute(supported: true, type: 4), false, true, 'wired'),
      ('wired headset', OutputRoute(supported: true, type: 3), false, true, 'wired'),
      ('USB headset', OutputRoute(supported: true, type: 22), false, true, 'wired'),
      ('A2DP headphones', OutputRoute(supported: true, type: 8, bluetoothClass: 0x0418), false, true, 'bluetoothHeadphones'),
      ('A2DP headset', OutputRoute(supported: true, type: 8, bluetoothClass: 0x0404), false, true, 'bluetoothHeadphones'),
      ('LE headset', OutputRoute(supported: true, type: 26, bluetoothClass: 0x0404), false, true, 'bluetoothHeadphones'),
      ('car audio on A2DP', OutputRoute(supported: true, type: 8, bluetoothClass: 0x0420), false, false, 'bluetoothOther'),
      ('hands-free on A2DP', OutputRoute(supported: true, type: 8, bluetoothClass: 0x0408), false, false, 'bluetoothOther'),
      ('uncategorized A2DP', OutputRoute(supported: true, type: 8, bluetoothClass: 0x0400), false, false, 'bluetoothOther'),
      ('A2DP class unknown', OutputRoute(supported: true, type: 8), false, false, 'bluetoothClassUnknown'),
      ('LE headset class unknown', OutputRoute(supported: true, type: 26), false, false, 'bluetoothClassUnknown'),
      ('phone speaker', OutputRoute(supported: true, type: 2), false, false, 'speaker'),
      ('Bluetooth SCO', OutputRoute(supported: true, type: 7), false, false, 'other'),
      ('BLE speaker', OutputRoute(supported: true, type: 27), false, false, 'other'),
      ('Android 12 or older', OutputRoute.unknown, false, false, 'unsupported'),
      ('Android car mode', OutputRoute(supported: true, type: 4, androidCarMode: true), false, false, 'androidCarMode'),
      ('Wing car mode', OutputRoute(supported: true, type: 4), true, false, 'carMode'),
    ];
    for (final (name, route, carMode, headphones, reason) in cases) {
      test(name, () {
        final verdict = classifyRoute(route, wingCarMode: carMode);
        expect(verdict.headphones, headphones);
        expect(verdict.reason, reason);
      });
    }
  });

  test('the route log line carries numbers only', () {
    const bluetooth = OutputRoute(supported: true, type: 8, bluetoothClass: 0x0418);
    expect(
      routeLogLine(bluetooth, classifyRoute(bluetooth, wingCarMode: false)),
      'route headphones=1 reason=bluetoothHeadphones type=8 btClass=0x0418 androidCarMode=0',
    );
    const speaker = OutputRoute(supported: true, type: 2);
    expect(
      routeLogLine(speaker, classifyRoute(speaker, wingCarMode: false)),
      'route headphones=0 reason=speaker type=2 btClass=none androidCarMode=0',
    );
  });

  test('OutputRoute reads the channel map', () {
    final route = OutputRoute.fromMap({
      'supported': true,
      'type': 8,
      'bluetoothClass': 1048,
      'androidCarMode': false,
    });
    expect(route.supported, isTrue);
    expect(route.type, 8);
    expect(route.bluetoothClass, 0x0418);
    expect(OutputRoute.fromMap({}).supported, isFalse);
  });

  group('HeadphoneRoute', () {
    late HeadphoneRouteFixture host;
    late HeadphoneRoute route;
    var carMode = false;
    var notified = 0;

    setUp(() {
      host = HeadphoneRouteFixture();
      carMode = false;
      notified = 0;
      route = HeadphoneRoute(host, wingCarMode: () => carMode)
        ..addListener(() => notified++);
    });
    tearDown(() async {
      route.dispose();
      await host.close();
    });

    test('refresh reads the routed device', () async {
      host.route = HeadphoneRouteFixture.headphones;
      expect(await route.refresh(), isTrue);
      expect(route.headphones, isTrue);
      expect(notified, 1);
    });

    test('route changes close and reopen the verdict', () async {
      host.route = HeadphoneRouteFixture.headphones;
      await route.refresh();
      host.change(HeadphoneRouteFixture.speaker);
      expect(route.headphones, isFalse);
      host.change(HeadphoneRouteFixture.headphones);
      expect(route.headphones, isTrue);
      expect(notified, 3);
    });

    test('Wing car mode closes the verdict', () async {
      host.route = HeadphoneRouteFixture.headphones;
      await route.refresh();
      carMode = true;
      route.carModeChanged();
      expect(route.headphones, isFalse);
    });
  });
}
```

- [ ] **Step 3: Commit the tests and run them to verify they fail**

```
git add test/support/headphone_route_fixture.dart test/voice_offline/headphone_route_test.dart
git commit -m "test(voice): headphone route verdict for barge-in during read-aloud"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/headphone_route_test.dart`
Expected: `conclusion=failure` (analyzer: "Target of URI doesn't exist: 'package:wing/voice_offline/headphone_route.dart'").

- [ ] **Step 4: Dart implementation**

`lib/voice_offline/headphone_route.dart`:

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'barge_in_policy.dart';

/// Raw facts about the device Android routes read-aloud to (the attributes
/// of VoicePlayback.kt: USAGE_MEDIA, CONTENT_TYPE_SPEECH). [type] is an
/// AudioDeviceInfo.TYPE_* value, [bluetoothClass] a BluetoothClass.Device
/// code. Dart decides what counts as headphones ([classifyRoute]).
class OutputRoute {
  const OutputRoute({
    required this.supported,
    required this.type,
    this.bluetoothClass,
    this.androidCarMode = false,
  });

  factory OutputRoute.fromMap(Map<Object?, Object?> map) => OutputRoute(
    supported: map['supported'] == true,
    type: (map['type'] as num?)?.toInt() ?? 0,
    bluetoothClass: (map['bluetoothClass'] as num?)?.toInt(),
    androidCarMode: map['androidCarMode'] == true,
  );

  /// Android 12 or older, or the query failed.
  static const unknown = OutputRoute(supported: false, type: 0);

  final bool supported;
  final int type;

  /// Null when Android does not let Wing read it (no Nearby devices access,
  /// anonymised address, Bluetooth off) or the device is not Bluetooth.
  final int? bluetoothClass;
  final bool androidCarMode;
}

typedef RouteVerdict = ({bool headphones, String reason});

const _wired = {3, 4, 22}; // WIRED_HEADSET, WIRED_HEADPHONES, USB_HEADSET
const _bluetooth = {8, 26}; // BLUETOOTH_A2DP, BLE_HEADSET
const _speaker = 2; // BUILTIN_SPEAKER
const _headphoneClasses = {0x0404, 0x0418}; // WEARABLE_HEADSET, HEADPHONES

/// Spec §3.4.1 (D2): voice barge-in into read-aloud only with headphones.
/// Conservative: a car kit, a hands-free unit or an unreadable Bluetooth
/// class is not headphones, and car mode always closes the gate.
RouteVerdict classifyRoute(OutputRoute route, {required bool wingCarMode}) {
  if (!route.supported) return (headphones: false, reason: 'unsupported');
  if (wingCarMode) return (headphones: false, reason: 'carMode');
  if (route.androidCarMode) {
    return (headphones: false, reason: 'androidCarMode');
  }
  if (_wired.contains(route.type)) return (headphones: true, reason: 'wired');
  if (_bluetooth.contains(route.type)) {
    final deviceClass = route.bluetoothClass;
    if (deviceClass == null) {
      return (headphones: false, reason: 'bluetoothClassUnknown');
    }
    return _headphoneClasses.contains(deviceClass)
        ? (headphones: true, reason: 'bluetoothHeadphones')
        : (headphones: false, reason: 'bluetoothOther');
  }
  return (
    headphones: false,
    reason: route.type == _speaker ? 'speaker' : 'other',
  );
}

/// Numbers and states only: never an address or a device name.
String routeLogLine(OutputRoute route, RouteVerdict verdict) {
  final deviceClass = route.bluetoothClass;
  final btClass = deviceClass == null
      ? 'none'
      : '0x${deviceClass.toRadixString(16).padLeft(4, '0')}';
  return 'route headphones=${verdict.headphones ? 1 : 0} '
      'reason=${verdict.reason} type=${route.type} btClass=$btClass '
      'androidCarMode=${route.androidCarMode ? 1 : 0}';
}

/// Native side of the route check (HeadphoneRouteChannel.kt).
abstract interface class HeadphoneRouteHost {
  Future<OutputRoute> current();

  /// Fires on every audio device added or removed.
  Stream<OutputRoute> get changes;

  /// Wing may read Bluetooth classes (always true below Android 12).
  Future<bool> bluetoothAllowed();

  /// Asks for Nearby devices access; resolves to whether Wing has it.
  Future<bool> requestBluetooth();
}

class AndroidHeadphoneRouteHost implements HeadphoneRouteHost {
  AndroidHeadphoneRouteHost._() {
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      if (call.method == 'changed' && args is Map) {
        _changes.add(OutputRoute.fromMap(args));
      }
    });
  }

  static final instance = AndroidHeadphoneRouteHost._();
  static const _channel = MethodChannel('com.tarkilhk.wing/headphone_route');
  final _changes = StreamController<OutputRoute>.broadcast();

  @override
  Stream<OutputRoute> get changes => _changes.stream;

  @override
  Future<OutputRoute> current() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('current');
      return map == null ? OutputRoute.unknown : OutputRoute.fromMap(map);
    } on Object {
      return OutputRoute.unknown;
    }
  }

  @override
  Future<bool> bluetoothAllowed() async {
    try {
      return await _channel.invokeMethod<bool>('bluetoothAllowed') ?? true;
    } on Object {
      return true;
    }
  }

  @override
  Future<bool> requestBluetooth() async {
    try {
      return await _channel.invokeMethod<bool>('requestBluetooth') ?? false;
    } on Object {
      return false;
    }
  }
}

/// Cached headphone verdict: the playback decision in the workspace screen
/// is synchronous. Logs one `route` line whenever the inputs change.
class HeadphoneRoute extends ChangeNotifier {
  HeadphoneRoute(this.host, {required bool Function() wingCarMode})
    : _wingCarMode = wingCarMode {
    _changes = host.changes.listen(_apply);
  }

  final HeadphoneRouteHost host;
  final bool Function() _wingCarMode;
  late final StreamSubscription<OutputRoute> _changes;
  OutputRoute _route = OutputRoute.unknown;
  bool _headphones = false;
  String? _logged;
  bool _disposed = false;

  bool get headphones => _headphones;

  Future<bool> refresh() async {
    _apply(await host.current());
    return _headphones;
  }

  /// Wing car mode switched on or off; re-evaluate the last route.
  void carModeChanged() => _apply(_route);

  void _apply(OutputRoute route) {
    if (_disposed) return;
    _route = route;
    final verdict = classifyRoute(route, wingCarMode: _wingCarMode());
    final line = routeLogLine(route, verdict);
    if (line != _logged) {
      _logged = line;
      bargeLog(line);
    }
    if (verdict.headphones == _headphones) return;
    _headphones = verdict.headphones;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_changes.cancel());
    super.dispose();
  }
}
```

- [ ] **Step 5: Kotlin implementation**

`android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/HeadphoneRouteChannel.kt`:

```kotlin
package com.tarkilhk.wing.voiceoffline

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.UiModeManager
import android.bluetooth.BluetoothManager
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Where read-aloud plays (spec 2026-10-14 barge-in §3.4.1). Returns raw facts only; Dart decides what
 * counts as headphones. The attributes match VoicePlayback (USAGE_MEDIA, CONTENT_TYPE_SPEECH). Never
 * returns or logs a Bluetooth address or device name.
 */
class HeadphoneRouteChannel(private val activity: Activity, messenger: BinaryMessenger) {
    companion object { const val PERMISSION_REQUEST = 7315 }
    private val channel = MethodChannel(messenger, "com.tarkilhk.wing/headphone_route")
    private val audio = activity.getSystemService(AudioManager::class.java)
    private val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
    private var pending: MethodChannel.Result? = null
    private val devices = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>?) { changed() }
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>?) { changed() }
    }

    init {
        channel.setMethodCallHandler(::handle)
        audio.registerAudioDeviceCallback(devices, Handler(Looper.getMainLooper()))
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "current" -> result.success(current())
            "bluetoothAllowed" -> result.success(bluetoothAllowed())
            "requestBluetooth" -> requestBluetooth(result)
            else -> result.notImplemented()
        }
    }

    private fun changed() { channel.invokeMethod("changed", current()) }

    private fun current(): Map<String, Any?> {
        val unsupported = mapOf<String, Any?>("supported" to false, "type" to 0)
        if (Build.VERSION.SDK_INT < 33) return unsupported
        val device = try { audio.getAudioDevicesForAttributes(attributes).firstOrNull() } catch (_: Exception) { null }
            ?: return unsupported
        val ui = activity.getSystemService(UiModeManager::class.java)
        return mapOf(
            "supported" to true,
            "type" to device.type,
            "bluetoothClass" to bluetoothClass(device),
            "androidCarMode" to (ui?.currentModeType == Configuration.UI_MODE_TYPE_CAR),
        )
    }

    private fun bluetoothAllowed() = Build.VERSION.SDK_INT < 31 ||
        activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    /** Null unless the device is a Bluetooth sink whose class Android lets Wing read. */
    @SuppressLint("MissingPermission")
    private fun bluetoothClass(device: AudioDeviceInfo): Int? {
        if (device.type != AudioDeviceInfo.TYPE_BLUETOOTH_A2DP && device.type != AudioDeviceInfo.TYPE_BLE_HEADSET) return null
        if (!bluetoothAllowed()) return null
        return try {
            val adapter = activity.getSystemService(BluetoothManager::class.java)?.adapter ?: return null
            adapter.getRemoteDevice(device.address).bluetoothClass?.deviceClass
        } catch (_: Exception) { null }
    }

    private fun requestBluetooth(result: MethodChannel.Result) {
        if (bluetoothAllowed()) return result.success(true)
        if (pending != null) return result.success(false)
        pending = result
        activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), PERMISSION_REQUEST)
    }

    fun permissionResult(grants: IntArray) {
        pending?.success(grants.firstOrNull() == PackageManager.PERMISSION_GRANTED); pending = null
        changed()
    }

    fun close() {
        audio.unregisterAudioDeviceCallback(devices)
        pending?.success(false); pending = null
        channel.setMethodCallHandler(null)
    }
}
```

`android/app/src/main/AndroidManifest.xml`, directly after the `RECORD_AUDIO` line:

```xml
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
```

`android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt`:
- import `com.tarkilhk.wing.voiceoffline.HeadphoneRouteChannel` with the other imports;
- directly after `private val background = BackgroundVoiceChannel(activity, messenger)`:

```kotlin
    private val route = HeadphoneRouteChannel(activity, messenger)
```

- first line inside `fun permissionResult(requestCode: Int, grants: IntArray): Boolean {`:

```kotlin
        if (requestCode == HeadphoneRouteChannel.PERMISSION_REQUEST) { route.permissionResult(grants); return true }
```

- in `fun close()`, directly after `background.close()`: `        route.close()`

`MainActivity.kt:320` already forwards every permission result to `voiceChannel.permissionResult`; no
change there.

- [ ] **Step 6: Commit, run the tests and the Kotlin compile**

```
git add lib/voice_offline/headphone_route.dart android/app/src/main/kotlin/com/tarkilhk/wing/voiceoffline/HeadphoneRouteChannel.kt android/app/src/main/AndroidManifest.xml android/app/src/main/kotlin/com/tarkilhk/wing/VoiceChannel.kt
git commit -m "feat(voice): headphone route verdict from the routed output device"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/headphone_route_test.dart`
Expected: last line `ci-suite: run <id> conclusion=success`.
Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=false`
Expected: last line `dispatch-check: voice-apk.yml run <id> conclusion=success …`. A lint `NewApi` error
on `getAudioDevicesForAttributes` means the `SDK_INT < 33` guard was moved; keep the early return.

---

### Task 16: Settings row states the headphones-only rule

**Files:**
- Modify: `lib/voice_offline/barge_in_settings.dart` (constructor :17-23, state, `_probe` :46, playback switch :123-136)
- Modify: `lib/voice_offline/barge_in_policy.dart` (remove `bargeInPlaybackHint`, :16-17)
- Test: `test/voice_preferences_test.dart` (append; make :332 independent of Task 7)

**Interfaces:**
- Consumes: Task 15 `HeadphoneRouteHost`, `AndroidHeadphoneRouteHost`, `classifyRoute`, `routeLogLine`;
  test fixture `HeadphoneRouteFixture`.
- Produces: `BargeInSettings({…existing…, HeadphoneRouteHost? route, bool playbackAvailable = bargeInPlaybackAvailable})`.
  Subtitle strings (exact): `Only with headphones. On the speaker or in the car, tap to stop.` and
  `Only with wired headphones. Allow Nearby devices for Bluetooth headphones.`

- [ ] **Step 1: Write the failing tests** (append inside `main()` of `test/voice_preferences_test.dart`,
  after the `barge-in settings render` loop; add the imports
  `import 'package:wing/voice_offline/barge_in_policy.dart';`,
  `import 'package:wing/voice_offline/barge_in_settings.dart';` and
  `import 'support/headphone_route_fixture.dart';`)

```dart
  const headphonesOnly =
      'Only with headphones. On the speaker or in the car, tap to stop.';
  const wiredOnly =
      'Only with wired headphones. Allow Nearby devices for Bluetooth headphones.';
  const playbackOff = VoicePreferences(
    input: VoiceInputRoute.vad,
    conversation: true,
  );
  const playbackOn = VoicePreferences(
    input: VoiceInputRoute.vad,
    conversation: true,
    bargeInPlayback: true,
  );

  Future<List<(String, String)>> showBargeIn(
    WidgetTester tester,
    VoicePreferences settings,
    HeadphoneRouteFixture route, {
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    final saved = <(String, String)>[];
    final device = VoiceDeviceFixture();
    addTearDown(device.stream.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(brightness),
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(320, 800),
            textScaler: TextScaler.linear(scale),
          ),
          child: RepaintBoundary(
            key: frame,
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: BargeInSettings(
                  settings: settings,
                  device: device,
                  saving: false,
                  onSave: (key, value) async => saved.add((key, value)),
                  route: route,
                  playbackAvailable: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return saved;
  }

  testWidgets('read-aloud barge-in states the headphones-only rule', (
    tester,
  ) async {
    final route = HeadphoneRouteFixture();
    addTearDown(route.close);
    await showBargeIn(tester, playbackOff, route);
    expect(find.text('Interrupt read-aloud by speaking'), findsOneWidget);
    expect(find.text(headphonesOnly), findsOneWidget);
  });

  testWidgets('switching it on saves and asks for Bluetooth access', (
    tester,
  ) async {
    final route = HeadphoneRouteFixture();
    addTearDown(route.close);
    final saved = await showBargeIn(tester, playbackOff, route);
    await tester.tap(find.byKey(const ValueKey('voice-barge-in-playback')));
    await tester.pumpAndSettle();
    expect(saved, [(VoicePreferences.bargeInPlaybackKey, 'on')]);
    expect(route.requests, 1);
  });

  testWidgets('without Bluetooth access the row says wired only', (
    tester,
  ) async {
    final route = HeadphoneRouteFixture()..allowed = false;
    addTearDown(route.close);
    await showBargeIn(tester, playbackOn, route);
    expect(find.text(wiredOnly), findsOneWidget);
    expect(find.text(headphonesOnly), findsNothing);
  });

  testWidgets('switching it off does not ask for anything', (tester) async {
    final route = HeadphoneRouteFixture();
    addTearDown(route.close);
    final saved = await showBargeIn(tester, playbackOn, route);
    await tester.tap(find.byKey(const ValueKey('voice-barge-in-playback')));
    await tester.pumpAndSettle();
    expect(saved, [(VoicePreferences.bargeInPlaybackKey, 'off')]);
    expect(route.requests, 0);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final allowed in [true, false]) {
        testWidgets(
          'read-aloud barge-in row renders in $brightness at ${scale}x '
          '(bluetooth ${allowed ? 'allowed' : 'denied'})',
          (tester) async {
            final route = HeadphoneRouteFixture()..allowed = allowed;
            addTearDown(route.close);
            await showBargeIn(
              tester,
              playbackOn,
              route,
              brightness: brightness,
              scale: scale,
            );
            await tester.ensureVisible(
              find.text('Interrupt read-aloud by speaking'),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await screenshot(
              tester,
              'barge-playback-${allowed ? 'headphones' : 'wired'}-'
              '${brightness.name}-${(scale * 100).round()}',
            );
          },
        );
      }
    }
  }
```

In the existing test `listen-while-working settings appear only with vad conversation` replace
`expect(find.text('Interrupt read-aloud by speaking'), findsNothing);` with:

```dart
    expect(
      find.text('Interrupt read-aloud by speaking'),
      bargeInPlaybackAvailable ? findsOneWidget : findsNothing,
    );
```

(Task 7 may set the constant to `true`; the card itself keeps the constant as its default.)

- [ ] **Step 2: Commit the tests and run them to verify they fail**

```
git add test/voice_preferences_test.dart
git commit -m "test(voice): read-aloud barge-in row states the headphones-only rule"
```

Run: `bash tools/factory/ci-suite.sh test/voice_preferences_test.dart`
Expected: `conclusion=failure` (analyzer: "The named parameter 'route' isn't defined").

- [ ] **Step 3: Implementation**

`lib/voice_offline/barge_in_policy.dart`: delete the two lines

```dart
/// Subtitle for that switch, e.g. when only headphones passed the gate.
const String? bargeInPlaybackHint = null;
```

`lib/voice_offline/barge_in_settings.dart`:

Add the import `import 'headphone_route.dart';`.

Constructor and fields — replace

```dart
    required this.onSave,
  });
```

with

```dart
    required this.onSave,
    this.route,
    this.playbackAvailable = bargeInPlaybackAvailable,
  });
```

and add below `final Future<void> Function(String key, String value) onSave;`:

```dart

  /// Native route check; tests pass a fake.
  final HeadphoneRouteHost? route;

  /// Shows "Interrupt read-aloud by speaking" (the echo gate, Task 7).
  final bool playbackAvailable;
```

In `_BargeInSettingsState`, add below `bool _probing = false;`:

```dart
  bool _bluetoothAllowed = true;

  static const _headphonesOnly =
      'Only with headphones. On the speaker or in the car, tap to stop.';
  static const _wiredOnly =
      'Only with wired headphones. Allow Nearby devices for Bluetooth headphones.';

  HeadphoneRouteHost get _route =>
      widget.route ?? AndroidHeadphoneRouteHost.instance;

  @override
  void initState() {
    super.initState();
    if (widget.playbackAvailable) unawaited(_readBluetooth());
  }

  Future<void> _readBluetooth() async {
    final allowed = await _route.bluetoothAllowed();
    if (mounted && allowed != _bluetoothAllowed) {
      setState(() => _bluetoothAllowed = allowed);
    }
  }

  /// Spec §6: saving never waits for the permission dialog; a denial only
  /// changes the subtitle.
  Future<void> _togglePlayback(bool on) async {
    unawaited(
      widget.onSave(VoicePreferences.bargeInPlaybackKey, on ? 'on' : 'off'),
    );
    if (!on) return;
    final allowed = await _route.requestBluetooth();
    if (mounted) setState(() => _bluetoothAllowed = allowed);
  }
```

In `_probe()`, directly after `setState(() => _probing = true);` insert:

```dart
    final route = await _route.current();
    bargeLog(routeLogLine(route, classifyRoute(route, wingCarMode: false)));
```

Replace the whole `if (bargeInPlaybackAvailable) CompactSwitchListTile(…),` entry with:

```dart
        if (widget.playbackAvailable)
          CompactSwitchListTile(
            key: const ValueKey('voice-barge-in-playback'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Interrupt read-aloud by speaking'),
            subtitle: Text(
              s.bargeInPlayback && !_bluetoothAllowed
                  ? _wiredOnly
                  : _headphonesOnly,
            ),
            value: s.bargeInPlayback,
            onChanged: widget.saving
                ? null
                : (value) => unawaited(_togglePlayback(value)),
          ),
```

- [ ] **Step 4: Commit and run**

```
git add lib/voice_offline/barge_in_settings.dart lib/voice_offline/barge_in_policy.dart
git commit -m "feat(voice): read-aloud barge-in row says headphones only and asks for Bluetooth access"
```

Run: `bash tools/factory/ci-suite.sh test/voice_preferences_test.dart`
Expected: last line `ci-suite: run <id> conclusion=success`.

- [ ] **Step 5: Render and inspect** (design charter §"Layout and controls", two-line switch row)

Run: `bash tools/factory/dispatch-check.sh voice-review.yml`
Expected: `conclusion=success`. Then, one command each:

```
git fetch -q origin voice-review-bin
mkdir -p build/wing-review
git show origin/voice-review-bin:barge-playback-headphones-light-100.png > build/wing-review/barge-playback-headphones-light-100.png
git show origin/voice-review-bin:barge-playback-wired-dark-200.png > build/wing-review/barge-playback-wired-dark-200.png
git show origin/voice-review-bin:barge-playback-headphones-dark-100.png > build/wing-review/barge-playback-headphones-dark-100.png
git show origin/voice-review-bin:barge-playback-wired-light-200.png > build/wing-review/barge-playback-wired-light-200.png
```

Open each PNG with the Read tool. Check: title 16 sp, subtitle 13 sp muted, no blank line between them,
the switch stays in the trailing column, the wrapped subtitle at 200 % pushes the row taller (no
clipping, no overflow stripe), contrast fine in dark mode, no extra heading or card. Fix what looks
wrong, commit, render again.

---

### Task 6 [WORKER + Birk]: Echo measurement with headphones (S2 = the gate)

Done by the **Hermes worker** via `hadb`; Birk brings the headphones. S1 and S3 are optional.

- [ ] **Step 1: Pick the build.** If Tasks 15 and 16 are merged into `voice-offline`, build from there:
  `bash tools/factory/dispatch-check.sh voice-apk.yml publish=true` → `conclusion=success`; note
  `SOURCE_COMMIT`. Otherwise use the Task 5 APK (SOURCE_COMMIT `fff2ed93`) and skip every step marked
  *(route)*; the route checks then move to Task 13.
- [ ] **Step 2: Sign and install** with the sideload key (same procedure as every voice build). Check:
  `hadb shell dumpsys package com.tarkilhk.wing.voice | grep versionName`. Note versionName and
  `SOURCE_COMMIT`.
- [ ] **Step 3: Settings:** input "On this phone · Parakeet", Conversation mode on, "Keep voice
  recordings" on, the normal SherpaTTS voice, speed Normal.
- [ ] **Step 4 *(route)*: Nearby devices access.** `hadb shell pm grant com.tarkilhk.wing.voice android.permission.BLUETOOTH_CONNECT`
  Expected: no output.
- [ ] **Step 5: Log forwarding check.** `hadb logcat -c`, tap "Measure speaker echo", wait 40 s, then
  `hadb logcat -d | grep WingBargeIn`. Expected: exactly one `I flutter : WingBargeIn probe windows=…`
  line and a `WingBargeIn listen close reason=probe` line; *(route)* a `WingBargeIn route …` line before
  them. No line at all: release builds do not forward `debugPrint`; stop and report it.
- [ ] **Step 6: Real audio source.** During a probe run: `hadb shell dumpsys audio | grep -i -A3 "rec"`.
  Note VOICE_COMMUNICATION (source 7) or VOICE_RECOGNITION (6).
- [ ] **Step 7: S2 headphones (gate).** For each headphone type Birk uses (wired and/or Bluetooth): Birk
  plugs in or connects; normal media volume; quiet room; three probe runs. Collect the three `probe`
  lines per type. *(route)* Before each run the log shows
  `route headphones=1 reason=wired …` or `route headphones=1 reason=bluetoothHeadphones … btClass=0x0404|0x0418`.
  If a Bluetooth pair shows `bluetoothClassUnknown` or `bluetoothOther`: record its `type` and `btClass`
  numbers in the card comment and report; do not change the rule (spec ANNAHMEN §3.4.1).
- [ ] **Step 8 (optional): S1 speaker.** No headphones. For `n` in {9, 15}:
  `hadb shell cmd media_session volume --stream 3 --set <n>`, three runs each. *(route)* Expected
  `route headphones=0 reason=speaker`.
- [ ] **Step 9 (optional): S3 car.** Parked, BT to the car, three runs if Birk is there anyway.
  *(route)* Expected `route headphones=0` with `reason=bluetoothOther`, `carMode` or `androidCarMode`;
  record `btClass`.
- [ ] **Step 10: Evaluate S2 only**, worst run across all S2 runs:
  - Pass: all runs `run50 ≤ 6` **and** `p99 < 0.5`.
  - Marginal: all runs `run50 ≤ 15` **and** `p99 < 0.75`.
  - Fail: anything else.
- [ ] **Step 11: Write the result** into `docs/VOICE_BARGE_IN.md` under "## Echo measurement" (numbers
  only): date, versionName, SOURCE_COMMIT, real source, one table row per run (scenario, headphone type
  or volume, the `probe` numbers), the S2 verdict, S1/S3 marked "informational". *(route)* One line per
  device: `type`, `btClass`, verdict. Commit:
  `git add docs/VOICE_BARGE_IN.md`
  `git commit -m "docs(voice): headphone echo measurement for barge-in (S2 gate)"`
  Verify: `grep -c "S2" docs/VOICE_BARGE_IN.md` → a number ≥ 1.
- [ ] **Step 12:** Delete the debug recordings ("Delete debug recordings") and switch "Keep voice
  recordings" off again.

---

### Task 7: Apply the S2 result

**Files:**
- Modify: `lib/voice_offline/barge_in_policy.dart` (constants :14, :21-22)
- Modify: `docs/VOICE_BARGE_IN.md` (decision line)

**Interfaces:** Produces the final `bargeInPlaybackAvailable`, `bargeGateThreshold`, `bargeGateWindows`.

- [ ] **Step 1: Pick the row** from Task 6's S2 verdict:

| S2 | `bargeInPlaybackAvailable` | Gate constants | Next |
|---|---|---|---|
| pass | `true` | unchanged (0.7 / 16) | Task 10 |
| marginal | `true` | formula below, from the S2 numbers | Step 3 re-check, then Task 10 |
| fail | `false` (unchanged) | unchanged | Step 4 fail branch; skip 10, 17, 18 |

Formula (spec §4.2), from the worst S2 run:
`bargeGateThreshold = max(0.7, ceil10(p99 + 0.15))` and `bargeGateWindows = max(16, 2 × run70)`.
`ceil10(x)` rounds up to one decimal. Threshold > 0.9 or windows > 31 → use the fail row.

- [ ] **Step 2: Edit the constants.** Pass: `const bool bargeInPlaybackAvailable = true;` only. Marginal,
  for example p99 = 0.62 and run70 = 11: also `const double bargeGateThreshold = 0.8;` and
  `const int bargeGateWindows = 22;`.
- [ ] **Step 3: Marginal re-check [WORKER]** (marginal only). Commit, build
  (`bash tools/factory/dispatch-check.sh voice-apk.yml publish=true` → `conclusion=success`), install,
  repeat S2 with three probe runs per headphone type. Every `probe` line must show `wouldTrigger=0`.
  Otherwise use the fail row.
- [ ] **Step 4: Fail branch only.** Remove the unused route code and permission: `git log --oneline -8`,
  then `git revert --no-edit <hash>` once per Task 15 and Task 16 commit (newest first). Verify:
  `git grep -n "BLUETOOTH_CONNECT" -- android/app/src/main/AndroidManifest.xml` → no output.
- [ ] **Step 5:** Add the line "Decision: S2 <pass|marginal|fail>, bargeInPlaybackAvailable=<v>,
  threshold <t>, windows <w>" under "## Echo measurement" in `docs/VOICE_BARGE_IN.md`.
- [ ] **Step 6: Commit and run**

```
git add lib/voice_offline/barge_in_policy.dart docs/VOICE_BARGE_IN.md
git commit -m "feat(voice): barge-in gate from the headphone echo measurement"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/barge_in_policy_test.dart`
Expected: last line `ci-suite: run <id> conclusion=success` (the whole suite runs; Task 16 made the
settings expectation follow the constant).

---

### Task 10: Screen hooks for (b) — barge-in during read-aloud, headphones only

Only if Task 7 set `bargeInPlaybackAvailable = true`.

**Files:**
- Modify: `lib/voice_offline/turn_listener.dart` (getter below `bool get isOpen`, :40)
- Modify: `lib/core/screens/profile_workspace_screen.dart` (:103/:120 widget parameter, :193 field,
  :319 and :331-336 in `_speakCompletedReply`, :448 `_sendConversationTurn`, below `_openListen` :496,
  :823 initState, :899 and :911 dispose)
- Test: `test/voice_offline/turn_listener_test.dart`, `test/voice_workspace_test.dart` (append; fixture
  wiring)

**Interfaces:**
- Consumes: Task 15 `HeadphoneRoute`, `HeadphoneRouteHost`, `AndroidHeadphoneRouteHost`, `OutputRoute`,
  `HeadphoneRouteFixture`; merged `BargeInCoordinator.open/close/setPlayback/listening/chat`,
  `TurnListener.setPlayback`, `_openListen(chat, {bool playback})`, `_autoSpeakQueue`,
  `bargeInPlaybackAvailable`, `VoicePreferences.bargeInPlayback`, `CarModeSession.active`.
- Produces: `TurnListener.playback` (`bool`); `ProfileWorkspaceScreen({…, HeadphoneRouteHost? headphoneRoute})`;
  screen-private `_headphones`, `_playbackBargeIn(chat, settings)`, `_headphoneRouteChanged()`; log
  reason `listen close reason=route`.

- [ ] **Step 1: `TurnListener.playback` — failing test** (append inside `main()` of
  `test/voice_offline/turn_listener_test.dart`)

```dart
  test('playback reports the stricter read-aloud mode', () async {
    await listener.open(settings, playback: true);
    expect(listener.playback, isTrue);
    listener.setPlayback(false);
    expect(listener.playback, isFalse);
    listener.setPlayback(true);
    await listener.close('test');
    expect(listener.playback, isFalse);
  });
```

- [ ] **Step 2: Widget tests** (`test/voice_workspace_test.dart`)

Fixture wiring: add `import 'support/headphone_route_fixture.dart';` and
`import 'package:wing/voice_offline/headphone_route.dart';`; next to `late BackgroundVoiceFixture background;`
add `late HeadphoneRouteFixture route;`; next to `background = BackgroundVoiceFixture();` add
`route = HeadphoneRouteFixture();`; next to `await background.close();` add `await route.close();`; in
`show`, next to `backgroundVoice: background,` add `headphoneRoute: route,`. The default route is the
speaker, so every existing test keeps today's behaviour.

Append after the `media key ends a listen utterance and steers it` test:

```dart
  Future<void> bargeInPlayback(bool on) => controller.preferences.setString(
    VoicePreferences.bargeInPlaybackKey,
    on ? 'on' : 'off',
  );
  int playbackStops() => device.calls.where((c) => c == 'stopPlayback').length;

  /// A conversation turn whose reply is being read aloud (playback held).
  Future<void> readingAloud(WidgetTester tester, OutputRoute output) async {
    route.route = output;
    await bargeInPlayback(true);
    device.playbackDelay = Completer<void>();
    await vadConversationTurn(tester);
    await completeReply(tester, 'Lange Antwort.');
    expect(device.spoken, 'Lange Antwort.');
  }

  Future<void> finishReading(WidgetTester tester) async {
    device.playbackDelay!.complete();
    device.playbackDelay = null;
    await settle(tester);
  }

  testWidgets('with headphones, speaking during read-aloud stops it and sends', (
    tester,
  ) async {
    await readingAloud(tester, HeadphoneRouteFixture.headphones);
    expect(find.text('Listening'), findsOneWidget);
    final stopsBefore = playbackStops();
    device.vadTranscript = 'Testsatz zwei, stopp';
    await windows(tester, 0.95, 40);
    expect(playbackStops(), greaterThan(stopsBefore));
    await finishReading(tester);
    await windows(tester, 0.1, 60);
    expect(prompts(), 2);
    expect(
      fixture.calls.lastWhere((c) => c.$2 == 'prompt.submit').$3['text'],
      startsWith('Testsatz zwei, stopp'),
    );
    await tester.tap(find.text('Stop listening'));
    await settle(tester);
  });

  testWidgets('with headphones, a cough during read-aloud changes nothing', (
    tester,
  ) async {
    await readingAloud(tester, HeadphoneRouteFixture.headphones);
    final stopsBefore = playbackStops();
    await windows(tester, 0.8, 14);
    await windows(tester, 0.1, 60);
    expect(playbackStops(), stopsBefore);
    expect(prompts(), 1);
    await finishReading(tester);
    // Read-aloud ended normally: the open round now listens for the next prompt.
    expect(find.text('Listening'), findsOneWidget);
    await tester.tap(find.text('Stop listening'));
    await settle(tester);
  });

  testWidgets('over the speaker, speaking during read-aloud does not stop it', (
    tester,
  ) async {
    await readingAloud(tester, HeadphoneRouteFixture.speaker);
    expect(find.text('Listening'), findsNothing);
    final starts = vadStarts();
    final stopsBefore = playbackStops();
    await windows(tester, 0.95, 40);
    await windows(tester, 0.1, 60);
    expect(playbackStops(), stopsBefore);
    expect(vadStarts(), starts);
    expect(prompts(), 1);
    await finishReading(tester);
    expect(find.textContaining('Recording ·'), findsOneWidget);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
  });

  testWidgets('unplugging headphones during read-aloud closes the round', (
    tester,
  ) async {
    await readingAloud(tester, HeadphoneRouteFixture.headphones);
    expect(find.text('Listening'), findsOneWidget);
    route.change(HeadphoneRouteFixture.speaker);
    await settle(tester);
    expect(find.text('Listening'), findsNothing);
    final stopsBefore = playbackStops();
    await windows(tester, 0.95, 40);
    expect(playbackStops(), stopsBefore);
    await finishReading(tester);
    expect(find.textContaining('Recording ·'), findsOneWidget);
    await tester.tap(find.text('Cancel recording'));
    await settle(tester);
  });

  testWidgets('plugging headphones in during read-aloud opens the round', (
    tester,
  ) async {
    await readingAloud(tester, HeadphoneRouteFixture.speaker);
    expect(find.text('Listening'), findsNothing);
    route.change(HeadphoneRouteFixture.headphones);
    await settle(tester);
    expect(find.text('Listening'), findsOneWidget);
    expect(device.vadOptions!.keepPlayback, isTrue);
    await finishReading(tester);
    await tester.tap(find.text('Stop listening'));
    await settle(tester);
  });
```

- [ ] **Step 3: Commit the tests and run them to verify they fail**

```
git add test/voice_offline/turn_listener_test.dart test/voice_workspace_test.dart
git commit -m "test(voice): barge-in during read-aloud only with headphones"
```

Run: `bash tools/factory/ci-suite.sh test/voice_workspace_test.dart`
Expected: `conclusion=failure` (analyzer: "The named parameter 'headphoneRoute' isn't defined" and
"The getter 'playback' isn't defined").

- [ ] **Step 4: Implementation**

`lib/voice_offline/turn_listener.dart`, directly below `bool get isOpen => phase != ListenPhase.idle;`:

```dart

  /// The round uses the stricter read-aloud gate.
  bool get playback => _gate != null;
```

`lib/core/screens/profile_workspace_screen.dart`:

4a. Import with the other `voice_offline` imports: `import '../../voice_offline/headphone_route.dart';`

4b. Widget parameter: below `final BackgroundVoiceHost? backgroundVoice;` add
`final HeadphoneRouteHost? headphoneRoute;`; below `this.backgroundVoice,` add `this.headphoneRoute,`.

4c. Field, directly after the `late final _bargeIn = BargeInCoordinator(…);` declaration:

```dart

  /// Voice barge-in into read-aloud only with headphones (spec §3.4.1, D2).
  late final _headphones = HeadphoneRoute(
    widget.headphoneRoute ?? AndroidHeadphoneRouteHost.instance,
    wingCarMode: () => _car.active,
  );
```

4d. `_speakCompletedReply`: replace the line
`    unawaited(_bargeIn.close('turnEnd').catchError((Object _) {}));` with:

```dart
    if (_playbackBargeIn(chat, settings)) {
      _openListen(chat, playback: true);
    } else {
      unawaited(_bargeIn.close('turnEnd').catchError((Object _) {}));
    }
```

In the same method, replace

```dart
        if (!finished) {
          // Stop speech, a newer playback or a failure ends the conversation,
          // unless the user already tapped the microphone again.
          if (!_voiceInput.active) _conversation = null;
          return;
        }
```

with

```dart
        if (!finished) {
          // Stop speech, a newer playback or a failure ends the conversation,
          // unless the user already tapped the microphone again or a barge-in
          // stopped the reply (its listen round keeps the conversation).
          if (!_voiceInput.active && !_bargeIn.listening) _conversation = null;
          return;
        }
        if (_bargeIn.listening && _bargeIn.chat == chat.key) {
          // Read-aloud ended: the open round replaces the reopened dictation
          // and uses the normal rules once no other reply waits to be read.
          if (_autoSpeakQueue.isEmpty) _bargeIn.setPlayback(false);
          if (chat.busy) _conversationAwaitingReply = true;
          return;
        }
```

4e. `_sendConversationTurn`: directly after `    _bargeIn.beginTurn();` add:

```dart
    // Fresh route verdict for when this turn's reply is read aloud.
    unawaited(_headphones.refresh());
```

4f. New helpers, directly below the closing `}` of `_openListen`:

```dart

  /// Voice barge-in into read-aloud (spec §3.4, D2): setting on, echo gate
  /// passed, the conversation's chat, output on headphones.
  bool _playbackBargeIn(ProfileChat chat, VoicePreferences settings) =>
      bargeInPlaybackAvailable &&
      settings.bargeInPlayback &&
      _conversation == chat.key &&
      _headphones.headphones;

  /// The output route changed while Wing reads aloud (spec §3.4.2):
  /// headphones gone closes a playback round, headphones back opens one.
  void _headphoneRouteChanged() {
    final chat = controller.notificationChat ?? controller.current?.chat;
    if (!mounted ||
        chat == null ||
        _conversation != chat.key ||
        _voiceOutput.owner == null) {
      return;
    }
    if (!_headphones.headphones) {
      if (_bargeIn.listener.playback) {
        unawaited(_bargeIn.close('route').catchError((Object _) {}));
      }
      return;
    }
    final VoicePreferences settings;
    try {
      settings = VoicePreferences.read(controller.preferences);
    } on FormatException {
      return;
    }
    if (!_bargeIn.listening && _playbackBargeIn(chat, settings)) {
      _openListen(chat, playback: true);
    }
  }
```

4g. `initState`: directly after `    _car.addListener(_carActiveChanged);` add:

```dart
    _car.addListener(_headphones.carModeChanged);
    _headphones.addListener(_headphoneRouteChanged);
```

4h. `dispose`: directly before `    _car.removeListener(_carActiveChanged);` add
`    _car.removeListener(_headphones.carModeChanged);`; directly after `    _bargeIn.dispose();` add
`    _headphones.dispose();`.

- [ ] **Step 5: Commit and run**

```
git add lib/voice_offline/turn_listener.dart lib/core/screens/profile_workspace_screen.dart
git commit -m "feat(voice): barge-in during read-aloud only while the output is headphones"
```

Run: `bash tools/factory/ci-suite.sh test/voice_workspace_test.dart`
Expected: last line `ci-suite: run <id> conclusion=success`. If a new test fails because of the fixture
(for example the round is not yet open when the reply completes), fix the hook, not the expectation, and
name the cause in the commit message.

---

### Task 17: Interrupted-reply hint

Only if Task 10 was built.

**Files:**
- Modify: `lib/voice_offline/barge_in_policy.dart` (append)
- Modify: `lib/voice_offline/turn_listener.dart` (fields, `_startRound` :74, `_event` :120-121, `_decided` :149-191)
- Modify: `lib/voice_offline/barge_in_coordinator.dart` (`_utterance` :93, `_deliver` :101-127)
- Test: `test/voice_offline/barge_in_policy_test.dart`, `test/voice_offline/turn_listener_test.dart`,
  `test/voice_offline/barge_in_coordinator_test.dart`, `test/voice_workspace_test.dart` (append)

**Interfaces:**
- Produces: `const String interruptedReplyHint`, `String withInterruptedReplyHint(String text)`;
  `TurnListener.utteranceBarged` (`bool`, true only while `onUtterance` runs for an utterance whose round
  fired the playback gate); log `deliver kind=<send|queue> result=ok hint=<0|1>`.
- Consumes: Task 10 test helpers `readingAloud`, `finishReading`; merged `_Target`, `utter` in the
  coordinator test.

- [ ] **Step 1: Write the failing tests**

Append inside `main()` of `test/voice_offline/barge_in_policy_test.dart`:

```dart
  test('the interrupted-reply hint follows the words after a blank line', () {
    expect(
      withInterruptedReplyHint('Testsatz zwei, stopp '),
      'Testsatz zwei, stopp\n\n'
      '[Hinweis von Wing: Die vorige Antwort wurde beim Vorlesen abgebrochen '
      'und nicht zu Ende gehört.]',
    );
  });
```

Append inside `main()` of `test/voice_offline/turn_listener_test.dart`:

```dart
  test('only an utterance that fired the playback gate counts as barged', () async {
    final barged = <bool>[];
    listener.onUtterance = (_) => barged.add(listener.utteranceBarged);
    await listener.open(settings, playback: true);
    await say(0.9, 30);
    await say(0.1, 60);
    await say(0.9, 20);
    await say(0.1, 60);
    expect(barged, [true, false]);
    expect(listener.utteranceBarged, isFalse);
  });
```

Append inside `main()` of `test/voice_offline/barge_in_coordinator_test.dart`:

```dart
  Future<void> bargeIn(String text) async {
    await coordinator.open(
      'chat-a',
      target,
      settings,
      playback: true,
      onBarge: () async {},
    );
    await utter(text);
  }

  test('words that cut off read-aloud carry the hint when sent or queued', () async {
    target.current = ListenChatState.idle;
    await bargeIn('Testsatz zwei, stopp');
    target.current = ListenChatState.busy;
    await bargeIn('Testsatz drei');
    expect(target.log, [
      'send:${withInterruptedReplyHint('Testsatz zwei, stopp')}',
      'queue:${withInterruptedReplyHint('Testsatz drei')}',
    ]);
  });

  test('a steer never carries the hint, even after a barge-in', () async {
    await bargeIn('Testsatz vier');
    expect(target.log, ['steer:Testsatz vier']);
  });
```

(The existing coordinator tests `busy and idle chats queue or send directly` and the workspace test
`while Hermes works the microphone listens and steers` assert exact texts without a barge-in, so they
already cover "no hint without barge-in" and "steer without read-aloud".)

Append inside `main()` of `test/voice_workspace_test.dart`, after the Task 10 tests (add
`import 'package:wing/voice_offline/barge_in_policy.dart';` if it is not imported yet):

```dart
  testWidgets('the message after a barge-in carries the interrupted-reply hint', (
    tester,
  ) async {
    await readingAloud(tester, HeadphoneRouteFixture.headphones);
    device.vadTranscript = 'Testsatz zwei, stopp';
    await windows(tester, 0.95, 40);
    await finishReading(tester);
    await windows(tester, 0.1, 60);
    expect(
      fixture.calls.lastWhere((c) => c.$2 == 'prompt.submit').$3['text'],
      withInterruptedReplyHint('Testsatz zwei, stopp'),
    );
    await tester.tap(find.text('Stop listening'));
    await settle(tester);
  });
```

- [ ] **Step 2: Commit the tests and run them to verify they fail**

```
git add test/voice_offline/barge_in_policy_test.dart test/voice_offline/turn_listener_test.dart test/voice_offline/barge_in_coordinator_test.dart test/voice_workspace_test.dart
git commit -m "test(voice): interrupted-reply hint after a barge-in"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/barge_in_coordinator_test.dart`
Expected: `conclusion=failure` (analyzer: "The function 'withInterruptedReplyHint' isn't defined").

- [ ] **Step 3: Implementation**

`lib/voice_offline/barge_in_policy.dart`, append at the end:

```dart

/// Appended to a message that cut off read-aloud by voice (spec §3.6). The
/// profile's Wing platform hint asks Hermes to fold the unheard points of
/// the previous reply into the next one. No percentage: Wing has no
/// sentence-level read-aloud progress.
const String interruptedReplyHint =
    '[Hinweis von Wing: Die vorige Antwort wurde beim Vorlesen abgebrochen '
    'und nicht zu Ende gehört.]';

String withInterruptedReplyHint(String text) =>
    '${text.trimRight()}\n\n$interruptedReplyHint';
```

`lib/voice_offline/turn_listener.dart`:

- below `Future<void> Function()? onBarge;` add:

```dart

  /// True only while [onUtterance] runs for an utterance whose round fired
  /// the playback gate (a voice barge-in into read-aloud).
  bool utteranceBarged = false;
```

- below `bool _disposed = false;` add `  bool _barged = false;`
- in `_startRound`, directly after `_gate = playback ? PlaybackGate() : null;` add `    _barged = false;`
- in `_event`, replace `      if (onset != null) unawaited(_barge(onset));` with:

```dart
      if (onset != null) {
        _barged = true;
        unawaited(_barge(onset));
      }
```

- in `_decided`, directly after `if (id == null || endpointer == null) return;` add
  `    final barged = _barged;`, and replace the final `    onUtterance?.call(text);` with:

```dart
    utteranceBarged = barged;
    try {
      onUtterance?.call(text);
    } finally {
      utteranceBarged = false;
    }
```

`lib/voice_offline/barge_in_coordinator.dart`:

Replace `_utterance` and `_deliver` with:

```dart
  void _utterance(String text) {
    final target = _target;
    if (target == null) return;
    final barged = listener.utteranceBarged;
    _deliveries = _deliveries
        .then((_) => _deliver(target, text, barged: barged))
        .catchError((Object _) => bargeLog('deliver failed'));
  }

  Future<void> _deliver(
    ListenTarget target,
    String text, {
    required bool barged,
  }) async {
    var decision = decideDelivery(target.state, text);
    if (decision == ListenDelivery.steer) {
      if (await target.steer(text)) {
        steered = true;
        bargeLog('deliver kind=steer result=queued');
        return;
      }
      bargeLog('deliver kind=steer result=rejected');
      decision = decideDelivery(target.state, text, steerRejected: true);
    }
    // Spec §3.6: a new message that cut off read-aloud says so; a steer
    // never does.
    final message = barged ? withInterruptedReplyHint(text) : text;
    final hint = barged ? 1 : 0;
    switch (decision) {
      case ListenDelivery.drop:
        bargeLog(
          'deliver kind=drop result=${text.trim().isEmpty ? 'empty' : 'filler'}',
        );
      case ListenDelivery.queue:
        await target.queue(message);
        bargeLog('deliver kind=queue result=ok hint=$hint');
      case ListenDelivery.send:
        await target.send(message);
        bargeLog('deliver kind=send result=ok hint=$hint');
      case ListenDelivery.steer:
        // Unreachable: a rejected steer is re-decided with steerRejected.
        break;
    }
  }
```

- [ ] **Step 4: Commit and run**

```
git add lib/voice_offline/barge_in_policy.dart lib/voice_offline/turn_listener.dart lib/voice_offline/barge_in_coordinator.dart
git commit -m "feat(voice): message after a barge-in tells Hermes the reply was cut off"
```

Run: `bash tools/factory/ci-suite.sh test/voice_offline/barge_in_coordinator_test.dart`
Expected: last line `ci-suite: run <id> conclusion=success` (the run covers all four test files).

---

### Task 11R: Documentation and phone build

**Files:**
- Modify: `docs/VOICE_BARGE_IN.md`

**Interfaces:** none.

- [ ] **Step 1: Update `docs/VOICE_BARGE_IN.md`** (keep "## Echo measurement" from Tasks 6/7):
  - "What it does": (b) built, headphones only (or, after a failed S2: "(b) not built: S2 failed; read-aloud
    is interrupted by tap and media key only").
  - Replace the block "D1-D3 (ANNAHME Birk-Gate, confirmed 2026-10-14)" with "Decisions (Birk 14.10.)":
    D1, D2, D3 in one line each, pointing to the spec section "Decisions (Birk 14.10.)" for the verbatim
    text.
  - "Settings": the `voice.barge_in_playback` row with the two subtitles from spec §6 and the Nearby
    devices request on switch-on.
  - New "## Headphone detection": the rule table from spec §3.4.1 and the route re-evaluation (§3.4.2).
  - New "## Interrupted-reply hint": the exact hint text, when it is appended, that there is no
    percentage and why, and the `platform_hints.wing` sentence (Task 18).
  - "Log lines": replace the block with the one from spec §7 verbatim.
  - "Limits": add "a car on an AUX cable looks like wired headphones; only car mode closes the gate";
    "Bluetooth headphones with an unreadable or unusual class do not count"; "the hint is visible in the
    user's own message".
- [ ] **Step 2: Verify and commit**

Run: `grep -c "ANNAHME Birk-Gate" docs/VOICE_BARGE_IN.md`
Expected: `0`.
Run: `grep -c "route headphones=" docs/VOICE_BARGE_IN.md`
Expected: a number ≥ 1.

```
git add docs/VOICE_BARGE_IN.md
git commit -m "docs(voice): barge-in during read-aloud with headphones and the interrupted-reply hint"
```

- [ ] **Step 3: Phone build**

Run: `bash tools/factory/dispatch-check.sh voice-apk.yml publish=true`
Expected: last line `dispatch-check: voice-apk.yml run <id> conclusion=success …`. Note
`git rev-parse HEAD` in the card comment as "Abnahme-APK".

---

### Task 18 [WORKER]: Wing platform hint for the interrupted reply

Only if Task 17 was built. The Hermes worker edits Birk's profile config; Claude Code does not.

**Files:**
- Modify: `/home/birk/.hermes/profiles/birk/config.yaml` (key `platform_hints.wing.append`; procedure as in
  `docs/superpowers/plans/2026-10-13-wing-client-source.md` Task D1)

**Interfaces:** Consumes the exact hint text of Task 17 (`interruptedReplyHint`).

- [ ] **Step 1: Locate the key and save the current values**

```
grep -n "platform_hints" -A 4 /home/birk/.hermes/profiles/birk/config.yaml
/home/birk/.hermes/hermes-agent/venv/bin/python -c "import yaml; h=yaml.safe_load(open('/home/birk/.hermes/profiles/birk/config.yaml'))['platform_hints']; open('/tmp/wing-hint-before.txt','w').write(h['wing']['append']); open('/tmp/telegram-hint-before.txt','w').write(h['telegram']['append'])"
```

Expected: the grep shows `  wing:` and `    append: "Standard Wing (Handy-App): …"`; the python call
prints nothing. If there is no `wing` entry (a `KeyError`): stop and report "platform_hints.wing
missing"; do not create it here.

- [ ] **Step 2: Append one sentence** at the end of the `wing` `append` value, inside its closing double
  quote, after one space. Change nothing else (not the telegram entry, no re-quoting, no reflow):

```
Steht am Ende einer Nachricht '[Hinweis von Wing: Die vorige Antwort wurde beim Vorlesen abgebrochen und nicht zu Ende gehört.]', die nicht gehörten Kernpunkte der vorigen Antwort knapp in die neue Antwort einarbeiten.
```

- [ ] **Step 3: Verify**

```
/home/birk/.hermes/hermes-agent/venv/bin/python -c "import yaml; h=yaml.safe_load(open('/home/birk/.hermes/profiles/birk/config.yaml'))['platform_hints']; w=h['wing']['append']; print(w.startswith(open('/tmp/wing-hint-before.txt').read()), w.endswith('die nicht gehörten Kernpunkte der vorigen Antwort knapp in die neue Antwort einarbeiten.'), w.count('[Hinweis von Wing: Die vorige Antwort wurde beim Vorlesen abgebrochen und nicht zu Ende gehört.]'), h['telegram']['append'] == open('/tmp/telegram-hint-before.txt').read())"
grep -c "nicht gehörten Kernpunkte der vorigen Antwort" /home/birk/.hermes/profiles/birk/config.yaml
```

Expected: `True True 1 True`, then `1`. In the profile repo, `git diff` shows exactly one changed line.

- [ ] **Step 4: Commit** in the profile repo following its own commit rules (`docs/repo-strategie.md`),
  only this path. The sentence takes effect like client-source Task D1 Step 3 (after the profile is
  reloaded); restarting or upgrading the gateway is a separate action Birk decides on.

---

### Task 13 [WORKER]: Install, on-device look, CPU

- [ ] **Step 1:** Sign and install the Task 11R APK. Check `versionName` and `SOURCE_COMMIT` as in Task 6.
- [ ] **Step 2: Screenshots** at normal text size and with the largest Android font size
  (`hadb shell settings put system font_scale 1.3`; restore to `1.0` afterwards), light and dark
  (`hadb shell cmd uimode night yes` / `hadb shell cmd uimode night no`):
  - voice settings with the listen rows and, if (b) was built, "Interrupt read-aloud by speaking" with
    the normal subtitle; switch it on, deny "Nearby devices" once to see the wired-only subtitle, then
    switch off and on again and allow it;
  - a chat during a listen round (synthetic turn `Führe im Terminal "sleep 25" aus und antworte dann nur
    mit "fertig".`).
  Capture with `hadb exec-out screencap -p > <file>` outside the repo. Check: subtitle readable, row
  wraps without clipping at 1.3, switch in the trailing column, "Stop listening" reachable, contrast in
  dark mode. Do not store the screenshots in the repo (they show the chat list).
- [ ] **Step 3 *(route, if Task 6 could not check it)*:** with Birk's headphones connected, start the
  synthetic turn and read `hadb logcat -d | grep "WingBargeIn route"`. Expected `headphones=1`. Record
  `type` and `btClass` in the card comment.
- [ ] **Step 4: CPU during a listen round** while the synthetic sleep turn runs and nobody speaks:
  `hadb shell top -b -n 5 -d 2 | grep com.tarkilhk.wing.voice`. Expected: average `%CPU` < 10 (one
  core = 100). Record the value in `docs/VOICE_BARGE_IN.md` under "Battery". Above 10: report it; do not
  tune on your own.

---

### Task 14 [WORKER + Birk]: On-device acceptance

Birk speaks; the worker drives `hadb` and collects logs. Settings: vad route, Conversation mode on,
"Listen while Hermes works" on. "Interrupt read-aloud by speaking" on only if Task 10 was built.
`hadb logcat -c` before each scenario, `hadb logcat -d | grep WingBargeIn` after it. Synthetic texts only.

- [ ] **Scenario 1: steer.** Birk dictates `Führe im Terminal "sleep 25" aus und antworte dann nur mit
  "fertig" und dem heutigen Datum, falls ich danach frage.` and pauses. During the sleep he says
  "Testsatz eins, bitte nenne zusätzlich das heutige Datum". Pass: `listen open mode=turn`,
  `utterance segmentMs=… textLen=…`, `deliver kind=steer result=queued`; a steer row in the chat that shows
  only his words (no hint); the final reply contains a date.
- [ ] **Scenario 1b: D1 switch off.** "Listen while Hermes works" off; repeat scenario 1. Pass: no
  `listen open` line; his words during the sleep send nothing. Switch it on again.
- [ ] **Scenario 2: barge-in with headphones** (Task 10 built). Headphones connected. Synthetic prompt
  `Zähle langsam in Worten von eins bis vierzig.` While the reply is read aloud, Birk says "Testsatz
  zwei, stopp". Pass: `route headphones=1`, `listen open mode=playback` or a playback switch of the open
  round, `barge trigger sinceOnsetMs=<n> stopMs=<m>` with `n ≤ 1200`; TTS audibly stops; then
  `deliver kind=send result=ok hint=1`.
- [ ] **Scenario 2b: message after barge-in carries the hint.** In the chat, the message sent in
  scenario 2 ends with `[Hinweis von Wing: Die vorige Antwort wurde beim Vorlesen abgebrochen und nicht
  zu Ende gehört.]`. If Task 18 is in effect, Birk judges whether the reply takes up the unheard points.
- [ ] **Scenario 3: cough.**
  - (3a, headphones, Task 10 built) During read-aloud of the scenario 2 prompt, three coughs about 5 s
    apart. Pass: no `barge trigger`; TTS reads to the end.
  - (3b) During a scenario 1 sleep turn, three coughs. Pass: at most `deliver kind=drop`, no
    `deliver kind=steer`.
- [ ] **Scenario 4: speaker — speaking during read-aloud does NOT stop it** (Task 10 built). No
  headphones. Scenario 2 prompt; during read-aloud Birk says "Testsatz drei, stopp". Pass:
  `route headphones=0 reason=speaker`, no `listen open mode=playback`, no `barge trigger`; TTS reads on.
  Tapping the stop control still stops it.
- [ ] **Scenario 5: headphones removed during read-aloud → voice barge-in off** (Task 10 built).
  Scenario 2 prompt into headphones; once `listen open mode=playback` (or the playback switch) appeared,
  Birk unplugs or switches the headphones off. Pass: `route headphones=0` follows; no `barge trigger`
  after it; either Android stopped read-aloud or `listen close reason=route` appears; speaking afterwards
  over the speaker does not stop any read-aloud.
- [ ] **Scenario 6: turn end while speaking.** During scenario 1, Birk starts talking about 1 s before
  "fertig" appears. Pass: the reply is not read aloud (D3), and his words arrive as the next prompt
  (`deliver kind=send` or `kind=steer`, depending on timing).
- [ ] **Scenario 7: approval.** Synthetic prompt `Lösche die Datei /tmp/wing-barge-test.txt mit rm.`
  When the approval appears: the "Listening" row disappears and logcat shows
  `listen close reason=conversationEnd`.
- [ ] **Optional scenario 8: car.** In the parked car with BT and headphones off: scenario 4 setup.
  Pass: `route headphones=0` (`bluetoothOther`, `carMode` or `androidCarMode`); no `barge trigger`.
- [ ] **Evidence:** paste the logcat lines (no text content in them) into the card comment, with
  versionName, SOURCE_COMMIT, date and the scenario verdicts.
- [ ] **Birk's confirmation:** Birk writes in his own words on the card whether it works as he wished.

---

## Self-review notes (plan author)

- Spec coverage:
  - §3.2/§3.3 (a) → done (fff2ed93); D1 test exists (`voice_workspace_test.dart:705`), device check
    Task 14 scenario 1b
  - §3.4 (b) flow → Task 10; media key unchanged
  - §3.4.1 detection and permission → Task 15 (native + classifier), Task 16 (request on switch-on)
  - §3.4.2 route changes → Task 15 (`changed`, `carModeChanged`), Task 10 (`_headphoneRouteChanged`)
  - §3.5 speech queue → Task 10 (`_autoSpeakQueue.isEmpty`); car mode → Task 15 classifier + Task 10
    wiring
  - §3.6 hint → Task 17 (Wing), Task 18 (profile)
  - §4.2 / §5.3 → Tasks 6, 7
  - §6 settings row → Task 16 (+ render), Task 13 (device)
  - §7 logs and acceptance → Tasks 15, 17 (lines), 14 (scenarios)
  - §8 files → file map; §9 → Task R0
- `VoicePlayback.kt` and `voice_input_controller.dart` stay untouched: the route query copies the two
  attribute constants, and the progress question is answered without a new playback event.
- Fixture risk: `VoiceDeviceFixture.startVad` resets the window counter per round, matching native
  `VadCapture.readLoop` (`first = 0` per round); Task 10/17 tests rely on it as the merged tests do.
- If `insertVoiceTranscript` ever trims or reflows newlines, the Task 17 workspace test fails first; the
  coordinator test still pins the hint format.

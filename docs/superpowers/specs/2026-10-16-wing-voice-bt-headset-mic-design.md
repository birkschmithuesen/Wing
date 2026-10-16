# Wing Voice: Bluetooth headset microphone, and headphone detection for the WH-1000XM4

Card t_3954f61f · 2026-10-16 · branch `voice-offline` at `0d9cd8fb` · status: design (headless run, see "Process")

## Kurzfassung (Deutsch)

- Birks Annahme stimmt für die **Ausgabe** (verbundene BT-Kopfhörer werden Standard, A2DP/LDAC), aber **nicht fürs Mikro**. Laut AOSP `Engine.cpp` nimmt Android ein klassisches BT-Headset-Mikro (SCO/HFP) nur, wenn eine App es per `setCommunicationDevice` anfordert. Kabel-, USB- und LE-Audio-Mikros nimmt Android automatisch. Ob das Sony-Mikro in Wing wirklich Ton liefert, ist erst nach der Gerätemessung belegt.
- Neue Regel (ersetzt die Regel vom 13.10.): **„Mikro des verbundenen Headsets, wenn vorhanden, sonst Handy.“**
- Wing fordert das Headset-Mikro nur für eine echte Aufnahme an (Diktat, Gesprächszug). Dazu nutzt es `AudioManager.setCommunicationDevice` (API 31+), danach `clearCommunicationDevice`. Während des Vorlesens und beim Mithören, während Hermes arbeitet, bleibt das Handy-Mikro aktiv. So klingt das Vorlesen weiter in A2DP-Qualität.
- Freisprechanlage im Auto: vorerst Handy-Mikro (Entscheidung 2).
- `bluetoothClassUnknown` beim WH-1000XM4 kommt von der fehlenden Berechtigung „Geräte in der Nähe“ (`BLUETOOTH_CONNECT granted=false`). Wing fragt nie danach, weil der einzige Schalter, der fragt, ausgeblendet ist (`bargeInPlaybackAvailable = false`). Lösung: einmalig nachfragen, bei der ersten Aufnahme mit verbundenem BT-Audiogerät.
- Drei Entscheidungen für Birk stehen unten. Danach folgen die Coder-Karte und zwei Gerätekarten (Messung vorher/nachher).

## Process

Brainstorming ran headless: no questions could be asked. The design decisions below were taken from the code, the
Android API reference and the facts measured on Birk's phone on 16.10. Everything unverified is marked
`ANNAHME: <what> - check: <how>`. Three genuine product decisions are left to Birk in §9. This feature touches no Hermes
API (client-only audio routing), so there is no upstream Hermes commit to inspect. The AGENTS.md backend rule
holds trivially.

## 1. Praemisse geprueft

Birk (16.10.): „Sobald ich die Bluetooth-Kopfhoerer verbinde, werden diese auf dem Telefon zum Standard.“

| Part | Verdict | Evidence (Xperia 5 IV, Android 16 / SDK 36, Wing 1.1.3, `hadb`, 16.10. ~11:45) |
|---|---|---|
| Output | **true** | `dumpsys audio`: `Active communication device: … type:bt_a2dp … name:WH-1000XM4`. Media goes to A2DP with LDAC 96 kHz. |
| Microphone | **false** | `mBtScoOnByApp=false`, `Preferred communication device: null`. With no communication device set, the AOSP policy engine never picks the BT SCO headset mic (`0x80000008`) for app capture (source below), so capture stays on the built-in mic (`0x80000004`). |

Retracted (correction Birk/Robo, 16.10.): an earlier draft cited four `adev_open_input_stream … devices(0x80000008)`
lines at 11:34:12 as "another app used the Sony mic". Those lines come 2 s after `HeadsetService setActiveDevice`
(11:34:10). All four fall within 36 ms and use four different channel masks, so they are very likely the audio
policy probing the device profiles on connect, not an app. They are **not** evidence that the Sony mic delivers audio.
`ANNAHME: the WH-1000XM4 mic delivers usable audio to Wing over SCO once Wing requests the communication device -
check: during a Wing recording with SCO requested, dumpsys media.audio_policy (active inputs: device
AUDIO_DEVICE_IN_BLUETOOTH_SCO_HEADSET) plus logcat adev_open_input_stream … devices(0x80000008), and non-silent PCM
(firstSoundMs, WER) - plan Tasks 14 and 10.`

**Source for the routing rule.** AOSP `frameworks/av/services/audiopolicy/enginedefault/src/Engine.cpp` (main),
`Engine::getDeviceForInputSource()`. For the sources `MIC`, `VOICE_RECOGNITION` and `VOICE_COMMUNICATION`,
`AUDIO_DEVICE_IN_BLUETOOTH_SCO_HEADSET` is chosen **only** if `audio_is_bluetooth_out_sco_device(commDeviceType)`.
`commDeviceType` is the preferred device of strategy PHONE, which is set through `setCommunicationDevice` (or by
Telecom during calls). Otherwise the order is `WIRED_HEADSET` > `USB_HEADSET` > `USB_DEVICE` > `BLUETOOTH_BLE` >
`BUILTIN_MIC`. Consequences:
- A classic BT headset (HFP) is **never** taken automatically as the mic. Wing must request it.
- LE Audio headsets, wired headsets and USB headsets **are** taken automatically.
- The WH-1000XM4 has no LE (`LE:N` in `dumpsys bluetooth_manager`, profile policy `LE_AUDIO=-1`). Only the HFP/SCO
  path through `setCommunicationDevice` remains.

`ANNAHME: LineageOS on Birk's Xperia 5 IV (pdx224) uses the default engine and does not change
getDeviceForInputSource - check: plan Task 15 (device: which libaudiopolicyengine*.so is loaded; source:
LineageOS/android_frameworks_av at the build's branch, diff of Engine.cpp against AOSP; device trees
LineageOS/android_device_sony_pdx224 and android_device_sony_sm8450-common for audio_policy_configuration.xml and an
audio_policy_engine_*.xml engine config).`

Consequence: Birk's decision of 13.10. ("Mikro = was Android routet, keine eigene SCO-Aktivierung, kein Mikro-Schalter
in der App") assumed that Android's default mic is the headset mic once a headset is connected. That assumption is
false. The 13.10. rule is **superseded** by:

> **Mikro des verbundenen Headsets, wenn vorhanden, sonst Handy.**

The parts of 13.10. that remain: **no microphone switch in the app** (the choice is automatic), and Wing changes
routing only for its own recording rounds and only while they run.

## 2. Current code (what exists)

- `VadCapture.kt` (route vad, Parakeet): `AudioRecord` 16 kHz mono. The source is `VOICE_COMMUNICATION` (7, the
  default "Call processing" setting, with fallback 6) or `VOICE_RECOGNITION` (6). The class comment says *"never
  changes audio routing"*. It logs `inputDevice = routedDevice.productName (type)` into the debug JSON only.
- Callers of `startVad`: `voice_input_controller.dart` (explicit recording: dictation, conversation turn, car mode)
  and `turn_listener.dart` (listen rounds with `keepPlayback: true`, plus the echo probe).
- `VoiceCapture.kt` (routes `hermes` = `MediaRecorder` `MIC`, `local` = Android `SpeechRecognizer`): out of scope (§8).
- `VoicePlayback.kt`: TTS/MediaPlayer with `USAGE_MEDIA`, `AUDIOFOCUS_GAIN_TRANSIENT`.
- `BackgroundVoiceService.kt`: `watchCalls()` stops the service when the audio mode becomes `MODE_RINGTONE`,
  `MODE_IN_CALL`, **`MODE_IN_COMMUNICATION`** or `MODE_CALL_SCREENING`. If Wing set `MODE_IN_COMMUNICATION` itself, it
  would end its own screen-off conversation. This is the main reason the design avoids changing the mode (§4.2).
- `HeadphoneRouteChannel.kt` / `headphone_route.dart`: native facts plus a pure Dart verdict for barge-in part (b).
  `bluetoothClass()` reads `BluetoothDevice.getBluetoothClass()`, which needs `BLUETOOTH_CONNECT` on API 31+.

## 3. Root cause of `bluetoothClassUnknown` (question 5)

Log: `route headphones=0 reason=bluetoothClassUnknown type=8 btClass=none`. Package dump:
`android.permission.BLUETOOTH_CONNECT: granted=false` (declared in `AndroidManifest.xml:5`).

Why the request never happened (verified in code):

1. `requestBluetooth` is called from exactly one place: `BargeInSettings._togglePlayback(true)`
   (`lib/voice_offline/barge_in_settings.dart:77`).
2. That switch is rendered only `if (widget.playbackAvailable)`. The default is `bargeInPlaybackAvailable`, which is
   `const false` (`barge_in_policy.dart:14`) until barge-in Task 7 applies the S2 echo result. The switch is therefore
   invisible in 1.1.3, nobody could turn it on, and Android never showed the dialog.
3. Without the permission, `bluetoothAllowed()` is false and `bluetoothClass()` returns null, so the verdict is
   `bluetoothClassUnknown`. `ANNAHME: on Android 14+ AudioDeviceInfo.getAddress() of a BT device is also anonymised
   without BLUETOOTH_CONNECT, so getRemoteDevice() would fail even if the class call were allowed - check: in the
   Task 10 log the new perm=0/1 field next to btClass before and after granting.`

Fix:

- **F1 (permission):** ask for "Nearby devices" **once**, at the first explicit recording that starts while a
  Bluetooth audio device is connected and Wing is in the foreground. The recording waits for the answer, the same way
  the existing `RECORD_AUDIO` pending flow in `VoiceChannel` does, and then starts either way. Denied means phone
  mic, no further asking (Android itself stops showing the dialog after two denials). The barge-in switch keeps its
  own request. Timing is decision **D3**.
- **F2 (diagnosis):** `current()` also returns `bluetoothAllowed`. Dart then distinguishes
  `reason=bluetoothNoPermission` from `reason=bluetoothClassUnknown` (permission granted, class still unreadable) and
  logs `perm=0|1`. A future log then shows which case occurred.
- **Class-free fallback: rejected.** A car kit is also A2DP + HFP (SCO input present, same address). The class and
  the mode flags (Wing car mode, Android car mode) are the only public signals that separate the two.
  `AudioManager.getBluetoothAudioDeviceCategory` exists but is `@SystemApi`, so Wing cannot use it. Android car mode
  is only set by Android Auto, and many cars run without it. Treating "A2DP + SCO, no car mode" as headphones would
  open SCO in such cars, which shows a call on the head unit and mutes the radio. The conservative rule of the
  barge-in spec stays: unknown class means not headphones and not a headset mic.

The WH-1000XM4 reports class `0x240404`, so device class `0x0404` = `AUDIO_VIDEO_WEARABLE_HEADSET`. That is already in
`_headphoneClasses`. With F1 granted, the existing rule yields `bluetoothHeadphones`.

## 4. How Wing takes the headset mic (question 1)

### 4.1 API choice

| Option | Verdict |
|---|---|
| `AudioManager.setCommunicationDevice(AudioDeviceInfo)` / `clearCommunicationDevice()` (API 31+) | **Chosen.** Replaces the deprecated SCO APIs. You pass a sink from `getAvailableCommunicationDevices()`. The platform picks the matching source and brings up the SCO link. Per `Engine.cpp` (§1), this is the only way to get the SCO mic for `MIC`/`VOICE_RECOGNITION`/`VOICE_COMMUNICATION` capture. The request lasts while the process lives or until it is cleared. Confirmation comes through `OnCommunicationDeviceChangedListener`. |
| `startBluetoothSco()` / `stopBluetoothSco()` | Deprecated since API 31. Not used (minSdk is irrelevant: Birk's phone is SDK 36, and below 31 Wing keeps the phone mic). |
| `AudioRecord.setPreferredDevice(scoInput)` | **Used in addition** to pin the record to the SCO input (`TYPE_BLUETOOTH_SCO`, `isSource`) once the link is up. `ANNAHME: setPreferredDevice alone does not bring up the SCO link - check: not needed for the design; the link is always requested through setCommunicationDevice first.` |

Device selection: in `getAvailableCommunicationDevices()`, take the first entry of type `TYPE_BLUETOOTH_SCO` whose
address equals the A2DP output's address. If no address matches, take the first SCO entry. LE Audio
(`TYPE_BLE_HEADSET`) is never requested: the engine already routes its mic (§1). A matching input is a `getDevices(GET_DEVICES_INPUTS)` entry of the same type and address.

### 4.2 Audio mode, capture source, permissions, focus

- **No `setMode(MODE_IN_COMMUNICATION)`.** Input selection follows the communication device and does not depend
  on the mode (Engine.cpp, §1). `ANNAHME: since Android 12, AudioDeviceBroker brings up SCO for a
  communication-device client (virtual-call SCO) without the app changing the audio mode, and the PHONE strategy's
  preferred device becomes bt_sco - check: Task 14 step B and Task 10 step "mic proof": dumpsys media.audio_policy
  shows an active input on AUDIO_DEVICE_IN_BLUETOOTH_SCO_HEADSET, logcat shows adev_open_input_stream …
  devices(0x80000008) source(7) and source(6) during the Wing round, and dumpsys audio shows mode NORMAL.` If the
  check fails, conditional plan Task 13 sets
  `MODE_IN_COMMUNICATION` only for the round. It then marks the mode as Wing-owned so that
  `BackgroundVoiceService.watchCalls` ignores it.
- **Capture source:** unchanged, from the user setting. Engine.cpp treats `VOICE_COMMUNICATION` (7, the default)
  and `VOICE_RECOGNITION` (6) the same way: both take the SCO mic when the communication device is SCO. The setting
  stays. Task 10 checks both on the device.
- **Sample rate:** 16 kHz mono, as today. That equals mSBC wideband. `ANNAHME: the Sony negotiates mSBC (WBS) and
  possibly LC3-SWB (HFP log EVENT_TYPE_WBS valInt=2, EVENT_TYPE_SWB valInt2=1) - check: dumpsys bluetooth_manager
  while SCO is open (Task 10).` If only CVSD (8 kHz) were negotiated, Android would resample to 16 kHz and recognition
  quality would drop. The WER measurement would show that.
- **Permissions:** `MODIFY_AUDIO_SETTINGS` (normal, install-time) is **not** declared today (`AndroidManifest.xml`
  only has `BLUETOOTH_CONNECT` at line 5, checked 16.10.); plan Task 4 adds it.
  `ANNAHME: AudioService checks MODIFY_AUDIO_SETTINGS in setCommunicationDevice - check: harmless either way, normal
  permission; Task 10 confirms setCommunicationDevice returns true.` `BLUETOOTH_CONNECT` is **not** needed to route.
  It is needed only to read the device class (§3). `ANNAHME: setCommunicationDevice works without BLUETOOTH_CONNECT -
  check: only matters if Birk picks E3 = b; then Task 10 is run once after pm revoke and must show
  WingMic acquire result=true.`
- **Audio focus:** none for capture (as today). Read-aloud never overlaps a headset-mic round, because explicit rounds
  stop playback (`VoiceChannel.start` without `keepPlayback`).

### 4.3 Detection matrix (rule → mic, output quality)

The decision is made natively at round start (`HeadsetMicRoute.decide`, §6). It uses fresh facts from the moment
the round starts.

| Situation | Signals | Mic for an explicit round | Mic for listen rounds / probe | Output |
|---|---|---|---|---|
| No headset | output speaker | phone (`0x80000004`) | phone | speaker |
| BT headphones with HFP (WH-1000XM4) | output A2DP, SCO in communication devices, class `0x0404`/`0x0418` | **headset (SCO `0x80000008`)** | phone (D1 = A) | A2DP/LDAC. During the round, A2DP is suspended (§5), and it returns after release. |
| BT headphones, class unknown (no permission) | A2DP + SCO, class null | phone, and F1 asks once | phone | A2DP |
| BT A2DP only (no mic / HFP off) | A2DP, no SCO | phone | phone | A2DP |
| LE Audio headset | `TYPE_BLE_HEADSET` input present | headset mic, routed **automatically** by the engine (`BLUETOOTH_BLE` ranks above `BUILTIN_MIC`). Wing does nothing. **Untested: no device.** | the same LE mic. Wing does not pin listen rounds to the phone; LE keeps its own bidirectional quality. | LE Audio. Not an option for the Sony (`LE:N`, `LE_AUDIO=-1`). |
| Wired headset with mic | `TYPE_WIRED_HEADSET` / `TYPE_USB_HEADSET` (or a USB audio device) | headset mic, routed **automatically** (`WIRED_HEADSET` > `USB_HEADSET` > `USB_DEVICE`). Wing does nothing. | same | wired |
| Wired headphones without mic | `TYPE_WIRED_HEADPHONES` | phone | phone | wired |
| Car hands-free (BT HFP) | class `0x0408`/`0x0420` or other non-headset class, or Android car mode, or Wing car mode | **phone** (D2) | phone | A2DP to the car |

Order of checks in `decide`:
1. SDK < 31 → phone.
2. Wing car mode holder on → phone.
3. Android car mode → phone.
4. No SCO device in the communication devices → phone (also covers wired, USB and LE, which the engine routes itself).
5. Class unreadable → phone (reason `noPermission` or `classUnknown`).
6. Class not in {`0x0404`, `0x0418`} → phone (`notHeadset`).
7. Otherwise → headset.

Wired, USB and LE Audio are not in the decision logic because the engine already routes them (§1). `mic: phone`
does not override them: only classic SCO is avoided for listen rounds.

### 4.4 Exit paths (release on every one)

`HeadsetMicRoute.release()` is idempotent. It runs `clearCommunicationDevice()` only if Wing set the device and
nobody else changed it since.

| Path | Where |
|---|---|
| Round finished (pause / max / noSpeech) | `VadCapture.finish` → `stopReading` → release, **before** recognition, so A2DP resumes while Parakeet decodes |
| Cancel | `cancelRound` → `stopReading` → release |
| Error (read < 0, time limit) | `fail` → `stopReading` → release |
| App leaves foreground, no background hold | `VoiceChannel.pause` → `vad.pause` → `fail` → release |
| Screen-off conversation (`BackgroundVoiceService.keepsVoice()`) | the round continues and so does the route. Release happens on round end like above. The listen rounds of D1 = A use the phone mic, so a long-held SCO cannot occur. |
| New round while one runs | `start` → `cancelCurrent` → release, then acquire for the new round |
| Activity destroyed | `VoiceChannel.close` → `vad.close` → release; `HeadsetMicRoute.close()` unregisters listeners |
| Process death | the platform drops the request (documented lifetime). Nothing to do. |
| Headset disconnects mid-round | the communication device listener reports a change. Wing logs `WingMic lost`, the record falls back to the default input, and the PCM collected so far stays in the round buffer. `ANNAHME: AudioRecord keeps delivering frames after its preferred device disappears (re-routes to the built-in mic) instead of returning an error - check: Task 10 step "disconnect".` If `read()` returns an error instead, the existing `fail` path keeps today's behaviour (error message, utterance lost). The plan then gets a follow-up card; no speculative reopen logic now. |
| Acquire timeout (SCO did not come up within 2500 ms) | release, record from the phone mic, log `WingMic fallback reason=timeout` |

## 5. Sound price (question 2)

While SCO is open, the headset runs HFP. Output drops to call quality (mono, mSBC 16 kHz), and A2DP media is
suspended. `ANNAHME: while Wing holds a SCO communication device without call mode, USAGE_MEDIA output is either
silent (A2DP suspended) or routed over SCO in call quality - check: Task 10 step "media during SCO" (play a TTS
sample while a round is open via the probe build, note audibility).` Option A does not depend on the answer.

The brief's options A ("SCO only during an actual recording, not during long listening or read-aloud") and B
("listening while working uses the phone mic, explicit recording uses the headset mic") have the same effect on
Wing's flow: listen rounds are the long listening, and explicit rounds are the recordings. They are merged here into
**A**. A distinct middle option was added as **B**.

| Option | Behaviour | Read-aloud quality | Mic for "listen while Hermes works" | Cost |
|---|---|---|---|---|
| **A (recommended)** | Headset mic only for explicit rounds (dictation, conversation turn). Listen rounds and the probe use the phone mic. | A2DP/LDAC always | phone mic (Sony on the head, phone on the table) | +SCO setup latency per turn before the cue (expected 0.3-1.5 s, measured in Task 10). Steering while Hermes works uses the phone mic. |
| B | As A, plus listen rounds use the headset mic **while nothing plays**. They switch to the phone mic when read-aloud starts. | A2DP for read-aloud | headset until read-aloud, then phone | mic switch inside a running round (re-acquire, gap of up to 1.5 s, possible lost words). SCO is held for minutes during tool turns, the music of other apps stays suspended, and the battery cost is higher. |
| C | Headset mic for everything, SCO held through the whole conversation | call quality (mono 16 kHz) for all read-aloud | headset | read-aloud sounds like a phone call. The barge-in echo path changes (HFP headset AEC). All echo numbers would need to be measured again. |

First-syllable risk: the start cue plays **after** the SCO link is confirmed and the `AudioRecord` runs. The cue
therefore keeps meaning "speak now". The VAD pre-roll covers the rest. Conversation rounds always play the start cue
(`startCue` = `cues`). If Birk has cues off, the latency still applies but nothing announces it. Task 10 measures
the gap from `WingMic acquire` to the first non-silent frame.

## 6. Components

| Unit | Kind | Responsibility |
|---|---|---|
| `android/.../voiceoffline/HeadsetMicRoute.kt` | new | facts, `decide()`, `acquire(onReady)`, `release()`, `close()`. Communication-device listener, timeout, one-time Nearby-devices request (`PERMISSION_REQUEST = 7316`, asked flag in `SharedPreferences` `wing_voice_route`/`bt_connect_asked`), `WingMic` logs. |
| `VadCapture.kt` | hook | `Options.mic` (`"auto"`/`"phone"`). `start` becomes asynchronous: acquire, then begin (cue, VAD, `AudioRecord` with `setPreferredDevice`), then the callback. Release in `stopReading`. Debug JSON `mic` object. |
| `VoiceChannel.kt` | hook | creates/closes `HeadsetMicRoute`. For `startVad`: optional permission step, then `vad.start(…) { result }`. Forwards `7316` in `permissionResult`. New method `setPhoneMicOnly`. |
| `AndroidManifest.xml` | hook | `MODIFY_AUDIO_SETTINGS` |
| `HeadphoneRouteChannel.kt` | hook | `current()` gets the key `bluetoothAllowed` (F2). `refresh()` pushes the route after a grant through the dictation path. |
| `lib/voice_offline/headphone_route.dart` | change | `OutputRoute.bluetoothAllowed`, reason `bluetoothNoPermission`, log field `perm=` |
| `lib/core/services/android_voice.dart` | hook | `VadMic {auto, phone}`, `VadCaptureOptions.mic` (default `auto`, map key `mic`), `VoiceDevice.setPhoneMicOnly`, `VoiceSwitchHolders.phoneMic` |
| `lib/voice_offline/turn_listener.dart` | hook | listen rounds pass `mic: VadMic.phone` (D1 = A) |
| `lib/car_mode/car_mode_session.dart` | hook | holds `VoiceSwitchHolders.phoneMic(device)` while active (D2 = phone) |
| `tools/voice/wer.py` | new | word error rate, numbers only |
| `docs/VAD_INPUT.md` | change | section "Microphone route" |

`voice_input_controller.dart` and `VoicePlayback.kt` are **not touched**. Explicit rounds get `mic: auto` through the
default of `VadCaptureOptions`.

Duplication accepted: the headset class set `{0x0404, 0x0418}` exists in Dart (`headphone_route.dart`) and in Kotlin
(`HeadsetMicRoute`). The mic decision has to be native because Wing needs fresh facts at round start and Dart is
not on that path. A comment in each file points to the other.

Logs (`android.util.Log.i`, tag `WingMic`). They contain numbers, types and reasons only, never addresses, names or
text:
`WingMic decide mic=headset|phone reason=<r> out=<type> comm=<type|none> btClass=<hex|none> perm=0|1`,
`WingMic acquire result=true|false`, `WingMic ready readyMs=<n>`, `WingMic first firstSoundMs=<n>`,
`WingMic fallback reason=timeout|rejected`, `WingMic lost`, `WingMic release heldMs=<n>`.

The barge-in Global Constraints said "Kotlin: nothing new" for barge-in logs. This card needs native proof of the
route, so it adds the `WingMic` tag with the same privacy rule.

## 7. Car (question 3)

A car hands-free unit is BT HFP as well, so technically the same mechanism would work. Reasons against applying the
headset rule in the car now:

- Skill `car-threshold-and-mic` (13.10.): road noise was as loud as speech over a headset path.
- Opening SCO makes most head units show an active call and mute the radio or media for the whole round.
- Car-mode plan `2026-10-14-wing-car-mode.md` and the VAD tuning were measured on the phone mic.

Rule proposal (D2): car kit means phone mic, unless a later measurement shows the car mic is better. Detection: a
non-headset class, Android car mode, or the Wing car mode holder.

## 8. Out of scope

- Routes `hermes` (MediaRecorder `MIC`) and `local` (Android `SpeechRecognizer`). Birk uses Parakeet (vad), and the
  system recognizer manages its own input. They keep the phone mic. A follow-up card is needed only if Birk asks.
- Any UI. No switch (13.10. still holds) and no indicator. The only visible change is Android's one-time
  "Nearby devices" dialog. The AGENTS.md rendered-screen check therefore covers only "the dialog appears once, and
  the recording starts after it".
- Barge-in part (b) gating (whether BT headphones count for read-aloud barge-in). That is sibling card t_98e8c3c2
  plus the echo result t_fabcb273. This card only makes the class readable.

## 9. Entscheidungen fuer Birk

**E1 – Klangpreis: Wann läuft das Kopfhörer-Mikro?**
- A: Nur für echte Aufnahmen (Diktat, Gesprächszug). Mithören, während Hermes arbeitet, und Reinreden ins Vorlesen nutzen das Handy-Mikro. Vorlesen bleibt immer in voller Qualität. Pro Zug kommt bis zu ca. 1 s Verzögerung bis zum Startton dazu.
- B: Wie A, aber auch beim Mithören das Kopfhörer-Mikro, solange nichts vorgelesen wird. Beim Vorlesen schaltet Wing auf das Handy-Mikro um (Lücke beim Umschalten, Musik anderer Apps bleibt minutenlang stumm).
- C: Immer das Kopfhörer-Mikro. Vorlesen klingt dann wie ein Telefonat (Mono, 16 kHz), und die Echo-Messung muss neu gemacht werden.
- **Empfehlung: A.**

**E2 – Auto-Freisprechanlage: welches Mikro?**
- 1: Handy-Mikro im Auto, auch wenn die Anlage ein Mikro hat. Erkennung über Gerätetyp, Android-Automodus oder Wing-Automodus.
- 2: Mikro der Anlage, wie bei Kopfhörern. Das Radio zeigt dann pro Aufnahme einen „Anruf“ und schaltet Musik stumm.
- 3: Erst eine Messfahrt (Handy- gegen Anlagen-Mikro, Fehlerquote), dann entscheiden. Bis dahin gilt 1.
- **Empfehlung: 1 (mit 3 als späterer Gerätekarte, wenn du willst).**

**E3 – Wann fragt Wing nach „Geräte in der Nähe“ (nötig, um Kopfhörer von Autoanlage zu unterscheiden)?**
- a: Einmalig bei der ersten Aufnahme, während ein Bluetooth-Audiogerät verbunden ist. Die Aufnahme startet nach der Antwort. Bei Ablehnung bleibt es beim Handy-Mikro.
- b: Gar nicht fragen. Kopfhörer-Mikro immer, wenn das Gerät ein Mikro hat, außer im Wing- oder Android-Automodus. Risiko: im Auto ohne Automodus „Anruf“ am Radio.
- c: Eine eigene Zeile in den Spracheinstellungen („Bluetooth-Headset erkennen“), die die Abfrage auslöst.
- **Empfehlung: a.**

The plan implements the recommendations (A, 1, a). The tasks that depend on a different answer are named in the
plan's "Decision impact" table.

## 10. What the coder card builds, device cards

Coder card (this plan, Tasks 1-8): F1/F2, `HeadsetMicRoute`, the VadCapture/VoiceChannel hooks, the `mic` option,
the car holder, `wer.py`, and docs.

Device cards:
- **Input routing facts (Task 14 [WORKER], step A before the build, step B after):** `dumpsys media.audio_policy`
  (active inputs and their device) plus `adev_open_input_stream` lines during a Wing recording. Before: expected
  `AUDIO_DEVICE_IN_BUILTIN_MIC` with the Sony connected. After: expected `AUDIO_DEVICE_IN_BLUETOOTH_SCO_HEADSET`.
- **LineageOS engine check (Task 15, no code):** verifies that pdx224 runs the default engine with an unmodified
  `getDeviceForInputSource`. The source above only holds if this check passes.
- **Before (Task 9 [WORKER + Birk], can run now on 1.1.3):** phone-mic baseline in the cafe. WER on the reference
  sentences, with the Sony connected (A2DP output) and without it. Plus a probe pair that separates cafe noise from
  Sony leakage (§11).
- **After (Task 10 [WORKER + Birk]):** route proof (`devices(0x80000008)`), SCO open and close latency, codec,
  disconnect, media during SCO, Sony button during SCO. WER phone mic vs Sony mic in the same session. A/B with HFP
  ("Phone calls") switched off in the Sony's Android Bluetooth settings, which forces the phone mic with no app
  switch.
- **t_fabcb273 (echo S2 with Sony):** with D1 = A, read-aloud barge-in listens through the **phone mic** while the Sony
  plays A2DP. That is exactly the path the current probe measures, so t_fabcb273 can run **now**, independent of this
  card, but in a quiet room (S2 definition). The 11:24 cafe run (p99 0.720, run50 18) would be "fail" (run50 > 15),
  but the cafe confounds it. Add one run at media volume 0 as a noise-floor baseline. If p99/run50 stay high at volume
  0, the cause is the cafe, not leakage. Only if Birk picks C does a second probe series with SCO open follow after
  this card. That series measures the HFP path with the headset's echo cancellation, which is a different gate.

## 11. Measurement design (question 4)

- Reference text: three fixed synthetic German sentences (in the plan, Task 9). Birk reads each once per condition,
  and the conditions alternate (phone, Sony, phone, Sony …).
- Hypothesis text: dictated into an empty Wing chat draft (never sent), read with `uiautomator dump`, saved under
  `build/voice-measure/` (git-ignored), and deleted after scoring. The reference text is synthetic, so the draft
  contains no personal text.
- Score: `python3 -I tools/voice/wer.py --reference <ref> --hypothesis <hyp>` prints
  `wer=<0.000> words=<n> sub=<n> del=<n> ins=<n>`. Normalisation: lowercase, punctuation removed, digits kept.
- Acceptance for keeping the headset mic as default: Sony WER ≤ phone WER + 0.05 in the cafe. If the Sony is clearly
  worse, the rule is reported back to Birk. The code is not changed silently.
- Echo thresholds unchanged from barge-in: pass `run50 ≤ 6` and `p99 < 0.5`; marginal `run50 ≤ 15` and `p99 < 0.75`.

## 12. ANNAHMEN (collected)

1. Android 14+ anonymises BT `AudioDeviceInfo` addresses without `BLUETOOTH_CONNECT`. Check: `perm=` field (Task 10).
2. `setPreferredDevice` alone does not bring up SCO. Check: not needed (the design always calls setCommunicationDevice).
3. SCO comes up for Wing's communication-device request without a mode change (input selection itself is sourced
   from Engine.cpp, §1). Check: Task 14 step B and Task 10 "mic proof" (`dumpsys media.audio_policy` active input on
   `AUDIO_DEVICE_IN_BLUETOOTH_SCO_HEADSET`, `devices(0x80000008) source(7)` and `source(6)`, `dumpsys audio` mode
   NORMAL).
4. The Sony negotiates mSBC, possibly LC3-SWB. Check: `dumpsys bluetooth_manager` while SCO is open (Task 10).
5. `setCommunicationDevice` checks `MODIFY_AUDIO_SETTINGS`. Check: harmless; Task 10 confirms `result=true`.
6. `setCommunicationDevice` works without `BLUETOOTH_CONNECT`. Check: only relevant for E3 = b; `result=true` log.
7. `AudioRecord` keeps delivering frames after the SCO device disappears. Check: Task 10 "disconnect".
8. Media output during SCO is either silent or call quality. Check: Task 10 "media during SCO".
9. SCO setup takes 0.3-1.5 s, and A2DP resumes within about 1 s after release. Check: Task 10 latency lines.
10. A tap on the Sony during SCO may be sent as an HFP call action (hang-up) rather than an AVRCP media key, so it
    could close SCO and miss Wing's media-key stop. Check: Task 10 "button".
11. The start cue (`ToneGenerator`, `STREAM_MUSIC`) is audible in the Sony while SCO is open. Check: Task 10 "cue".
12. The sibling t_98e8c3c2 adds `HeadphoneRoute.wired` and keeps the barge-in subtitle "wired only" (from its test
    diff at `e6880010`). Check: Task 0 reads the merged state before editing `headphone_route.dart`.
13. The WH-1000XM4 mic delivers usable audio to Wing over SCO. (The 11:34:12 `adev_open_input_stream` lines are
    retracted as evidence: very likely profile probing on connect.) Check: `dumpsys media.audio_policy` active inputs
    plus `adev_open_input_stream … devices(0x80000008)` during a Wing recording with SCO requested, and non-silent
    audio (`firstSoundMs`, WER). Plan Tasks 14B and 10.
14. LineageOS for pdx224 uses the AOSP default engine and leaves `Engine::getDeviceForInputSource` unchanged. Check:
    plan Task 15 (loaded `libaudiopolicyengine*.so`, engine config files in `/vendor/etc`, the diff of
    `services/audiopolicy/enginedefault/src/Engine.cpp` in `LineageOS/android_frameworks_av` against AOSP for the
    build's branch, and the device trees `LineageOS/android_device_sony_pdx224` / `android_device_sony_sm8450-common`).
15. Before the build, a Wing recording with the Sony connected uses `AUDIO_DEVICE_IN_BUILTIN_MIC`. This follows
    from Engine.cpp but has not been observed. Check: plan Task 14 step A.

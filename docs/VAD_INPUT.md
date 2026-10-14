# Voice input route "vad" (developer notes)

Design: `docs/superpowers/specs/2026-10-13-wing-voice-vad-input-design.md`.

## sherpa-onnx dependency (checked 2026-10-13)

- AAR `sherpa-onnx-1.13.8.aar`, SHA256 `633c24321e06b1fe79feafa03ea16cbc0f8a286641e2da3559bac91bdb13bd96` (matches the published release digest), checked with `tools/voice/check_sherpa_aar.py`.
- Result: AAR contains classes and arm64 JNI libs.
- arm64 libraries:
  - `libonnxruntime.so` 22249560
  - `libsherpa-onnx-c-api.so` 4465168
  - `libsherpa-onnx-cxx-api.so` 440688
  - `libsherpa-onnx-jni.so` 4771760
- Consumer ProGuard rules in the AAR: present.
- Downloads: the egress firewall blocks `release-assets.githubusercontent.com`, so release assets are fetched through `tools/factory/ci-fetch.sh` instead of direct `curl`/`gh release download`.

## Maximum duration (steering 13.10. 17:33)

Birk 13.10. 17:33: the longest recording on route vad must be at least 10 minutes (brainstorming dictations take 3-6 min),
not 120 s. Choices are 10 / 15 / 20 / 30 min, default 10 min. Older stored values below 10 min load as the 10 min default.
Kotlin keeps a round as 16-bit PCM sized from the configured maximum (30 min = 57.6 MB); the debug WAV is streamed to disk in blocks.

## Chunked recognition (steering 13.10. 17:33)

Birk 13.10. 17:33: long segments are recognized in pieces (memory, latency). Dart plans the pieces
(`vadChunksFor` in `lib/core/services/vad_endpoint.dart`) and sends them as `chunks` (`[startWindow, endWindow]` pairs) with `finishVad`;
Kotlin decodes them one after the other with one sherpa stream per chunk and joins the non-empty texts with one space.
Rules: a segment up to 30 s is one chunk; otherwise every chunk is at most 30 s and ends in the middle of the longest pause
(windows below 0.35, earliest on ties) within the last 10 s of the allowed chunk, or at 30 s exactly when there is no pause.
A final remainder under 2 s joins the previous chunk if that stays within 32 s. Without `chunks` Kotlin decodes the whole cut as one chunk.
Cancelling between chunks stops further decoding. The recognition budget adds 1 s per chunk after the first.
The debug JSON `recognition.chunks` lists `[startWindow, endWindow, decodeMs]` per chunk. The Python mirror does not
carry the chunk planner (it only mirrors the end-of-utterance decision for tuning); `test/vad_chunks_test.dart` covers it.

## ANNAHME outcomes

| Assumption | Check | Outcome |
|---|---|---|
| AAR has classes + JNI libs | Task 1 | Confirmed: all 9 classes and member names present, arm64 JNI libs present; no fallback needed |
| Silero model uses v5 layout (`x`, `state`, `sr`) | Task 5 | Failed: legacy layout `x[1,512]`, `h`, `c`; checker and `Vad.compute` use 512-sample windows (see below) |
| Model download resumes after the GitHub redirect | Task 15 Step 5 | Confirmed (2026-10-14): app traffic blocked at 185.1 MB, status "timeout", after unblocking and Retry the `.part` file kept growing (196.0 MB 8 s later, no restart at 0) up to 487,170,055 bytes; archive sha256 accepted |
| Active session in `STATE_PAUSED` receives media buttons | Task 15 Step 8 | Failed (2026-10-14): `dumpsys media_session` named `com.spotify.music` as media button session, `dispatch play-pause` toggled Spotify, no Wing round. Fallback `STATE_PLAYING` (4a1a86c) also failed: Wing session `active=true`, `PLAYING`, but the media button session stayed `null` and the next dispatch again went to Spotify. Wing's session has `flags=0` and `mediaButtonReceiver=null`. Cause not established; untried: `setMediaButtonReceiver`, setting the state after `isActive = true` |

## Verification status (2026-10-14)

- Suite `bash tools/factory/ci-suite.sh` on 4a1a86c6f3e9: `ci-suite: run 38480782174 conclusion=success`.
- Final suite on 7e6e6ddd (last code change 4a1a86c6, then docs only): `ci-suite: run 38483716946 conclusion=success`.
- On-device (Task 15): see "On-device verification 2026-10-14". Open: audio-source A/B and the self-test rounds (a wired
  headset stayed connected), media key (fails, see above and "Known open gap").

## On-device verification 2026-10-14

APK: first bd5df3df (sha256 `caaad84f…77fa`), for Step 8 4a1a86c6f3e9 (`ef80a1ed…d1b6`, signer `cae14a2c…` both); installed
as updates, data kept.

| Item | Result |
|---|---|
| Model download (Step 3) | 487,170,055 byte archive via the phone's own connection at about 2.4 MB/s, unpacked to `parakeet-tdt-0.6b-v3-int8/` (encoder 652,184,281 B, decoder 11,845,275 B, joiner 6,355,277 B, tokens 93,939 B), download directory empty, manifest `archiveSha256` `5793d0fd…16bf`, UI "Speech model ready" |
| Resume (Step 5) | Confirmed, see ANNAHME table. Interruption by blocking the app uid with `iptables` instead of airplane mode (airplane mode would cut the adb link over the tailnet); rule removed afterwards |
| Preload (Step 4) | `model loaded in 2767 ms`; TOTAL PSS 807,050 kB, TOTAL RSS 918,392 kB |
| Self-test A/B (Step 7) | Not done. A wired headset (`h2w`, type 3, sink and source) was connected the whole time, so playback went to the headset, not the speaker. One round with "Call processing": source `VOICE_COMMUNICATION`, inputDevice `h2w (type 3)`, 376 windows, max p 0.053, `noSpeech` at window 374 (12 s wait), no recognition. Not a valid A/B; no "Recognition" round |
| No-speech timeout (Step 7b) | Pass: wait 8 s, "No speech detected. Try again.", `decision.reason == 'noSpeech'`, `atWindow == 249`, 252 windows, max p 0.27 (room), no `recognition` timings; inputDevice `h2w (type 3)` |
| Media key (Step 8) | Fail, see ANNAHME table |
| Keep screen on (Step 9) | Pass: conversation mode on, "Dictate message": Wing window flags include `KEEP_SCREEN_ON` (count 1); "Cancel recording" 2 s later: count 0 |
| Per-chunk decode times | Not measured (no long segment) |

Notes: Birk used the phone in parallel (other rounds appeared in the debug directory and settings values changed
meanwhile); only the four rounds of this run were removed from the phone, the others were left alone.

## Known open gap (review note, 2026-10-14)

**Media key / A/B gap: Wing does not receive the media key; Spotify holds the media button session. The audio-source
A/B (Task 15 Step 7) has no valid numbers.** Birk recorded the media key as a review finding during his own device
test and does not want another phone run for it. Commit 4a1a86c6 (`STATE_PLAYING`) stays: CI is green and it shows no
regression, but it does not solve the problem. A follow-up card is created after this run.

## Open items for Birk

- Unplug the wired headset (or run on the speaker and built-in mic) and repeat the Step 7 A/B with
  `tools/voice/make_selftest_audio.py` output; the headset case should also be compared with the built-in mic.
- Media key: decide on the follow-up for the session (see ANNAHME table) and repeat Step 8 with another media app present.
- A test drive with the phone mic as Android routes it (car connected as usual), debug recordings on, alternating the audio
  source "Call processing" / "Recognition" between rounds. This decides the default source (spec 1.2).
- Whether 8 s "Wait for speech" fits in the car; the cue tone choice.
- After the drive, tune the pause from the debug rounds with `vad_offline_check.py` and delete the recordings.

## Vad.compute window size (Task 13, sherpa-onnx tag v1.13.8)

The plan's 576-sample rule (64 context + 512) is the Silero v5 layout; it is wrong for the pinned model.
- `sherpa-onnx/csrc/silero-vad-model.cc` lines 208-211: `(4 inputs && 3 outputs) || IsExportedByK2Fsa()` selects `is_v5_ = false`;
  lines 277-288: `IsExportedByK2Fsa()` is true for inputs `x,h,c` and outputs `prob,new_h,new_c`, exactly our model (see above).
  `window_overlap_ = 64` is set only in the v5 branch (line 216), so here it stays 0.
- `RunV4` (line 416) builds `x_shape = {1, n}` from the array length and feeds `x, h, c`; the model needs `x[1,512]`.
- `sherpa-onnx/jni/voice-activity-detector.cc` `Vad_compute` (line 264-): `n = GetArrayLength(samples)`, then `vad->Compute(p, n)`
  (`voice-activity-detector.cc` line 46) -> `SileroVadModel::Compute` -> `Run`; no windowing or context added by sherpa.
- Kotlin `Vad.kt` `compute(samples)` (line 61) is a thin `external` call.
Result: `VadCapture` passes exactly 512 new samples per call (no context prefix); h/c state is kept inside sherpa.

## Mutation check (pause threshold 0)

`_pauseWindows = 0` (Dart) / `self._pause_windows = 0` (Python): CI run 38428132411 failed in
`a thinking pause shorter than the pause keeps the round open` (+ 7 more: `ends after the pause and keeps the tail`,
`56 silent windows do not end it and pre-roll is clamped at zero`, `a speech start in progress at the no-speech timeout is not cut`,
`probabilities between the thresholds keep speech going`, `probabilities between the thresholds do not reset a starting run`,
`a shorter pause setting ends earlier`, `media key stop keeps speech minus pre-roll`); the Python parity test failed locally
with the same 8 subTests (`FAILED (failures=8)`).

## Offline endpoint check (Task 5, vServer)

Tools: `tools/voice/vad_offline_check.py`, `tools/voice/make_selftest_audio.py` (venv in `build/vad-venv`, numpy + onnxruntime).
Model `build/vad-check/silero_vad.onnx`, SHA256 `9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6`.
Numbers only; the private car WAV was read in place and not copied.

ANNAHME outcome (model layout): NOT confirmed. `--inspect` printed inputs `x [1,512]`, `h [2,1,64]`, `c [2,1,64]`, outputs
`prob, new_h, new_c` (older Silero layout: no 64-sample context, no `state`, no `sr`). The checker now picks the layout by
input name (legacy `h`/`c` feed, v5 fallback kept). Concern: the Dart/Kotlin side runs this model through sherpa-onnx, which
handles the layout itself; it must not assume the v5 `state`/context layout.

Controls (synthetic, known ground truth):
- `mix_s1_snr0.wav` (speech 1.000-4.634 s): `share_above_start` 0.483, one `endOfFile` round, `start_s` 0.896. As expected.
- `noise_only_15s.wav`: `share_above_start` 0.0, p99 0.276; one `noSpeech` round decided at 8.0 s, then `endOfFile`. No false alarm.
- `selftest.wav` (speech 4.0-7.435 s and 8.435-11.367 s, 1.0 s thinking pause, 6 s tail, SNR 10 dB): at every pause from 1000 to
  3000 ms exactly one speech round (the 1.0 s pause does not split), `false_rounds` 0, `end_error_ms` 633 for all pauses.
  Deviation: the brief expects -300..+600; 633 ms is slightly above (the endpointer keeps a trailing tail after the last speech window).

Car recording (68.52 s, 44.1 kHz stereo, built-in phone mic in driving noise):
- Probability percentiles p10/p50/p90/p99: 0.028 / 0.291 / 0.934 / 0.991; `share_above_start` 0.414. Silero does hear the voice at
  phone-mic distance (share well above zero, p90 high); no sign of noise counted as speech.
- Rounds with speech (reason `pause`): 5 for every pause value 1000-3000 ms. No `maxDuration` round, none lasting the whole file.
  Speech spans (start-end, s): 2.75-7.01, 9.98-12.26, 15.26-27.26, 35.71-39.97 (1000 ms: 36.03), 43.62-55.49. Two spans are 12.0 s
  and 11.9 s long, i.e. continuous speech without a gap of the pause length inside.
- `decided_s - end_s` per pause: 1000 ms 0.768; 1400 ms 1.152; 1800 ms 1.568; 2400 ms 2.144; 3000 ms 2.752 (same for all five rounds).
- `noSpeech` rounds with default 8 s timeout: pause 1000 ms: 2 (decided at 36.03 s and 64.26 s), 1400 ms: 1 (64.64 s),
  1800 ms: 1 (65.06 s), 2400 and 3000 ms: 0. Each hit a stretch after a speech round, i.e. silence in the file, not a missed utterance
  (speech start in every other stretch was detected).
- With `--no-speech-ms 12000`: 0 `noSpeech` rounds for all pauses; the 5 speech rounds and their times are unchanged, the file ends with
  an `endOfFile` round from 64.9 s. A longer wait therefore only removes the trailing/idle `noSpeech` rounds, nothing else changes.
- Whether the `noSpeech` stretches correspond to silent passages or to unheard speech cannot be decided without labels;
  the high share above start suggests the former.

## Debug recordings

With the debug switch on (App settings → Voice → Pause detection), every vad round writes
`files/voice-debug/<yyyyMMdd-HHmmss>-<id8>.wav` (16 kHz mono PCM16, whole round) and `.json` inside the app's private
storage. Cancelled rounds are written too; the newest 30 rounds are kept; "Delete debug recordings" removes all. The JSON
holds `version, roundId, startedAt, sampleRate, windowSamples, windowMs, source, inputDevice, config, probabilities`
(3 decimals), `computeErrors`, `decision{reason, startWindow, endWindow, atWindow}` and
`recognition{segmentMs, decodeMs, modelReadyAtFinish, textLength, error}`. It contains no transcript text. Nothing is
uploaded by the app.

Retrieval from the phone (root, over `hadb`; 48 kB base64 chunks, SHA256 compared with the phone):

```bash
python3 -I tools/voice/pull_debug_round.py --list
python3 -I tools/voice/pull_debug_round.py --round <yyyyMMdd-HHmmss-id8> --out build/voice-debug
```

The recordings are private: keep them under `build/` (git-ignored), never commit, upload or paste them, and delete the
directory after analysis.

## Tuning

Offline check against a recording (numbers only; venv with numpy and onnxruntime, model `silero_vad.onnx`):

```bash
python3 -I tools/voice/vad_offline_check.py --model <silero_vad.onnx> --inspect
python3 -I tools/voice/vad_offline_check.py --model <silero_vad.onnx> --wav <round.wav> --grid
python3 -I tools/voice/vad_offline_check.py --model <silero_vad.onnx> --wav <round.wav> --labels <labels> --no-speech-ms 12000
```

`--grid` prints the endpoints for pause values 1000-3000 ms; `--labels` adds the end error in ms; `--no-speech-ms`
changes the wait for speech start. Change the defaults in the app only with numbers from such a run.

Render review 2026-10-13: none. Light and dark, 320 dp at 100% and 200% text (voice-review-bin run 38453228316): the speech-model row sits under the route select with a single action per state (Download / Cancel with progress / Retry with error), no clipped text at 200%, switch rows share the trailing column, dark contrast is fine, no permanent success text. Minor: the debug-audio-source field sits close under the debug switch row; left as is.

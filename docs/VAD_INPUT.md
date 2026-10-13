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

## ANNAHME outcomes

| Assumption | Check | Outcome |
|---|---|---|
| AAR has classes + JNI libs | Task 1 | Confirmed: all 9 classes and member names present, arm64 JNI libs present; no fallback needed |

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

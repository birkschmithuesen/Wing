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

## Mutation check (pause threshold 0)

`_pauseWindows = 0` (Dart) / `self._pause_windows = 0` (Python): CI run 38428132411 failed in
`a thinking pause shorter than the pause keeps the round open` (+ 7 more: `ends after the pause and keeps the tail`,
`56 silent windows do not end it and pre-roll is clamped at zero`, `a speech start in progress at the no-speech timeout is not cut`,
`probabilities between the thresholds keep speech going`, `probabilities between the thresholds do not reset a starting run`,
`a shorter pause setting ends earlier`, `media key stop keeps speech minus pre-roll`); the Python parity test failed locally
with the same 8 subTests (`FAILED (failures=8)`).

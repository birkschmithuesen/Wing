#!/usr/bin/env python3
"""Offline check of the vad endpoint parameters. Prints numbers only.

Never copies or prints audio or text. Typical use:
  build/vad-venv/bin/python -I tools/voice/vad_offline_check.py --model build/vad-check/silero_vad.onnx --inspect
  build/vad-venv/bin/python -I tools/voice/vad_offline_check.py --model M --wav <file> [--labels L.json] [--grid]
--labels: JSON {"speech": [[start_s, end_s], ...]} with true speech intervals (for synthetic files from
make_selftest_audio.py, or hand-made for a real recording; keep such labels outside the repo).
"""
import argparse
import json
import pathlib
import sys
import wave

import numpy as np
import onnxruntime as ort

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import vad_endpoint as ve  # noqa: E402

RATE = 16000
CONTEXT = 64


def read_mono_16k(path):
    with wave.open(str(path)) as w:
        channels, width, rate, frames = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        if width != 2:
            raise SystemExit(f"only 16-bit PCM supported, got {width * 8}-bit")
        data = np.frombuffer(w.readframes(frames), dtype="<i2").astype(np.float32) / 32768.0
    data = data.reshape(-1, channels).mean(axis=1)
    if rate != RATE:
        # FFT resampling; fine for VAD purposes.
        n_out = int(round(len(data) * RATE / rate))
        spectrum = np.fft.rfft(data)
        keep = n_out // 2 + 1
        spectrum = spectrum[:keep] if len(spectrum) >= keep else np.pad(spectrum, (0, keep - len(spectrum)))
        data = np.fft.irfft(spectrum, n_out).astype(np.float32) * (n_out / len(data))
    return data, rate, channels


class Silero:
    """Same input layout as Wing: 64 context samples + 512 new ones per call."""

    def __init__(self, model):
        options = ort.SessionOptions()
        options.inter_op_num_threads = 1
        options.intra_op_num_threads = 1
        self.session = ort.InferenceSession(str(model), options, providers=["CPUExecutionProvider"])
        self.inputs = {i.name: i for i in self.session.get_inputs()}

    def probabilities(self, samples):
        # The model in build/vad-check (sherpa-onnx asr-models/silero_vad.onnx) has inputs x [1,512], h, c
        # [2,1,64] and outputs prob, new_h, new_c (v4 layout, no context, no sr). The v5 layout
        # (x with 64 context samples, state [2,1,128], sr) is kept as fallback.
        legacy = "h" in self.inputs
        state = np.zeros((2, 1, 128), dtype=np.float32)
        h = np.zeros((2, 1, 64), dtype=np.float32)
        c = np.zeros((2, 1, 64), dtype=np.float32)
        context = np.zeros(CONTEXT, dtype=np.float32)
        sr = np.array(RATE, dtype=np.int64)
        out = []
        for start in range(0, len(samples) - ve.WINDOW_SAMPLES + 1, ve.WINDOW_SAMPLES):
            chunk = samples[start:start + ve.WINDOW_SAMPLES]
            if legacy:
                prob, h, c = self.session.run(None, {"x": chunk[None, :], "h": h, "c": c})[:3]
            else:
                x = np.concatenate([context, chunk])[None, :]
                prob, state = self.session.run(None, {"x": x, "state": state, "sr": sr})[:2]
                context = chunk[-CONTEXT:]
            out.append(float(np.asarray(prob).reshape(-1)[0]))
        return out


def segments(probabilities, config):
    """Run the endpointer repeatedly like consecutive rounds; returns decisions in seconds."""
    result, offset = [], 0
    while offset < len(probabilities):
        endpointer = ve.Endpointer(config)
        decision = endpointer.feed_all(probabilities[offset:])
        if decision is None:
            decision = endpointer.force_end("endOfFile")
        w = ve.WINDOW_MS / 1000
        result.append({
            "reason": decision.reason,
            "start_s": round((offset + decision.start_window) * w, 3),
            "end_s": round((offset + decision.end_window) * w, 3),
            "decided_s": round((offset + decision.at_window + 1) * w, 3),
        })
        offset += decision.at_window + 1
    return result


def score(found, labels):
    """End error of the round covering each labeled utterance group, false rounds, splits."""
    speech = labels["speech"]
    spoken = [s for s in found if s["reason"] in ("pause", "maxDuration")]
    false_rounds = [s for s in spoken if not any(a < s["end_s"] and b > s["start_s"] for a, b in speech)]
    end_errors = []
    for s in spoken:
        inside = [b for a, b in speech if a < s["end_s"] and b > s["start_s"]]
        if inside:
            end_errors.append(round((s["end_s"] - max(inside)) * 1000))
    return {"rounds_with_speech": len(spoken), "false_rounds": len(false_rounds), "end_error_ms": end_errors}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--wav")
    parser.add_argument("--labels")
    parser.add_argument("--grid", action="store_true")
    parser.add_argument("--inspect", action="store_true")
    parser.add_argument("--no-speech-ms", type=int, default=8000)
    args = parser.parse_args()
    silero = Silero(args.model)
    if args.inspect:
        print(json.dumps({"inputs": {n: list(i.shape) for n, i in silero.inputs.items()},
                          "outputs": [o.name for o in silero.session.get_outputs()]}))
        return
    samples, rate, channels = read_mono_16k(args.wav)
    probabilities = silero.probabilities(samples)
    p = np.array(probabilities)
    report = {
        "input": {"rate": rate, "channels": channels, "seconds": round(len(samples) / RATE, 2)},
        "windows": len(p),
        "probability_percentiles": {str(q): round(float(np.percentile(p, q)), 3) for q in (10, 50, 90, 99)},
        "share_above_start": round(float((p >= ve.START_THRESHOLD).mean()), 3),
    }
    labels = json.loads(pathlib.Path(args.labels).read_text()) if args.labels else None
    pauses = (1000, 1400, 1800, 2400, 3000) if args.grid else (1800,)
    report["runs"] = []
    for pause in pauses:
        found = segments(probabilities, ve.Config(pause_ms=pause, no_speech_ms=args.no_speech_ms))
        run = {"pause_ms": pause, "rounds": found}
        if labels:
            run["score"] = score(found, labels)
        report["runs"].append(run)
    print(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()

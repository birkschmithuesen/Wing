#!/usr/bin/env python3
"""Builds a synthetic test file: noise lead, sentence A, short thinking pause, sentence B, noise tail.

Inputs must be synthetic (TTS) speech, never real recordings of a person.
Writes 16 kHz mono PCM16 WAV and a labels JSON {"speech": [[s, e], ...], "thinking_pause_s": x}.
Prints only numbers.
"""
import argparse
import json
import pathlib
import sys
import wave

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from vad_offline_check import RATE, read_mono_16k  # noqa: E402


def rms(x):
    return float(np.sqrt(np.mean(np.square(x)) + 1e-12))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--speech", action="append", required=True)
    parser.add_argument("--noise", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--labels-out", required=True)
    parser.add_argument("--lead-s", type=float, default=4.0)
    parser.add_argument("--pause-s", type=float, default=1.0)
    parser.add_argument("--tail-s", type=float, default=6.0)
    parser.add_argument("--snr-db", type=float, default=10.0)
    args = parser.parse_args()
    parts, labels, cursor = [], [], 0.0
    gap = np.zeros(int(args.lead_s * RATE), dtype=np.float32)
    parts.append(gap)
    cursor += args.lead_s
    for index, path in enumerate(args.speech):
        speech, _, _ = read_mono_16k(path)
        # Trim digital silence around the TTS sentence so labels are exact.
        voiced = np.flatnonzero(np.abs(speech) > 0.01)
        speech = speech[voiced[0]:voiced[-1] + 1]
        labels.append([round(cursor, 3), round(cursor + len(speech) / RATE, 3)])
        parts.append(speech)
        cursor += len(speech) / RATE
        pause = args.pause_s if index < len(args.speech) - 1 else args.tail_s
        parts.append(np.zeros(int(pause * RATE), dtype=np.float32))
        cursor += pause
    clean = np.concatenate(parts)
    noise, _, _ = read_mono_16k(args.noise)
    noise = np.resize(noise, len(clean))
    speech_rms = rms(np.concatenate([clean[int(a * RATE):int(b * RATE)] for a, b in labels]))
    noise = noise * (speech_rms / rms(noise)) / (10 ** (args.snr_db / 20))
    mix = np.clip(clean + noise, -1, 1)
    with wave.open(args.out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((mix * 32767).astype("<i2").tobytes())
    pathlib.Path(args.labels_out).write_text(json.dumps({"speech": labels, "thinking_pause_s": args.pause_s}))
    print(json.dumps({"seconds": round(len(mix) / RATE, 2), "speech": labels, "snr_db": args.snr_db}))


if __name__ == "__main__":
    main()

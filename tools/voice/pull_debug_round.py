#!/usr/bin/env python3
"""Fetches one debug round (WAV + JSON) of Wing Voice from the phone via hadb (root).

hadb push/pull fail above ~100 kB over Tailscale, so the file is copied to /data/local/tmp,
read as base64 in 48 kB chunks and checked against the phone's sha256. The data is private:
use an --out directory under build/ (git-ignored) and delete it after analysis.
Usage: python3 -I tools/voice/pull_debug_round.py --list
       python3 -I tools/voice/pull_debug_round.py --round 20261014-101500-abcd1234 --out build/voice-debug
"""
import argparse
import base64
import hashlib
import pathlib
import subprocess

HADB = str(pathlib.Path.home() / ".local/bin/hadb")
SRC = "/data/data/com.tarkilhk.wing.voice/files/voice-debug"
TMP = "/data/local/tmp/wingvad"
CHUNK = 49152


def shell(command):
    return subprocess.run([HADB, "shell", command], check=True, capture_output=True).stdout


def pull(name, out):
    shell(f"mkdir -p {TMP}")
    shell(f'su -c "cp {SRC}/{name} {TMP}/{name}"')
    shell(f'su -c "chmod 644 {TMP}/{name}"')
    size = int(shell(f"stat -c %s {TMP}/{name}").strip())
    expected = shell(f"sha256sum {TMP}/{name}").split()[0].decode()
    data = bytearray()
    for index in range((size + CHUNK - 1) // CHUNK):
        chunk = shell(f"dd if={TMP}/{name} bs={CHUNK} skip={index} count=1 2>/dev/null | base64")
        data += base64.b64decode(b"".join(chunk.split()))
    shell(f"rm -f {TMP}/{name}")
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        raise SystemExit(f"{name}: sha256 mismatch")
    (out / name).write_bytes(bytes(data))
    print(f"{name} {size} bytes sha256 ok")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--round")
    parser.add_argument("--out", default="build/voice-debug")
    args = parser.parse_args()
    if args.list:
        print(shell(f'su -c "ls -l {SRC}"').decode())
        return
    if not args.round:
        parser.error("--round or --list required")
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for suffix in (".json", ".wav"):
        pull(args.round + suffix, out)


if __name__ == "__main__":
    main()

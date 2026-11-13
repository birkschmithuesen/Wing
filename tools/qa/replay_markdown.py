#!/usr/bin/env python3
"""Collect matched profile replays from the focused Wing Perf QA app only."""
import argparse
import json
import re
import urllib.parse
from pathlib import Path

from wing_perf_client import WingPerfClient

PACKAGE = "com.tarkilhk.wing.perfqa"


def focused(client):
    windows = client.call("shell", "dumpsys", "window")
    if not any("mCurrentFocus=" in line and re.search(
            r"(?:^|\s)" + re.escape(PACKAGE) + "/", line)
            for line in windows.splitlines()):
        raise RuntimeError("Wing Perf QA must be focused")


def collect(client, mode, report):
    report['stage'] = 'focus'
    focused(client)
    flags = {f["name"]: f["valueAsString"] for f in client.rpc("getFlagList")["flags"]}
    original = flags["profiler"]
    try:
        report['stage'] = 'profiler_flag'
        client.rpc("setFlag", name="profiler", value="false")
        # The private service URL is used in memory only and never printed.
        params = {"isolateId": client.isolate,
                  "fences": "true" if mode == "fences" else "false"}
        url = client.base + "ext.wingPerf.replay?" + urllib.parse.urlencode(params)
        report['stage'] = 'replay_rpc'
        with client.http.open(url, timeout=30) as response:
            value = json.load(response)
        if "error" in value:
            raise RuntimeError("Replay failed")
        replay = value["result"]
        report['stage'] = 'validation'
        focused(client)
        expected = {"valid": 1, "exactFinalContent": 1, "exactFinalDraft": 1,
                    "exactFinalRendered": 1, "pendingParses": 0,
                    "deltas": 600, "presentations": 60, "draftEdits": 120}
        if any(replay.get(key) != count for key, count in expected.items()):
            raise RuntimeError("Replay correctness validation failed")
        if not replay["buildUs"] or len(replay["buildUs"]) != replay["frameCount"]:
            raise RuntimeError("Frame capture is empty or incomplete")
        return replay
    finally:
        client.rpc("setFlag", name="profiler", value=original)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--mode", choices=["prose", "fences"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = {"mode": args.mode, "status": "inconclusive", "cpuSamplerEnabled": False}
    try:
        report['stage'] = 'connect'
        with WingPerfClient(args.serial, PACKAGE) as client:
            report["replay"] = collect(client, args.mode, report)
            report["status"] = "complete"
    except Exception as error:
        # Exception text can contain private VM URLs or connected addresses.
        report["errorType"] = type(error).__name__
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "mode": args.mode,
                      "stage": report.get('stage'),
                      "frames": report.get("replay", {}).get("frameCount")}))
    return 0 if report["status"] == "complete" else 2


if __name__ == "__main__":
    raise SystemExit(main())

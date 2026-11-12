#!/usr/bin/env python3
"""Bounded CPU/timeline diagnostic for the synthetic perfqa profile APK only."""
import argparse
import json
import re
import urllib.parse
from pathlib import Path

from wing_perf_client import WingPerfClient

PACKAGE = "com.tarkilhk.wing.perfqa"
STREAMS = ["Dart", "Embedder", "GC"]


class RpcFailure(Exception):
    def __init__(self, method, code=-1):
        self.method, self.code = method, code


def rpc(client, method, timeout=8, **params):
    """Keep transport/error details private, including the service access token."""
    url = client.base + method + "?" + urllib.parse.urlencode(params)
    try:
        with client.http.open(url, timeout=timeout) as response:
            value = json.load(response)
    except Exception:
        raise RpcFailure(method) from None
    if not isinstance(value, dict):
        raise RpcFailure(method)
    if "error" in value:
        code = value["error"].get("code", -1) if isinstance(value["error"], dict) else -1
        raise RpcFailure(method, code if type(code) is int else -1)
    result = value.get("result")
    if not isinstance(result, dict) or result.get("type") in ("Error", "Sentinel"):
        raise RpcFailure(method)
    if method in ("setFlag", "setVMTimelineFlags") and result.get("type") != "Success":
        raise RpcFailure(method)
    return result


def require(condition):
    if not condition:
        raise ValueError()


def integer(value, minimum=0):
    require(type(value) is int and value >= minimum)
    return value


def error_record(error, stage):
    result = {"stage": stage, "type": type(error).__name__}
    if isinstance(error, RpcFailure):
        result.update(method=error.method, code=error.code)
    return result


def focused(client):
    windows = client.call("shell", "dumpsys", "window")
    require(any("mCurrentFocus=" in line and re.search(r"(?:^|\s)" + re.escape(PACKAGE) + "/", line)
                for line in windows.splitlines()))


def sanitize_cpu(value, start, end):
    require(value.get("type") == "CpuSamples")
    functions, samples = value["functions"], value["samples"]
    require(isinstance(functions, list) and isinstance(samples, list))
    require(integer(value["sampleCount"], 1) == len(samples) and functions)
    rows = []
    for row in functions:
        name, uri = row["function"]["name"], row.get("resolvedUrl", "")
        require(isinstance(name, str) and isinstance(uri, str))
        native_image = re.fullmatch(
            r"\[Native\] .*[\\/](lib(?:app|flutter|c|m|dl|log|android|vulkan|EGL|GLESv2|hwui|art)\.so)(\+0x[0-9a-fA-F]+)?",
            name,
        )
        if native_image:
            name = "[Native] " + native_image[1] + (native_image[2] or "")
        elif "\\" in name or re.search(r"/[A-Za-z0-9_.]", name):
            name = ""
        owner = row["function"].get("owner")
        owner_name = ""
        if isinstance(owner, dict) and owner.get("type") in ("@Class", "@Function"):
            candidate = owner.get("name", "")
            if isinstance(candidate, str) and re.fullmatch(r"[A-Za-z0-9_$<>. ]{1,256}", candidate):
                owner_name = candidate
        rows.append({"name": name, "source": uri if uri.startswith(("dart:", "package:")) else "",
                     "owner": owner_name,
                     "inclusive_ticks": integer(row["inclusiveTicks"]),
                     "exclusive_ticks": integer(row["exclusiveTicks"])})
    clean = []
    for sample in samples:
        timestamp, stack = integer(sample["timestamp"]), sample["stack"]
        require(start <= timestamp <= end and isinstance(stack, list))
        require(all(type(index) is int and 0 <= index < len(rows) for index in stack))
        require(type(sample.get("truncated", False)) is bool)
        clean.append({"timestamp": timestamp, "tid": integer(sample["tid"]),
                      "stack": stack[:], "truncated": sample.get("truncated", False)})
    require(any(sample["stack"] for sample in clean))
    return {"sample_count": len(clean), "unattributed_sample_count": sum(not s["stack"] for s in clean),
            "sample_period_us": integer(value["samplePeriod"], 1),
            "max_stack_depth": integer(value["maxStackDepth"], 1),
            "start_us": start, "end_us": end, "stack_order": "leaf_first",
            "functions": rows, "samples": clean}


def sanitize_timeline(value, start, end):
    require(value.get("type") == "Timeline" and isinstance(value["traceEvents"], list))
    clean, markers, dart_events, frames = [], set(), 0, 0
    for event in value["traceEvents"]:
        require(isinstance(event, dict))
        if event.get("ph") in ("M", "C"):
            continue  # Metadata/counter arguments are unnecessary for attribution.
        timestamp = event.get("ts")
        require(type(timestamp) in (int, float) and start <= timestamp <= end)
        require(isinstance(event.get("name"), str) and isinstance(event.get("ph"), str))
        if event.get("cat") == "Dart":
            dart_events += 1
        if event["name"] == "Frame":
            frames += 1
        if event["name"] in ("WingStreamingReplayStart", "WingStreamingReplayEnd"):
            markers.add(event["name"])
        row = {key: event[key] for key in ("name", "ph", "ts")}
        if event.get("cat") in STREAMS:
            row["cat"] = event["cat"]
        if "id" in event:
            identifier = event["id"]
            require(type(identifier) is int or
                    (isinstance(identifier, str) and re.fullmatch(r"(?:0x)?[0-9a-fA-F]+", identifier)))
            row["id"] = identifier  # Link async frame events without exporting arguments.
        for key in ("dur", "tid", "pid"):
            if key in event:
                require(type(event[key]) in (int, float) and event[key] >= 0)
                row[key] = event[key]
        clean.append(row)
    require(clean and dart_events and frames and len(markers) == 2)
    return {"start_us": start, "end_us": end, "traceEvents": clean}


def capture(client, mode, label):
    report = {"label": label, "mode": mode, "package": PACKAGE, "status": "inconclusive", "errors": []}
    original_profiler, original_streams, stage = None, None, 1
    try:
        focused(client)
        isolate = rpc(client, "getIsolate", isolateId=client.isolate)
        require("ext.wingPerf.replay" in isolate.get("extensionRPCs", []))
        flags = {flag["name"]: flag["valueAsString"] for flag in rpc(client, "getFlagList")["flags"]}
        original_profiler = flags["profiler"]
        require(original_profiler in ("true", "false"))
        report["profile_period_us"] = integer(int(flags["profile_period"]), 1)
        timeline_flags = rpc(client, "getVMTimelineFlags")
        streams = timeline_flags["recordedStreams"]
        require(isinstance(streams, list) and all(isinstance(s, str) for s in streams))
        original_streams = streams
        require(timeline_flags["recorderName"] in ("Ring", "Endless", "Startup"))
        require(set(STREAMS) <= set(timeline_flags["availableStreams"]))
        report["timeline_recorder"] = timeline_flags["recorderName"]
        stage = 2
        rpc(client, "setFlag", name="profiler", value="true")
        rpc(client, "setVMTimelineFlags", recordedStreams="[" + ",".join(STREAMS) + "]")
        require(set(rpc(client, "getVMTimelineFlags")["recordedStreams"]) == set(STREAMS))
        envelope_start = integer(rpc(client, "getVMTimelineMicros")["timestamp"], 1)
        stage = 3
        replay = rpc(client, "ext.wingPerf.replay", timeout=25, isolateId=client.isolate,
                     fences="true" if mode == "fences" else "false")
        envelope_end = integer(rpc(client, "getVMTimelineMicros")["timestamp"], 1)
        focused(client)
        require(all(replay[key] == count for key, count in
                    {"deltas": 600, "presentations": 60, "draftEdits": 120, "valid": 1,
                     "geometryStable": 1, "animationEnabled": 1, "focusHeld": 1,
                     "exactFinalContent": 1, "exactFinalDraft": 1}.items()))
        require(replay["keyboardStartDp"] > 0 and replay["keyboardEndDp"] > 0)
        integer(replay["frameCount"], 1)
        start, end = integer(replay["startMonotonicUs"], 1), integer(replay["endMonotonicUs"], 1)
        require(envelope_start <= start < end <= envelope_end and envelope_end - envelope_start <= 30000000)
        stage = 4
        report["cpu"] = sanitize_cpu(rpc(client, "getCpuSamples", isolateId=client.isolate,
                                    timeOriginMicros=start, timeExtentMicros=end - start), start, end)
        report["timeline"] = sanitize_timeline(rpc(client, "getVMTimeline", timeOriginMicros=envelope_start,
                                              timeExtentMicros=envelope_end - envelope_start), envelope_start, envelope_end)
        report["replay"] = {key: replay[key] for key in
                            ("run", "deltas", "presentations", "draftEdits", "frameCount", "elapsedUs")}
        for key in ("buildUs", "rasterUs", "frameBuildStartUs"):
            values = replay[key]
            require(isinstance(values, list) and len(values) == replay["frameCount"])
            require(all(type(v) is int and v >= 0 for v in values))
            if key == "frameBuildStartUs":
                require(all(start < v <= end for v in values))
            report["replay"][key] = values
    except Exception as error:
        report["errors"].append(error_record(error, stage))
    finally:
        for method, params in (("setVMTimelineFlags", {"recordedStreams": "[" + ",".join(original_streams or []) + "]"}),
                               ("setFlag", {"name": "profiler", "value": original_profiler})):
            if (original_streams if method == "setVMTimelineFlags" else original_profiler) is not None:
                try:
                    rpc(client, method, **params)
                except Exception as error:
                    report["errors"].append(error_record(error, 5))
        try:
            if original_streams is not None:
                require(rpc(client, "getVMTimelineFlags")["recordedStreams"] == original_streams)
            if original_profiler is not None:
                restored = rpc(client, "getFlagList")["flags"]
                require(next(f["valueAsString"] for f in restored if f["name"] == "profiler") == original_profiler)
        except Exception as error:
            report["errors"].append(error_record(error, 5))
    report["status"] = "inconclusive" if report["errors"] else "complete"
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--mode", required=True, choices=("plain", "fences"))
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", args.label):
        parser.error("label must contain 1-80 letters, digits, underscores or hyphens")
    try:
        with WingPerfClient(args.serial, PACKAGE) as client:
            report = capture(client, args.mode, args.label)
    except Exception as error:
        report = {"status": "inconclusive", "errors": [error_record(error, 0)]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "errors": report["errors"]}))
    return 0 if report["status"] == "complete" else 1


if __name__ == "__main__":
    raise SystemExit(main())

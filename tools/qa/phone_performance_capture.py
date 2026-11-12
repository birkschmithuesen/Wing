#!/usr/bin/env python3
"""Bounded release traces and sparse screen-off battery observations.

No gestures, app stops, installations, settings writes or backend calls. Keep
outputs under ignored build/. The caller controls the scenario and validates
trace capabilities. Battery counters describe the whole phone, not app energy.
"""
import argparse
import datetime
import json
import re
import signal
import subprocess
import time
import uuid
from pathlib import Path

PACKAGE = "com.tarkilhk.wing"


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def parse_battery(raw):
    names = {
        "level": "level_percent", "status": "status", "health": "health",
        "temperature": "temperature_tenths_c", "voltage": "voltage_mv",
        "Charge counter": "charge_counter_uah",
    }
    result = {}
    for source, target in names.items():
        match = re.search(r"^\s*" + re.escape(source) + r":\s*(-?\d+)\s*$", raw, re.M)
        result[target] = int(match[1]) if match else None
    for source, target in (
        ("AC powered", "ac_powered"), ("USB powered", "usb_powered"),
        ("Wireless powered", "wireless_powered"), ("Dock powered", "dock_powered"),
    ):
        match = re.search(r"^\s*" + re.escape(source) + r":\s*(true|false)\s*$", raw, re.M)
        result[target] = match[1] == "true" if match else None
    return result


def parse_power(raw):
    match = re.search(r"\bmWakefulness=(\w+)", raw)
    states = sorted(set(re.findall(r"Display Power: state=(\w+)", raw)))
    return {"wakefulness": match[1] if match else None, "display_states": states}


def parse_idle(raw):
    result = {}
    for name in ("mState", "mLightState", "mScreenOn", "mCharging"):
        match = re.search(r"\b" + name + r"=(\w+)", raw)
        result[name] = match[1] if match else None
    return result


def parse_version(raw):
    result = {}
    for name in ("versionCode", "versionName"):
        match = re.search(r"\b" + name + r"=(\S+)", raw)
        result[name] = match[1] if match else None
    return result


def checkpoint_issues(checkpoint, expected_state, original_pids=None):
    issues = []
    battery, power = checkpoint["battery"], checkpoint["power"]
    if any(battery[name] is None for name in ("ac_powered", "usb_powered", "wireless_powered")):
        issues.append("Charging-source state unavailable")
    if any(battery.get(name) is True for name in ("ac_powered", "usb_powered", "wireless_powered", "dock_powered")):
        issues.append("Phone connected to power")
    if battery["status"] != 3:
        issues.append("Battery not confirmed discharging")
    if battery["charge_counter_uah"] is None or battery["charge_counter_uah"] <= 0:
        issues.append("Usable charge counter unavailable")
    if power["wakefulness"] not in ("Asleep", "Dozing"):
        issues.append("Phone not confirmed logically screen off")
    if any(state not in ("OFF", "DOZE", "DOZE_SUSPEND") for state in power["display_states"]):
        issues.append("An observed display is on")
    if checkpoint["device_idle"]["mScreenOn"] == "true":
        issues.append("Device-idle service reports screen on")
    pids = checkpoint["wing_pids"]
    if bool(pids) != (expected_state == "running"):
        issues.append("Wing process state differs from expected state")
    if original_pids is not None and pids != original_pids:
        issues.append("Wing PID changed between sampled checkpoints")
    return issues


def charge_summary(checkpoints):
    if len(checkpoints) < 2:
        return None
    first, last = checkpoints[0], checkpoints[-1]
    start = first["battery"]["charge_counter_uah"]
    end = last["battery"]["charge_counter_uah"]
    seconds = last["battery_read_monotonic_seconds"] - first["battery_read_monotonic_seconds"]
    if start is None or end is None or seconds <= 0:
        return None
    drop = start - end
    return {"counter_elapsed_seconds": round(seconds, 3), "drop_uah": drop,
            "drop_mah": drop / 1000, "mean_whole_device_ma": drop * 3.6 / seconds}


def trace_config(seconds):
    return f'''buffers {{ size_kb: 32768 fill_policy: RING_BUFFER }}
duration_ms: {seconds * 1000}
write_into_file: true
data_sources {{ config {{ name: "linux.process_stats"
  process_stats_config {{ scan_all_processes_on_start: true }} }} }}
data_sources {{ config {{ name: "android.surfaceflinger.frametimeline" }} }}
data_sources {{ config {{ name: "linux.ftrace" ftrace_config {{
  ftrace_events: "sched/sched_switch"
  ftrace_events: "sched/sched_waking"
  ftrace_events: "power/cpu_frequency"
  ftrace_events: "power/cpu_idle"
  atrace_categories: "gfx"
  atrace_categories: "view"
  atrace_categories: "input"
  atrace_categories: "wm"
  atrace_categories: "am"
  atrace_apps: "{PACKAGE}"
}} }} }}
data_sources {{ config {{ name: "android.log" android_log_config {{
  filter_tags: "WingPerf"
}} }} }}
'''


class Capture:
    def __init__(self, args):
        self.args = args
        self.adb = ["adb", "-s", args.serial]
        self.started = time.monotonic()
        self.deadline = self.started + 90 if args.mode == "trace" else None
        self.stop_reason = None
        self.last_progress = self.started
        self.report = {"label": args.label, "mode": args.mode, "package": PACKAGE,
                       "started_utc": utc_now(), "requested_seconds": args.seconds,
                       "status": "recording", "inconclusive_reasons": []}
        args.output.mkdir(parents=True, exist_ok=True)

    def signal_stop(self, signum, _frame):
        self.stop_reason = "Received " + signal.Signals(signum).name

    def check_stop(self):
        if self.args.abort_file and self.args.abort_file.exists():
            self.stop_reason = "Abort file present"
        if self.deadline is not None and time.monotonic() >= self.deadline:
            self.stop_reason = "90-second trace command deadline reached"
        if self.stop_reason:
            raise InterruptedError(self.stop_reason)

    def call(self, *words, check=True, cleanup=False, input_text=None):
        if not cleanup:
            self.check_stop()
        timeout = 30.0 if words and words[0] == "pull" else 8.0
        if self.deadline is not None:
            timeout = min(timeout, self.deadline - time.monotonic())
            if timeout <= 0:
                raise TimeoutError("Trace command deadline reached")
        result = subprocess.run(self.adb + list(words), capture_output=True,
                                text=True, timeout=timeout, input=input_text)
        if check and result.returncode:
            # Do not expose arbitrary ADB stdout/stderr (may contain app data).
            raise RuntimeError("ADB operation failed")
        return result

    def shell(self, *words):
        return self.call("shell", *words).stdout

    def save(self):
        self.report["elapsed_host_seconds"] = round(time.monotonic() - self.started, 3)
        temporary = self.args.output / "capture.json.tmp"
        temporary.write_text(json.dumps(self.report, indent=2) + "\n")
        temporary.replace(self.args.output / "capture.json")

    def wait_until(self, deadline):
        while time.monotonic() < deadline:
            self.check_stop()
            now = time.monotonic()
            if now - self.last_progress >= 30:
                print(f"{self.args.mode}: {now - self.started:.0f}s elapsed", flush=True)
                self.last_progress = now
            time.sleep(min(.25, max(0, deadline - now)))

    def metadata(self):
        return {"device_model": self.shell("getprop", "ro.product.model").strip(),
                "android_version": self.shell("getprop", "ro.build.version.release").strip(),
                "wing_version": parse_version(self.shell("dumpsys", "package", PACKAGE))}

    def outside_interval(self):
        thermal = self.shell("dumpsys", "thermalservice")
        match = re.search(r"^\s*Thermal Status: (\d+)\s*$", thermal, re.M)
        memory = self.shell("cat", "/proc/meminfo")
        result = {"time_utc": utc_now(), "thermal_status": int(match[1]) if match else None,
                  "memory_kb": {k: int(v) for k, v in re.findall(
                      r"^(MemAvailable|SwapTotal|SwapFree):\s+(\d+)", memory, re.M)}}
        if self.args.expected_wing_state == "running":
            app_memory = self.shell("dumpsys", "meminfo", PACKAGE)
            result["wing_memory_kb"] = {k: int(v) for k, v in re.findall(
                r"(TOTAL PSS|TOTAL RSS|TOTAL SWAP PSS):\s+(\d+)", app_memory)}
        return result

    def battery_checkpoint(self, target_offset):
        before = time.monotonic()
        raw = self.shell("dumpsys", "battery")
        after = time.monotonic()
        checkpoint = {"target_offset_seconds": target_offset, "battery_read_utc": utc_now(),
                      "battery_read_monotonic_seconds": (before + after) / 2,
                      "battery_read_latency_seconds": after - before,
                      "battery": parse_battery(raw)}
        # Retain a counter already read if a later state query is interrupted.
        self.report["checkpoints"].append(checkpoint)
        self.save()
        pid = self.call("shell", "pidof", PACKAGE, check=False)
        if pid.returncode not in (0, 1):
            raise RuntimeError("Wing PID query failed")
        pids = pid.stdout.strip().split()
        if any(not value.isdigit() for value in pids):
            raise RuntimeError("Wing PID query returned unexpected data")
        checkpoint["wing_pids"] = sorted(pids, key=int)
        checkpoint["power"] = parse_power(self.shell("dumpsys", "power"))
        checkpoint["device_idle"] = parse_idle(self.shell("dumpsys", "deviceidle"))
        return checkpoint

    def battery(self):
        self.report.update({"expected_wing_state": self.args.expected_wing_state,
                            "checkpoints": [], "observation_scope":
                            "Sparse sampled screen/process/policy states only; wireless ADB is an observer. "
                            "No continuous screen-off, PID stability or natural Doze guarantee.",
                            "counter_timestamp_basis": "Host monotonic midpoint of each battery-read call; latency records its uncertainty."})
        self.report["environment"] = self.metadata()
        if not all(self.report["environment"]["wing_version"].values()):
            raise RuntimeError("Installed Wing version unavailable")
        self.report["outside_interval_before"] = self.outside_interval()
        first = self.battery_checkpoint(0)
        origin = first["battery_read_monotonic_seconds"]
        issues = checkpoint_issues(first, self.args.expected_wing_state)
        self.report["inconclusive_reasons"].extend(issues)
        self.save()
        if issues:
            return
        offsets = list(range(600, self.args.seconds, 600)) + [self.args.seconds]
        for offset in offsets:
            self.wait_until(origin + offset)
            checkpoint = self.battery_checkpoint(offset)
            issues = checkpoint_issues(checkpoint, self.args.expected_wing_state, first["wing_pids"])
            previous_counter = self.report["checkpoints"][-2]["battery"]["charge_counter_uah"]
            current_counter = checkpoint["battery"]["charge_counter_uah"]
            if previous_counter is not None and current_counter is not None and current_counter > previous_counter:
                issues.append("Charge counter increased between unplugged checkpoints")
            self.report["inconclusive_reasons"].extend(issues)
            self.report["charge_summary"] = charge_summary(self.report["checkpoints"])
            self.save()
            if issues:
                return
        self.report["wing_version_after"] = parse_version(self.shell("dumpsys", "package", PACKAGE))
        if self.report["wing_version_after"] != self.report["environment"]["wing_version"]:
            self.report["inconclusive_reasons"].append("Wing version changed")
        summary = self.report["charge_summary"]
        if summary is None or summary["drop_uah"] <= 0:
            self.report["inconclusive_reasons"].append("No positive measured discharge; counter resolution/recalibration may obscure it")
        self.report["outside_interval_after"] = self.outside_interval()
        self.report["completed_interval"] = True

    def trace(self):
        nonce = uuid.uuid4().hex
        key = "wing-qa-" + nonce
        remote_trace = "/data/misc/perfetto-traces/" + key + ".pftrace"
        config = self.args.output / "trace-config.pbtxt"
        config.write_text(trace_config(self.args.seconds))
        self.report.update({"session_key": key, "trace_file": "trace.pftrace",
                            "own_remote_trace": remote_trace,
                            "interpretation": "Scheduler/native submission evidence; SurfaceView presentation jank and composer input-to-glyph latency are not established."})
        attempted = False
        try:
            self.report["environment"] = self.metadata()
            if self.deadline - time.monotonic() < self.args.seconds + 12:
                raise TimeoutError("Insufficient time left to start bounded trace")
            attempted = True
            self.call("shell", "perfetto", "--txt", "-c", "-",
                      "-o", remote_trace, "--detach=" + key,
                      input_text=config.read_text())
            self.report["trace_started_utc"] = utc_now()
            self.save()
            print("Trace armed; caller controls the QA scenario.", flush=True)
            self.wait_until(time.monotonic() + self.args.seconds + 1)
            self.report["completed_interval"] = True
        finally:
            if attempted:
                try:
                    state = self.call("shell", "perfetto", "--is_detached=" + key,
                                      check=False, cleanup=True)
                    if state.returncode == 0:
                        stopped = self.call("shell", "perfetto", "--attach=" + key,
                                            "--stop", check=False, cleanup=True)
                        if stopped.returncode:
                            self.report["inconclusive_reasons"].append("Own trace stop was not confirmed; bounded trace duration remains in force")
                    elif state.returncode != 2:
                        self.report["inconclusive_reasons"].append("Own trace session state unavailable")
                    pulled = self.call("pull", remote_trace, str(self.args.output / "trace.pftrace"),
                                       check=False, cleanup=True)
                    local_trace = self.args.output / "trace.pftrace"
                    self.report["trace_bytes"] = local_trace.stat().st_size if local_trace.is_file() else 0
                    self.report["trace_pulled"] = pulled.returncode == 0 and self.report["trace_bytes"] > 0
                    if not self.report["trace_pulled"]:
                        self.report["inconclusive_reasons"].append("Trace artifact unavailable")
                except Exception as error:
                    self.report["inconclusive_reasons"].append("Trace finalization failed: " + type(error).__name__)
            if attempted and self.report.get("trace_pulled"):
                try:
                    removed = self.call("shell", "rm", "-f", remote_trace,
                                        check=False, cleanup=True)
                    self.report["own_remote_files_removed"] = removed.returncode == 0
                    if not self.report["own_remote_files_removed"]:
                        self.report["inconclusive_reasons"].append("Own remote file cleanup unconfirmed")
                except Exception as error:
                    self.report["inconclusive_reasons"].append("Own remote cleanup failed: " + type(error).__name__)
            elif attempted:
                # A failed pull must not discard the only recoverable evidence.
                self.report["own_remote_files_removed"] = False
                self.report["recovery_remote_trace"] = remote_trace


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="mode", required=True)
    for name, seconds in (("trace", 45), ("battery", 1200)):
        command = commands.add_parser(name)
        command.add_argument("--serial", required=True)
        command.add_argument("--label", required=True)
        command.add_argument("--seconds", type=int, default=seconds)
        command.add_argument("--output", type=Path, required=True, help="Artifact directory")
        command.add_argument("--abort-file", type=Path)
        if name == "battery":
            command.add_argument("--expected-wing-state", choices=("running", "stopped"), required=True)
    args = parser.parse_args()
    if args.seconds < 1 or (args.mode == "trace" and args.seconds > 60):
        parser.error("seconds must be positive; trace captures are limited to 60 seconds")
    capture = Capture(args)
    previous = {sig: signal.signal(sig, capture.signal_stop) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        capture.save()
        getattr(capture, args.mode)()
    except InterruptedError as error:
        capture.report["interrupted"] = True
        capture.report["inconclusive_reasons"].append(str(error))
    except Exception as error:
        capture.report["inconclusive_reasons"].append("Capture failed: " + type(error).__name__)
    finally:
        if capture.report.get("checkpoints"):
            capture.report["charge_summary"] = charge_summary(capture.report["checkpoints"])
        if capture.stop_reason:
            capture.report["interrupted"] = True
            if capture.stop_reason not in capture.report["inconclusive_reasons"]:
                capture.report["inconclusive_reasons"].append(capture.stop_reason)
        capture.report["status"] = "complete" if (capture.report.get("completed_interval")
            and not capture.report["inconclusive_reasons"]) else "inconclusive"
        capture.save()
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    print(json.dumps({"status": capture.report["status"],
                      "report": str(args.output / "capture.json"),
                      "inconclusive_reasons": capture.report["inconclusive_reasons"]}), flush=True)
    return 0 if capture.report["status"] == "complete" else 2


if __name__ == "__main__":
    raise SystemExit(main())

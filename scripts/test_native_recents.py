#!/usr/bin/env python3
"""Drive installed Recents chats using API 36 Android touch events on an emulator.

Only owned fixture chats are used. No live backend, model call or physical device.
Build in an isolated source copy when other agents are changing the checkout.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import re
import subprocess
import time

PACKAGE = "com.tarkilhk.wing.dev"
REMOTE_DEX = "/data/local/tmp/wing-recents-touch.dex"
STAGE = "code_cache/wing-recents-stage.json"
ACK = "code_cache/wing-recents-ack"


def require_completed_cases(stages, *, name=None, mode='standard'):
    if mode not in ('standard', 'code', 'momentum', 'events'):
        raise ValueError(f'Unknown Recents journey mode: {mode}')
    expected = set()
    for theme in ('dark', 'light'):
        for size in ('normal', 'large'):
            if mode == 'momentum' and (theme, size) != ('dark', 'normal'):
                continue
            test_name = (f'native incoming messages {theme} {size}' if mode == 'events'
                         else f'native Recents {theme} {size}' + (' code' if mode == 'code' else ''))
            if name is not None and not re.search(name, test_name):
                continue
            prefix = 'events-' if mode == 'events' else ''
            suffix = f'-{mode}' if mode in ('code', 'momentum') else ''
            expected.add(f'{prefix}{theme}-{size}{suffix}-complete')
    completed = [stage['name'] for stage in stages if stage['name'].endswith('-complete')]
    if not expected or set(completed) != expected or len(completed) != len(expected):
        raise RuntimeError(f'Native Recents acceptance incomplete: expected {sorted(expected)}, got {completed}')
    return completed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--source-directory", type=Path, default=Path.cwd())
    parser.add_argument("--name", help="Run one named Flutter case when recovering a failure")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--momentum-only", action="store_true",
                        help="Run the limited circular-fling and painted-selection journey")
    modes.add_argument("--code-only", action="store_true",
                        help="Run only independent code-copy/exclusion and Android-edge probes")
    modes.add_argument("--events-only", action="store_true",
                        help="Run incoming chat/bot/group cues and read transitions in all four configurations")
    args = parser.parse_args()
    if not args.device.startswith("emulator-"):
        parser.error("This test installs a fixture APK and accepts disposable emulators only")
    source = args.source_directory.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True, mode=0o700)

    def adb(*command: str, data: bytes | None = None, required: bool = True,
            timeout: int = 30) -> subprocess.CompletedProcess:
        result = subprocess.run(["adb", "-s", args.device, *command], input=data,
                                capture_output=True, timeout=timeout)
        if required and result.returncode:
            raise RuntimeError(f"ADB failed: {command!r}\n{result.stderr.decode(errors='replace')}")
        return result

    def shell(*command: str) -> str:
        return adb("shell", *command).stdout.decode().strip()

    if shell("getprop", "ro.kernel.qemu") != "1":
        raise RuntimeError("The selected target is not an emulator")
    if shell("getprop", "ro.build.version.sdk") != "36":
        raise RuntimeError("The native touch fixture targets API 36 explicitly")
    original_size = shell("wm", "size")
    original_density = shell("wm", "density")
    original_scale = shell("settings", "get", "system", "font_scale")
    original_timeout = shell("settings", "get", "system", "screen_off_timeout")
    process = None
    screenrecord = None
    stages: list[dict] = []
    seen: set[str] = set()
    sdk = Path(os.environ["ANDROID_HOME"])
    classes = output / "touch-classes"
    dex = output / "touch-dex"
    classes.mkdir(exist_ok=True)
    dex.mkdir(exist_ok=True)
    fixture = source / "integration_test/fixtures/recents_touch/NativeRecentsTouch.java"
    subprocess.run(["javac", "-cp", str(sdk / "platforms/android-36/android.jar"),
                    "-d", str(classes), str(fixture)], check=True)
    subprocess.run([str(sdk / "build-tools/36.0.0/d8"), "--lib",
                    str(sdk / "platforms/android-36/android.jar"), "--output", str(dex),
                    str(classes / "NativeRecentsTouch.class")], check=True)
    adb("push", str(dex / "classes.dex"), REMOTE_DEX)
    snapshot = {}
    for folder in ["lib", "integration_test", "test/support"]:
        for path in sorted((source / folder).rglob("*")):
            if path.is_file():
                snapshot[str(path.relative_to(source))] = hashlib.sha256(path.read_bytes()).hexdigest()
    for name in ["pubspec.yaml", "pubspec.lock", "assets/fonts/codicons.ttf"]:
        path = source / name
        snapshot[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    snapshot["scripts/test_native_recents.py"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    (output / "tested-inputs.json").write_text(json.dumps(snapshot, indent=2) + "\n")

    def action(item: dict, ratio: float) -> None:
        kind = item["type"]
        if kind == "configure":
            # A previous device task can leave an override density. Fix the
            # native viewport for this matrix and restore the operator's value
            # in finally, rather than testing enlarged text on a tablet width.
            shell("wm", "density", "420")
            shell("wm", "size", "840x2240" if item["large"] else "reset")
            shell("settings", "put", "system", "font_scale", "2.0" if item["large"] else "1.0")
            time.sleep(.8)
        elif kind in ("one", "two", "interrupt"):
            coordinates = [str(round(number * ratio, 3))
                           for contact in item["contacts"] for number in contact]
            command = [kind, *coordinates, str(item["milliseconds"])]
            if kind == "interrupt":
                command.append(str(-24 * ratio))
            # Shell has Android's injection permission. The Java sidecar is never
            # packaged in Wing and explicitly uses the current API 36 input API.
            invocation = (f"CLASSPATH={REMOTE_DEX} app_process /system/bin NativeRecentsTouch "
                          + " ".join(shlex.quote(value) for value in command))
            adb("shell", invocation)
            time.sleep(.7)
        elif kind == "tap":
            shell("input", "tap", str(round(item["x"] * ratio)), str(round(item["y"] * ratio)))
            time.sleep(.3)
        elif kind == "text":
            shell("input", "text", item["text"])
            time.sleep(.6)
        elif kind == "back":
            shell("input", "keyevent", "4")
            time.sleep(.5)
        elif kind == "wait":
            time.sleep(item["milliseconds"] / 1000)
        else:
            raise ValueError(f"Unknown native action {kind}")

    log_path = output / "native-test.log"
    receipt = {"device": args.device, "android": shell("getprop", "ro.build.version.release"),
               "api": 36, "result": "incomplete", "nativeActions": 0,
               "limits": ["Injected stock-shaped gateway observations; no live Hermes or model calls",
                          "Debug emulator animations are not physical-device frame-time measurements",
                          "Accessibility navigation flag; not a TalkBack user session"]}
    try:
        shell("settings", "put", "system", "screen_off_timeout", "2147483647")
        shell("input", "keyevent", "224")
        shell("wm", "dismiss-keyguard")
        adb("shell", "run-as", PACKAGE, "rm", "-f", STAGE, ACK, required=False)
        command = ["flutter", "test", "--no-pub", "--no-uninstall", "-d", args.device,
                   "--reporter", "expanded", "--dart-define=RECENTS_NATIVE_INPUT=true",
                   "integration_test/recent_conversation_native_test.dart"]
        if args.code_only:
            command.append("--dart-define=RECENTS_CODE_ONLY=true")
        if args.momentum_only:
            command.append("--dart-define=RECENTS_MOMENTUM_ONLY=true")
        if args.events_only:
            command.append("--dart-define=RECENTS_EVENTS_ONLY=true")
        if args.name:
            command.extend(["--name", args.name])
        print("Installing and running native Recents acceptance:", args.device, flush=True)
        with log_path.open("w") as stream:
            process = subprocess.Popen(command, cwd=source, stdout=stream, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 1200
            while process.poll() is None:
                if time.monotonic() > deadline:
                    raise TimeoutError("Native Recents acceptance exceeded its 20 minute bound")
                raw = adb("shell", "run-as", PACKAGE, "cat", STAGE, required=False)
                try:
                    stage = json.loads(raw.stdout)
                except (ValueError, UnicodeDecodeError):
                    time.sleep(.15)
                    continue
                if stage["token"] in seen:
                    time.sleep(.08)
                    continue
                # Launch screenrecord once during the first gesture scenario.
                if stage["name"].endswith(("slide-next", "bot-ripple")) and screenrecord is None:
                    video = f"/sdcard/wing-recents-{stage['name']}.mp4"
                    screenrecord = subprocess.Popen(["adb", "-s", args.device, "shell", "screenrecord",
                                                     "--time-limit", "25", video],
                                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    receipt["video"] = video
                for item in stage["actions"]:
                    action(item, stage["devicePixelRatio"])
                    receipt["nativeActions"] += 1
                if stage["capture"]:
                    screenshot = adb("exec-out", "screencap", "-p")
                    if not screenshot.stdout.startswith(b"\x89PNG"):
                        raise RuntimeError("Android screenshot did not contain PNG bytes")
                    (output / f"{stage['name']}.png").write_bytes(screenshot.stdout)
                (output / f"{stage['name']}.json").write_text(json.dumps(stage, indent=2) + "\n")
                adb("shell", "run-as", PACKAGE, "tee", ACK, data=stage["token"].encode())
                seen.add(stage["token"])
                stages.append(stage)
                print("Native Android checkpoint:", stage["name"], flush=True)
            if process.returncode:
                print(log_path.read_text()[-12000:], flush=True)
                raise RuntimeError(f"Native test failed: {log_path}")
        process = None
        mode = ('events' if args.events_only else 'momentum' if args.momentum_only
                else 'code' if args.code_only else 'standard')
        receipt["completedCases"] = require_completed_cases(stages, name=args.name, mode=mode)
        receipt["result"] = "passed"
        print(log_path.read_text()[-1800:], flush=True)
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            process.wait(timeout=20)
        if screenrecord is not None:
            try:
                screenrecord.wait(timeout=30)
            except subprocess.TimeoutExpired:
                screenrecord.terminate()
                screenrecord.wait(timeout=10)
            adb("pull", receipt["video"], str(output / "native-gestures.mp4"), required=False)
            adb("shell", "rm", "-f", receipt["video"], required=False)
        shell("wm", "size", original_size.split("Override size: ")[-1].strip()
              if "Override size:" in original_size else "reset")
        shell("wm", "density", original_density.split("Override density: ")[-1].strip()
              if "Override density:" in original_density else "reset")
        for key, value in [("font_scale", original_scale), ("screen_off_timeout", original_timeout)]:
            if value == "null":
                shell("settings", "delete", "system", key)
            else:
                shell("settings", "put", "system", key, value)
        adb("shell", "rm", "-f", REMOTE_DEX)
        receipt["checkpoints"] = len(stages)
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()

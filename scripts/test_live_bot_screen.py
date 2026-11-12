#!/usr/bin/env python3
"""Approved live screen acceptance; use an exclusively owned disposable emulator.

Creates one temporary full-screen event recorder on the chosen bot's Linux
desktop. No model calls, server patches, settings changes or existing human
lease eviction. The production Flutter journey owns all lease changes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
from urllib.parse import urlsplit, urlunsplit
import uuid

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "com.tarkilhk.wing.dev"
STAGE = "code_cache/wing-screen-stage.json"
ACK = "code_cache/wing-screen-ack"
LOGIN = "cache/wing-screen-login.json"
MARKER = "Wing screen QA 123"

# Runs in a new terminal, never a shell receiving the test keystrokes. Terminal
# mouse reporting makes clicks/scrolls observable independently of Flutter.
RECORDER = r'''
import curses, json, os, pathlib, sys
events = []
text = ""
target = pathlib.Path(sys.argv[1])
def save():
    temp = target.with_suffix(".new")
    temp.write_text(json.dumps({"text": text, "events": events}))
    temp.replace(target)
def run(screen):
    global text
    curses.curs_set(1)
    curses.mousemask(curses.ALL_MOUSE_EVENTS | curses.REPORT_MOUSE_POSITION)
    curses.mouseinterval(0)
    screen.keypad(True)
    save()
    while True:
        screen.erase()
        screen.addstr(2, 3, "Wing phone screen test - temporary input recorder")
        screen.addstr(4, 3, "Typing here changes only this test window.")
        row = max(6, curses.LINES - 4)
        col = max(3, (curses.COLS - 40) // 2)
        screen.addstr(row, col, "Received: " + repr(text)[1:-1][:35])
        screen.move(row + 1, col + 10)
        screen.refresh()
        key = screen.get_wch()
        if key == curses.KEY_MOUSE:
            _, x, y, _, buttons = curses.getmouse()
            events.append({"mouse": [x, y, buttons]})
        else:
            events.append({"key": key})
            if key in (curses.KEY_BACKSPACE, "\x7f", "\b"):
                text = text[:-1]
            elif isinstance(key, str):
                text += key
        save()
curses.wrapper(run)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--adb-server-port", type=int, default=5039)
    parser.add_argument("--host", required=True, help="SSH user@host")
    parser.add_argument("--profile", required=True)
    parser.add_argument("--url", required=True, help="Final dashboard URL")
    parser.add_argument("--login-file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--hermes-directory", default="/home/tarkil/.hermes/hermes-agent")
    parser.add_argument("--profile-home", required=True)
    args = parser.parse_args()
    os.environ["ANDROID_ADB_SERVER_PORT"] = str(args.adb_server_port)
    os.environ["ADB_SERVER_SOCKET"] = "tcp:127.0.0.1:" + str(args.adb_server_port)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    nonce = uuid.uuid4().hex
    remote = "/tmp/wing-screen-qa-" + nonce
    records = []
    process = None
    forward_port = None
    recorder_created = False
    receipt = {"device": args.device, "profile": args.profile, "result": "incomplete",
               "source_sha256": {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest()
                                 for p in ["lib/core/services/bot_screen_session.dart",
                                           "lib/core/services/bot_display_client.dart",
                                           "lib/core/screens/bots/bot_screen_view.dart",
                                           "lib/core/widgets/bot_display_surface.dart",
                                           "lib/core/widgets/bot_display_viewport.dart",
                                           "lib/core/services/bot_screen_window.dart",
                                           "android/app/src/main/kotlin/com/tarkilhk/wing/BotScreenChannel.kt",
                                           "android/app/src/main/kotlin/com/tarkilhk/wing/MainActivity.kt",
                                           "integration_test/bot_screen_live_test.dart",
                                           "scripts/test_live_bot_screen.py"]}}

    def adb(*cmd, data=None, required=True):
        r = subprocess.run(["adb", "-P", str(args.adb_server_port), "-s", args.device, *cmd], input=data,
                           capture_output=True, timeout=20)
        if required and r.returncode:
            raise RuntimeError("Android operation failed: " + r.stderr.decode(errors="replace"))
        return r.stdout

    def shell(*cmd):
        return adb("shell", *cmd).decode().strip()

    def ssh_python(code):
        command = "python3 -"
        return subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                               args.host, command], input=code.encode(),
                              capture_output=True, check=True, timeout=30).stdout

    def keyboard():
        return bool(re.search(r"type=ime[^\n]*\bvisible=true\b",
                              shell("dumpsys", "window")))

    def recorder():
        return json.loads(ssh_python(
            f"from pathlib import Path\nprint(Path({remote!r}+'/events.json').read_text())"))

    def verify(predicate, reason):
        end = time.monotonic() + 8
        while time.monotonic() < end:
            value = recorder()
            if predicate(value):
                return value
            time.sleep(.15)
        raise AssertionError(reason)

    if not args.device.startswith("emulator-") or shell("getprop", "ro.kernel.qemu") != "1":
        raise ValueError("Use an exclusively owned disposable emulator")
    activity = shell("cmd", "package", "resolve-activity", "--brief", PACKAGE).splitlines()[-1]
    if not activity.startswith(PACKAGE + "/"):
        raise ValueError("Installed Dev package has no launcher activity")
    receipt["activity"] = activity
    login = args.login_file.read_bytes()
    parsed = json.loads(login)
    if not all(isinstance(parsed.get(k), str) and parsed[k] for k in ("username", "password")):
        raise ValueError("Private login file needs username/password")
    try:
        shell("am", "force-stop", PACKAGE)
        adb("shell", "run-as", PACKAGE, "rm", "-f", STAGE, ACK)
        adb("shell", "run-as", PACKAGE, "tee", LOGIN, data=login)
        adb("shell", "run-as", PACKAGE, "chmod", "600", LOGIN)
        build_command = ["flutter", "build", "apk", "--debug", "--no-pub",
                   "--target-platform=android-x64",
                   "--target=integration_test/bot_screen_live_test.dart",
                   "--dart-define=BOT_SCREEN_LIVE=true",
                   "--dart-define=WING_HERMES_URL=" + args.url,
                   "--dart-define=BOT_SCREEN_PROFILE=" + args.profile,
                   "--dart-define=WING_HERMES_LOGIN_FILE=/data/user/0/" + PACKAGE + "/" + LOGIN]
        with (output / "flutter-test.log").open("w") as log:
            subprocess.run(build_command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=180)
            # Explicit in-place install has no uninstall/reinstall fallback.
            adb("install", "-r", str(ROOT / "build/app/outputs/flutter-apk/app-debug.apk"))
            shell("am", "start", "-n", activity)
            vm = None
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                pid = adb("shell", "pidof", PACKAGE, required=False).decode().strip()
                if pid:
                    launch = adb("logcat", "-d", "--pid=" + pid, "-s", "flutter").decode()
                    matches = re.findall(r"The Dart VM service is listening on (http://[^\s]+)", launch)
                    if matches:
                        vm = urlsplit(matches[-1])
                        break
                time.sleep(.2)
            if vm is None:
                raise RuntimeError("Installed test app did not expose its VM service")
            forward_port = adb("forward", "tcp:0", "tcp:" + str(vm.port)).decode().strip()
            vm_url = urlunsplit((vm.scheme, "127.0.0.1:" + forward_port, vm.path, "", ""))
            command = ["flutter", "drive", "--no-pub", "--no-dds", "--keep-app-running",
                       "-d", args.device, "--use-existing-app=" + vm_url,
                       "--driver=test_driver/roadmap_emulator_driver.dart"]
            process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            seen = set()
            end = time.monotonic() + 600
            while process.poll() is None:
                if time.monotonic() > end:
                    raise TimeoutError("Live screen acceptance exceeded ten minutes")
                try:
                    stage = json.loads(adb("shell", "run-as", PACKAGE, "cat", STAGE, required=False))
                except (ValueError, UnicodeDecodeError):
                    time.sleep(.2)
                    continue
                if stage["token"] in seen:
                    time.sleep(.15)
                    continue
                action = stage["action"]
                if action == "prepare":
                    # Run the stock environment resolver, never alter backend
                    # source. Only the uniquely owned terminal receives input.
                    code = f'''import os, pathlib, subprocess, json
p=pathlib.Path({remote!r});p.mkdir(mode=0o700)
(p/'recorder.py').write_text({RECORDER!r})
env={{**os.environ, 'HERMES_HOME': {args.profile_home!r}}}
resolver=[{args.hermes_directory!r}+'/.venv/bin/python', '-c',
          'import json; from tools.bot_desktop.runtime import desktop_env; print(json.dumps(desktop_env()))']
d=json.loads(subprocess.check_output(resolver,env=env,cwd={args.hermes_directory!r}))
env.update(d)
f=(p/'terminal.log').open('w')
child=subprocess.Popen(['xfce4-terminal','--disable-server','--fullscreen',
 '--hide-menubar','--hide-toolbar','--title=Wing screen QA {nonce}',
 '--execute','python3',str(p/'recorder.py'),str(p/'events.json')],
 env=env,stdout=f,stderr=f,start_new_session=True)
(p/'pid').write_text(str(child.pid))
'''
                    ssh_python(code)
                    recorder_created = True
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        try:
                            recorder()
                            break
                        except subprocess.CalledProcessError:
                            time.sleep(.2)
                    else:
                        raise RuntimeError("Owned input recorder failed to open")
                    time.sleep(.8)
                elif action == "tap-screen":
                    mouse_count = sum("mouse" in e for e in recorder()["events"])
                    shell("input", "tap", *(str(p) for p in stage["point"]))
                    verify(lambda v: sum("mouse" in e for e in v["events"]) > mouse_count,
                           "Phone click did not reach the real desktop")
                elif action == "move-click":
                    before = recorder()["events"]
                    x, y = stage["point"]
                    shell("input", "swipe", str(x), str(y), str(x + 150), str(y), "400")
                    shell("input", "tap", str(x + 150), str(y))
                    old = [e["mouse"] for e in before if "mouse" in e]
                    verify(lambda v: any(e.get("mouse", [0, 0, 0])[0] > old[-1][0]
                                         for e in v["events"][len(before):]),
                           "Trackpad movement did not move the real desktop pointer")
                elif action in ("landscape", "portrait"):
                    shell("settings", "put", "system", "accelerometer_rotation", "0")
                    shell("settings", "put", "system", "user_rotation", "1" if action == "landscape" else "0")
                    time.sleep(.6)
                elif action == "back":
                    shell("input", "keyevent", "KEYCODE_BACK")
                    time.sleep(.6)
                elif action == "type":
                    deadline = time.monotonic() + 6
                    while not keyboard() and time.monotonic() < deadline:
                        time.sleep(.1)
                    if not keyboard():
                        raise AssertionError("Android keyboard did not open")
                    shell("input", "text", MARKER.replace(" ", "%s"))
                    verify(lambda v: v["text"] == MARKER,
                           "Android typing did not reach the real desktop exactly")
                elif action == "verify-input":
                    verified = verify(lambda v: v["text"] == MARKER[:-1] + "\t\n",
                                      "Backspace/Tab/Enter did not reach the real desktop")
                    if not any(e.get("mouse", [0, 0, 0])[2] & 2097152 for e in verified["events"]):
                        raise AssertionError("Scroll did not reach the desktop")
                    receipt["remote_input"] = verified
                elif action == "background":
                    shell("input", "keyevent", "KEYCODE_HOME")
                    time.sleep(1)
                elif action == "resume":
                    shell("am", "start", "-n", activity)
                    time.sleep(1)
                elif action not in ("capture", "cleanup"):
                    raise ValueError("Unknown live stage")
                stage["keyboard_visible"] = keyboard()
                (output / (stage["name"] + ".png")).write_bytes(adb("exec-out", "screencap", "-p"))
                records.append(stage)
                (output / "checkpoints.json").write_text(json.dumps(records, indent=2) + "\n")
                adb("shell", "run-as", PACKAGE, "tee", ACK, data=stage["token"].encode())
                seen.add(stage["token"])
                print("Live screen checkpoint:", stage["name"], flush=True)
            if process.returncode:
                raise RuntimeError("Live screen test failed; see " + str(output / "flutter-test.log"))
            if not records or records[-1]["name"] != "complete" or "remote_input" not in receipt:
                raise RuntimeError("Driver exited without completing real input and handback acceptance")
        receipt["result"] = "passed"
    finally:
        if process is not None and process.poll() is None:
            # Allow the bounded Flutter test to run its lease-release finally.
            try:
                process.wait(timeout=100)
            except subprocess.TimeoutExpired:
                receipt["lease_cleanup"] = "Unconfirmed: Flutter did not exit within the cleanup deadline"
                process.terminate()
                process.wait(timeout=20)
        try:
            if recorder_created:
                ssh_python(f'''import os, pathlib, signal, shutil
p=pathlib.Path({remote!r})
pid=int((p/'pid').read_text())
try:
 args=pathlib.Path('/proc/'+str(pid)+'/cmdline').read_bytes()
 if {nonce.encode()!r} in args: os.kill(pid, signal.SIGTERM)
except FileNotFoundError: pass
shutil.rmtree(p)
''')
        except subprocess.SubprocessError:
            receipt["result"] = "cleanup_unconfirmed"
            receipt["window_cleanup"] = "Unconfirmed: SSH cleanup failed"
            raise
        finally:
            adb("shell", "settings", "put", "system", "user_rotation", "0", required=False)
            adb("shell", "run-as", PACKAGE, "rm", "-f", LOGIN, STAGE, ACK, required=False)
            if forward_port is not None:
                adb("forward", "--remove", "tcp:" + forward_port, required=False)
            if receipt["result"] != "passed":
                receipt.setdefault("lease_cleanup", "Unconfirmed: inspect the live test's owned lease before retrying")
            receipt["checkpoints"] = records
            (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()

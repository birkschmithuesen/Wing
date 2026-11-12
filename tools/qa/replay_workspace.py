#!/usr/bin/env python3
"""One explicit future-phone-window replay; never installs or touches production.

Launch a prepared QA build first. Inspect the synthetic screen/SwiftKey geometry
before passing --keyboard-verified. Outputs omit source text, drafts and VM URLs.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import re
import subprocess
import time
from pathlib import Path

from trace_streaming_cpu import rpc, require, sanitize_cpu
from trace_render_system import capture_system, private_output
from wing_perf_client import WingPerfClient

PACKAGE = 'com.tarkilhk.wing.perfqa'
KEYS = [(486,1693),(270,1693),(216,1840),(486,1693),(540,2120)]
KEY_COUNT = 60
KEY_PERIOD = .25


def adb(client, *args):
    result = subprocess.run(client.adb + list(args), capture_output=True, timeout=10)
    require(result.returncode == 0)
    return result.stdout


def guard(client):
    focus = next((s for s in adb(client, 'shell', 'dumpsys', 'window').decode().splitlines()
                  if 'mCurrentFocus=' in s), '')
    require(PACKAGE + '/' in focus)


def keyboard_preflight(client, input_mode):
    guard(client)
    if input_mode == 'emulator':
        require(client.adb[-1].startswith('emulator-'))
        require(adb(client, 'shell', 'getprop', 'ro.kernel.qemu').strip() == b'1')
    else:
        ime = adb(client, 'shell', 'settings', 'get', 'secure', 'default_input_method').decode()
        require('com.touchtype.swiftkey.beta/' in ime)
    # The fixture locates exactly one composer and reports its actual editable
    # state. Android's accessibility root can be null while SwiftKey is visible;
    # use the owning editable and native IME visibility as independent checks.
    ready = rpc(client, 'ext.wingReplay.ready', isolateId=client.isolate)
    require(ready['prepared'] and ready['keyboard'] and ready['composerFocused']
            and ready['draft'] == '')
    native = adb(client, 'shell', 'dumpsys', 'input_method').decode()
    require(re.search(r'\bmInputShown=true\b', native) is not None)


def native_typing(client, input_mode):
    # Exact same letter/space sequence and absolute deadlines in every arm.
    start = time.monotonic_ns()
    achieved = []
    started = []
    for index in range(KEY_COUNT):
        due = start + int((index + 1) * KEY_PERIOD * 1e9)
        time.sleep(max(0, (due - time.monotonic_ns()) / 1e9))
        guard(client)
        started.append((time.monotonic_ns() - start) // 1000)
        if input_mode == 'emulator':
            char = 'test '[index % 5]
            if char == ' ':
                adb(client, 'shell', 'input', 'keyevent', '62')
            else:
                adb(client, 'shell', 'input', 'text', char)
        else:
            x, y = KEYS[index % len(KEYS)]
            adb(client, 'shell', 'input', 'tap', str(x), str(y))
        achieved.append((time.monotonic_ns() - start) // 1000)
    lateness = [t - int((i + 1) * KEY_PERIOD * 1e6) for i, t in enumerate(achieved)]
    return {'inputMode':input_mode, 'keys': len(achieved), 'periodUs': int(KEY_PERIOD * 1e6),
            'hostOriginNs':start, 'keyCommandStartedUs':started, 'achievedUs': achieved, 'maxCompletionLatenessUs': max(lateness),
            'scheduleValid': max(lateness) <= 500000}


def export_replay(report):
    # Strings are authored synthetic content but are still unnecessary exports.
    out = {k:v for k,v in report.items() if k not in ['source','initialSource','draft']}
    for field in ['source','initialSource','draft']:
        value = report[field]
        require(isinstance(value, str))
        out[field + 'Sha256'] = hashlib.sha256(value.encode()).hexdigest()
        out[field + 'Characters'] = len(value)
    out['startMonotonicUs'] = report['startUs']
    out['endMonotonicUs'] = report['endUs']
    out['frameBuildStartUs'] = [f['startUs'] for f in report['frames']]
    out['buildUs'] = [f['buildUs'] for f in report['frames']]
    out['frameRasterStartUs'] = [f['rasterStartUs'] for f in report['frames']]
    out['rasterUs'] = [f['rasterUs'] for f in report['frames']]
    return out


def capture(serial, label, output, processor, input_mode, native_stacks=False, dart_cpu=False):
    require(input_mode in ['swiftkey','emulator'])
    if input_mode == 'emulator':
        require(re.fullmatch(r'emulator-[0-9]+', serial) is not None)
    output = private_output(output)
    with WingPerfClient(serial, PACKAGE) as client:
        prepare = rpc(client, 'ext.wingReplay.prepare', isolateId=client.isolate, timeout=30)
        require(prepare['prepared'] and prepare['keyboard'] and prepare['composerFocused'])
        keyboard_preflight(client, input_mode)
        # Keep VM sampling overhead out of the paired metrics; optional native
        # call stacks come from the same Perfetto setup in both arms.
        original = next(f['valueAsString'] for f in rpc(client, 'getFlagList')['flags']
                        if f['name'] == 'profiler')
        try:
            rpc(client, 'setFlag', name='profiler', value='true' if dart_cpu else 'false')
            def scenario(_):
                host_before = time.monotonic_ns()
                vm_us = rpc(client, 'getVMTimelineMicros')['timestamp']
                host_after = time.monotonic_ns()
                with ThreadPoolExecutor(max_workers=1) as pool:
                    future = pool.submit(rpc, client, 'ext.wingReplay.replay',
                                         isolateId=client.isolate, timeout=45, label=label)
                    native = native_typing(client, input_mode)
                    report = future.result(timeout=35)
                guard(client)
                require(report['valid'] and report['completed'] and report['exactFinalSource']
                        and report['finalRendererReady'] and report['deltaCount'] == 400)
                clean = export_replay(report)
                clean['dartCpuSampling'] = dart_cpu
                clean['nativeInput'] = native
                first_lo = vm_us + (native['hostOriginNs'] + native['keyCommandStartedUs'][0]*1000 - host_after)//1000
                last_hi = vm_us + (native['hostOriginNs'] + native['achievedUs'][-1]*1000 - host_before)//1000
                clean['inputAlignment'] = {'hostVmCalibrationUncertaintyUs':(host_after-host_before)//1000,
                    'firstKeyLowerOffsetUs':first_lo-report['startUs'],
                    'lastKeyUpperOffsetUs':last_hi-report['startUs']}
                draft_correct = report['draft'].lower() == 'test ' * (KEY_COUNT//5)
                cadence_late = max(t-report['startUs']-(i+1)*report['deltaIntervalUs']
                                   for i,t in enumerate(report['deltaAchievedUs']))
                clean['maxDeltaLatenessUs'] = cadence_late
                clean['expectedDraftVerified'] = draft_correct
                clean['comparisonEligible'] = (native['scheduleValid'] and draft_correct
                    and (host_after-host_before)//1000 <= 100000
                    and first_lo >= report['startUs'] and last_hi <= report['streamEndUs']
                    and cadence_late <= 500000)
                (output/'replay.json').write_text(json.dumps(clean, indent=2)+'\n')
                if dart_cpu:
                    cpu = sanitize_cpu(rpc(client, 'getCpuSamples', isolateId=client.isolate,
                        timeOriginMicros=report['startUs'],
                        timeExtentMicros=report['endUs']-report['startUs']),
                        report['startUs'], report['endUs'])
                    (output/'dart-cpu.json').write_text(json.dumps(cpu, indent=2)+'\n')
                return clean
            system = capture_system(client, output, 30, scenario, processor,
                                    native_stacks=native_stacks)
            (output/'system-summary.json').write_text(json.dumps(system, indent=2)+'\n')
            print(json.dumps({'status':'captured', 'label':label,
                              'keys':KEY_COUNT, 'sourceExported':False}))
        finally:
            rpc(client, 'setFlag', name='profiler', value=original)
            restored = next(f['valueAsString'] for f in rpc(client, 'getFlagList')['flags']
                            if f['name'] == 'profiler')
            require(restored == original)
            (output/'vm-profiler-restored.json').write_text('{"restored":true}\n')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--serial', required=True)
    p.add_argument('--label', required=True, choices=['control-1','fixed-1','fixed-2','control-2'])
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--trace-processor', type=Path, required=True)
    p.add_argument('--keyboard-verified', action='store_true')
    p.add_argument('--input-mode', required=True, choices=['swiftkey','emulator'])
    p.add_argument('--native-stacks', action='store_true')
    p.add_argument('--dart-cpu', action='store_true', help='Separate diagnostic run; adds sampling overhead')
    a = p.parse_args()
    try:
        require(a.input_mode == 'emulator' or a.keyboard_verified)
        capture(a.serial, a.label, a.output, a.trace_processor, a.input_mode, a.native_stacks, a.dart_cpu)
    except Exception:
        # Never display device responses, exception payloads or VM-service URLs.
        print(json.dumps({'status':'incomplete','reason':'Replay or trace validation failed; inspect numeric local records.'}))
        raise SystemExit(1) from None


if __name__ == '__main__':
    main()

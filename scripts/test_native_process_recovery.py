#!/usr/bin/env python3
"""Prove durable outbox recovery across Android force-stop on an owned emulator."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.test import fingerprint, stop_process_group  # noqa: E402
from tools.qa import run_notification_gate as android  # noqa: E402

PACKAGE = 'com.tarkilhk.wing.notificationqa'
TARGET = 'integration_test/outbox_process_recovery_native_test.dart'
STAGE = 'code_cache/wing-process-recovery.json'


def validate_checkpoints(records: list[dict], run_id: str) -> None:
    """A first-phase marker, a stale file or owner recreation is never success."""
    if not isinstance(records, list) or len(records) != 2 or any(not isinstance(r, dict) for r in records):
        raise ValueError('Recovery requires two structured checkpoints')
    if [r.get('phase') for r in records] != ['ready_for_stop', 'restored']:
        raise ValueError('Recovery requires exactly the stop and restored checkpoints, in order')
    if not run_id or any(r.get('run_id') != run_id for r in records):
        raise ValueError('Recovery checkpoint belongs to another run')
    pids = [r.get('pid') for r in records]
    if any(type(pid) is not int or pid <= 0 for pid in pids) or pids[0] == pids[1]:
        raise ValueError('Recovery must execute in two distinct Android processes')
    if any(type(r.get(key)) is not int for r in records for key in ('submissions', 'uploads')):
        raise ValueError('Recovery submission and upload counts must be integers')
    if records[0].get('submissions') != 1 or records[0].get('uploads') != 1:
        raise ValueError('Original process did not submit the attachment exactly once')
    if records[1].get('submissions') != 1 or records[1].get('uploads') != 0:
        raise ValueError('Relaunch must recover one exact submission without reuploading')
    for record in records:
        if type(record.get('server_admission_count')) is not int or record['server_admission_count'] != 1:
            raise ValueError('Recovery must retain exactly one remote admission')
        for key in ('submission_id', 'admission_id'):
            if not isinstance(record.get(key), str) or not record[key]:
                raise ValueError('Recovery must identify its exact submission and admission')
        wire = record.get('wire_payload')
        if (not isinstance(wire, dict) or wire.get('submission_id') != record['submission_id']
                or not all(isinstance(wire.get(key), str) and wire[key] for key in ('session_id', 'profile', 'text'))):
            raise ValueError('Recovery requires the original scoped wire payload')
    if any(records[0][key] != records[1][key] for key in ('submission_id', 'admission_id', 'wire_payload')):
        raise ValueError('Recovery changed submission identity, accepted receipt or wire payload')
    if any(records[1].get(key) is not True for key in
           ('draft_restored', 'attachment_restored', 'outbox_paused', 'receipt_reconciled')):
        raise ValueError('Relaunch did not restore all user work')


def run(device: str, output: Path) -> dict:
    """Build/run both phases on the caller's disposable emulator; save a receipt."""
    android.require_emulator(device)
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    run_id = uuid.uuid4().hex
    before = fingerprint()
    receipt = {'passed': False, 'run_id': run_id, 'device': device,
               'source_before': before, 'checkpoints': [], 'no_live_server': True}

    def shell(*arguments):
        return android.device(device, 'shell', *arguments)

    def read_stage():
        result = subprocess.run([android.adb_path(), '-s', device, 'shell', 'run-as',
                                 PACKAGE, 'cat', STAGE], capture_output=True, timeout=25)
        try:
            value = json.loads(result.stdout)
            return value if isinstance(value, dict) else {}
        except ValueError:
            return {}

    def await_stage(phase):
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            stage = read_stage()
            if stage.get('run_id') == run_id:
                if stage.get('phase') == phase:
                    return stage
                if stage.get('phase') != 'ready_for_stop':
                    raise RuntimeError(f'Unexpected recovery phase: {stage.get("phase")}')
            time.sleep(.2)
        raise TimeoutError(f'Android did not reach {phase}; see device.log')

    def launch():
        shell('am', 'start', '-W', '-n', PACKAGE + '/com.tarkilhk.wing.MainActivity')

    try:
        command = ['flutter', 'build', 'apk', '--debug', '--no-pub',
                   '--target-platform', 'android-x64', '-t', TARGET,
                   '--dart-define=PROCESS_RECOVERY_RUN_ID=' + run_id]
        receipt['build_command'] = command
        with (output / 'build.log').open('w') as log:
            process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True,
                                       env={**os.environ, 'ORG_GRADLE_PROJECT_notificationQa': 'true'})
            try:
                if process.wait(timeout=900) != 0:
                    raise RuntimeError('Recovery APK build failed; see build.log')
            finally:
                stop_process_group(process)
        apk = ROOT / 'build/app/outputs/flutter-apk/app-debug.apk'
        subprocess.run([android.adb_path(), '-s', device, 'install', '--no-incremental',
                        '-r', '-g', str(apk)], check=True, capture_output=True, timeout=120)
        shell('am', 'force-stop', PACKAGE)
        shell('run-as', PACKAGE, 'rm', '-f', STAGE)
        shell('input', 'keyevent', 'KEYCODE_WAKEUP')
        shell('wm', 'dismiss-keyguard')
        launch()
        initial = await_stage('ready_for_stop')
        first_pid = shell('pidof', PACKAGE)
        if first_pid != str(initial.get('pid')):
            raise RuntimeError('Checkpoint did not come from the running Android process')
        receipt['checkpoints'].append(initial)
        shell('am', 'force-stop', PACKAGE)
        # pidof exits 1 when absent, so inspect the process result explicitly.
        stopped = subprocess.run([android.adb_path(), '-s', device, 'shell', 'pidof', PACKAGE],
                                 capture_output=True, timeout=25)
        if stopped.returncode != 1 or stopped.stdout.strip():
            raise RuntimeError('Android process remained alive after force-stop')
        receipt['original_process_stopped'] = True
        launch()
        restored = await_stage('restored')
        if shell('pidof', PACKAGE) != str(restored.get('pid')):
            raise RuntimeError('Restoration checkpoint did not come from the relaunched process')
        receipt['checkpoints'].append(restored)
        validate_checkpoints(receipt['checkpoints'], run_id)
        receipt['passed'] = True
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        receipt['error'] = str(error)
    finally:
        try:
            (output / 'device.log').write_text(android.device(
                device, 'logcat', '-d', '-s', 'flutter:V', 'AndroidRuntime:E'))
            shell('am', 'force-stop', PACKAGE)
        except (OSError, subprocess.SubprocessError) as error:
            receipt.update(passed=False, cleanup_error=str(error))
        receipt['source_after'] = fingerprint()
        if receipt['source_after'] != before:
            receipt.update(passed=False, source_changed=True)
        (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/process-recovery')
    args = parser.parse_args()
    result = run(args.device, args.output)
    print(json.dumps(result, indent=2))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

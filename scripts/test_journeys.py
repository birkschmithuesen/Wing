#!/usr/bin/env python3
"""Run mandatory, deterministic Android journeys on a disposable emulator.

Without --device, create and retire an isolated API 36 AVD. Uses injected gateway
responses, real Android storage and production controls; never contacts Hermes.
The required final journey force-stops Android and restores the durable outbox.
"""
from __future__ import annotations

import argparse
from contextlib import ExitStack, contextmanager, nullcontext
import json
import os
import re
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.qa import run_notification_gate as android  # noqa: E402
from scripts.test import fingerprint, stop_process_group  # noqa: E402
from scripts import test_native_process_recovery as process_recovery  # noqa: E402

CRITICAL = frozenset({
    'dark setup recovers and saves verified connection',
    'light setup recovers and saves verified connection',
    'setup saves credentials in Android secure storage and reopens them',
    'uncertain Send survives owner recreation beside a newer draft',
})
ROADMAP = frozenset({
    'native clarification answers from the composer with its captured generation',
    'Git review opens from chat and retains draft through held reads',
    'live tool progress and plan recovery use the production conversation',
    'drawer settings profiles chats and projects work at large text',
    'draft model slash find outputs and context use the production chat',
    'a missing staged file restores as removable without sending',
    'activity approvals and queued work keep their chat owner',
    'project discovery review delivery and input jump stay native',
    'subagents goals and background work keep their chat owner',
    'completed child stays in current work while the parent streams',
    'administration checks edits and update refusal stay scoped',
    'saved answers edit regenerate branch and fork through Hermes',
})
SUITES = (
    ('critical', 'integration_test/critical_journeys_test.dart', CRITICAL),
    ('roadmap', 'integration_test/roadmap_emulator_test.dart', ROADMAP),
)


def verdict(lines: list[str], returncode: int, expected: frozenset[str]) -> dict:
    """Only completed, non-skipped named journeys constitute acceptance."""
    names = {}
    completed = []
    skipped = []
    failures = []
    done = False
    summaries = 0
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            continue  # Flutter build/install diagnostics are not test events.
        if not isinstance(event, dict):
            continue
        kind = event.get('type')
        if kind == 'testStart':
            names[event['test']['id']] = event['test']['name']
        elif kind == 'testDone' and not event.get('hidden'):
            name = names.get(event.get('testID'), '<unregistered test>')
            if event.get('skipped'):
                skipped.append(name)
            elif event.get('result') == 'success':
                completed.append(name)
            else:
                failures.append(name)
        elif kind == 'error':
            failures.append(names.get(event.get('testID'), '<test loading>'))
        elif kind == 'done':
            summaries += 1
            done = event.get('success') is True
    missing = sorted(expected.difference(completed))
    unexpected = sorted(set(completed).difference(expected))
    duplicates = sorted(name for name in expected if completed.count(name) > 1)
    passed = (bool(expected) and returncode == 0 and summaries == 1 and done
              and not (missing or unexpected or duplicates or skipped or failures))
    return {'passed': passed, 'completed': completed, 'skipped': skipped,
            'failed': failures, 'missing': missing, 'unexpected': unexpected, 'duplicates': duplicates,
            'process_exit': returncode, 'test_run_completed': done, 'summary_count': summaries}



@contextmanager
def completed_onboarding(device: str, evidence: dict):
    """Scope established permission/battery prerequisites to the owned QA app."""
    package = 'com.tarkilhk.wing.notificationqa'
    def shell(*args):
        return android.device(device, 'shell', *args)
    if not shell('pm', 'path', package).strip().startswith('package:'):
        raise RuntimeError('Critical journey did not leave the owned QA package installed')
    state = shell('dumpsys', 'package', package)
    permissions = {
        permission: bool(re.search(re.escape(permission) + r': granted=true', state))
        for permission in ('android.permission.POST_NOTIFICATIONS', 'android.permission.RECORD_AUDIO')
    }
    exempt = package in shell('dumpsys', 'deviceidle', 'whitelist')
    evidence.update(package=package, permissions_before=permissions, battery_exempt_before=exempt,
                    scope='completed onboarding; permission prompts and default battery policy are separate acceptance')
    with ExitStack() as cleanup:
        if not exempt:
            cleanup.callback(shell, 'dumpsys', 'deviceidle', 'whitelist', '-' + package)
            shell('dumpsys', 'deviceidle', 'whitelist', '+' + package)
        for permission, granted in permissions.items():
            if not granted:
                cleanup.callback(shell, 'pm', 'revoke', package, permission)
                shell('pm', 'grant', package, permission)
        cleanup.callback(shell, 'am', 'force-stop', package)
        shell('am', 'force-stop', package)
        yield
    evidence['restored'] = True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', help='Reuse a disposable emulator; physical devices are rejected')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/android-journeys')
    parser.add_argument('--capture-frames', action='store_true',
                        help='Export production Flutter frames from journey capture points before retiring the emulator')
    args = parser.parse_args()
    os.chdir(ROOT)
    if args.device and not args.device.startswith('emulator-'):
        parser.error('Android journeys require a disposable emulator')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    android.OUTPUT = output
    before = fingerprint()
    result = {'passed': False, 'source_before': before, 'suites': {}}
    try:
        with nullcontext(args.device) if args.device else android.owned_emulator() as device:
            android.require_emulator(device)
            android.device(device, 'shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
            android.device(device, 'shell', 'wm', 'dismiss-keyguard')
            result['device'] = device
            for name, target, expected in SUITES:
                command = ['flutter', 'test', '--no-pub', '--no-uninstall', '-d', device,
                           '--reporter=json', target]
                if args.capture_frames:
                    command.append('--dart-define=CAPTURE_JOURNEYS=true')
                suite = result['suites'][name] = {'passed': False, 'command': command}
                log_path = output / f'{name}.jsonl'
                setup = completed_onboarding(device, suite.setdefault('onboarding', {})) if name == 'roadmap' else nullcontext()
                with setup, log_path.open('w') as log:
                    process = subprocess.Popen(command, cwd=ROOT, stdout=log,
                                               stderr=subprocess.STDOUT, start_new_session=True,
                                               env={**os.environ,
                                                    'ORG_GRADLE_PROJECT_notificationQa': 'true',
                                                    'ORG_GRADLE_PROJECT_performanceQa': 'false',
                                                    'ORG_GRADLE_PROJECT_nativeShareQa': 'false',
                                                    'ORG_GRADLE_PROJECT_wingDevelopment': 'false'})
                    try:
                        code = process.wait(timeout=900)
                        log.flush()
                        suite.update(verdict(log_path.read_text().splitlines(), code, expected))
                    except (OSError, subprocess.SubprocessError) as error:
                        suite['error'] = str(error)
                        raise
                    finally:
                        # Capture before force-stop/onboarding cleanup and AVD retirement.
                        try:
                            if not suite['passed']:
                                android.capture_failure(device, output / (name + '-failure'))
                        except Exception as error:
                            suite.setdefault('capture_errors', []).append(str(error))
                        finally:
                            stop_process_group(process)
                    captures = output / (name + '-frames')
                    suite['frames'] = []
                    for path in sorted(set(re.findall(r'Journey frame: ([^"\\\s]+\.png)', log_path.read_text()))):
                        captures.mkdir(exist_ok=True)
                        destination = captures / Path(path).name
                        try:
                            with destination.open('wb') as frame:
                                subprocess.run([android.adb_path(), '-s', device, 'exec-out',
                                                'run-as', 'com.tarkilhk.wing.notificationqa', 'cat', path],
                                               stdout=frame, check=True, timeout=25)
                            suite['frames'].append(str(destination))
                        except (OSError, subprocess.SubprocessError) as error:
                            suite.setdefault('capture_errors', []).append(str(error))
                            suite['passed'] = False
                if not suite['passed']:
                    break
            else:
                result['process_recovery'] = process_recovery.run(device, output / 'process-recovery')
                result['passed'] = result['process_recovery'].get('passed') is True
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        result.update(passed=False, error=str(error))
    finally:
        result['source_after'] = fingerprint()
        if result['source_after'] != before:
            result.update(passed=False, source_changed=True)
        (output / 'receipt.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    if not result['passed']:
        for log in output.glob('*.jsonl'):
            print(f'{log.name}:\n{log.read_text()[-16000:]}', file=sys.stderr)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

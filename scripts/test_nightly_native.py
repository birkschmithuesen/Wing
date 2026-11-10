#!/usr/bin/env python3
"""Run one nightly Android family on an owned, disposable API 36 emulator.

Each matrix entry runs regardless of failures in other families. Existing native
drivers own behavioral verdicts; direct Flutter suites require exact test names.
No physical device, existing backend or production package is accepted.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.test import fingerprint, stop_process_group  # noqa: E402
from scripts.test_journeys import verdict  # noqa: E402
from scripts.test_vanilla_hermes import cleanup_signals  # noqa: E402
from scripts.test_native_bots import input_view_visible  # noqa: E402
from tools.qa import run_notification_gate as android  # noqa: E402
from scripts.native_impact import FAMILIES, plan as impact_plan  # noqa: E402

DEV = 'com.tarkilhk.wing.dev'
QA = 'com.tarkilhk.wing.notificationqa'
ADB_INPUT_TIMEOUT_EXIT = 75
CLIPBOARD_DEFINES = ('--dart-define=HERMES_CLIPBOARD_DEVICE_TEST=true',)
SLASH_DEFINES = ('--dart-define=SLASH_NATIVE_INPUT=true',)
DIRECT_SUITES = {
    'dependency_plugins_native_test.dart': frozenset({
        'native package metadata and app storage remain available',
        'native notifications preserve content and cancel only their ID',
    }),
    'scheduled_tasks_native_test.dart': frozenset({
        'Android task creation, keyboard, anchored menu and back navigation',
    }),
    'administration_native_test.dart': frozenset({
        'Android runtime findings survive reviewing the same operation',
        'Android editors: keyboard, conflict, accessibility action and discard',
        'Android full-screen Identity retains long draft on back',
        'Android provider ownership and separate capability actions at large text',
        'Connected apps retain named-account drafts through held failure and retry',
        'Subagent route and prepared compression save through production controls',
        'Conversation connection requests retain owner through pending failure and retry',
    }),
    'queued_message_edit_test.dart': frozenset({
        'long press opens the native keyboard; Queue restores text and files',
        'Cancel restores the draft and discards only the queue edit',
        'red cross asks before deleting just the selected instruction',
        'Steer waits for acknowledgement, sends once and restores the draft',
        'rejected and failed canonical steering preserve the admitted instruction',
        'server claim retires an outdated edit without resubmission',
        'unaccepted attachment draft survives editing at large text with the keyboard',
    }),
}


def registered_names(lines):
    """Enumerate loaded wrapper suites without copying their host test catalog."""
    names, hidden = {}, set()
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get('type') == 'testStart':
            names[event['test']['id']] = event['test']['name']
        elif event.get('type') == 'testDone' and event.get('hidden'):
            hidden.add(event['testID'])
    return frozenset(name for identity, name in names.items() if identity not in hidden)


class Runner:
    def __init__(self, output: Path):
        self.output = output
        self.device = None
        self.prepared = None
        self.steps = []
        self.input_timeout_at = None
        self.environment = dict(os.environ)
        self.environment.update({
            'ORG_GRADLE_PROJECT_notificationQa': 'false',
            'ORG_GRADLE_PROJECT_nativeShareQa': 'false',
            'ORG_GRADLE_PROJECT_performanceQa': 'false',
            'ORG_GRADLE_PROJECT_wingDevelopment': 'false',
        })

    def run(self, name, command, *, expected=None, checkpoint=None, timeout=1200):
        log_path = self.output / (name + '.log')
        step = {'name': name, 'command': list(map(str, command)), 'passed': False}
        self.steps.append(step)
        print('START ' + name, flush=True)
        with log_path.open('w') as log:
            child = subprocess.Popen(command, cwd=ROOT, env=self.environment,
                                     stdout=log, stderr=subprocess.STDOUT,
                                     start_new_session=True)
            try:
                deadline = time.monotonic() + timeout
                while child.poll() is None:
                    if time.monotonic() >= deadline:
                        raise TimeoutError(name + ' exceeded its execution deadline')
                    if checkpoint:
                        checkpoint()
                    time.sleep(.25)
                step['exit_code'] = child.returncode
            finally:
                stop_process_group(child)
        if expected is not None:
            lines = log_path.read_text().splitlines()
            if expected == 'registered':
                expected = registered_names(lines)
            step.update(verdict(lines, child.returncode, expected))
        else:
            step['passed'] = child.returncode == 0
        if not step['passed']:
            print(log_path.read_text()[-16000:], file=sys.stderr)
            raise RuntimeError(name + ' failed; see ' + str(log_path))
        print('PASS ' + name, flush=True)

    def adb(self, *parts):
        return android.device(self.device, *parts)

    def shell(self, *parts):
        return self.adb('shell', *parts)

    def capture_failure(self):
        return android.capture_failure(self.device, self.output)

    def build(self, target, *, qa=False, defines=()):
        self.environment['ORG_GRADLE_PROJECT_notificationQa'] = str(qa).lower()
        key = (target, qa, tuple(defines), self.environment['ORG_GRADLE_PROJECT_nativeShareQa'])
        if self.prepared == key:
            return
        self.run('build-' + Path(target).stem, [
            'flutter', 'build', 'apk', '--debug', '--no-pub',
            '--target-platform', 'android-x64', '-t', target, *defines,
        ])
        self.prepared = key

    def install(self, target, *, qa=False, defines=()):
        self.build(target, qa=qa, defines=defines)
        self.run('install-' + Path(target).stem, [
            android.adb_path(), '-s', self.device, 'install', '--no-incremental',
            '-r', '-g', str(ROOT / 'build/app/outputs/flutter-apk/app-debug.apk'),
        ], timeout=180)

    def launch(self, package):
        self.shell('am', 'force-stop', package)
        self.shell('am', 'start', '-W', '-n', package + '/com.tarkilhk.wing.MainActivity')

    def flutter(self, target, expected, *, defines=(), checkpoint=None):
        self.run(Path(target).stem, [
            'flutter', 'test', '--no-pub', '--no-uninstall', '-d', self.device,
            '--reporter=json', 'integration_test/' + target, *defines,
        ], expected=expected, checkpoint=checkpoint)

    @contextmanager
    def forward(self, remote):
        port = self.adb('forward', 'tcp:0', remote)
        try:
            yield port
        finally:
            self.adb('forward', '--remove', 'tcp:' + port)

    def driver(self, script, *args):
        # Let legacy driver finally blocks retire their own Flutter process groups
        # when the outer deadline/cancellation sends SIGTERM.
        trampoline = (
            'import os,runpy,signal,subprocess,sys,traceback\n'
            'def stop(signum, frame): raise KeyboardInterrupt("Nightly cancelled")\n'
            'signal.signal(signal.SIGTERM, stop)\n'
            'serial = sys.argv[1]\n'
            'sys.argv = sys.argv[2:]\n'
            'try:\n'
            '    runpy.run_path(sys.argv[0], run_name="__main__")\n'
            'except subprocess.TimeoutExpired as error:\n'
            '    cmd = error.cmd\n'
            '    if (isinstance(cmd, (tuple, list)) and len(cmd) > 5\n'
            '            and os.path.basename(cmd[0]) == "adb"\n'
            '            and list(cmd[1:5]) == ["-s", serial, "shell", "input"]):\n'
            '        traceback.print_exc()\n'
            f'        sys.exit({ADB_INPUT_TIMEOUT_EXIT})\n'
            '    raise\n'
        )
        try:
            self.run(Path(script).stem, [sys.executable, '-c', trampoline,
                                       str(self.device), script, *map(str, args)], timeout=3000)
        except RuntimeError:
            if self.steps[-1].get('exit_code') == ADB_INPUT_TIMEOUT_EXIT:
                self.input_timeout_at = time.time()
            raise

    def wait_fixture(self, port):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen('http://127.0.0.1:' + port + '/', timeout=2) as response:
                    if json.load(response).get('ready') is True:
                        return
            except (OSError, ValueError):
                pass
            time.sleep(.25)
        raise TimeoutError('Notification fixture did not become ready')

    def family(self, family, hermes_source=None):
        if family not in FAMILIES:
            raise ValueError('Unknown nightly family: ' + family)
        if family == 'journeys':
            self.driver('scripts/test_journeys.py', '--device', self.device,
                        '--output', self.output / 'journeys')
        elif family == 'stock-hermes':
            if hermes_source is None:
                raise ValueError('stock-hermes requires --hermes-source with prepared current stock dependencies')
            self.driver('scripts/test_vanilla_hermes.py', '--hermes-source', hermes_source,
                        '--output', self.output / 'stock')
        elif family in ('notification-actions', 'notification-restore',
                        'notification-counts', 'notification-cold'):
            target = ('notification_cold_input_device.dart' if family == 'notification-cold'
                      else 'notification_revamp_device.dart')
            self.install('integration_test/' + target, qa=True)
            if family == 'notification-actions':
                self.driver('tools/qa/check_notification_revamp.py', '--serial', self.device,
                            '--output', self.output / 'actions')
            elif family == 'notification-counts':
                self.shell('dumpsys', 'deviceidle', 'whitelist', '+' + QA)
                self.launch(QA)
                with self.forward('tcp:18766') as port:
                    self.wait_fixture(port)
                    self.driver('scripts/test_native_notification_counts.py',
                                '--serial', self.device, '--port', port)
            else:
                if family == 'notification-cold':
                    # Onboarding reads this permission at startup. Granting it
                    # after launch cannot establish the monitoring prerequisite.
                    self.shell('dumpsys', 'deviceidle', 'whitelist', '+' + QA)
                    self.launch(QA)
                script = ('test_native_cold_notification.py' if family == 'notification-cold'
                          else 'test_native_notification_restore.py')
                self.driver('scripts/' + script, '--serial', self.device)
        elif family == 'background':
            self.install('integration_test/background_monitoring_device.dart')
            self.driver('tools/qa/check_background_monitoring.py', '--serial', self.device,
                        '--output', self.output / 'background')
        elif family == 'external-share':
            self.environment['ORG_GRADLE_PROJECT_nativeShareQa'] = 'true'
            self.install('integration_test/share_intake_device.dart', qa=True,
                         defines=['--dart-define=WING_NATIVE_SHARE_QA=true'])
            self.launch(QA)
            self.driver('tools/qa/check_external_share.py', '--serial', self.device,
                        '--provider-faults', '--output', self.output / 'external-share')
        elif family in ('health-normal', 'health-large', 'health-retention'):
            large = family == 'health-large'
            retention = family == 'health-retention'
            defines = ['--dart-define=ALERT_RETENTION_NATIVE=true'] if retention else [
                '--dart-define=ALERT_EXPECT_LARGE=' + str(large).lower()]
            self.install('integration_test/health_alerts_native_test.dart', qa=True, defines=defines)
            if large:
                self.shell('wm', 'density', '420')
                self.shell('wm', 'size', '840x2215')
            self.shell('settings', 'put', 'system', 'font_scale', '2.0' if large else '1.0')
            self.shell('dumpsys', 'deviceidle', 'whitelist', '+' + QA)
            expected = frozenset({'Android health threshold retention through real Home and reopen'}) if retention else frozenset(
                f'Android health alerts {theme}, large={str(large).lower()}'
                for theme in ('dark', 'light'))
            self.flutter('health_alerts_native_test.dart', expected, defines=defines,
                         checkpoint=self.retention_checkpoint() if retention else None)
        elif family == 'html':
            self.html()
        elif family == 'clipboard':
            self.install('integration_test/clipboard_device_test.dart', defines=CLIPBOARD_DEFINES)
            self.clipboard()
        elif family == 'queue-editing':
            target = 'queued_message_edit_test.dart'
            self.install('integration_test/' + target)
            self.flutter(target, DIRECT_SUITES[target])
        elif family == 'slash':
            self.install('integration_test/slash_completion_native_test.dart', defines=SLASH_DEFINES)
            self.slash()
        else:
            # Drivers using --no-uninstall require a dev package on the fresh AVD.
            self.install('integration_test/file_transfer_native_test.dart')
            direct = {'platform-plugins': 'dependency_plugins_native_test.dart',
                      'scheduled-tasks': 'scheduled_tasks_native_test.dart',
                      'administration': 'administration_native_test.dart'}
            if family in direct:
                target = direct[family]
                if family == 'administration':
                    self.administration()
                else:
                    self.flutter(target, DIRECT_SUITES[target])
            elif family in ('health-entry', 'transcript-expansion'):
                # These entrypoints reuse complete host suites; all registered
                # cases must finish, with no errors, skips or empty verdict.
                target = ('administration_health_entry_test.dart' if family == 'health-entry'
                          else 'profile_expansion_scroll_test.dart')
                self.flutter(target, expected='registered')
            else:
                script = {'backup': 'config_backup', 'bots': 'bots',
                          'file-transfer': 'file_transfer', 'voice': 'voice',
                          'recents': 'recents', 'recents-code': 'recents',
                          'recents-events': 'recents', 'recents-momentum': 'recents'}[family]
                extra = ['--' + family.removeprefix('recents-') + '-only'] if family.startswith('recents-') else []
                self.driver('scripts/test_native_' + script + '.py', '--device', self.device,
                            '--output', self.output / family, *extra)

    def clipboard(self):
        helper = 'com.tarkilhk.wing.shareqa.fixture'
        output = self.output / 'clipboard-fixture'
        self.run('build-clipboard-fixture', [sys.executable, '-c',
            'import os,sys; from pathlib import Path; '
            'from tools.qa.check_external_share import build_helper; '
            'build_helper(Path(os.environ["ANDROID_HOME"]), Path(os.environ["JAVA_HOME"]), Path(sys.argv[1]))',
            str(output)])
        self.run('install-clipboard-fixture', [android.adb_path(), '-s', self.device,
            'install', '--no-incremental', str(output / 'external-share-fixture.apk')])
        try:
            self.shell('am', 'start', '-W', '-n', helper + '/.ClipboardSenderActivity')
            self.flutter('clipboard_device_test.dart', frozenset({
                'synthetic image clip crosses Android clipboard with exact pixels',
                'long-press Paste stages an image beside a picked-image thumbnail',
            }), defines=CLIPBOARD_DEFINES)
        finally:
            try:
                for name, command in {
                    'clipboard-logcat.txt': ('logcat', '-d', '-t', '3000'),
                    'clipboard-window.txt': ('shell', 'dumpsys', 'window'),
                    'clipboard-service.txt': ('shell', 'dumpsys', 'clipboard'),
                }.items():
                    (self.output / name).write_text(self.adb(*command))
            finally:
                self.adb('uninstall', helper)

    def read_checkpoint(self, package, path):
        result = subprocess.run([
            android.adb_path(), '-s', self.device, 'shell', 'run-as', package,
            'cat', path,
        ], capture_output=True, text=True, timeout=25)
        if result.returncode:
            return None
        try:
            stage = json.loads(result.stdout)
        except json.JSONDecodeError:
            # Dart can be between truncation and completion of writeAsString.
            # The existing fixture/child deadlines still bound missing records.
            return None
        if not isinstance(stage, dict):
            raise ValueError('Native checkpoint must be a JSON object')
        return stage

    def administration(self):
        seen = set()
        captures = set()
        expected = {
            f'{surface}-{theme}-{scale}{state}'
            for theme in ('dark', 'light') for scale in ('1.0', '2.0')
            for surface, states in (
                ('hosted-account', ('-keyboard', '-pending', '-failed')),
                ('delegation', ('-keyboard', '-pending')),
                ('prepared-compression', ('',)),
                ('connection-request', ('-request', '-pending', '-failed')),
            ) for state in states
        }

        def checkpoint():
            stage = self.read_checkpoint(DEV, 'code_cache/wing-administration-stage.json')
            if stage is None or stage['token'] in seen:
                return
            token, name = stage['token'], stage['name']
            if name not in expected:
                raise ValueError('Unknown administration checkpoint: ' + name)
            keyboard = self.shell('dumpsys', 'input_method')
            (self.output / (name + '-input-method.txt')).write_text(keyboard)
            if stage.get('keyboard') is True and not input_view_visible(keyboard):
                raise RuntimeError('Administration checkpoint requires a visible keyboard: ' + name)
            with (self.output / (name + '.png')).open('wb') as capture:
                subprocess.run([android.adb_path(), '-s', self.device, 'exec-out',
                                'screencap', '-p'], stdout=capture, check=True, timeout=25)
            subprocess.run([android.adb_path(), '-s', self.device, 'shell', 'run-as', DEV,
                            'sh', '-c', '"cat > code_cache/wing-administration-ack"'],
                           input=token, text=True, check=True, timeout=25)
            seen.add(token)
            captures.add(name)

        self.flutter('administration_native_test.dart', DIRECT_SUITES['administration_native_test.dart'],
                     defines=('--dart-define=ADMINISTRATION_NATIVE_CAPTURE=true',), checkpoint=checkpoint)
        if captures != expected:
            raise RuntimeError('Missing administration captures: ' + ', '.join(sorted(expected - captures)))

    def slash(self):
        seen = set()

        def checkpoint():
            stage = self.read_checkpoint(DEV, 'code_cache/wing-slash-stage.json')
            if stage is None:
                return
            token, name = stage['token'], stage['name']
            if token in seen:
                return
            if name.endswith('-configure'):
                self.shell('wm', 'density', '420')
                self.shell('wm', 'size', '840x2215' if '-2.0-' in name else '1024x2215')
                self.shell('settings', 'put', 'system', 'font_scale', '2.0' if '-2.0-' in name else '1.0')
                self.shell('cmd', 'uimode', 'night', 'yes' if name.startswith('dark-') else 'no')
                self.shell('wm', 'dismiss-keyguard')
                time.sleep(.8)
            elif name.endswith('-type-inline'):
                self.shell('input', 'text', 'Please%suse%s/a-')
            elif name.endswith('-type-suffix'):
                self.shell('input', 'text', 'for%sthis%stask')
            elif name.endswith('-type-post-compression'):
                self.shell('input', 'text', 'Keep%sthis%snewer%sdraft')
            elif name.endswith('-backspace'):
                self.shell('input', 'keyevent', 'KEYCODE_DEL')
            elif not name.endswith(('-picker-ready', '-selected', '-suffix-ready', '-post-compression-ready')):
                raise ValueError('Unknown slash native checkpoint: ' + name)
            if name.endswith(('-picker-ready', '-selected', '-suffix-ready', '-post-compression-ready')):
                keyboard = self.shell('dumpsys', 'input_method')
                (self.output / (name + '-input-method.txt')).write_text(keyboard)
                if not input_view_visible(keyboard):
                    raise RuntimeError('Slash checkpoint requires a visible Android keyboard: ' + name)
            with (self.output / (name + '.png')).open('wb') as capture:
                subprocess.run([android.adb_path(), '-s', self.device, 'exec-out',
                                'screencap', '-p'], stdout=capture, check=True, timeout=25)
            # Token is generated by the fixture; stdin avoids shell interpolation.
            subprocess.run([android.adb_path(), '-s', self.device, 'shell', 'run-as', DEV,
                            'sh', '-c', '"cat > code_cache/wing-slash-ack"'],
                           input=token, text=True, check=True, timeout=25)
            seen.add(token)

        self.flutter('slash_completion_native_test.dart', frozenset(
            f'/app selection {theme} {scale}' for theme in ('dark', 'light')
            for scale in ('1.0', '2.0')), defines=SLASH_DEFINES,
            checkpoint=checkpoint)

    def retention_checkpoint(self):
        seen = set()

        def checkpoint():
            stage = self.read_checkpoint(QA, 'code_cache/wing-health-retention-stage.json')
            if stage is None:
                return
            token = stage['token']
            if token in seen:
                return
            if stage['action'] == 'background':
                seconds = stage['seconds']
                if seconds not in (30, 120):
                    raise ValueError('Unexpected health retention interval')
                self.shell('input', 'keyevent', 'KEYCODE_HOME')
                time.sleep(seconds)
                self.shell('am', 'start', '-W', '-n', QA + '/com.tarkilhk.wing.MainActivity')
            elif stage['action'] != 'capture':
                raise ValueError('Unexpected health retention action')
            subprocess.run([android.adb_path(), '-s', self.device, 'shell', 'run-as', QA,
                            'sh', '-c', '"cat > code_cache/wing-health-retention-ack"'],
                           input=token, text=True, check=True, timeout=25)
            seen.add(token)
        return checkpoint

    def html(self):
        self.install('integration_test/large_html_native_preview.dart')
        self.launch(DEV)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            remote = 'webview_devtools_remote_' + self.shell('pidof', DEV)
            if remote in self.shell('cat', '/proc/net/unix'):
                break
            time.sleep(.3)
        else:
            raise TimeoutError('Android WebView debug socket did not become ready')
        with self.forward('localabstract:' + remote) as port:
            self.environment.update(WING_ADB_SERIAL=self.device,
                                    WING_CDP_ENDPOINT='http://127.0.0.1:' + port)
            self.run('html-isolation', ['node', 'scripts/check-large-html-native.mjs'], timeout=300)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('family', choices=FAMILIES, nargs='?')
    parser.add_argument('--matrix', action='store_true', help='Publish every enrolled native family to CI')
    parser.add_argument('--changed-since', help='With --matrix, select affected families; an unknown base runs all')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/nightly-native')
    parser.add_argument('--hermes-source', type=Path)
    args = parser.parse_args()
    if args.changed_since is not None and not args.matrix:
        parser.error('--changed-since requires --matrix')
    if args.matrix:
        if not FAMILIES or len(set(FAMILIES)) != len(FAMILIES):
            raise ValueError('Nightly native catalog must be nonempty with unique families')
        selection = (impact_plan(ROOT, args.changed_since) if args.changed_since is not None
                     else {'families': list(FAMILIES), 'reasons': {}, 'changed': None})
        matrix = json.dumps(selection['families'])
        if 'GITHUB_OUTPUT' in os.environ:
            with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
                output.write('families=' + matrix + '\n')
        if 'GITHUB_STEP_SUMMARY' in os.environ:
            with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a') as summary:
                summary.write('### Native verification selection\n\n')
                summary.write(f"Selected {len(selection['families'])} of {len(FAMILIES)} families.\n\n")
                for family, paths in selection['reasons'].items():
                    summary.write(f'- **{family}**: ' + ', '.join(f'`{path}`' for path in paths) + '\n')
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / 'selection.json').write_text(json.dumps(selection, indent=2) + '\n')
        print(matrix)
        return 0
    if args.family is None:
        parser.error('Choose a native family or --matrix')
    os.chdir(ROOT)
    output = args.output.resolve() / args.family
    receipt = run_family_attempt(args, output,
                                 detect_graphics_stall=os.environ.get('GITHUB_ACTIONS') == 'true')
    if receipt.get('graphics_input_stall') and not receipt.get('source_changed'):
        recovery = Path(tempfile.mkdtemp(prefix='graphics-retry-', dir=output))
        first_receipt = recovery / 'first-attempt.json'
        (output / 'receipt.json').replace(first_receipt)
        print('Android gfxstream input ANR; repeating the complete family on a fresh emulator.',
              flush=True)
        retry = run_family_attempt(args, recovery)
        if retry['source_before'] != receipt['source_before']:
            retry.update(passed=False, source_changed=True)
        retry['graphics_recovery'] = {
            'first_receipt': str(first_receipt.relative_to(output)),
            'retry_receipt': str((recovery / 'receipt.json').relative_to(output)),
        }
        receipt = retry
        (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2), flush=True)
    return 0 if receipt['passed'] else 1


def run_family_attempt(args, output, *, detect_graphics_stall=False):
    output.mkdir(parents=True, exist_ok=True)
    previous_output = android.OUTPUT
    android.OUTPUT = output
    runner = Runner(output)
    receipt = {'family': args.family, 'passed': False, 'source_before': fingerprint(),
               'steps': runner.steps}
    try:
        with cleanup_signals():
            if args.family == 'clipboard':
                # Build before boot: System UI must own focus for the real clipboard grant.
                runner.build('integration_test/clipboard_device_test.dart', defines=CLIPBOARD_DEFINES)
            elif args.family == 'queue-editing':
                runner.build('integration_test/queued_message_edit_test.dart')
            elif args.family == 'slash':
                runner.build('integration_test/slash_completion_native_test.dart', defines=SLASH_DEFINES)
            if args.family == 'stock-hermes':
                # The stock runner admits current upstream before it boots its
                # own emulator. A wrapper-owned boot would make that prepared
                # source stale if upstream advances during Android startup.
                runner.family(args.family, args.hermes_source)
            else:
                stalled = None
                with android.owned_emulator() as device:
                    runner.device = device
                    android.require_emulator(device)
                    receipt['device'] = device
                    try:
                        runner.family(args.family, args.hermes_source)
                    except (Exception, KeyboardInterrupt) as error:
                        report = runner.capture_failure()
                        if (not detect_graphics_stall or runner.input_timeout_at is None or
                                isinstance(error, KeyboardInterrupt) or
                                not android.has_graphics_input_anr(report, runner.input_timeout_at)):
                            raise
                        stalled = error
                # Recovery is safe only after the first AVD has retired.
                if stalled is not None:
                    receipt['graphics_input_stall'] = True
                    raise stalled
        receipt['passed'] = bool(runner.steps) and all(step['passed'] for step in runner.steps)
    except (Exception, KeyboardInterrupt) as error:
        receipt['error'] = str(error) or type(error).__name__
    finally:
        android.OUTPUT = previous_output
        receipt['source_after'] = fingerprint()
        if receipt['source_before'] != receipt['source_after']:
            receipt.update(passed=False, source_changed=True)
        (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


if __name__ == '__main__':
    raise SystemExit(main())

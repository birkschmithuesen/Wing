#!/usr/bin/env python3
"""Run authorized Wing UI acceptance on an owned emulator against real Hermes.

Creates/removes a unique blank QA profile, seeds one disabled MCP configuration,
performs plugin maintenance only after verifying zero user installs, and drives
real isolated conversation/provider usage. Never changes shared plugin/config
policy. Credentials enter the owned Dev package only at runtime and are removed.
"""
import argparse
import hashlib
import http.cookiejar
import json
from pathlib import Path
import re
import select
import socket
import socketserver
import subprocess
import sys
import threading
import urllib.request
from urllib.parse import urlsplit
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.test import fingerprint
from scripts.test_vanilla_hermes import cleanup_signals
from scripts.test_nightly_native import Runner, DEV
from tools.qa import run_notification_gate as android

EXPECTED = {
    'processes': frozenset({
        'production Android discovers follows and stops background processes',
        'production Android compact activity preserves streamed order and details',
    }),
    'admin': frozenset({
        'Production N18 plugin maintenance confirms isolated inventory',
        'Production N19 cached MCP refresh retains disabled connector',
        'Production N23 settings save confirms isolated profile readback',
        'Production N17 skill lock and unlock confirm isolated readback',
    }),
    'conversation': frozenset({
        'production Android compression preview and applied history',
        'production Android discovers detached work without attachment',
    }),
    'groups': frozenset({
        'Production N09 N10 group settings persist and N03 work stops',
        'Production N08 N12 task policy and group delivery persist',
        'Production N07 stops an owned scheduled execution',
        'Production N11 continues an owned bounded group discussion',
    }),
    'sessions': frozenset({
        'Production N13 stages and confirms a real clarification batch',
        'Production N15 resets an owned session to its profile model',
    }),
    'context': frozenset({'Production N16 shows a configured context pin after a real reply'}),
}

TARGETS = {
    'processes': 'background_processes_prod_test.dart',
    'admin': 'hermes_next_admin_prod_test.dart',
    'conversation': 'hermes_next_conversation_prod_test.dart',
    'groups': 'hermes023_groups_tasks_prod_test.dart',
    'sessions': 'hermes023_sessions_prod_test.dart',
    'context': 'hermes023_context_prod_test.dart',
}
GROUP_MANIFESTS = {
    'Production N09 N10 group settings persist and N03 work stops': 'groups',
    'Production N08 N12 task policy and group delivery persist': 'tasks',
    'Production N07 stops an owned scheduled execution': 'task-stop',
    'Production N11 continues an owned bounded group discussion': 'continue',
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True)
    parser.add_argument('--login-file', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--suite', choices=EXPECTED, required=True)
    parser.add_argument('--case', action='append', help='Exact named case; repeat for focused recovery')
    args = parser.parse_args()
    expected = frozenset(args.case) if args.case else EXPECTED[args.suite]
    if not expected or not expected <= EXPECTED[args.suite]:
        parser.error('--case must name an exact case in the selected suite')
    address = urlsplit(args.url)
    if address.scheme != 'http' or address.path not in ('', '/') or address.username or address.query:
        raise ValueError('This TCP-forward recipe requires the canonical HTTP gateway origin')
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    nonce = 'wing-qa-' + uuid.uuid4().hex[:18]
    login = json.loads(args.login_file.read_bytes())
    credentials = {key: login[key] for key in ('provider', 'username', 'password')}
    private_login = json.dumps(credentials).encode()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def request(path, method='GET', body=None):
        req = urllib.request.Request(args.url.rstrip('/') + path,
            data=None if body is None else json.dumps(body).encode(), method=method,
            headers={'Content-Type': 'application/json', 'Origin': args.url.rstrip('/')})
        with opener.open(req, timeout=60) as response:
            return json.load(response)

    request('/auth/password-login', 'POST', credentials)
    backend = request('/api/health')
    if not isinstance(backend.get('commit'), str) or not re.fullmatch(r'[0-9a-f]{40}', backend['commit']):
        raise RuntimeError('Production acceptance requires the running backend commit')
    baseline = {row['name'] for row in request('/api/profiles')['profiles']}
    owned_profiles = [nonce] if args.suite in ('admin', 'context') else (
        [nonce + '-a', nonce + '-b'] if args.suite == 'groups' else [])
    if any(name in baseline for name in owned_profiles):
        raise RuntimeError('QA profile already exists')
    receipt = {'suite': args.suite, 'source_before': fingerprint(),
        'runner_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'app_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'backend_commit': backend.get('commit'), 'backend_version': backend.get('version'),
        'profile': nonce if args.suite in ('admin', 'context') else 'default', 'nonce': nonce,
        'profile_cleanup': 'not-needed', 'passed': False}
    receipt['backend_origin'] = args.url.rstrip('/')
    receipt['owned_profiles'] = owned_profiles
    receipt['expected'] = sorted(expected)
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2))
    runner = Runner(out)
    failure = None
    attempted_profiles = []
    device_started = False
    final_capture_confirmed = False

    relay_stopping = threading.Event()

    class Relay(socketserver.BaseRequestHandler):
        def handle(self):
            with socket.create_connection((address.hostname, address.port or 80), timeout=30) as remote:
                remote.settimeout(None)
                peers = [self.request, remote]
                while not relay_stopping.is_set():
                    ready, _, _ = select.select(peers, [], [], 1)
                    if not ready:
                        continue
                    for incoming in ready:
                        data = incoming.recv(65536)
                        if not data:
                            return
                        (remote if incoming is self.request else self.request).sendall(data)

    class Forward(socketserver.ThreadingTCPServer):
        daemon_threads = True
        allow_reuse_address = True

    android.OUTPUT = out
    try:
        if args.suite == 'admin':
            attempted_profiles.append(nonce)
            receipt['profile_cleanup'] = 'creation-attempted'
            (out / 'receipt.json').write_text(json.dumps(receipt, indent=2))
            request('/api/profiles', 'POST', {'name': nonce, 'no_skills': True,
                'description': 'Owned Wing production acceptance ' + nonce})
            receipt['profile_cleanup'] = 'pending'
            request('/api/config?profile=' + nonce, 'PUT', {'profile': nonce, 'config': {
                'mcp_servers': {'wing-qa-disabled': {
                    'command': 'python3', 'args': ['-c', 'pass'], 'enabled': False}},
                'memory': {'memory_char_limit': 2200}}})
            request('/api/skills', 'POST', {'profile': nonce, 'name': 'wing-qa-skill',
                'content': '---\nname: wing-qa-skill\ndescription: Isolated Wing skill lock acceptance.\n---\nThis skill is an inert QA fixture. Do not invoke tools or change files.\n'})
            rows = request('/api/mcp/servers?profile=' + nonce)['servers']
            assert len(rows) == 1 and rows[0]['name'] == 'wing-qa-disabled' and rows[0]['enabled'] is False
        elif args.suite in ('groups', 'context'):
            model = request('/api/model/info?profile=default')
            assert model.get('provider') and model.get('model'), 'Configured provider/model required'
            receipt['profile_cleanup'] = 'pending'
            for name in owned_profiles:
                attempted_profiles.append(name)
                receipt['attempted_profiles'] = list(attempted_profiles)
                (out / 'receipt.json').write_text(json.dumps(receipt, indent=2))
                created = request('/api/profiles', 'POST', {
                    'name': name, 'no_skills': True,
                    'description': 'Owned Wing production acceptance ' + nonce,
                    'provider': model['provider'], 'model': model['model']})
                assert created.get('model_set') is True, 'QA model configuration was refused'
                resolved = request('/api/model/info?profile=' + name)
                assert all(resolved.get(key) == model[key] for key in ('provider', 'model'))
            if args.suite == 'context':
                request('/api/config?profile=' + nonce, 'PUT', {
                    'profile': nonce, 'config': {'model': {'context_length': 65536}}})
                pinned = request('/api/model/info?profile=' + nonce)
                assert pinned['config_context_length'] == pinned['effective_context_length'] == 65536
        with Forward(('127.0.0.1', 0), Relay) as relay:
            port = relay.server_address[1]
            thread = threading.Thread(target=relay.serve_forever, daemon=True)
            thread.start()
            try:
                target = 'integration_test/' + TARGETS[args.suite]
                device_login = '/data/user/0/' + DEV + '/cache/wing-prod-login.json'
                defines = [
                    '--dart-define=WING_HERMES_URL=http://127.0.0.1:' + str(port),
                    '--dart-define=WING_HERMES_LOGIN_FILE=' + device_login,
                    '--dart-define=WING_QA_PROFILE=' + (owned_profiles[0] if owned_profiles else nonce),
                    '--dart-define=WING_QA_NONCE=' + nonce,
                    '--dart-define=CAPTURE_JOURNEYS=true', '--dart-define=JOURNEY_THEME=dark',
                ]
                if args.suite == 'groups':
                    defines.append('--dart-define=WING_QA_PROFILE_B=' + owned_profiles[1])
                runner.build(target, defines=defines)
                with android.owned_emulator() as serial:
                    runner.device = serial
                    receipt['device'] = serial
                    runner.install(target, defines=defines)
                    runner.adb('reverse', 'tcp:' + str(port), 'tcp:' + str(port))
                    # Avoid printing tee's output: credentials never enter logs or arguments.
                    subprocess.run([android.adb_path(), '-s', serial, 'shell', 'run-as', DEV,
                        'tee', 'cache/wing-prod-login.json'], input=private_login,
                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True, timeout=15)
                    runner.shell('run-as', DEV, 'chmod', '600', 'cache/wing-prod-login.json')
                    last_pulls = {}

                    def capture():
                        names = runner.shell('run-as', DEV, 'ls', 'code_cache').splitlines()
                        for name in names:
                            if not (name.startswith('wing-journey-') and name.endswith('.png') or
                                    name.startswith('wing-prod-owned-') and name.endswith('.json')):
                                continue
                            size = runner.shell('run-as', DEV, 'stat', '-c', '%s', 'code_cache/' + name)
                            if last_pulls.get(name) == size:
                                continue
                            data = subprocess.check_output([android.adb_path(), '-s', serial,
                                'exec-out', 'run-as', DEV, 'cat', 'code_cache/' + name], timeout=20)
                            (out / name).write_bytes(data)
                            last_pulls[name] = size

                    try:
                        device_started = True
                        selection = [] if not args.case else [
                            '--name', '^(?:' + '|'.join(re.escape(name) for name in expected) + ')$']
                        runner.run('production-' + args.suite, ['flutter', 'test', '--no-pub',
                            '--no-uninstall', '-d', serial, '--reporter=json', target, *defines, *selection],
                            expected=expected, checkpoint=capture, timeout=1800)
                        last_pulls.clear()
                        capture()
                        final_capture_confirmed = True
                    except Exception:
                        last_pulls.clear()
                        capture()
                        final_capture_confirmed = True
                        runner.capture_failure()
                        raise
                    finally:
                        runner.shell('run-as', DEV, 'rm', '-f', 'cache/wing-prod-login.json')
                        runner.adb('reverse', '--remove', 'tcp:' + str(port))
                receipt['passed'] = True
            finally:
                relay_stopping.set()
                relay.shutdown()
                thread.join(timeout=5)
    except Exception as error:
        failure = error
        receipt['error_type'] = type(error).__name__
    finally:
        if attempted_profiles:
            try:
                if args.suite == 'groups' and device_started:
                    assert final_capture_confirmed, 'Final ownership capture missing: retain QA profiles'
                    kinds = {GROUP_MANIFESTS[name] for name in expected}
                    manifests = {path.name: path for path in out.glob('wing-prod-owned-' + nonce + '-*.json')}
                    assert set(manifests) == {'wing-prod-owned-' + nonce + '-' + kind + '.json'
                        for kind in kinds}, 'Incomplete ownership receipts: retain QA profiles'
                    for kind in kinds:
                        manifest = json.loads(manifests['wing-prod-owned-' + nonce + '-' + kind + '.json'].read_text())
                        assert manifest.get('nonce') == nonce and manifest.get('kind') == kind
                        assert manifest.get('profiles') == owned_profiles
                        assert manifest.get('room_id') == nonce + '-' + kind
                        assert manifest.get('cleanup') == 'confirmed absent', 'Unfinished owned work: retain QA profiles'
                elif args.suite == 'context' and device_started:
                    assert final_capture_confirmed, 'Final ownership capture missing: retain QA profile'
                    manifest = json.loads((out / ('wing-prod-owned-' + nonce + '-context.json')).read_text())
                    assert manifest.get('nonce') == nonce and manifest.get('kind') == 'context'
                    assert manifest.get('profile') == nonce and manifest.get('cleanup') == 'confirmed absent'
                    assert manifest.get('session_ids'), 'No owned chat identity: retain QA profile'
                names = {row['name'] for row in request('/api/profiles')['profiles']}
                for name in attempted_profiles:
                    if name in names:
                        # Exact fresh names were absent in the pre-mutation snapshot.
                        request('/api/profiles/' + name, 'DELETE')
                names = {row['name'] for row in request('/api/profiles')['profiles']}
                assert not set(attempted_profiles) & names and baseline <= names
                receipt['profile_cleanup'] = 'confirmed-absent'
            except Exception as error:
                receipt['profile_cleanup'] = 'unconfirmed'
                receipt['cleanup_error_type'] = type(error).__name__
                failure = failure or error
        receipt['source_after'] = fingerprint()
        receipt['steps'] = runner.steps
        try:
            receipt['backend_after'] = request('/api/health').get('commit')
        except Exception as error:
            receipt['backend_after_error'] = type(error).__name__
        receipt['passed'] = bool(receipt['passed'] and failure is None and
            receipt['source_before'] == receipt['source_after'] and
            receipt['backend_commit'] == receipt.get('backend_after'))
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        print(json.dumps({key: receipt.get(key) for key in
            ('suite', 'passed', 'profile_cleanup', 'backend_commit', 'error_type')}), flush=True)
    if not receipt['passed']:
        raise SystemExit('Production UI acceptance incomplete; inspect private artifacts')


if __name__ == '__main__':
    with cleanup_signals():
        main()

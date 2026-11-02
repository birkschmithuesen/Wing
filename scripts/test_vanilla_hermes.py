#!/usr/bin/env python3
"""Run two provider-free Android journeys against a fresh, current stock Hermes.

Requires an unmodified upstream checkout with its web dependencies prepared in
.venv. This runner owns the backend home, process group and emulator forwarding;
it never accepts an existing server address or diagnostic credentials.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager, nullcontext
import http.cookiejar
import json
import os
from pathlib import Path
import re
import signal
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.test import fingerprint, stop_process_group  # noqa: E402
from scripts.test_journeys import verdict  # noqa: E402
from tools.qa import run_notification_gate as android  # noqa: E402

UPSTREAM = 'https://github.com/NousResearch/hermes-agent.git'
TARGET = 'integration_test/profile_admin_live_test.dart'
EXPECTED = frozenset({
    'project create rename appearance reload and delete use the real UI',
    'profile editor saves through UI and restores original server values',
})
PROFILES = ('android-qa-a', 'android-qa-b')
PACKAGE = 'com.tarkilhk.wing.notificationqa'


class PreconditionError(ValueError):
    """A safe, actionable message containing no backend response or secret."""


class RunInterrupted(RuntimeError):
    pass


@contextmanager
def cleanup_signals():
    """An outer timeout must unwind owned backend/emulator context managers."""
    def interrupted(signum, frame):
        raise RunInterrupted(f'Interrupted by signal {signum}')
    previous = {number: signal.signal(number, interrupted)
                for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        yield
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def checkout_revision(source: Path) -> str:
    """Reject dirty/non-root checkouts and ignored project credential files."""
    def git(*arguments):
        return subprocess.check_output(['git', *arguments], cwd=source,
                                       text=True, stderr=subprocess.PIPE, timeout=30).strip()
    if Path(git('rev-parse', '--show-toplevel')).resolve() != source.resolve():
        raise PreconditionError('--hermes-source must be the checkout root')
    if git('status', '--porcelain', '--untracked-files=all'):
        raise PreconditionError('Hermes checkout must have no modified or untracked files')
    if (source / '.env').exists():
        raise PreconditionError('Hermes checkout contains a project .env; refusing credential inheritance')
    if not (source / '.venv/bin/python').is_file():
        raise PreconditionError('Prepare the stock checkout .venv with its web dependencies first')
    return git('rev-parse', 'HEAD')


def current_upstream_revision() -> str:
    # No saved Git credentials, URL rewrites or caller-supplied remote are used.
    env = {key: value for key, value in os.environ.items() if key in {
        'PATH', 'LANG', 'LC_ALL', 'SSL_CERT_FILE', 'SSL_CERT_DIR',
        'HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'NO_PROXY',
        'https_proxy', 'http_proxy', 'all_proxy', 'no_proxy',
    }}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
               GIT_TERMINAL_PROMPT='0')
    result = subprocess.check_output(
        ['git', '-c', 'credential.helper=', 'ls-remote', UPSTREAM, 'refs/heads/main'],
        text=True, stderr=subprocess.PIPE, timeout=60, env=env, cwd=tempfile.gettempdir(),
    ).strip().split()
    if len(result) != 2 or result[1] != 'refs/heads/main' or not re.fullmatch(r'[0-9a-f]{40}', result[0]):
        raise PreconditionError('Could not establish the current official upstream main revision')
    return result[0]


def validate_source(source: Path) -> str:
    revision = checkout_revision(source)
    upstream = current_upstream_revision()
    if revision != upstream:
        raise PreconditionError(f'Hermes checkout {revision} is not current official upstream main '
                                f'{upstream}; prepare a current checkout')
    return revision


def backend_environment(source: Path, temporary: Path, inherited: dict) -> dict:
    """Allowlist environment; even unknown provider/plugin credentials stay out."""
    env = {key: inherited[key] for key in ('LANG', 'LC_ALL', 'SSL_CERT_FILE', 'SSL_CERT_DIR')
           if key in inherited}
    env.update({
        'PATH': f'{source}/.venv/bin:/usr/local/bin:/usr/bin:/bin',
        'HOME': str(temporary / 'user'),
        'USER': 'wing-vanilla-test', 'LOGNAME': 'wing-vanilla-test',
        'HERMES_HOME': str(temporary / 'hermes'),
        'XDG_CONFIG_HOME': str(temporary / 'user/config'),
        'XDG_CACHE_HOME': str(temporary / 'user/cache'),
        'XDG_DATA_HOME': str(temporary / 'user/data'),
        'TMPDIR': str(temporary / 'tmp'),
        'HERMES_RUNTIME_DIR': str(temporary / 'runtime'),
        'HERMES_GATEWAY_LOCK_DIR': str(temporary / 'locks'),
        'PYTHONNOUSERSITE': '1', 'PYTHONDONTWRITEBYTECODE': '1',
        'PYTHONUNBUFFERED': '1',
    })
    return env


def private_file(path: Path):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(descriptor, 0o600)
    return os.fdopen(descriptor, 'w')


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('Disposable backend unexpectedly redirected a request')


def local_request(port: int, path: str):
    """Only the owned loopback listener; proxies/redirects cannot change it."""
    if type(port) is not int or not 0 < port < 65536 or not path.startswith('/') or path.startswith('//'):
        raise ValueError('Invalid owned backend request')
    request = urllib.request.Request(f'http://127.0.0.1:{port}{path}')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    with opener.open(request, timeout=5) as response:
        return response.read().decode()


@contextmanager
def owned_backend(source: Path, output: Path, *, startup_timeout: float = 120):
    with tempfile.TemporaryDirectory(prefix='wing-vanilla-hermes-') as directory:
        temporary = Path(directory)
        env = backend_environment(source, temporary, os.environ)
        for key in ('HOME', 'HERMES_HOME', 'TMPDIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME'):
            Path(env[key]).mkdir(parents=True, exist_ok=True, mode=0o700)
        home = Path(env['HERMES_HOME'])
        # Use the canonical gateway's Webapp listener and the same password
        # login as Wing. Standalone `serve` has no session authority.
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        username, password = 'wing-ci', secrets.token_urlsafe(32)
        origin = f'http://127.0.0.1:{port}'
        # A declared non-loopback public host engages stock password auth even
        # on a loopback bind. All test traffic still uses the owned local port;
        # this reserved .test name is never resolved or contacted.
        with private_file(home / 'config.yaml') as config:
            json.dump({'webapp': {'enabled': True, 'host': '127.0.0.1',
                                  'port': port, 'public_url': 'http://wing-ci.test'},
                       'dashboard': {'basic_auth': {'username': username,
                                                    'password': password}}}, config)
        defines = temporary / 'android-defines.json'
        with private_file(defines) as stream:
            json.dump({'HERMES_TEST_PORT': port, 'HERMES_TEST_USERNAME': username,
                       'HERMES_TEST_PASSWORD': password}, stream)
        (home / '.env').write_text('')
        (home / '.no-bundled-skills').write_text('Disposable profile: essential stock skills only.\n')
        command = [str(source / '.venv/bin/python'), '-m', 'hermes_cli.main', 'gateway', 'run']
        with private_file(output / 'backend.log') as log:
            process = subprocess.Popen(command, cwd=source, env=env, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                deadline = time.monotonic() + startup_timeout
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError('Stock Hermes exited during startup; see private backend.log')
                    try:
                        local_request(port, '/api/health')
                        break
                    except (OSError, ValueError):
                        pass
                    time.sleep(.1)
                else:
                    raise TimeoutError('Stock Hermes startup timed out; see private backend.log')
                cookies = http.cookiejar.CookieJar()
                client = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                    _NoRedirect(), urllib.request.HTTPCookieProcessor(cookies))
                def post(path, body):
                    request = urllib.request.Request(origin + path,
                        data=json.dumps(body).encode(), headers={'Content-Type': 'application/json'})
                    with client.open(request, timeout=30) as response:
                        return json.load(response)
                post('/auth/password-login', {'provider': 'basic',
                     'username': username, 'password': password})
                for name in PROFILES:
                    post('/api/profiles', {'name': name, 'no_skills': True})
                cookies.clear()
                yield {'port': port, 'pid': process.pid, 'temporary_home': str(home),
                       'defines_file': str(defines)}
                if process.poll() is not None:
                    raise RuntimeError('Stock Hermes exited before acceptance completed')
            finally:
                stop_process_group(process)


def journey_verdict(lines: list[str], returncode: int) -> dict:
    return verdict(lines, returncode, EXPECTED)


def flutter_environment(inherited: dict) -> dict:
    return {**inherited, 'ORG_GRADLE_PROJECT_notificationQa': 'true',
            'ORG_GRADLE_PROJECT_nativeShareQa': 'false',
            'ORG_GRADLE_PROJECT_wingDevelopment': 'false',
            'ORG_GRADLE_PROJECT_performanceQa': 'false'}


def run(source: Path, output: Path, device: str | None = None) -> dict:
    source, output = source.resolve(), output.resolve()
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    before = fingerprint()
    receipt = {'passed': False, 'source_before': before, 'upstream': UPSTREAM,
               'target': TARGET, 'expected': sorted(EXPECTED), 'provider_credentials': False,
               'custom_backend_extensions': False}
    previous_output = android.OUTPUT
    stage = 'source validation'
    try:
        receipt['hermes_revision'] = validate_source(source)
        android.OUTPUT = output
        stage = 'emulator admission'
        with nullcontext(device) if device else android.owned_emulator() as serial:
            android.require_emulator(serial)
            receipt['device'] = serial
            stage = 'backend initialization'
            try:
                with owned_backend(source, output) as backend:
                    receipt['backend'] = backend
                    endpoint = f'tcp:{backend["port"]}'
                    forwarded = False
                    stage = 'Android journeys'
                    try:
                        android.device(serial, 'reverse', '--no-rebind', endpoint, endpoint)
                        forwarded = True
                        command = ['flutter', 'test', '--no-pub', '-d', serial, '--reporter=json',
                                   '--dart-define-from-file=' + backend['defines_file'], TARGET]
                        receipt['command'] = command
                        with private_file(output / 'journeys.jsonl') as log:
                            process = subprocess.Popen(command, cwd=ROOT, stdout=log,
                                                       stderr=subprocess.STDOUT, start_new_session=True,
                                                       env=flutter_environment(os.environ))
                            try:
                                code = process.wait(timeout=900)
                            finally:
                                stop_process_group(process)
                        receipt['journeys'] = journey_verdict((output / 'journeys.jsonl').read_text().splitlines(), code)
                        receipt['passed'] = receipt['journeys']['passed']
                    finally:
                        try:
                            android.device(serial, 'shell', 'am', 'force-stop', PACKAGE)
                        finally:
                            if forwarded:
                                android.device(serial, 'reverse', '--remove', endpoint)
            finally:
                if not receipt['passed']:
                    android.capture_failure(serial, output)
        receipt['backend_cleaned'] = not Path(receipt['backend']['temporary_home']).exists()
        stage = 'source recheck'
        if checkout_revision(source) != receipt['hermes_revision']:
            raise ValueError('Hermes checkout changed during execution')
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        # Exception bodies/HTTP responses can contain local session tokens.
        receipt.update(passed=False, error_type=type(error).__name__, failed_stage=stage,
                       error=str(error) if isinstance(error, PreconditionError) else
                       'Vanilla Hermes acceptance failed; inspect the private logs and prerequisites')
    finally:
        android.OUTPUT = previous_output
        if 'backend' in receipt:
            receipt['backend_cleaned'] = not Path(receipt['backend']['temporary_home']).exists()
            if not receipt['backend_cleaned']:
                receipt['passed'] = False
        receipt['source_after'] = fingerprint()
        if receipt['source_after'] != before:
            receipt.update(passed=False, source_changed=True)
        with private_file(output / 'receipt.json') as result:
            result.write(json.dumps(receipt, indent=2) + '\n')
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hermes-source', required=True, type=Path)
    parser.add_argument('--device', help='Reuse a caller-owned disposable emulator; never a physical device')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/vanilla-hermes')
    args = parser.parse_args()
    with cleanup_signals():
        result = run(args.hermes_source, args.output, args.device)
    print(json.dumps(result, indent=2))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

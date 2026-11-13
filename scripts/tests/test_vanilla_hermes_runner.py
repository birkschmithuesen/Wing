"""Ownership, credential isolation and completion guards for live acceptance."""
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from scripts import test_vanilla_hermes as runner
from scripts.tests.test_journey_runner import events


class VanillaSourceAdmission(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='wing-source-guard-')
        self.addCleanup(self.directory.cleanup)
        self.source = Path(self.directory.name)
        (self.source / '.venv/bin').mkdir(parents=True)
        (self.source / '.venv/bin/python').symlink_to(sys.executable)
        (self.source / '.gitignore').write_text('.venv/\n.env\n')
        (self.source / 'stock.py').write_text('value = 1\n')
        self.git('init', '-q')
        self.git('add', '.')
        self.git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                 'commit', '-qm', 'stock fixture')
        self.revision = self.git('rev-parse', 'HEAD').strip()

    def git(self, *arguments):
        return subprocess.check_output(['git', *arguments], cwd=self.source,
                                       text=True, stderr=subprocess.PIPE)

    def test_clean_current_prepared_source_is_admitted(self):
        with patch.object(runner, 'current_upstream_revision', return_value=self.revision):
            self.assertEqual(runner.validate_source(self.source), self.revision)

    def test_stale_revision_is_rejected_before_backend_start(self):
        with patch.object(runner, 'current_upstream_revision', return_value='a' * 40):
            with self.assertRaises(ValueError):
                runner.validate_source(self.source)

    def test_stale_source_cannot_allocate_emulator_or_backend(self):
        with tempfile.TemporaryDirectory() as output, \
             patch.object(runner, 'current_upstream_revision', return_value='b' * 40), \
             patch.object(runner, 'fingerprint', return_value='stable'), \
             patch.object(runner.android, 'owned_emulator') as emulator, \
             patch.object(runner, 'owned_backend') as backend:
            result = runner.run(self.source, Path(output))
        self.assertFalse(result['passed'])
        self.assertEqual(result['failed_stage'], 'source validation')
        self.assertIn(self.revision, result['error'])
        self.assertIn('b' * 40, result['error'])
        emulator.assert_not_called()
        backend.assert_not_called()

    def test_modified_backend_code_is_rejected(self):
        (self.source / 'stock.py').write_text('value = 2\n')
        with self.assertRaises(ValueError):
            runner.checkout_revision(self.source)

    def test_untracked_backend_extension_is_rejected(self):
        (self.source / 'extension.py').write_text('value = 2\n')
        with self.assertRaises(ValueError):
            runner.checkout_revision(self.source)

    def test_ignored_project_credentials_are_rejected(self):
        (self.source / '.env').write_text('UNKNOWN_PROVIDER_SECRET=do-not-load\n')
        self.assertEqual(self.git('status', '--porcelain'), '')
        with self.assertRaises(ValueError):
            runner.checkout_revision(self.source)

    def test_checkout_subdirectory_cannot_redirect_bootstrap(self):
        nested = self.source / 'nested'
        nested.mkdir()
        with self.assertRaises(ValueError):
            runner.checkout_revision(nested)


class VanillaEnvironmentAndVerdict(unittest.TestCase):
    def test_inherited_build_flavors_cannot_change_the_owned_qa_package(self):
        inherited = {'ORG_GRADLE_PROJECT_' + key: 'true' for key in
                     ('nativeShareQa', 'wingDevelopment', 'performanceQa')}
        inherited['ORG_GRADLE_PROJECT_notificationQa'] = 'false'
        inherited['ANDROID_HOME'] = '/sdk'
        selected = runner.flutter_environment(inherited)
        self.assertEqual(selected['ORG_GRADLE_PROJECT_notificationQa'], 'true')
        self.assertEqual(selected['ANDROID_HOME'], '/sdk')
        for key in ('nativeShareQa', 'wingDevelopment', 'performanceQa'):
            self.assertEqual(selected['ORG_GRADLE_PROJECT_' + key], 'false')

    def test_unknown_credentials_and_process_injection_never_reach_backend(self):
        inherited = {
            'HOME': '/real/user', 'HERMES_HOME': '/real/hermes',
            'NEW_VENDOR_TOKEN': 'secret', 'OPENAI_API_KEY': 'secret',
            'PYTHONPATH': '/untrusted', 'LD_PRELOAD': '/untrusted/library',
            'HERMES_ENABLE_PROJECT_PLUGINS': '1', 'HTTPS_PROXY': 'http://secret@proxy',
            'LANG': 'C.UTF-8', 'SSL_CERT_FILE': '/public/ca.pem',
        }
        env = runner.backend_environment(Path('/stock'), Path('/owned'), inherited)
        self.assertNotIn('secret', json.dumps(env))
        self.assertNotIn('untrusted', json.dumps(env))
        self.assertFalse(set(inherited).difference({'HOME', 'HERMES_HOME', 'LANG', 'SSL_CERT_FILE'}) & set(env))
        self.assertEqual(env['HOME'], '/owned/user')
        self.assertEqual(env['HERMES_HOME'], '/owned/hermes')
        self.assertEqual(env['SSL_CERT_FILE'], '/public/ca.pem')

    def test_both_exact_completed_journeys_pass(self):
        self.assertTrue(runner.journey_verdict(events(runner.EXPECTED), 0)['passed'])

    def test_each_missing_or_skipped_live_journey_fails(self):
        for name in runner.EXPECTED:
            for field in ('skipped', 'omitted'):
                with self.subTest(name=name, field=field):
                    self.assertFalse(runner.journey_verdict(events(runner.EXPECTED, **{field: name}), 0)['passed'])

    def test_an_extra_passing_journey_cannot_expand_mutation_scope(self):
        result = runner.journey_verdict(events(runner.EXPECTED | {'unapproved workflow'}), 0)
        self.assertFalse(result['passed'])
        self.assertEqual(result['unexpected'], ['unapproved workflow'])

    def test_interrupted_or_nonzero_exit_cannot_pass(self):
        lines = events(runner.EXPECTED)
        self.assertFalse(runner.journey_verdict(lines[:-1], 0)['passed'])
        self.assertFalse(runner.journey_verdict(lines, 1)['passed'])

    def test_backend_request_cannot_target_external_address(self):
        for path in ('https://example.invalid/', '//example.invalid/'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                runner.local_request(12345, path)


# This tiny server tests process/socket ownership, not Hermes interoperability.
# The production runner still starts its standard CLI and creates profiles over
# HTTP. Native acceptance uses only the independently verified upstream checkout.
FAKE_STOCK_CLI = '''
import http.server, json, os, pathlib, sys
assert sys.argv[1:] == ["gateway", "run"], "Must launch the canonical gateway"
home = pathlib.Path(os.environ['HERMES_HOME'])
config = json.loads((home / 'config.yaml').read_text())
assert config['webapp']['host'] == '127.0.0.1'
assert config['webapp']['public_url'] == 'http://wing-ci.test'
auth = config['dashboard']['basic_auth']
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        assert self.path == '/api/health'
        self.send_response(200); self.end_headers()
        self.wfile.write(b'{"status":"ok"}')
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if self.path == '/auth/password-login':
            assert body == dict(provider='basic', **auth)
            self.send_response(200)
            self.send_header('Set-Cookie', 'hermes_session_at=synthetic-local-token; Path=/')
        else:
            assert self.path == '/api/profiles'
            assert self.headers['Cookie'] == 'hermes_session_at=synthetic-local-token'
            assert body['no_skills'] is True and set(body) == {'name', 'no_skills'}
            (home / body['name']).write_text('owned profile')
            self.send_response(200)
        self.end_headers(); self.wfile.write(b'{}')
server = http.server.HTTPServer(('127.0.0.1', config['webapp']['port']), Handler)
server.serve_forever()
'''



class BackendOwnership(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='wing-backend-guard-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / 'stock'
        (self.source / '.venv/bin').mkdir(parents=True)
        (self.source / '.venv/bin/python').symlink_to(sys.executable)
        (self.source / 'hermes_cli').mkdir()
        (self.source / 'hermes_cli/__init__.py').touch()
        (self.source / 'hermes_cli/main.py').write_text(FAKE_STOCK_CLI)
        self.output = self.root / 'evidence'
        self.output.mkdir()

    def test_owned_profiles_process_and_home_retire_after_caller_failure(self):
        with self.assertRaisesRegex(RuntimeError, 'journey failed'):
            with runner.owned_backend(self.source, self.output, startup_timeout=5) as backend:
                home = Path(backend['temporary_home'])
                defines = Path(backend['defines_file'])
                credentials = json.loads(defines.read_text())
                self.assertEqual(defines.stat().st_mode & 0o777, 0o600)
                self.assertEqual(credentials['HERMES_TEST_PORT'], backend['port'])
                self.assertNotIn(credentials['HERMES_TEST_PASSWORD'], json.dumps(backend))
                self.assertEqual({p.name for p in home.glob('android-qa-*')}, set(runner.PROFILES))
                self.assertEqual(runner.local_request(backend['port'], '/api/health'), '{"status":"ok"}')
                raise RuntimeError('journey failed')
        self.assertFalse(home.exists())
        self.assertFalse(defines.exists())
        with self.assertRaises(ProcessLookupError):
            os.kill(backend['pid'], 0)
        self.assertEqual((self.output / 'backend.log').stat().st_mode & 0o777, 0o600)

    def test_backend_exit_during_startup_is_not_a_ready_server(self):
        (self.source / 'hermes_cli/main.py').write_text('raise SystemExit(7)\n')
        with self.assertRaisesRegex(RuntimeError, 'exited during startup'):
            with runner.owned_backend(self.source, self.output, startup_timeout=5):
                self.fail('Startup failure must never yield a backend')

    def test_termination_signal_unwinds_backend_ownership(self):
        previous = signal.getsignal(signal.SIGTERM)
        with runner.cleanup_signals():
            with self.assertRaises(runner.RunInterrupted):
                with runner.owned_backend(self.source, self.output, startup_timeout=5) as backend:
                    os.kill(os.getpid(), signal.SIGTERM)
        self.assertEqual(signal.getsignal(signal.SIGTERM), previous)
        self.assertFalse(Path(backend['temporary_home']).exists())
        with self.assertRaises(ProcessLookupError):
            os.kill(backend['pid'], 0)

    def test_full_runner_removes_its_forward_and_backend_after_flutter_failure(self):
        commands = []

        def device(serial, *args):
            commands.append((serial, args))
            return ''

        real_popen = subprocess.Popen

        def start(command, **kwargs):
            if command[0] == 'flutter':
                raise OSError('synthetic-local-token must not enter the receipt')
            return real_popen(command, **kwargs)

        with patch.object(runner, 'validate_source', return_value='a' * 40), \
             patch.object(runner, 'fingerprint', return_value='stable'), \
             patch.object(runner.android, 'require_emulator'), \
             patch.object(runner.android, 'device', side_effect=device), \
             patch.object(runner.android, 'capture_failure') as capture, \
             patch.object(runner.subprocess, 'Popen', side_effect=start):
            result = runner.run(self.source, self.output, 'emulator-5562')
        capture.assert_called_once_with('emulator-5562', self.output)
        self.assertFalse(result['passed'])
        self.assertTrue(result['backend_cleaned'])
        self.assertNotIn('synthetic-local-token', json.dumps(result))
        endpoint = f'tcp:{result["backend"]["port"]}'
        self.assertIn(('emulator-5562', ('reverse', '--remove', endpoint)), commands)
        self.assertIn(('emulator-5562', ('shell', 'am', 'force-stop', runner.PACKAGE)), commands)
        with self.assertRaises(ProcessLookupError):
            os.kill(result['backend']['pid'], 0)


if __name__ == '__main__':
    unittest.main()

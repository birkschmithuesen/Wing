#!/usr/bin/env python3
"""Run routine product tests and linters, or the complete nightly suite."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]


def requires_full(path):
    """Checker, fixture, runner and dependency changes require exhaustive proofs."""
    return (path.startswith(('tools/', '.github/', '.githooks/', 'scripts/',
                             'test/support/', 'test/fixtures/', 'test/helpers/'))
            or path.endswith('_guard_test.dart')
            or path.startswith('test/architecture_')
            or path in {
                'pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml', 'dart_test.yaml',
                'test/architecture_contract_test.dart', 'test/image_codec_confinement_test.dart',
                'test/image_codec_provenance_test.dart', 'test/required_quality_gates_test.dart',
                'test/test_batches_test.dart', 'test/architecture_proof_process_test.dart',
            }
            or path.endswith('flutter_test_config.dart'))


def full_for_changes(root, reference):
    if not reference or set(reference) == {'0'}:
        return True
    try:
        resolved = subprocess.run(
            ['git', 'rev-parse', '--verify', '--end-of-options', reference + '^{commit}'],
            cwd=root, capture_output=True, check=True,
        ).stdout.decode().strip()
        changed = subprocess.run(
            ['git', 'diff', '--no-renames', '--name-only', '-z', resolved, '--'],
            cwd=root, capture_output=True, check=True,
        ).stdout
        untracked = subprocess.run(
            ['git', 'ls-files', '--others', '--exclude-standard', '-z'],
            cwd=root, capture_output=True, check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return True
    return any(requires_full(name) for name in
               (changed + untracked).decode('utf-8', errors='surrogateescape').split('\0') if name)


def fingerprint():
    digest = hashlib.sha256()
    authored = subprocess.check_output(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT,
    ).decode('utf-8', errors='surrogateescape').split('\0')
    names = {name for name in authored if name}
    names.add('.dart_tool/package_config.json')
    for name in sorted(names):
        digest.update(name.encode())
        path = ROOT / name
        if path.is_file():
            digest.update(b'file\0')
            digest.update(path.read_bytes())
        else:
            digest.update(b'missing\0')
    return digest.hexdigest()


def prepare_proof_commands(dart, directory, proofs, archive):
    """Share compiled harness code; every selected proof still gets a fresh VM."""
    directory = Path(directory)
    snapshot = directory / 'proofs.aot'
    runtime = str(Path(dart).with_name('dartaotruntime.exe' if os.name == 'nt' else 'dartaotruntime'))
    if not Path(runtime).is_file():
        raise ValueError('the selected SDK has no native Dart runtime')
    compilation = subprocess.run(
        [dart, 'compile', 'aot-snapshot', '--packages=.dart_tool/package_config.json',
         str(directory / 'proofs.dart'), '-o', str(snapshot)],
        cwd=ROOT, capture_output=True, text=True,
    )
    (archive / 'proof-compilation.stdout').write_text(compilation.stdout)
    (archive / 'proof-compilation.stderr').write_text(compilation.stderr)
    if compilation.returncode or not snapshot.is_file():
        sys.stderr.write(compilation.stdout)
        sys.stderr.write(compilation.stderr)
        raise ValueError('architecture proof dispatcher did not compile; see private evidence')
    shim_directory = directory / 'bin'
    shim_directory.mkdir()
    shim = shim_directory / 'dart'
    shim.write_text(
        f'#!{sys.executable}\n'
        'import os\nfrom pathlib import Path\nimport sys\n'
        f'dart = {dart!r}\n'
        f'runtime = {runtime!r}\n'
        f'snapshot = {str(snapshot)!r}\n'
        f'proofs = frozenset({proofs!r})\n'
        'arguments = sys.argv[1:]\n'
        "if len(arguments) >= 2 and arguments[0] == 'run':\n"
        '    source = str(Path(arguments[1]).resolve())\n'
        '    if source in proofs:\n'
        '        os.execv(runtime, [runtime, snapshot, source, *arguments[2:]])\n'
        'os.execv(dart, [dart, *arguments])\n'
    )
    shim.chmod(0o700)
    descriptor = directory / 'architecture-commands.json'
    descriptor.write_text(json.dumps({
        'root': str(ROOT), 'dart': dart, 'runtime': runtime, 'snapshot': str(snapshot), 'commands': proofs,
        'package_config': str(ROOT / '.dart_tool/package_config.json'),
    }))
    return {**os.environ, 'PATH': str(shim_directory) + os.pathsep + os.environ['PATH'],
            'WING_TEST_ARCHITECTURE_COMMANDS': str(descriptor)}


def stop_process_group(process):
    """Release only this run's children before deleting their artifacts."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    # A leader can exit on SIGTERM while a descendant ignores it. Finish
    # terminating this owned group before its temporary inputs are removed.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--concurrency', type=int, default=min(8, os.cpu_count() or 1))
    parser.add_argument('--full', action='store_true', help='Run every checker proof as well as product tests')
    parser.add_argument('--changed-since', help='Also require full verification when checking-tool inputs changed')
    parser.add_argument('--skip-linters', action='store_true',
                        help='Run host tests with source linters enforced in separate CI steps')
    args = parser.parse_args()
    if args.concurrency < 1:
        parser.error('concurrency must be positive')
    flutter = shutil.which('flutter')
    dart = shutil.which('dart')
    if not flutter or not dart:
        parser.error('activate the project Flutter toolchain first')
    started = time.monotonic()
    full = args.full or (args.changed_since is not None and full_for_changes(ROOT, args.changed_since))
    archive = Path(tempfile.mkdtemp(prefix='wing-host-tests-'))
    (ROOT / 'build').mkdir(exist_ok=True)
    before = fingerprint()
    (archive / 'source-before.json').write_text(json.dumps({'fingerprint': before}) + '\n')
    toolchain = {
        'flutter': flutter,
        'dart': dart,
        'flutter_version': subprocess.check_output(
            [flutter, '--version', '--machine'], cwd=ROOT, text=True,
        ),
        'dart_version': subprocess.check_output([dart, '--version'], text=True),
    }
    (archive / 'toolchain.json').write_text(json.dumps(toolchain, indent=2) + '\n')
    counts = Counter()
    skipped_tests = []
    reported_errors = 0
    done = None
    result = 2
    interrupted = False
    lint = None
    lint_logs = []
    try:
        if args.skip_linters:
            print('Host tests only; current-source linters must run separately.', flush=True)
        if not args.skip_linters:
            lint_logs = [(archive / name).open('w') for name in ('linters.stdout', 'linters.stderr')]
            lint = subprocess.Popen([sys.executable, 'scripts/check_commit_linters.py'],
                                    cwd=ROOT, stdout=lint_logs[0], stderr=lint_logs[1],
                                    start_new_session=True)
            print('Checking current-source linters alongside host tests.', flush=True)
        with tempfile.TemporaryDirectory(prefix='host-test-batches-', dir=ROOT / 'build') as directory:
            planning = subprocess.run(
                [dart, '--packages=.dart_tool/package_config.json',
                 'tools/testing/test_batches.dart', directory, str(args.concurrency), 'full' if full else 'routine'],
                cwd=ROOT, capture_output=True, text=True,
            )
            (archive / 'planning.stdout').write_text(planning.stdout)
            (archive / 'planning.stderr').write_text(planning.stderr)
            if planning.returncode:
                sys.stderr.write(planning.stderr)
                result = planning.returncode
                return result
            plan = json.loads(planning.stdout)
            discovered = sorted(str(path.relative_to(ROOT)).replace(os.sep, '/')
                                for path in (ROOT / 'test').rglob('*_test.dart'))
            represented = plan['isolated'] + [name for batch in plan['batches'] for name in batch]
            if (Counter(represented + plan['scheduled']) != Counter(discovered)
                    or plan['files'] != discovered or (full and plan['scheduled'])):
                raise ValueError('every original main must be selected or scheduled exactly once')
            (archive / 'plan.json').write_text(json.dumps(plan, indent=2) + '\n')
            environment = prepare_proof_commands(
                plan['dart_executable'], directory, plan['proof_commands'], archive,
            ) if full else dict(os.environ)
            grouped = sum(map(len, plan['batches']))
            print(f'Running {len(represented)} {"full" if full else "routine"} host suites: {grouped} grouped, '
                  f'{len(plan["isolated"])} isolated; concurrency {args.concurrency}.', flush=True)
            if plan['scheduled']:
                print(f'{len(plan["scheduled"])} checker proof suites run nightly, on tool changes, and before release.', flush=True)
            command = [flutter, 'test', '--no-pub', f'--concurrency={args.concurrency}',
                       '--reporter=json', *plan['targets']]
            (archive / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
            last_update = time.monotonic()
            tests = {}
            diagnostics = {}
            with (archive / 'tests.jsonl').open('w') as log, (archive / 'tests.stderr').open('w') as err:
                process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE,
                                           stderr=err, text=True, env=environment, start_new_session=True)
                try:
                    for line in process.stdout:
                        log.write(line)
                        try:
                            event = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if event.get('type') == 'testStart':
                            tests[event['test']['id']] = event['test']['name']
                        elif event.get('type') == 'print':
                            test_id = event.get('testID')
                            # Flutter emits assertion details as print events
                            # before the error. Keep a bounded tail for failures.
                            diagnostics[test_id] = (diagnostics.get(test_id, '')
                                                    + event.get('message', '') + '\n')[-65536:]
                        elif event.get('type') == 'testDone' and not event.get('hidden'):
                            counts['skipped' if event.get('skipped') else event['result']] += 1
                            if event.get('skipped'):
                                skipped_tests.append(tests.get(event.get('testID'), 'Unknown skipped test'))
                            diagnostics.pop(event.get('testID'), None)
                        elif event.get('type') == 'done':
                            done = event
                        elif event.get('type') == 'error':
                            reported_errors += 1
                            print(tests.get(event.get('testID'), 'Test loading failure'),
                                  file=sys.stderr, flush=True)
                            detail = diagnostics.pop(event.get('testID'), '')
                            if detail:
                                print(detail, file=sys.stderr, flush=True)
                            print(event.get('error', 'test error'), file=sys.stderr, flush=True)
                            if event.get('stackTrace'):
                                print(event['stackTrace'], file=sys.stderr, flush=True)
                        if time.monotonic() - last_update >= 15:
                            print(f'{time.monotonic() - started:.0f}s: {dict(counts)}', flush=True)
                            last_update = time.monotonic()
                    result = process.wait()
                finally:
                    stop_process_group(process)
        if lint is not None:
            lint_result = lint.wait()
            if lint_result:
                for name in ('linters.stdout', 'linters.stderr'):
                    sys.stderr.write((archive / name).read_text())
                result = result or lint_result
            else:
                print('Current-source linters passed.', flush=True)
        after = fingerprint()
        if before != after:
            print('Sources changed during verification; this run cannot certify fixed-source performance.',
                  file=sys.stderr)
            result = result or 1
        if done is None or not done.get('success'):
            result = result or 1
        if reported_errors or counts['error'] or counts['failure']:
            result = result or 1
        if not counts['success']:
            print('No non-skipped tests passed; an empty or skipped run cannot certify behavior.',
                  file=sys.stderr)
            result = result or 1
        summary = {'elapsed_seconds': time.monotonic() - started, 'counts': dict(counts),
                   'done': done, 'exit_code': result, 'source_before': before,
                   'source_after': after, 'concurrency': args.concurrency}
        summary['suite'] = 'full' if full else 'routine'
        summary['linters'] = 'external' if args.skip_linters else 'local'
        summary['scheduled_suites'] = plan['scheduled']
        summary['skipped_tests'] = skipped_tests
        summary['reported_errors'] = reported_errors
        (archive / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        print(f'{summary["elapsed_seconds"]:.2f}s: {dict(counts)}; evidence {archive}', flush=True)
        return result
    except KeyboardInterrupt:
        interrupted = True
        result = 130
        print(f'Host verification interrupted; evidence {archive}', file=sys.stderr)
        return result
    except (OSError, ValueError, KeyError) as error:
        result = 2
        print(f'Host test runner input failure: {error}; evidence {archive}', file=sys.stderr)
        return result
    finally:
        if lint is not None:
            stop_process_group(lint)
        for log in lint_logs:
            log.close()
        if not (archive / 'summary.json').exists():
            try:
                after = fingerprint()
            except OSError:
                after = None
            (archive / 'summary.json').write_text(json.dumps({
                'elapsed_seconds': time.monotonic() - started,
                'counts': dict(counts), 'done': done, 'exit_code': result,
                'source_before': before, 'source_after': after,
                'concurrency': args.concurrency, 'interrupted': interrupted,
                'suite': 'full' if full else 'routine',
                'linters': 'external' if args.skip_linters else 'local',
            }, indent=2) + '\n')


if __name__ == '__main__':
    raise SystemExit(main())

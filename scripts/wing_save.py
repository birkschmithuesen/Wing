#!/usr/bin/env python3
"""Save staged Wing changes and internal drafts, then push both repositories."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import subprocess
import sys


class SaveError(Exception):
    """A failed save leaves completed commits available for retry."""


def git(root: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    # A caller's alternate index or repository context must never cross repos.
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('GIT_')}
    environment['GIT_TERMINAL_PROMPT'] = '0'
    result = subprocess.run(['git', '-C', str(root), *args], env=environment,
                            capture_output=True, text=True)
    if check and result.returncode:
        raise SaveError('\n'.join(part for part in
                        (result.stdout.strip(), result.stderr.strip()) if part)
                        or f'Git {args[0]} failed.')
    return result


def output(root: Path, *args: str) -> str:
    return git(root, *args).stdout.strip()


def changed(root: Path) -> bool:
    result = git(root, 'diff', '--cached', '--quiet', check=False)
    if result.returncode not in (0, 1):
        raise SaveError('Could not inspect staged changes.')
    return result.returncode == 1


def private_boundary(root: Path, *, push_only: bool, revision: str = 'HEAD') -> None:
    if output(root, 'ls-files', '--', 'internal'):
        raise SaveError('App Git tracks internal content; remove it from the app index first.')
    sources = [output(root, 'show', ':.gitignore'), (root / '.gitignore').read_text()]
    if push_only:
        sources.append(output(root, 'show', f'{revision}:.gitignore'))
    if any('/internal/' not in source.splitlines() for source in sources):
        raise SaveError('Keep /internal/ in the tracked app .gitignore and stage that rule before saving.')
    ignored = git(root, 'check-ignore', '--quiet', '--no-index', 'internal/', check=False)
    if ignored.returncode != 0:
        raise SaveError('The app ignore rules must exclude internal/.')
    # A deletion commit still publishes its ancestors. Inspect each commit
    # not already recorded in an origin branch, rather than only the index.
    revisions = output(root, 'rev-list', revision, '--not', '--remotes=origin').splitlines()
    revisions.append(output(root, 'rev-parse', revision))
    for revision in dict.fromkeys(revisions):
        if output(root, 'ls-tree', '-r', '--name-only', revision, '--', 'internal'):
            raise SaveError('App commit history contains internal content; remove those unpublished commits before pushing.')


def repository(root: Path, expected_remote: str) -> str:
    if not (root / '.git').exists() or root.is_symlink():
        raise SaveError(f'{root.name}: expected an independent Git checkout.')
    if Path(output(root, 'rev-parse', '--show-toplevel')).resolve() != root:
        raise SaveError(f'{root.name}: expected an independent Git checkout.')
    branch = output(root, 'symbolic-ref', '--quiet', '--short', 'HEAD')
    for marker in ('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD',
                   'rebase-merge', 'rebase-apply', 'sequencer'):
        path = Path(output(root, 'rev-parse', '--git-path', marker))
        if not path.is_absolute():
            path = root / path
        if path.exists():
            raise SaveError(f'{root.name}: finish the active Git operation first.')
    if output(root, 'ls-files', '--unmerged'):
        raise SaveError(f'{root.name}: resolve unmerged files first.')
    for flags in (('--all',), ('--push', '--all')):
        if output(root, 'remote', 'get-url', *flags, 'origin').splitlines() != [expected_remote]:
            raise SaveError(f'{root.name}: origin differs from the configured save destination.')
    return branch


@contextmanager
def save_lock(root: Path):
    directory = Path(output(root, 'rev-parse', '--git-common-dir'))
    if not directory.is_absolute():
        directory = root / directory
    with (directory / 'wing-save.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise SaveError('Another Wing save is running; wait for it to finish.') from error
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def save(root: Path, message: str | None, *, commit_only: bool = False,
         push_only: bool = False) -> None:
    root = root.resolve(strict=True)
    internal = root / 'internal'
    status = {'app': 'unchanged', 'internal': 'unchanged',
              'Gitea': 'not attempted', 'GitHub': 'not attempted'}
    try:
        with save_lock(root):
            app_remote = output(root, 'config', '--local', '--get', 'wing.appRemote')
            internal_remote = output(root, 'config', '--local', '--get', 'wing.internalRemote')
            if not app_remote or not internal_remote or app_remote == internal_remote:
                raise SaveError('Configure distinct wing.appRemote and wing.internalRemote destinations first.')
            app_branch = repository(root, app_remote)
            internal_branch = repository(internal, internal_remote)
            private_boundary(root, push_only=push_only)
            app_sha = output(root, 'rev-parse', '--verify', 'HEAD')
            if not push_only:
                if not message or not message.strip():
                    raise SaveError('Supply a nonempty commit message.')
                if changed(root):
                    git(root, 'commit', '-m', message)
                    app_sha = output(root, 'rev-parse', '--verify', 'HEAD')
                    status['app'] = f'committed {app_sha[:12]}'
                private_boundary(root, push_only=True, revision=app_sha)
                git(internal, 'add', '-A', '--', '.')
                if changed(internal):
                    git(internal, 'commit', '-m', message,
                        '-m', f'Wing-Commit: {app_sha}')
                    status['internal'] = f'committed {output(internal, "rev-parse", "HEAD")[:12]}'
            internal_sha = output(internal, 'rev-parse', '--verify', 'HEAD')
            if not commit_only:
                # Push only captured commits to explicit branches, even when
                # another tool commits while the network request is running.
                status['Gitea'] = 'push not confirmed'
                git(internal, '-c', 'push.followTags=false', 'push', '--porcelain', internal_remote,
                    f'{internal_sha}:refs/heads/{internal_branch}')
                status['Gitea'] = f'pushed {internal_sha[:12]}'
                status['GitHub'] = 'push not confirmed'
                git(root, '-c', 'push.followTags=false', 'push', '--porcelain', app_remote,
                    f'{app_sha}:refs/heads/{app_branch}')
                status['GitHub'] = f'pushed {app_sha[:12]}'
    finally:
        for name, result in status.items():
            print(f'{name}: {result}', flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('message', nargs='?', help='Commit message for both repositories')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--commit-only', action='store_true', help='Commit both repositories without pushing')
    mode.add_argument('--push-only', action='store_true', help='Retry pushing existing commits without committing edits')
    args = parser.parse_args()
    if not args.push_only and not args.message:
        parser.error('Supply a commit message, or use --push-only.')
    if args.push_only and args.message:
        parser.error('--push-only takes no commit message.')
    try:
        save(Path(__file__).resolve().parents[1], args.message,
             commit_only=args.commit_only, push_only=args.push_only)
    except (SaveError, OSError) as error:
        print(f'Save stopped: {error}\nCompleted commits remain local. Fix the problem and retry; '
              'use --push-only when only publication remains.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

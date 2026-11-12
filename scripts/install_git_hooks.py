#!/usr/bin/env python3
"""Enable the tracked Wing pre-commit hook in this local repository."""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--toolchain-env', type=Path,
                        help='Shell environment file for this machine only')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    actual = subprocess.check_output(
        ['git', '-C', str(root), 'rev-parse', '--show-toplevel'], text=True).strip()
    if Path(actual).resolve() != root:
        parser.error('Run the installer from an actual Wing checkout.')
    existing = subprocess.run(
        ['git', '-C', str(root), 'config', '--get', 'core.hooksPath'],
        capture_output=True, text=True).stdout.strip()
    if existing and existing != '.githooks':
        parser.error('Another hooksPath is configured; reconcile it before installation.')
    default_hook = Path(subprocess.check_output(
        ['git', '-C', str(root), 'rev-parse', '--git-path', 'hooks/pre-commit'],
        text=True).strip())
    if not default_hook.is_absolute():
        default_hook = root / default_hook
    if not existing and default_hook.exists():
        parser.error('An existing pre-commit hook needs reconciliation before installation.')
    if args.toolchain_env:
        environment = args.toolchain_env.resolve(strict=True)
        if not environment.is_file():
            parser.error('--toolchain-env must name a shell environment file.')
        subprocess.run(['git', '-C', str(root), 'config', '--local',
                        'wing.toolchainEnv', str(environment)], check=True)
    hook = root / '.githooks/pre-commit'
    hook.chmod(hook.stat().st_mode | 0o111)
    subprocess.run(['git', '-C', str(root), 'config', '--local',
                    'core.hooksPath', '.githooks'], check=True)
    print('Wing pre-commit linters enabled for all branches in this repository.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

#!/usr/bin/env python3
"""Parsed canonical voice permission lifecycle dispatch; OS ordering stays behavioral."""
import argparse
from pathlib import Path
import subprocess
import sys
from file_api_boundary import ROOT, SOURCE as PARSER_SOURCE, command

SOURCE = Path(__file__).with_name('VoicePermissionLifecycleGuard.kt')
ID = 'NATIVE_VOICE_PERMISSION_LIFECYCLE'


def lifecycle_command():
    return command(source=SOURCE, companions=(PARSER_SOURCE,),
                   main_class='VoicePermissionLifecycleGuard',
                   cache_name='native-voice-permission-guard')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, action='append')
    args = parser.parse_args()
    native = ROOT / 'android/app/src/main/kotlin/com/tarkilhk/wing'
    sources = args.source or [native / (name + '.kt') for name in ['MainActivity', 'VoiceChannel']]
    try:
        return subprocess.run(lifecycle_command() + list(map(str, sources))).returncode
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'[{ID}] Invalid input: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())

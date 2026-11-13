"""Generate Wing titles from the inspected upstream desktop English catalog.

Usage: python3 tools/generate_tool_labels.py /path/to/apps/desktop/src/i18n/en.ts COMMIT
No network or backend modifications. Review regenerated changes before adopting.
"""
from pathlib import Path
import json
import re
import sys


def main():
    source, commit = sys.argv[1:]
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('A full inspected upstream commit is required')
    block = Path(source).read_text().split('      titles: {', 1)[1].split('\n      }', 1)[0]
    entries = re.findall(r"(\w+):\s*\{\s*done:\s*'([^']*)',\s*pending:\s*'([^']*)'", block)
    declared = re.findall(r'(\w+):\s*\{', block)
    if not entries or set(declared) != {entry[0] for entry in entries}:
        raise ValueError('Desktop title format changed; inspect before regenerating')
    rows = [
        '// Generated from Hermes desktop assistant.tool.titles, upstream commit',
        f'// {commit}. Do not edit by hand.',
        '// Regenerate with tools/generate_tool_labels.py <en.ts> <commit>.',
        'const desktopToolLabels = <String, ({String done, String pending})>{',
    ]
    def quote(value):
        # JSON escaping is also valid inside these double-quoted Dart literals.
        return json.dumps(value).replace('$', r'\$')

    for name, done, pending in entries:
        rows.append(f'  {quote(name)}: (done: {quote(done)}, pending: {quote(pending)}),')
    rows.append('};\n')
    target = Path(__file__).resolve().parents[1] / 'lib/core/presentation/desktop_tool_labels.dart'
    target.write_text('\n'.join(rows))


if __name__ == '__main__':
    main()

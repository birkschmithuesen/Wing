#!/usr/bin/env python3
"""Prevent reintroducing the retired synthetic recovery ledger into the fixture."""
from __future__ import annotations

import argparse
import ast
from pathlib import Path

ID = "FIXTURE_RETIRED_RECOVERY"
DIRECTORY = "tools/fake_gateway"
MODULE = "turn_recovery_contract"


def check(root: Path) -> list[str]:
    directory = root / DIRECTORY
    if not directory.is_dir():
        raise ValueError("Missing owned fixture directory")
    failures = []
    if (directory / f"{MODULE}.py").exists():
        failures.append(f"{DIRECTORY}/{MODULE}.py {ID}: remove the retired ledger")
    for path in sorted(directory.rglob("*.py")):
        tree = ast.parse(path.read_text())
        for node in ast.walk(tree):
            canonical = {MODULE, f"tools.fake_gateway.{MODULE}"}
            retired_import = isinstance(node, ast.Import) and any(
                alias.name in canonical for alias in node.names)
            if isinstance(node, ast.ImportFrom):
                module = node.module or ""
                if node.level:
                    package = path.relative_to(root).parent.parts
                    keep = len(package) - node.level + 1
                    module = '.'.join((*package[:max(0, keep)], module)).rstrip('.')
                retired_import = (
                    module in canonical
                    or (module == "tools.fake_gateway"
                        and any(alias.name == MODULE for alias in node.names))
                )
            if retired_import:
                failures.append(f"{path.relative_to(root)}:{node.lineno} {ID}: remove retired protocol import")
    return sorted(set(failures))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    try:
        failures = check(args.root)
    except (OSError, SyntaxError, ValueError) as error:
        print(f"{ID}_INPUT: {error}")
        return 2
    for failure in failures:
        print(failure)
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(main())

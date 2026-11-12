#!/usr/bin/env python3
"""Require the authored checkout census to name every present Git-visible file.

This checks scope coverage, not liveness or executable-root completeness.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path, PurePosixPath
import subprocess

ID = "ARCH_AUTHORED_CENSUS"
MANIFEST = "tools/architecture/roots.json"
ROOT_EXCLUDED = {".git", "build", ".dart_tool"}
NESTED_EXCLUDED = {"node_modules", "__pycache__"}


def authored_files(root: Path) -> set[str]:
    root = root.resolve(strict=True)
    repository = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--show-toplevel"],
        capture_output=True, check=True,
    ).stdout.decode().removesuffix("\n")
    if Path(repository).resolve() != root:
        raise ValueError("--root must identify the application checkout itself")
    output = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--cached", "--others",
         "--exclude-standard", "-z"],
        capture_output=True, check=True,
    ).stdout
    result = set()
    for raw in output.split(b"\0"):
        if not raw:
            continue
        path = raw.decode()
        parts = PurePosixPath(path).parts
        if (parts[0] in ROOT_EXCLUDED and len(parts) > 1
                or any(part in NESTED_EXCLUDED for part in parts[:-1])):
            continue
        # Tracked deletion remains in the index until the eventual commit.
        # A symlink is authored even when its target is intentionally missing.
        absolute = root / path
        if absolute.is_symlink() or absolute.is_file():
            result.add(path)
        elif absolute.exists():
            raise ValueError("Git entry is not an authored file")
    return result


def check(root: Path) -> list[str]:
    document = json.loads((root / MANIFEST).read_text())
    if (not isinstance(document, dict) or type(document.get("schema")) is not int
            or document["schema"] != 1):
        raise ValueError("Expected census schema 1")
    files = document.get("files")
    if not isinstance(files, list):
        raise ValueError("Expected authored files list")
    declared = set()
    failures = []
    for entry in files:
        path = entry.get("path") if isinstance(entry, dict) else None
        if (not isinstance(path, str) or not path or "\\" in path or "\0" in path
                or path != PurePosixPath(path).as_posix()
                or PurePosixPath(path).is_absolute()
                or any(part in {".", ".."} for part in path.split("/"))):
            raise ValueError("Expected canonical checkout-relative file paths")
        if path in declared:
            failures.append(f"{MANIFEST}:1 [{ID}] duplicate: {_display(path)}")
        declared.add(path)
    actual = authored_files(root)
    failures.extend(f"{MANIFEST}:1 [{ID}] missing: {_display(path)}"
                    for path in actual - declared)
    failures.extend(f"{MANIFEST}:1 [{ID}] stale: {_display(path)}"
                    for path in declared - actual)
    return sorted(failures)


def _display(path: str) -> str:
    return path if path.isprintable() else json.dumps(path, ensure_ascii=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    try:
        failures = check(args.root)
    except (OSError, ValueError, UnicodeError, subprocess.CalledProcessError):
        # Do not echo arbitrary malformed manifest values or Git diagnostics.
        print(f"{MANIFEST}:1 [{ID}_INPUT] Invalid census or checkout input.")
        return 2
    for failure in failures:
        print(failure)
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(main())

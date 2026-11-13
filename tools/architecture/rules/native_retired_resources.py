#!/usr/bin/env python3
"""Reject three retired Android resource paths and preserve launcher bindings."""
from __future__ import annotations

import argparse
from pathlib import Path
import xml.etree.ElementTree as ET

ID = "ARCH_NATIVE_RETIRED_RESOURCES"
MANIFEST = "android/app/src/main/AndroidManifest.xml"
ANDROID = "{http://schemas.android.com/apk/res/android}"
RETIRED = (
    "android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml",
    "android/app/src/main/res/mipmap-anydpi-v33/ic_launcher_round.xml",
    "android/app/src/main/res/drawable-v21/launch_background.xml",
)


def check(root: Path) -> list[str]:
    manifest = ET.fromstring((root / MANIFEST).read_text())
    applications = manifest.findall("application")
    if manifest.tag != "manifest" or len(applications) != 1:
        raise ValueError("Invalid manifest structure")
    failures = []
    application = applications[0]
    for attribute in ("icon", "roundIcon"):
        if application.get(ANDROID + attribute) != "@mipmap/ic_launcher":
            failures.append(f"{MANIFEST}:1 [{ID}] {attribute} must bind @mipmap/ic_launcher")
    for relative in RETIRED:
        path = root / relative
        if path.exists() or path.is_symlink():
            failures.append(f"{relative}:1 [{ID}] remove retired resource")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    try:
        failures = check(args.root)
    except (OSError, UnicodeError, ET.ParseError, ValueError):
        print(f"{ID}_INPUT: invalid Android manifest source")
        return 2
    for failure in failures:
        print(failure)
    print(f"{ID}: {len(failures)} findings")
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(main())

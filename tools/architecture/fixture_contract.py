"""Fail closed when an executable checker proof loses its test cases."""
import json
from pathlib import Path


def require(condition, detail="Checker proof failed"):
    """Proof verdicts must survive Python's -O and PYTHONOPTIMIZE modes."""
    if not condition:
        raise AssertionError(detail)


def read_cases(path, *, required_exits=(0, 1, 2), required_names=()):
    cases = json.loads(Path(path).read_text())["cases"]
    return validate_cases(cases, required_exits=required_exits,
                          required_names=required_names)


def validate_cases(cases, *, required_exits=(0, 1, 2), required_names=()):
    if not isinstance(cases, list) or not cases:
        raise ValueError("Checker proof requires a nonempty case list")
    names, exits = set(), set()
    for case in cases:
        if not isinstance(case, dict):
            raise ValueError("Checker proof case must be an object")
        name, status = case.get("name"), case.get("exit")
        if not isinstance(name, str) or not name.strip() or name in names:
            raise ValueError("Checker proof case names must be nonempty and unique")
        if type(status) is not int or status not in (0, 1, 2):
            raise ValueError(f"{name}: expected an explicit exit 0, 1 or 2")
        names.add(name)
        exits.add(status)
    if missing := set(required_exits) - exits:
        raise ValueError(f"Checker proof is missing exit categories: {sorted(missing)}")
    if missing := set(required_names) - names:
        raise ValueError(f"Checker proof is missing CLI representatives: {sorted(missing)}")
    return cases

"""Reject invented slot names in scheduled-task template submissions."""
import sys

from _task_blueprint_contract import run_cli

ID = "STOCK_TASK_BLUEPRINT_SLOT"


def check(payload, catalog):
    """Check names only; valid values and default/optional semantics stay server authoritative."""
    submissions = payload["submissions"]
    if not isinstance(submissions, list):
        raise ValueError("submissions must be a list")
    problems = []
    for submission in submissions:
        key = submission["blueprint"]
        values = submission["values"]
        if not isinstance(key, str) or not isinstance(values, dict):
            raise ValueError("Each submission requires a blueprint key and values object")
        if key not in catalog:
            problems.append(f"{key}: blueprint is absent from pinned stock")
            continue
        names = {field["name"] for field in catalog[key]["fields"]}
        for name in values.keys() - names:
            problems.append(f"{key}.{name}: slot is absent from pinned stock; remove it")
    return problems


if __name__ == "__main__":
    sys.exit(run_cli(check, ID))

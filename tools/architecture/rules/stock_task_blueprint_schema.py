"""Reject scheduled-task fixture form schemas that differ from pinned stock."""
import copy
import sys

from _task_blueprint_contract import run_cli

ID = "STOCK_TASK_BLUEPRINT_SCHEMA"


def check(payload, catalog):
    """Check the full advertised catalog, allowing declared dynamic delivery options."""
    rows = payload["blueprints"]
    if not isinstance(rows, list):
        raise ValueError("blueprints must be a list")
    expected = copy.deepcopy(catalog)
    if "delivery_targets" in payload:
        targets = payload["delivery_targets"]
        if not isinstance(targets, list) or any(not isinstance(value, str) or not value for value in targets):
            raise ValueError("delivery_targets must contain nonempty platform IDs")
        if len(targets) != len(set(targets)):
            raise ValueError("delivery_targets must be unique")
        options = ["origin", "local", *(target for target in targets if target != "local")]
        for blueprint in expected.values():
            for field in blueprint["fields"]:
                if field["name"] == "deliver":
                    field["options"] = options
    problems = []
    seen = set()
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("key"), str):
            raise ValueError("Each blueprint requires a string key")
        key = row["key"]
        if key in seen:
            problems.append(f"{key}: duplicate blueprint")
        seen.add(key)
        if key not in expected:
            problems.append(f"{key}: blueprint is absent from pinned stock")
            continue
        # Stock emits extra schedule/command/deep-link rendering fields. Those
        # are outside this form-schema property and may remain in the response.
        actual = {name: row[name] for name in expected[key] if name in row}
        if actual != expected[key]:
            problems.append(f"{key}: use the pinned stock form schema")
    for key in expected.keys() - seen:
        problems.append(f"{key}: missing stock blueprint")
    return problems


if __name__ == "__main__":
    sys.exit(run_cli(check, ID))

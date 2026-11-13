"""Small shared data loader for independent offline stock-contract guards."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ARTIFACT = Path(__file__).resolve().parents[2] / "contracts/hermes_task_blueprints.json"


def load_catalog(path=ARTIFACT):
    artifact = json.loads(Path(path).read_text())
    rows = artifact["blueprints"]
    if not isinstance(rows, list) or not rows:
        raise ValueError("Pinned blueprint projection must be a nonempty list")
    for row in rows:
        if not isinstance(row, dict) or set(row) != {"key", "title", "description", "category", "tags", "fields"}:
            raise ValueError("Pinned blueprint row has invalid form-schema properties")
        if any(not isinstance(row[name], str) or not row[name] for name in ("key", "title", "description", "category")):
            raise ValueError("Pinned blueprint metadata requires nonempty strings")
        if not isinstance(row["tags"], list) or any(not isinstance(tag, str) for tag in row["tags"]):
            raise ValueError("Pinned blueprint tags must be strings")
        fields = row["fields"]
        if not isinstance(fields, list) or not fields:
            raise ValueError("Pinned blueprint fields must be a nonempty list")
        names = []
        for field in fields:
            if not isinstance(field, dict) or set(field) != {"name", "type", "label", "default", "options", "optional", "strict", "help"}:
                raise ValueError("Pinned blueprint field has invalid properties")
            if any(not isinstance(field[name], str) for name in ("name", "type", "label", "help")) or not field["name"]:
                raise ValueError("Pinned blueprint field metadata requires strings")
            if field["default"] is not None and not isinstance(field["default"], str):
                raise ValueError("Pinned blueprint defaults must be strings or null")
            if type(field["optional"]) is not bool or type(field["strict"]) is not bool:
                raise ValueError("Pinned blueprint field flags must be booleans")
            if not isinstance(field["options"], list) or any(not isinstance(option, str) for option in field["options"]):
                raise ValueError("Pinned blueprint field options must be strings")
            names.append(field["name"])
        if len(names) != len(set(names)):
            raise ValueError("Pinned blueprint slot names must be unique")
    projection = json.dumps(rows, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    if artifact["schema"] != 1 or hashlib.sha256(projection.encode()).hexdigest() != artifact["provenance"]["projection_sha256"]:
        raise ValueError("Pinned blueprint projection hash does not match")
    keys = [row["key"] for row in rows]
    if len(keys) != len(set(keys)):
        raise ValueError("Pinned blueprint keys must be unique")
    return {row["key"]: row for row in rows}


def run_cli(check, diagnostic):
    parser = argparse.ArgumentParser(description=check.__doc__)
    parser.add_argument("--input", required=True, help="JSON input path, or - for stdin")
    parser.add_argument("--catalog", type=Path, default=ARTIFACT)
    args = parser.parse_args()
    try:
        payload = json.load(sys.stdin) if args.input == "-" else json.loads(Path(args.input).read_text())
        problems = sorted(check(payload, load_catalog(args.catalog)))
        for problem in problems:
            print(f"[{diagnostic}] {problem}")
        return 1 if problems else 0
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f"[{diagnostic} INPUT] Invalid contract input: {error}", file=sys.stderr)
        return 2

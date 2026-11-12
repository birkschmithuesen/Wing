#!/usr/bin/env python3
"""Check the literal model-options catalog emitted by the local gateway fixture."""
from __future__ import annotations

import argparse
import ast
from pathlib import Path

ID = "FIXTURE_MODEL_CATALOG"
SOURCE = "tools/fake_gateway/fake_gateway.py"


def check_source(source: str) -> list[str]:
    tree = ast.parse(source)
    aliases = {
        alias.asname or alias.name
        for node in tree.body
        if isinstance(node, ast.ImportFrom) and node.module == "aiohttp"
        for alias in node.names if alias.name == "web"
    }
    functions = [node for node in tree.body
                 if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
                 and node.name == "model_options"]
    if len(functions) != 1:
        raise ValueError("Expected one model_options fixture function")
    returns = [node for node in ast.walk(functions[0])
               if isinstance(node, ast.Return) and isinstance(node.value, ast.Call)
               and isinstance(node.value.func, ast.Attribute)
               and isinstance(node.value.func.value, ast.Name)
               and node.value.func.value.id in aliases
               and node.value.func.attr == "json_response"]
    if len(returns) != 1 or len(returns[0].value.args) != 1:
        raise ValueError("Expected one literal catalog response")
    catalog = ast.literal_eval(returns[0].value.args[0])
    rows = catalog.get("providers") if isinstance(catalog, dict) else None
    if not isinstance(rows, list):
        return [f"{ID}: providers must be a list"]
    failures = []
    for index, row in enumerate(rows):
        if (not isinstance(row, dict)
                or not isinstance(row.get("slug"), str) or not row["slug"].strip()
                or not isinstance(row.get("name"), str)
                or not isinstance(row.get("models"), list)
                or any(not isinstance(value, str) or not value.strip()
                       for value in row["models"])):
            failures.append(f"{ID}: provider[{index}] requires slug/name and string model IDs")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    try:
        failures = check_source((args.root / SOURCE).read_text())
    except (OSError, SyntaxError, ValueError, TypeError) as error:
        print(f"{SOURCE} {ID}_INPUT: {error}")
        return 2
    for failure in failures:
        print(f"{SOURCE} {failure}")
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(main())

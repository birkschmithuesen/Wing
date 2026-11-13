"""Mandatory offline-QA entry point for the two independent blueprint guards."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ARTIFACT = ROOT / "tools/contracts/hermes_task_blueprints.json"


class TaskBlueprintQualityGateTest(unittest.TestCase):
    def test_independent_rule_fixtures_propagate_cli_failures(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "tools/architecture/tests/test_task_blueprint_guards.py"), "-v"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_malformed_inputs_fail_closed_without_tracebacks(self):
        cases = {
            "schema": [{}, {"blueprints": None}, {"blueprints": [{}]}],
            "slots": [{}, {"submissions": [{}]}, {"submissions": [{"blueprint": "morning-brief"}]}],
        }
        for kind, inputs in cases.items():
            for payload in inputs:
                with self.subTest(kind=kind, payload=payload):
                    result = subprocess.run(
                        [sys.executable, str(ROOT / f"tools/architecture/rules/stock_task_blueprint_{kind}.py"), "--input", "-"],
                        input=json.dumps(payload), capture_output=True, text=True, check=False,
                    )
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assertIn("INPUT]", result.stderr)
                    self.assertNotIn("Traceback", result.stderr)

    def test_invalid_artifact_fails_both_rules_closed(self):
        source = json.loads(ARTIFACT.read_text())
        corrupt = copy.deepcopy(source)
        corrupt["blueprints"][0]["fields"][0]["optional"] = "false"
        # Schema corruption must fail even if its projection hash is rewritten.
        import hashlib
        projection = json.dumps(corrupt["blueprints"], ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        corrupt["provenance"]["projection_sha256"] = hashlib.sha256(projection.encode()).hexdigest()
        for artifact in ({}, {**source, "schema": 2}, corrupt):
            with tempfile.TemporaryDirectory(prefix="wing-blueprint-qa-") as directory:
                path = Path(directory) / "catalog.json"
                path.write_text(json.dumps(artifact))
                for kind in ("schema", "slots"):
                    with self.subTest(kind=kind, artifact=artifact.get("schema")):
                        result = subprocess.run(
                            [sys.executable, str(ROOT / f"tools/architecture/rules/stock_task_blueprint_{kind}.py"), "--input", "-", "--catalog", str(path)],
                            input="{}", capture_output=True, text=True, check=False,
                        )
                        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                        self.assertIn("INPUT]", result.stderr)
                        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()

"""Exercise each independent guard's real CLI with minimal bad/valid mutations."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
ARTIFACT = ROOT / "tools/contracts/hermes_task_blueprints.json"
sys.path.insert(0, str(ROOT))
from tools.architecture.fixture_contract import validate_cases

FIXTURES = ROOT / "tools/architecture/fixtures/task_blueprints.fixture.json"


class TaskBlueprintGuardsTest(unittest.TestCase):
    def test_independent_cli_fixtures(self):
        rows = json.loads(ARTIFACT.read_text())["blueprints"]
        cases = json.loads(FIXTURES.read_text())
        self.assertEqual(set(cases), {"schema", "slots"}, "Both independent guards require proofs")
        for kind, fixtures in cases.items():
            for fixture in validate_cases(fixtures, required_exits=(0, 1)):
                with self.subTest(kind=kind, fixture=fixture["name"]):
                    if kind == "schema":
                        payload = {"blueprints": copy.deepcopy(rows)}
                        morning = next(row for row in payload["blueprints"] if row["key"] == "morning-brief")
                        if "field" in fixture:
                            morning["fields"].append(fixture["field"])
                        if "default" in fixture:
                            morning["fields"][0]["default"] = fixture["default"]
                        if "optional" in fixture:
                            morning["fields"][0]["optional"] = fixture["optional"]
                        if "delivery_targets" in fixture:
                            payload["delivery_targets"] = fixture["delivery_targets"]
                            for row in payload["blueprints"]:
                                for field in row["fields"]:
                                    if field["name"] == "deliver":
                                        field["options"] = ["origin", *fixture["delivery_targets"]]
                    else:
                        payload = {"submissions": fixture["submissions"]}
                    result = subprocess.run(
                        [sys.executable, str(ROOT / f"tools/architecture/rules/stock_task_blueprint_{kind}.py"), "--input", "-"],
                        input=json.dumps(payload), capture_output=True, text=True, check=False,
                    )
                    self.assertEqual(result.returncode, fixture["exit"], result.stdout + result.stderr)
                    if fixture["exit"] == 1:
                        diagnostic = "STOCK_TASK_BLUEPRINT_SCHEMA" if kind == "schema" else "STOCK_TASK_BLUEPRINT_SLOT"
                        self.assertIn(f"[{diagnostic}]", result.stdout)


if __name__ == "__main__":
    unittest.main()

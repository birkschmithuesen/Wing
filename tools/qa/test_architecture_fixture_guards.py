"""Offline positive, negative and actual CLI proofs for focused fixture guards."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tools.architecture.rules import fixture_model_catalog as catalog
from tools.architecture.rules import retired_fixture_recovery as recovery


def source(rows, alias="web"):
    return (f"from aiohttp import web as {alias}\n"
            "async def model_options(request):\n"
            f"    return {alias}.json_response({{'providers': {rows!r}}})\n")


class FixtureGuardChecks(unittest.TestCase):
    def test_owned_fixture_current_catalog(self):
        checkout = Path(__file__).resolve().parents[2]
        self.assertEqual(catalog.check_source((checkout / catalog.SOURCE).read_text()), [])

    def test_owned_fixture_has_no_retired_recovery(self):
        checkout = Path(__file__).resolve().parents[2]
        self.assertEqual(recovery.check(checkout), [])

    def test_current_catalog_variants_and_import_alias_are_valid(self):
        rows = [{"slug": "built-in", "name": "Built in", "models": ["org/model"]},
                {"slug": "custom", "name": "Custom", "models": []}]
        self.assertEqual(catalog.check_source(source(rows, "response")), [])

    def test_unrelated_same_named_data_is_ignored(self):
        text = source([]) + "\nother = {'models': [{'id': 'unrelated'}]}\n"
        self.assertEqual(catalog.check_source(text), [])

    def test_old_aliases_map_models_and_nonstrings_fail(self):
        for row in [
            {"id": "p", "name": "P", "models": ["m"]},
            {"slug": "p", "title": "P", "models": ["m"]},
            {"slug": "p", "name": "P", "models": [{"id": "m"}]},
            {"slug": "p", "name": "P", "models": [24]},
            {"slug": "", "name": "P", "models": ["m"]},
        ]:
            with self.subTest(row=row):
                self.assertIn(catalog.ID, catalog.check_source(source([row]))[0])

    def test_nonliteral_catalog_requires_explicit_guard_adaptation(self):
        with self.assertRaises(ValueError):
            catalog.check_source("from aiohttp import web\n"
                                 "async def model_options(request):\n"
                                 "    return web.json_response(computed_catalog)\n")

    def test_canonical_retired_import_spellings_fail(self):
        for statement in [
            "import turn_recovery_contract as ledger",
            "from .turn_recovery_contract import TurnRecoveryContractLedger as Ledger",
            "from . import turn_recovery_contract as ledger",
            "import tools.fake_gateway.turn_recovery_contract as ledger",
            "from tools.fake_gateway import turn_recovery_contract",
        ]:
            with self.subTest(statement=statement), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                path = root / recovery.DIRECTORY / "fake_gateway.py"
                path.parent.mkdir(parents=True)
                path.write_text(statement)
                self.assertIn(recovery.ID, recovery.check(root)[0])

    def test_unrelated_module_and_negative_rpc_probe_are_valid(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / recovery.DIRECTORY / "test_fake_gateway.py"
            path.parent.mkdir(parents=True)
            path.write_text("from unrelated import turn_recovery_contract\n"
                            "import unrelated.turn_recovery_contract\n"
                            "retired_method = 'session.open'\n")
            self.assertEqual(recovery.check(root), [])

    def test_nested_fixture_module_cannot_hide_a_retired_import(self):
        for statement in [
            'from tools.fake_gateway.turn_recovery_contract import Ledger',
            'from ..turn_recovery_contract import Ledger',
            'from .. import turn_recovery_contract',
        ]:
            with self.subTest(statement=statement), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                path = root / recovery.DIRECTORY / 'support' / 'fixture.py'
                path.parent.mkdir(parents=True)
                path.write_text(statement)
                self.assertTrue(recovery.check(root), 'Nested fixture files remain in guard scope')

    def test_nested_relative_homonym_is_not_the_retired_root_module(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / recovery.DIRECTORY / 'support' / 'fixture.py'
            path.parent.mkdir(parents=True)
            path.write_text('from . import turn_recovery_contract\n')
            self.assertEqual(recovery.check(root), [])

    def test_actual_cli_bad_valid_and_input_error_exits(self):
        checkout = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / catalog.SOURCE
            fixture.parent.mkdir(parents=True)
            for module, contents, expected in [
                (catalog, source([{"slug": "p", "name": "P", "models": [{"id": "m"}]}]), 1),
                (catalog, source([]), 0),
                (catalog, "broken syntax (", 2),
                (recovery, "from .turn_recovery_contract import Ledger", 1),
                (recovery, "retired_method = 'session.open'", 0),
                (recovery, "broken syntax (", 2),
            ]:
                fixture.write_text(contents)
                command = checkout / "tools/architecture/rules" / f"{module.__name__.split('.')[-1]}.py"
                result = subprocess.run([sys.executable, str(command), "--root", str(root)],
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                if expected:
                    self.assertIn(module.ID, result.stdout)

    def test_retired_file_reintroduction_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / recovery.DIRECTORY / f"{recovery.MODULE}.py"
            path.parent.mkdir(parents=True)
            path.write_text("# retired implementation")
            self.assertIn(recovery.ID, recovery.check(root)[0])


if __name__ == "__main__":
    unittest.main()

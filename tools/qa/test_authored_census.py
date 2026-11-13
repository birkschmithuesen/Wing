"""Real CLI scope-census regressions; never a whole-program liveness proof."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from tools.architecture.rules import authored_census as census


class AuthoredCensusChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wing-census-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.write(".gitignore", "/build/\n/ignored/\n")
        self.write("lib/main.dart", "void main() {}\n")
        self.write("test/example_test.dart", "void main() {}\n")
        self.manifest = self.root / census.MANIFEST
        self.manifest.parent.mkdir(parents=True)
        self.record()

    def write(self, path, contents):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents)
        return target

    def record(self):
        self.manifest.write_text(json.dumps({"schema": 1, "files": [
            {"path": path} for path in sorted(
                census.authored_files(self.root) | {census.MANIFEST})
        ]}))

    def cli(self, expected):
        script = Path(census.__file__).resolve()
        result = subprocess.run(
            [sys.executable, str(script), "--root", str(self.root)],
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout

    def test_complete_tracked_and_untracked_census_is_valid(self):
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        self.write("tools/new tool.py", "pass\n")
        self.record()
        self.cli(0)

    def test_missing_authored_file_fails_exact_cli_and_repairs(self):
        self.write(".github/workflows/new.yml", "name: New\n")
        output = self.cli(1)
        self.assertIn(f":1 [{census.ID}] missing: .github/workflows/new.yml", output)
        self.record()
        self.cli(0)

    def test_deleted_tracked_file_is_stale_until_census_is_updated(self):
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        (self.root / "lib/main.dart").unlink()
        self.assertIn("stale: lib/main.dart", self.cli(1))
        self.record()
        self.cli(0)

    def test_ignored_generated_and_cache_outputs_are_not_authored(self):
        for path in ["build/output.bin", ".dart_tool/generated.dart",
                     "tools/node_modules/dependency.js", "ignored/local.txt",
                     "tools/__pycache__/example.pyc"]:
            self.write(path, "output\n")
        self.cli(0)

    def test_manifest_exclusion_cannot_hide_authored_source(self):
        self.write("lib/hidden.dart", "void helper() {}\n")
        value = json.loads(self.manifest.read_text())
        value["scope"] = {"exclude": ["lib/**"]}
        self.manifest.write_text(json.dumps(value))
        self.assertIn("missing: lib/hidden.dart", self.cli(1))

    def test_nested_build_name_is_legitimate_authored_source(self):
        self.write("tools/build/review.py", "pass\n")
        self.assertIn("missing: tools/build/review.py", self.cli(1))
        self.record()
        self.cli(0)

    def test_regular_file_cache_names_are_authored(self):
        for path in ["tools/node_modules", "tools/__pycache__", "build"]:
            with self.subTest(path=path):
                target = self.write(path, "authored input\n")
                # The intentionally broad Git ignore would otherwise ignore
                # a root file called build too; tracked inputs remain visible.
                subprocess.run(["git", "-C", str(self.root), "add", "-f", path],
                               check=True)
                self.assertIn(f"missing: {path}", self.cli(1))
                self.record()
                self.cli(0)
                self.assertTrue(target.is_file())

    def test_trailing_space_checkout_path_is_supported(self):
        spaced = Path(self.temporary.name + " ")
        self.root.rename(spaced)
        self.addCleanup(shutil.rmtree, spaced)
        self.root = spaced
        self.manifest = self.root / census.MANIFEST
        self.cli(0)

    def test_control_character_filename_diagnostic_is_escaped(self):
        self.write("tools/name\ncontinued.py", "pass\n")
        output = self.cli(1)
        self.assertEqual(len(output.splitlines()), 1)
        self.assertIn(r"name\ncontinued.py", output)
        self.record()
        self.cli(0)

    def test_duplicate_census_entry_fails(self):
        value = json.loads(self.manifest.read_text())
        value["files"].append(value["files"][0])
        self.manifest.write_text(json.dumps(value))
        self.assertIn("duplicate:", self.cli(1))

    def test_broken_symlink_is_still_authored(self):
        (self.root / "supported-link").symlink_to("missing-target")
        self.assertIn("missing: supported-link", self.cli(1))
        self.record()
        self.cli(0)

    def test_malformed_or_escaping_input_fails_closed(self):
        for value in ["{", "[]", json.dumps({"schema": 2}),
                      json.dumps({"schema": True, "files": []}),
                      json.dumps({"schema": 1, "files": [{"path": "bad\0path"}]}),
                      json.dumps({"schema": 1, "files": [{"path": "../outside"}]}),
                      json.dumps({"schema": 1, "files": [{"path": "/absolute"}]}),
                      json.dumps({"schema": 1, "files": [{"path": "lib//main.dart"}]})]:
            with self.subTest(value=value):
                self.manifest.write_text(value)
                self.assertIn(f"[{census.ID}_INPUT]", self.cli(2))

    def test_checkout_must_not_be_silently_inferred_from_parent(self):
        script = Path(census.__file__).resolve()
        for path in [self.root / "lib", self.root / "missing"]:
            result = subprocess.run([sys.executable, str(script), "--root", str(path)],
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()

"""Finite Android resource-retirement CLI regressions."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tools.architecture.rules import native_retired_resources as guard


class NativeRetiredResourceChecks(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="wing-native-resource-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.write(guard.MANIFEST, '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
                   '<application android:icon="@mipmap/ic_launcher" '
                   'android:roundIcon="@mipmap/ic_launcher" /></manifest>')

    def write(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def cli(self, expected):
        result = subprocess.run([sys.executable, str(Path(guard.__file__).resolve()),
                                 "--root", str(self.root)], capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout

    def test_supported_successor_accepts_future_resource_appearance(self):
        self.write("android/app/src/main/res/drawable/launch_background.xml", "changed appearance")
        self.cli(0)

    def test_each_original_retired_path_is_rejected(self):
        for relative in guard.RETIRED:
            with self.subTest(relative=relative):
                path = self.write(relative, "retired original")
                self.assertIn(relative, self.cli(1))
                path.unlink()

    def test_launcher_binding_cannot_return_to_round_resource(self):
        path = self.root / guard.MANIFEST
        path.write_text(path.read_text().replace('android:roundIcon="@mipmap/ic_launcher"',
                                                'android:roundIcon="@mipmap/ic_launcher_round"'))
        self.assertIn("roundIcon must bind", self.cli(1))

    def test_malformed_inputs_fail_without_echoing_contents(self):
        path = self.root / guard.MANIFEST
        path.write_text("private-malformed-content")
        output = self.cli(2)
        self.assertIn(guard.ID + "_INPUT", output)
        self.assertNotIn("private-malformed-content", output)

    def test_missing_manifest_is_an_input_error(self):
        (self.root / guard.MANIFEST).unlink()
        self.assertIn(guard.ID + "_INPUT", self.cli(2))


if __name__ == "__main__":
    unittest.main()

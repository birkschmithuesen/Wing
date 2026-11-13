"""Integration tests for the local pre-commit linter hook.

These tests use disposable Git repositories and fake tool executables. They do
not start Flutter, Android builds, devices, or backend services.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "scripts/check_commit_linters.py"
INSTALLER = ROOT / "scripts/install_git_hooks.py"
HOOK = ROOT / ".githooks/pre-commit"
PYTHON_GUARDS = (
    "tools/architecture/rules/authored_census.py",
    "tools/architecture/rules/native_retired_resources.py",
    "tools/architecture/rules/fixture_model_catalog.py",
    "tools/architecture/rules/retired_fixture_recovery.py",
    "tools/architecture/native_share/provider_boundary.py",
    "tools/architecture/native_notification/retired_action.py",
    "tools/architecture/native_notification/retired_declaration.py",
    "tools/architecture/native_voice/file_api_boundary.py",
    "tools/architecture/native_voice/permission_lifecycle.py",
)


class CommitLintersIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wing-commit-hook-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self._git("init", "--quiet")
        self._git("config", "user.name", "Wing Hook Test")
        self._git("config", "user.email", "wing-hook-test@example.invalid")
        self._fixture_files()
        self._git("add", ".")
        # Seed the repository before enabling its real hook.
        self._git("-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "fixture")
        self._install_hook()
        self._install_fake_tools()

    def _git(self, *args, env=None, check=True):
        return subprocess.run(
            ["git", "-C", str(self.repo), *args],
            text=True,
            capture_output=True,
            env=env,
            check=check,
        )

    def _write(self, relative, contents):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        return path

    def _fixture_files(self):
        self._write(".gitignore", ".dart_tool/\n")
        self._write(".dart_tool/package_config.json", "{}\n")
        self._write(
            "tools/architecture/check_all.dart",
            "import 'cli.dart';\nimport 'model.dart';\n"
            "final allRules = <String, Rule>{\n};\n"
            "Future<void> main(List<String> args) => run(args, allRules);\n",
        )
        self._write(
            "tools/architecture/baseline.json",
            '{"schema":1,"entries":[]}\n',
        )
        for guard in PYTHON_GUARDS:
            self._write(
                guard,
                "import os, pathlib, sys\n"
                f"name = {guard!r}\n"
                "with pathlib.Path(os.environ['WING_GUARDS_LOG']).open('a') as log:\n"
                "    log.write(name + '\\n')\n"
                "if os.environ.get('WING_FAIL_GUARD') == name:\n"
                "    print('fake guard failure: ' + name)\n"
                "    raise SystemExit(1)\n"
                "raise SystemExit(0)\n",
            )
        self._write("lint_target.dart", "baseline clean\n")
        self._write("other.dart", "other baseline\n")
        self._write("scripts/check_commit_linters.py", RUNNER.read_text())
        self._write(".githooks/pre-commit", HOOK.read_text())
        (self.repo / ".githooks/pre-commit").chmod(0o755)

    def _install_hook(self):
        self._git("config", "core.hooksPath", ".githooks")

    def _install_fake_tools(self):
        fake_dart = self.bin / "dart"
        fake_dart.write_text(
            "#!" + sys.executable + "\n"
            "import os, pathlib, sys\n"
            "target = pathlib.Path.cwd() / 'lint_target.dart'\n"
            "contents = target.read_text() if target.exists() else '<missing>'\n"
            "pathlib.Path(os.environ['WING_DART_OBSERVED']).write_text(contents)\n"
            "other = pathlib.Path.cwd() / 'other.dart'\n"
            "pathlib.Path(os.environ['WING_OTHER_OBSERVED']).write_text(other.read_text() if other.exists() else '<missing>')\n"
            "fail_if = os.environ.get('WING_DART_FAIL_IF')\n"
            "raise SystemExit(1 if fail_if is not None and contents == fail_if else 0)\n"
        )
        fake_dart.chmod(0o755)
        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.bin}{os.pathsep}{self.env.get('PATH', '')}"
        self.env["WING_DART_OBSERVED"] = str(self.base / "dart-observed.txt")
        self.env["WING_OTHER_OBSERVED"] = str(self.base / "other-observed.txt")
        self.env["WING_GUARDS_LOG"] = str(self.base / "guards-run.txt")

    def _commit(self, message="change", env=None):
        return self._git("commit", "-m", message, env=env or self.env, check=False)

    def test_installer_enables_hook_for_local_commits(self):
        # The installer runs against its own path, so use an isolated checkout
        # shaped like the real repository and inspect its local Git config.
        subprocess.run(["git", "-C", str(self.repo), "config", "--unset", "core.hooksPath"], check=True)
        (self.repo / "scripts/install_git_hooks.py").write_text(INSTALLER.read_text())
        result = subprocess.run(
            [sys.executable, str(self.repo / "scripts/install_git_hooks.py")],
            cwd=self.repo,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self._git("config", "--local", "--get", "core.hooksPath").stdout.strip(), ".githooks")

    def test_staged_violation_blocks_commit_even_with_unstaged_fix(self):
        target = self.repo / "lint_target.dart"
        target.write_text("staged violation\n")
        self._git("add", "lint_target.dart")
        target.write_text("unstaged fixed version\n")
        self.env["WING_DART_FAIL_IF"] = "staged violation\n"
        staged_before = self._git("diff", "--cached", "--binary").stdout
        worktree_before = target.read_bytes()

        result = self._commit("staged violation")

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(Path(self.env["WING_DART_OBSERVED"]).read_text(), "staged violation\n")
        self.assertEqual(self._git("diff", "--cached", "--binary").stdout, staged_before)
        self.assertEqual(target.read_bytes(), worktree_before)
        self.assertIn("MM lint_target.dart", self._git("status", "--porcelain").stdout)

    def test_unstaged_violation_does_not_block_clean_staged_commit(self):
        target = self.repo / "lint_target.dart"
        target.write_text("staged clean\n")
        self._git("add", "lint_target.dart")
        target.write_text("unstaged violation\n")
        self.env.pop("WING_DART_FAIL_IF", None)
        staged_before = self._git("diff", "--cached", "--binary").stdout
        worktree_before = target.read_bytes()

        result = self._commit("clean staged tree")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(Path(self.env["WING_DART_OBSERVED"]).read_text(), "staged clean\n")
        self.assertEqual(
            Path(self.env["WING_GUARDS_LOG"]).read_text().splitlines(),
            list(PYTHON_GUARDS),
        )
        self.assertEqual(target.read_bytes(), worktree_before)
        self.assertNotEqual(self._git("diff", "--cached", "--binary").stdout, staged_before)
        self.assertIn("unstaged violation", target.read_text())

    def test_missing_dart_fails_closed_before_commit(self):
        target = self.repo / "lint_target.dart"
        target.write_text("staged change\n")
        self._git("add", "lint_target.dart")
        isolated_bin = self.base / "minimal-bin"
        isolated_bin.mkdir()
        for name in ("git", "python3"):
            executable = shutil.which(name)
            if executable:
                (isolated_bin / name).symlink_to(executable)
        env = self.env.copy()
        env["PATH"] = str(isolated_bin)
        result = self._commit("missing dart", env=env)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Dart is missing", result.stdout + result.stderr)
        self.assertEqual(self._git("diff", "--cached", "--binary").stdout.count("staged change"), 1)
        self.assertEqual(self._git("log", "-1", "--format=%s").stdout.strip(), "fixture")

    def test_nonempty_architecture_baseline_blocks_before_dart_runs(self):
        baseline = self.repo / "tools/architecture/baseline.json"
        baseline.write_text('{"schema":1,"entries":[{"id":"ARCH_TEST"}]}\n')
        self._git("add", "tools/architecture/baseline.json")
        staged_before = self._git("diff", "--cached", "--binary").stdout

        result = self._commit("nonempty architecture baseline")

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Architecture baseline must remain empty", result.stderr)
        self.assertFalse(Path(self.env["WING_DART_OBSERVED"]).exists())
        self.assertEqual(self._git("diff", "--cached", "--binary").stdout, staged_before)
        self.assertEqual(self._git("log", "-1", "--format=%s").stdout.strip(), "fixture")

    def test_python_native_guard_failure_blocks_commit(self):
        target = self.repo / "lint_target.dart"
        target.write_text("staged change\n")
        self._git("add", "lint_target.dart")
        env = self.env.copy()
        env["WING_FAIL_GUARD"] = PYTHON_GUARDS[-1]

        result = self._commit("python guard failure", env=env)

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            f"fake guard failure: {PYTHON_GUARDS[-1]}",
            result.stdout + result.stderr,
        )
        self.assertEqual(
            Path(self.env["WING_GUARDS_LOG"]).read_text().splitlines(),
            list(PYTHON_GUARDS),
        )
        self.assertEqual(self._git("log", "-1", "--format=%s").stdout.strip(), "fixture")

    def test_path_limited_commit_lints_partial_index_and_preserves_other_staged_change(self):
        target = self.repo / "lint_target.dart"
        target.write_text("path limited staged\n")
        other = self.repo / "other.dart"
        other.write_text("excluded staged violation\n")
        self._git("add", "lint_target.dart", "other.dart")
        env = self.env.copy()
        env["WING_DART_FAIL_IF"] = "excluded staged violation\n"

        result = self._git(
            "commit", "-m", "partial commit", "--", "lint_target.dart",
            env=env, check=False,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(Path(self.env["WING_DART_OBSERVED"]).read_text(), "path limited staged\n")
        self.assertEqual(Path(self.env["WING_OTHER_OBSERVED"]).read_text(), "other baseline\n")
        self.assertEqual(self._git("show", "HEAD:lint_target.dart").stdout, "path limited staged\n")
        self.assertEqual(self._git("show", "HEAD:other.dart").stdout, "other baseline\n")
        self.assertIn("excluded staged violation", self._git("diff", "--cached", "--", "other.dart").stdout)


if __name__ == "__main__":
    unittest.main()

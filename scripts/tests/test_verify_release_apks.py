import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_release_apks


class VerifyApksTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.apks = self.root / "build/app/outputs/flutter-apk"
        self.apks.mkdir(parents=True)
        self.abis = {"armeabi-v7a": 1, "arm64-v8a": 2, "x86_64": 3}
        for abi in self.abis:
            with zipfile.ZipFile(self.apks / f"app-{abi}-release.apk", "w",
                                 compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr(f"lib/{abi}/libapp.so", b"compiled app snapshot")
        (self.root / "android").mkdir()
        (self.root / "android/wing-release-certificate.sha256").write_text("a" * 64)
        (self.root / "sdk/build-tools/36.0.0").mkdir(parents=True)
        self.bad_package = False
        self.package_override = None
        self.bad_build = False
        self.bad_version = False
        self.bad_abi = False
        self.debuggable = False
        self.certificate = "a" * 64
        self.unsigned = False
        for patcher in [
            patch.object(verify_release_apks, "ROOT", self.root),
            patch.object(verify_release_apks, "current_version", return_value=((2, 36, 16), 2233)),
            patch.dict(os.environ, {"ANDROID_HOME": str(self.root / "sdk")}),
            patch.object(verify_release_apks.subprocess, "check_output", side_effect=self.tool_output),
        ]:
            patcher.start()
            self.addCleanup(patcher.stop)

    def tool_output(self, args, **kwargs):
        abi = Path(args[-1]).name.removeprefix("app-").removesuffix("-release.apk")
        if Path(args[0]).name == "aapt":
            # Damage x86_64 only: every split must be checked, not just ARM64.
            damaged = abi == "x86_64"
            package = (self.package_override or "wrong.package") if damaged and self.bad_package else "com.tarkilhk.wing"
            build = "2233" if damaged and self.bad_build else str(2233 * 10 + self.abis[abi])
            version = "2.36.15" if damaged and self.bad_version else "2.36.16"
            native = "arm64-v8a" if damaged and self.bad_abi else abi
            output = f"package: name='{package}' versionCode='{build}' versionName='{version}'\nnative-code: '{native}'\n"
            if damaged and self.debuggable:
                output += "application-debuggable\n"
            return output
        if self.unsigned:
            raise subprocess.CalledProcessError(1, args, "DOES NOT VERIFY")
        if Path(args[0]).parent.name == "37.0.0":
            return f"V2 Signer: certificate SHA-256 digest: {self.certificate}\n"
        return f"Signer #1 certificate SHA-256 digest: {self.certificate}\n"

    def verify(self):
        with contextlib.redirect_stdout(io.StringIO()):
            verify_release_apks.verify()

    def test_accepts_complete_signed_release(self):
        self.verify()

    def test_newer_installed_sdk_does_not_break_valid_certificates(self):
        (self.root / "sdk/build-tools/37.0.0").mkdir()
        self.verify()

    def test_rejects_non_release_package_identity_on_non_arm64_split(self):
        self.bad_package = True
        for package in ('wrong.package', 'com.tarkilhk.wing.dev',
                        'com.tarkilhk.wing.notificationqa', 'com.tarkilhk.wing.perfqa'):
            with self.subTest(package=package):
                self.package_override = package
                with self.assertRaisesRegex(ValueError, 'incorrect package or version'):
                    self.verify()

    def test_rejects_base_version_code_without_abi_offset_on_non_arm64_split(self):
        self.bad_build = True
        with self.assertRaisesRegex(ValueError, 'incorrect package or version'):
            self.verify()

    def test_rejects_wrong_version_name_on_non_arm64_split(self):
        self.bad_version = True
        with self.assertRaisesRegex(ValueError, 'incorrect package or version'):
            self.verify()

    def test_rejects_wrong_native_architecture_on_non_arm64_split(self):
        self.bad_abi = True
        with self.assertRaisesRegex(ValueError, 'incorrect native architecture'):
            self.verify()

    def test_rejects_debuggable_release_on_non_arm64_split(self):
        self.debuggable = True
        with self.assertRaisesRegex(ValueError, 'release must not be debuggable'):
            self.verify()

    def test_rejects_wrong_signing_key(self):
        self.certificate = "b" * 64
        with self.assertRaisesRegex(ValueError, "incorrect signing certificate"):
            self.verify()

    def test_rejects_unsigned_apk(self):
        self.unsigned = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.verify()

    def test_rejects_missing_split(self):
        (self.apks / "app-x86_64-release.apk").unlink()
        with self.assertRaisesRegex(ValueError, "Expected exactly"):
            self.verify()

    def test_rejects_extra_debug_artifact(self):
        (self.apks / "app-debug.apk").touch()
        with self.assertRaisesRegex(ValueError, "Expected exactly"):
            self.verify()

    def test_rejects_each_measurement_marker_in_non_arm64_snapshot(self):
        apk = self.apks / 'app-x86_64-release.apk'
        for marker in verify_release_apks.PERFORMANCE_MARKERS:
            with self.subTest(marker=marker):
                with zipfile.ZipFile(apk, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
                    archive.writestr('lib/x86_64/libapp.so', b'snapshot ' + marker)
                with self.assertRaisesRegex(ValueError, 'performance instrumentation'):
                    self.verify()

    def test_rejects_missing_compiled_snapshot(self):
        with zipfile.ZipFile(self.apks / 'app-x86_64-release.apk', 'w'):
            pass
        with self.assertRaisesRegex(ValueError, 'missing compiled app snapshot'):
            self.verify()


if __name__ == "__main__":
    unittest.main()

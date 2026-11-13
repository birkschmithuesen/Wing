#!/usr/bin/env python3
"""Verify every distributable APK before allowing release publication."""

import os
from pathlib import Path
import re
import subprocess
import zipfile

from release import ROOT, current_version


PERFORMANCE_MARKERS = (
    b"wing.markdown.prepare",
    b"wing.markdown.fence.scan",
    b"markdown.background.",
    b"markdown.message.",
    b"markdown.code.",
    b"markdown.blocks.",
    b"markdown.ast.copy",
    b"ext.wingLive.",
    b"ext.wingReplay.",
    b"ext.wingPerf.",
    b"ext.wingNavigationSoak.",
)


def verify_no_performance_instrumentation(apk):
    """Check compiled app snapshots, not compressed archive byte strings.

    This corroborates source gating; marker absence alone cannot prove that all
    possible overhead is absent. The product-mode probe verifies the real paths.
    """
    with zipfile.ZipFile(apk) as archive:
        snapshots = [name for name in archive.namelist()
                     if re.fullmatch(r"lib/[^/]+/libapp\.so", name)]
        if not snapshots:
            raise ValueError(f"{apk.name}: missing compiled app snapshot")
        for name in snapshots:
            data = archive.read(name)
            if any(marker in data for marker in PERFORMANCE_MARKERS):
                raise ValueError(f"{apk.name}: performance instrumentation in {name}")


def verify():
    version, build = current_version()
    version_name = ".".join(map(str, version))
    apk_dir = ROOT / "build/app/outputs/flutter-apk"
    abi_codes = {"armeabi-v7a": 1, "arm64-v8a": 2, "x86_64": 3}
    expected = {f"app-{abi}-release.apk" for abi in abi_codes}
    actual = {path.name for path in apk_dir.glob("*.apk")}
    if actual != expected:
        raise ValueError(f"Expected exactly {sorted(expected)}, found {sorted(actual)}")
    sdk = Path(os.environ["ANDROID_HOME"])
    # apksigner 37 changed its certificate report format. Verification uses
    # the explicit toolchain contract instead of the runner's newest install.
    build_tools = sdk / "build-tools/36.0.0"
    if not build_tools.is_dir():
        raise ValueError("Install Android build-tools;36.0.0 before verifying APKs")
    certificate = (ROOT / "android/wing-release-certificate.sha256").read_text().strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", certificate):
        raise ValueError("Invalid pinned signing certificate")
    for abi, code in abi_codes.items():
        apk = apk_dir / f"app-{abi}-release.apk"
        verify_no_performance_instrumentation(apk)
        badging = subprocess.check_output([str(build_tools / "aapt"), "dump", "badging", str(apk)], text=True)
        package = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging, re.M)
        expected_package = ("com.tarkilhk.wing", str(build * 10 + code), version_name)
        if not package or package.groups() != expected_package:
            raise ValueError(f"{apk.name}: incorrect package or version")
        if "application-debuggable" in badging:
            raise ValueError(f"{apk.name}: release must not be debuggable")
        native = re.search(r"^native-code: (.+)$", badging, re.M)
        if not native or native.group(1).strip() != f"'{abi}'":
            raise ValueError(f"{apk.name}: incorrect native architecture")
        signed = subprocess.check_output(
            [str(build_tools / "apksigner"), "verify", "--print-certs", str(apk)],
            text=True, stderr=subprocess.STDOUT,
        )
        fingerprints = re.findall(r"^Signer #\d+ certificate SHA-256 digest: (\w+)$", signed, re.M)
        if [value.lower() for value in fingerprints] != [certificate]:
            raise ValueError(f"{apk.name}: incorrect signing certificate")
        print(f"Verified {apk.name}: {version_name}, versionCode {build * 10 + code}, expected release certificate")


if __name__ == "__main__":
    verify()

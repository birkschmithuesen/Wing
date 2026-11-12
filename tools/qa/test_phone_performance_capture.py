"""Host-only parser, measurement and cancellation checks; never calls ADB."""
import argparse
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from phone_performance_capture import (
    Capture, charge_summary, checkpoint_issues, parse_battery, parse_idle,
    parse_power, parse_version, trace_config,
)


BATTERY = """Current Battery Service state:
  AC powered: false
  USB powered: false
  Wireless powered: false
  status: 3
  health: 2
  level: 95
  temperature: 360
  voltage: 4321
  Charge counter: 4421340
"""


def checkpoint(counter=4421340, moment=100, pids=None):
    battery = parse_battery(BATTERY)
    battery["charge_counter_uah"] = counter
    return {"battery": battery, "battery_read_monotonic_seconds": moment,
            "wing_pids": ["42"] if pids is None else pids,
            "power": parse_power("mWakefulness=Asleep\nDisplay Power: state=OFF"),
            "device_idle": parse_idle("mState=IDLE mLightState=IDLE mScreenOn=false mCharging=false")}


class MeasurementTests(unittest.TestCase):
    def test_units_and_sensitive_fields_are_not_retained(self):
        battery = parse_battery(BATTERY + "  private-chat-content: SECRET\n")
        self.assertEqual(battery["charge_counter_uah"], 4421340)
        self.assertEqual(battery["temperature_tenths_c"], 360)
        self.assertNotIn("SECRET", str(battery))
        self.assertEqual(parse_version("versionCode=23562 minSdk=26\nversionName=1.1.3\nSECRET"),
                         {"versionCode": "23562", "versionName": "1.1.3"})

    def test_missing_counter_and_unknown_power_fail_closed(self):
        sample = checkpoint()
        sample["battery"] = parse_battery("level: 95\n")
        self.assertIn("Usable charge counter unavailable", checkpoint_issues(sample, "running"))
        self.assertIn("Charging-source state unavailable", checkpoint_issues(sample, "running"))

    def test_charging_screen_on_and_pid_change_are_detected(self):
        sample = checkpoint(pids=["43"])
        sample["battery"]["usb_powered"] = True
        sample["power"] = parse_power("mWakefulness=Awake\nDisplay Power: state=ON")
        issues = checkpoint_issues(sample, "running", ["42"])
        self.assertIn("Phone connected to power", issues)
        self.assertIn("Phone not confirmed logically screen off", issues)
        self.assertIn("Wing PID changed between sampled checkpoints", issues)

    def test_expected_stopped_state_and_aod_are_accepted(self):
        sample = checkpoint(pids=[])
        sample["power"] = parse_power("mWakefulness=Dozing\nDisplay Power: state=DOZE")
        self.assertEqual(checkpoint_issues(sample, "stopped", []), [])
        self.assertIn("Wing process state differs from expected state", checkpoint_issues(sample, "running"))

    def test_charge_rate_uses_counter_read_interval(self):
        summary = charge_summary([checkpoint(4421340, 100), checkpoint(4419340, 1300)])
        self.assertEqual(summary["counter_elapsed_seconds"], 1200)
        self.assertEqual(summary["drop_mah"], 2)
        self.assertEqual(summary["mean_whole_device_ma"], 6)
        self.assertIsNone(charge_summary([checkpoint()]))

    def test_20_minute_sampling_is_sparse_and_absolute(self):
        with tempfile.TemporaryDirectory() as output:
            args = argparse.Namespace(mode="battery", seconds=1200, serial="not-a-device",
                                      label="test", abort_file=None, output=Path(output),
                                      expected_wing_state="running")
            capture = Capture(args)
            capture.metadata = Mock(return_value={"wing_version": {"versionCode": "23562", "versionName": "1.1.3"}})
            capture.outside_interval = Mock(return_value={})
            capture.shell = Mock(return_value="versionCode=23562\nversionName=1.1.3")
            capture.wait_until = Mock()
            offsets = []

            def read(offset):
                offsets.append(offset)
                sample = checkpoint(4421340 - offset, 100 + offset)
                capture.report["checkpoints"].append(sample)
                return sample

            capture.battery_checkpoint = read
            capture.battery()
            self.assertEqual(offsets, [0, 600, 1200])
            self.assertEqual([call.args[0] for call in capture.wait_until.call_args_list], [700, 1300])
            self.assertTrue(capture.report["completed_interval"])
            self.assertEqual(capture.report["inconclusive_reasons"], [])

    def test_trace_cancellation_stops_only_own_session_and_files(self):
        with tempfile.TemporaryDirectory() as output:
            args = argparse.Namespace(mode="trace", seconds=45, serial="not-a-device",
                                      label="test", abort_file=None, output=Path(output))
            capture = Capture(args)
            capture.metadata = Mock(return_value={})
            capture.wait_until = Mock(side_effect=InterruptedError("test abort"))
            operations = []

            def call(*words, **kwargs):
                operations.append(words)
                if words[0] == "pull":
                    Path(words[2]).write_bytes(b"test trace")
                return SimpleNamespace(returncode=0, stdout="")

            capture.call = call
            with self.assertRaises(InterruptedError):
                capture.trace()
            key = capture.report["session_key"]
            self.assertIn(("shell", "perfetto", "--attach=" + key, "--stop"), operations)
            self.assertIn(("shell", "rm", "-f", "/data/misc/perfetto-traces/" + key + ".pftrace"), operations)
            self.assertFalse(capture.report.get("completed_interval", False))
            self.assertNotIn("killall", str(operations))
            self.assertNotIn("--remove-all", str(operations))

    def test_failed_trace_pull_preserves_owned_remote_evidence(self):
        for failure in ("nonzero", "timeout"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as output:
                args = argparse.Namespace(mode="trace", seconds=45, serial="not-a-device",
                                          label="test", abort_file=None, output=Path(output))
                capture = Capture(args)
                capture.metadata = Mock(return_value={})
                capture.wait_until = Mock()
                operations = []

                def call(*words, **kwargs):
                    operations.append(words)
                    if words[0] == "pull":
                        if failure == "timeout":
                            raise subprocess.TimeoutExpired("mock pull", 30)
                        return SimpleNamespace(returncode=1, stdout="")
                    return SimpleNamespace(returncode=0, stdout="")

                capture.call = call
                capture.trace()
                key = capture.report["session_key"]
                remote = "/data/misc/perfetto-traces/" + key + ".pftrace"
                self.assertIn(("shell", "perfetto", "--attach=" + key, "--stop"), operations)
                self.assertFalse(any(words[:2] == ("shell", "rm") for words in operations))
                self.assertFalse(capture.report["own_remote_files_removed"])
                self.assertEqual(capture.report["recovery_remote_trace"], remote)
                self.assertTrue(capture.report["inconclusive_reasons"])

    def test_partial_counter_read_survives_later_query_failure(self):
        with tempfile.TemporaryDirectory() as output:
            args = argparse.Namespace(mode="battery", seconds=1200, serial="not-a-device",
                                      label="test", abort_file=None, output=Path(output),
                                      expected_wing_state="running")
            capture = Capture(args)
            capture.report["checkpoints"] = []
            capture.shell = Mock(return_value=BATTERY)
            capture.call = Mock(return_value=SimpleNamespace(returncode=2, stdout=""))
            with self.assertRaises(RuntimeError):
                capture.battery_checkpoint(0)
            self.assertEqual(capture.report["checkpoints"][0]["battery"]["charge_counter_uah"], 4421340)
            self.assertTrue((Path(output) / "capture.json").is_file())

    def test_preexisting_abort_file_prevents_adb(self):
        with tempfile.TemporaryDirectory() as output:
            abort = Path(output) / "abort"
            abort.touch()
            args = argparse.Namespace(mode="battery", seconds=1200, serial="not-a-device",
                                      label="test", abort_file=abort, output=Path(output),
                                      expected_wing_state="running")
            capture = Capture(args)
            with patch("phone_performance_capture.subprocess.run") as adb:
                with self.assertRaises(InterruptedError):
                    capture.call("shell", "dumpsys", "battery")
                adb.assert_not_called()

    def test_trace_config_has_bounded_duration_and_filtered_logs(self):
        config = trace_config(45)
        self.assertIn("duration_ms: 45000", config)
        self.assertIn('filter_tags: "WingPerf"', config)
        for forbidden in ("android.input.inputevent", "surfaceflinger.layers", "windowmanager", "atrace_apps: \"*\""):
            self.assertNotIn(forbidden, config)


if __name__ == "__main__":
    unittest.main()

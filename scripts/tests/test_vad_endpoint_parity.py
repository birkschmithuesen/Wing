"""Golden cases shared with test/vad_endpoint_test.dart (Dart is the app's implementation)."""
import json
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "voice"))

import vad_endpoint  # noqa: E402


def expand(runs):
    for probability, count in runs:
        for _ in range(count):
            yield float(probability)


class VadEndpointParityTest(unittest.TestCase):
    def test_golden_cases(self):
        cases = json.loads((ROOT / "test/fixtures/vad_endpoint_cases.json").read_text())["cases"]
        self.assertGreaterEqual(len(cases), 16)
        for case in cases:
            with self.subTest(case["name"]):
                raw = case["config"]
                config = vad_endpoint.Config(
                    pause_ms=raw.get("pauseMs", 1800),
                    min_speech_ms=raw.get("minSpeechMs", 250),
                    pre_roll_ms=raw.get("preRollMs", 300),
                    max_ms=raw.get("maxMs", 600000),
                    no_speech_ms=raw.get("noSpeechMs", 8000),
                )
                endpointer = vad_endpoint.Endpointer(config)
                decision = endpointer.feed_all(expand(case["runs"]))
                if decision is None and case["force"]:
                    decision = endpointer.force_end(case["force"])
                expected = case["expect"]
                if expected is None:
                    self.assertIsNone(decision)
                    continue
                self.assertIsNotNone(decision)
                self.assertEqual(
                    (decision.reason, decision.start_window, decision.end_window, decision.at_window),
                    (expected["reason"], expected["startWindow"], expected["endWindow"], expected["atWindow"]),
                )


if __name__ == "__main__":
    unittest.main()

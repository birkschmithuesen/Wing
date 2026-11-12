"""Host-only checks for paired replay provenance and matching layout inputs."""
import json
from pathlib import Path
import tempfile
import unittest

from compare_workspace_replays import LABELS, compare


class ComparisonChecks(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for index,label in enumerate(LABELS):
            directory = self.root / label
            directory.mkdir()
            start = 100000000 + index * 40000000
            report = {
                'label':label, 'startEpochUs':1800000000000000 + index * 40000000,
                'startUs':start, 'streamEndUs':start + 20000000,
                'endUs':start + 20500000,
                'comparisonEligible':True, 'valid':True, 'expectedDraftVerified':True,
                'sourceSha256':'source', 'initialSourceSha256':'initial', 'draftSha256':'draft',
                'deltaCount':400, 'deltaIntervalUs':50000,
                'keyboardStartPx':300, 'keyboardEndPx':300, 'displayRefreshHz':120,
                'nativeDraftStorage':False,
                'dartCpuSampling':False,
                'physicalWidthPx':1080, 'physicalHeightPx':2400,
                'devicePixelRatio':3, 'textScaleAt14':14,
                'maxDeltaLatenessUs':1000,
                'nativeInput':{'keys':60, 'periodUs':250000, 'inputMode':'emulator',
                               'maxCompletionLatenessUs':2000},
                'frames':[
                    {'startUs':start + 50000, 'buildUs':12000, 'rasterUs':3000},
                    {'startUs':start + 100000, 'buildUs':2000, 'rasterUs':4000},
                    {'startUs':start + 20100000, 'buildUs':5000, 'rasterUs':2000},
                ],
            }
            self.write(label, 'replay.json', report)
            self.write(label, 'system-summary.json', {
                'start_monotonic_us':start, 'end_monotonic_us':report['endUs'],
                'trace_data_loss':[{'total':0}], 'native_preflight':{'supported':False},
            })
            self.write(label, 'vm-profiler-restored.json', {'restored':True})

    def write(self, label, name, value):
        (self.root / label / name).write_text(json.dumps(value))

    def mutate(self, arm, name, **changes):
        path = self.root / arm / name
        value = json.loads(path.read_text())
        value.update(changes)
        self.write(arm, name, value)

    def test_matching_abba_is_eligible_and_keeps_frame_metrics(self):
        result = compare(self.root)
        self.assertTrue(result['eligible'])
        self.assertEqual(result['issues'], [])
        self.assertEqual(result['runs']['control-1']['ui']['frames'], 2)
        self.assertEqual(result['runs']['control-1']['ui']['p95Ms'], 12)
        self.assertEqual(result['runs']['control-1']['completionUi']['maxMs'], 5)

    def test_replay_label_must_match_its_arm_directory(self):
        self.mutate('fixed-1', 'replay.json', label='control-1')
        result = compare(self.root)
        self.assertFalse(result['eligible'])
        self.assertIn('fixed-1: replay label mismatch', result['issues'])

    def test_diagnostic_sampling_cannot_mix_with_paired_timings(self):
        self.mutate('fixed-1', 'replay.json', dartCpuSampling=True)
        result = compare(self.root)
        self.assertFalse(result['eligible'])
        self.assertIn('Different dartCpuSampling across runs', result['issues'])

    def test_capture_chronology_must_be_strict_abba(self):
        for timestamp in [1800000000000000, 1799999999000000]:
            with self.subTest(timestamp=timestamp):
                self.mutate('fixed-1', 'replay.json', startEpochUs=timestamp)
                result = compare(self.root)
                self.assertFalse(result['eligible'])
                self.assertIn('Replay capture order is not ABBA', result['issues'])

    def test_system_trace_must_match_both_replay_bounds(self):
        for field,value in [('start_monotonic_us',140000001),
                            ('end_monotonic_us',160500001)]:
            with self.subTest(field=field):
                self.mutate('fixed-1', 'system-summary.json',
                            start_monotonic_us=140000000, end_monotonic_us=160500000)
                self.mutate('fixed-1', 'system-summary.json', **{field:value})
                result = compare(self.root)
                self.assertFalse(result['eligible'])
                self.assertIn('fixed-1: system trace bounds do not match replay',
                              result['issues'])

    def test_matching_keyboard_does_not_hide_changed_layout_inputs(self):
        for key,value in [('physicalWidthPx',1200), ('physicalHeightPx',2600),
                          ('devicePixelRatio',2.5), ('textScaleAt14',28)]:
            with self.subTest(key=key):
                original = json.loads((self.root/'fixed-1'/'replay.json').read_text())
                self.mutate('fixed-1', 'replay.json', **{key:value})
                result = compare(self.root)
                self.assertFalse(result['eligible'])
                self.assertIn('Different '+key+' across runs', result['issues'])
                self.write('fixed-1', 'replay.json', original)


if __name__ == '__main__':
    unittest.main()

"""Small offline property guard proofs; the host test exports real Dart rows."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from tools.architecture.rules import stock_task_schedule_projection as rule


def valid():
    return {'observations': [
        {'id': case['id'], 'operation': method,
         'response': {'schedule': copy.deepcopy(case['schedule']), 'schedule_display': case['schedule_display'],
                      'unrelated': 'allowed'}}
        for case in rule.load()['cases'] for method in ('POST', 'PUT')
    ]}


class ScheduleProjectionChecks(unittest.TestCase):
    def test_valid_stock_outputs_and_unrelated_fields_pass(self):
        self.assertEqual(rule.check(valid()), [])

    def test_wrong_kind_instant_precision_and_display_fail(self):
        for field, replacement in [('kind', 'cron'), ('run_at', '2026-10-05T09:45:00+00:00'),
                                   ('run_at', '2026-10-04T09:45:00.000Z'), ('display', 'wrong')]:
            rows = copy.deepcopy(valid())
            target = next(row for row in rows['observations'] if row['id'] == 'utc-once')
            target['response']['schedule'][field] = replacement
            self.assertTrue(all(rule.ID in finding for finding in rule.check(rows)))
            self.assertEqual(len(rule.check(rows)), 1)

    def test_input_and_artifact_errors_are_explicit(self):
        for rows in [{}, {'observations': None}, {'observations': []},
                     {'observations': [{'operation': 'POST'}]}]:
            with self.assertRaises(ValueError):
                rule.check(rows)
        rows = valid()
        del rows['observations'][0]['response']['schedule']
        with self.assertRaises(ValueError):
            rule.check(rows)

    def test_actual_cli_exit_proof_and_fail_closed_artifact(self):
        bad = copy.deepcopy(valid())
        bad['observations'][0]['response']['schedule']['kind'] = 'once'
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / 'input.json'
            for payload, status in [(valid(), 0), (bad, 1), ({}, 2)]:
                path.write_text(json.dumps(payload))
                result = subprocess.run([sys.executable, rule.__file__, '--input', str(path)], text=True, capture_output=True)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                if status:
                    self.assertIn(rule.ID, result.stdout)
                self.assertNotIn('Traceback', result.stdout + result.stderr)
            artifact = Path(scratch) / 'artifact.json'
            altered = rule.load()
            altered['cases'][0]['schedule']['kind'] = 'once'
            artifact.write_text(json.dumps(altered))
            path.write_text(json.dumps(valid()))
            result = subprocess.run([sys.executable, rule.__file__, '--input', str(path), '--artifact', str(artifact)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn(rule.ID, result.stdout)
            self.assertNotIn('Traceback', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()

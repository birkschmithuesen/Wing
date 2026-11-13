"""Reject partial, stale and identity-changing Android process-recovery evidence."""
import unittest

from scripts.test_native_process_recovery import validate_checkpoints


class ProcessRecoveryCompletion(unittest.TestCase):
    def records(self):
        identity = {
            'submission_id': 'input-1', 'admission_id': 'accepted-1',
            'server_admission_count': 1,
            'wire_payload': {'submission_id': 'input-1', 'session_id': 'chat',
                             'profile': 'a', 'text': 'Exact original input'},
        }
        return [
            {**identity, 'phase': 'ready_for_stop', 'run_id': 'owned', 'pid': 100,
             'submissions': 1, 'uploads': 1},
            {**identity, 'phase': 'restored', 'run_id': 'owned', 'pid': 200,
             'submissions': 1, 'uploads': 0, 'draft_restored': True,
             'attachment_restored': True, 'outbox_paused': True, 'receipt_reconciled': True},
        ]

    def test_two_distinct_processes_recover_exact_receipt_without_new_admission(self):
        validate_checkpoints(self.records(), 'owned')

    def test_partial_or_duplicate_phases_fail(self):
        records = self.records()
        for incomplete in ([], records[:1], records[1:], records[::-1], records + records[1:]):
            with self.subTest(incomplete=incomplete), self.assertRaises(ValueError):
                validate_checkpoints(incomplete, 'owned')

    def test_malformed_checkpoint_shapes_fail(self):
        for records in (None, {}, [None, None], ['ready_for_stop', 'restored']):
            with self.subTest(records=records), self.assertRaises(ValueError):
                validate_checkpoints(records, 'owned')

    def test_non_integer_counts_fail(self):
        for value in (None, True, False, '0', 0.0):
            for phase in range(2):
                for field in ('submissions', 'uploads'):
                    records = self.records()
                    records[phase][field] = value
                    with self.subTest(value=value, phase=phase, field=field), self.assertRaises(ValueError):
                        validate_checkpoints(records, 'owned')

    def test_stale_checkpoint_fails(self):
        for phase in range(2):
            records = self.records()
            records[phase]['run_id'] = 'previous'
            with self.subTest(phase=phase), self.assertRaises(ValueError):
                validate_checkpoints(records, 'owned')

    def test_owner_recreation_in_same_process_fails(self):
        records = self.records()
        records[1]['pid'] = records[0]['pid']
        with self.assertRaises(ValueError):
            validate_checkpoints(records, 'owned')

    def test_invalid_process_identity_fails(self):
        for value in (None, '', 0, -1, True):
            records = self.records()
            records[1]['pid'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_checkpoints(records, 'owned')

    def test_missing_original_submission_fails(self):
        records = self.records()
        records[0]['submissions'] = 0
        with self.assertRaises(ValueError):
            validate_checkpoints(records, 'owned')

    def test_duplicate_submit_or_upload_fails(self):
        for field in ('submissions', 'uploads'):
            records = self.records()
            records[1][field] = 2 if field == 'submissions' else 1
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_checkpoints(records, 'owned')

    def test_each_missing_user_work_observation_fails(self):
        for field in ('draft_restored', 'attachment_restored', 'outbox_paused', 'receipt_reconciled'):
            records = self.records()
            del records[1][field]
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_checkpoints(records, 'owned')

    def test_changed_identity_payload_or_duplicate_admission_fails(self):
        for key, value in (
            ('submission_id', 'different-input'), ('admission_id', 'different-admission'),
            ('server_admission_count', 2),
            ('wire_payload', {'submission_id': 'input-1', 'session_id': 'chat',
                              'profile': 'b', 'text': 'Exact original input'}),
        ):
            records = self.records()
            records[1][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_checkpoints(records, 'owned')

    def test_missing_wire_proof_fails(self):
        for key in ('submission_id', 'admission_id', 'wire_payload', 'server_admission_count'):
            records = self.records()
            del records[1][key]
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_checkpoints(records, 'owned')


if __name__ == '__main__':
    unittest.main()
